import Foundation

struct ParentalLockState: Codable {
    var isEnabled: Bool = false
    var pinHash: String?
    var lockedCategoryIds: Set<String> = []
}
