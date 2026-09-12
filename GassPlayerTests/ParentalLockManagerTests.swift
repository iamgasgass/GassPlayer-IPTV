import XCTest
@testable import GassPlayer

final class ParentalLockManagerTests: XCTestCase {
    @MainActor
    func testSetPINEnablesLock() {
        let manager = ParentalLockManager()
        manager.setPIN("1234")
        XCTAssertTrue(manager.state.isEnabled)
        XCTAssertTrue(manager.verify("1234"))
        XCTAssertFalse(manager.verify("0000"))
    }

    @MainActor
    func testDisableClearsHash() {
        let manager = ParentalLockManager()
        manager.setPIN("1234")
        manager.disable()
        XCTAssertFalse(manager.state.isEnabled)
        XCTAssertFalse(manager.verify("1234"))
    }

    @MainActor
    func testLockUnlockCategory() {
        let manager = ParentalLockManager()
        manager.setPIN("1234")
        manager.lock(categoryId: "adulti")
        XCTAssertTrue(manager.isLocked(categoryId: "adulti"))
        manager.unlock(categoryId: "adulti")
        XCTAssertFalse(manager.isLocked(categoryId: "adulti"))
    }
}
