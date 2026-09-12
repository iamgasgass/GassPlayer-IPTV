import Foundation

/// Wrapper generico di retry con backoff esponenziale per qualunque
/// chiamata di rete asincrona che lancia errori.
enum RetryPolicy {
    static func withRetry<T>(
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 0.5,
        shouldRetry: @escaping (Error) -> Bool = { _ in true },
        operation: @escaping () async throws -> T
    ) async throws -> T {
        var attempt = 0
        var delay = initialDelay
        while true {
            do {
                return try await operation()
            } catch {
                attempt += 1
                DebugLogger.shared.log(.warning, "Tentativo \(attempt)/\(maxAttempts) fallito: \(error.localizedDescription)")
                guard attempt < maxAttempts, shouldRetry(error) else { throw error }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2
            }
        }
    }
}
