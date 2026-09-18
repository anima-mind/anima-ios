import Foundation
import Testing
@testable import AnimaKit

@Suite struct ErrorClassifierTests {

    @Test func maps429ToRateLimitedRespectingRetryAfter() {
        #expect(ErrorClassifier.classify(status: 429, retryAfter: "7", body: "") == .rateLimited(after: 7))
        #expect(ErrorClassifier.classify(status: 429, retryAfter: nil, body: "") == .rateLimited(after: nil))
    }

    @Test func maps529ToRetryable() {
        #expect(ErrorClassifier.classify(status: 529, retryAfter: nil, body: "overloaded") == .retryable(after: 10))
    }

    @Test func maps5xxToRetryable() {
        #expect(ErrorClassifier.classify(status: 503, retryAfter: nil, body: "") == .retryable(after: nil))
    }

    @Test func maps400ContextToOverflow() {
        let body = #"{"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}"#
        #expect(ErrorClassifier.classify(status: 400, retryAfter: nil, body: body) == .contextOverflow)
    }

    @Test func maps400OtherToFatal() {
        let body = "messages: roles must alternate"
        #expect(ErrorClassifier.classify(status: 400, retryAfter: nil, body: body) == .fatal(status: 400, message: body))
    }

    @Test func maps401ToFatal() {
        #expect(ErrorClassifier.classify(status: 401, retryAfter: nil, body: "bad key") == .fatal(status: 401, message: "bad key"))
    }

    // MARK: - Retry / backoff

    @Test func retriesRateLimitedThenSucceeds() async throws {
        let attempts = Locked(0)
        let sleeps = Locked(0)
        let result: String = try await withRetry(
            policy: RetryPolicy(maxAttempts: 5, baseDelay: 1, maxDelay: 30),
            sleep: { _ in sleeps.mutate { $0 += 1 } }
        ) { _ in
            let n = attempts.mutate { $0 += 1; return $0 }
            if n < 3 { throw ClassifiedError.rateLimited(after: nil) }
            return "ok"
        }
        #expect(result == "ok")
        #expect(attempts.value == 3)   // 2 fallos + 1 éxito
        #expect(sleeps.value == 2)     // durmió antes de cada reintento
    }

    @Test func fatalIsNotRetried() async {
        let attempts = Locked(0)
        await #expect(throws: ClassifiedError.self) {
            _ = try await withRetry(sleep: { _ in }) { _ -> String in
                attempts.mutate { $0 += 1 }
                throw ClassifiedError.fatal(status: 400, message: "x")
            }
        }
        #expect(attempts.value == 1)   // no reintenta un fatal
    }

    @Test func stopsAfterMaxAttempts() async {
        let attempts = Locked(0)
        await #expect(throws: ClassifiedError.self) {
            _ = try await withRetry(
                policy: RetryPolicy(maxAttempts: 3, baseDelay: 1, maxDelay: 30),
                sleep: { _ in }
            ) { _ -> String in
                attempts.mutate { $0 += 1 }
                throw ClassifiedError.retryable(after: nil)
            }
        }
        #expect(attempts.value == 3)
    }

    @Test func backoffGrowsAndRespectsRetryAfter() {
        let policy = RetryPolicy(baseDelay: 1, maxDelay: 30)
        // Con jitter fijo=1, el backoff crece exponencial: 1, 2, 4.
        #expect(policy.delay(attempt: 1, retryAfter: nil, jitter: 1) == 1)
        #expect(policy.delay(attempt: 2, retryAfter: nil, jitter: 1) == 2)
        #expect(policy.delay(attempt: 3, retryAfter: nil, jitter: 1) == 4)
        // retry-after actúa de piso.
        #expect(policy.delay(attempt: 1, retryAfter: 12, jitter: 0) == 12)
        // cap a maxDelay.
        #expect(policy.delay(attempt: 20, retryAfter: nil, jitter: 1) == 30)
    }
}

/// Contenedor mutable thread-safe para asserts en closures @Sendable.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    @discardableResult func mutate<R>(_ body: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }; return body(&_value)
    }
}
