import AppKit
import Foundation
import WarrenDomain

/// Plays the short completion chime used for completed Agent turns. The
/// preference is client-local, so one desktop can stay quiet without changing
/// another client connected to the same Host.
@MainActor
public enum WarrenDesktopNotificationSound {
    private static var activeSound: NSSound?

    public static func isAgentCompletionSoundEnabled(
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard let value = defaults.object(forKey: WarrenPreferenceKey.agentCompletionSoundEnabled)
            as? Bool else {
            return true
        }
        return value
    }

    public static func playAgentCompletionSoundIfEnabled(
        defaults: UserDefaults = .standard
    ) {
        playAgentCompletionSoundIfEnabled(defaults: defaults, play: playCompletionSound)
    }

    public static func playAgentCompletionSoundIfEnabled(
        defaults: UserDefaults = .standard,
        play: () -> Void
    ) {
        guard isAgentCompletionSoundEnabled(defaults: defaults) else { return }
        play()
    }

    private static func playCompletionSound() {
        guard let sound = NSSound(data: completionSoundData) else {
            NSSound.beep()
            return
        }
        // Keep the sound alive while NSSound plays asynchronously.
        activeSound = sound
        sound.play()
    }

    private static let completionSoundData = makeCompletionSoundData()

    private static func makeCompletionSoundData() -> Data {
        let sampleRate = 44_100.0
        let notes: [(frequency: Double, start: Double, duration: Double, level: Double)] = [
            (523.25, 0, 0.24, 0.22),
            (659.25, 0.1, 0.3, 0.2),
            (783.99, 0.21, 0.46, 0.18),
        ]
        let totalDuration = 0.72
        let frameCount = Int((totalDuration * sampleRate).rounded(.up))
        var pcm = Data(capacity: frameCount * MemoryLayout<Int16>.size)

        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            var sample = 0.0

            for note in notes {
                let elapsed = time - note.start
                guard elapsed >= 0, elapsed <= note.duration else { continue }

                let attack = 0.018
                let envelope: Double
                if elapsed < attack {
                    envelope = elapsed / attack
                } else {
                    envelope = exp(-5.5 * (elapsed - attack) / note.duration)
                }

                let phase = 2 * Double.pi * note.frequency * elapsed
                let chime = sin(phase) * 0.84 + sin(phase * 2) * 0.16
                sample += note.level * envelope * chime
            }

            let value = Int16((max(-1.0, min(1.0, sample)) * Double(Int16.max)).rounded())
            appendLittleEndian(value, to: &pcm)
        }

        var data = Data(capacity: 44 + pcm.count)
        data.append(contentsOf: Data("RIFF".utf8))
        appendLittleEndian(UInt32(36 + pcm.count), to: &data)
        data.append(contentsOf: Data("WAVE".utf8))
        data.append(contentsOf: Data("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data) // PCM
        appendLittleEndian(UInt16(1), to: &data) // mono
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * 2), to: &data) // byte rate
        appendLittleEndian(UInt16(2), to: &data) // block alignment
        appendLittleEndian(UInt16(16), to: &data) // bits per sample
        data.append(contentsOf: Data("data".utf8))
        appendLittleEndian(UInt32(pcm.count), to: &data)
        data.append(contentsOf: pcm)
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndianValue = value.littleEndian
        withUnsafeBytes(of: &littleEndianValue) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
