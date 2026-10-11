import Foundation

public struct RecordingSignal {
    public let rmsDB: Double
    public var isQuiet: Bool { rmsDB < -48 }
    public init(samples: [Float]) {
        let finite = samples.map { $0.isFinite ? Double($0) : 0 }
        let rms = sqrt(finite.reduce(0) { $0 + $1 * $1 } / Double(max(1, finite.count)))
        rmsDB = 20 * log10(max(rms, 1e-9))
    }
}
