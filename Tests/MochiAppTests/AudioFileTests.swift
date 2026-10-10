import AVFoundation
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
        for k in [0, 1, 100, 12345, 23999] {
            XCTAssertEqual(value(pcm, at: k), Int16(Int(tone[2 * k] * 32767)), "sample \(k)")
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
