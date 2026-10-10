import AppKit
import MochiKernel
import UniformTypeIdentifiers

/// A file the user is asked to choose. The model receives the chosen URL, so its file work can be tested without panels.
enum PanelRequest: Equatable {
    case exportTranscript(count: Int, json: Bool)
    case exportBackup
    case importBackup
    case importReference
}

enum FilePanels {
    @MainActor static func choose(_ request: PanelRequest) -> URL? {
        switch request {
        case .exportTranscript(let count, let json):
            let panel = NSSavePanel()
            panel.nameFieldStringValue =
                count == 1 ? "Conversation.\(json ? "json" : "md")" : "Conversations.\(json ? "json" : "md")"
            panel.allowedContentTypes = [json ? .json : UTType(filenameExtension: "md") ?? .plainText]
            panel.prompt = "Export"
            panel.message =
                json
                ? "Includes transcript, drafts and conversation metadata. For recordings, use Export Library Backup."
                : "Export conversation text. For recordings, use Export Library Backup."
            return panel.runModal() == .OK ? panel.url : nil
        case .exportBackup:
            let panel = NSSavePanel()
            panel.nameFieldStringValue =
                "Mochi-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).mochilibrary"
            panel.allowedContentTypes = [UTType(exportedAs: AppIdentity.backupType, conformingTo: .package)]
            panel.prompt = "Export Backup"
            panel.message =
                "Includes all conversations, deleted history, drafts, saved expressions and their recordings. Sign-in credentials are excluded. Choose a new filename."
            return panel.runModal() == .OK ? panel.url : nil
        case .importBackup:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.treatsFilePackagesAsDirectories = true
            panel.prompt = "Import"
            panel.message =
                "Choose a .mochilibrary or older .enjoylibrary backup. Missing items are added; matching IDs keep the local version."
            return panel.runModal() == .OK ? panel.url : nil
        case .importReference:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.audio]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
}
