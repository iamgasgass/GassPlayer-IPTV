import SwiftUI

// MARK: - Dimensioni e Metriche UI
enum MediaDetailMetrics {
    static let heroHeight: CGFloat = 320
    static let heroFadeHeight: CGFloat = 130
}

// MARK: - Hero Header con Backdrop, Logo/Titolo e Tasto Chiudi
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
                colors: [
                    Color.clear,
                    Color(uiColor: .systemBackground).opacity(0.4),
                    Color(uiColor: .systemBackground)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: MediaDetailMetrics.heroFadeHeight)

            titleBlock
                .padding(.bottom, 10)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: MediaDetailMetrics.heroHeight)
        .clipped()
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.trailing, 16)
                .padding(.top, 50)
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
                        .frame(maxHeight: 74)
                        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
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
            .shadow(color: .black.opacity(0.7), radius: 6, y: 2)
            .lineLimit(2)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.5), in: Circle())
        }
        .accessibilityLabel("Chiudi")
    }
}

// MARK: - Riga Metadati (Voto, Durata/Anno, Generi)
struct MediaMetaRow: View {
    let ratingText: String?
    let secondaryText: String?
    let genres: [String]

    var body: some View {
        HStack(spacing: 8) {
            if let ratingText {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(ratingText)
                        .font(.subheadline.weight(.heavy))
                }
                .foregroundStyle(.yellow)
            }

            if let secondaryText {
                if ratingText != nil { dot }
                Text(secondaryText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if !genres.isEmpty {
                dot
                Text(genres.prefix(2).joined(separator: ", "))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .multilineTextAlignment(.center)
    }

    private var dot: some View {
        Circle()
            .fill(Color.secondary.opacity(0.5))
            .frame(width: 3, height: 3)
    }
}

// MARK: - Pulsante Riproduci Principale
struct MediaPlayButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.subheadline.weight(.bold))
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icon Button Rotondo
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
                    .fill(Color(uiColor: .secondarySystemBackground))

                if let progress, progress < 1 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                }

                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 44, height: 44)
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Tasto Altre Fonti Capsule
struct AltreFontiButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Altre fonti")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sezione Valutazioni
struct MediaRatingsSection: View {
    let ratings: MediaRatings

    private struct Badge: Identifiable {
        let id: String
        let label: String
        let value: String
        let icon: String
        let tint: Color
    }

    private var badges: [Badge] {
        var items: [Badge] = []

        if let percent = ratings.tmdbPercent, percent > 0 {
            items.append(Badge(id: "tmdb", label: "TMDB", value: "\(percent)%", icon: "film", tint: .teal))
        }
        if let percent = ratings.rottenTomatoesPercent {
            items.append(Badge(id: "rt", label: "Critiche", value: "\(percent)%", icon: "circle.circle", tint: .red))
        }
        if let trakt = ratings.traktPercent {
            items.append(Badge(id: "trakt", label: "Trakt", value: "\(trakt)%", icon: "checkmark.square", tint: .red))
        }
        if let score = ratings.imdbScore {
            items.append(Badge(id: "imdb", label: "IMDb", value: String(format: "%.1f", score), icon: "square.fill", tint: .yellow))
        }
        if let score = ratings.metacriticScore {
            items.append(Badge(id: "mc", label: "Metacritic", value: "\(score)", icon: "circlebadge.fill", tint: .green))
        }

        return items
    }

    var body: some View {
        if !badges.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("VALUTAZIONI")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(badges) { badge in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(badge.tint)
                                        .frame(width: 7, height: 7)
                                    Text(badge.label)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                Text(badge.value)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sezione Cast
struct MediaCastSection: View {
    let cast: [MediaCastMember]

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("CAST")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(cast) { member in
                            HStack(spacing: 10) {
                                castPhoto(member)
                                    .frame(width: 48, height: 48)
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.name)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let role = member.role, !role.isEmpty {
                                        Text(role)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func castPhoto(_ member: MediaCastMember) -> some View {
        if let photoURL = member.photoURL {
            AsyncImage(url: photoURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
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
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.secondary)
            }
    }
}

// MARK: - Formattazione Voti
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
