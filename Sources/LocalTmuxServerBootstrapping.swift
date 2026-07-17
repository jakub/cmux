import Foundation

/// Starts the user's local tmux server outside cmux's application coalition.
///
/// The caller has already established that no server responds. A socket path
/// may still exist after an unclean server exit and is not evidence of liveness.
protocol LocalTmuxServerBootstrapping: Sendable {
    func startServer(
        environment: [String: String],
        shellExecutablePath: String
    ) async throws
}
