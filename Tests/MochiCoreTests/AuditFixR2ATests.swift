import XCTest

@testable import MochiCore

final class AuditFixR2ATests: XCTestCase {
    private func tone(_ hz: Double, rate: Double) -> [Float] {
        (0..<Int(rate)).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// #87: the decimation filter must remove tones the analysis rate cannot carry, not merely notch some.
    func testTonesAboveTheAnalysisNyquistNeverYieldPitch() {
        for (hz, rate) in [
            (10800.0, 24000.0), (9000, 24000), (10800, 22050), (21000, 44100), (13000, 48000), (40000, 96000),
        ] {
            let voiced = PitchAnalyzer.analyze(samples: tone(hz, rate: rate), sampleRate: rate).compactMap(\.hz)
            XCTAssertTrue(voiced.isEmpty, "\(hz) Hz at \(rate) Hz produced \(voiced.prefix(3))")
        }
    }
    func testSpeechPitchSurvivesTheFilterAtCommonRates() {
        for rate in [44100.0, 48000] {
            let values = PitchAnalyzer.analyze(samples: tone(220, rate: rate), sampleRate: rate).compactMap(\.hz)
                .sorted()
            XCTAssertEqual(values.isEmpty ? 0 : values[values.count / 2], 220, accuracy: 3, "rate \(rate)")
        }
    }
}
