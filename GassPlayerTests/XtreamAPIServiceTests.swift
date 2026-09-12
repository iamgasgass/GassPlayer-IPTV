import XCTest
@testable import GassPlayer

final class XtreamAPIServiceTests: XCTestCase {
    func testStreamURLConstruction() {
        let credentials = XtreamCredentials(host: "http://example.com:8080", username: "user1", password: "pass1")
        let service = XtreamAPIService(credentials: credentials)

        let url = service.streamURL(for: 12345, kind: .live, ext: "m3u8")
        XCTAssertEqual(url?.absoluteString, "http://example.com:8080/live/user1/pass1/12345.m3u8")
    }

    func testStreamURLForMovie() {
        let credentials = XtreamCredentials(host: "http://example.com:8080", username: "user1", password: "pass1")
        let service = XtreamAPIService(credentials: credentials)

        let url = service.streamURL(for: 999, kind: .movie, ext: "mkv")
        XCTAssertEqual(url?.absoluteString, "http://example.com:8080/movie/user1/pass1/999.mkv")
    }

    func testMalformedHostThrows() async {
        let credentials = XtreamCredentials(host: "not-a-valid-host", username: "u", password: "p")
        let service = XtreamAPIService(credentials: credentials)

        do {
            _ = try await service.authenticate()
            XCTFail("Doveva lanciare XtreamError.malformedHost")
        } catch let error as XtreamError {
            switch error {
            case .malformedHost: break
            default: XCTFail("Errore inatteso: \(error)")
            }
        } catch {
            XCTFail("Tipo di errore inatteso: \(error)")
        }
    }
}
