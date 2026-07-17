import Foundation

/// Owns the process-latched state for localhost tmux reconciliation.
@MainActor
final class LocalTmuxPrimaryRuntime {
    struct SessionOrderRequest: Equatable {
        let revision: Int
        let updates: [RemoteTmuxSessionOrderUpdate]
    }

    let isEnabled: Bool
    weak var tabManager: TabManager?
    private(set) var reconcileTask: Task<Void, Never>?
    private var reconcileRequested = false
    private var reconcileShouldActivate = false
    private(set) var sessionOrderTask: Task<Void, Never>?
    private var latestSessionOrderRequest: SessionOrderRequest?
    private var lastTakenSessionOrderRevision = 0
    private var nextSessionOrderRevision = 0
    private var persistedSessionOrderRevision = 0
    var isApplyingAuthoritativeSessionOrder = false
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

    /// Records the latest complete order. A running writer skips superseded
    /// requests, while reconciliation can use this as an overlay until tmux has
    /// acknowledged the newest write.
    func requestSessionOrderPersistence(_ updates: [RemoteTmuxSessionOrderUpdate]) -> Bool {
        nextSessionOrderRevision += 1
        latestSessionOrderRequest = SessionOrderRequest(
            revision: nextSessionOrderRevision,
            updates: updates
        )
        return sessionOrderTask == nil
    }

    func installSessionOrderTask(_ task: Task<Void, Never>) {
        precondition(sessionOrderTask == nil)
        sessionOrderTask = task
    }

    func takeSessionOrderRequest() -> SessionOrderRequest? {
        guard let request = latestSessionOrderRequest,
              request.revision > lastTakenSessionOrderRevision else { return nil }
        lastTakenSessionOrderRevision = request.revision
        return request
    }

    func markSessionOrderPersisted(revision: Int) {
        persistedSessionOrderRevision = max(persistedSessionOrderRevision, revision)
    }

    func finishSessionOrderPersistence() {
        sessionOrderTask = nil
    }

    func orderedSessions(_ sessions: [RemoteTmuxSession]) -> [RemoteTmuxSession] {
        guard let request = latestSessionOrderRequest else {
            return RemoteTmuxSession.orderedForCmux(sessions)
        }
        let updates = request.updates
        if request.revision <= persistedSessionOrderRevision,
           Self.sessionOrder(updates, matches: sessions) {
            latestSessionOrderRequest = nil
            return RemoteTmuxSession.orderedForCmux(sessions)
        }
        let orderById = Dictionary(uniqueKeysWithValues: updates.compactMap { update in
            update.sessionId.map { ($0, update.order) }
        })
        let orderByName = Dictionary(uniqueKeysWithValues: updates.map { ($0.sessionName, $0.order) })
        return sessions.enumerated().sorted { lhs, rhs in
            let leftOrder = orderById[lhs.element.id] ?? orderByName[lhs.element.name]
            let rightOrder = orderById[rhs.element.id] ?? orderByName[rhs.element.name]
            switch (leftOrder, rightOrder) {
            case let (.some(left), .some(right)) where left != right:
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    private static func sessionOrder(
        _ updates: [RemoteTmuxSessionOrderUpdate],
        matches sessions: [RemoteTmuxSession]
    ) -> Bool {
        let sessionById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let sessionByName = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0) })
        return updates.allSatisfy { update in
            let session = update.sessionId.flatMap { sessionById[$0] } ?? sessionByName[update.sessionName]
            return session?.cmuxOrder == update.order
        }
    }

    /// Returns true only when a failure message should be presented to the user.
    func recordFailure(_ message: String) -> Bool {
        guard lastFailureMessage != message else { return false }
        lastFailureMessage = message
        return true
    }

    func reset() {
        reconcileTask?.cancel()
        sessionOrderTask?.cancel()
        reconcileTask = nil
        sessionOrderTask = nil
        tabManager = nil
        reconcileRequested = false
        reconcileShouldActivate = false
        latestSessionOrderRequest = nil
        lastTakenSessionOrderRevision = 0
        nextSessionOrderRevision = 0
        persistedSessionOrderRevision = 0
        isApplyingAuthoritativeSessionOrder = false
        workspaceIDsPendingClosure.removeAll()
        lastFailureMessage = nil
        requestedSessionName = nil
        requestedWorkingDirectory = nil
        requestedInitialInput = nil
        shouldCreateRequestedSession = false
        pendingPreferredSession = nil
    }
}
