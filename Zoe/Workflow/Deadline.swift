import Foundation

/// Bound the caller's wait even if an async dependency ignores cancellation.
/// This cannot kill framework work. Callers must isolate it and reject late results.
@MainActor
func withTimeout<T: Sendable>(seconds: Int, onCancel: @escaping @MainActor @Sendable () -> Void = {},
                             operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    try await withTimeout(after: .seconds(seconds), onCancel: onCancel, operation: operation)
}

@MainActor
func withTimeout<T: Sendable>(after duration: Duration, onCancel: @escaping @MainActor @Sendable () -> Void = {},
                             operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>(onCancel: onCancel)
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            race.start(continuation, duration: duration, operation: operation)
        }
    } onCancel: {
        Task { @MainActor in race.finish(.failure(CancellationError()), cancelWork: true) }
    }
}

@MainActor
private final class DeadlineRace<T: Sendable> {
    private var continuation: CheckedContinuation<T, any Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private let onCancel: @MainActor @Sendable () -> Void
    init(onCancel: @escaping @MainActor @Sendable () -> Void) { self.onCancel = onCancel }

    func start(_ continuation: CheckedContinuation<T, any Error>, duration: Duration,
               operation: @escaping @MainActor @Sendable () async throws -> T) {
        self.continuation = continuation
        work = Task { @MainActor in
            do { self.finish(.success(try await operation()), cancelWork: false) }
            catch { self.finish(.failure(error), cancelWork: false) }
        }
        timer = Task { @MainActor in
            do { try await Task.sleep(for: duration) } catch { return }
            self.finish(.failure(ZoeError("Operation deadline reached.", status: .partial)), cancelWork: true)
        }
    }

    func finish(_ result: Result<T, any Error>, cancelWork: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        if cancelWork { work?.cancel(); onCancel() }
        work = nil
        continuation.resume(with: result)
    }
}
