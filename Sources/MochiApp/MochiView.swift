import AppKit
import SwiftUI

struct MochiView: View {
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    /// The idle animation, the first row of the sprite sheet.
    static let frames: [CGImage] = PetSprite.shared.frames(.idle)
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
