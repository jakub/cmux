import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the remote-tmux SSH auth path that backs `cmux ssh-tmux`:
/// the stderr → "needs interactive auth" classifier, the ControlMaster host-key
/// policy baked into the standard control args, and the interactive auth `ssh`
/// argv the CLI runs in the user's terminal to open the shared master. These
/// assert produced values and decisions, never source text.
@Suite struct RemoteTmuxAuthTests {

    @Test @MainActor func sessionsChangedFansOutAndObserverRemovalStopsDelivery() {
        let connection = RemoteTmuxControlConnection(
            sshHost: RemoteTmuxHost(destination: "user@host"),
            sessionName: "dev"
        )
        var firstCount = 0
        var secondCount = 0
        let first = connection.addObserver(onSessionsChanged: { firstCount += 1 })
        _ = connection.addObserver(onSessionsChanged: { secondCount += 1 })

        connection.handleMessageForTesting(.sessionsChanged)
        connection.removeObserver(first)
        connection.handleMessageForTesting(.sessionsChanged)

        #expect(firstCount == 1)
        #expect(secondCount == 2)
    }

    // MARK: - Auth-required classification

    @Test(arguments: [
        "Permission denied (publickey,password).",
        "user@host: Permission denied (publickey,keyboard-interactive).",
        "Host key verification failed.",
        "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@",
        "Authentication failed.",
        "Too many authentication failures",
    ])
    func classifiesInteractiveAuthFailures(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))
    }

    @Test(arguments: [
        "no server running on /tmp/tmux-501/default",
        "no sessions",
        "error connecting to /tmp/tmux-501/default (No such file or directory)",
        // Algorithm-negotiation failure: an interactive retry can't fix it, so it
        // must NOT route to auth (surfaces as a normal error instead).
        "no matching host key type found. their offer: ssh-rsa",
        // A success-time banner that merely mentions keyboard-interactive must not
        // be mistaken for an auth failure (the bare substring was dropped).
        "this server offers password and keyboard-interactive methods",
        "",
        "some unrelated failure",
    ])
    func doesNotClassifyNonAuthFailures(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))
    }

    @Test func noServerIsNotTreatedAsAuthRequired() {
        // A reachable host whose tmux server just isn't running must be treated as
        // zero sessions, never as an auth prompt — otherwise attaching would pop an
        // interactive ssh instead of offering to create a session.
        let stderr = "no server running on /tmp/tmux-501/default"
        #expect(RemoteTmuxSSHTransport.indicatesNoServer(stderr))
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))

        let socketMissing = "error connecting to /tmp/tmux-501/default (No such file or directory)"
        #expect(RemoteTmuxSSHTransport.indicatesNoServer(socketMissing))
        #expect(!RemoteTmuxSSHTransport.indicatesAuthRequired(socketMissing))
    }

    @Test func localPrimaryCreatesSessionWithoutSSH() async throws {
        let root = try temporaryDirectory(prefix: "local-tmux-bootstrap")
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appendingPathComponent("invocations.log")
        let fakeShell = root.appendingPathComponent("fake-shell")
        try writeExecutable(
            at: fakeShell,
            contents: """
            #!/bin/sh
            printf '%s\n' "$*" >> '\(invocationLog.path)'
            case " $* " in
              *" -V "*) printf 'tmux 3.4\n' ;;
              *) printf '$7:1:0:123:claude-work\n' ;;
            esac
            """
        )

        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            shellExecutablePath: fakeShell.path
        )
        let session = try await transport.createSession(
            name: "claude-work",
            workingDirectory: "/tmp/work tree"
        )

        #expect(session.id == "$7")
        #expect(session.name == "claude-work")
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(invocations.count == 2)
        #expect(invocations.allSatisfy { !$0.contains("ssh") })
        #expect(invocations[0].contains("cmux-local-tmux display-message -p #{pid}"))
        #expect(invocations[1].contains("cmux-local-tmux new-session -d -P -F"))
        #expect(invocations[1].hasSuffix("-s claude-work -c /tmp/work tree"))
    }

    @Test func localPrimaryFirstServerIsOwnedByLaunchd() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/cmux-launchd-\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = ProcessInfo.processInfo.environment
        environment["TMUX_TMPDIR"] = root.path
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        environment["CMUX_SOCKET_PATH"] = "do-not-leak-to-launchd"
        environment["OP_SERVICE_ACCOUNT_TOKEN"] = "do-not-leak-to-launchd"
        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            environment: environment,
            defaultWorkingDirectory: root.path
        )
        let socketPath = root
            .appendingPathComponent("tmux-\(getuid())", isDirectory: true)
            .appendingPathComponent("default", isDirectory: false)
            .path
        let socketDirectory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: socketDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: socketDirectory.path)
        try createStaleUnixSocket(at: socketPath)
        let serviceLabel = localTmuxLaunchdServiceLabel(socketPath: socketPath)
        let serviceTarget = "gui/\(getuid())/\(serviceLabel)"
        defer {
            _ = try? runProcess(
                executable: "/bin/launchctl",
                arguments: ["bootout", serviceTarget],
                environment: environment
            )
        }

        do {
            _ = try await transport.createSession(
                name: "cmux-launchd-\(String(UUID().uuidString.prefix(8)))",
                workingDirectory: nil
            )
            let service = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["print", serviceTarget],
                environment: environment
            )

            #expect(service.status == 0)
            #expect(service.stdout.contains("state = running"))
            #expect(service.stdout.contains("tmux"))
            #expect(service.stdout.contains("-D"))
            #expect(!service.stdout.contains("do-not-leak-to-launchd"))

            let exitEmpty = try await transport.runTmux([
                "show-options", "-sv", "exit-empty",
            ])
            #expect(exitEmpty.succeeded)
            #expect(exitEmpty.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "on")
        } catch {
            _ = try? await transport.runTmux(["kill-server"])
            _ = try? runProcess(
                executable: "/bin/launchctl",
                arguments: ["bootout", serviceTarget],
                environment: environment
            )
            throw error
        }

        let killed = try await transport.runTmux(["kill-server"])
        #expect(killed.succeeded)
        let stoppedService = try await waitForLaunchdService(
            serviceTarget,
            environment: environment,
            containing: "state = not running"
        )
        #expect(stoppedService.status == 0)
        #expect(stoppedService.stdout.contains("state = not running"))
    }

    @Test func localPrimaryColdLaunchdJobReplacesStaleSocketBeforeReady() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/cmux-launchd-cold-\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        let socketDirectory = root.appendingPathComponent("tmux-\(getuid())", isDirectory: true)
        let socketPath = socketDirectory.appendingPathComponent("default").path
        try FileManager.default.createDirectory(
            at: socketDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try createStaleUnixSocket(at: socketPath)
        let staleSocketIdentity = try #require(fileIdentity(at: socketPath))

        var environment = ProcessInfo.processInfo.environment
        environment["TMUX_TMPDIR"] = root.path
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        let tmuxPath = try #require(tmuxExecutablePath(environment: environment))

        let delayedLauncher = root.appendingPathComponent("delayed-tmux-server")
        try writeExecutable(
            at: delayedLauncher,
            contents: """
            #!/bin/sh
            /bin/sleep 6
            /bin/rm -f -- '\(socketPath)'
            exec '\(tmuxPath)' -D
            """
        )
        let serviceLabel = localTmuxLaunchdServiceLabel(socketPath: socketPath)
        let serviceTarget = "gui/\(getuid())/\(serviceLabel)"
        let jobURL = root.appendingPathComponent("delayed-tmux-server.plist")
        let jobEnvironment = [
            "HOME": environment["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TMUX_TMPDIR": root.path,
            "USER": environment["USER"] ?? NSUserName(),
        ]
        try writeLaunchdJob(
            at: jobURL,
            label: serviceLabel,
            programArguments: [delayedLauncher.path],
            environment: jobEnvironment
        )
        let bootstrap = try runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(getuid())", jobURL.path],
            environment: environment
        )
        try #require(bootstrap.status == 0)
        defer {
            _ = try? runProcess(
                executable: "/bin/launchctl",
                arguments: ["bootout", serviceTarget],
                environment: environment
            )
        }

        let serverBootstrapper = LaunchdLocalTmuxServerBootstrapper()
        try await serverBootstrapper.startServer(
            environment: environment,
            shellExecutablePath: "/bin/sh"
        )

        let readySocketIdentity = try #require(fileIdentity(at: socketPath))
        try #require(readySocketIdentity != staleSocketIdentity)
        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            environment: environment,
            defaultWorkingDirectory: root.path
        )
        let ready = try await transport.runTmux(["display-message", "-p", "#{pid}"])
        #expect(ready.succeeded)
    }

    @Test func localPrimaryLeavesExistingServerOwnershipAndExitPolicyUntouched() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/cmux-existing-\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var environment = ProcessInfo.processInfo.environment
        environment["TMUX_TMPDIR"] = root.path
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            environment: environment,
            defaultWorkingDirectory: root.path
        )
        do {
            let start = try await transport.runTmux([
                "new-session", "-d", "-s", "already-running",
            ])
            #expect(start.succeeded)
            let policy = try await transport.runTmux([
                "set-option", "-s", "exit-empty", "off",
            ])
            #expect(policy.succeeded)

            _ = try await transport.createSession(
                name: "cmux-added",
                workingDirectory: nil
            )
            let exitEmpty = try await transport.runTmux([
                "show-options", "-sv", "exit-empty",
            ])
            #expect(exitEmpty.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "off")

            let socketPath = root
                .appendingPathComponent("tmux-\(getuid())", isDirectory: true)
                .appendingPathComponent("default", isDirectory: false)
                .path
            let serviceTarget =
                "gui/\(getuid())/\(localTmuxLaunchdServiceLabel(socketPath: socketPath))"
            let service = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["print", serviceTarget],
                environment: environment
            )
            #expect(service.status != 0)
        } catch {
            _ = try? await transport.runTmux(["kill-server"])
            throw error
        }
        _ = try? await transport.runTmux(["kill-server"])
    }

    @Test func localPrimaryDefaultsImplicitWorkingDirectoryToHome() async throws {
        let root = try temporaryDirectory(prefix: "local-tmux-bootstrap-home")
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appendingPathComponent("invocations.log")
        let fakeShell = root.appendingPathComponent("fake-shell")
        try writeExecutable(
            at: fakeShell,
            contents: """
            #!/bin/sh
            printf '%s\n' "$*" > '\(invocationLog.path)'
            printf '$8:1:0:124:home-session\n'
            """
        )

        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            shellExecutablePath: fakeShell.path,
            defaultWorkingDirectory: "/Users/tester"
        )
        _ = try await transport.createSession(name: nil, workingDirectory: nil)

        let invocation = try String(contentsOf: invocationLog, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(invocation.hasSuffix("-c /Users/tester"))
    }

    @Test func localPrimaryTmuxShellLoadsBundledCmuxIntegration() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/cmux-shell-\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let record = root.appendingPathComponent("startup.txt", isDirectory: false)
        let contextRecord = root.appendingPathComponent("context.txt", isDirectory: false)
        let contextTrigger = root.appendingPathComponent("capture-context", isDirectory: false)
        let readyChannel = "cmux-shell-ready-\(UUID().uuidString)"
        let contextReadyChannel = "cmux-context-ready-\(UUID().uuidString)"
        let workspaceID = UUID().uuidString
        let surfaceID = UUID().uuidString
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try """
        _cmux_test_record_startup() {
            print -r -- "${CMUX_CLAUDE_WRAPPER_SHIM:-}" > '\(record.path)'
            print -r -- "$PATH" >> '\(record.path)'
            tmux wait-for -S '\(readyChannel)'
            precmd_functions=("${(@)precmd_functions:#_cmux_test_record_startup}")
        }
        _cmux_test_record_context() {
            [[ -e '\(contextTrigger.path)' ]] || return 0
            print -r -- "${CMUX_WORKSPACE_ID:-}|${CMUX_TAB_ID:-}|${CMUX_SURFACE_ID:-}|${CMUX_PANEL_ID:-}" > '\(contextRecord.path)'
            tmux wait-for -S '\(contextReadyChannel)'
            precmd_functions=("${(@)precmd_functions:#_cmux_test_record_context}")
        }
        precmd_functions+=(_cmux_test_record_startup _cmux_test_record_context)
        """.write(
            to: home.appendingPathComponent(".zshrc", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationDirectory = repoRoot
            .appendingPathComponent("Resources/shell-integration", isDirectory: true)
        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            environment: [
                "CMUX_SHELL_INTEGRATION_DIR": integrationDirectory.path,
                "HOME": home.path,
                "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                "SHELL": "/bin/zsh",
                "TERM": "xterm-256color",
                "TMPDIR": root.path,
                "TMUX_TMPDIR": root.path,
            ],
            defaultWorkingDirectory: home.path
        )
        let startup: [String]
        let context: [String]
        do {
            _ = try await transport.createSession(
                name: "cmux-shell-\(String(UUID().uuidString.prefix(8)))",
                workingDirectory: nil
            )
            _ = try await transport.runTmux(["wait-for", readyChannel])
            startup = try String(contentsOf: record, encoding: .utf8)
                .components(separatedBy: .newlines)

            let panes = try await transport.runTmux(["list-panes", "-a", "-F", "#{pane_id}"])
            let paneID = try #require(
                panes.stdout.split(whereSeparator: \.isNewline).first.map(String.init)
            )
            _ = try await transport.runTmux([
                "set-option", "-p", "-t", paneID, "@cmux_workspace_id", workspaceID,
            ])
            _ = try await transport.runTmux([
                "set-option", "-p", "-t", paneID, "@cmux_surface_id", surfaceID,
            ])
            try "".write(to: contextTrigger, atomically: true, encoding: .utf8)
            _ = try await transport.runTmux(["send-keys", "-t", paneID, "Enter"])
            _ = try await transport.runTmux(["wait-for", contextReadyChannel])
            context = try String(contentsOf: contextRecord, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init)
        } catch {
            _ = try? await transport.runTmux(["kill-server"])
            bootoutLocalTmuxLaunchdService(
                tmuxRoot: root,
                environment: ["PATH": "/usr/bin:/bin"]
            )
            throw error
        }
        _ = try? await transport.runTmux(["kill-server"])
        bootoutLocalTmuxLaunchdService(
            tmuxRoot: root,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let shimPath = try #require(startup.first)
        #expect(!shimPath.isEmpty)
        #expect(FileManager.default.isExecutableFile(atPath: shimPath))
        let shellPath = try #require(startup.dropFirst().first)
        #expect(shellPath.split(separator: ":").first.map(String.init) ==
            URL(fileURLWithPath: shimPath).deletingLastPathComponent().path)
        #expect(context == [workspaceID, workspaceID, surfaceID, surfaceID])
    }

    @Test func localTransportRunsDiscoveryAndCreationWithoutSSH() async throws {
        let root = try temporaryDirectory(prefix: "local-tmux-direct-commands")
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appendingPathComponent("invocations.log")
        let fakeShell = root.appendingPathComponent("fake-shell")
        try writeExecutable(
            at: fakeShell,
            contents: """
            #!/bin/sh
            printf '%s|TMUX=%s|TMUX_PANE=%s|TMUX_TMPDIR=%s\n' \
              "$*" "${TMUX-}" "${TMUX_PANE-}" "${TMUX_TMPDIR-}" >> '\(invocationLog.path)'
            case " $* " in
              *" list-sessions "*) printf '$4:1:0:123:direct-work\n' ;;
              *" new-session "*) printf '$5:1:0:124:home-work\n' ;;
            esac
            """
        )

        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            shellExecutablePath: fakeShell.path,
            environment: [
                "HOME": "/Users/tester",
                "TMUX": "/tmp/tmux-501/default,99,0",
                "TMUX_PANE": "%9",
                "TMUX_TMPDIR": "/tmp/direct-lab",
            ],
            defaultWorkingDirectory: "/Users/tester"
        )
        let sessions = try await transport.listSessions()
        let created = try await transport.createSession(name: "home-work", workingDirectory: nil)

        #expect(sessions.map(\.name) == ["direct-work"])
        #expect(created.name == "home-work")
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(invocations.count == 3)
        #expect(invocations.allSatisfy { !$0.contains("ssh") })
        #expect(invocations.allSatisfy { $0.contains("|TMUX=|TMUX_PANE=|TMUX_TMPDIR=/tmp/direct-lab") })
        #expect(invocations[0].contains("cmux-local-tmux list-sessions -F"))
        #expect(invocations[1].contains("cmux-local-tmux display-message -p #{pid}"))
        #expect(invocations[2].hasPrefix("-c "))
        #expect(invocations[2].contains("cmux-local-tmux new-session -d -P -F"))
        #expect(invocations[2].contains("-s home-work -c /Users/tester"))
    }

    @Test func localTransportDiscoveryCreatesFirstSessionInHomeDirectory() async throws {
        let root = try temporaryDirectory(prefix: "local-tmux-direct-discovery")
        defer { try? FileManager.default.removeItem(at: root) }
        let invocationLog = root.appendingPathComponent("invocations.log")
        let serverState = root.appendingPathComponent("server-exists")
        let fakeShell = root.appendingPathComponent("fake-shell")
        try writeExecutable(
            at: fakeShell,
            contents: """
            #!/bin/sh
            printf '%s\n' "$*" >> '\(invocationLog.path)'
            case " $* " in
              *" display-message "*)
                if [ -f '\(serverState.path)' ]; then printf 'tmux 3.4\n'; else printf 'no server running\n' >&2; exit 1; fi ;;
              *" -V "*) printf 'tmux 3.4\n' ;;
              *" list-sessions "*)
                if [ -f '\(serverState.path)' ]; then printf '$9:1:0:125:home-work\n'; else printf 'no server running\n' >&2; exit 1; fi ;;
              *" new-session "*) touch '\(serverState.path)' ;;
            esac
            """
        )

        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            shellExecutablePath: fakeShell.path,
            defaultWorkingDirectory: "/Users/tester",
            serverBootstrapper: NoopLocalTmuxServerBootstrapper()
        )
        let sessions = try await transport.discoverMirrorSessions(createIfEmpty: true)

        #expect(sessions.map(\.name) == ["home-work"])
        let invocations = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        #expect(invocations.allSatisfy { !$0.contains("ssh") })
        #expect(invocations.contains {
            $0.contains("new-session -d -e OP_BIOMETRIC_UNLOCK_ENABLED=true")
                && $0.hasSuffix("-c /Users/tester")
        })
    }

    @Test func localTransportBuildsDirectControlInvocationWithSanitizedEnvironment() {
        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            shellExecutablePath: "/test/bin/sh",
            environment: [
                "HOME": "/Users/tester",
                "TMUX": "/tmp/tmux-501/default,99,0",
                "TMUX_PANE": "%9",
                "TMUX_TMPDIR": "/tmp/direct-lab",
            ]
        )

        let invocation = transport.controlProcessInvocation(
            sessionName: "work tree",
            createIfMissing: false
        )

        #expect(transport.kind == .local)
        #expect(invocation.executablePath == "/usr/bin/script")
        #expect(invocation.arguments.prefix(3) == ["-q", "/dev/null", "/test/bin/sh"])
        #expect(invocation.arguments.suffix(4) == ["-CC", "attach-session", "-t", "work tree"])
        #expect(invocation.environment?["TMUX"] == nil)
        #expect(invocation.environment?["TMUX_PANE"] == nil)
        #expect(invocation.environment?["TMUX_TMPDIR"] == "/tmp/direct-lab")
        #expect(invocation.environment?["HOME"] == "/Users/tester")
        #expect(invocation.environment?["OP_BIOMETRIC_UNLOCK_ENABLED"] == "true")
        #expect(
            transport.startupForCreatedSession().environment["OP_BIOMETRIC_UNLOCK_ENABLED"] == "true"
        )
    }

    @Test func localTransportPreservesExplicitlyDisabled1PasswordIntegration() {
        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            environment: ["OP_BIOMETRIC_UNLOCK_ENABLED": "false"]
        )

        let invocation = transport.controlProcessInvocation(
            sessionName: "work",
            createIfMissing: false
        )

        #expect(invocation.environment?["OP_BIOMETRIC_UNLOCK_ENABLED"] == "false")
        #expect(
            transport.startupForCreatedSession().environment["OP_BIOMETRIC_UNLOCK_ENABLED"] == "false"
        )
    }

    @Test @MainActor func controllerSelectsDirectTransportOnlyForLocalPrimaryEndpoint() {
        let enabled = RemoteTmuxController(localPrimaryEnabled: true)
        #expect(enabled.transport(for: RemoteTmuxController.localPrimaryHost).kind == .local)
        #expect(enabled.transport(for: RemoteTmuxHost(destination: "user@remote")).kind == .ssh)

        let disabled = RemoteTmuxController(localPrimaryEnabled: false)
        #expect(disabled.transport(for: RemoteTmuxController.localPrimaryHost).kind == .ssh)
    }

    @Test @MainActor func directLocalControlStreamAttachesToRealTmux() async throws {
        // tmux's socket path is also subject to macOS's short AF_UNIX limit, so
        // use a deliberately compact root instead of XCTest's long temp path.
        let root = URL(
            fileURLWithPath: "/tmp/cmux-direct-\(String(UUID().uuidString.prefix(8)))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = ProcessInfo.processInfo.environment
        environment["TMUX_TMPDIR"] = root.path
        environment["TMUX"] = "/tmp/wrong-server,99,0"
        environment["TMUX_PANE"] = "%99"
        let transport = LocalTmuxTransport(
            host: RemoteTmuxController.localPrimaryHost,
            environment: environment,
            defaultWorkingDirectory: root.path
        )
        let session = try await transport.createSession(
            name: "cmux-direct-\(String(UUID().uuidString.prefix(8)))",
            workingDirectory: nil
        )
        let connection = RemoteTmuxControlConnection(
            sessionName: session.name,
            transport: transport
        )

        do {
            try connection.start()
            #expect(await connection.waitUntilConnected())
            #expect(connection.transportKind == .local)
            #expect(connection.sessionId != nil)
        } catch {
            connection.stop()
            _ = try? await transport.runTmux(["kill-server"])
            bootoutLocalTmuxLaunchdService(tmuxRoot: root, environment: environment)
            throw error
        }

        connection.stop()
        _ = try? await transport.runTmux(["kill-server"])
        bootoutLocalTmuxLaunchdService(tmuxRoot: root, environment: environment)
    }

    @Test func staleSSHAgentErrorDoesNotMaskPermissionDeniedAuthRequirement() {
        let stderr = """
        Error connecting to agent: No such file or directory
        user@host: Permission denied (publickey,password).
        """
        #expect(!RemoteTmuxSSHTransport.indicatesNoServer(stderr))
        #expect(RemoteTmuxSSHTransport.indicatesAuthRequired(stderr))
    }

    @Test(arguments: [
        "command refresh-client: unknown flag -B",
        "refresh-client: unknown option -- B",
        "refresh-client: invalid option -- B",
        "refresh-client: illegal option -- B",
    ])
    func classifiesUnsupportedRefreshClientSubscriptionProbe(_ stderr: String) {
        #expect(RemoteTmuxSSHTransport.indicatesRefreshClientSubscriptionUnsupported(stderr))
        #expect(!RemoteTmuxSSHTransport.indicatesRefreshClientNeedsCurrentClient(stderr))
    }

    @Test(arguments: [
        "refresh-client: unknown option while building command",
        "refresh-client: unknown option btree",
        "refresh-client: invalid option because backend returned an error",
    ])
    func doesNotClassifyUnrelatedBWordsAsUnsupportedRefreshClientSubscriptionProbe(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesRefreshClientSubscriptionUnsupported(stderr))
        #expect(!RemoteTmuxSSHTransport.indicatesRefreshClientNeedsCurrentClient(stderr))
    }

    @Test(arguments: [
        "no current client",
        "not a control client",
        "refresh-client: not a client",
    ])
    func classifiesRecognizedRefreshClientSubscriptionProbeWithoutClient(_ stderr: String) {
        #expect(!RemoteTmuxSSHTransport.indicatesRefreshClientSubscriptionUnsupported(stderr))
        #expect(RemoteTmuxSSHTransport.indicatesRefreshClientNeedsCurrentClient(stderr))
    }

    // MARK: - Host-key policy in the standard control args

    @Test func nonInteractiveControlArgsDoNotPinHostKeyPolicy() {
        // The mirror's batch path must NOT force StrictHostKeyChecking — it honors
        // the user's ~/.ssh/config, and an unknown host key fails BatchMode (which
        // routes to interactive auth) rather than being silently trusted.
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
        #expect(!args.contains(where: { $0.hasPrefix("StrictHostKeyChecking=") }))
        #expect(consecutive(args, "-o", "BatchMode=yes"))
        #expect(consecutive(args, "-o", "ControlPath=\(host.controlSocketPath)"))
    }

    @Test func nonBatchControlArgsOmitBatchMode() {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: false)
        #expect(!args.contains("BatchMode=yes"))
    }

    @Test func controlModeArgumentsAreNonInteractive() {
        let host = RemoteTmuxHost(destination: "user@host")
        let args = host.controlModeArguments(sessionName: "work", createIfMissing: false)
        #expect(consecutive(args, "-o", "BatchMode=yes"))
        #expect(!args.contains("BatchMode=no"))
    }

    @Test func controlModeArgumentsFindUserLocalTmuxWithMinimalSSHPath() throws {
        let root = try temporaryDirectory(prefix: "remote-tmux-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let emptyPath = root.appendingPathComponent("empty-path", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyPath, withIntermediateDirectories: true)
        let fakeTmux = bin.appendingPathComponent("tmux")
        try writeExecutable(
            at: fakeTmux,
            contents: """
            #!/bin/sh
            printf 'fake-tmux'
            for arg in "$@"; do printf ' <%s>' "$arg"; done
            printf '\\n'
            """
        )

        let host = RemoteTmuxHost(destination: "user@example.test")
        let args = host.controlModeArguments(sessionName: "work session", createIfMissing: false)
        let dashDash = try #require(args.firstIndex(of: "--"))
        let command = args[dashDash + 2]
        let result = try runShell(
            command,
            environment: [
                "HOME": home.path,
                "PATH": emptyPath.path,
            ]
        )

        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "fake-tmux <-CC> <attach-session> <-t> <work session>\n")
    }

    @Test func controlModeArgumentsUseRemoteTmuxResolverAfterDestinationGuard() throws {
        let host = RemoteTmuxHost(destination: "-oProxyCommand=evil")
        let args = host.controlModeArguments(sessionName: "work session", createIfMissing: false)
        let dashDash = try #require(args.firstIndex(of: "--"))
        #expect(args[dashDash + 1] == "-oProxyCommand=evil")
        let remoteCommand = args[dashDash + 2]
        #expect(!remoteCommand.contains("\n"))
        #expect(remoteCommand.contains("/opt/homebrew/bin"))
        #expect(remoteCommand.hasSuffix("'cmux-remote-tmux' '-CC' 'attach-session' '-t' 'work session'"))
    }

    @Test func controlArgsAppendPortAndIdentity() {
        let host = RemoteTmuxHost(destination: "user@host", port: 2222, identityFile: "/keys/id")
        let args = host.sshControlArguments(controlPersistSeconds: 180, batchMode: true)
        #expect(consecutive(args, "-p", "2222"))
        #expect(consecutive(args, "-i", "/keys/id"))
    }

    @Test func connectionHashVariesByPortAndIdentity() {
        // The controller keys transports / connections / windows / persistence by
        // connectionHash, so distinct endpoints must produce distinct hashes (and
        // the same endpoint a stable one) — otherwise a command could be routed to
        // the wrong server through a shared transport/master.
        let base = RemoteTmuxHost(destination: "user@host")
        #expect(base.connectionHash == RemoteTmuxHost(destination: "user@host").connectionHash)
        #expect(base.connectionHash != RemoteTmuxHost(destination: "user@host", port: 2222).connectionHash)
        #expect(base.connectionHash != RemoteTmuxHost(destination: "user@host", identityFile: "/keys/id").connectionHash)
        #expect(
            RemoteTmuxHost(destination: "user@host", port: 2222).connectionHash
                != RemoteTmuxHost(destination: "user@host", identityFile: "/keys/id").connectionHash
        )
    }

    @Test func controlSocketPathVariesByPortAndIdentity() {
        // Distinct endpoints (same destination, different port/identity) must NOT
        // share a ControlMaster socket — otherwise a destructive command could
        // route to the wrong server through the shared master.
        let base = RemoteTmuxHost(destination: "user@host")
        let otherPort = RemoteTmuxHost(destination: "user@host", port: 2222)
        let otherIdentity = RemoteTmuxHost(destination: "user@host", identityFile: "/keys/id")
        #expect(base.controlSocketPath != otherPort.controlSocketPath)
        #expect(base.controlSocketPath != otherIdentity.controlSocketPath)
        #expect(otherPort.controlSocketPath != otherIdentity.controlSocketPath)
        // Deterministic: same identity → same socket path.
        #expect(base.controlSocketPath == RemoteTmuxHost(destination: "user@host").controlSocketPath)
    }

    @Test func controlSocketPathFitsUnixLimitForLongDestination() {
        // Regression: a long SSH destination produced a ControlPath that, once
        // OpenSSH appended its transient `.XXXXXXXXXXXXXXXX` bind suffix,
        // overflowed the AF_UNIX sun_path limit — `ssh` died with
        // `unix_listener: path "…" too long for Unix domain socket`. The path
        // OpenSSH actually binds (ControlPath + transient suffix), not the renamed
        // ControlPath, is what must fit.
        let host = RemoteTmuxHost(destination: "dev-host-2a-7059f1dc.us-west-2.example.internal")
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(host.controlSocketPath))
    }

    @Test func controlSocketPathFitsUnixLimitForExtremeDestination() {
        // Even a pathological destination must stay within budget; the hash
        // (uniqueness) is preserved, only the slug is trimmed.
        let host = RemoteTmuxHost(destination: String(repeating: "very-long-host.example.com.", count: 20))
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(host.controlSocketPath))
        // The collision-resistant hash is never trimmed away.
        #expect(host.controlSocketPath.hasSuffix("-\(host.connectionHash).sock"))
    }

    @Test func controlSocketPathTrimmingPreservesEndpointUniqueness() {
        // Two long destinations that share a slug prefix (so the slug alone would
        // collapse after trimming) must still get distinct socket paths via the
        // untrimmed connectionHash — otherwise destructive commands could route to
        // the wrong host through a shared master.
        let a = RemoteTmuxHost(destination: "dev-host-2a-7059f1dc.us-west-2.example.internal")
        let b = RemoteTmuxHost(destination: "dev-host-2a-7059f1dc.us-east-1.example.internal")
        #expect(a.controlSocketPath != b.controlSocketPath)
        // …and both still fit the limit after trimming.
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(a.controlSocketPath))
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(b.controlSocketPath))
    }

    @Test func controlSocketPathFitnessPredicateMatchesAFUnixLimit() {
        // The predicate that `ensureControlSocketDirectory()` gates on: a path
        // leaving room for OpenSSH's 17-byte transient suffix fits; one that does
        // not, does not. macOS sun_path is 104 bytes incl. NUL (103 usable), so
        // the longest fitting ControlPath is 103 - 17 = 86 bytes.
        let fitting = String(repeating: "a", count: 86)
        let overflowing = String(repeating: "a", count: 87)
        #expect(RemoteTmuxHost.controlSocketPathFitsUnixLimit(fitting))
        #expect(!RemoteTmuxHost.controlSocketPathFitsUnixLimit(overflowing))
    }

    @Test func controlModeCommandNameRejectsLineDelimitersAndControlScalars() {
        #expect(RemoteTmuxHost.controlModeCommandName("work session") == "work session")
        #expect(RemoteTmuxHost.controlModeCommandName("  work session  ") == "work session")
        #expect(RemoteTmuxHost.controlModeCommandName("") == nil)
        #expect(RemoteTmuxHost.controlModeCommandName("safe\nrename-window injected") == nil)
        #expect(RemoteTmuxHost.controlModeCommandName("safe\rrename-window injected") == nil)
        #expect(RemoteTmuxHost.controlModeCommandName("safe\u{7f}") == nil)
    }

    @Test func confirmedControlModeNamesPreserveSafeSpacing() {
        #expect(RemoteTmuxHost.controlModeLineSafeName(" work session ") == " work session ")
        #expect(RemoteTmuxHost.controlModeLineSafeName("work\tbad") == nil)
        #expect(RemoteTmuxHost.controlModeLineSafeName("work\nbad") == nil)
    }

    @Test func sendKeysHexArgumentsAreLowercaseSpaceSeparatedBytes() {
        #expect(RemoteTmuxControlConnection.hexByteArguments(Data([0x00, 0x0f, 0x10, 0xff])) == "00 0f 10 ff")
        #expect(RemoteTmuxControlConnection.hexByteArguments(Data()) == "")
    }

    @Test @MainActor func pastePaneRejectsDisconnectedControlStream() {
        let connection = RemoteTmuxControlConnection(sshHost: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        #expect(connection.pastePane(paneId: 1, text: "/tmp/image.png") == false)
        #expect(connection.pastePane(paneId: 1, text: "") == false)
    }

    @Test @MainActor func sessionRenamedUpdatesTrackedNameAndEmitsObserverWithoutSessionId() {
        // A documented `%session-renamed <name>` must still track the new name
        // (reused for reconnect) and fire the observer the mirror listens on.
        let connection = RemoteTmuxControlConnection(
            sshHost: RemoteTmuxHost(destination: "user@host"), sessionName: "old"
        )
        var observed: (old: String, new: String)?
        let token = connection.addObserver(onSessionChanged: { old, new in
            observed = (old, new)
        })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.sessionRenamed(sessionId: nil, name: "dev", idBearingName: nil))

        #expect(connection.sessionName == "dev")
        #expect(connection.sessionId == nil)
        #expect(observed?.old == "old")
        #expect(observed?.new == "dev")
    }

    @Test @MainActor func sessionRenamedUpdatesTrackedIdWhenTmuxSuppliesOne() {
        let connection = RemoteTmuxControlConnection(
            sshHost: RemoteTmuxHost(destination: "user@host"), sessionName: "old"
        )
        connection.handleMessageForTesting(.sessionChanged(sessionId: 7, name: "old"))

        connection.handleMessageForTesting(.sessionRenamed(sessionId: 7, name: "$7 dev", idBearingName: "dev"))

        #expect(connection.sessionName == "dev")
        #expect(connection.sessionId == 7)
    }

    @Test @MainActor func sessionRenamedIgnoresDifferentSessionId() {
        let connection = RemoteTmuxControlConnection(
            sshHost: RemoteTmuxHost(destination: "user@host"), sessionName: "old"
        )
        connection.handleMessageForTesting(.sessionChanged(sessionId: 7, name: "old"))
        var observed: (old: String, new: String)?
        let token = connection.addObserver(onSessionChanged: { old, new in
            observed = (old, new)
        })
        defer { connection.removeObserver(token) }

        connection.handleMessageForTesting(.sessionRenamed(sessionId: 8, name: "$8 other", idBearingName: "other"))

        #expect(connection.sessionName == "old")
        #expect(connection.sessionId == 7)
        #expect(observed == nil)
    }

    @Test @MainActor func sessionRenamedIgnoresIdBearingRenameUntilSessionIdIsKnown() {
        let connection = RemoteTmuxControlConnection(
            sshHost: RemoteTmuxHost(destination: "user@host"), sessionName: "old"
        )

        connection.handleMessageForTesting(.sessionRenamed(sessionId: 7, name: "$7 dev", idBearingName: "dev"))

        #expect(connection.sessionName == "old")
        #expect(connection.sessionId == nil)
    }

    @Test @MainActor func controllerRekeysCachedConnectionWhenSessionIsRenamed() {
        let controller = RemoteTmuxController()
        let host = RemoteTmuxHost(destination: "user@host")
        let connection = RemoteTmuxControlConnection(sshHost: host, sessionName: "old")
        controller.cacheConnection(connection)

        #expect(controller.connection(host: host, sessionName: "old") === connection)

        connection.handleMessageForTesting(.sessionRenamed(sessionId: nil, name: "dev", idBearingName: nil))

        #expect(controller.connection(host: host, sessionName: "old") == nil)
        #expect(controller.connection(host: host, sessionName: "dev") === connection)
    }

    @Test @MainActor func attachBlockDrainQueuesInitialWindowRequest() {
        let connection = RemoteTmuxControlConnection(sshHost: RemoteTmuxHost(destination: "user@host"), sessionName: "work")
        let pipe = Pipe()
        let writer = RemoteTmuxControlPipeWriter(
            handle: pipe.fileHandleForWriting,
            label: "remote-tmux-initial-window-request-test",
            maxPendingBytes: 4096,
            onFailure: {}
        )
        connection.installStdinWriterForTesting(writer)
        defer {
            writer.close()
            try? pipe.fileHandleForReading.close()
        }

        connection.handleMessageForTesting(.enter)
        #expect(connection.pendingCommandKindsForTesting.isEmpty)

        connection.handleMessageForTesting(.commandResult(commandNumber: 1, lines: [], isError: false))

        #expect(connection.pendingCommandKindsForTesting == [
            .listWindows(reorderGeneration: 0, retainedPaneIDs: [])
        ])
    }

    @Test func pastePaneCommandsProtectOptionLookingText() throws {
        let commands = try #require(RemoteTmuxControlConnection.pastePaneCommands(paneId: 7, text: "-n not-an-option"))
        #expect(commands.setBuffer == "set-buffer -b cmux-paste-7 -- '-n not-an-option'")
        #expect(commands.pasteBuffer == "paste-buffer -p -d -b cmux-paste-7 -t %7")
    }

    @Test func pastePaneCommandsRejectEmptyText() {
        #expect(RemoteTmuxControlConnection.pastePaneCommands(paneId: 7, text: "") == nil)
    }

    // MARK: - Interactive auth invocation (what `cmux ssh-tmux` runs in the tty)

    @Test func interactiveAuthInvocationShape() {
        let host = RemoteTmuxHost(destination: "user@host")
        let argv = host.interactiveAuthInvocation(sshExecutablePath: "/usr/bin/ssh")
        // Executable first, so the CLI can exec argv[0] directly.
        #expect(argv.first == "/usr/bin/ssh")
        // Force interactive mode so the prompt works even under ssh_config BatchMode yes…
        #expect(consecutive(argv, "-o", "BatchMode=no"))
        #expect(!argv.contains("BatchMode=yes"))
        // No -f: foreground auth keeps the post-auth ControlMaster retry deterministic.
        #expect(!argv.contains("-f"))
        // Keep -n explicitly; -f used to imply stdin from /dev/null.
        #expect(argv.contains("-n"))
        // The master must persist after the foreground client exits so discovery / the
        // -CC client can multiplex over it.
        #expect(argv.contains(where: { $0.hasPrefix("ControlPersist=") }))
        // …but do NOT pin StrictHostKeyChecking — honor the user's host-key policy.
        #expect(!argv.contains(where: { $0.hasPrefix("StrictHostKeyChecking=") }))
        // Opens the SAME shared master that discovery / the -CC client multiplex over.
        #expect(consecutive(argv, "-o", "ControlPath=\(host.controlSocketPath)"))
        // `--` guards the destination; the remote command is the trivial `true`.
        #expect(Array(argv.suffix(3)) == ["--", "user@host", "true"])
    }

    @Test func interactiveAuthInvocationGuardsDashPrefixedDestination() {
        // A dash-prefixed destination must sit AFTER `--`, never be parsed as an
        // ssh option (defense in depth; the dialog/socket also reject it upstream).
        let host = RemoteTmuxHost(destination: "-oProxyCommand=evil")
        let argv = host.interactiveAuthInvocation()
        guard let dashDash = argv.firstIndex(of: "--"),
              let dest = argv.firstIndex(of: "-oProxyCommand=evil") else {
            Issue.record("expected both `--` and the destination in the argv")
            return
        }
        #expect(dashDash < dest)
    }

    @Test func interactiveAuthInvocationIncludesPortAndIdentity() {
        let host = RemoteTmuxHost(destination: "user@host", port: 2222, identityFile: "/keys/id")
        let argv = host.interactiveAuthInvocation()
        #expect(consecutive(argv, "-p", "2222"))
        #expect(consecutive(argv, "-i", "/keys/id"))
    }

    /// True when `a` is immediately followed by `b` in `args` — i.e. an ssh
    /// `-o KEY=VALUE` / `-p N` / `-i path` pair is adjacent, as ssh requires.
    private func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b {
            return true
        }
        return false
    }

    private func temporaryDirectory(prefix: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL, contents: String) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func createStaleUnixSocket(at path: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func fileIdentity(at path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private func tmuxExecutablePath(environment: [String: String]) -> String? {
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/tmux" }
        let fallbackCandidates = [
            "/opt/homebrew/bin/tmux",
            "/usr/local/bin/tmux",
            "/opt/local/bin/tmux",
            "/usr/bin/tmux",
        ]
        return (pathCandidates + fallbackCandidates).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func writeLaunchdJob(
        at url: URL,
        label: String,
        programArguments: [String],
        environment: [String: String]
    ) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "EnvironmentVariables": environment,
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": "/dev/null",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private func localTmuxLaunchdServiceLabel(socketPath: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in socketPath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "com.cmuxterm.local-tmux-server.\(String(format: "%016llx", hash))"
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }

    private func bootoutLocalTmuxLaunchdService(
        tmuxRoot: URL,
        environment: [String: String]
    ) {
        let socketPath = tmuxRoot
            .appendingPathComponent("tmux-\(getuid())", isDirectory: true)
            .appendingPathComponent("default", isDirectory: false)
            .path
        let label = localTmuxLaunchdServiceLabel(socketPath: socketPath)
        _ = try? runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())/\(label)"],
            environment: environment
        )
    }

    private func waitForLaunchdService(
        _ serviceTarget: String,
        environment: [String: String],
        containing expectedOutput: String
    ) async throws -> (status: Int32, stdout: String, stderr: String) {
        var result = try runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", serviceTarget],
            environment: environment
        )
        for _ in 0..<50 where !result.stdout.contains(expectedOutput) {
            try await Task.sleep(for: .milliseconds(20))
            result = try runProcess(
                executable: "/bin/launchctl",
                arguments: ["print", serviceTarget],
                environment: environment
            )
        }
        return result
    }

    private func runShell(
        _ command: String,
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(decoding: stdoutData, as: UTF8.self),
            String(decoding: stderrData, as: UTF8.self)
        )
    }
}

private actor NoopLocalTmuxServerBootstrapper: LocalTmuxServerBootstrapping {
    func startServer(
        environment _: [String: String],
        shellExecutablePath _: String
    ) async throws {}
}
