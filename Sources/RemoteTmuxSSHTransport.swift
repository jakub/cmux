import Foundation

/// Runs commands against a remote host's tmux server over a shared SSH
/// ControlMaster connection.
///
/// This is the non-interactive half of the remote-tmux feature: session
/// discovery (`tmux list-sessions`) and one-shot mutations (`new-session`,
/// `new-window`, `split-window`, `kill-*`, `send-keys`). The latency-sensitive
/// `tmux -CC` control stream is NOT run here — it runs in a ghostty surface so
/// it gets a PTY. Both share the same ControlMaster socket
/// (``RemoteTmuxHost/controlSocketPath``), so the first to connect authenticates
/// and the rest are subsecond.
///
/// Modeled as an `actor` because it owns the per-host connection lifecycle and
/// serializes process launches; reads/writes are `async`.
actor RemoteTmuxSSHTransport: RemoteTmuxTransport {
    nonisolated let kind = RemoteTmuxTransportKind.ssh

    /// The host this transport talks to.
    ///
    /// `nonisolated` so the controller can read it synchronously (it's an immutable
    /// `Sendable` value) when tearing down masters on quit/window-close.
    nonisolated let host: RemoteTmuxHost

    nonisolated private let sshExecutablePath: String
    nonisolated private let controlPersistSeconds: Int
    private let processExecutor: RemoteTmuxProcessExecutor

    /// In-flight shared-master warmup, if any. ``ensureMasterReady()`` funnels every
    /// concurrent caller through this single task so the master is opened at most
    /// once even though the actor is reentrant across awaits (see that method).
    private var readinessTask: Task<Bool, Error>?

    /// - Parameters:
    ///   - host: the remote destination.
    ///   - sshExecutablePath: the local `ssh` binary (overridable for tests).
    ///   - controlPersistSeconds: idle lifetime of the shared master.
    init(
        host: RemoteTmuxHost,
        sshExecutablePath: String = RemoteTmuxHost.defaultSSHExecutablePath(),
        controlPersistSeconds: Int = 180,
        processExecutor: RemoteTmuxProcessExecutor = RemoteTmuxProcessExecutor()
    ) {
        self.host = host
        self.sshExecutablePath = sshExecutablePath
        self.controlPersistSeconds = controlPersistSeconds
        self.processExecutor = processExecutor
    }

    /// Runs an arbitrary remote command over the shared SSH master.
    ///
    /// `ssh` concatenates the post-destination argv with spaces and the remote
    /// login shell re-splits the result, so each remote token is single-quoted
    /// here; otherwise whitespace inside an argument (e.g. the tabs in a
    /// `list-sessions -F` format string) would be word-split on the remote.
    /// A leading literal `tmux` is the `runTmux(_:)` contract and selects the
    /// remote tmux resolver; other commands are treated as explicit remote argv.
    @discardableResult
    func run(_ remoteArgs: [String]) async throws -> RemoteTmuxCommandResult {
        try host.ensureControlSocketDirectory()
        let remoteCommand: String
        if remoteArgs.first == "tmux" {
            remoteCommand = RemoteTmuxHost.tmuxRemoteCommand(arguments: Array(remoteArgs.dropFirst()))
        } else {
            remoteCommand = remoteArgs
                .map { RemoteTmuxHost.shellSingleQuoted($0) }
                .joined(separator: " ")
        }
        // `--` ends ssh option parsing so a destination beginning with `-`
        // (e.g. `-oProxyCommand=…`) can never be consumed as an ssh option.
        let sshArgs =
            host.sshControlArguments(controlPersistSeconds: controlPersistSeconds, batchMode: true)
            + ["--", host.destination, remoteCommand]
        return try await processExecutor.run(executable: sshExecutablePath, arguments: sshArgs)
    }

    /// Opens the shared SSH ControlMaster (if it isn't already up) and confirms it
    /// accepts multiplexed sessions, so the burst of `tmux -CC attach` connections
    /// the controller fires next — each `ControlMaster=auto`
    /// (``RemoteTmuxHost/controlModeArguments``) — rides a *ready* master instead of
    /// all racing to create one at the same `ControlPath`.
    ///
    /// On a cold first attach with many sessions, that creation race makes
    /// all-but-one connection fail with "ControlSocket … already exists, disabling
    /// multiplexing", so only one or two sessions mirror (#6732). Even discovery
    /// (which opens the master implicitly) leaves a brief background hand-off window
    /// where the socket exists but isn't yet accepting sessions; `ssh -O check` is
    /// the authoritative "ready now" signal that closes it.
    ///
    /// Idempotent: returns `true` at once when a master is already live (warm path);
    /// otherwise opens it exactly once with `run(["true"])` — a single connection
    /// can't lose the creation race — and then confirms with one authoritative
    /// `ssh -O check` (a non-multiplexed fallback can make `run` succeed without a
    /// live master, so the open's exit code is not trusted). A single mux-socket
    /// query, never a timer or poll. Returns `false` only when readiness can't be
    /// confirmed; the controller fails closed on `false` (aborts the burst rather
    /// than racing the cold master).
    ///
    /// Single-flight: the actor is reentrant across `await`, so two concurrent
    /// bulk-mirror callers for the same host (e.g. a dedicated-window attach and a
    /// `remote.tmux.mirror` socket call) could otherwise both observe no master and
    /// both open it, recreating the race. Every caller shares one in-flight
    /// ``readinessTask``; the check-create-store below is a single synchronous actor
    /// step (no `await` between them), so only one caller becomes the creator.
    ///
    /// Not cancellation-aware by itself: the shared warmup is unstructured and
    /// bounded by `ConnectTimeout`, so a cancelled caller awaits its completion
    /// rather than tearing it down for the others. Callers that must bail re-check
    /// `Task.checkCancellation()` after this — as the controller does before
    /// creating the dedicated window.
    @discardableResult
    func ensureMasterReady() async throws -> Bool {
        if let existing = readinessTask {
            return try await existing.value
        }
        let task = Task { try await self.performMasterReady() }
        readinessTask = task
        defer { readinessTask = nil }
        return try await task.value
    }

    /// The actual warmup, run exactly once per ``readinessTask`` (see
    /// ``ensureMasterReady()`` for the single-flight + readiness rationale).
    private func performMasterReady() async throws -> Bool {
        try? host.ensureControlSocketDirectory()
        if try await masterIsRunning() { return true }
        // Warm the shared master once, then confirm. The open's exit code is not
        // trusted (a non-multiplexed fallback can make `run` exit 0 with no live
        // master — see the doc comment); the post-open `ssh -O check` is authoritative.
        _ = try? await run(["true"])
        return try await masterIsRunning()
    }

    /// Whether the shared ControlMaster is live and accepting sessions, via the
    /// local `ssh -O check` control command. `-O check` hits the LOCAL control
    /// socket only (identified by `ControlPath`), so it never opens a network
    /// connection and returns in milliseconds.
    ///
    /// Propagates `CancellationError` (so a cancelled ``ensureMasterReady()`` aborts
    /// rather than mis-reading the cancellation as "no master"); collapses only
    /// ordinary launch/socket failures to `false`.
    private func masterIsRunning() async throws -> Bool {
        do {
            let result = try await processExecutor.run(
                executable: sshExecutablePath,
                arguments: ["-O", "check", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
            )
            return result.succeeded
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
    }

    /// Tears down the shared SSH master (e.g. when the user removes a host).
    func shutdownMaster() async {
        _ = try? await processExecutor.run(
            executable: sshExecutablePath,
            arguments: ["-O", "exit", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
        )
    }

    func prepareForControlBurst() async throws -> Bool {
        try await ensureMasterReady()
    }

    func shutdown() async {
        await shutdownMaster()
    }

    nonisolated func spawnShutdown() {
        Self.spawnControlMasterExit(host: host, sshExecutablePath: sshExecutablePath)
    }

    nonisolated func controlProcessInvocation(
        sessionName: String,
        createIfMissing: Bool
    ) -> RemoteTmuxProcessInvocation {
        RemoteTmuxProcessInvocation(
            executablePath: sshExecutablePath,
            arguments: host.controlModeArguments(
                sessionName: sessionName,
                createIfMissing: createIfMissing,
                controlPersistSeconds: controlPersistSeconds
            ),
            environment: nil
        )
    }

    /// Fire-and-forget `ssh -O exit` to close the host's shared SSH ControlMaster.
    ///
    /// `nonisolated` and non-`async` so it can run from the synchronous app-quit /
    /// window-close paths where awaiting an actor isn't possible. `-O exit` hits the
    /// LOCAL control socket (fast, no network round-trip) and the spawned process
    /// runs independently of cmux, so the master is torn down even as the app exits
    /// — instead of lingering for `ControlPersist` after the user closes the app or
    /// the mirror window. Best-effort: a missing/dead socket just fails fast.
    nonisolated static func spawnControlMasterExit(
        host: RemoteTmuxHost,
        sshExecutablePath: String = RemoteTmuxHost.defaultSSHExecutablePath()
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshExecutablePath)
        process.arguments = ["-O", "exit", "-o", "ControlPath=\(host.controlSocketPath)", "--", host.destination]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()  // fire-and-forget — do not wait
    }

}
