import AVFoundation
import XCTest

@testable import MochiApp

final class CaptureChannelRoutingTests: XCTestCase {
    func testMonoCaptureKeepsTheMicrophoneInsteadOfChoosingASilentCenterChannel() async throws {
        for tag in [
            kAudioChannelLayoutTag_Stereo, kAudioChannelLayoutTag_MPEG_3_0_A,
            kAudioChannelLayoutTag_Quadraphonic, kAudioChannelLayoutTag_MPEG_5_1_A,
        ] {
            let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: tag))
            let channels = Int(layout.channelCount)
            let format = try XCTUnwrap(
                AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 48000, interleaved: false, channelLayout: layout))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
            buffer.frameLength = 4800
            for channel in 0..<channels {
                for frame in 0..<4800 {
                    buffer.floatChannelData?[channel][frame] =
                        channel == 0
                        ? Float(sin(Double(frame) * 2 * .pi * 180 / 48000) * 0.25) : 0
                }
            }
            var sink: AsyncThrowingStream<Data, Error>.Continuation!
            let stream = AsyncThrowingStream<Data, Error> { sink = $0 }
            let converter = try HandsFreePCMConverter(format: format, continuation: sink)
            converter.receive(buffer)
            var iterator = stream.makeAsyncIterator()
            let next = try await iterator.next()
            let pcm = try XCTUnwrap(next)
            var energy = 0.0
            for i in stride(from: 0, to: pcm.count, by: 2) {
                let sample = Double(Int16(bitPattern: UInt16(pcm[i]) | UInt16(pcm[i + 1]) << 8)) / 32768
                energy += sample * sample
            }
            let rms = sqrt(energy / Double(pcm.count / 2))
            XCTAssertGreaterThan(rms, 0.15, "Keep microphone gain with \(channels) capture channels; got RMS \(rms)")
            sink.finish()
        }
    }
}
