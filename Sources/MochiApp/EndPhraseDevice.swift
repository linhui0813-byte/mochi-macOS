import AVFoundation
import CoreMedia
import MochiCore
import MochiKernel
import Speech

@MainActor protocol EndPhraseDevice: AnyObject {
    func start(matched: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void)
    func beginTurn()
    func endTurn()
    func append(_ pcm: Data) throws
    func stop()
}

/// Local recognition only. It reuses Mochi's echo-cancelled samples and never opens another microphone.
@available(macOS 26, *)
@MainActor final class LocalEndPhraseDevice: EndPhraseDevice {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let format: AVAudioFormat
    private let sourceFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var window: EndPhraseRecognitionWindow
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var sampleTime: Int64 = 0
    private var stopped = false
    static func prepare(_ phrase: EndTurnPhrase) async throws -> LocalEndPhraseDevice {
        TestEnvironment.assertNotUnderTest("Local end-of-turn recognition")
        guard SpeechTranscriber.isAvailable,
            let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        else { throw AppFailure("Local English speech recognition is unavailable. Pause detection still works.") }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: source, to: format)
        else { throw AppFailure("Local English speech recognition is unavailable. Pause detection still works.") }
        converter.primeMethod = .none
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.prepareToAnalyze(in: format)
            try Task.checkCancellation()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return LocalEndPhraseDevice(
            phrase: phrase, transcriber: transcriber, analyzer: analyzer, format: format, source: source,
            converter: converter)
    }
    private init(
        phrase: EndTurnPhrase, transcriber: SpeechTranscriber, analyzer: SpeechAnalyzer,
        format: AVAudioFormat, source: AVAudioFormat, converter: AVAudioConverter
    ) {
        window = EndPhraseRecognitionWindow(phrase: phrase)
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.format = format
        sourceFormat = source
        self.converter = converter
    }
    func start(matched: @escaping @MainActor () -> Void, failed: @escaping @MainActor (Error) -> Void) {
        let (stream, sink) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(100))
        input = sink
        analysisTask = Task { [weak self, analyzer] in
            do { try await analyzer.start(inputSequence: stream) } catch {
                if let self, !self.stopped, !Task.isCancelled { failed(error) }
            }
        }
        resultsTask = Task { [weak self, transcriber] in
            do {
                for try await result in transcriber.results {
                    guard let self, !self.stopped, !Task.isCancelled else { return }
                    if self.window.accept(
                        text: String(result.text.characters), isFinal: result.isFinal,
                        endingAt: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)))
                    {
                        matched()
                    }
                }
            } catch { if let self, !self.stopped, !Task.isCancelled { failed(error) } }
        }
    }
    func beginTurn() { window.begin(at: max(0, Double(sampleTime) / format.sampleRate - 0.3)) }
    func endTurn() { window.end() }
    func append(_ pcm: Data) throws {
        guard !stopped, let input, !pcm.isEmpty else { return }
        let count = pcm.count / 2
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
            let values = source.floatChannelData?[0]
        else { throw AppFailure("Spoken ending phrase detection stopped. Pause detection still works.") }
        source.frameLength = AVAudioFrameCount(count)
        for index in 0..<count {
            values[index] = Float(Int16(bitPattern: UInt16(pcm[index * 2]) | UInt16(pcm[index * 2 + 1]) << 8)) / 32768
        }
        let capacity = AVAudioFrameCount(ceil(Double(count) * format.sampleRate / 24000) + 16)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw AppFailure("Spoken ending phrase detection stopped. Pause detection still works.")
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        if result == .error {
            if let error { throw error }
            throw AppFailure("Spoken ending phrase detection stopped. Pause detection still works.")
        }
        guard output.frameLength > 0 else { return }
        let time = CMTime(value: sampleTime, timescale: CMTimeScale(format.sampleRate))
        sampleTime += Int64(output.frameLength)
        if case .dropped = input.yield(AnalyzerInput(buffer: output, bufferStartTime: time)) {
            throw AppFailure("Spoken ending phrase detection stopped. Pause detection still works.")
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        window.end()
        input?.finish()
        input = nil
        analysisTask?.cancel()
        resultsTask?.cancel()
        analysisTask = nil
        resultsTask = nil
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
    }
}
