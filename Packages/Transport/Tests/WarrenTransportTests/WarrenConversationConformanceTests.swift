import XCTest
import Foundation
@testable import WarrenTransport

/// Projects the shared fixture stream the web client also projects
/// (`Web/src/conversation.conformance.test.js`) and asserts the same facts.
///
/// The two folds are independent implementations of RFC 0023 §9. A change that
/// only lands in one of them changes what a person reads on one surface, which
/// no single-language test can see.
final class WarrenConversationConformanceTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Expect: Decodable {
            struct Turn: Decodable {
                let prompt: String
                let answer: String
                let answerComplete: Bool
                let status: String
                let narration: [String]
                let summary: String
                struct File: Decodable {
                    let file: String
                    let additions: Int
                    let deletions: Int
                }
                let files: [File]
                let reasoningCount: Int
            }
            let turns: [Turn]
        }
        let events: [WarrenRemoteAgentEvent]
        let expect: Expect
    }

    func testSharedFixtureProjectsTheSameConversationInSwiftAndWeb() throws {
        let fixture = try loadFixture()
        let conversation = WarrenConversation.project(fixture.events)

        XCTAssertEqual(conversation.turns.count, fixture.expect.turns.count)
        for (turn, expected) in zip(conversation.turns, fixture.expect.turns) {
            XCTAssertEqual(turn.prompt, expected.prompt)
            XCTAssertEqual(turn.answer, expected.answer)
            XCTAssertEqual(turn.answerComplete, expected.answerComplete)
            XCTAssertEqual(turn.status.rawValue, expected.status)
            XCTAssertEqual(turn.narration, expected.narration)
            XCTAssertEqual(turn.summary, expected.summary)
            XCTAssertEqual(turn.reasoning.count, expected.reasoningCount)
            XCTAssertEqual(turn.files.count, expected.files.count)
            for (file, expectedFile) in zip(turn.files, expected.files) {
                XCTAssertEqual(file.file, expectedFile.file)
                XCTAssertEqual(file.additions, expectedFile.additions)
                XCTAssertEqual(file.deletions, expectedFile.deletions)
            }
        }
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(findFixture(named: "conversation-basic.json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    private func findFixture(named name: String) -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory
                .appendingPathComponent("protocol/fixtures/agent")
                .appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
