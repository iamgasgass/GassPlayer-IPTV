import Foundation

struct XtreamCredentials: Codable, Equatable {
    var host: String
    var username: String
    var password: String
}

struct XtreamAuthResponse: Codable {
    struct UserInfo: Codable {
        let username: String
        let status: String
        let expDate: String?
        enum CodingKeys: String, CodingKey { case username, status; case expDate = "exp_date" }
    }
    struct ServerInfo: Codable { let url: String; let port: String }
    let userInfo: UserInfo
    let serverInfo: ServerInfo
    enum CodingKeys: String, CodingKey { case userInfo = "user_info"; case serverInfo = "server_info" }
}

struct XtreamCategory: Codable, Identifiable, Hashable {
    let categoryId: String
    let categoryName: String
    var id: String { categoryId }
    enum CodingKeys: String, CodingKey { case categoryId = "category_id"; case categoryName = "category_name" }
}

struct XtreamStream: Codable, Identifiable, Hashable {
    let streamId: Int
    let name: String
    let streamIcon: String?
    let categoryId: String?
    var id: Int { streamId }
    enum CodingKeys: String, CodingKey {
        case streamId = "stream_id", name, categoryId = "category_id"
        case streamIcon = "stream_icon"
    }
}

enum XtreamStreamKind {
    case live, movie, series
    var pathComponent: String {
        switch self { case .live: return "live"; case .movie: return "movie"; case .series: return "series" }
    }
}

enum XtreamError: Error { case invalidURL, invalidCredentials, decoding(Error), noProviderVPN }
