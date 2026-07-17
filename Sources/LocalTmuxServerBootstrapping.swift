import Foundation

/// Starts the user's local tmux server outside cmux's application coalition.
protocol LocalTmuxServerBootstrapping: Sendable {
    func startServer(
        environment: [String: String],
        shellExecutablePath: String
    ) async throws
}
