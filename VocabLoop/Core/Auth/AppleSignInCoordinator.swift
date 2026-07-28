import Foundation
import AuthenticationServices
import UIKit

/// Bridges `AuthenticationServices` to ``AppleCredential``.
///
/// Kept separate from ``AuthService`` so that nothing else in the app imports
/// `AuthenticationServices`, and so the whole Apple flow can be swapped for a stub in
/// tests. The `ASAuthorizationController` delegate API is callback-based, so this type
/// exists mainly to wrap it in `async`/`await`.
@MainActor
public final class AppleSignInCoordinator: NSObject {
    private var continuation: CheckedContinuation<AppleCredential, Error>?
    /// Strong reference for the duration of the request — the controller does not retain
    /// itself, and letting it deallocate silently drops the callback.
    private var controller: ASAuthorizationController?

    public override init() {
        super.init()
    }

    /// Present the Apple sign-in sheet and return the credential.
    ///
    /// Throws ``AuthError/appleSignInCancelled`` when the user dismisses it — callers are
    /// expected to swallow that rather than show an alert.
    public func requestCredential() async throws -> AppleCredential {
        // Only one request may be in flight; a second would overwrite the continuation
        // and leak the first, hanging the caller forever.
        guard continuation == nil else {
            throw AuthError.appleSignInFailed("A sign-in request is already in progress.")
        }

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(with result: Result<AppleCredential, Error>) {
        controller = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            finish(with: .failure(AuthError.appleSignInFailed("Unexpected credential type.")))
            return
        }

        // Name and email arrive on the *first* authorisation only. Apple will not send
        // them again, so anything we want must be persisted now.
        let name = [credential.fullName?.givenName, credential.fullName?.familyName]
            .compactMap { $0 }
            .joined(separator: " ")

        finish(with: .success(
            AppleCredential(
                userIdentifier: credential.user,
                email: credential.email,
                fullName: name.isEmpty ? nil : name,
                identityToken: credential.identityToken
            )
        ))
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        guard let authError = error as? ASAuthorizationError else {
            finish(with: .failure(AuthError.appleSignInFailed(error.localizedDescription)))
            return
        }
        switch authError.code {
        case .canceled:
            finish(with: .failure(AuthError.appleSignInCancelled))
        case .unknown, .invalidResponse, .notHandled, .failed:
            // `unknown` is also what you get when the Sign in with Apple *capability* is
            // missing from the build, which is by far the most likely cause during
            // development — so the message points there rather than saying "unknown".
            finish(with: .failure(AuthError.appleSignInUnavailable))
        default:
            finish(with: .failure(AuthError.appleSignInFailed(authError.localizedDescription)))
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Reach for the foreground scene's window rather than holding a reference: in
        // SwiftUI there is no view controller to ask, and the key window can change.
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
            ?? scenes.first?.windows.first
        return window ?? ASPresentationAnchor()
    }
}
