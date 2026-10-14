import Foundation

/// Finds turns in echo-cancelled 24 kHz mono PCM16. Silence is kept only in a short prefix, never uploaded by itself.
public struct SpeechTurnDetector {
    public enum Event: Equatable {
        case started
        case ended(Data)
    }
    public private(set) var levelDB: Float = -80
    public private(set) var speaking = false
    private var pending = Data()
    private var prefix = Data()
    private var take = Data()
    private var candidateFrames = 0
    private var quietFrames = 0
    private var noiseDB: Float = -65
    public init() {}
    public mutating func accept(_ pcm: Data) -> [Event] {
        pending.append(pcm)
        var events: [Event] = []
        var offset = 0
        // 20 ms frames make timing independent of the audio device's buffer size.
        while offset + 960 <= pending.count {
            let frame = pending.subdata(in: offset..<offset + 960)
            offset += 960
            var energy = 0.0
            frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for index in stride(from: 0, to: bytes.count, by: 2) {
                    let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                    let value = Double(Int16(bitPattern: bits)) / 32768
                    energy += value * value
                }
            }
            levelDB = Float(10 * log10(max(energy / 480, 1e-10)))
            let threshold = max(-47, min(-30, noiseDB + 12))
            let voiced = levelDB >= threshold
            if !speaking {
                prefix.append(frame)
                if prefix.count > 14400 { prefix = Data(prefix.suffix(14400)) }
                if !voiced { noiseDB = 0.96 * noiseDB + 0.04 * max(-80, levelDB) }
                candidateFrames = voiced ? candidateFrames + 1 : max(0, candidateFrames - 1)
                guard candidateFrames >= 6 else { continue }
                speaking = true
                take = prefix
                prefix.removeAll(keepingCapacity: true)
                quietFrames = 0
                events.append(.started)
            } else {
                take.append(frame)
                quietFrames = voiced ? 0 : quietFrames + 1
                if quietFrames >= 55 || take.count >= 2_880_000 {
                    // Keep 240 ms of tail, rather than a whole second of trailing silence.
                    let trim = max(0, quietFrames - 12) * 960
                    let audio = Data(take.prefix(max(0, take.count - trim)))
                    speaking = false
                    candidateFrames = 0
                    quietFrames = 0
                    take.removeAll(keepingCapacity: true)
                    events.append(.ended(audio))
                }
            }
        }
        if offset > 0 { pending = Data(pending.dropFirst(offset)) }
        return events
    }
}
