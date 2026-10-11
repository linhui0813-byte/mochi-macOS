import AppKit
import SwiftUI

/// Rounded field frame that shows keyboard focus for inputs drawn without a system bezel.
struct FieldFrame: ViewModifier {
    let cornerRadius: CGFloat
    let focused: Bool
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(
                    focused ? AnyShapeStyle(Color(nsColor: .keyboardFocusIndicatorColor)) : AnyShapeStyle(.quaternary),
                    lineWidth: focused ? 3 : 1)
            }
    }
}

extension View {
    func fieldFrame(cornerRadius: CGFloat, focused: Bool) -> some View {
        modifier(FieldFrame(cornerRadius: cornerRadius, focused: focused))
    }
}
