import SwiftUI

/// Offset verticale del contenuto dentro lo `ScrollView` della scheda
/// dettaglio, misurato nel coordinate space dedicato `"mediaDetailScroll"`.
/// `0` = in cima; valori negativi = quanto si è scrollato verso il basso.
/// Usato SOLO come fallback su iOS 17 (su iOS 18+ si legge direttamente
/// `ScrollGeometry`, vedi `MediaDetailTopBarProgressModifier`).
struct MediaDetailScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Da applicare all'hero delle schede dettaglio: espone l'offset di scroll
/// tramite `MediaDetailScrollOffsetKey` (fallback iOS 17). Su iOS 18+ non
/// emette nulla, così non si paga un `GeometryReader` per ogni frame.
struct MediaDetailScrollTracker: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
        } else {
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
}

/// Misura lo scroll della `ScrollView` e lo traduce direttamente nel
/// progresso 0...1 della barra superiore.
///
/// FIX: prima l'offset grezzo finiva in uno `@State` aggiornato ad OGNI
/// frame di scroll, ridisegnando l'intera scheda (episodi inclusi). Ora
/// si pubblica solo il progresso già limitato a 0...1: fuori dalla breve
/// rampa di dissolvenza il valore non cambia e non c'è alcun ridisegno.
///
/// - iOS 18+: `onScrollGeometryChange` (offset reale del contenuto,
///   indipendente da coordinate space e safe area).
/// - iOS 17: `PreferenceKey` + coordinate space nominato.
struct MediaDetailTopBarProgressModifier: ViewModifier {
    @Binding var progress: CGFloat
    let safeAreaTop: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            // Copia locale: la closure di misura è `@Sendable` e non deve
            // catturare `self` (contiene un `Binding`, non `Sendable`).
            let safeAreaTop = self.safeAreaTop

            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                // `contentOffset.y + contentInsets.top` = 0 a riposo, sia con
                // sia senza inset di safe area, positivo scrollando in basso.
                MediaDetailMetrics.topBarProgress(
                    forScrolledDistance: geometry.contentOffset.y + geometry.contentInsets.top,
                    safeAreaTop: safeAreaTop
                )
            } action: { _, newValue in
                progress = newValue
            }
        } else {
            content
                .coordinateSpace(name: "mediaDetailScroll")
                .onPreferenceChange(MediaDetailScrollOffsetKey.self) { minY in
                    let newValue = MediaDetailMetrics.topBarProgress(
                        forScrolledDistance: -minY,
                        safeAreaTop: safeAreaTop
                    )
                    if abs(newValue - progress) > 0.001 { progress = newValue }
                }
        }
    }
}

extension View {
    /// Collega lo scroll di una `ScrollView` di scheda dettaglio al
    /// progresso della `MediaDetailScrollTopBar`.
    func mediaDetailTopBarProgress(_ progress: Binding<CGFloat>, safeAreaTop: CGFloat) -> some View {
        modifier(MediaDetailTopBarProgressModifier(progress: progress, safeAreaTop: safeAreaTop))
    }
}

/// Barra superiore fissa (fuori dallo `ScrollView`) identica al video di
/// riferimento: all'apertura è trasparente con solo la X in alto a destra;
/// quando il logo/titolo dell'hero scorre sotto la barra, un blur morbido
/// e scurito (senza bordo netto in basso) sfuma dentro insieme al titolo
/// centrato sulla STESSA riga della X, che resta sempre nello stesso punto.
///
/// Misure calibrate sul video di riferimento (1180×2556 px nativi = 3×):
/// - cerchio X ⌀ 44pt, margine destro 16pt, bordo superiore = safe area top
///   (nessun valore fisso: si adatta a Dynamic Island e notch);
/// - titolo 17pt semibold bianco, centro alla stessa altezza della X;
/// - blur che sfuma verso il basso fino a ≈26pt sotto la riga della X;
/// - dissolvenza: parte quando il fondo del logo raggiunge ≈100pt sotto la
///   safe area e si completa ≈60pt di scroll dopo.
struct MediaDetailScrollTopBar: View {
    let title: String
    /// 0 = in cima (trasparente), 1 = scrollato oltre l'hero (blur pieno).
    let progress: CGFloat
    /// Altezza della safe area superiore (Dynamic Island / notch).
    let safeAreaTop: CGFloat
    let onClose: () -> Void

    private let closeButtonSize: CGFloat = 44
    private let closeTrailingPadding: CGFloat = 16
    private let blurTailHeight: CGFloat = 26

    private var rowHeight: CGFloat { closeButtonSize }
    private var backgroundHeight: CGFloat { safeAreaTop + rowHeight + blurTailHeight }

    var body: some View {
        ZStack(alignment: .top) {
            backgroundBlur
                .frame(height: backgroundHeight)
                .opacity(progress)
                .allowsHitTesting(false)

            // Titolo: sfuma dentro con lo scroll, centrato sulla riga della X
            // con margini simmetrici per non sovrapporsi mai al pulsante.
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .padding(.horizontal, closeButtonSize + closeTrailingPadding * 2)
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
                .padding(.top, safeAreaTop)
                .opacity(progress)
                .allowsHitTesting(false)
                .accessibilityHidden(progress < 0.5)

            // La X è SEMPRE visibile fin dall'apertura (Liquid Glass) e non
            // sfuma mai.
            HStack {
                Spacer()
                GlassIconButton(systemImage: "xmark", tint: .white, size: closeButtonSize, accessibilityLabel: "Chiudi") {
                    onClose()
                }
                .padding(.trailing, closeTrailingPadding)
            }
            .padding(.top, safeAreaTop)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(edges: .top)
    }

    /// Blur progressivo + scurimento, entrambi mascherati con un gradiente
    /// verticale: pieno in alto (status bar compresa), morbido verso il
    /// basso, nessun bordo netto. Sempre in scheme scuro come nel video,
    /// anche con tema chiaro attivo.
    private var backgroundBlur: some View {
        ZStack {
            Rectangle()
                .fill(.thinMaterial)
                .mask(fadeMask)

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.55), location: 0.0),
                    .init(color: .black.opacity(0.42), location: 0.6),
                    .init(color: .black.opacity(0.0), location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .environment(\.colorScheme, .dark)
    }

    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: 0.62),
                .init(color: .black.opacity(0.0), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

extension MediaDetailMetrics {
    /// Converte la distanza scrollata (positiva verso il basso) in un
    /// progresso 0...1 per la barra superiore. La dissolvenza parte quando
    /// il fondo del logo/titolo dell'hero (14pt sopra il bordo inferiore
    /// dell'hero) arriva a ≈100pt sotto la safe area e finisce dopo ≈60pt
    /// di scroll, come nel video. Funzione pura e non isolata: richiamabile
    /// anche dalla closure `@Sendable` di `onScrollGeometryChange`.
    static func topBarProgress(forScrolledDistance distance: CGFloat, safeAreaTop: CGFloat) -> CGFloat {
        let logoBottomAtRest = heroHeight - 14
        let start = logoBottomAtRest - (safeAreaTop + 100)
        let length: CGFloat = 60
        return min(max((distance - start) / length, 0), 1)
    }
}
