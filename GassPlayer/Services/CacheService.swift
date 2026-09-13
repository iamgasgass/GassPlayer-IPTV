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

    func clearAll() {
        store.removeAll()
    }
}

actor CachedXtreamRepository {
    private let api: XtreamAPIService
    private let cachePrefix: String

    init(credentials: XtreamCredentials) {
        api = XtreamAPIService(credentials: credentials)
        cachePrefix = Self.makeCachePrefix(credentials: credentials)
    }

    func categories(kind: XtreamStreamKind, forceRefresh: Bool = false) async throws -> [XtreamCategory] {
        let key = "\(cachePrefix).categories.\(kind.rawValue)"
        if !forceRefresh, let cached: [XtreamCategory] = await CacheService.shared.value(for: key) {
            return cached
        }

        let result = try await RetryPolicy.withRetry(shouldRetry: Self.shouldRetry) {
            try await self.api.fetchCategories(kind: kind)
        }
        await CacheService.shared.set(result, for: key, ttl: 600)
        return result
    }

    func streams(
        kind: XtreamStreamKind,
        categoryId: String?,
        forceRefresh: Bool = false
    ) async throws -> [XtreamStream] {
        let categoryKey = categoryId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "all"
        let key = "\(cachePrefix).streams.\(kind.rawValue).\(categoryKey)"
        if !forceRefresh, let cached: [XtreamStream] = await CacheService.shared.value(for: key) {
            return cached
        }

        let result = try await RetryPolicy.withRetry(shouldRetry: Self.shouldRetry) {
            try await self.api.fetchStreams(kind: kind, categoryId: categoryId)
        }
        await CacheService.shared.set(result, for: key, ttl: 300)
        return result
    }

    func allStreams(kind: XtreamStreamKind, forceRefresh: Bool = false) async throws -> [XtreamStream] {
        let key = "\(cachePrefix).catalog.\(kind.rawValue)"
        if !forceRefresh, let cached: [XtreamStream] = await CacheService.shared.value(for: key) {
            return cached
        }

        let result = try await RetryPolicy.withRetry(shouldRetry: Self.shouldRetry) {
            try await self.api.fetchAllStreams(kind: kind)
        }
        await CacheService.shared.set(result, for: key, ttl: kind == .movie ? 900 : 300)
        return result
    }

    func invalidate(kind: XtreamStreamKind? = nil) async {
        let prefix: String
        if let kind {
            prefix = "\(cachePrefix)."
        } else {
            prefix = cachePrefix
        }
        await CacheService.shared.invalidate(prefix: prefix)
    }

    func streamURL(for stream: XtreamStream, kind: XtreamStreamKind) -> URL? {
        api.streamURL(for: stream, kind: kind)
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        guard let error = error as? XtreamError else { return true }
        switch error {
        case .wrongCredentials, .malformedHost, .invalidURL, .decoding:
            return false
        case .unreachable, .timeout, .httpStatus, .noProviderVPN:
            return true
        }
    }

    private static func makeCachePrefix(credentials: XtreamCredentials) -> String {
        let host = credentials.host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let stableInput = "\(host)|\(credentials.username)"
        let digest = stableInput.utf8.reduce(UInt64(14695981039346656037)) { partial, byte in
            (partial ^ UInt64(byte)) &* UInt64(1099511628211)
        }
        return "xtream.\(String(digest, radix: 16))"
    }
}
