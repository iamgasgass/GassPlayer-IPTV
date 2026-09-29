import SwiftUI

/// Barra superiore fissa (fuori dallo `ScrollView`) identica al video di
/// riferimento: all'apertura è trasparente con solo la X in alto a destra;
/// scrollando verso il basso oltre l'header, uno sfondo Liquid Glass
/// (blur parziale, non un nero pieno) sfuma dentro insieme al titolo
/// centrato, mentre la X resta sempre nello stesso punto.
struct MediaDetailScrollTopBar: View {
    let title: String
    /// 0 = in cima (trasparente), 1 = scrollato oltre l'header (blur pieno).
    let progress: CGFloat
    let onClose: () -> Void

    private let barHeight: CGFloat = 96

    var body: some View {
        ZStack {
            backgroundMaterial
                .opacity(progress)

            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 64)
                .opacity(progress)
                .frame(maxWidth: .infinity)
        }
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
        .overlay(alignment: .topTrailing) {
            GlassIconButton(systemImage: "xmark", tint: .white, size: 32, accessibilityLabel: "Chiudi") {
                onClose()
            }
            .padding(.trailing, 16)
            .padding(.top, 48)
        }
        .allowsHitTesting(true)
    }

    @ViewBuilder
    private var backgroundMaterial: some View {
        if #available(iOS 26.0, *) {
            Rectangle()
                .fill(.clear)
                .glassEffect(.regular, in: Rectangle())
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.18))
        }
    }
}

extension MediaDetailScrollTopBar {
    /// Converte l'offset grezzo dello scroll in un progresso 0...1, con la
    /// soglia allineata alla fine del fade dell'hero (dove il titolo
    /// diventa illeggibile sopra al testo che scorre sotto).
    static func progress(forOffset offset: CGFloat) -> CGFloat {
        let distance: CGFloat = MediaDetailMetrics.heroHeight - MediaDetailMetrics.heroFadeHeight - 20
        guard distance > 0 else { return offset < 0 ? 1 : 0 }
        return min(max(-offset / distance, 0), 1)
    }
}
