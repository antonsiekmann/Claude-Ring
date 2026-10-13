import Foundation

/// Decides how long to wait before the next usage request.
///
/// The usage endpoint limits requests strictly and can answer 429 for a long
/// time, often with `Retry-After: 0`. So after a 429 the schedule backs off
/// far more than after other failures.
enum RefreshSchedule {
    /// Upper bound for the exponential backoff after ordinary failures.
    static let maximumBackoff: Duration = .seconds(15 * 60)
    /// First wait after a 429.
    static let rateLimitBackoff: Duration = .seconds(5 * 60)
    /// Upper bound for the backoff after repeated 429s.
    static let maximumRateLimitBackoff: Duration = .seconds(30 * 60)
    /// Upper bound for a server-provided `Retry-After`.
    static let maximumRetryAfter: Duration = .seconds(60 * 60)
    /// Data younger than this is fresh enough when the popover opens.
    static let stalenessThreshold: Duration = .seconds(2 * 60)

    /// - Parameters:
    ///   - interval: The interval chosen in the settings.
    ///   - consecutiveFailures: Failed requests since the last success.
    ///   - isRateLimited: Whether the last failure was a 429.
    ///   - retryAfter: The server's `Retry-After` from the last response, if any.
    static func delay(
        interval: Duration,
        consecutiveFailures: Int,
        isRateLimited: Bool = false,
        retryAfter: Duration? = nil
    ) -> Duration {
        var delay = interval
        if isRateLimited {
            let base = max(interval, rateLimitBackoff)
            let factor = 1 << min(max(consecutiveFailures - 1, 0), 6)
            delay = min(base * factor, max(base, maximumRateLimitBackoff))
        } else if consecutiveFailures > 0 {
            let factor = 1 << min(consecutiveFailures, 6)
            delay = min(interval * factor, max(interval, maximumBackoff))
        }
        if let retryAfter {
            delay = max(delay, min(retryAfter, maximumRetryAfter))
        }
        return delay
    }

    /// Timer tolerance that lets macOS coalesce the wake-up with other work.
    static func tolerance(for delay: Duration) -> Duration {
        delay / 10
    }

    static func isStale(lastUpdated: Date?, now: Date) -> Bool {
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) >= stalenessThreshold.timeInterval
    }
}
