import AuthenticationServices
import UIKit
import AtumNativeAPI

/// A fixed, non-sensitive classification of failures produced by
/// `ASWebAuthenticationSession` itself. Provider callbacks continue to use
/// `OIDCFailure`, so diagnostics can distinguish an OS/browser failure from a
/// standards-level OAuth rejection without retaining an NSError or URL.
enum MASWebAuthFailure: Error, Equatable {
    case cancelled
    case presentationContextNotProvided
    case presentationContextInvalid
    case systemFailure
    case callbackMalformed
    case callbackSchemeMismatch
    case callbackHostMismatch
    case callbackExplicitPort
    case callbackUserInfo
    case callbackFragment
    case callbackPathMismatch
    case callbackCodeMissing
    case callbackCodeInvalid
    case callbackInvalidUnclassified
}

/// Live MAS browser adapter. Requires delivered static clients and the
/// associated webcredentials/applinks entitlement.
@MainActor final class MASWebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private let flows: OIDCFlows
    private var session: ASWebAuthenticationSession?
    private var attempt: UUID?
    private var state: String?
    private var continuation: CheckedContinuation<OIDCAcceptedCallback, any Error>?

    init(anchor: ASPresentationAnchor, flows: OIDCFlows) { self.anchor = anchor; self.flows = flows }

    func signIn(clients: MASPublicClients, metadata: MASMetadata, transport: MASHTTP = MASHTTP()) -> OIDCSignIn {
        OIDCSignIn(clients: clients, metadata: metadata, flows: flows, transport: transport) { [self] flow in
            try await authorize(flow)
        }
    }

    func authorize(_ flow: OIDCFlow) async throws -> OIDCAcceptedCallback {
        guard session == nil else { throw OIDCFailure.browserBusy }
        guard flows.isIssued(flow.state) else { throw OIDCFailure.unknownOrUsedState }
        guard anchor.isKeyWindow, anchor.windowScene?.activationState == .foregroundActive else {
            flows.cancel(flow.state); throw OIDCFailure.browserUnavailable
        }
        do {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { pending in
                    let id = UUID()
                    attempt = id; state = flow.state; continuation = pending
                    let browser = ASWebAuthenticationSession(url: flow.authorizationURL,
                        callback: .https(host: MASPublicClients.callback.host!, path: MASPublicClients.callback.path)) { [weak self] url, error in
                        // Provider/OS errors and callback URLs never enter diagnostics.
                        let failure = Self.browserFailure(error)
                        Task { @MainActor in self?.finish(id, url: url, failure: failure) }
                    }
                    browser.presentationContextProvider = self
                    browser.prefersEphemeralWebBrowserSession = false
                    session = browser
                    if !browser.start() {
                        finish(id, url: nil, failure: OIDCFailure.browserUnavailable)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(expectedState: flow.state) }
            }
        } catch {
            // Also handles cancellation before the browser/continuation exists.
            flows.cancel(flow.state)
            throw error
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func cancel() { cancel(expectedState: state) }
    private func cancel(expectedState: String?) {
        guard expectedState != nil, expectedState == state, let attempt else { return }
        let browser = session
        finish(attempt, url: nil, failure: OIDCFailure.authorizationDenied)
        browser?.cancel()
    }
    private func finish(_ id: UUID, url: URL?, failure: any Error) {
        guard id == attempt, let pending = continuation, let state else { return }
        session = nil; attempt = nil; continuation = nil; self.state = nil
        do {
            guard let url else { throw failure }
            pending.resume(returning: try flows.consume(url, expectedState: state))
        } catch let error as OIDCFailure {
            flows.cancel(state)
            if error == .invalidCallback, let url {
                pending.resume(throwing: Self.classifyInvalidCallback(url))
            } else {
                pending.resume(throwing: error)
            }
        } catch let error as MASWebAuthFailure {
            flows.cancel(state)
            pending.resume(throwing: error)
        } catch {
            flows.cancel(state)
            pending.resume(throwing: OIDCFailure.invalidCallback)
        }
    }

    nonisolated private static func browserFailure(_ error: (any Error)?) -> MASWebAuthFailure {
        guard let error else { return .systemFailure }
        let nsError = error as NSError
        guard nsError.domain == ASWebAuthenticationSessionError.errorDomain,
              let code = ASWebAuthenticationSessionError.Code(rawValue: nsError.code) else {
            return .systemFailure
        }
        return switch code {
        case .canceledLogin: .cancelled
        case .presentationContextNotProvided: .presentationContextNotProvided
        case .presentationContextInvalid: .presentationContextInvalid
        @unknown default: .systemFailure
        }
    }

    /// Mirrors only the two `OIDCFlows.consume` branches which can emit
    /// `invalidCallback`. Values are compared in memory and never retained.
    nonisolated private static func classifyInvalidCallback(_ callback: URL) -> MASWebAuthFailure {
        guard let url = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            return .callbackMalformed
        }
        guard url.scheme == "https" else { return .callbackSchemeMismatch }
        guard url.host == MASPublicClients.callback.host else { return .callbackHostMismatch }
        guard url.port == nil else { return .callbackExplicitPort }
        guard url.user == nil, url.password == nil else { return .callbackUserInfo }
        guard url.fragment == nil else { return .callbackFragment }
        guard url.percentEncodedPath == MASPublicClients.callback.path else {
            return .callbackPathMismatch
        }
        guard let code = (url.queryItems ?? []).first(where: { $0.name == "code" })?.value else {
            return .callbackCodeMissing
        }
        guard (1...8192).contains(code.utf8.count),
              !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .callbackCodeInvalid
        }
        return .callbackInvalidUnclassified
    }
}
