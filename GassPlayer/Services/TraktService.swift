import Foundation

struct TraktDeviceCode: Decodable {
    let deviceCode: String, userCode: String, verificationUrl: String, expiresIn: Int, interval: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code"
        case verificationUrl = "verification_url", expiresIn = "expires_in", interval
    }
}

struct TraktToken: Codable {
    let accessToken: String, refreshToken: String, expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
    }
}

actor TraktService {
    private let clientId: String
    private let clientSecret: String
    private let base = URL(string: "https://api.trakt.tv")!

    init(clientId: String, clientSecret: String) { self.clientId = clientId; self.clientSecret = clientSecret }

    func requestDeviceCode() async throws -> TraktDeviceCode {
        var request = URLRequest(url: base.appendingPathComponent("oauth/device/code"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["client_id": clientId])
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(TraktDeviceCode.self, from: data)
    }

    func pollForToken(deviceCode: String) async throws -> TraktToken {
        var request = URLRequest(url: base.appendingPathComponent("oauth/device/token"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["code": deviceCode, "client_id": clientId, "client_secret": clientSecret])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw XtreamError.invalidCredentials }
        return try JSONDecoder().decode(TraktToken.self, from: data)
    }

    func scrobbleStart(token: String, imdbId: String, progress: Double) async {
        await sendScrobble(action: "start", token: token, imdbId: imdbId, progress: progress)
    }
    func scrobbleStop(token: String, imdbId: String, progress: Double) async {
        await sendScrobble(action: "stop", token: token, imdbId: imdbId, progress: progress)
    }
    private func sendScrobble(action: String, token: String, imdbId: String, progress: Double) async {
        var request = URLRequest(url: base.appendingPathComponent("scrobble/\(action)"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientId, forHTTPHeaderField: "trakt-api-key")
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        let body: [String: Any] = ["movie": ["ids": ["imdb": imdbId]], "progress": progress]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: request)
    }
}
