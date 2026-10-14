import AVFoundation
import MochiKernel

@MainActor protocol HandsFreeAudioDevice: AnyObject {
    func start() throws -> AsyncThrowingStream<Data, Error>
    func makePlayer(finished: @escaping @MainActor (Bool) -> Void) throws -> any StreamingPlaybackPlayer
    func stop()
}

/// One engine carries both sides of the conversation, so voice processing has the speaker signal as its echo reference.
@MainActor final class HandsFreeAudio: HandsFreeAudioDevice {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var observer: NSObjectProtocol?
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var tapped = false
    private var started = false
    private var outputID = UUID()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    func start() throws -> AsyncThrowingStream<Data, Error> {
        let input = engine.inputNode
        // Fail explicitly if echo cancellation is unavailable; never open an unprocessed microphone as a fallback.
        try input.setVoiceProcessingEnabled(true)
        guard input.isVoiceProcessingEnabled else {
            throw AppFailure("Echo cancellation is unavailable. Check your audio devices and try again.")
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AppFailure("The microphone is unavailable. Check your audio input and try again.")
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        var sink: AsyncThrowingStream<Data, Error>.Continuation!
        let stream = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(100)) { sink = $0 }
        let continuation = sink!
        self.continuation = continuation
        let capture = try HandsFreePCMConverter(format: inputFormat, continuation: continuation)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in capture.receive(buffer) }
        tapped = true
        engine.prepare()
        do { try engine.start() } catch {
            stop()
            throw error
        }
        started = true
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.started, !self.engine.isRunning else { return }
                continuation.finish(
                    throwing: AppFailure("The audio device changed. Start continuous conversation again."))
            }
        }
        return stream
    }
    func makePlayer(finished: @escaping @MainActor (Bool) -> Void) throws -> any StreamingPlaybackPlayer {
        guard started, engine.isRunning else { throw AppFailure("Continuous conversation audio is no longer active.") }
        node.stop()
        outputID = UUID()
        return HandsFreePlayer(owner: self, id: outputID, format: format, finished: finished)
    }
    fileprivate func valid(_ id: UUID) -> Bool { started && engine.isRunning && outputID == id }
    fileprivate func play(_ id: UUID) -> Bool {
        guard valid(id) else { return false }
        node.play()
        return true
    }
    fileprivate func pause(_ id: UUID) { if valid(id) { node.pause() } }
    fileprivate func stopOutput(_ id: UUID) {
        if valid(id) {
            node.stop()
            outputID = UUID()
        }
    }
    fileprivate func time(_ id: UUID) -> Int64? {
        guard valid(id), let time = node.lastRenderTime else { return nil }
        return node.playerTime(forNodeTime: time)?.sampleTime
    }
    fileprivate func schedule(_ buffer: AVAudioPCMBuffer, id: UUID, played: @escaping @Sendable () -> Void) throws {
        guard valid(id) else { throw AppFailure("Continuous conversation audio is no longer active.") }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in played() }
    }
    func stop() {
        started = false
        outputID = UUID()
        continuation?.finish()
        continuation = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        node.stop()
        engine.stop()
    }
}

/// Conversion runs on one serial queue, away from the capture callback. A bounded stream fails rather than losing speech.
final class HandsFreePCMConverter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Mochi.hands-free-input", qos: .userInitiated)
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var queued = 0
    init(format input: AVAudioFormat, continuation: AsyncThrowingStream<Data, Error>.Continuation) throws {
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true),
            let converter = AVAudioConverter(from: input, to: format)
        else { throw AppFailure("The microphone audio format is unsupported.") }
        self.format = format
        self.converter = converter
        self.continuation = continuation
    }
    func receive(_ source: AVAudioPCMBuffer) {
        guard source.frameLength > 0 else { return }
        lock.lock()
        guard queued < 100 else {
            lock.unlock()
            continuation.finish(throwing: AppFailure("Audio capture fell behind. Start continuous conversation again."))
            return
        }
        queued += 1
        lock.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            didConvert()
            continuation.finish(throwing: AppFailure("The microphone audio could not be converted."))
            return
        }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in from.indices {
            if let src = from[index].mData, let dst = to[index].mData {
                memcpy(dst, src, Int(min(from[index].mDataByteSize, to[index].mDataByteSize)))
            }
        }
        queue.async {
            defer { self.didConvert() }
            self.convert(copy)
        }
    }
    private func didConvert() {
        lock.lock()
        queued -= 1
        lock.unlock()
    }
    private func convert(_ source: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * 24000 / source.format.sampleRate) + 32)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            continuation.finish(throwing: AppFailure("The microphone audio could not be converted."))
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return source
        }
        if status == .error {
            continuation.finish(throwing: AppFailure("The microphone audio could not be converted.", underlying: error))
            return
        }
        guard output.frameLength > 0, let bytes = output.int16ChannelData?[0] else { return }
        if case .dropped = continuation.yield(Data(bytes: bytes, count: Int(output.frameLength) * 2)) {
            continuation.finish(throwing: AppFailure("Audio capture fell behind. Start continuous conversation again."))
        }
    }
}

/// Stopping a reply stops only the speaker node; the microphone and its echo canceller stay running.
@MainActor private final class HandsFreePlayer: StreamingPlaybackPlayer {
    private weak var owner: HandsFreeAudio?
    private let id: UUID
    private let format: AVAudioFormat
    private var decoder = StreamingPCMDecoder()
    private var frames: Int64 = 0
    private var playedFrames: Int64 = 0
    private var ended = false
    private var cancelled = false
    private var finished: (@MainActor (Bool) -> Void)?
    var enableRate = false
    var rate: Float = 1
    var duration: TimeInterval { Double(frames) / 24000 }
    var currentTime: TimeInterval {
        get { Double(min(frames, max(playedFrames, owner?.time(id) ?? playedFrames))) / 24000 }
        set {}
    }
    init(owner: HandsFreeAudio, id: UUID, format: AVAudioFormat, finished: @escaping @MainActor (Bool) -> Void) {
        self.owner = owner
        self.id = id
        self.format = format
        self.finished = finished
    }
    func play() -> Bool { owner?.play(id) == true }
    func pause() { owner?.pause(id) }
    func stop() {
        cancelled = true
        finished = nil
        owner?.stopOutput(id)
    }
    func appendPCM(_ data: Data) throws {
        let samples = decoder.decode(data)
        guard !samples.isEmpty else { return }
        guard !cancelled, !ended, let owner,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { throw AppFailure("Continuous conversation audio is no longer active.") }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices { channel[index] = samples[index] }
        let count = Int64(samples.count)
        frames += count
        try owner.schedule(buffer, id: id) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.cancelled else { return }
                self.playedFrames += count
                self.complete()
            }
        }
    }
    func finishInput() throws {
        try decoder.finish()
        ended = true
        complete()
    }
    private func complete() {
        guard ended, !cancelled, playedFrames >= frames else { return }
        let callback = finished
        finished = nil
        callback?(true)
    }
}
