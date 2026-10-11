import AVFoundation
import MochiTestSupport
import XCTest

@testable import MochiApp

final class AuditFixG2Tests: XCTestCase {
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
    private func value(_ pcm: Data, at index: Int) -> Int16 {
        Int16(littleEndian: pcm.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: index * 2, as: Int16.self) })
    }

    func testHugeFiniteSamplesAreClampedInsteadOfTrapping() throws {
        let url = try wav(frames: 4800) { $0.isMultiple(of: 2) ? 1e30 : -.greatestFiniteMagnitude }
        let pcm = try AudioFile.pcm(url)
        XCTAssertEqual(value(pcm, at: 0), 32767)
        XCTAssertEqual(value(pcm, at: 1), -32767)
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
}
