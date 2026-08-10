import SwiftUI
import AuthenticationServices

/// Apple's own sign-in button, wired to ``AuthService``.
///
/// Uses `SignInWithAppleButton` rather than a look-alike because Apple's guidelines require
/// it, and because the system button handles its own presentation, localisation and dark
/// mode. The scope request and the result mapping both live here so every place that offers
/// Apple sign-in behaves identically.
struct AppleSignInButton: View {
    var onSuccess: () -> Void = {}

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SignInWithAppleButton(.signIn) { request in
            // Both are optional to Apple, and both are only ever delivered once — on the
            // very first authorisation for this app.
            request.requestedScopes = [.fullName, .email]
        } onCompletion: { result in
            Task { await handle(result) }
        }
        // Match the system appearance so the button does not look pasted on in dark mode.
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: LayoutMetrics.minimumTapTarget)
        .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
    }

    private func handle(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            do {
                let credential = try AppleSignInCoordinator.credential(from: authorization)
                if await dependencies.auth.signIn(appleCredential: credential) {
                    onSuccess()
                }
            } catch {
                dependencies.auth.reportAppleSignInFailure(AppleSignInCoordinator.mapError(error))
            }
        case .failure(let error):
            dependencies.auth.reportAppleSignInFailure(AppleSignInCoordinator.mapError(error))
        }
    }
}
