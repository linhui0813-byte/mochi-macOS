import AppKit
import MochiCore
import MochiKernel
import SwiftUI

@main struct MochiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    init() {
        SingleInstanceController.shared.enforce()
        _model = State(
            initialValue: AppModel(
                demo: DevelopmentLaunch.demo, libraryRoot: DevelopmentLaunch.libraryRoot,
                preferences: DevelopmentLaunch.preferences))
    }
    var body: some Scene {
        Window("Mochi", id: "main") {
            WorkspaceView(app: model)
                .background(MainWindowReader { delegate.attachWindow($0, model: model) })
                .onAppear {
                    delegate.attachModel(model)
                    delegate.runDevelopmentActions(model)
                }
        }.defaultSize(width: 1040, height: 760)
            .windowToolbarStyle(.unified)
            .commands {
                CommandGroup(replacing: .appTermination) {
                    Button("Close Window to Tray", action: delegate.tray.closeToTray).keyboardShortcut("q")
                    Button("Quit Mochi Completely", action: delegate.tray.quitApp)
                }
                CommandGroup(replacing: .newItem) {
                    Button("New Conversation", action: model.newChat).keyboardShortcut("n").disabled(
                        model.automationModal)
                    Button("New Conversation from Template…", action: model.openTemplatePicker).keyboardShortcut(
                        "n", modifiers: [.command, .shift]
                    ).disabled(!model.canOpenConversationInstructions)
                    Button("Manage Templates…", action: model.openTemplateManager).disabled(
                        !model.canOpenConversationInstructions)
                }
                CommandMenu("Conversation") {
                    Button("Find in Conversation", action: model.findInConversation).keyboardShortcut("f").disabled(
                        !model.canFindInConversation)
                    Button("Next Match") { model.moveConversationMatch(1) }.keyboardShortcut("g").disabled(
                        model.conversationMatchIDs.isEmpty)
                    Button("Previous Match") { model.moveConversationMatch(-1) }.keyboardShortcut(
                        "g", modifiers: [.command, .shift]
                    ).disabled(model.conversationMatchIDs.isEmpty)
                    Button("Search All Conversations") {
                        model.searchOpen = true
                        model.searchFocusRequest += 1
                    }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(
                        model.practice || model.renameID != nil || !model.permanentDeleteIDs.isEmpty)
                    Button("Manage Conversations…") { model.managerOpen = true }.keyboardShortcut(
                        "m", modifiers: [.command, .shift]
                    ).disabled(model.practice)
                    if let chat = model.conversation { ChatActions(app: model, chat: chat).disabled(model.practice) }
                    Divider()
                    Button("Export Library Backup…", action: model.exportLibraryBackup).disabled(
                        model.libraryTransfer != nil)
                    Button("Import Library Backup…", action: model.importLibraryBackup).disabled(
                        model.libraryTransfer != nil)
                    Divider()
                    Button("Help Me Say This", action: model.startHelp).keyboardShortcut(
                        "h", modifiers: [.command, .shift]
                    ).disabled(!model.writableConversation)
                    Button("Stop") {
                        if model.conversationSearchOpen { model.closeConversationSearch() } else { model.stop() }
                    }.keyboardShortcut(.escape, modifiers: [])
                }
            }
        Settings {
            SettingsView(app: model)
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    let tray = TrayController()
    #if MOCHI_DEVELOPMENT
        private let instanceE2E = SingleInstanceE2E()
    #endif
    #if MOCHI_DEVELOPMENT
        /// Development runs perform their scripted actions once per launch.
        var ran = false
    #endif
    func attachWindow(_ window: NSWindow, model: AppModel) {
        tray.attach(window, model: model)
        #if MOCHI_DEVELOPMENT
            instanceE2E.attach(window, tray: tray)
        #endif
        SingleInstanceController.shared.revealWorkspace = { [weak self] in self?.tray.showWindow() }
    }
    func attachModel(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        model.revealWorkspace = { [weak self] in self?.tray.showWindow() }
        model.configureAutomation()
    }
    func runDevelopmentActions(_ model: AppModel) {
        #if MOCHI_DEVELOPMENT
            if CommandLine.arguments.contains("--tools-probe") {
                toolsProbe(model)
                return
            }
            if CommandLine.arguments.contains("--probe") {
                probe(model)
                return
            }
            if CommandLine.arguments.contains("--smoke-test") { smoke(model) }
            if CommandLine.arguments.contains("--tray-smoke-test")
                || CommandLine.arguments.contains("--single-instance-smoke-test")
            {
                smokeTray(model)
            }
        #endif
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        tray.install()
    }
    func applicationDidBecomeActive(_ notification: Notification) { model?.configureAutomation() }
    func applicationWillTerminate(_ notification: Notification) {
        model?.automation.server?.stop()
        model?.notice = nil
        model?.stop()
        model?.save()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        tray.showWindow()
        return false
    }
}

enum DevelopmentLaunch {
    static var libraryRoot: URL? {
        #if MOCHI_DEVELOPMENT
            if let root = ProcessInfo.processInfo.environment["MOCHI_E2E_LIBRARY_ROOT"] {
                return URL(fileURLWithPath: root)
            }
        #endif
        return nil
    }
    static var preferences: UserDefaults? {
        libraryRoot.map { UserDefaults(suiteName: "mochi-e2e-" + $0.lastPathComponent)! }
    }
    static var demo: Bool {
        #if MOCHI_DEVELOPMENT
            return [
                "--preview", "--smoke-test", "--tray-smoke-test", "--single-instance-smoke-test", "--tools-probe",
                "--probe",
            ].contains { CommandLine.arguments.contains($0) }
        #else
            return false
        #endif
    }
}
