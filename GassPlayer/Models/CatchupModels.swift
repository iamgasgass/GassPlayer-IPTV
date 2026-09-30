import Foundation

/// Richiesta di riproduzione in differita (timeshift/catch-up) per un
/// programma specifico di un canale Xtream. Usata da `EPGService.catchupURL`
/// per costruire l'URL `/timeshift/...` del provider.
struct CatchupRequest: Hashable {
    let streamId: Int
    let start: Date
    let durationMinutes: Int
}
