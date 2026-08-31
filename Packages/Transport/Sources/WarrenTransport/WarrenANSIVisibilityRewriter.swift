import Foundation

/// Rewrites the one ANSI foreground sequence that is invisible on Warren's
/// dark terminal background. The Host remains the source of truth for all
/// terminal state; this is only a renderer-side visibility correction for
/// clients whose renderer does not expose Ghostty's minimum-contrast setting.
///
/// Only the exact semicolon-delimited truecolor foreground tuple
/// `38;2;0;0;0` is changed. Background colors, indexed colors, and every other
/// SGR sequence are passed through byte-for-byte.
public struct WarrenANSIVisibilityRewriter: Sendable {
    private enum State: Sendable {
        case normal
        case escape
        case csi
    }

    private var state: State = .normal
    private var pendingSequence: [UInt8] = []

    public init() {}

    /// Clears a partially received escape sequence. Call this at an atomic
    /// terminal checkpoint boundary before feeding the new replay.
    public mutating func reset() {
        state = .normal
        pendingSequence.removeAll(keepingCapacity: true)
    }

    /// Rewrites a stream chunk while carrying an incomplete CSI sequence into
    /// the next chunk. ANSI sequences are allowed to cross WebSocket frames.
    public mutating func rewrite(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }

        var rewritten = Data()
        rewritten.reserveCapacity(data.count)

        for byte in data {
            switch state {
            case .normal:
                if byte == 0x1B { // ESC
                    pendingSequence = [byte]
                    state = .escape
                } else {
                    rewritten.append(byte)
                }

            case .escape:
                if byte == 0x5B { // [
                    pendingSequence.append(byte)
                    state = .csi
                } else {
                    // It was not a CSI sequence. Preserve the pending ESC and
                    // process the current byte as the beginning of a fresh
                    // sequence or ordinary output.
                    rewritten.append(contentsOf: pendingSequence)
                    pendingSequence.removeAll(keepingCapacity: true)
                    state = .normal
                    if byte == 0x1B {
                        pendingSequence = [byte]
                        state = .escape
                    } else {
                        rewritten.append(byte)
                    }
                }

            case .csi:
                pendingSequence.append(byte)
                if isCSIFinalByte(byte) {
                    if byte == 0x6D { // m (SGR)
                        rewritten.append(contentsOf: rewrittenSGR(pendingSequence))
                    } else {
                        rewritten.append(contentsOf: pendingSequence)
                    }
                    pendingSequence.removeAll(keepingCapacity: true)
                    state = .normal
                } else if pendingSequence.count >= 4096 {
                    // A malformed or unbounded CSI must never retain an
                    // arbitrary amount of PTY output. Preserve it unchanged.
                    rewritten.append(contentsOf: pendingSequence)
                    pendingSequence.removeAll(keepingCapacity: true)
                    state = .normal
                }
            }
        }

        return rewritten
    }

    private func isCSIFinalByte(_ byte: UInt8) -> Bool {
        (0x40 ... 0x7E).contains(byte)
    }

    private func rewrittenSGR(_ sequence: [UInt8]) -> [UInt8] {
        guard sequence.count >= 3,
              sequence.first == 0x1B,
              sequence.dropFirst().first == 0x5B,
              sequence.last == 0x6D else {
            return sequence
        }

        let parameterBytes = sequence.dropFirst(2).dropLast()
        let parameters = String(decoding: parameterBytes, as: UTF8.self)
        var components = parameters.split(separator: ";", omittingEmptySubsequences: false)
            .map(String.init)
        var changed = false
        var index = 0

        while index + 4 < components.count {
            guard components[index] == "38",
                  components[index + 1] == "2",
                  components[index + 2] == "0",
                  components[index + 3] == "0",
                  components[index + 4] == "0" else {
                index += 1
                continue
            }
            components[index + 2] = "234"
            components[index + 3] = "232"
            components[index + 4] = "230"
            changed = true
            index += 5
        }

        guard changed else { return sequence }
        return Array("\u{1B}[\(components.joined(separator: ";"))m".utf8)
    }
}
