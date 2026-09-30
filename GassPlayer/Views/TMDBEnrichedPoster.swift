import SwiftUI

/// Poster arricchito da TMDB con fallback Xtream.
///
/// La card non usa piu' `AsyncImage`: il caricamento passa dalla pipeline
/// condivisa, che deduplica le richieste, conserva le immagini in RAM/disk
/// cache e downscala prima del rendering. Il fallback Xtream resta visibile
/// mentre TMDB viene cercato/scaricato, quindi lo scroll non mostra celle vuote
/// o lampeggiamenti.
struct TMDBEnrichedPoster: View {
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

    @AppStorage(TMDBService.apiKeyDefaultsKey)
    private var tmdbAPIKey = ""

    @State private var result: TMDBSearchResult?

    private var service: TMDBService { TMDBService.shared }

    private var fallbackURL: URL? {
        guard let fallbackIconURL, !fallbackIconURL.isEmpty else { return nil }
        return URL(string: fallbackIconURL)
    }

    var body: some View {
        ZStack(alignment: badgeStyle == .classic ? .bottomTrailing : .topTrailing) {
            CachedRemoteImage(
                primaryURL: result?.posterURL,
                fallbackURL: fallbackURL,
                width: width,
                height: height,
                primaryContentMode: .fill,
                fallbackContentMode: .fit
            ) {
                placeholderImage
            }

            if let rating = result?.voteAverage, rating > 0 {
                ratingBadge(rating)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: "\(title)|\(isSeries)|\(tmdbAPIKey)") {
            guard !tmdbAPIKey.isEmpty else {
                result = nil
                return
            }

            result = try? await service.lookup(
                title: title,
                isSeries: isSeries
            )
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private func ratingBadge(_ rating: Double) -> some View {
        switch badgeStyle {
        case .classic:
            Text(String(format: "%.1f", rating))
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.black.opacity(0.7), in: Capsule())
                .foregroundStyle(.yellow)
                .padding(3)

        case .topTrailing:
            Text(String(format: "%.1f", rating))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    .black.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .padding(5)
        }
    }

    @ViewBuilder
    private var placeholderImage: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                Image(systemName: isSeries ? "rectangle.stack.fill" : "film")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
    }
}
