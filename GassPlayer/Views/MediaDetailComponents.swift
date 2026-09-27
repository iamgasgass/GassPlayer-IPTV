import SwiftUI

/// Metriche visive condivise conformi al design nativo compatto di iOS
enum MediaDetailMetrics {
    static let heroHeight: CGFloat = 340
    static let heroFadeHeight: CGFloat = 130
}

/// Hero della scheda dettaglio: backdrop con sfumatura, logo/titolo, e pulsante chiusura
struct MediaHeroHeader: View {
    let title: String
    let logoURL: URL?
    let backdropURL: URL?
    let fallbackImageURLString: String?
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            backdropImage
                .frame(maxWidth: .infinity)
                .frame(height: MediaDetailMetrics.heroHeight)
                .clipped()

            LinearGradient(
                colors: [.clear, Color(uiColor: .systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: MediaDetailMetrics.heroFadeHeight)

            titleBlock
                .padding(.bottom, 12)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: MediaDetailMetrics.heroHeight)
        .clipped()
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.trailing, 16)
                .padding(.top, 48)
        }
    }

    @ViewBuilder
    private var backdropImage: some View {
        let urlToLoad = backdropURL ?? fallbackImageURLString.flatMap(URL.init(string:))

        if let urlToLoad {
            AsyncImage(url: urlToLoad) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Color.black.opacity(0.85), Color.black.opacity(0.55)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }

    @ViewBuilder
    private var titleBlock: some View {
        if let logoURL {
            AsyncImage(url: logoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 70)
                        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                default:
                    fallbackTitleText
                }
            }
        } else {
            fallbackTitleText
        }
    }

    private var fallbackTitleText: some View {
        Text(title)
            .font(.system(size: 26, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chiudi")
    }
}

/// Riga info compattata: ★ Voto · Anno/Durata · Generi
struct MediaMetaRow: View {
    let ratingText: String?
    let secondaryText: String?
    let genres: [String]

    var body: some View {
        HStack(spacing: 6) {
            if let ratingText {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11))
                    Text(ratingText)
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.yellow)
            }

            if let secondaryText {
                if ratingText != nil { dot }
                Text(secondaryText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            if !genres.isEmpty {
                if ratingText != nil || secondaryText != nil { dot }
                Text(genres.prefix(2).joined(separator: ", "))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var dot: some View {
        Circle()
            .fill(Color.secondary.opacity(0.7))
            .frame(width: 3, height: 3)
    }
}

/// Pulsante di riproduzione principale a tutta larghezza
struct MediaPlayButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.semibold))
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Pulsante icona circolare per la barra azioni
struct MediaIconButton: View {
    let systemImage: String
    var tint: Color = .primary
    var progress: Double? = nil
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color(uiColor: .secondarySystemFill))

                if let progress, progress < 1 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(2)
                }

                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Pulsante a pillola "Altre fonti" espandibile
struct AltreFontiButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Altre fonti")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(uiColor: .secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Sezione "VALUTAZIONI"
struct MediaRatingsSection: View {
    let ratings: MediaRatings

    private struct Badge: Identifiable {
        let id: String
        let label: String
        let value: String
        let tint: Color
    }

    private var badges: [Badge] {
        var items: [Badge] = []
        if let percent = ratings.tmdbPercent, percent > 0 {
            items.append(Badge(id: "tmdb", label: "TMDB", value: "\(percent)%", tint: .blue))
        }
        if let percent = ratings.rottenTomatoesPercent {
            items.append(Badge(id: "rt", label: "Critica", value: "\(percent)%", tint: .red))
        }
        if let percent = ratings.traktPercent {
            items.append(Badge(id: "trakt", label: "Trakt", value: "\(percent)%", tint: .purple))
        }
        if let score = ratings.imdbScore {
            items.append(Badge(id: "imdb", label: "IMDb", value: String(format: "%.1f", score), tint: .yellow))
        }
        if let score = ratings.metacriticScore {
            items.append(Badge(id: "mc", label: "Metacritic", value: "\(score)", tint: .green))
        }
        return items
    }

    var body: some View {
        if !badges.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("VALUTAZIONI")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 20) {
                    ForEach(badges) { badge in
                        VStack(spacing: 3) {
                            Text(badge.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(badge.tint)
                            Text(badge.value)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }
}

/// Sezione "CAST"
struct MediaCastSection: View {
    let cast: [MediaCastMember]

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("CAST")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(cast) { member in
                            VStack(spacing: 6) {
                                castPhoto(member)
                                    .frame(width: 54, height: 54)
                                    .clipShape(Circle())

                                Text(member.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 72)

                                if let role = member.role, !role.isEmpty {
                                    Text(role)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 72)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func castPhoto(_ member: MediaCastMember) -> some View {
        if let photoURL = member.photoURL {
            AsyncImage(url: photoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    castInitial(member)
                }
            }
        } else {
            castInitial(member)
        }
    }

    private func castInitial(_ member: MediaCastMember) -> some View {
        Circle()
            .fill(Color.secondary.opacity(0.2))
            .overlay {
                Text(member.name.prefix(1))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
            }
    }
}

enum MediaRatingFormatter {
    static func starText(fromPercent percent: Int?) -> String? {
        guard let percent, percent > 0 else { return nil }
        let value = Double(percent) / 10.0
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
