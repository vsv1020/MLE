import SwiftUI

/// "Continue with Google", shown only when the build carries a Google client ID.
///
/// Drawn to Google's branding rules for a neutral button — white (or dark grey) fill, a thin
/// outline, the four-colour "G" at the leading edge — at the same height and radius as the
/// Apple button beside it, so neither provider looks preferred.
struct GoogleSignInButton: View {
    var onSuccess: () -> Void = {}

    @Environment(\.appDependencies) private var dependencies
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if GoogleSignInConfiguration.isConfigured {
            Button {
                Task {
                    if await dependencies.auth.signInWithGoogle() { onSuccess() }
                }
            } label: {
                HStack(spacing: Spacing.sm) {
                    GoogleGlyph()
                        .frame(width: 18, height: 18)
                    Text("通过 Google 登录")
                        .font(.system(size: 19, weight: .medium))
                }
                .foregroundStyle(colorScheme == .dark ? Color(white: 0.89) : Color(white: 0.12))
                .frame(maxWidth: .infinity, minHeight: LayoutMetrics.minimumTapTarget)
                .background(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .fill(colorScheme == .dark ? Color(white: 0.075) : .white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color(white: 0.56) : Color(white: 0.45), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(dependencies.auth.isBusy)
            .accessibilityLabel("通过 Google 登录")
        }
    }
}

/// Google's "G", drawn as four arcs so no image asset is needed.
private struct GoogleGlyph: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let line = size * 0.2
            ZStack {
                arc(from: -40, to: 45, color: Color(red: 0.26, green: 0.52, blue: 0.96), line: line)  // blue
                arc(from: 45, to: 135, color: Color(red: 0.20, green: 0.66, blue: 0.33), line: line)  // green
                arc(from: 135, to: 205, color: Color(red: 0.98, green: 0.74, blue: 0.02), line: line) // yellow
                arc(from: 205, to: 320, color: Color(red: 0.92, green: 0.26, blue: 0.21), line: line) // red
                Rectangle()
                    .fill(Color(red: 0.26, green: 0.52, blue: 0.96))
                    .frame(width: size * 0.47, height: line)
                    .offset(x: size * 0.22)
            }
            .frame(width: size, height: size)
        }
        .accessibilityHidden(true)
    }

    private func arc(from start: Double, to end: Double, color: Color, line: CGFloat) -> some View {
        Circle()
            .trim(from: start / 360, to: end / 360)
            .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .butt))
            .padding(line / 2)
    }
}
