import AVFoundation
import MochiKernel

@MainActor protocol StreamingPlaybackPlayer: PlaybackPlayer {
    func appendPCM(_ data: Data) throws
    func finishInput() throws
}

/// Handles 16-bit mono PCM chunks even when a network chunk splits a sample in half.
struct StreamingPCMDecoder {
    private var trailingByte: UInt8?
    mutating func decode(_ data: Data) -> [Float] {
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count + 1)
        if let trailingByte { bytes.append(trailingByte) }
        bytes.append(contentsOf: data)
        let count = bytes.count / 2
        trailingByte = bytes.count % 2 == 0 ? nil : bytes.last
        return (0..<count).map { index in
            let value = UInt16(bytes[index * 2]) | (UInt16(bytes[index * 2 + 1]) << 8)
            return Float(Int16(bitPattern: value)) / 32768
        }
    }
    func finish() throws {
        guard trailingByte == nil else { throw AppFailure("Mochi's response audio arrived damaged. Please retry.") }
    }
}

/// Schedules audio as soon as it arrives; an empty queue between chunks is not the end of a reply.
@MainActor final class StreamingAudioPlayer: StreamingPlaybackPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let speed = AVAudioUnitTimePitch()
    private let format: AVAudioFormat
    private var decoder = StreamingPCMDecoder()
    private var frames: Int64 = 0
    private var playedFrames: Int64 = 0
    private var inputFinished = false
    private var epoch = UUID()
    private var completion: (@MainActor (Bool) -> Void)?
    var enableRate = false
    var rate: Float = 1 { didSet { speed.rate = rate } }
    var duration: TimeInterval { Double(frames) / 24000 }
    var currentTime: TimeInterval {
        get {
            let rendered = node.lastRenderTime.flatMap { node.playerTime(forNodeTime: $0) }?.sampleTime ?? playedFrames
            return Double(min(frames, max(playedFrames, rendered))) / 24000
        }
        set {}  // Seeking becomes available on the complete saved recording, after streaming ends.
    }
    init(finished: @escaping @MainActor (Bool) -> Void) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
        else { throw AppFailure("Streaming audio could not be prepared.") }
        self.format = format
        completion = finished
        engine.attach(node)
        engine.attach(speed)
        engine.connect(node, to: speed, format: format)
        engine.connect(speed, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }
    func play() -> Bool {
        guard engine.isRunning else { return false }
        node.play()
        return true
    }
    func pause() { node.pause() }
    func stop() {
        epoch = UUID()
        completion = nil
        node.stop()
        engine.stop()
    }
    func appendPCM(_ data: Data) throws {
        guard !inputFinished else { throw AppFailure("Streaming audio has already finished.") }
        let samples = decoder.decode(data)
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw AppFailure("Streaming audio could not be prepared.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices { channel[index] = samples[index] }
        let count = Int64(samples.count)
        frames += count
        let token = epoch
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.epoch == token else { return }
                self.playedFrames += count
                self.completeIfDrained()
            }
        }
    }
    func finishInput() throws {
        try decoder.finish()
        inputFinished = true
        completeIfDrained()
    }
    private func completeIfDrained() {
        guard inputFinished, playedFrames >= frames else { return }
        let finished = completion
        completion = nil
        node.stop()
        engine.stop()
        finished?(true)
    }
}
