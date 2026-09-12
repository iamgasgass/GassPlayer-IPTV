import Foundation
import Combine

@MainActor
final class NavigationOverlayState: ObservableObject {
    @Published var showSearch = false
    @Published var showSettings = false
}
