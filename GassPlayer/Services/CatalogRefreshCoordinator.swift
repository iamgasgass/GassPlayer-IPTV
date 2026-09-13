import Foundation
import Combine

/// Canale di refresh condiviso tra SettingsView e ChannelGridView.
///
/// Una schermata Impostazioni non deve mantenere riferimenti diretti alle
/// griglie dei tab. Pubblica invece una richiesta tipizzata; la griglia
/// appartenente alla stessa sorgente Xtream e alla stessa sezione
/// (Live/Film/Serie) la intercetta e aggiorna soltanto il catalogo pertinente.
@MainActor
final class CatalogRefreshCoordinator: ObservableObject {
    struct Request: Equatable {
        let id = UUID()
        let host: String
        let kind: XtreamStreamKind
    }

    @Published private(set) var latestRequest: Request?

    func requestRefresh(
        host: String,
        kind: XtreamStreamKind
    ) {
        latestRequest = Request(
            host: host,
            kind: kind
        )
    }
}
