// ErrorClassifier.swift — mapea status HTTP / errores de red a ClassifiedError,
// y retry con backoff exponencial + jitter respetando retry-after (§4.6).

import Foundation

public enum ErrorClassifier {

    /// Clasifica una respuesta HTTP no-200.
    /// - contextOverflow: 400 cuyo mensaje habla de contexto/prompt demasiado largo.
    public static func classify(status: Int, retryAfter: String?, body: String) -> ClassifiedError {
        let retry = parseRetryAfter(retryAfter)
        switch status {
        case 429:
            return .rateLimited(after: retry)
        case 529:
            return .retryable(after: retry ?? 10)
        case 500...599:
            return .retryable(after: retry)
        case 400 where isContextOverflow(body):
            return .contextOverflow
        default:
            return .fatal(status: status, message: body)
        }
    }

    /// Errores de transporte (URLSession): timeouts y caídas de red son retryable;
    /// cancelación se propaga tal cual.
    public static func classify(transport error: Error) -> Error {
        if error is CancellationError { return error }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return error }
        switch ns.code {
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
             NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed:
            return ClassifiedError.retryable(after: nil)
        default:
            return error
        }
    }

    static func isContextOverflow(_ body: String) -> Bool {
        let s = body.lowercased()
        return s.contains("context") || s.contains("prompt is too long")
            || s.contains("too many tokens") || s.contains("maximum")
    }

    static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return seconds
    }
}

// MARK: - Retry / backoff

public struct RetryPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval

    public init(maxAttempts: Int = 5, baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Backoff exponencial con jitter completo. `attempt` es 1-based.
    /// Respeta retry-after como piso cuando el servidor lo indica.
    public func delay(attempt: Int, retryAfter: TimeInterval?, jitter: Double = Double.random(in: 0...1)) -> TimeInterval {
        let expo = min(maxDelay, baseDelay * pow(2, Double(max(0, attempt - 1))))
        let withJitter = expo * jitter
        if let retryAfter { return min(maxDelay, max(retryAfter, withJitter)) }
        return withJitter
    }
}

/// Ejecuta `operation` con reintentos. `sleep` es inyectable para tests
/// deterministas (sin esperas reales). retryable/rateLimited reintentan;
/// contextOverflow/fatal se propagan.
public func withRetry<T: Sendable>(
    policy: RetryPolicy = .init(),
    sleep: @Sendable (TimeInterval) async throws -> Void,
    operation: @Sendable (_ attempt: Int) async throws -> T
) async throws -> T {
    var attempt = 1
    while true {
        do {
            return try await operation(attempt)
        } catch let error as ClassifiedError {
            let after: TimeInterval?
            switch error {
            case .retryable(let a): after = a
            case .rateLimited(let a): after = a
            case .contextOverflow, .fatal:
                throw error
            }
            guard attempt < policy.maxAttempts else { throw error }
            try await sleep(policy.delay(attempt: attempt, retryAfter: after))
            attempt += 1
        }
    }
}
