import Foundation

/// A tmux session discovered on a remote host.
///
/// Mirrors the fields cmux requests from `tmux list-sessions`. The `id` is
/// tmux's native session id (e.g. `$2`), which is stable for the lifetime of
/// the remote tmux server and is what cmux keys its sidebar workspace on.
struct RemoteTmuxSession: Sendable, Equatable, Codable, Identifiable {
    /// tmux's native session id, e.g. `$2`.
    let id: String

    /// The session name, e.g. `main`.
    let name: String

    /// Number of windows in the session.
    let windowCount: Int

    /// Whether any client is currently attached to the session.
    let attached: Bool

    /// Session creation time as a Unix timestamp, when reported by tmux.
    let createdUnix: Int?

    /// cmux's persisted sidebar position, stored as tmux's `@cmux_order`
    /// session option. Sessions not yet ordered by cmux report `nil`.
    let cmuxOrder: Int?

    init(
        id: String,
        name: String,
        windowCount: Int,
        attached: Bool,
        createdUnix: Int?,
        cmuxOrder: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.windowCount = windowCount
        self.attached = attached
        self.createdUnix = createdUnix
        self.cmuxOrder = cmuxOrder
    }

    /// Applies cmux's persisted session order while keeping discovery order as
    /// the stable fallback. Newly discovered unordered sessions append after
    /// ordered sessions instead of displacing an existing sidebar layout.
    static func orderedForCmux(_ sessions: [RemoteTmuxSession]) -> [RemoteTmuxSession] {
        sessions.enumerated().sorted { lhs, rhs in
            switch (lhs.element.cmuxOrder, rhs.element.cmuxOrder) {
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
}
