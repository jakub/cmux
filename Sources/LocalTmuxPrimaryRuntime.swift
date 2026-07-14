import Foundation

/// Owns the process-latched state for localhost tmux reconciliation.
@MainActor
final class LocalTmuxPrimaryRuntime {
    let isEnabled: Bool
    weak var tabManager: TabManager?
    private(set) var reconcileTask: Task<Void, Never>?
    private var reconcileRequested = false
    private var reconcileShouldActivate = false
    var workspaceIDsPendingClosure: Set<UUID> = []
    var lastFailureMessage: String?
    var requestedSessionName: String?
    var requestedWorkingDirectory: String?
    var requestedInitialInput: String?
    var shouldCreateRequestedSession = false
    var pendingPreferredSession: RemoteTmuxSession?

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    func prepare(
        tabManager: TabManager,
        requestedSessionName: String? = nil,
        requestedWorkingDirectory: String? = nil,
        requestedInitialInput: String? = nil,
        createRequestedSession: Bool = false
    ) {
        self.tabManager = tabManager
        guard createRequestedSession else { return }
        self.requestedSessionName = requestedSessionName
        self.requestedWorkingDirectory = requestedWorkingDirectory
        self.requestedInitialInput = requestedInitialInput
        shouldCreateRequestedSession = true
    }

    /// Records another reconciliation pass and returns whether a task must be started.
    func requestReconciliation(activate: Bool) -> Bool {
        reconcileRequested = true
        reconcileShouldActivate = reconcileShouldActivate || activate
        return reconcileTask == nil
    }

    func installReconcileTask(_ task: Task<Void, Never>) {
        precondition(reconcileTask == nil)
        reconcileTask = task
    }

    func takeReconciliationRequest() -> (tabManager: TabManager, shouldActivate: Bool)? {
        guard reconcileRequested, let tabManager else { return nil }
        reconcileRequested = false
        let shouldActivate = reconcileShouldActivate
        reconcileShouldActivate = false
        return (tabManager, shouldActivate)
    }

    func finishReconciliation() {
        reconcileTask = nil
    }

    /// Returns true only when a failure message should be presented to the user.
    func recordFailure(_ message: String) -> Bool {
        guard lastFailureMessage != message else { return false }
        lastFailureMessage = message
        return true
    }

    func reset() {
        reconcileTask?.cancel()
        reconcileTask = nil
        tabManager = nil
        reconcileRequested = false
        reconcileShouldActivate = false
        workspaceIDsPendingClosure.removeAll()
        lastFailureMessage = nil
        requestedSessionName = nil
        requestedWorkingDirectory = nil
        requestedInitialInput = nil
        shouldCreateRequestedSession = false
        pendingPreferredSession = nil
    }
}
