import Foundation

/// Talks to the user's local tmux server directly from cmux's GUI process.
actor LocalTmuxTransport: RemoteTmuxTransport {
    nonisolated let host: RemoteTmuxHost
    nonisolated let kind = RemoteTmuxTransportKind.local
    nonisolated let validatesVersionBeforeSessionCreation = false

    nonisolated private let shellExecutablePath: String
    nonisolated private let environment: [String: String]
    nonisolated private let defaultWorkingDirectory: String
    private let processExecutor: RemoteTmuxProcessExecutor

    init(
        host: RemoteTmuxHost,
        shellExecutablePath: String = "/bin/sh",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaultWorkingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        processExecutor: RemoteTmuxProcessExecutor = RemoteTmuxProcessExecutor()
    ) {
        self.host = host
        self.shellExecutablePath = shellExecutablePath
        var sanitizedEnvironment = environment
        sanitizedEnvironment.removeValue(forKey: "TMUX")
        sanitizedEnvironment.removeValue(forKey: "TMUX_PANE")
        self.environment = sanitizedEnvironment
        self.defaultWorkingDirectory = defaultWorkingDirectory
        self.processExecutor = processExecutor
    }

    func run(_ arguments: [String]) async throws -> RemoteTmuxCommandResult {
        guard arguments.first == "tmux" else {
            return try await processExecutor.run(
                executable: "/usr/bin/env",
                arguments: arguments,
                environment: environment
            )
        }
        let invocation = RemoteTmuxHost.tmuxResolverInvocation(
            arguments: Array(arguments.dropFirst()),
            commandName: "cmux-local-tmux"
        )
        return try await processExecutor.run(
            executable: shellExecutablePath,
            arguments: invocation.arguments,
            environment: environment
        )
    }

    func prepareForControlBurst() async throws -> Bool { true }

    func shutdown() async {}

    nonisolated func spawnShutdown() {}

    nonisolated func controlProcessInvocation(
        sessionName: String,
        createIfMissing: Bool
    ) -> RemoteTmuxProcessInvocation {
        let tmuxArguments = createIfMissing
            ? ["-CC", "new-session", "-A", "-s", sessionName]
            : ["-CC", "attach-session", "-t", sessionName]
        let resolver = RemoteTmuxHost.tmuxResolverInvocation(
            arguments: tmuxArguments,
            commandName: "cmux-local-tmux-control"
        )
        // tmux control mode still calls tcgetattr(3), even though cmux consumes
        // the protocol over pipes. SSH supplied that PTY via `-tt`; direct local
        // mode uses macOS's quiet script(1) wrapper to provide the same terminal
        // boundary without routing through sshd. Killing script also closes the
        // PTY and detaches its tmux client while leaving the server alive.
        return RemoteTmuxProcessInvocation(
            executablePath: "/usr/bin/script",
            arguments: ["-q", "/dev/null", shellExecutablePath] + resolver.arguments,
            environment: environment
        )
    }

    nonisolated func workingDirectoryForCreatedSession(_ requested: String?) -> String? {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : defaultWorkingDirectory
    }
}
