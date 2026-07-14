import Foundation

/// Creates localhost tmux sessions from cmux's GUI security context.
///
/// SSH remains the control transport after creation, but it must not create the
/// tmux server: a server born under sshd cannot read login-keychain credentials
/// noninteractively, and every pane it later spawns inherits that restriction.
actor LocalTmuxServerBootstrapper {
    private let shellExecutablePath: String
    private let defaultWorkingDirectory: String

    init(
        shellExecutablePath: String = "/bin/sh",
        defaultWorkingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.shellExecutablePath = shellExecutablePath
        self.defaultWorkingDirectory = defaultWorkingDirectory
    }

    /// Creates one detached session and returns tmux's authoritative identity.
    func createSession(name: String?, workingDirectory: String?) async throws -> RemoteTmuxSession {
        let requestedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkingDirectory = requestedWorkingDirectory?.isEmpty == false
            ? requestedWorkingDirectory
            : defaultWorkingDirectory
        let invocation = RemoteTmuxHost.tmuxResolverInvocation(
            arguments: RemoteTmuxSSHTransport.createSessionArguments(
                name: name,
                workingDirectory: resolvedWorkingDirectory
            ),
            commandName: "cmux-local-tmux"
        )
        let result = try await RemoteTmuxSSHTransport.runProcess(
            executable: shellExecutablePath,
            arguments: invocation.arguments
        )
        guard result.succeeded else {
            if RemoteTmuxSSHTransport.indicatesTmuxMissing(
                exitCode: result.exitCode,
                stderr: result.stderr
            ) {
                throw RemoteTmuxError.tmuxNotFound(destination: "localhost")
            }
            throw RemoteTmuxError.commandFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        guard let session = RemoteTmuxSessionListParser.parse(result.stdout).first else {
            throw RemoteTmuxError.commandFailed(
                exitCode: result.exitCode,
                stderr: String(
                    localized: "localTmux.primary.error.missingSessionIdentity",
                    defaultValue: "tmux created a session without reporting its identity."
                )
            )
        }
        return session
    }
}
