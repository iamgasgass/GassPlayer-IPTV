import SwiftUI

// MARK: - Continua a guardare (identico a HomeView)

/// Sezione "Continua a guardare" condivisa da `HomeView` (tutti i tipi) e
/// da `ChannelGridView` (solo il tipo della propria sezione: film in VOD,
/// serie in Serie TV). Card, misure e comportamento sono quelli storici di
/// `HomeView`; ora la card mostra l'immagine della scheda dettaglio
/// (`MovieDetailView`/`SeriesEpisodesView`) invece della sola icona
/// (l'icona resta come segnaposto mentre carica o se l'immagine manca).
struct ContinueWatchingSection: View {
    /// `nil` = tutti i tipi; altrimenti solo `RecentlyWatchedItem.kind == kindFilter`.
    var kindFilter: String? = nil
    /// Margine laterale di header e riga (0 in `HomeView`, che ha già il
    /// proprio padding di contenitore).
    var horizontalInset: CGFloat = 0
    var topPadding: CGFloat = 0
    var bottomPadding: CGFloat = 0

    @EnvironmentObject private var recentlyWatched: RecentlyWatchedStore
    @State private var resumeItem: RecentlyWatchedItem?

    private static let cardWidth: CGFloat = 168
    private static let cardImageHeight: CGFloat = 94

    private var items: [RecentlyWatchedItem] {
        guard let kindFilter else { return recentlyWatched.items }
        return recentlyWatched.items.filter { $0.kind == kindFilter }
    }

    var body: some View {
        let visibleItems = items

        VStack(alignment: .leading, spacing: 12) {
            if !visibleItems.isEmpty {
                HStack {
                    Text("Continua a guardare")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button("Svuota") {
                        withAnimation(.snappy) {
                            if let kindFilter {
                                recentlyWatched.clear(kind: kindFilter)
                            } else {
                                recentlyWatched.clear()
                            }
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, horizontalInset)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(visibleItems) { item in
                            card(item)
                        }
                    }
                    .padding(.horizontal, horizontalInset)
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.top, visibleItems.isEmpty ? 0 : topPadding)
        .padding(.bottom, visibleItems.isEmpty ? 0 : bottomPadding)
        .fullScreenCover(item: $resumeItem) { item in
            AdaptivePlayerView(url: item.streamURL, title: item.title)
        }
    }

    private func card(_ item: RecentlyWatchedItem) -> some View {
        Button {
            resumeItem = item
        } label: {
            GlassCard(cornerRadius: 16, padding: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        artwork(item)

                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, tint(item))
                            .padding(8)
                    }

                    Text(item.title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(width: Self.cardWidth, alignment: .leading)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                withAnimation(.snappy) { recentlyWatched.remove(item) }
            } label: {
                Label("Rimuovi", systemImage: "trash")
            }
        }
        .accessibilityLabel(item.title)
        .accessibilityHint("Riprendi la riproduzione")
    }

    /// Immagine della scheda dettaglio, ritagliata 168×94 (angoli 11) come
    /// il vecchio riquadro a icona, che resta come segnaposto.
    private func artwork(_ item: RecentlyWatchedItem) -> some View {
        ZStack {
            placeholder(item)

            if let urlString = item.imageURLString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image
                            .resizable()
                            .scaledToFill()
                            .transaction { $0.animation = nil }
                    }
                }
            }
        }
        .frame(width: Self.cardWidth, height: Self.cardImageHeight)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func placeholder(_ item: RecentlyWatchedItem) -> some View {
        ZStack {
            Rectangle().fill(tint(item).opacity(0.16))

            Image(systemName: systemImage(item))
                .font(.title2.weight(.semibold))
                .foregroundStyle(tint(item))
        }
    }

    private func systemImage(_ item: RecentlyWatchedItem) -> String {
        switch item.kind {
        case XtreamStreamKind.live.rawValue: return "tv.fill"
        case XtreamStreamKind.movie.rawValue: return "film.fill"
        case XtreamStreamKind.series.rawValue: return "rectangle.stack.fill"
        default: return "play.rectangle.fill"
        }
    }

    private func tint(_ item: RecentlyWatchedItem) -> Color {
        switch item.kind {
        case XtreamStreamKind.live.rawValue: return .red
        case XtreamStreamKind.movie.rawValue: return .purple
        case XtreamStreamKind.series.rawValue: return .blue
        default: return .accentColor
        }
    }
}
