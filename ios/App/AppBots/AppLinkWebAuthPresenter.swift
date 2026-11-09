import AuthenticationServices
import AtumNativeAPI
import UIKit

enum AppLinkWebAuthFailure: Error, Equatable, Sendable {
    case busy
    case cancelled
    case timedOut
    case browserUnavailable
    case invalidReturn
}

/// One associated-domain authentication session for one provider-bound app
/// attempt. Callback URLs and codes stay in memory and are never logged.
@MainActor
final class AppLinkWebAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?
    private var attempt: UUID?
    private var continuation: CheckedContinuation<AppLinkReturnProof, any Error>?
    private var timeoutTask: Task<Void, Never>?

    init(anchor: ASPresentationAnchor) { self.anchor = anchor }

    func authorize(at authorizationURL: URL,
                   nonce: AppLinkNonce,
                   initiationID: NativeID,
                   timeout: Duration = .seconds(600)) async throws -> AppLinkReturnProof {
        guard session == nil else { throw AppLinkWebAuthFailure.busy }
        guard anchor.isKeyWindow, anchor.windowScene?.activationState == .foregroundActive else {
            throw AppLinkWebAuthFailure.browserUnavailable
        }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending in
                let id = UUID()
                attempt = id
                continuation = pending
                let browser = ASWebAuthenticationSession(
                    url: authorizationURL,
                    callback: .https(host: "api.atumplatform.com",
                                     path: AppOnboardingPolicy.callbackPathPrefix + nonce.rawValue)
                ) { [weak self] callback, error in
                    Task { @MainActor in
                        self?.finish(id, callback: callback, error: error,
                                     nonce: nonce, initiationID: initiationID)
                    }
                }
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = false
                session = browser
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.expire(id)
                }
                guard browser.start() else {
                    finish(id, result: .failure(AppLinkWebAuthFailure.browserUnavailable))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    func cancel() {
        guard let attempt else { return }
        let browser = session
        finish(attempt, result: .failure(AppLinkWebAuthFailure.cancelled))
        browser?.cancel()
    }

    private func expire(_ id: UUID) {
        guard id == attempt else { return }
        let browser = session
        finish(id, result: .failure(AppLinkWebAuthFailure.timedOut))
        browser?.cancel()
    }

    private func finish(_ id: UUID, callback: URL?, error: (any Error)?,
                        nonce: AppLinkNonce, initiationID: NativeID) {
        guard id == attempt else { return }
        if let callback {
            do {
                finish(id, result: .success(try AppLinkReturnProof.parse(
                    callback, nonce: nonce, initiationID: initiationID
                )))
            } catch {
                finish(id, result: .failure(AppLinkWebAuthFailure.invalidReturn))
            }
            return
        }
        let nsError = error as NSError?
        let cancelled = nsError?.domain == ASWebAuthenticationSessionError.errorDomain
            && nsError?.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
        finish(id, result: .failure(cancelled ? AppLinkWebAuthFailure.cancelled
                                               : AppLinkWebAuthFailure.browserUnavailable))
    }

    private func finish(_ id: UUID, result: Result<AppLinkReturnProof, any Error>) {
        guard id == attempt, let pending = continuation else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        session = nil
        attempt = nil
        continuation = nil
        pending.resume(with: result)
    }
}
