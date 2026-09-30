import SwiftUI

/// Badge poster/rating TMDB, usato per arricchire le card VOD con dati reali
/// (Xtream spesso fornisce solo un'icona generica, non un poster proprio).
/// Fallback silenzioso: se manca l'API key o TMDB non trova corrispondenze,
/// non mostra nulla di rotto, semplicemente l'icona placeholder originale.
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
        .task {
            guard !didAttemptLookup, TMDBService.hasAPIKey else { return }
            didAttemptLookup = true
            result = try? await service.lookup(title: title, isSeries: isSeries)
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

    @ViewBuilder
    private var posterImage: some View {
        if let posterURL = result?.posterURL {
            AsyncImage(url: posterURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    placeholderImage
                }
            }
        } else {
            placeholderImage
        }
    }

    @ViewBuilder
    private var placeholderImage: some View {
        AsyncImage(url: URL(string: fallbackIconURL ?? "")) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFit()
            default:
                RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    .overlay(Image(systemName: isSeries ? "rectangle.stack.fill" : "film").foregroundStyle(.secondary))
            }
        }
    }
}
