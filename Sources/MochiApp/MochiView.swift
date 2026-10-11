import AppKit
import SwiftUI

struct MochiView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    /// The idle animation: the first six cells of the sprite sheet's top row.
    static let frames: [CGImage] = {
        guard let url = Bundle.module.url(forResource: "mochi", withExtension: "webp"),
            let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return [] }
        return (0..<6).compactMap { cg.cropping(to: CGRect(x: $0 * 192, y: 0, width: 192, height: 208)) }
    }()
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18, paused: reducedMotion)) { context in
            let frames = Self.frames
            let index = reducedMotion ? 0 : Int(context.date.timeIntervalSinceReferenceDate * 3) % max(1, frames.count)
            if !frames.isEmpty {
                Image(decorative: frames[index], scale: 1).resizable().interpolation(.high).scaledToFit()
            }
        }.accessibilityLabel("Mochi")
    }
}
