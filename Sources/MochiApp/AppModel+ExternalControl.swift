import Foundation
import MochiKernel

/// External control: the local socket an MCP client reaches, and the tool handler that answers it.
extension AppModel {
    var tools: ToolHandler { ToolHandler(app: self) }
    var controlSocketPath: String { AutomationController.socketPath(forLibraryRoot: store.root) }
    func configureAutomation() {
        InstanceEvidence.record("automation-configured")
        automation.configure(
            enabled: externalControlEnabled && (!demo || allowDemoAutomation), path: controlSocketPath,
            recheck: { [weak self] in self?.configureAutomation() },
            handler: { [weak self] data in self?.tools.handleControlRequest(data) ?? Data() })
    }
}
