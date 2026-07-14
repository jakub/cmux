import Foundation

@MainActor
extension RemoteTmuxController {
    /// Starts localhost tmux ownership for one main-window workspace manager.
    func startLocalPrimary(
        in tabManager: TabManager,
        activate: Bool,
        requestedSessionName: String? = nil,
        requestedWorkingDirectory: String? = nil,
        requestedInitialInput: String? = nil,
        createRequestedSession: Bool = false
    ) {
        guard localPrimaryEnabled else { return }
        localPrimaryRuntime.prepare(
            tabManager: tabManager,
            requestedSessionName: requestedSessionName,
            requestedWorkingDirectory: requestedWorkingDirectory,
            requestedInitialInput: requestedInitialInput,
            createRequestedSession: createRequestedSession
        )
        scheduleLocalPrimaryReconciliation(activate: activate)
    }

    /// Creates a localhost tmux session, mirrors it, and returns its cmux workspace id.
    func createLocalPrimaryWorkspace(
        in tabManager: TabManager,
        title: String?,
        workingDirectory: String?,
        select: Bool
    ) async throws -> UUID {
        guard localPrimaryEnabled else {
            throw RemoteTmuxError.unreachable(String(
                localized: "localTmux.primary.error.disabled",
                defaultValue: "Local tmux primary mode is disabled."
            ))
        }
        if let reconciliation = localPrimaryRuntime.reconcileTask {
            await reconciliation.value
            try Task.checkCancellation()
        }
        localPrimaryRuntime.prepare(tabManager: tabManager)
        let host = Self.localPrimaryHost
        let session = try await transport(for: host).createSession(
            name: title,
            workingDirectory: workingDirectory
        )
        try await ensureControlMasterReadyForBurst(host: host)
        try Task.checkCancellation()
        _ = mirrorDiscoveredSessions(host: host, sessions: [session], into: tabManager)
        guard let mirror = sessionMirrors.values.first(where: { mirror in
            guard mirror.host.connectionHash == host.connectionHash else { return false }
            if let numericId = Self.tmuxSessionNumericId(session.id) {
                return mirror.connection.sessionId == numericId || mirror.seededSessionId == numericId
            }
            return mirror.sessionName == session.name
        }), let workspaceId = mirror.mirroredWorkspaceId else {
            throw RemoteTmuxError.unreachable(String(
                localized: "localTmux.primary.error.mirrorCreatedSession",
                defaultValue: "The tmux session was created but could not be mirrored."
            ))
        }
        if select, let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) {
            tabManager.selectWorkspace(workspace)
        }
        return workspaceId
    }

    /// Coalesces server-wide session-change events into one authoritative listing.
    func handleServerSessionsChanged(host: RemoteTmuxHost) {
        guard localPrimaryEnabled,
              host.connectionHash == Self.localPrimaryHost.connectionHash,
              localPrimaryRuntime.tabManager != nil else { return }
        scheduleLocalPrimaryReconciliation(activate: false)
    }

    /// Keeps a dead last mirror visible until a replacement tmux session exists.
    func recoverLocalPrimaryMirrorIfNeeded(
        host: RemoteTmuxHost,
        tabManager: TabManager,
        workspace: Workspace
    ) -> Bool {
        guard localPrimaryEnabled,
              host.connectionHash == Self.localPrimaryHost.connectionHash else { return false }
        localPrimaryRuntime.prepare(tabManager: tabManager)
        localPrimaryRuntime.workspaceIDsPendingClosure.insert(workspace.id)
        scheduleLocalPrimaryReconciliation(activate: false)
        return true
    }

    func isLocalPrimaryMirrorWorkspace(workspaceId: UUID) -> Bool {
        guard localPrimaryEnabled else { return false }
        return sessionMirrors.values.contains { mirror in
            mirror.host.connectionHash == Self.localPrimaryHost.connectionHash
                && mirror.mirroredWorkspaceId == workspaceId
        }
    }

    private func scheduleLocalPrimaryReconciliation(activate: Bool) {
        guard localPrimaryRuntime.requestReconciliation(activate: activate) else { return }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await runLocalPrimaryReconciliationLoop()
        }
        localPrimaryRuntime.installReconcileTask(task)
    }

    private func runLocalPrimaryReconciliationLoop() async {
        defer { localPrimaryRuntime.finishReconciliation() }
        while !Task.isCancelled,
              let request = localPrimaryRuntime.takeReconciliationRequest() {
            do {
                try await reconcileLocalPrimary(
                    in: request.tabManager,
                    activate: request.shouldActivate
                )
                localPrimaryRuntime.lastFailureMessage = nil
            } catch is CancellationError {
                return
            } catch {
                Self.logger.error("local-tmux: reconciliation failed: \(error.localizedDescription, privacy: .public)")
                let message = error.localizedDescription
                if localPrimaryRuntime.recordFailure(message) {
                    AppDelegate.shared?.presentLocalTmuxPrimaryFailure(error)
                }
            }
        }
    }

    private func reconcileLocalPrimary(in tabManager: TabManager, activate: Bool) async throws {
        guard localPrimaryEnabled else { return }
        let host = Self.localPrimaryHost
        let transport = transport(for: host)
        var sessions = try await transport.discoverMirrorSessions(createIfEmpty: false)
        var preferredSession = localPrimaryRuntime.pendingPreferredSession
        if sessions.isEmpty || localPrimaryRuntime.shouldCreateRequestedSession {
            let session = try await transport.createSession(
                name: localPrimaryRuntime.shouldCreateRequestedSession ? localPrimaryRuntime.requestedSessionName : nil,
                workingDirectory: localPrimaryRuntime.shouldCreateRequestedSession
                    ? localPrimaryRuntime.requestedWorkingDirectory
                    : tabManager.selectedWorkspace?.currentDirectory
            )
            sessions.append(session)
            preferredSession = session
            localPrimaryRuntime.pendingPreferredSession = session
            localPrimaryRuntime.shouldCreateRequestedSession = false
        }
        if preferredSession == nil {
            preferredSession = sessions.first
        }
        try await ensureControlMasterReadyForBurst(host: host)
        try Task.checkCancellation()

        let nativeTerminalWorkspaceIDs = Set(tabManager.tabs.compactMap { workspace -> UUID? in
            guard !workspace.isRemoteTmuxMirror,
                  workspace.focusedTerminalPanel != nil,
                  workspace.panels.values.allSatisfy({ $0 is TerminalPanel }) else { return nil }
            return workspace.id
        })
        let mirroredWorkspaceIDs = mirrorDiscoveredSessions(
            host: host,
            sessions: sessions,
            into: tabManager
        )
        guard !mirroredWorkspaceIDs.isEmpty else {
            throw RemoteTmuxError.unreachable(String(
                localized: "localTmux.primary.error.noMirror",
                defaultValue: "cmux could not mirror any localhost tmux session."
            ))
        }

        closeLocalPrimaryWorkspaces(
            nativeTerminalWorkspaceIDs.union(localPrimaryRuntime.workspaceIDsPendingClosure),
            in: tabManager
        )
        localPrimaryRuntime.workspaceIDsPendingClosure.subtract(nativeTerminalWorkspaceIDs)
        localPrimaryRuntime.workspaceIDsPendingClosure = localPrimaryRuntime.workspaceIDsPendingClosure.filter { workspaceId in
            tabManager.tabs.contains(where: { $0.id == workspaceId })
        }

        let preferredWorkspace: Workspace? = preferredSession.flatMap { session in
            sessionMirrors.values.first(where: { mirror in
                guard mirror.host.connectionHash == host.connectionHash else { return false }
                if let numericId = Self.tmuxSessionNumericId(session.id) {
                    return mirror.connection.sessionId == numericId || mirror.seededSessionId == numericId
                }
                return mirror.sessionName == session.name
            })?.mirroredWorkspaceId.flatMap { workspaceId in
                tabManager.tabs.first(where: { $0.id == workspaceId })
            }
        }
        if let initialInput = localPrimaryRuntime.requestedInitialInput,
           !initialInput.isEmpty,
           let preferredWorkspace {
            localPrimaryRuntime.requestedInitialInput = nil
            AppDelegate.shared?.sendTextWhenReady(initialInput, to: preferredWorkspace)
        }
        if preferredWorkspace != nil {
            localPrimaryRuntime.pendingPreferredSession = nil
            localPrimaryRuntime.requestedSessionName = nil
            localPrimaryRuntime.requestedWorkingDirectory = nil
            localPrimaryRuntime.requestedInitialInput = nil
        }

        if activate,
           let workspace = preferredWorkspace
            ?? tabManager.tabs.first(where: { mirroredWorkspaceIDs.contains($0.id) }) {
            tabManager.selectWorkspace(workspace)
        }
    }

    private func closeLocalPrimaryWorkspaces(_ workspaceIDs: Set<UUID>, in tabManager: TabManager) {
        for workspaceId in workspaceIDs {
            guard tabManager.tabs.count > 1,
                  let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }) else { continue }
            workspace.isRemoteTmuxMirror = false
            tabManager.closeWorkspace(workspace, recordHistory: false)
            localPrimaryRuntime.workspaceIDsPendingClosure.remove(workspaceId)
        }
    }
}
