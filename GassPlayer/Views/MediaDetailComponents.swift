import SwiftUI

/// Dimensioni e metriche precise identiche al video di riferimento
enum MediaDetailMetrics {
    static let heroHeight: CGFloat = 280
    static let heroFadeHeight: CGFloat = 110
}

/// Hero header compatto: backdrop proporzionato, sfumatura verso il nero, logo centrato e pulsante X
struct MediaHeroHeader: View {
    let title: String
    let logoURL: URL?
    let backdropURL: URL?
    let fallbackImageURLString: String?
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // Immagine Backdrop
            backdropImage
                .frame(maxWidth: .infinity)
                .frame(height: MediaDetailMetrics.heroHeight)
                .clipped()

            // Sfumatura verso lo sfondo nero
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: Color.black.opacity(0.6), location: 0.6),
                    .init(color: Color.black, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: MediaDetailMetrics.heroFadeHeight)

            // Titolo o Logo
            titleBlock
                .padding(.bottom, 10)
                .padding(.horizontal, 24)
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
                    colors: [Color(white: 0.15), Color.black],
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
                        .frame(maxHeight: 60)
                        .shadow(color: .black.opacity(0.8), radius: 8, y: 2)
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
            .font(.system(size: 22, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.9), radius: 6, y: 2)
            .lineLimit(2)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chiudi")
    }
}

/// Riga metadata compatta con pillola badge stella + anno/durata + generi
struct MediaMetaRow: View {
    let ratingText: String?
    let secondaryText: String?
    let genres: [String]

    var body: some View {
        HStack(spacing: 8) {
            if let ratingText {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                    Text(ratingText)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }

            if let secondaryText, !secondaryText.isEmpty {
                Text(secondaryText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !genres.isEmpty {
                Text(genres.prefix(2).joined(separator: ", "))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Pulsante Play a larghezza piena con altezza nativa
struct MediaPlayButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Tasto circolare proporzionato da 38x38 pt
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
                        .padding(2)
                }

                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 38, height: 38)
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Pillola "Altre fonti" che si espande orizzontalmente senza forzare overflow
struct AltreFontiButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Altre fonti")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color.white.opacity(0.12), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }
}

/// Sezione "VALUTAZIONI" con loghi colorati e scorrimento fluido
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
            VStack(alignment: .leading, spacing: 8) {
                Text("VALUTAZIONI")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(badges) { badge in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 4) {
                                    Image(systemName: badge.iconName)
                                        .font(.system(size: 9))
                                        .foregroundStyle(badge.iconColor)
                                    Text(badge.label)
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.secondary)
                                }
                                Text(badge.value)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

/// Sezione "CAST" a scorrimento orizzontale
struct MediaCastSection: View {
    let cast: [MediaCastMember]

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("CAST")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .center, spacing: 14) {
                        ForEach(cast) { member in
                            HStack(spacing: 10) {
                                castPhoto(member)
                                    .frame(width: 44, height: 44)
                                    .clipShape(Circle())

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(member.name)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)

                                    if let role = member.role, !role.isEmpty {
                                        Text(role)
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 85, alignment: .leading)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
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
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
            }
    }
}

/// Formattazione del rating a stella
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
