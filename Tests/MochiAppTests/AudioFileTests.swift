import AVFoundation
import MochiTestSupport
import XCTest

@testable import MochiApp

/// The converter every voice message passes through before it is sent for a reply.
final class AudioFileTests: XCTestCase {
    private func wav(rate: Double, channels: AVAudioChannelCount = 1, frames: Int, _ sample: (Int, Int) -> Float) throws
        -> URL
    {
        let folder = makeTemporaryFolder()
        let url = folder.appendingPathComponent("clip.wav")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for channel in 0..<Int(channels) {
            for i in 0..<frames { buffer.floatChannelData![channel][i] = sample(channel, i) }
        }
        try file.write(from: buffer)
        return url
    }
    private func value(_ pcm: Data, at index: Int) -> Int16 {
        Int16(littleEndian: pcm.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 2, as: Int16.self) })
    }

    func testStereo48kBecomesMono24kLittleEndianInt16() throws {
        let tone = (0..<48000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48000)) * 0.5 }
        let url = try wav(rate: 48000, channels: 2, frames: 48000) { _, i in tone[i] }
        let pcm = try AudioFile.pcm(url)
        XCTAssertEqual(pcm.count, 24000 * 2)
        // Band-limited resampling keeps an in-band tone intact; samples near the clip edges carry filter ringing.
        for k in [100, 101, 12345, 23899] {
            let expected = sin(2 * Double.pi * 440 * Double(k) / 24000) * 0.5 * 32767
            XCTAssertEqual(Double(value(pcm, at: k)), expected, accuracy: 20, "sample \(k)")
        }
    }
    func testOtherRatesAreResampledToTheRightLength() throws {
        let url = try wav(rate: 44100, frames: 88200) { _, i in Float(i % 100) / 400 }
        XCTAssertEqual(try AudioFile.pcm(url).count, 48000 * 2)
    }
    func testClipsShorterThanATenthOfASecondAreRejected() throws {
        let url = try wav(rate: 24000, frames: 1200) { _, _ in 0.1 }
        XCTAssertThrowsError(try AudioFile.pcm(url)) { XCTAssertTrue($0.localizedDescription.contains("too short")) }
    }
    func testClipsLongerThanTheLimitAreRejected() throws {
        let url = try wav(rate: 8000, frames: 8000 * 66) { _, _ in 0 }
        XCTAssertThrowsError(try AudioFile.pcm(url)) {
            XCTAssertTrue($0.localizedDescription.contains("shorter audio clip"))
        }
    }
    func testInvalidSamplesBecomeSilenceAndLoudOnesAreClamped() throws {
        let url = try wav(rate: 24000, frames: 4800) { _, i in i < 10 ? .nan : (i < 20 ? 4 : -4) }
        let pcm = try AudioFile.pcm(url)
        for k in 0..<10 { XCTAssertEqual(value(pcm, at: k), 0) }
        XCTAssertEqual(value(pcm, at: 15), 32767)
        XCTAssertEqual(value(pcm, at: 25), -32767)
    }
    func testBundledMP3DecodesForPitchAnalysis() throws {
        let decoded = try AudioFile.samples(fixtureURL("reference.mp3"))
        XCTAssertFalse(decoded.samples.isEmpty)
        XCTAssertGreaterThan(decoded.rate, 0)
        XCTAssertTrue(try AudioFile.pitch(fixtureURL("reference.mp3")).contains { $0.hz != nil })
    }
}

extension AudioFileTests {
    func testHugeFiniteSamplesAreClampedInsteadOfTrapping() throws {
        let url = try wav(frames: 4800) { $0.isMultiple(of: 2) ? 1e30 : -.greatestFiniteMagnitude }
        let pcm = try AudioFile.pcm(url)
        XCTAssertEqual(value(pcm, at: 0), 32767)
        XCTAssertEqual(value(pcm, at: 1), -32767)
    }

    func testHighToneAbove12kHzDoesNotFoldIntoTheConvertedMessage() throws {
        for rate in [48000.0, 44100] {
            let url = try wav(rate: rate, frames: Int(rate)) {
                Float(0.5 * sin(2 * Double.pi * 16000 * Double($0) / rate))
            }
            let pcm = try AudioFile.pcm(url)
            XCTAssertEqual(pcm.count, 24000 * 2)
            let peak = pcm.withUnsafeBytes { raw in
                (100..<23900).map {
                    abs(Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))))
                }
                .max() ?? 0
            }
            // Sample skipping or linear interpolation leaves an 8 kHz (or 7.9 kHz) tone near full scale.
            XCTAssertLessThan(peak, 33, "rate \(rate)")
        }
    }

    func testCancelledSynchronousDecodingThrowsInsteadOfReturningAResult() async throws {
        let url = try wav(rate: 24000, frames: 24000 * 5) { Float(0.5 * sin(2 * Double.pi * 200 * Double($0) / 24000)) }
        let outcomes = await Task.detached { () -> [String] in
            withUnsafeCurrentTask { $0?.cancel() }
            func outcome(_ work: () throws -> Any) -> String {
                do {
                    _ = try work()
                    return "returned"
                } catch is CancellationError { return "cancelled" } catch { return "\(error)" }
            }
            return [
                outcome { try AudioFile.samples(url) }, outcome { try AudioFile.pcm(url) },
                outcome { try AudioFile.pitch(url) },
            ]
        }.value
        XCTAssertEqual(outcomes, ["cancelled", "cancelled", "cancelled"])
    }

    func testCancelledPitchAnalysisThrowsCancellationInsteadOfAnEmptyResult() async throws {
        let url = try wav(frames: 24000 * 10) { Float(0.5 * sin(2 * Double.pi * 200 * Double($0) / 24000)) }
        let task = Task { try await AudioFile.pitchInBackground(url) }
        task.cancel()
        do {
            let points = try await task.value
            XCTFail("A cancelled analysis returned \(points.count) points")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    private func wav(frames: Int, _ sample: (Int) -> Float) throws -> URL {
        let folder = TestScratch.folder("g2-audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = sample(i) }
        try file.write(from: buffer)
        return url
    }

    private func wav(rate: Double, frames: Int, _ sample: (Int) -> Float) throws -> URL {
        let folder = TestScratch.folder("r2a-audio")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("clip-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames { buffer.floatChannelData![0][i] = sample(i) }
        try file.write(from: buffer)
        return url
    }
}
