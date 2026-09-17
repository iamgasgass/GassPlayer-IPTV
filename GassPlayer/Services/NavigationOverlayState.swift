import Foundation
import Combine

@MainActor
final class NavigationOverlayState: ObservableObject {
    @Published var showSearch = false
    @Published var showSettings = false
    /// Apre `SourcesView` direttamente (senza passare dalla radice di
    /// Impostazioni), usato dalla sezione "Sorgenti" in Home: toccandola si
    /// deve aprire esattamente la stessa schermata "Sorgenti" raggiungibile
    /// da Impostazioni → Connessioni → Sorgenti, non l'elenco Impostazioni.
    @Published var showSources = false
}
