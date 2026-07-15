import Foundation

/// A fully resolved child-process launch used by a tmux control connection.
struct RemoteTmuxProcessInvocation: Sendable {
    let executablePath: String
    let arguments: [String]
    let environment: [String: String]?
}
