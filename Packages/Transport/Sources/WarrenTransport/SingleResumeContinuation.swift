import Foundation

/// Bridges a callback API into a checked continuation while guaranteeing the
/// continuation is resumed exactly once.
///
/// Foundation can invoke a completion handler more than once when the owning
/// task is cancelled while a request is in flight — `URLSessionWebSocketTask`
/// has been observed to call one `sendPing` completion twice, once with the
/// result and once with a cancellation error. A second `resume` on a checked
/// continuation traps the process, which is how an iOS ping raced a Relay
/// reconnect and crashed the app. Cancellation also races the callback
/// because `withTaskCancellationHandler` may run before the operation attaches
/// its continuation, so every path shares this guard.
///
/// `attach` must be called from the operation body; `succeed`/`fail` may be
/// called from any thread and from any number of racing paths. If the outcome
/// is decided before the operation attaches, `attach` delivers it immediately
/// instead of leaving the continuation pending forever.
final class SingleResumeContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pendingError: Error?
    private var resolved = false

    init() {}

    func attach(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if resolved {
            let error = pendingError
            self.continuation = nil
            lock.unlock()
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func succeed() {
        resolve(.success(()))
    }

    func fail(_ error: Error) {
        resolve(.failure(error))
    }

    private func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        guard let continuation else {
            // Decided before the operation attached; remember a failure so
            // attach can deliver it instead of leaking the continuation.
            if case .failure(let error) = result {
                pendingError = error
            }
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }
}
