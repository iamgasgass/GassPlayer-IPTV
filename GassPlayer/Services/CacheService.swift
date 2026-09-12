import Foundation

actor CacheService {
    static let shared = CacheService()

    private struct Entry {
        let value: Any
        let expiresAt: Date
    }
    private var store: [String: Entry] = [:]

    func value<T>(for key: String) -> T? {
        guard let entry = store[key], entry.expiresAt > Date() else {
            store[key] = nil
            return nil
        }
        return entry.value as? T
    }
    func set<T>(_ value: T, for key: String, ttl: TimeInterval = 300) {
        store[key] = Entry(value: value, expiresAt: Date().addingTimeInterval(ttl))
    }
    func invalidate(prefix: String) {
        store.keys.filter { $0.hasPrefix(prefix) }.forEach { store[$0] = nil }
    }
    func clearAll() { store.removeAll() }
}

actor CachedXtreamRepository {
    private let api: XtreamAPIService
    private let hostKey: String

    init(credentials: XtreamCredentials) {
        self.api = XtreamAPIService(credentials: credentials)
        self.hostKey = credentials.host
    }

    func categories(kind: XtreamStreamKind) async throws -> [XtreamCategory] {
        let key = "\(hostKey)-categories-\(kind)"
        if let cached: [XtreamCategory] = await CacheService.shared.value(for: key) { return cached }
        let result = try await RetryPolicy.withRetry {
            try await self.api.fetchCategories(kind: kind)
        }
        await CacheService.shared.set(result, for: key, ttl: 600)
        return result
    }

    func streams(kind: XtreamStreamKind, categoryId: String?) async throws -> [XtreamStream] {
        let key = "\(hostKey)-streams-\(kind)-\(categoryId ?? "all")"
        if let cached: [XtreamStream] = await CacheService.shared.value(for: key) { return cached }
        let result = try await RetryPolicy.withRetry {
            try await self.api.fetchStreams(kind: kind, categoryId: categoryId)
        }
        await CacheService.shared.set(result, for: key, ttl: 300)
        return result
    }

    func streamURL(for streamId: Int, kind: XtreamStreamKind) -> URL? {
        api.streamURL(for: streamId, kind: kind)
    }
}
