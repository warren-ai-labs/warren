import Foundation
import WarrenDomain
import GhosttyAdapter

@MainActor
func run() throws {
    let surface = GhosttySurface(
        id: TerminalSessionID(),
        attachmentID: TerminalAttachmentID(),
        workingDirectory: "/tmp",
        observeANSISemantics: true,
        onInput: { _ in },
        onResize: { _, _ in }
    )
    surface.receive(Data("plain \u{1b}[1;38;2;224;120;80morange\u{1b}[0m \u{1b}[38;5;42mgreen\u{1b}[0m".utf8))
    let snapshot = surface.semanticSnapshot()
    guard snapshot.containsStyledText,
          snapshot.plainText == "plain orange green" else {
        throw NSError(
            domain: "Warren.TerminalProbe",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Terminal ANSI semantics were not preserved."]
        )
    }
    let directory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["WARREN_ARTIFACT_DIR"]
            ?? "/tmp/warren-observation/terminal-probe",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(snapshot)
    try data.write(to: directory.appendingPathComponent("terminal-semantics.json"), options: .atomic)
    print("terminal semantics OK: \(snapshot.runs.count) runs -> \(directory.path)")
}

try run()
