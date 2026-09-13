import SwiftUI

/// Pulsante circolare traslucido compatibile con iOS 17+.
/// `isInSystemToolbar` evita di disegnare un secondo sfondo quando la toolbar
/// di sistema fornisce gia' il proprio contenitore visivo.
struct GlassIconButton: View {
    let systemImage: String
    var tint: Color? = nil
    var size: CGFloat = 44
    var isInSystemToolbar: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.41, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? .primary)
        .modifier(GlassCircleStyle(isInSystemToolbar: isInSystemToolbar))
        .accessibilityAddTraits(.isButton)
    }
}

private struct GlassCircleStyle: ViewModifier {
    let isInSystemToolbar: Bool

    func body(content: Content) -> some View {
        if isInSystemToolbar {
            content
        } else {
            content
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }
}
