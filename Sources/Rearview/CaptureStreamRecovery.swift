import Foundation

/// ScreenCaptureKit configuration and start/stop calls must not overtake one another.
actor CaptureOperationQueue {
    private var tail: Task<Void, Never>?

    func run(cancellable: Bool = true, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task {
            await previous?.value
            try Task.checkCancellation()
            try await operation()
        }
        tail = Task { _ = await task.result }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            if cancellable { task.cancel() }
        }
    }
}

/// Bounded, event-driven recovery. An unchanged screen is not a failure signal.
final class CaptureStreamRecovery: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var active = false
    private var task: Task<Void, Never>?
    private let delay: Duration
    private let attempts: Int

    init(delay: Duration = .milliseconds(500), attempts: Int = 3) {
        self.delay = delay
        self.attempts = attempts
    }

    var isRecovering: Bool { lock.withLock { task != nil } }

    func begin() {
        cancel()
        lock.withLock { active = true }
    }

    func cancel() {
        lock.withLock {
            active = false
            epoch &+= 1
            task?.cancel()
            task = nil
        }
    }

    func request(
        restart: @escaping @Sendable () async throws -> Void,
        shouldRetry: @escaping @Sendable (Error) -> Bool = { _ in true },
        failed: @escaping @Sendable (Error) -> Void
    ) {
        lock.withLock {
            guard active else { return }
            epoch &+= 1
            let requestEpoch = epoch
            task?.cancel()
            task = Task { [weak self, delay, attempts] in
                for attempt in 0..<attempts {
                    do {
                        // Coalesce display reconfiguration bursts; also back off retries.
                        try await Task.sleep(for: delay * (attempt + 1))
                        try Task.checkCancellation()
                        try await restart()
                        try Task.checkCancellation()
                        self?.finish(requestEpoch)
                        return
                    } catch {
                        guard !Task.isCancelled else { return }
                        if attempt == attempts - 1 || !shouldRetry(error) {
                            if self?.finish(requestEpoch) == true { failed(error) }
                            return
                        }
                    }
                }
            }
        }
    }

    @discardableResult
    private func finish(_ requestEpoch: UInt64) -> Bool {
        lock.withLock {
            guard active, epoch == requestEpoch else { return false }
            task = nil
            return true
        }
    }
}
