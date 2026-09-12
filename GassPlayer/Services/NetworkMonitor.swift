import Foundation
import Network
import Combine

/// Sostituisce il vecchio `isOnWiFi() -> true` placeholder in
/// DownloadManager con un monitor di rete reale basato su NWPathMonitor.
/// Serve a tre cose critiche per lo streaming:
/// 1. Non tentare riconnessioni a raffica quando il device è offline
///    (evita "retry storm" che peggiora il problema)
/// 2. Sapere se la rete è "constrained" (risparmio dati attivo dall'utente
///    iOS) o "expensive" (cellulare/hotspot) per abbassare automaticamente
///    la qualità richiesta
/// 3. Decidere se un download può partire davvero in base a Wi-Fi reale,
///    non a un valore fisso
@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published private(set) var isConnected = true
    @Published private(set) var isExpensive = false
    @Published private(set) var isConstrained = false
    @Published private(set) var connectionType: NWInterface.InterfaceType?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "gassplayer.networkmonitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let type = path.availableInterfaces.first?.type
            Task { @MainActor in
                self?.isConnected = connected
                self?.isExpensive = expensive
                self?.isConstrained = constrained
                self?.connectionType = type
            }
        }
        monitor.start(queue: queue)
    }

    var isOnWiFi: Bool { connectionType == .wifi }

    /// Suggerisce se abbassare automaticamente la qualità video in base
    /// alle condizioni di rete correnti (cellulare, risparmio dati attivo).
    var shouldPreferLowerQuality: Bool { isExpensive || isConstrained }
}
