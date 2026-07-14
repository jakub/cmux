import AppKit

@MainActor
extension AppDelegate {
    func performNewLocalTmuxWorkspaceAction(
        tabManager preferredTabManager: TabManager?,
        event: NSEvent?,
        debugSource: String,
        title: String? = nil,
        workingDirectory requestedWorkingDirectory: String? = nil,
        initialInput: String? = nil
    ) -> Bool {
        if mainWindowContexts.isEmpty {
            _ = createMainWindow(
                initialWorkspaceTitle: title,
                initialWorkingDirectory: requestedWorkingDirectory,
                initialTerminalInput: initialInput ?? "",
                createLocalTmuxSession: true,
                shouldActivate: true
            )
            return true
        }
        guard let manager = preferredTabManager
            ?? preferredMainWindowContextForWorkspaceCreation(event: event, debugSource: debugSource)?.tabManager
            ?? tabManager else {
            return false
        }
        return scheduleNewLocalTmuxWorkspace(
            in: manager,
            debugSource: debugSource,
            title: title,
            workingDirectory: requestedWorkingDirectory ?? manager.selectedWorkspace?.currentDirectory,
            initialInput: initialInput
        )
    }

    private func scheduleNewLocalTmuxWorkspace(
        in manager: TabManager,
        debugSource: String,
        title: String?,
        workingDirectory: String?,
        initialInput: String?
    ) -> Bool {
        Task { @MainActor [weak self, weak manager] in
            guard let self, let manager else { return }
            do {
                let workspaceId = try await remoteTmuxController.createLocalPrimaryWorkspace(
                    in: manager,
                    title: title,
                    workingDirectory: workingDirectory,
                    select: true
                )
                if let initialInput,
                   let workspace = manager.tabs.first(where: { $0.id == workspaceId }) {
                    sendTextWhenReady(initialInput, to: workspace)
                }
            } catch {
                RemoteTmuxController.logger.error(
                    "local-tmux: workspace creation failed from \(debugSource, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                presentLocalTmuxPrimaryFailure(error)
            }
        }
        return true
    }

    func presentLocalTmuxPrimaryFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "localTmux.primary.failure.title",
            defaultValue: "Local tmux is unavailable"
        )
        alert.informativeText = String(
            localized: "localTmux.primary.failure.message",
            defaultValue: "cmux could not create or mirror a localhost tmux session. Native terminal fallback is disabled while this beta is enabled."
        ) + "\n\n" + error.localizedDescription
        alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            _ = alert.runModal()
        }
    }
}
