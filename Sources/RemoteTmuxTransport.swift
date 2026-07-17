import Foundation

/// The command and control boundary shared by local and SSH-backed tmux servers.
protocol RemoteTmuxTransport: Actor {
    nonisolated var host: RemoteTmuxHost { get }
    nonisolated var kind: RemoteTmuxTransportKind { get }
    nonisolated var validatesVersionBeforeSessionCreation: Bool { get }

    func run(_ arguments: [String]) async throws -> RemoteTmuxCommandResult
    func prepareForControlBurst() async throws -> Bool
    func shutdown() async
    nonisolated func spawnShutdown()
    nonisolated func controlProcessInvocation(
        sessionName: String,
        createIfMissing: Bool
    ) -> RemoteTmuxProcessInvocation
    nonisolated func workingDirectoryForCreatedSession(_ requested: String?) -> String?
    nonisolated func startupForCreatedSession() -> RemoteTmuxSessionStartup
}

struct RemoteTmuxSessionStartup: Equatable, Sendable {
    var environment: [String: String] = [:]
    var command: String? = nil
}

struct RemoteTmuxSessionOrderUpdate: Equatable, Sendable {
    let sessionId: String?
    let sessionName: String
    let order: Int

    var target: String { sessionId ?? sessionName }
    var tmuxArguments: [String] {
        ["set-option", "-t", target, "@cmux_order", String(order)]
    }
}

extension RemoteTmuxTransport {
    nonisolated var validatesVersionBeforeSessionCreation: Bool { true }

    func listSessions() async throws -> [RemoteTmuxSession] {
        let result = try await runTmux([
            "list-sessions", "-F", RemoteTmuxSessionListParser.formatString,
        ])
        if !result.succeeded {
            if Self.indicatesAuthRequired(result.stderr) {
                throw RemoteTmuxError.commandFailed(
                    exitCode: result.exitCode,
                    stderr: result.stderr
                )
            }
            if Self.indicatesNoServer(result.stderr) { return [] }
            throw commandFailure(result)
        }
        return RemoteTmuxSessionListParser.parse(result.stdout)
    }

    func createSession(name: String?, workingDirectory: String?) async throws -> RemoteTmuxSession {
        if validatesVersionBeforeSessionCreation {
            try await assertMinimumTmuxVersion(checkClientWhenNoServer: true)
        }
        let startup = startupForCreatedSession()
        let result = try await runTmux(Self.createSessionArguments(
            name: name,
            workingDirectory: workingDirectoryForCreatedSession(workingDirectory),
            startup: startup
        ))
        guard result.succeeded else { throw commandFailure(result) }
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

    nonisolated func workingDirectoryForCreatedSession(_ requested: String?) -> String? {
        requested
    }

    nonisolated func startupForCreatedSession() -> RemoteTmuxSessionStartup {
        RemoteTmuxSessionStartup()
    }

    static func createSessionArguments(
        name: String?,
        workingDirectory: String?,
        startup: RemoteTmuxSessionStartup = RemoteTmuxSessionStartup(),
        reportsIdentity: Bool = true
    ) -> [String] {
        var arguments = ["new-session", "-d"]
        if reportsIdentity {
            arguments += ["-P", "-F", RemoteTmuxSessionListParser.formatString]
        }
        for key in startup.environment.keys.sorted() {
            guard let value = startup.environment[key] else { continue }
            arguments += ["-e", "\(key)=\(value)"]
        }
        if let name = name.flatMap(RemoteTmuxHost.controlModeCommandName) {
            arguments += ["-s", name]
        }
        if let workingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !workingDirectory.isEmpty {
            arguments += ["-c", workingDirectory]
        }
        if let command = startup.command?.trimmingCharacters(in: .whitespacesAndNewlines),
           !command.isEmpty {
            arguments.append(command)
        }
        return arguments
    }

    func tmuxClientVersion() async throws -> RemoteTmuxVersion? {
        let result = try await run(["tmux", "-V"])
        guard result.succeeded else { throw commandFailure(result) }
        return RemoteTmuxVersion.parse(result.stdout)
    }

    private func tmuxServerVersionProbe() async throws -> (
        serverExists: Bool,
        version: RemoteTmuxVersion?
    ) {
        let result = try await runTmux(["display-message", "-p", "#{version}"])
        guard result.succeeded else {
            if Self.indicatesNoServer(result.stderr) {
                return (serverExists: false, version: nil)
            }
            throw commandFailure(result)
        }
        return (
            serverExists: true,
            version: RemoteTmuxVersion.parseServerFormat(result.stdout)
        )
    }

    private func serverSupportsRefreshClientSubscriptions() async throws -> Bool {
        let result = try await runTmux(["refresh-client", "-B", "cmux_probe::#{version}"])
        if result.succeeded { return true }
        if Self.indicatesRefreshClientSubscriptionUnsupported(result.stderr) { return false }
        if Self.indicatesRefreshClientNeedsCurrentClient(result.stderr) { return true }
        throw commandFailure(result)
    }

    func assertMinimumTmuxVersion(checkClientWhenNoServer: Bool) async throws {
        let serverProbe = try await tmuxServerVersionProbe()
        if serverProbe.serverExists {
            guard let version = serverProbe.version else {
                if try await serverSupportsRefreshClientSubscriptions() { return }
                throw RemoteTmuxError.unsupportedTmux(
                    detected: RemoteTmuxError.unknownVersionDisplayName
                )
            }
            try Self.assertSupportedTmuxVersion(version)
            return
        }
        guard checkClientWhenNoServer else { return }
        if let version = try await tmuxClientVersion() {
            try Self.assertSupportedTmuxVersion(version)
        }
    }

    private static func assertSupportedTmuxVersion(_ version: RemoteTmuxVersion) throws {
        if !version.meetsMinimum {
            throw RemoteTmuxError.unsupportedTmux(detected: version.displayString)
        }
    }

    func discoverMirrorSessions(createIfEmpty: Bool) async throws -> [RemoteTmuxSession] {
        try await assertMinimumTmuxVersion(checkClientWhenNoServer: createIfEmpty)
        var sessions = try await listSessions()
        if sessions.isEmpty, createIfEmpty {
            let arguments = Self.createSessionArguments(
                name: nil,
                workingDirectory: workingDirectoryForCreatedSession(nil),
                startup: startupForCreatedSession(),
                reportsIdentity: false
            )
            _ = try? await runTmux(arguments)
            sessions = try await listSessions()
        }
        return sessions
    }

    func persistCmuxSessionOrder(_ updates: [RemoteTmuxSessionOrderUpdate]) async throws {
        for update in updates {
            let result = try await runTmux(update.tmuxArguments)
            guard result.succeeded else { throw commandFailure(result) }
        }
    }

    @discardableResult
    func runTmux(_ arguments: [String]) async throws -> RemoteTmuxCommandResult {
        try await run(["tmux"] + arguments)
    }

    static func indicatesNoServer(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no server running")
            || lowered.contains("no sessions")
            || (lowered.contains("error connecting to /") && lowered.contains("/tmux-"))
    }

    static func indicatesRefreshClientSubscriptionUnsupported(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        let tokens = lowered.split { character in
            !(character.isLetter || character.isNumber || character == "-")
        }.map(String.init)
        let mentionsBFlag = tokens.enumerated().contains { index, token in
            if token == "-b" || token == "--b" { return true }
            guard token == "b" else { return false }
            if index > 0, tokens[index - 1] == "flag" || tokens[index - 1] == "option" {
                return true
            }
            if index > 1, tokens[index - 1] == "--" {
                let optionNoun = tokens[index - 2]
                return optionNoun == "flag" || optionNoun == "option"
            }
            return false
        }
        let rejectsOption = lowered.contains("unknown flag")
            || lowered.contains("unknown option")
            || lowered.contains("invalid option")
            || lowered.contains("illegal option")
        return mentionsBFlag && rejectsOption
    }

    static func indicatesRefreshClientNeedsCurrentClient(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("no current client")
            || lowered.contains("not a client")
            || lowered.contains("not a control client")
    }

    static func indicatesAuthRequired(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return lowered.contains("permission denied")
            || lowered.contains("host key verification failed")
            || lowered.contains("remote host identification has changed")
            || lowered.contains("authentication failed")
            || lowered.contains("too many authentication failures")
    }
}
