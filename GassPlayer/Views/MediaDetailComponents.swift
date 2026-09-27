import SwiftUI

// MARK: - Metriche Hero e Layout
enum MediaDetailMetrics {
    static let heroHeight: CGFloat = 380
    static let heroFadeHeight: CGFloat = 140
}

// MARK: - Hero Header con Backdrop, Logo e Tasto Chiusura circolare
struct MediaHeroHeader: View {
    let title: String
    let logoURL: URL?
    let backdropURL: URL?
    let fallbackImageURLString: String?
    let onClose: () -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                // Backdrop full-bleed vincolato alla larghezza dello schermo
                backdropImage
                    .frame(width: geo.size.width, height: MediaDetailMetrics.heroHeight)
                    .clipped()

                // Gradiente lineare inferiore
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.black.opacity(0.35),
                        Color(uiColor: .systemBackground).opacity(0.85),
                        Color(uiColor: .systemBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(width: geo.size.width, height: MediaDetailMetrics.heroFadeHeight)

                // Logo TMDB o Titolo Fallback
                titleBlock
                    .padding(.bottom, 12)
                    .padding(.horizontal, 24)
                    .frame(width: geo.size.width, alignment: .center)
            }
            .frame(width: geo.size.width, height: MediaDetailMetrics.heroHeight)
            .clipped()
            .overlay(alignment: .topTrailing) {
                closeButton
                    .padding(.trailing, 16)
                    .padding(.top, 50)
            }
        }
        .frame(height: MediaDetailMetrics.heroHeight)
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
                    colors: [Color.black.opacity(0.85), Color.black.opacity(0.6)],
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
                        .frame(maxHeight: 84)
                        .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
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
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.7), radius: 6, y: 2)
            .lineLimit(2)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chiudi")
    }
}

// MARK: - Riga Metadati (Badge Stella + Anno/Durata + Generi)
struct MediaMetaRow: View {
    let ratingText: String?
    let secondaryText: String?
    let genres: [String]

    var body: some View {
        HStack(spacing: 12) {
            if let ratingText {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                    Text(ratingText)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if let secondaryText, !secondaryText.isEmpty {
                Text(secondaryText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if !genres.isEmpty {
                Text(genres.prefix(2).joined(separator: ", "))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
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
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tasto Circolare Icona (Preferiti, Muto, Download)
struct MediaIconButton: View {
    let systemImage: String
    var tint: Color = .white
    var progress: Double? = nil
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))

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

// MARK: - Pillola "Altre fonti"
struct AltreFontiButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Altre fonti")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.12), in: Capsule())
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
        let iconName: String
        let iconColor: Color
    }

    private var badges: [Badge] {
        var items: [Badge] = []

        if let percent = ratings.tmdbPercent, percent > 0 {
            items.append(Badge(id: "tmdb", label: "TMDB", value: "\(percent)%", iconName: "circle.fill", iconColor: Color.green.opacity(0.85)))
        }

        if let percent = ratings.rottenTomatoesPercent {
            items.append(Badge(id: "rt", label: "Critiche", value: "\(percent)%", iconName: "circle.fill", iconColor: Color.red))
        }

        if let percent = ratings.traktPercent {
            items.append(Badge(id: "trakt", label: "Trakt", value: "\(percent)%", iconName: "checkmark.square.fill", iconColor: Color.pink))
        }

        if let score = ratings.imdbScore {
            items.append(Badge(id: "imdb", label: "IMDb", value: String(format: "%.1f", score), iconName: "square.fill", iconColor: Color.yellow))
        }

        if let score = ratings.metacriticScore {
            items.append(Badge(id: "mc", label: "Metacritic", value: "\(score)", iconName: "m.square.fill", iconColor: Color.orange))
        }

        return items
    }

    var body: some View {
        if !badges.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("VALUTAZIONI")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 24) {
                        ForEach(badges) { badge in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 5) {
                                    Image(systemName: badge.iconName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(badge.iconColor)
                                    Text(badge.label)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                Text(badge.value)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 2)
                }
            }
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 18) {
                        ForEach(cast) { member in
                            HStack(spacing: 12) {
                                castPhoto(member)
                                    .frame(width: 50, height: 50)
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(member.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let role = member.role, !role.isEmpty {
                                        Text(role)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 95, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
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
            .fill(Color.secondary.opacity(0.25))
            .overlay {
                Text(member.name.prefix(1))
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
    }
}

// MARK: - Formattazione Voti
enum MediaRatingFormatter {
    static func starText(fromPercent percent: Int?) -> String? {
        guard let percent, percent > 0 else { return nil }
        let value = Double(percent) / 10
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
