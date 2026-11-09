import Foundation

/// Authorization result, before SDK/store custody. Domain failure has no API
/// that can remove this Matrix grant or its encrypted identity.
public struct OIDCMatrixSignIn: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let device: MatrixAuthenticatedDevice
    public let delivery: MASCodeDelivery
    fileprivate init(device: MatrixAuthenticatedDevice, delivery: MASCodeDelivery) {
        self.device = device; self.delivery = delivery
    }
    public var description: String { "OIDCMatrixSignIn(<identity and secrets redacted>)" }
    public var debugDescription: String { description }
}

@MainActor public struct OIDCDomainSignIn: CustomStringConvertible, CustomDebugStringConvertible {
    public let binding: OIDCAccountBinding
    public let refresh: OIDCGrantRefresh
    fileprivate init(binding: OIDCAccountBinding, refresh: OIDCGrantRefresh) { self.binding = binding; self.refresh = refresh }
    public nonisolated var description: String { "OIDCDomainSignIn(<identity and secrets redacted>)" }
    public nonisolated var debugDescription: String { description }
}

@MainActor public struct OIDCDriveSignIn: CustomStringConvertible, CustomDebugStringConvertible {
    public let refresh: OIDCGrantRefresh
    fileprivate init(refresh: OIDCGrantRefresh) { self.refresh = refresh }
    public nonisolated var description: String { "OIDCDriveSignIn(<identity and secrets redacted>)" }
    public nonisolated var debugDescription: String { description }
}

/// Joins real browser authorization and bounded HTTP adapters. Configuration
/// comes from the provider delivery; fixture registrations never select it.
/// The caller owns Matrix SDK preparation and the explicit installation marker.
@MainActor public final class OIDCSignIn {
    public typealias Authorize = @MainActor (OIDCFlow) async throws -> OIDCAcceptedCallback
    private let clients: MASPublicClients
    private let metadata: MASMetadata
    private let flows: OIDCFlows
    private let transport: MASHTTP
    private let authorize: Authorize
    private var busy = false
    public init(clients: MASPublicClients, metadata: MASMetadata, flows: OIDCFlows,
                transport: MASHTTP, authorize: @escaping Authorize) {
        self.clients = clients; self.metadata = metadata; self.flows = flows
        self.transport = transport; self.authorize = authorize
    }

    /// Starts an explicit first sign-in only after copy-only custody inventory
    /// proves that no Matrix record survives. Recovery and sign-out own every
    /// nonempty state; opening a browser must never be the first discovery of it.
    public func matrix(deviceID: String, sessionReader: MatrixSessionReader) async throws -> OIDCMatrixSignIn {
        guard !busy else { throw OIDCFailure.browserBusy }
        try sessionReader.requireAbsent()
        busy = true; defer { busy = false }
        let delivery = try await grant(.matrix(deviceID: deviceID))
        let device = try await transport.matrixWhoami(grant: delivery.grant)
        try Task.checkCancellation()
        return OIDCMatrixSignIn(device: device, delivery: delivery)
    }

    public func domain(matrix: OIDCMatrixSignIn, installation: OIDCInstallation,
                       store: OIDCDomainKeychain) async throws -> OIDCDomainSignIn {
        guard !busy else { throw OIDCFailure.browserBusy }
        guard matrix.delivery.grant.identity.issuer == metadata.issuer,
              matrix.delivery.grant.identity.audience == clients.matrix,
              matrix.delivery.grant.identity.isAuthorizationCode else { throw OIDCGrantFailure.invalidIdentity }
        return try await domain(matrixIssuer: matrix.delivery.grant.identity.issuer,
                                matrixSubject: matrix.delivery.grant.identity.subject,
                                installation: installation, store: store) { domain, me in
            try OIDCAccountBinding.bind(matrix: matrix.delivery.grant.identity,
                                        domain: domain, me: me, clients: clients)
        }
    }

    /// Resume the independent domain grant from a ready Matrix custody ticket.
    /// This is the relaunch path after a denied, cancelled or interrupted domain
    /// browser flow; it cannot create or replace the encrypted Matrix identity.
    public func domain(matrix: MatrixCustodyTicket, installation: OIDCInstallation,
                       store: OIDCDomainKeychain) async throws -> OIDCDomainSignIn {
        guard !busy else { throw OIDCFailure.browserBusy }
        guard matrix.envelope.generation == installation.generation,
              matrix.envelope.installationID == installation.id else {
            throw MatrixCustodyFailure.recoveryRequired
        }
        _ = try matrix.requiredDeviceKeys()
        guard matrix.envelope.issuer == metadata.issuer,
              matrix.envelope.session.clientID == clients.matrix else {
            throw OIDCGrantFailure.invalidIdentity
        }
        return try await domain(matrixIssuer: matrix.envelope.issuer,
                                matrixSubject: matrix.envelope.subject,
                                installation: installation, store: store) { domain, me in
            try OIDCAccountBinding.bind(matrix: matrix, domain: domain,
                                        me: me, clients: clients)
        }
    }

    /// Starts the separate Drive public-client flow only for the subject that
    /// the current Matrix/domain binding already verified.
    public func drive(account: OIDCRestoredAccount, installation: OIDCInstallation,
                      store: OIDCDriveKeychain) async throws -> OIDCDriveSignIn {
        guard !busy else { throw OIDCFailure.browserBusy }
        try store.requireEmptyForSignIn()
        busy = true
        defer { busy = false }
        let delivery = try await grant(.drive)
        do {
            guard delivery.grant.identity.issuer == account.issuer,
                  delivery.grant.identity.subject == account.subject,
                  delivery.grant.identity.audience == MASPublicClients.drive,
                  delivery.grant.identity.isAuthorizationCode else {
                throw OIDCFailure.subjectMismatch
            }
            let refresh = try OIDCGrantRefresh(
                store: store,
                metadata: metadata,
                grant: delivery.grant,
                generation: installation.generation,
                kind: .drive,
                clients: clients
            )
            try refresh.install(now: delivery.requestStartedAt)
            try Task.checkCancellation()
            return OIDCDriveSignIn(refresh: refresh)
        } catch {
            let record = OIDCStoredGrant(
                generation: installation.generation,
                issuer: metadata.issuer,
                clientID: MASPublicClients.drive,
                subject: delivery.grant.identity.subject,
                accessToken: delivery.grant.response.accessToken,
                refreshToken: delivery.grant.response.refreshToken,
                expiresAt: delivery.requestStartedAt,
                phase: .ready,
                attempt: nil
            )
            _ = try? await Task {
                _ = try? store.withdraw()
                try await transport.revokeDomain(record, metadata: metadata)
            }.value
            throw error
        }
    }

    private func domain(matrixIssuer: String, matrixSubject: String,
                        installation: OIDCInstallation, store: OIDCDomainKeychain,
                        bind: (VerifiedOIDCIdentity, OIDCMe) throws -> OIDCAccountBinding) async throws -> OIDCDomainSignIn {
        // Do not authorize over a surviving grant, pending cleanup or prior
        // account. The explicit recovery/revocation path resolves it first.
        try store.requireEmptyForSignIn(installation: installation, clients: clients, metadata: metadata)
        busy = true; defer { busy = false }
        let delivery = try await grant(.domain)
        var installed = false
        do {
            let refresh = try OIDCGrantRefresh(store: store, metadata: metadata, grant: delivery.grant,
                generation: installation.generation, kind: .domain, clients: clients)
            try refresh.install(now: delivery.requestStartedAt)
            installed = true
            try Task.checkCancellation()
            guard matrixIssuer == delivery.grant.identity.issuer,
                  matrixSubject == delivery.grant.identity.subject else {
                throw OIDCFailure.subjectMismatch
            }
            guard Date().timeIntervalSince(delivery.requestStartedAt) < Double(delivery.grant.response.expiresIn) else {
                throw OIDCGrantFailure.reauthenticationRequired
            }
            let me = try await transport.domainMe(grant: delivery.grant)
            try Task.checkCancellation()
            let binding = try bind(delivery.grant.identity, me)
            try store.bind(binding, domainGrant: delivery.grant, installation: installation)
            return OIDCDomainSignIn(binding: binding, refresh: refresh)
        } catch {
            // Cleanup must run even if the caller task is cancelled. It only
            // addresses this unbound domain record; durable failure remains
            // for explicit revokeUnbound replay, never accepted as readiness.
            _ = try? await Task {
                if installed { try await store.revokeUnbound(using: transport, matching: delivery.grant) }
                else {
                    // Storage failed before a ready ticket existed. Never
                    // expose these tokens; attempt immediate remote cleanup.
                    let record = OIDCStoredGrant(generation: installation.generation, issuer: metadata.issuer,
                        clientID: clients.domain, subject: delivery.grant.identity.subject,
                        accessToken: delivery.grant.response.accessToken, refreshToken: delivery.grant.response.refreshToken,
                        expiresAt: delivery.requestStartedAt, phase: .ready, attempt: nil)
                    try await transport.revokeDomain(record, metadata: metadata)
                    // A failed readback may have left an unbound record.
                    try await store.revokeUnbound(using: transport, matching: delivery.grant)
                }
            }.value
            throw error
        }
    }

    private func grant(_ kind: OIDCFlow.Kind) async throws -> MASCodeDelivery {
        try Task.checkCancellation()
        let flow = try flows.begin(kind, clients: clients, metadata: metadata)
        defer { flows.cancel(flow.state) }
        let callback = try await authorize(flow)
        try Task.checkCancellation()
        guard callback.flow.state == flow.state, callback.flow.kind == kind,
              callback.flow.clientID == flow.clientID else { throw OIDCFailure.unknownOrUsedState }
        return try await transport.exchange(callback, metadata: metadata)
    }
}
