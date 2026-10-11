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
                (count == 1 ? String(localized: "Conversation") : String(localized: "Conversations"))
                + (json ? ".json" : ".md")
            panel.allowedContentTypes = [json ? .json : UTType(filenameExtension: "md") ?? .plainText]
            panel.prompt = String(localized: "Export")
            panel.message =
                json
                ? String(
                    localized:
                        "Includes transcript, drafts and conversation metadata. For recordings, use Export Library Backup."
                )
                : String(localized: "Export conversation text. For recordings, use Export Library Backup.")
            return panel.runModal() == .OK ? panel.url : nil
        case .exportBackup:
            let panel = NSSavePanel()
            panel.nameFieldStringValue =
                "Mochi-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).mochilibrary"
            panel.allowedContentTypes = [UTType(exportedAs: AppIdentity.backupType, conformingTo: .package)]
            panel.prompt = String(localized: "Export Backup")
            panel.message = String(
                localized:
                    "Includes all conversations, deleted history, drafts, saved expressions and their recordings. Sign-in credentials are excluded. Choose a new filename."
            )
            return panel.runModal() == .OK ? panel.url : nil
        case .importBackup:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.treatsFilePackagesAsDirectories = true
            panel.prompt = String(localized: "Import")
            panel.message = String(
                localized:
                    "Choose a .mochilibrary or older .enjoylibrary backup. Missing items are added; matching IDs keep the local version."
            )
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
