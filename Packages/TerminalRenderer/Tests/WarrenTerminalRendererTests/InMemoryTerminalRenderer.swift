import Foundation
import WarrenDomain
import WarrenClientCore
import WarrenTerminalRenderer

/// Deterministic renderer used by cross-platform tests and previews. It keeps
/// renderer state only; it has no session-kill operation by design.
public actor InMemoryTerminalRenderer: TerminalRenderer {
    public struct SurfaceState: Hashable, Sendable {
        public let surface: TerminalSurface
        public fileprivate(set) var viewport: TerminalViewport
        fileprivate var outputSequence: TerminalOutputSequence
        public fileprivate(set) var focused: Bool
        public fileprivate(set) var outputs: [Data]
        public fileprivate(set) var inputs: [Data]
        public fileprivate(set) var reanchors: [RecoveryAnchor]

        public var expectedAnchor: RecoveryAnchor { outputSequence.expectedAnchor }
        public var needsReanchor: Bool { outputSequence.needsReanchor }

        fileprivate init(
            surface: TerminalSurface,
            viewport: TerminalViewport,
            anchor: RecoveryAnchor
        ) {
            self.surface = surface
            self.viewport = viewport
            self.outputSequence = TerminalOutputSequence(anchor: anchor)
            self.focused = false
            self.outputs = []
            self.inputs = []
            self.reanchors = []
        }
    }

    public enum Event: Hashable, Sendable {
        case output(TerminalSurfaceID, BinaryOutputFrame)
        case resize(TerminalSurfaceID, TerminalViewport)
        case focus(TerminalSurfaceID, Bool)
        case input(TerminalSurfaceID, Data)
        case reanchor(TerminalSurfaceID, RecoveryAnchor)
        case dispose(TerminalSurfaceID)
    }

    private var states: [TerminalSurfaceID: SurfaceState] = [:]
    private var attachmentToSurface: [TerminalAttachmentID: TerminalSurfaceID] = [:]
    private var disposedSurfaceIDs: Set<TerminalSurfaceID> = []
    private var eventLog: [Event] = []

    public init() {}

    public func createSurface(
        for attachment: TerminalAttachment,
        viewport: TerminalViewport,
        anchor: RecoveryAnchor
    ) async throws -> TerminalSurface {
        guard attachmentToSurface[attachment.id] == nil else {
            throw TerminalRendererError.surfaceAlreadyExists(attachment.id)
        }

        let surface = TerminalSurface(attachment: attachment)
        states[surface.id] = SurfaceState(
            surface: surface,
            viewport: viewport,
            anchor: anchor
        )
        attachmentToSurface[attachment.id] = surface.id
        return surface
    }

    public func render(_ output: BinaryOutputFrame, on surface: TerminalSurface) async throws {
        var state = try requireState(for: surface)
        do {
            _ = try state.outputSequence.accept(
                output,
                sessionID: surface.sessionID,
                surfaceID: surface.id
            )
            state.outputs.append(output.payload)
            states[surface.id] = state
            eventLog.append(.output(surface.id, output))
        } catch {
            states[surface.id] = state
            throw error
        }
    }

    public func resize(_ viewport: TerminalViewport, on surface: TerminalSurface) async throws {
        var state = try requireState(for: surface)
        state.viewport = viewport
        states[surface.id] = state
        eventLog.append(.resize(surface.id, viewport))
    }

    public func focus(_ focused: Bool, on surface: TerminalSurface) async throws {
        var state = try requireState(for: surface)
        state.focused = focused
        states[surface.id] = state
        eventLog.append(.focus(surface.id, focused))
    }

    public func send(_ input: TerminalInputEvent, to surface: TerminalSurface) async throws {
        var state = try requireState(for: surface)
        let data: Data
        do {
            data = try input.encodedData()
        } catch let error as TerminalInputEncodingError {
            throw TerminalRendererError.inputEncoding(error)
        }
        state.inputs.append(data)
        states[surface.id] = state
        eventLog.append(.input(surface.id, data))
    }

    public func reanchor(_ anchor: RecoveryAnchor, on surface: TerminalSurface) async throws {
        var state = try requireState(for: surface)
        state.outputSequence.reanchor(anchor)
        state.reanchors.append(anchor)
        states[surface.id] = state
        eventLog.append(.reanchor(surface.id, anchor))
    }

    public func dispose(_ surface: TerminalSurface) async {
        guard let state = states.removeValue(forKey: surface.id) else {
            return
        }
        attachmentToSurface.removeValue(forKey: state.surface.attachmentID)
        disposedSurfaceIDs.insert(surface.id)
        eventLog.append(.dispose(surface.id))
    }

    public func state(for surface: TerminalSurface) -> SurfaceState? {
        states[surface.id]
    }

    public func events() -> [Event] {
        eventLog
    }

    private func requireState(for surface: TerminalSurface) throws -> SurfaceState {
        guard let state = states[surface.id] else {
            if disposedSurfaceIDs.contains(surface.id) {
                throw TerminalRendererError.surfaceDisposed(surface.id)
            }
            throw TerminalRendererError.unknownSurface(surface.id)
        }
        guard state.surface == surface else {
            throw TerminalRendererError.surfaceBindingMismatch(surface.id)
        }
        return state
    }
}
