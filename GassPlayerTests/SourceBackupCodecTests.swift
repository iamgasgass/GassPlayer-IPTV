import XCTest
@testable import GassPlayer

final class SourceBackupCodecTests: XCTestCase {
    private func makeSources() -> [MediaSourceConfig] {
        [
            MediaSourceConfig(name: "Sorgente A", type: .xtream, host: "http://a.example.com:8080", username: "userA", password: "passA"),
            MediaSourceConfig(name: "Playlist B", type: .m3u8, host: "http://b.example.com/list.m3u")
        ]
    }

    func testEncodeProducesValidUTF8JSON() throws {
        let sources = makeSources()
        let json = try SourceBackupCodec.encodeAsString(sources)
        XCTAssertTrue(json.contains("Sorgente A"))
        XCTAssertTrue(json.contains("\"version\""))
    }

    func testRoundTripPreservesSources() throws {
        let sources = makeSources()
        let json = try SourceBackupCodec.encodeAsString(sources)
        let decoded = try SourceBackupCodec.decode(fromString: json)

        XCTAssertEqual(decoded.count, sources.count)
        XCTAssertEqual(decoded, sources)
    }

    func testRoundTripViaDataMatchesRoundTripViaString() throws {
        let sources = makeSources()
        let data = try SourceBackupCodec.encode(sources)
        let decodedFromData = try SourceBackupCodec.decode(data)
        XCTAssertEqual(decodedFromData, sources)
    }

    func testDecodeInvalidStringThrows() {
        XCTAssertThrowsError(try SourceBackupCodec.decode(fromString: "questo non e' un json valido"))
    }

    func testEmptyArrayRoundTrips() throws {
        let json = try SourceBackupCodec.encodeAsString([])
        let decoded = try SourceBackupCodec.decode(fromString: json)
        XCTAssertTrue(decoded.isEmpty)
    }
}
