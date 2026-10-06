import SwiftUI
import KSPlayer

/// Contesto "canale live" per il blocco informativo del player: logo,
/// nome del canale e programma in onda. Il programma viene chiesto a
/// `programProvider` (EPG Xtream o XMLTV delle playlist M3U) dal player
/// stesso, così i chiamanti non devono pre-caricare nulla.
struct PlayerLiveInfo {
    /// Identità del canale: quando cambia (zapping) il programma viene
    /// ricaricato.
    let id: String
    let channelName: String
    let logoURLString: String?
    /// Host/URL base per risolvere loghi con percorso relativo.
    let baseHost: String
    var programProvider: (() async -> EPGProgram?)?

    /// Canale Xtream: il programma arriva dalla breve EPG del provider.
    static func xtream(stream: XtreamStream, credentials: XtreamCredentials) -> PlayerLiveInfo {
        PlayerLiveInfo(
            id: "x\(stream.streamId)",
            channelName: stream.name,
            logoURLString: stream.streamIcon,
            baseHost: credentials.host,
            programProvider: {
                let programs = try? await EPGService(credentials: credentials)
                    .shortEPG(streamId: stream.streamId, limit: 8)
                let now = Date()
                return programs?.first { $0.isCurrent(at: now) } ?? programs?.first { $0.isUpcoming(at: now) }
            }
        )
    }

    /// Canale M3U: il programma arriva dall'XMLTV già caricato dallo store.
    @MainActor
    static func m3u(channel: M3UChannel, store: M3UPlaylistStore, baseHost: String) -> PlayerLiveInfo {
        PlayerLiveInfo(
            id: "m\(channel.id)",
            channelName: channel.title,
            logoURLString: channel.logoURL,
            baseHost: baseHost,
            programProvider: { @MainActor in
                store.currentProgram(for: channel)
            }
        )
    }
}

/// Valori dei badge sotto il titolo (playlist, motore, risoluzione, FPS,
/// audio), letti dal motore di riproduzione mentre i controlli sono visibili.
struct PlayerStreamBadges: Equatable {
    var engine: String = "KS"
    var width: Int = 0
    var height: Int = 0
    var fps: Int = 0
    var audio: String?

    /// VOD/Serie: dimensione esatta ("960X540"); Live: classe di qualità
    /// ("FHD"), come nei riferimenti.
    func resolutionLabel(isLive: Bool) -> String? {
        guard width > 0, height > 0 else { return nil }

        guard isLive else { return "\(width)X\(height)" }

        switch height {
        case 2000...: return "UHD"
        case 1000...: return "FHD"
        case 700...: return "HD"
        default: return "SD"
        }
    }

    static func audioLabel(channels: Int) -> String? {
        switch channels {
        case ...0: return nil
        case 1: return "MONO"
        case 2: return "STEREO"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)CH"
        }
    }
}

/// Chip dei badge (testo scuro su fondo grigio traslucido).
struct PlayerBadgeChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.62))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.white.opacity(0.34), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .lineLimit(1)
            .fixedSize()
    }
}

/// Blocco informativo in basso a sinistra del player (sopra la barra di
/// avanzamento): rigo piccolo (stagione/episodio o nome canale), titolo
/// grande, descrizione del programma (live) e badge. Sta in basso e non
/// più nella barra in alto, dove un titolo lungo copriva i tasti.
struct PlayerInfoBlock: View {
    let title: String
    let subtitle: String?
    let isLive: Bool
    let liveInfo: PlayerLiveInfo?
    let program: EPGProgram?
    let badges: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isLive, let liveInfo, liveInfo.logoURLString?.isEmpty == false {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.55))

                    CachedPosterImage(
                        urlString: liveInfo.logoURLString,
                        baseHost: liveInfo.baseHost,
                        width: 83,
                        height: 46,
                        cornerRadius: 12,
                        placeholderSymbol: "tv",
                        contentMode: .fit
                    )
                }
                .frame(width: 83, height: 46)
                .padding(.bottom, 4)
            }

            if let smallLine {
                Text(smallLine)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
            }

            Text(bigTitle)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.leading)
                .shadow(radius: 4)

            if isLive, let description = program?.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            if !badges.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
                            PlayerBadgeChip(text: badge)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Live con programma noto: nome del canale (maiuscolo) sopra il titolo
    /// del programma; VOD/Serie: "Stagione X Episodio Y".
    private var smallLine: String? {
        if isLive {
            guard program != nil else { return nil }
            return (liveInfo?.channelName ?? title).uppercased()
        }

        return subtitle
    }

    private var bigTitle: String {
        if isLive, let program { return program.title }
        return title
    }
}
