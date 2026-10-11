import AppKit
import SwiftUI

struct ConversationSearchControl: View {
    @Bindable var app: AppModel
    var body: some View {
        if app.find.isOpen {
            HStack(spacing: 6) {
                ConversationSearchField(app: app).frame(width: 180)
                Text(
                    app.find.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? ""
                        : app.find.matchIDs.isEmpty
                            ? "No matches"
                            : "\(min(app.find.matchIndex+1,app.find.matchIDs.count))/\(app.find.matchIDs.count)"
                )
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .lineLimit(1).frame(width: 64, alignment: .trailing)
                Button {
                    app.find.move(-1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .help("Previous Match (⇧⌘G)").accessibilityLabel("Previous Match").disabled(
                    app.find.matchIDs.isEmpty)
                Button {
                    app.find.move(1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .help("Next Match (⌘G)").accessibilityLabel("Next Match").disabled(app.find.matchIDs.isEmpty)
                Button(action: app.find.close) { Image(systemName: "xmark") }
                    .help("Close Search (Escape)").accessibilityLabel("Close conversation search")
            }
        } else {
            Button(action: app.openConversationSearch) { Label("Find in Conversation", systemImage: "magnifyingglass") }
                .labelStyle(.iconOnly).help("Find in Conversation (⌘F)")
        }
    }
}

private struct ConversationSearchField: NSViewRepresentable {
    @Bindable var app: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(app: app) }
    func makeNSView(context: Context) -> FocusableSearchField {
        let field = FocusableSearchField()
        field.placeholderString = "Search this conversation"
        field.setAccessibilityLabel("Search this conversation")
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        return field
    }
    func updateNSView(_ field: FocusableSearchField, context: Context) {
        context.coordinator.app = app
        if field.stringValue != app.find.query { field.stringValue = app.find.query }
        if context.coordinator.focusRequest != app.find.focusRequest {
            context.coordinator.focusRequest = app.find.focusRequest
            field.wantsFocus = true
            DispatchQueue.main.async { field.focusIfNeeded() }
        }
    }
    final class FocusableSearchField: NSSearchField {
        var wantsFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focusIfNeeded()
        }
        func focusIfNeeded() {
            guard wantsFocus, let window else { return }
            wantsFocus = false
            window.makeFirstResponder(self)
        }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var app: AppModel
        var focusRequest: Int?
        init(app: AppModel) { self.app = app }
        @objc func searchChanged(_ field: NSSearchField) {
            if app.find.query != field.stringValue { app.find.query = field.stringValue }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            searchChanged(field)
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                app.find.close()
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                app.find.move(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
                return true
            }
            return false
        }
    }
}
