import Foundation
import CryptoKit
import Combine

@MainActor
final class ParentalLockManager: ObservableObject {
    @Published private(set) var state = ParentalLockState()
    private let key = "gassplayer.parentallock"

    init() { load() }
    func setPIN(_ pin: String) { state.pinHash = Self.hash(pin); state.isEnabled = true; persist() }
    func disable() { state.isEnabled = false; state.pinHash = nil; persist() }
    func verify(_ pin: String) -> Bool { Self.hash(pin) == state.pinHash }
    func lock(categoryId: String) { state.lockedCategoryIds.insert(categoryId); persist() }
    func unlock(categoryId: String) { state.lockedCategoryIds.remove(categoryId); persist() }
    func isLocked(categoryId: String) -> Bool { state.isEnabled && state.lockedCategoryIds.contains(categoryId) }

    private static func hash(_ pin: String) -> String {
        SHA256.hash(data: Data(pin.utf8)).compactMap { String(format: "%02x", $0) }.joined()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: key) }
    }
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ParentalLockState.self, from: data) else { return }
        state = decoded
    }
}
