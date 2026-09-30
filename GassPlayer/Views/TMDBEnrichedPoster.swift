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
    @State private var didAttemptLookup = false

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
            _result = State(initialValue: TMDBService.cachedResult(title: title, isSeries: isSeries))
        }
    }

    private var service: TMDBService { TMDBService.shared }

    var body: some View {
        ZStack(alignment: badgeStyle == .classic ? .bottomTrailing : .topTrailing) {
            posterImage
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if let rating = result?.voteAverage, rating > 0 {
                ratingBadge(rating)
            }
        }
        .task(id: title) {
            guard TMDBService.hasAPIKey else { return }

            // Già risolto (cache): niente rete e niente cambio di stato.
            if let cached = TMDBService.cachedResult(title: title, isSeries: isSeries) {
                if result?.id != cached.id { result = cached }
                return
            }
            if TMDBService.isKnownMiss(title: title, isSeries: isSeries) { return }

            // Breve attesa: se la cella esce subito dallo schermo (scroll
            // veloce) il task viene cancellato e la richiesta non parte.
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }

            didAttemptLookup = true
            if let found = try? await service.lookup(title: title, isSeries: isSeries), !Task.isCancelled {
                result = found
            }
        }
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

    /// Poster TMDB se disponibile; finché non è pronto (o se manca) resta
    /// l'immagine del provider, così non compare mai una cella vuota.
    @ViewBuilder
    private var posterImage: some View {
        if let posterURL = result?.posterURL {
            CachedAsyncImage(url: posterURL, size: frameSize, contentMode: .fill) {
                placeholderImage
            }
        } else {
            placeholderImage
        }
    }

    @ViewBuilder
    private var placeholderImage: some View {
        CachedAsyncImage(
            url: ImageURLNormalizer.url(from: fallbackIconURL),
            size: frameSize,
            contentMode: .fit
        ) {
            RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                .overlay(Image(systemName: isSeries ? "rectangle.stack.fill" : "film").foregroundStyle(.secondary))
        }
    }
}
