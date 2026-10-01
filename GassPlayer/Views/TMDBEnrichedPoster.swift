import SwiftUI

/// Badge poster/rating TMDB, usato per arricchire le card VOD con dati reali
/// (Xtream spesso fornisce solo un'icona generica, non un poster proprio).
/// Fallback silenzioso: se manca l'API key o TMDB non trova corrispondenze,
/// non mostra nulla di rotto, semplicemente l'icona placeholder originale.
///
/// Senza sfarfallio: il risultato TMDB e l'immagine vengono letti in modo
/// sincrono dalle cache alla creazione della cella (vedi `TMDBLookupCache` e
/// `ImageLoader`), quindi una cella ricreata dalla griglia durante lo scroll
/// mostra subito il poster definitivo invece di passare dall'icona del
/// provider al poster TMDB ad ogni ricomparsa.
struct TMDBEnrichedPoster: View {
    /// Posizione/aspetto del voto. `.classic` è quello storico delle griglie
    /// (basso a destra, giallo); `.topTrailing` è quello delle righe di
    /// locandine nelle schede dettaglio (alto a destra, bianco su vetro
    /// scuro, come nel riferimento).
    enum BadgeStyle {
        case classic
        case topTrailing
    }

    let title: String
    let isSeries: Bool
    let fallbackIconURL: String?
    let width: CGFloat
    let height: CGFloat
    var badgeStyle: BadgeStyle = .classic

    @State private var result: TMDBSearchResult?
    /// `true` quando il poster TMDB è già a schermo: da quel momento il
    /// livello con l'immagine del provider non serve più e viene tolto.
    @State private var posterShown = false
    /// `true` quando la ricerca TMDB ha dato un esito (trovato/non trovato)
    /// oppure non serve farla: solo da qui, senza immagine del provider, si
    /// mostra il segnaposto con iniziali (prima c'è un riquadro neutro, così
    /// non c'è uno scambio segnaposto → poster).
    @State private var lookupSettled = true

    init(
        title: String,
        isSeries: Bool,
        fallbackIconURL: String?,
        width: CGFloat,
        height: CGFloat,
        badgeStyle: BadgeStyle = .classic
    ) {
        self.title = title
        self.isSeries = isSeries
        self.fallbackIconURL = fallbackIconURL
        self.width = width
        self.height = height
        self.badgeStyle = badgeStyle

        // Stato iniziale già definitivo se il titolo è stato risolto in precedenza.
        if TMDBService.hasAPIKey {
            let cached = TMDBService.cachedResult(title: title, isSeries: isSeries)
            _result = State(initialValue: cached)
            _posterShown = State(initialValue: Self.isPosterBitmapCached(cached, width: width, height: height))
            _lookupSettled = State(
                initialValue: cached != nil || TMDBService.isKnownMiss(title: title, isSeries: isSeries)
            )
        }
    }

    private var service: TMDBService { TMDBService.shared }

    private static func isPosterBitmapCached(_ result: TMDBSearchResult?, width: CGFloat, height: CGFloat) -> Bool {
        guard let url = result?.posterURL else { return false }
        let scale = UITraitCollection.current.displayScale > 0 ? UITraitCollection.current.displayScale : 3
        let bucket = ImageLoader.pixelBucket(points: max(width, height), scale: scale)
        return ImageLoader.shared.cachedImage(for: url, maxPixel: bucket) != nil
    }

    var body: some View {
        ZStack(alignment: badgeStyle == .classic ? .bottomTrailing : .topTrailing) {
            posterImage
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if let rating = result?.voteAverage, rating > 0 {
                ratingBadge(rating)
            }
        }
        .task(id: title) { await resolve() }
    }

    /// Risolve il titolo su TMDB. Gli errori di rete NON vengono scambiati
    /// per "nessun risultato": si riprova con pause crescenti finché la
    /// cella resta visibile (prima restava senza poster fino al prossimo
    /// riciclo della cella).
    private func resolve() async {
        guard TMDBService.hasAPIKey else {
            lookupSettled = true
            return
        }

        // Già risolto (cache): niente rete e nessun cambio visibile.
        if let cached = TMDBService.cachedResult(title: title, isSeries: isSeries) {
            if result?.id != cached.id {
                result = cached
                posterShown = Self.isPosterBitmapCached(cached, width: width, height: height)
            }
            lookupSettled = true
            return
        }
        if TMDBService.isKnownMiss(title: title, isSeries: isSeries) {
            lookupSettled = true
            return
        }

        lookupSettled = false

        // Breve attesa: se la cella esce subito dallo schermo (scroll
        // veloce) il task viene cancellato e la richiesta non parte.
        try? await Task.sleep(nanoseconds: 150_000_000)
        if Task.isCancelled { return }

        for attempt in 0..<3 {
            do {
                let found = try await service.lookup(title: title, isSeries: isSeries)
                if Task.isCancelled { return }
                posterShown = Self.isPosterBitmapCached(found, width: width, height: height)
                result = found
                lookupSettled = true
                return
            } catch TMDBError.noResults {
                lookupSettled = true
                return
            } catch {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_500_000_000)
                if Task.isCancelled { return }
            }
        }

        // Rete irraggiungibile: si mostra comunque il segnaposto.
        lookupSettled = true
    }

    @ViewBuilder
    private func ratingBadge(_ rating: Double) -> some View {
        switch badgeStyle {
        case .classic:
            Text(String(format: "%.1f", rating))
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.yellow)
                .padding(3)

        case .topTrailing:
            Text(String(format: "%.1f", rating))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(5)
        }
    }

    private var frameSize: CGSize { CGSize(width: width, height: height) }

    /// Due livelli con la STESSA geometria (`.fill`), mai uno scambio di
    /// viste: sotto l'immagine del provider (o il segnaposto con iniziali),
    /// sopra il poster TMDB che compare solo quando è davvero pronto. Così
    /// non c'è mai una cella vuota né il salto "icona piccola → poster".
    @ViewBuilder
    private var posterImage: some View {
        ZStack {
            if !posterShown {
                providerLayer
            }

            if let posterURL = result?.posterURL {
                CachedAsyncImage(
                    url: posterURL,
                    size: frameSize,
                    contentMode: .fill,
                    onLoaded: { posterShown = true }
                )
            }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private var providerLayer: some View {
        CachedAsyncImage(
            url: ImageURLNormalizer.url(from: fallbackIconURL),
            size: frameSize,
            contentMode: .fill,
            fallback: lookupSettled ? AnyView(placeholderArtwork) : AnyView(neutralArtwork)
        ) {
            neutralArtwork
        }
    }

    private var neutralArtwork: some View {
        Rectangle().fill(Color.white.opacity(0.06))
    }

    private var placeholderArtwork: some View {
        ArtworkPlaceholder(
            title: title,
            systemImage: isSeries ? "rectangle.stack.fill" : "film",
            cornerRadius: 12
        )
    }
}
