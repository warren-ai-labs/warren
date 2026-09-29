import AppKit
import SwiftUI
import XCTest
import WarrenDomain
import WarrenTransport
@testable import Warren

final class WarrenConversationSurfaceTests: XCTestCase {
    /// Opt-in acceptance against a running Host: connects the production model,
    /// renders the production Conversation surface for one ACP Session, and
    /// optionally sends a prompt through it. Images are written for review.
    @MainActor
    func testLiveConversationSurfaceRendersAndSends() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let url = environment["WARREN_CONVERSATION_URL"],
              let token = environment["WARREN_CONVERSATION_TOKEN"],
              let rawSessionID = environment["WARREN_CONVERSATION_SESSION"],
              let sessionID = TerminalSessionID(uuidString: rawSessionID) else {
            throw XCTSkip("Set WARREN_CONVERSATION_URL, _TOKEN, and _SESSION to render a live ACP Session")
        }
        let imagePrefix = environment["WARREN_CONVERSATION_IMAGE"] ?? "/tmp/warren-conversation"
        let model = WarrenRemoteApplicationModel()
        model.connect(WarrenRemoteEndpointConfiguration(name: "conversation-render-test", url: url, token: token))

        try await waitUntil("the roster marks the Session as ACP") { model.isConversationSession(sessionID) }
        let feed = model.conversationFeed(for: sessionID)
        try await waitUntil("the feed loads") { feed.loaded }
        try await Task.sleep(for: .milliseconds(800))

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Double(environment["WARREN_CONVERSATION_WIDTH"] ?? "") ?? 960,
                height: Double(environment["WARREN_CONVERSATION_HEIGHT"] ?? "") ?? 760
            ),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let light = environment["WARREN_CONVERSATION_APPEARANCE"] == "light"
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let hosting = NSHostingView(
            rootView: WarrenConversationSurface(sessionID: sessionID, model: model)
                .environment(\.colorScheme, light ? .light : .dark)
        )
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        window.orderFrontRegardless()
        try await render(hosting, to: "\(imagePrefix)-open.png")

        if let setting = environment["WARREN_CONVERSATION_CONFIG"], let equals = setting.firstIndex(of: "=") {
            let id = String(setting[..<equals])
            let value = String(setting[setting.index(after: equals)...])
            try await model.setConversationConfig(id, value: value, in: sessionID)
            try await waitUntil("the selector changes") {
                feed.conversation.config.first { $0.id == id }?.currentValue == value
            }
            try await render(hosting, to: "\(imagePrefix)-config.png")
        }

        if let prompt = environment["WARREN_CONVERSATION_PROMPT"] {
            let before = feed.conversation.turns.count
            _ = try await model.sendConversationMessage(prompt, to: sessionID)
            try await waitUntil("the turn starts", timeout: .seconds(20)) { feed.conversation.turns.count > before }
            try await Task.sleep(for: .milliseconds(600))
            try await render(hosting, to: "\(imagePrefix)-running.png")
            try await Task.sleep(for: .milliseconds(2600))
            if feed.conversation.turns.last?.status == .running {
                try await render(hosting, to: "\(imagePrefix)-live.png")
            }
            if let followUp = environment["WARREN_CONVERSATION_QUEUE"] {
                // A follow-up written while the turn runs waits in the queue
                // and goes out on its own once the Agent is ready.
                model.queueConversationPrompt(followUp, in: feed)
                XCTAssertEqual(feed.queuedPrompts.map(\.text), [followUp])
                try await Task.sleep(for: .milliseconds(300))
                try await render(hosting, to: "\(imagePrefix)-queued.png")
                try await waitUntil("the queued follow-up is sent", timeout: .seconds(120)) {
                    feed.conversation.turns.contains { $0.prompt == followUp }
                }
                XCTAssertTrue(feed.queuedPrompts.isEmpty)
            }
            try await waitUntil("the turn ends or asks", timeout: .seconds(90)) {
                !feed.conversation.decisions.isEmpty
                    || (feed.conversation.turns.last.map { $0.status != .running } ?? false)
            }
            try await Task.sleep(for: .milliseconds(600))
            try await render(hosting, to: "\(imagePrefix)-after.png")
            if let decision = feed.conversation.decisions.first, let option = decision.options.first {
                try await model.resolveConversationDecision(decision, optionID: option.id, in: sessionID)
                try await waitUntil("the decision resolves", timeout: .seconds(30)) {
                    feed.conversation.decisions.isEmpty
                        && (feed.conversation.turns.last.map { $0.status != .running } ?? false)
                }
                try await Task.sleep(for: .milliseconds(600))
                try await render(hosting, to: "\(imagePrefix)-resolved.png")
            }
            // A fresh mount opens at the bottom, so the new turn is in view.
            let fresh = NSHostingView(
                rootView: WarrenConversationSurface(sessionID: sessionID, model: model)
                    .environment(\.colorScheme, light ? .light : .dark)
            )
            fresh.frame = window.contentLayoutRect
            window.contentView = fresh
            try await Task.sleep(for: .milliseconds(600))
            try await render(fresh, to: "\(imagePrefix)-latest.png")
        }
        window.orderOut(nil)
    }

    @MainActor
    private func render(_ view: NSView, to path: String) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: path))
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(15),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting until \(description)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
