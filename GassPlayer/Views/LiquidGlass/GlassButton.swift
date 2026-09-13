import SwiftUI

/// GlassIconButton: da .glassEffect() manuale a stile nativo .glass/.glassProminent.
struct GlassIconButton: View {
    let systemImage: String
    var tint: Color? = nil
    var size: CGFloat = 44
    /// FIX "rettangolo scuro nei toggle Settings/Search": quando questo
    /// bottone vive dentro una toolbar di sistema (NavigationStack
    /// .toolbar), iOS 26 raggruppa automaticamente TUTTI gli elementi
    /// della stessa posizione (es. .navigationBarTrailing) in un'unica
    /// "pillola" di Liquid Glass condivisa. Applicare ANCHE
    /// .buttonStyle(.glass) sul singolo bottone in quel contesto
    /// sovrappone un SECONDO strato di vetro (circolare) dentro quello
    /// gia' fornito dal sistema, visibile come un rettangolo/cerchio
    /// leggermente piu' scuro. Con isInSystemToolbar = true si usa uno
    /// stile "plain" e si lascia che sia il sistema a rendere il vetro.
    var isInSystemToolbar: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.41, weight: .semibold))
                .frame(width: size, height: size)
        }
        .modifier(NativeOrLegacyGlassCircle(tint: tint, isInSystemToolbar: isInSystemToolbar))
    }
}

private struct NativeOrLegacyGlassCircle: ViewModifier {
    let tint: Color?
    var isInSystemToolbar: Bool = false
    func body(content: Content) -> some View {
        if isInSystemToolbar {
            content
                .buttonStyle(.plain)
                .foregroundStyle(tint ?? .primary)
        } else if #available(iOS 26.0, *) {
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
