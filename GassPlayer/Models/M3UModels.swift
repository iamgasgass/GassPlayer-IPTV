import Foundation

/// Canale/contenuto di una playlist M3U.
///
/// FIX: `id` era un `UUID()` generato ad ogni parsing, quindi cambiava a ogni
/// avvio (e a ogni ricarica della playlist): i preferiti e "Continua a
/// guardare" salvati con `sourceKey-id` non corrispondevano più a nulla.
/// Ora l'id deriva dall'URL dello stream (con un suffisso numerico solo per
/// i duplicati nella stessa playlist) ed è quindi stabile.
struct M3UChannel: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let logoURL: String?
    let groupTitle: String?
    let tvgId: String?
    /// Attributo `tvg-name` (nome XMLTV del canale), usato per abbinare la
    /// guida programmi quando manca il `tvg-id`.
    let tvgName: String?
    let streamURL: URL
    let kind: XtreamStreamKind

    static func == (l: M3UChannel, r: M3UChannel) -> Bool { l.id == r.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Risultato grezzo del parsing di una playlist.
struct M3UParseResult: Sendable {
    var channels: [M3UChannel]
    /// URL XMLTV dichiarati nell'intestazione (`x-tvg-url` / `url-tvg`).
    var epgURLs: [String]
}

/// Playlist già indicizzata: tutto ciò che le viste leggono (gruppi,
/// canali per gruppo, icona del gruppo, conteggi) è precalcolato UNA volta,
/// fuori dal main thread, al caricamento. Prima ogni lettura rifiltrava
/// l'intera playlist (`channels(for:group:)` per ogni riga e per ogni
/// conteggio: O(gruppi × canali) a ogni render).
struct M3UPlaylistSnapshot: Sendable {
    let channelsByKind: [XtreamStreamKind: [M3UChannel]]
    let groupsByKind: [XtreamStreamKind: [String]]
    let channelsByGroup: [XtreamStreamKind: [String: [M3UChannel]]]
    let iconsByGroup: [XtreamStreamKind: [String: String]]
    let epgURLs: [String]

    static let allChannelsGroup = "Tutti i canali"

    static let empty = M3UPlaylistSnapshot(
        channelsByKind: [:], groupsByKind: [:], channelsByGroup: [:], iconsByGroup: [:], epgURLs: []
    )

    init(
        channelsByKind: [XtreamStreamKind: [M3UChannel]],
        groupsByKind: [XtreamStreamKind: [String]],
        channelsByGroup: [XtreamStreamKind: [String: [M3UChannel]]],
        iconsByGroup: [XtreamStreamKind: [String: String]],
        epgURLs: [String]
    ) {
        self.channelsByKind = channelsByKind
        self.groupsByKind = groupsByKind
        self.channelsByGroup = channelsByGroup
        self.iconsByGroup = iconsByGroup
        self.epgURLs = epgURLs
    }

    init(_ parsed: M3UParseResult) {
        var byKind: [XtreamStreamKind: [M3UChannel]] = [:]
        for channel in parsed.channels {
            byKind[channel.kind, default: []].append(channel)
        }

        var groups: [XtreamStreamKind: [String]] = [:]
        var byGroup: [XtreamStreamKind: [String: [M3UChannel]]] = [:]
        var icons: [XtreamStreamKind: [String: String]] = [:]

        for (kind, channels) in byKind {
            var grouped: [String: [M3UChannel]] = [:]
            var groupIcons: [String: String] = [:]

            for channel in channels {
                guard let group = channel.groupTitle else { continue }
                grouped[group, default: []].append(channel)

                if groupIcons[group] == nil, let logo = channel.logoURL, !logo.isEmpty {
                    groupIcons[group] = logo
                }
            }

            let names = grouped.keys.sorted()

            if names.isEmpty {
                // Nessun `group-title`: un solo gruppo con tutti i canali.
                groups[kind] = [Self.allChannelsGroup]
                grouped[Self.allChannelsGroup] = channels
                if let icon = channels.first(where: { $0.logoURL?.isEmpty == false })?.logoURL {
                    groupIcons[Self.allChannelsGroup] = icon
                }
            } else {
                groups[kind] = names
            }

            byGroup[kind] = grouped
            icons[kind] = groupIcons
        }

        self.init(
            channelsByKind: byKind,
            groupsByKind: groups,
            channelsByGroup: byGroup,
            iconsByGroup: icons,
            epgURLs: parsed.epgURLs
        )
    }
}
