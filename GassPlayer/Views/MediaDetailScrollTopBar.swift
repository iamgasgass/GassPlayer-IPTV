import SwiftUI

/// Offset verticale del contenuto dentro lo `ScrollView` della scheda
/// dettaglio, misurato nel coordinate space dedicato `"mediaDetailScroll"`.
/// `0` = in cima; valori negativi = quanto si è scrollato verso il basso.
/// Usato solo come fallback su iOS 17 (da iOS 18 si usa
/// `onScrollGeometryChange`, che non passa dal ciclo delle preference).
struct MediaDetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Da applicare all'header dentro lo `ScrollView` (solo fallback iOS 17):
/// espone l'offset di scroll tramite `MediaDetailScrollOffsetKey`.
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

/// Da applicare allo `ScrollView` delle schede dettaglio: scrive in
/// `offset` la DISTANZA scrollata (`0` = in cima, cresce scendendo).
///
/// - iOS 18+: `onScrollGeometryChange`, lettura diretta del
///   `contentOffset` dello scroll view (affidabile, nessun
///   `GeometryReader` per frame).
/// - iOS 17: coordinate space + preference del `MediaDetailScrollTracker`.
struct MediaDetailScrollObserver: ViewModifier {
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                // `+ contentInsets.top` normalizza lo 0 sia che lo scroll
                // view applichi l'inset della safe area sia che lo ignori.
                max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
            } action: { _, newValue in
                if abs(newValue - offset) > 0.5 { offset = newValue }
            }
        } else {
            content
                .coordinateSpace(name: "mediaDetailScroll")
                .onPreferenceChange(MediaDetailScrollOffsetKey.self) { minY in
                    let scrolled = max(-minY, 0)
                    if abs(scrolled - offset) > 0.5 { offset = scrolled }
                }
        }
    }
}

/// Barra superiore fissa (fuori dallo `ScrollView`) identica al video di
/// riferimento (effetto "soft scroll edge" di iOS 26):
///
/// - In cima: trasparente, solo la X Liquid Glass neutra scura in alto a
///   destra, appoggiata sull'immagine.
/// - Quando il logo/titolo dell'hero passa sotto la barra: il contenuto
///   che scorre sotto viene sfocato in modo PROGRESSIVO (blur forte in
///   alto, che sfuma verso il basso) e scurito, e compare il titolo
///   centrato sulla STESSA riga della X. La X non si muove mai.
///
/// Lo sfondo NON usa `glassEffect` + `opacity` (il vetro non si dissolve
/// in modo affidabile con l'opacità e restava invisibile): usa materiali
/// di sistema con maschera a gradiente, che funzionano uguale su iOS 17+.
struct MediaDetailScrollTopBar: View {
    let title: String
    /// 0 = in cima (trasparente), 1 = oltre l'header (blur + titolo pieni).
    let progress: CGFloat
    /// Altezza della safe area superiore (Dynamic Island / notch), letta
    /// dalla vista che ospita la barra: niente più valore fisso a 59pt.
    let topInset: CGFloat
    let onClose: () -> Void

    // Misure calibrate sul video di riferimento (1180×2556 nativi = 3×):
    // cerchio X ≈ 44pt, centro riga a ≈81pt = inset (59pt) + metà cerchio;
    // il blur finisce poco sotto la riga (≈100pt) con dissolvenza morbida.
    private let rowHeight: CGFloat = 44
    private let closeButtonSize: CGFloat = 44
    private let fadeExtra: CGFloat = 8

    private var safeTop: CGFloat { max(topInset, 20) }
    private var barHeight: CGFloat { safeTop + rowHeight + fadeExtra }

    /// Il titolo compare un attimo dopo l'inizio del blur, come nel video.
    private var titleOpacity: Double {
        Double(min(max((progress - 0.35) / 0.65, 0), 1))
    }

    var body: some View {
        ZStack(alignment: .top) {
            progressiveBlurBackground
                .frame(height: barHeight)
                .opacity(Double(progress))
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                Color.clear.frame(width: closeButtonSize + 32, height: rowHeight)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
                    .opacity(titleOpacity)
                Color.clear.frame(width: closeButtonSize + 32, height: rowHeight)
            }
            .frame(height: rowHeight)
            .padding(.top, safeTop)
            .allowsHitTesting(false)
            .accessibilityHidden(titleOpacity < 0.5)

            HStack {
                Spacer(minLength: 0)
                // Tinta `nil`: vetro neutro scuro come nel video (una tinta
                // bianca renderebbe il cerchio bianco e la X invisibile).
                GlassIconButton(
                    systemImage: "xmark",
                    tint: nil,
                    size: closeButtonSize,
                    accessibilityLabel: "Chiudi"
                ) {
                    onClose()
                }
                .foregroundStyle(.white)
                .padding(.trailing, 16)
            }
            .frame(height: rowHeight)
            .padding(.top, safeTop)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        // Aspetto scuro anche con tema chiaro: il design delle schede
        // dettaglio è scuro (testi bianchi sull'hero).
        .environment(\.colorScheme, .dark)
    }

    /// Blur progressivo: due strati di materiale con maschere a gradiente
    /// diverse (sfocatura leggera che arriva più in basso + sfocatura
    /// forte concentrata in alto) più un velo scuro che sfuma.
    private var progressiveBlurBackground: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.55),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Rectangle()
                .fill(.regularMaterial)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.38),
                            .init(color: .clear, location: 0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.42), location: 0.0),
                    .init(color: .black.opacity(0.26), location: 0.6),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .compositingGroup()
    }
}

extension MediaDetailScrollTopBar {
    /// Converte la DISTANZA scrollata (0 = in cima) in progresso 0...1.
    /// Nel video la barra scatta quando il logo dell'hero passa sotto la
    /// riga della X (meta riga ≈ 230–315pt di scroll): rampa breve
    /// agganciata all'altezza dell'hero, non lineare dall'inizio.
    static func progress(forScrolled scrolled: CGFloat) -> CGFloat {
        let start = MediaDetailMetrics.heroHeight - 110
        let end = MediaDetailMetrics.heroHeight - 70
        guard end > start else { return scrolled >= start ? 1 : 0 }
        return min(max((scrolled - start) / (end - start), 0), 1)
    }
}
