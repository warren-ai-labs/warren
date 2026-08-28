import Foundation

/// Owns the bundled SSH forwarding helper used by SSH-backed endpoints.
/// Keeping the helper behind a small process boundary lets the Desktop remain
/// Swift-native while reusing Go's mature SSH config and authentication stack.
@MainActor
final class WarrenEmbeddedSSHTunnel {
    private struct Event: Decodable {
        let type: String
        let url: String?
        let token: String?
        let error: String?
    }

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = Data()
    private var pendingEvent: Event?
    private var readyContinuation: CheckedContinuation<Event, Error>?

    func start(
        name: String,
        target: String
    ) async throws -> WarrenRemoteEndpointConfiguration {
        guard process == nil else {
            throw NSError(
                domain: "WarrenEmbeddedSSHTunnel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "An SSH tunnel is already running."
                ]
            )
        }
        let executableURL = try Self.helperURL()
        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        let command = Process()
        command.executableURL = executableURL
        command.arguments = ["--target", target]
        command.standardInput = input
        command.standardOutput = output
        command.standardError = errorOutput
        command.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.helperTerminated(status: process.terminationStatus)
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.consume(data)
            }
        }
        // Drain stderr so a verbose SSH failure cannot fill the pipe and
        // deadlock the helper before it can report its structured error.
        errorOutput.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process = command
        inputPipe = input
        outputPipe = output
        outputBuffer.removeAll(keepingCapacity: true)
        pendingEvent = nil
        do {
            try command.run()
        } catch {
            cleanupProcess()
            throw NSError(
                domain: "WarrenEmbeddedSSHTunnel",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey: "Unable to start the embedded SSH helper.",
                    NSUnderlyingErrorKey: error,
                ]
            )
        }

        let event: Event
        do {
            event = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    readyContinuation = continuation
                    if let pendingEvent {
                        self.pendingEvent = nil
                        readyContinuation = nil
                        continuation.resume(returning: pendingEvent)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.stop() }
            }
        } catch {
            stop()
            throw error
        }
        guard event.type == "ready",
              let url = event.url, !url.isEmpty,
              let token = event.token, !token.isEmpty else {
            stop()
            throw NSError(
                domain: "WarrenEmbeddedSSHTunnel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: event.error ?? "The embedded SSH helper returned an invalid ready event."]
            )
        }
        return WarrenRemoteEndpointConfiguration(name: name, url: url, token: token, ssh: nil)
    }

    func stop() {
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        if let inputPipe,
           let data = "{\"type\":\"stop\"}\n".data(using: .utf8) {
            try? inputPipe.fileHandleForWriting.write(contentsOf: data)
            try? inputPipe.fileHandleForWriting.close()
        }
        if let process, process.isRunning {
            process.terminate()
        }
        cleanupProcess()
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let event = try? JSONDecoder().decode(Event.self, from: line) else {
                continue
            }
            if let readyContinuation {
                self.readyContinuation = nil
                readyContinuation.resume(returning: event)
            } else {
                pendingEvent = event
            }
        }
    }

    private func helperTerminated(status: Int32) {
        guard process != nil else { return }
        if let readyContinuation {
            self.readyContinuation = nil
            readyContinuation.resume(throwing: NSError(
                domain: "WarrenEmbeddedSSHTunnel",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "The embedded SSH helper exited before establishing the tunnel."]
            ))
        }
        cleanupProcess()
    }

    private func cleanupProcess() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        inputPipe = nil
        process = nil
    }

    private static func helperURL() throws -> URL {
        var candidates: [URL] = []
        if let configured = ProcessInfo.processInfo.environment["WARREN_SSH_TUNNEL_PATH"],
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("warren-ssh-tunnel"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/warren-ssh-tunnel"))
        if let executable = Bundle.main.executableURL {
            // `swift run` places the app executable below `.build/<triple>/debug`
            // while build-headless writes the helper at the repository `.build`
            // root. Walk a few parents to make source builds work without a
            // manual install step.
            var directory = executable.deletingLastPathComponent()
            for _ in 0..<4 {
                candidates.append(directory.appendingPathComponent("warren-ssh-tunnel"))
                directory.deleteLastPathComponent()
            }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(home.appendingPathComponent(".local/bin/warren-ssh-tunnel"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/warren-ssh-tunnel"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/warren-ssh-tunnel"))
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map {
                URL(fileURLWithPath: String($0)).appendingPathComponent("warren-ssh-tunnel")
            })
        }
        if let helper = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return helper
        }
        throw NSError(
            domain: "WarrenEmbeddedSSHTunnel",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "The embedded SSH helper is not installed. Reinstall Warren or build the headless tools."]
        )
    }
}
