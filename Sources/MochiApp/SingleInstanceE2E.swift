#if MOCHI_DEVELOPMENT
    import AppKit
    import MochiKernel

    /// Explicitly enabled only in the remote, isolated development test process.
    @MainActor final class SingleInstanceE2E {
        private var observer: NSObjectProtocol?
        func attach(_ window: NSWindow, tray: TrayController) {
            guard observer == nil, let scope = ProcessInfo.processInfo.environment["MOCHI_INSTANCE_EVENTS_DIR"] else {
                return
            }
            observer = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("mochi.e2e.command"), object: scope, queue: .main
            ) { [weak window, weak tray] notification in
                MainActor.assumeIsolated {
                    guard let window, let tray else { return }
                    let command = notification.userInfo?["command"] as? String
                    switch command {
                    case "hide": tray.closeToTray()
                    case "minimize": window.miniaturize(nil)
                    case "quit":
                        tray.quitApp()
                        return
                    default: break
                    }
                    let requestID = notification.userInfo?["request_id"] as? String
                    Task { @MainActor in
                        @MainActor func state() -> NSDictionary {
                            [
                                "pid": getpid(), "visible": window.isVisible, "miniaturized": window.isMiniaturized,
                                "hidden": NSApp.isHidden, "active": NSApp.isActive, "key": window.isKeyWindow,
                                "dock": NSApp.activationPolicy() == .regular, "tray": tray.statusItem != nil,
                            ]
                        }
                        func reached(_ state: NSDictionary) -> Bool {
                            switch command {
                            case "minimize": state["miniaturized"] as? Bool == true
                            case "hide": state["hidden"] as? Bool == true && state["dock"] as? Bool == false
                            // A reopen is complete only once the workspace is shown, active and key.
                            case "restored":
                                ["visible", "active", "key", "dock"].allSatisfy { state[$0] as? Bool == true }
                                    && state["miniaturized"] as? Bool == false && state["hidden"] as? Bool == false
                            default: true
                            }
                        }
                        // Window animations and activation finish on their own schedule: report once the command's
                        // expected state holds and two samples agree, or whatever holds after 5 s.
                        let deadline = Date().addingTimeInterval(5)
                        var previous: NSDictionary?
                        var current = state()
                        while Date() < deadline {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            current = state()
                            if reached(current), current == previous { break }
                            previous = current
                        }
                        let snapshot = NSMutableDictionary(dictionary: current)
                        snapshot["time"] = Date().timeIntervalSince1970
                        snapshot["command"] = command ?? "snapshot"
                        if let requestID { snapshot["request_id"] = requestID }
                        let destination = URL(fileURLWithPath: scope).appendingPathComponent(
                            "workspace-\(getpid()).json")
                        do {
                            try JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys).write(
                                to: destination, options: .atomic)
                        } catch {
                            let context = "E2E snapshot for \(command ?? "snapshot") to \(destination.path)"
                            MochiLog.failure(MochiLog.app, context, error)
                            FileHandle.standardError.write(Data("\(context) failed: \(error)\n".utf8))
                        }
                    }
                }
            }
            InstanceEvidence.record("workspace-attached")
        }
        deinit { if let observer { DistributedNotificationCenter.default().removeObserver(observer) } }
    }
#endif
