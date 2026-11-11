import Foundation

/// The NSE uses the app's journaled OIDC rotation, never the SDK's automatic
/// refresh. Only the shared Matrix record is writable; identity/store selection
/// comes from custody, never from the push. Six seconds covers discovery,
/// one token POST, optional JWKS, verification and durable token readback.
public enum MatrixNotificationSession {
    @MainActor public static func current() async throws -> MatrixCustodyTicket {
        let latestSpendStart = ContinuousClock.now.advanced(by: .seconds(3))
        return try await bounded {
            let reader = try MatrixSessionReader.notificationReader()
            let ticket: MatrixCustodyTicket
            do {
                let lease = try MatrixRefreshLease.acquire()
                defer { withExtendedLifetime(lease) {} }
                ticket = try reader.loadForRefresh()
            }
            // Refuse an inaccessible/missing store before risking a token spend.
            do { _ = try MatrixStoreDirectory().requireExisting(generation: ticket.generation) }
            catch let error as MatrixStoreFailure { throw error }
            catch { throw MatrixStoreFailure.unavailable }
            if ticket.session.expiresAt > Date().addingTimeInterval(30) { return ticket }
            let transport = MASHTTP()
            // Reachability and verified issuer metadata before the spend journal.
            let metadata = try await MASProduction.metadata(using: transport)
            try Task.checkCancellation()
            let keychain = MatrixSessionKeychain(generation: ticket.generation,
                clients: try MASProduction.clients(), metadata: metadata)
            let resume = try keychain.resumeGrantForNotificationRefresh(ticket: ticket)
            let refresh = try OIDCGrantRefresh(resuming: resume)
            _ = try await refresh.accessToken(now: Date(), minimumValidity: 30, preflight: {
                // Do not journal a spend at the tail of the deadline after slow
                // discovery. Leave at least three seconds for POST/JWKS/save.
                guard ContinuousClock.now < latestSpendStart else { throw MatrixRefreshFailure.timedOut }
            }) { request in
                try await transport.refresh(request, metadata: metadata)
            }
            try Task.checkCancellation()
            let updated = try reader.loadCurrent()
            guard updated.generation == ticket.generation,
                  updated.envelope.installationID == ticket.envelope.installationID else {
                throw MatrixRefreshFailure.recordChanged
            }
            return updated
        }
    }

    @MainActor static func bounded<T: Sendable>(seconds: Double = 6,
        operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let work = Task { try await operation() }
        let deadline = Task {
            try await Task.sleep(for: .seconds(seconds))
            work.cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            do { return try await work.value }
            catch {
                if work.isCancelled { throw MatrixRefreshFailure.timedOut }
                throw error
            }
        } onCancel: { work.cancel() }
    }
}
