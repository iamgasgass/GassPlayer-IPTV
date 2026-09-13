import SwiftUI

/// GlassIconButton: da .glassEffect() manuale a stile nativo .glass/.glassProminent.
///
/// FIX (stessa logica della tab bar): iOS 26 introduce buttonStyle(.glass) e
/// .glassProminent, pensati apposta per i bottoni — gestiscono automaticamente
/// stato pressed/hover, tinta, forma e la vera fisica del vetro dei
/// controlli di sistema. Avvolgere manualmente un bottone in .glassEffect()
/// (come facevo prima con GlassCircleModifier) da' un risultato visivamente
/// simile ma perde le micro-interazioni native (feedback di pressione,
/// adattamento automatico al contesto) che lo stile nativo fornisce gratis.
struct GlassIconButton: View {
    let systemImage: String
    var tint: Color? = nil
    var size: CGFloat = 44
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.41, weight: .semibold))
                .frame(width: size, height: size)
        }
        .modifier(NativeOrLegacyGlassCircle(tint: tint))
    }
}

private struct NativeOrLegacyGlassCircle: ViewModifier {
    let tint: Color?
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .tint(tint)
        } else {
            content
                .buttonStyle(.plain)
                .contentShape(Circle())
                .background(.ultraThinMaterial, in: Circle())
                .foregroundStyle(tint ?? .primary)
        }
    }
}

struct GlassPrimaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.headline).padding(.horizontal, 24).padding(.vertical, 12)
        }
        .modifier(NativeOrLegacyGlassCapsule())
    }
}

private struct NativeOrLegacyGlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(.accentColor)
        } else {
            content
                .buttonStyle(.plain)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}
