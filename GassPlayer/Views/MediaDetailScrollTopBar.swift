import SwiftUI

/// Offset verticale del contenuto dentro lo `ScrollView` della scheda
/// dettaglio, misurato nel coordinate space dedicato `"mediaDetailScroll"`.
/// `0` = in cima; valori negativi = quanto si è scrollato verso il basso.
struct MediaDetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Da applicare alla `ScrollView` delle schede dettaglio: espone l'offset
/// di scroll tramite `MediaDetailScrollOffsetKey`, da leggere con
/// `.onPreferenceChange`.
struct MediaDetailScrollTracker: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: MediaDetailScrollOffsetKey.self,
                    value: proxy.frame(in: .named("mediaDetailScroll")).minY
                )
            }
        )
    }
}

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

    // Misure calibrate pixel-per-pixel sul video di riferimento (frame
    // completamente scrollato, 1180×2556 nativi = fattore 3×):
    // cerchio X ⌀125px≈42pt→44pt standard; centro riga a 243px≈81pt da cima,
    // cioè 59pt di padding (il top-inset del Dynamic Island) + metà cerchio;
    // titolo sulla STESSA riga della X, non centrato nell'intera barra;
    // fondo sfocato/scurito finisce a ≈296px≈99pt → barHeight 104pt.
    private let barHeight: CGFloat = 104
    private let rowTopPadding: CGFloat = 59
    private let closeButtonSize: CGFloat = 44

    var body: some View {
        ZStack(alignment: .top) {
            backgroundMaterial
                .opacity(progress)
                .frame(height: barHeight)

            // Il titolo sfuma dentro con lo scroll; la X invece è SEMPRE
            // visibile fin dall'apertura (appoggiata sull'immagine, ne
            // assume il colore tramite il Liquid Glass) e resta ferma
            // nello stesso punto — non sfuma mai.
            HStack {
                Spacer(minLength: closeButtonSize + 32)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .opacity(progress)
                Spacer(minLength: closeButtonSize + 32)
            }
            .padding(.top, rowTopPadding)

            HStack {
                Spacer()
                GlassIconButton(systemImage: "xmark", tint: .white, size: closeButtonSize, accessibilityLabel: "Chiudi") {
                    onClose()
                }
                .padding(.trailing, 16)
            }
            .padding(.top, rowTopPadding)
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)
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
