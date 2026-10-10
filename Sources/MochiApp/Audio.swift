import Foundation
import AVFoundation
import MochiCore
import MochiKernel

protocol PlaybackPlayer: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get set }
    var enableRate: Bool { get set }
    var rate: Float { get set }
    func play() -> Bool
    func pause()
    func stop()
}
extension AVAudioPlayer: PlaybackPlayer {}

@MainActor @Observable final class AudioController: NSObject, AVAudioPlayerDelegate, AVAudioRecorderDelegate {
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var paused = false
    @ObservationIgnored private var playbackClock: Task<Void,Never>?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var player: (any PlaybackPlayer)?
    @ObservationIgnored var makePlayer: (URL) throws -> any PlaybackPlayer = { try AVAudioPlayer(contentsOf:$0) }
    @ObservationIgnored private var completion: (() -> Void)?
    @ObservationIgnored private var failure: (() -> Void)?
    /// Set when the recorder reports an error or the microphone it started on disconnects.
    @ObservationIgnored private(set) var recordingInterrupted = false
    @ObservationIgnored private var recordingDevice: String?
    @ObservationIgnored private var disconnectObserver: NSObjectProtocol?
    /// False once recording ends for any reason other than `stopRecording()`.
    var isRecording: Bool { recorder?.isRecording == true && !recordingInterrupted }
    var meter: Float { recorder?.updateMeters(); return recorder?.averagePower(forChannel:0) ?? -80 }
    func permission() async -> Bool {
        if AVCaptureDevice.authorizationStatus(for:.audio) == .authorized { return true }
        return await AVCaptureDevice.requestAccess(for:.audio)
    }
    func record(to url: URL, maxDuration: Double = 60) throws {
        stop()
        let r = try AVAudioRecorder(url:url,settings:[AVFormatIDKey:kAudioFormatLinearPCM,AVSampleRateKey:24000,AVNumberOfChannelsKey:1,AVLinearPCMBitDepthKey:16,AVLinearPCMIsFloatKey:false,AVLinearPCMIsBigEndianKey:false])
        r.isMeteringEnabled = true; r.delegate = self
        guard r.record(forDuration:maxDuration) else { throw AppFailure("Could not start the microphone. Check Sound settings and retry.") }
        recorder = r; recordingInterrupted = false
        recordingDevice = AVCaptureDevice.default(for:.audio)?.uniqueID
        disconnectObserver = NotificationCenter.default.addObserver(forName:AVCaptureDevice.wasDisconnectedNotification,object:nil,queue:.main) { [weak self] note in
            let id = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { self?.deviceDisconnected(id) }
        }
    }
    private func deviceDisconnected(_ id: String?) {
        // Only the microphone this recording started on matters; unplugging another device does not.
        guard recorder != nil, let id, id == recordingDevice else { return }
        MochiLog.audio.notice("The recording microphone disconnected")
        recordingInterrupted = true
    }
    func stopRecording() -> URL? {
        let url = recorder?.url; recorder?.stop(); recorder = nil
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        disconnectObserver = nil; recordingDevice = nil
        return url
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard self.recorder === recorder else { return }
            if let error { MochiLog.failure(MochiLog.audio,"Recording encode error",error) }
            self.recordingInterrupted = true
        }
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard self.recorder === recorder, !flag else { return }
            MochiLog.audio.notice("The recorder stopped unsuccessfully")
            self.recordingInterrupted = true
        }
    }
    func play(url: URL, rate: Float = 1, failed: (() -> Void)? = nil, completed: @escaping () -> Void) throws {
        stop()
        let p = try makePlayer(url); (p as? AVAudioPlayer)?.delegate = self; p.enableRate = true; p.rate = rate; completion = completed; failure = failed; player = p
        guard p.play() else { stop(); throw AppFailure("This audio file could not be played.") }
        duration = p.duration; paused = false
        playbackClock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
                do { try await Task.sleep(nanoseconds:100_000_000) } catch { return }
            }
        }
    }
    func togglePause() {
        guard let player else { return }
        if paused {
            guard player.play() else { let callback = failure ?? completion; stop(); callback?(); return }
            paused = false
        } else { player.pause(); position = player.currentTime; paused = true }
    }
    func seek(to seconds: Double) {
        guard let player, seconds.isFinite else { return }
        player.currentTime = min(max(0,seconds),player.duration)
        position = player.currentTime
    }
    private func resetPlayback() {
        playbackClock?.cancel(); playbackClock = nil
        position = 0; duration = 0; paused = false
    }
    func stop() { resetPlayback(); _ = stopRecording(); player?.stop(); player = nil; completion = nil; failure = nil }
    func finishPlayback(_ player: any PlaybackPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        let callback = flag ? completion : (failure ?? completion)
        completion = nil; failure = nil; self.player = nil; resetPlayback(); callback?()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.finishPlayback(player,successfully:flag) }
    }
    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in self.finishPlayback(player,successfully:false) }
    }
}
enum AudioFile {
    /// Decodes a whole file to mono samples. One `read(into:)` can stop short of the end, so reading
    /// continues until the file is exhausted; for uncompressed audio the decoded length must match exactly.
    static func samples(_ url: URL, maxDuration: Double = 65) throws -> (samples:[Float],rate:Double) {
        let file = try AVAudioFile(forReading:url), format = file.processingFormat
        guard file.length > 0, Double(file.length) / format.sampleRate <= maxDuration else { throw AppFailure("Choose a shorter audio clip for this operation.") }
        guard let chunk = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:65536) else { throw AppFailure("Cannot decode this recording.") }
        let channelCount = Int(format.channelCount)
        var samples = [Float](); samples.reserveCapacity(Int(file.length))
        while file.framePosition < file.length {
            try file.read(into:chunk)
            let count = Int(chunk.frameLength)
            guard count > 0 else { break }
            guard let channels = chunk.floatChannelData else { throw AppFailure("Unsupported recording format.") }
            for i in 0..<count {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                samples.append(sum / Float(channelCount))
            }
        }
        if file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatLinearPCM, samples.count != Int(file.length) {
            throw AppFailure("This recording could not be read completely. Record it again.")
        }
        return (samples,format.sampleRate)
    }
    static func pcm(_ url: URL) throws -> Data {
        let (samples,rate) = try samples(url)
        let count = Int(Double(samples.count) * 24000 / rate)
        guard count >= 2400 else { throw AppFailure("That recording was too short. Speak for at least a moment, then finish.") }
        var data = Data(capacity:count*2)
        for i in 0..<count {
            let position = Double(i) * rate / 24000, index = min(Int(position),samples.count-1), next = min(index+1,samples.count-1)
            let fraction = Float(position - Double(index))
            let mixed = samples[index] * (1-fraction) + samples[next] * fraction
            let sample = mixed.isFinite ? mixed : 0
            var value = Int16(max(-32767,min(32767,Int(sample * 32767)))).littleEndian
            withUnsafeBytes(of:&value) { data.append(contentsOf:$0) }
        }
        return data
    }
    static func pitch(_ url: URL) throws -> [PitchPoint] { let (samples,rate) = try samples(url); return PitchAnalyzer.analyze(samples:samples,sampleRate:rate) }
    /// Analyses off the main actor; cancelling the caller stops the analysis instead of letting it run on.
    static func pitchInBackground(_ url: URL) async throws -> [PitchPoint] {
        let work = Task.detached(priority:.userInitiated) { try pitch(url) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
}
