import XCTest
@testable import GassPlayer

final class MediaSourceConfigTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let original = MediaSourceConfig(
            name: "Sorgente Test", type: .xtream, host: "http://test.com:8080",
            username: "user", password: "pass", isEnabled: true, sortOrder: 2
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaSourceConfig.self, from: encoded)

        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.host, original.host)
        XCTAssertEqual(decoded.sortOrder, original.sortOrder)
    }

    func testArrayCodableRoundTrip() throws {
        let sources = [
            MediaSourceConfig(name: "A", type: .xtream, host: "http://a.com"),
            MediaSourceConfig(name: "B", type: .m3u8, host: "http://b.com/playlist.m3u")
        ]
        let encoded = try JSONEncoder().encode(sources)
        let decoded = try JSONDecoder().decode([MediaSourceConfig].self, from: encoded)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[1].type, .m3u8)
    }
}
