import XCTest
@testable import GassPlayer

final class M3UPlaylistServiceTests: XCTestCase {
    func testParsesBasicChannel() async {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 tvg-id="rai1" tvg-logo="https://example.com/rai1.png" group-title="Italia",Rai 1
        http://example.com/rai1.m3u8
        """
        let service = M3UPlaylistService()
        let channels = await service.parse(m3u)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first?.title, "Rai 1")
        XCTAssertEqual(channels.first?.groupTitle, "Italia")
        XCTAssertEqual(channels.first?.tvgId, "rai1")
        XCTAssertEqual(channels.first?.logoURL, "https://example.com/rai1.png")
    }

    func testIgnoresCommentsAndEmptyLines() async {
        let m3u = """
        #EXTM3U

        # commento generico
        #EXTINF:-1,Canale senza attributi
        http://example.com/canale.ts
        """
        let service = M3UPlaylistService()
        let channels = await service.parse(m3u)

        XCTAssertEqual(channels.count, 1)
        XCTAssertEqual(channels.first?.title, "Canale senza attributi")
        XCTAssertNil(channels.first?.groupTitle)
    }

    func testMultipleChannels() async {
        let m3u = """
        #EXTM3U
        #EXTINF:-1 group-title="Sport",Canale Sport 1
        http://example.com/sport1.m3u8
        #EXTINF:-1 group-title="News",Canale News 1
        http://example.com/news1.m3u8
        """
        let service = M3UPlaylistService()
        let channels = await service.parse(m3u)

        XCTAssertEqual(channels.count, 2)
        XCTAssertEqual(Set(channels.map { $0.groupTitle }), Set(["Sport", "News"]))
    }
}
