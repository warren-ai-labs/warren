import Foundation
import Darwin

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
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var pendingEvent: Event?
    private var readyContinuation: CheckedContinuation<Event, Error>?
    private static let readyTimeout: Duration = .seconds(30)

    func start(
        name: String,
        target: String,
        remoteAddress: String? = nil
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
        var arguments = ["--target", target]
        if let remoteAddress, !remoteAddress.isEmpty {
            arguments += ["--remote", remoteAddress]
        }
        command.arguments = arguments
        command.standardInput = input
        command.standardOutput = output
        command.standardError = errorOutput
        command.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in
                self?.helperTerminated(process: process, status: process.terminationStatus)
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self, weak command] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                guard let self, let command, self.process === command else { return }
                self.consume(data)
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
        errorPipe = errorOutput
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
            let timeoutTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.readyTimeout)
                } catch {
                    return
                }
                guard let self, let continuation = self.readyContinuation else { return }
                self.readyContinuation = nil
                continuation.resume(throwing: NSError(
                    domain: "WarrenEmbeddedSSHTunnel",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "The embedded SSH helper timed out while establishing the tunnel."]
                ))
            }
            defer { timeoutTask.cancel() }
            event = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    readyContinuation = continuation
                    if Task.isCancelled {
                        readyContinuation = nil
                        continuation.resume(throwing: CancellationError())
                        return
                    }
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
              let url = event.url,
              Self.isValidLoopbackURL(url),
              let token = event.token,
              Self.isValidToken(token) else {
            stop()
            throw NSError(
                domain: "WarrenEmbeddedSSHTunnel",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: event.error ?? "The embedded SSH helper returned an invalid ready event."]
            )
        }
        return WarrenRemoteEndpointConfiguration(name: name, url: url, token: token, ssh: nil)
    }

    private static func isValidLoopbackURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "http",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let host = components.host,
              let port = components.port,
              (1...65535).contains(port),
              components.path.isEmpty || components.path == "/" else {
            return false
        }
        // Foundation may retain the RFC 2732 brackets in URLComponents.host
        // for an IPv6 literal (for example, "[::1]"). Normalize only those
        // delimiters; accepting any other hostname here would weaken the
        // loopback-only boundary.
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let octets = normalizedHost.split(separator: ".")
        if octets.count == 4,
           let first = Int(octets[0]),
           (0...255).contains(first),
           octets.dropFirst().allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) {
            return first == 127
        }
        return normalizedHost == "::1"
    }

    private static func isValidToken(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 4096 else { return false }
        // The helper sends the token in a JSON line and the Go bootstrap
        // probe places it in an HTTP header. Visible ASCII avoids delimiters,
        // control bytes, and malformed header values on either boundary.
        return value.utf8.allSatisfy { (0x21...0x7E).contains(Int($0)) }
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
            // A helper blocked in an SSH syscall may not observe SIGTERM
            // promptly. Ensure endpoint switches and app termination cannot
            // leave a forwarding process (and its credentials) behind.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                // Process.isRunning is tied to this Process instance, so a
                // recycled PID cannot make us signal an unrelated process.
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                }
            }
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

    private func helperTerminated(process terminatedProcess: Process, status: Int32) {
        guard process === terminatedProcess else { return }
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
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        outputPipe = nil
        errorPipe = nil
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
