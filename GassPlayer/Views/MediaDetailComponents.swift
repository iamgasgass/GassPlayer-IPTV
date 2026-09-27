import SwiftUI

/// Altezza dell'hero (backdrop + logo/titolo), condivisa da film e serie:
/// stessa proporzione mostrata nel video dimostrativo (~45% di uno schermo
/// iPhone in verticale).
enum MediaDetailMetrics {
    static let heroHeight: CGFloat = 380
    static let heroFadeHeight: CGFloat = 140
}

/// Hero della scheda dettaglio: immagine di sfondo (backdrop TMDB se
/// disponibile, altrimenti la locandina/icona già fornita da Xtream),
/// sfumatura verso lo sfondo dell'app, logo del titolo (o testo in
/// grassetto se TMDB non ha un logo) e pulsante di chiusura in alto a
/// destra — esattamente il layout dei due video allegati.
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
                .padding(.bottom, 14)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: MediaDetailMetrics.heroHeight)
        .clipped()
        .overlay(alignment: .topTrailing) {
            closeButton
                .padding(.trailing, 16)
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var backdropImage: some View {
        let urlToLoad = backdropURL ?? fallbackImageURLString.flatMap(URL.init(string:))

        if let urlToLoad {
            AsyncImage(url: urlToLoad) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
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
                    image.resizable()
                        .scaledToFit()
                        .frame(maxHeight: 84)
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
            .font(.system(size: 30, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
            .lineLimit(2)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(.black.opacity(0.45), in: Circle())
        }
        .accessibilityLabel("Chiudi")
    }
}

/// Riga "★7   2 h 4 min   Crime, Dramma" (film) / "★7   2006   Commedia"
/// (serie), centrata sotto l'hero.
struct MediaMetaRow: View {
    let ratingText: String?
    let secondaryText: String?
    let genres: [String]

    var body: some View {
        HStack(spacing: 8) {
            if let ratingText {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                    Text(ratingText)
                        .font(.subheadline.weight(.bold))
                }
                .foregroundStyle(.yellow)
            }

            if let secondaryText {
                dot
                Text(secondaryText)
                    .font(.subheadline.weight(.medium))
            }

            if !genres.isEmpty {
                dot
                Text(genres.prefix(2).joined(separator: ", "))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }

    private var dot: some View {
        Circle()
            .fill(Color.secondary)
            .frame(width: 3, height: 3)
    }
}

/// Pulsante pieno "▶ Riproduci il film" / "▶ Riproduci Stagione X: Episodio Y".
struct MediaPlayButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
    }
}

/// Una delle icone circolari sotto il pulsante di riproduzione (preferiti,
/// muto anteprima, download): stesso stile visivo del video, con un
/// indicatore di progresso opzionale (usato dal download reale).
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
                    .fill(Color.primary.opacity(0.1))

                if let progress, progress < 1 {
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(3)
                }

                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
        .frame(width: 44, height: 44)
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

/// Pillola "Altre fonti".
struct AltreFontiButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Altre fonti")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.1), in: Capsule())
        .overlay {
            Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        }
    }
}

/// Sezione "VALUTAZIONI": una pillola per ogni fonte realmente disponibile
/// (nessuna chiave API configurata → quella fonte semplicemente non
/// compare, nessun placeholder rotto).
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
            VStack(alignment: .leading, spacing: 12) {
                Text("VALUTAZIONI")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 22) {
                    ForEach(badges) { badge in
                        VStack(spacing: 4) {
                            Text(badge.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(badge.tint)
                            Text(badge.value)
                                .font(.subheadline.weight(.bold))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// Sezione "CAST": scorrimento orizzontale di attori, con foto quando
/// disponibile (TMDB) o iniziale del nome altrimenti (solo dato Xtream).
struct MediaCastSection: View {
    let cast: [MediaCastMember]

    var body: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("CAST")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(cast) { member in
                            VStack(spacing: 6) {
                                castPhoto(member)
                                    .frame(width: 60, height: 60)
                                    .clipShape(Circle())

                                Text(member.name)
                                    .font(.caption.weight(.semibold))
                                    .lineLimit(1)
                                    .frame(width: 78)

                                if let role = member.role, !role.isEmpty {
                                    Text(role)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .frame(width: 78)
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

/// Formattazione condivisa (voto TMDB → "★7", "★7.5"...).
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
