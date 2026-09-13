import SwiftUI

/// Pulsante circolare traslucido realizzato soltanto con API SwiftUI pubbliche
/// disponibili dal deployment target iOS 17 del progetto.
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

struct GlassPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityAddTraits(.isButton)
    }
}
