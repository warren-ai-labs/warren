import SwiftUI
import WarrenDomain
import WarrenTransport

#if canImport(UIKit)
import UIKit
#endif

/// SwiftTerm adapter boundary for iOS. The optional SwiftTerm branch keeps
/// the UI package buildable for previews that do not link the renderer yet;
/// production iOS builds link SwiftTerm and use its native `TerminalView`.
public struct SwiftTermTerminalSurface: View {
    private let snapshot: Data
    private let output: Data
    private let outputRevision: UInt64
    private let isReady: Bool
    private let onInput: (Data) -> Void
    private let onTap: () -> Void
    private let onResize: (TerminalSize) -> Void

    public init(
        snapshot: Data = Data(),
        output: Data,
        outputRevision: UInt64 = 0,
        isReady: Bool,
        onInput: @escaping (Data) -> Void,
        onTap: @escaping () -> Void,
        onResize: @escaping (TerminalSize) -> Void = { _ in }
    ) {
        self.snapshot = snapshot
        self.output = output
        self.outputRevision = outputRevision
        self.isReady = isReady
        self.onInput = onInput
        self.onTap = onTap
        self.onResize = onResize
    }

    public var body: some View {
        ZStack {
            // Keep the native surface mounted throughout recovery and mode
            // changes, but do not reveal a partially installed checkpoint.
            PlatformTerminalView(
                snapshot: snapshot,
                output: output,
                outputRevision: outputRevision,
                isReady: isReady,
                onInput: onInput,
                onTap: onTap,
                onResize: onResize
            )
            // Keep the last rendered grid visible while a reconnect is
            // replaying an atomic checkpoint. The coordinator holds a new
            // snapshot until `synced`, so this never exposes a half-installed
            // recovery state.
            .allowsHitTesting(isReady)
            if !isReady && snapshot.isEmpty && output.isEmpty {
                ProgressView("Connecting terminal…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .accessibilityLabel("Connecting terminal")
            }
        }
        .background(IOSTheme.input)
        .clipShape(Rectangle())
        .accessibilityLabel("Terminal")
    }
}

#if canImport(UIKit) && canImport(SwiftTerm)
import SwiftTerm

private struct PlatformTerminalView: UIViewRepresentable {
    let snapshot: Data
    let output: Data
    let outputRevision: UInt64
    let isReady: Bool
    let onInput: (Data) -> Void
    let onTap: () -> Void
    let onResize: (TerminalSize) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onTap: onTap, onResize: onResize)
    }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        // A terminal's cursor, escape sequences, and column grid are
        // inherently LTR even when the surrounding SwiftUI hierarchy is RTL.
        view.semanticContentAttribute = .forceLeftToRight
        view.backgroundColor = UIColor(red: 21 / 255, green: 17 / 255, blue: 16 / 255, alpha: 1)
        view.nativeBackgroundColor = UIColor(red: 21 / 255, green: 17 / 255, blue: 16 / 255, alpha: 1)
        view.nativeForegroundColor = UIColor(red: 234 / 255, green: 232 / 255, blue: 230 / 255, alpha: 1)
        view.caretColor = UIColor(red: 224 / 255, green: 120 / 255, blue: 80 / 255, alpha: 1)
        // SwiftTerm installs its own accessory row during initialization.
        // Warren owns the single native shortcut rail below the terminal, so
        // keep SwiftTerm's input accessory from producing a duplicate bar.
        view.inputAccessoryView = nil
        context.coordinator.install(snapshot: snapshot, in: view)
        if !output.isEmpty {
            context.coordinator.feed(output, in: view)
        }
        context.coordinator.lastOutputCount = output.count
        context.coordinator.lastOutputRevision = outputRevision
        context.coordinator.isReady = isReady
        context.coordinator.hasRenderedContent = !snapshot.isEmpty || !output.isEmpty
        context.coordinator.terminalView = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        context.coordinator.onInput = onInput
        context.coordinator.onTap = onTap
        context.coordinator.onResize = onResize
        context.coordinator.isReady = isReady

        if isReady, let pending = context.coordinator.pendingSnapshot {
            context.coordinator.pendingSnapshot = nil
            context.coordinator.install(snapshot: pending.payload, in: view, force: true)
            context.coordinator.lastOutputRevision = pending.revision
        }

        let checkpointChanged = outputRevision != context.coordinator.lastOutputRevision
        // The model only replaces the snapshot together with a revision bump
        // (atomic checkpoint install/clear). Gating the O(n) Data compare on
        // that signal keeps every PTY frame at O(1) in the steady state and
        // for hidden LRU surfaces; the count check is belt-and-braces.
        let snapshotChanged: Bool = {
            guard checkpointChanged || snapshot.count != context.coordinator.lastSnapshot.count else {
                return false
            }
            return snapshot != context.coordinator.lastSnapshot
        }()
        if snapshotChanged || checkpointChanged {
            if !isReady && context.coordinator.hasRenderedContent {
                // Keep the previous grid on screen until the Host's `synced`
                // marker opens the presentation gate. Live bytes are held by
                // the model and will be fed after the pending checkpoint is
                // installed.
                context.coordinator.pendingSnapshot = (snapshot, outputRevision)
            } else {
                context.coordinator.install(snapshot: snapshot, in: view, force: checkpointChanged)
                context.coordinator.lastOutputRevision = outputRevision
                context.coordinator.lastOutputCount = 0
            }
        }
        if !isReady && context.coordinator.pendingSnapshot != nil {
            return
        }
        if output.count < context.coordinator.lastOutputCount {
            // A fresh atomic checkpoint replaces the previous stream. If a
            // caller resets or truncates the stream without changing the checkpoint,
            // align the baseline rather than replaying old bytes.
            context.coordinator.lastOutputCount = output.isEmpty ? 0 : output.count
            context.coordinator.resetStream()
        }
        if output.count > context.coordinator.lastOutputCount {
            let delta = output.dropFirst(context.coordinator.lastOutputCount)
            context.coordinator.feed(Data(delta), in: view)
            context.coordinator.hasRenderedContent = true
        }
        context.coordinator.lastOutputCount = output.count
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var onInput: (Data) -> Void
        var onTap: () -> Void
        var onResize: (TerminalSize) -> Void
        weak var terminalView: TerminalView?
        var isReady = false
        var hasRenderedContent = false
        var pendingSnapshot: (payload: Data, revision: UInt64)?
        var lastOutputCount = 0
        var lastSnapshot = Data()
        var lastOutputRevision: UInt64 = 0
        var visibilityRewriter = WarrenANSIVisibilityRewriter()

        init(
            onInput: @escaping (Data) -> Void,
            onTap: @escaping () -> Void,
            onResize: @escaping (TerminalSize) -> Void
        ) {
            self.onInput = onInput
            self.onTap = onTap
            self.onResize = onResize
        }

        @MainActor @objc func didTap() {
            // SwiftTerm normally promotes itself on its internal first-tap
            // recognizer. Warren also installs a forwarding recognizer for
            // the control lease, so explicitly becoming first responder here
            // guarantees that a terminal tap presents the system keyboard and
            // Warren's single shortcut rail on every iOS release.
            if terminalView?.isFirstResponder == false {
                _ = terminalView?.becomeFirstResponder()
            }
            onTap()
        }
        @MainActor
        func install(snapshot: Data, in view: TerminalView, force: Bool = false) {
            guard force || snapshot != lastSnapshot else { return }
            // `ghostline-vt-replay-v1` is an ANSI replay, not a normal live
            // output frame. RIS clears SwiftTerm's previous grid before the
            // replay is installed, preserving the atomic recovery boundary.
            visibilityRewriter.reset()
            view.feed(byteArray: [0x1B, 0x63][...])
            if !snapshot.isEmpty {
                feed(snapshot, in: view)
                hasRenderedContent = true
            }
            lastSnapshot = snapshot
            lastOutputCount = 0
        }
        @MainActor
        func resetOutput(in view: TerminalView) {
            visibilityRewriter.reset()
            view.feed(byteArray: [0x1B, 0x63][...])
            lastOutputCount = 0
        }

        func resetStream() {
            visibilityRewriter.reset()
        }

        @MainActor
        func feed(_ data: Data, in view: TerminalView) {
            let rewritten = visibilityRewriter.rewrite(data)
            guard !rewritten.isEmpty else { return }
            view.feed(byteArray: Array(rewritten)[...])
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            if let size = TerminalSize(columns: newCols, rows: newRows) {
                onResize(size)
            }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func send(source: TerminalView, data: ArraySlice<UInt8>) { onInput(Data(data)) }
        func scrolled(source: TerminalView, position: Double) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            #if canImport(UIKit)
            UIPasteboard.general.string = String(decoding: content, as: UTF8.self)
            #endif
        }
        func clipboardRead(source: TerminalView) -> Data? {
            #if canImport(UIKit)
            return UIPasteboard.general.string.map { Data($0.utf8) }
            #else
            return nil
            #endif
        }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
#elseif canImport(UIKit)
/// Development fallback used when SwiftTerm is not linked into previews. It
/// still provides native text selection and deliberately does not request the
/// software keyboard until the user taps the surface.
private struct PlatformTerminalView: UIViewRepresentable {
    let snapshot: Data
    let output: Data
    let outputRevision: UInt64
    let isReady: Bool
    let onInput: (Data) -> Void
    let onTap: () -> Void
    let onResize: (TerminalSize) -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.semanticContentAttribute = .forceLeftToRight
        view.backgroundColor = UIColor(red: 21 / 255, green: 17 / 255, blue: 16 / 255, alpha: 1)
        view.textColor = .white
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.text = String(decoding: snapshot + output, as: UTF8.self)
        view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap)))
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        guard isReady || !snapshot.isEmpty else { return }
        view.text = String(decoding: snapshot + output, as: UTF8.self)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    final class Coordinator: NSObject {
        let onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func didTap() { onTap() }
    }
}
#else
private struct PlatformTerminalView: View {
    let snapshot: Data
    let output: Data
    let outputRevision: UInt64
    let isReady: Bool
    let onInput: (Data) -> Void
    let onTap: () -> Void
    let onResize: (TerminalSize) -> Void

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(isReady ? String(decoding: snapshot + output, as: UTF8.self) : "Recovering terminal…")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .iosMachineText()
                .padding(10)
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
        }
    }
}
#endif
