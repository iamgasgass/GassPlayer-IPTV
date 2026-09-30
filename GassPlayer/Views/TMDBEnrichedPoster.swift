import SwiftUI

/// Badge poster/rating TMDB, usato per arricchire le card VOD con dati reali
/// (Xtream spesso fornisce solo un'icona generica, non un poster proprio).
/// Fallback silenzioso: se manca l'API key o TMDB non trova corrispondenze,
/// non mostra nulla di rotto, semplicemente l'icona placeholder originale.
struct TMDBEnrichedPoster: View {
    let title: String
    let isSeries: Bool
    let fallbackIconURL: String?
    let width: CGFloat
    let height: CGFloat

    @State private var result: TMDBSearchResult?
    @State private var didAttemptLookup = false

    private var service: TMDBService { TMDBService.shared }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            posterImage
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            if let rating = result?.voteAverage, rating > 0 {
                Text(String(format: "%.1f", rating))
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.7), in: Capsule())
                    .foregroundStyle(.yellow)
                    .padding(3)
            }
        }
        .task {
            guard !didAttemptLookup, TMDBService.hasAPIKey else { return }
            didAttemptLookup = true
            result = try? await service.lookup(title: title, isSeries: isSeries)
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
