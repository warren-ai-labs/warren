import Foundation
import XCTest
@testable import WarrenTerminalRenderer
import WarrenDomain
import WarrenProtocol
import WarrenClientCore

final class WarrenTerminalRendererTests: XCTestCase {
    func testEmberPaletteMatchesSupersetDefaultDarkTheme() {
        XCTAssertEqual(TerminalPalette.ember.count, 16)
        XCTAssertEqual(TerminalPalette.ember[0], TerminalPaletteColor(red: 0x15, green: 0x11, blue: 0x10))
        XCTAssertEqual(TerminalPalette.ember[1], TerminalPaletteColor(red: 0xdc, green: 0x6b, blue: 0x6b))
        XCTAssertEqual(TerminalPalette.ember[8], TerminalPaletteColor(red: 0x5c, green: 0x58, blue: 0x56))
        XCTAssertEqual(TerminalPalette.ember[15], TerminalPaletteColor(red: 0xff, green: 0xff, blue: 0xff))
    }

    func testEmberPaperPaletteMatchesSupersetDefaultLightTheme() {
        XCTAssertEqual(TerminalPalette.emberPaper.count, 16)
        XCTAssertEqual(TerminalPalette.emberPaper[0], TerminalPaletteColor(red: 0x2e, green: 0x34, blue: 0x36))
        XCTAssertEqual(TerminalPalette.emberPaper[1], TerminalPaletteColor(red: 0xcc, green: 0x00, blue: 0x00))
        XCTAssertEqual(TerminalPalette.emberPaper[2], TerminalPaletteColor(red: 0x4e, green: 0x9a, blue: 0x06))
        XCTAssertEqual(TerminalPalette.emberPaper[3], TerminalPaletteColor(red: 0xc4, green: 0xa0, blue: 0x00))
        XCTAssertEqual(TerminalPalette.emberPaper[4], TerminalPaletteColor(red: 0x34, green: 0x65, blue: 0xa4))
        XCTAssertEqual(TerminalPalette.emberPaper[5], TerminalPaletteColor(red: 0x75, green: 0x50, blue: 0x7b))
        XCTAssertEqual(TerminalPalette.emberPaper[6], TerminalPaletteColor(red: 0x06, green: 0x98, blue: 0x9a))
        XCTAssertEqual(TerminalPalette.emberPaper[7], TerminalPaletteColor(red: 0xd3, green: 0xd7, blue: 0xcf))
        XCTAssertEqual(TerminalPalette.emberPaper[8], TerminalPaletteColor(red: 0x55, green: 0x57, blue: 0x53))
        XCTAssertEqual(TerminalPalette.emberPaper[9], TerminalPaletteColor(red: 0xef, green: 0x29, blue: 0x29))
        XCTAssertEqual(TerminalPalette.emberPaper[10], TerminalPaletteColor(red: 0x8a, green: 0xe2, blue: 0x34))
        XCTAssertEqual(TerminalPalette.emberPaper[11], TerminalPaletteColor(red: 0xfc, green: 0xe9, blue: 0x4f))
        XCTAssertEqual(TerminalPalette.emberPaper[12], TerminalPaletteColor(red: 0x72, green: 0x9f, blue: 0xcf))
        XCTAssertEqual(TerminalPalette.emberPaper[13], TerminalPaletteColor(red: 0xad, green: 0x7f, blue: 0xa8))
        XCTAssertEqual(TerminalPalette.emberPaper[14], TerminalPaletteColor(red: 0x34, green: 0xe2, blue: 0xe2))
        XCTAssertEqual(TerminalPalette.emberPaper[15], TerminalPaletteColor(red: 0xee, green: 0xee, blue: 0xec))

        let white = TerminalPaletteColor(red: 0xff, green: 0xff, blue: 0xff)

        // Slot 8 carries TUI secondary text and stays legible on paper (> 4.5:1)
        // while remaining quieter than slot 0.
        XCTAssertGreaterThan(
            Self.contrastRatio(TerminalPalette.emberPaper[8], white), 4.5,
            "slot 8 carries TUI secondary text and must stay legible on paper"
        )
        XCTAssertGreaterThan(
            Self.luminance(TerminalPalette.emberPaper[8]),
            Self.luminance(TerminalPalette.emberPaper[0])
        )

        // Bright stays the lighter half
        for (normal, bright) in [(1, 9), (2, 10), (3, 11), (4, 12), (5, 13), (6, 14)] {
            let normalLuminance = Self.luminance(TerminalPalette.emberPaper[normal])
            let brightLuminance = Self.luminance(TerminalPalette.emberPaper[bright])
            XCTAssertGreaterThan(
                brightLuminance, normalLuminance,
                "Ember Paper slot \(bright) must stay lighter than \(normal)"
            )
            XCTAssertNotEqual(
                TerminalPalette.emberPaper[bright],
                TerminalPalette.emberPaper[normal],
                "a program using both halves needs two distinguishable colors"
            )
        }
    }

    private static func luminance(_ color: TerminalPaletteColor) -> Double {
        func linear(_ channel: UInt8) -> Double {
            let value = Double(channel) / 255
            return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    private static func contrastRatio(
        _ first: TerminalPaletteColor,
        _ second: TerminalPaletteColor
    ) -> Double {
        let lighter = max(luminance(first), luminance(second))
        let darker = min(luminance(first), luminance(second))
        return (lighter + 0.05) / (darker + 0.05)
    }

    func testOutputMustBeStrictlyOrdered() async throws {
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(
            sessionID: sessionID,
            clientID: ClientID()
        )
        let viewport = try XCTUnwrap(TerminalViewport(columns: 80, rows: 24))
        let renderer = InMemoryTerminalRenderer()
        let surface = try await renderer.createSurface(
            for: attachment,
            viewport: viewport,
            anchor: RecoveryAnchor(epoch: 3, sequence: 0)
        )

        try await renderer.render(try frame(sessionID: sessionID, epoch: 3, sequence: 0, bytes: [65]), on: surface)
        try await renderer.render(try frame(sessionID: sessionID, epoch: 3, sequence: 1, bytes: [66, 67]), on: surface)

        do {
            try await renderer.render(
                try frame(sessionID: sessionID, epoch: 3, sequence: 4, bytes: [68]),
                on: surface
            )
            XCTFail("Out-of-order output must be rejected")
        } catch {
            XCTAssertEqual(
                error as? TerminalRendererError,
                .outputOutOfOrder(expected: 3, received: 4)
            )
        }

        let state = try await state(of: surface, from: renderer)
        XCTAssertEqual(state.outputs, [Data([65]), Data([66, 67])])
        XCTAssertTrue(state.needsReanchor)
    }

    func testEpochMismatchRequiresExplicitReanchor() async throws {
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: ClientID())
        let viewport = try XCTUnwrap(TerminalViewport(columns: 100, rows: 30))
        let renderer = InMemoryTerminalRenderer()
        let surface = try await renderer.createSurface(
            for: attachment,
            viewport: viewport,
            anchor: RecoveryAnchor(epoch: 1, sequence: 7)
        )

        do {
            try await renderer.render(
                try frame(sessionID: sessionID, epoch: 2, sequence: 0, bytes: [88]),
                on: surface
            )
            XCTFail("An epoch change must require reanchor")
        } catch {
            XCTAssertEqual(
                error as? TerminalRendererError,
                .outputEpochMismatch(expected: 1, received: 2)
            )
        }

        do {
            try await renderer.render(
                try frame(sessionID: sessionID, epoch: 1, sequence: 7, bytes: [89]),
                on: surface
            )
            XCTFail("Frames must remain blocked until reanchor")
        } catch {
            XCTAssertEqual(error as? TerminalRendererError, .reanchorRequired(surface.id))
        }

        try await renderer.reanchor(RecoveryAnchor(epoch: 2, sequence: 0), on: surface)
        try await renderer.render(try frame(sessionID: sessionID, epoch: 2, sequence: 0, bytes: [90]), on: surface)

        let state = try await state(of: surface, from: renderer)
        XCTAssertEqual(state.expectedAnchor, RecoveryAnchor(epoch: 2, sequence: 1))
        XCTAssertFalse(state.needsReanchor)
        XCTAssertEqual(state.reanchors, [RecoveryAnchor(epoch: 2, sequence: 0)])
    }

    func testInputEventsMapToTerminalBytes() async throws {
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: ClientID())
        let viewport = try XCTUnwrap(TerminalViewport(columns: 80, rows: 24))
        let renderer = InMemoryTerminalRenderer()
        let surface = try await renderer.createSurface(for: attachment, viewport: viewport)

        try await renderer.send(.text("hi"), to: surface)
        try await renderer.send(.bytes(Data([0xF0, 0x9F])), to: surface)
        try await renderer.send(.escape, to: surface)
        try await renderer.send(.control("c"), to: surface)
        try await renderer.send(.tab, to: surface)
        try await renderer.send(.arrow(.up), to: surface)
        try await renderer.send(.arrow(.left), to: surface)

        let state = try await state(of: surface, from: renderer)
        XCTAssertEqual(
            state.inputs,
            [
                Data([0x68, 0x69]),
                Data([0xF0, 0x9F]),
                Data([0x1B]),
                Data([0x03]),
                Data([0x09]),
                Data([0x1B, 0x5B, 0x41]),
                Data([0x1B, 0x5B, 0x44]),
            ]
        )
    }

    func testDisposeOnlyDestroysSurface() async throws {
        let sessionID = TerminalSessionID()
        let attachment = TerminalAttachment(sessionID: sessionID, clientID: ClientID())
        let otherSessionID = TerminalSessionID()
        let otherAttachment = TerminalAttachment(sessionID: otherSessionID, clientID: ClientID())
        let viewport = try XCTUnwrap(TerminalViewport(columns: 80, rows: 24))
        let renderer = InMemoryTerminalRenderer()
        let surface = try await renderer.createSurface(for: attachment, viewport: viewport)
        let otherSurface = try await renderer.createSurface(for: otherAttachment, viewport: viewport)

        await renderer.dispose(surface)

        let events = await renderer.events()
        XCTAssertEqual(events, [.dispose(surface.id)])
        let otherState = try await state(of: otherSurface, from: renderer)
        XCTAssertEqual(otherState.surface.sessionID, otherSessionID)
        do {
            try await renderer.send(.text("disposed"), to: surface)
            XCTFail("A disposed surface must reject further operations")
        } catch {
            XCTAssertEqual(error as? TerminalRendererError, .surfaceDisposed(surface.id))
        }
    }

    private func frame(
        sessionID: TerminalSessionID,
        epoch: UInt64,
        sequence: UInt64,
        bytes: [UInt8]
    ) throws -> BinaryOutputFrame {
        let header = try XCTUnwrap(
            BinaryOutputFrameHeader(
                sessionID: sessionID,
                epoch: epoch,
                sequence: sequence,
                payloadLength: bytes.count
            )
        )
        return BinaryOutputFrame(header: header, payload: Data(bytes))
    }

    private func state(
        of surface: TerminalSurface,
        from renderer: InMemoryTerminalRenderer
    ) async throws -> InMemoryTerminalRenderer.SurfaceState {
        let value = await renderer.state(for: surface)
        return try XCTUnwrap(value)
    }
}
