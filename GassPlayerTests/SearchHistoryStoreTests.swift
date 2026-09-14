import XCTest
@testable import GassPlayer

final class SearchHistoryStoreTests: XCTestCase {
    private func makeStore(suiteName: String) -> SearchHistoryStore {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return SearchHistoryStore(defaults: defaults)
    }

    @MainActor
    func testRecordAddsItemToFront() {
        let store = makeStore(suiteName: "SearchHistoryStoreTests.record")
        store.record("rai 1")
        store.record("sky sport")
        XCTAssertEqual(store.items, ["sky sport", "rai 1"])
    }

    @MainActor
    func testRecordIgnoresShortQueries() {
        let store = makeStore(suiteName: "SearchHistoryStoreTests.short")
        store.record("a")
        store.record("")
        XCTAssertTrue(store.items.isEmpty)
    }

    @MainActor
    func testRecordMovesDuplicateToFrontWithoutDuplicating() {
        let store = makeStore(suiteName: "SearchHistoryStoreTests.dedup")
        store.record("rai 1")
        store.record("sky sport")
        store.record("Rai 1")
        XCTAssertEqual(store.items, ["Rai 1", "sky sport"])
    }

    @MainActor
    func testRecordEnforcesLimitOfTen() {
        let store = makeStore(suiteName: "SearchHistoryStoreTests.limit")
        for index in 0..<15 {
            store.record("query \(index)")
        }
        XCTAssertEqual(store.items.count, 10)
        XCTAssertEqual(store.items.first, "query 14")
    }

    @MainActor
    func testRemoveDeletesSingleItem() {
        let store = makeStore(suiteName: "SearchHistoryStoreTests.remove")
        store.record("rai 1")
        store.record("sky sport")
        store.remove("rai 1")
        XCTAssertEqual(store.items, ["sky sport"])
    }

    @MainActor
    func testClearEmptiesHistoryAndPersists() {
        let suiteName = "SearchHistoryStoreTests.clear"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SearchHistoryStore(defaults: defaults)
        store.record("rai 1")
        store.clear()
        XCTAssertTrue(store.items.isEmpty)

        let reloaded = SearchHistoryStore(defaults: defaults)
        XCTAssertTrue(reloaded.items.isEmpty)
    }

    @MainActor
    func testHistoryPersistsAcrossInstances() {
        let suiteName = "SearchHistoryStoreTests.persist"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SearchHistoryStore(defaults: defaults)
        store.record("rai 1")

        let reloaded = SearchHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.items, ["rai 1"])
    }
}
