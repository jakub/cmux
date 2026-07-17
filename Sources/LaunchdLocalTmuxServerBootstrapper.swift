import Darwin
import Foundation

/// Starts the first local tmux server as an on-demand launchd job.
///
/// The job is registered only when cmux needs to create a session and no server
/// already exists. It is not installed as a login item and has no keepalive
/// policy. launchd owns tmux's foreground server process, keeping it outside the
/// cmux application coalition that macOS terminates from the Dock background UI.
actor LaunchdLocalTmuxServerBootstrapper: LocalTmuxServerBootstrapping {
    private let processExecutor: RemoteTmuxProcessExecutor
    private let fileManager: FileManager
    private let userID: uid_t
    private let readinessTimeout: TimeInterval

    init(
        processExecutor: RemoteTmuxProcessExecutor = RemoteTmuxProcessExecutor(),
        fileManager: FileManager = .default,
        userID: uid_t = getuid(),
        readinessTimeout: TimeInterval = 5
    ) {
        self.processExecutor = processExecutor
        self.fileManager = fileManager
        self.userID = userID
        self.readinessTimeout = readinessTimeout
    }

    func startServer(
        environment: [String: String],
        shellExecutablePath: String
    ) async throws {
        let identity = LocalTmuxLaunchdIdentity(environment: environment, userID: userID)
        try prepareSocketDirectory(identity.socketDirectory)
        let serviceTarget = "gui/\(userID)/\(identity.serviceLabel)"
        let launchEnvironment = Self.launchEnvironment(from: environment)
        let existing = try await runLaunchctl(
            ["print", serviceTarget],
            environment: launchEnvironment
        )

        if existing.succeeded, !Self.isStoppedService(existing.stdout) {
            try await waitForSocket(identity)
            return
        }
        if existing.succeeded {
            _ = try await runLaunchctl(
                ["bootout", serviceTarget],
                environment: launchEnvironment
            )
        }

        let plistURL = fileManager.temporaryDirectory.appendingPathComponent(
            "\(identity.serviceLabel).\(UUID().uuidString).plist",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: plistURL) }
        try writeJobPlist(
            to: plistURL,
            identity: identity,
            environment: launchEnvironment,
            shellExecutablePath: shellExecutablePath
        )

        let bootstrap = try await runLaunchctl(
            ["bootstrap", "gui/\(userID)", plistURL.path],
            environment: launchEnvironment
        )
        if !bootstrap.succeeded {
            // A second tagged cmux may have won the same first-server race.
            // Adopt its stable-label job instead of starting another server.
            let winner = try await runLaunchctl(
                ["print", serviceTarget],
                environment: launchEnvironment
            )
            guard winner.succeeded, !Self.isStoppedService(winner.stdout) else {
                let detail = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw RemoteTmuxError.localServerBootstrapFailed(
                    detail.isEmpty ? "launchctl bootstrap exited \(bootstrap.exitCode)" : detail
                )
            }
        }

        try await waitForSocket(identity)
    }

    nonisolated static func serviceLabel(socketPath: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in socketPath.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return "com.cmuxterm.local-tmux-server.\(String(format: "%016llx", hash))"
    }

    private func prepareSocketDirectory(_ url: URL) throws {
        var isDirectory = ObjCBool(false)
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw RemoteTmuxError.localServerBootstrapFailed(
                    "tmux socket directory is not a directory: \(url.path)"
                )
            }
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == userID else {
            throw RemoteTmuxError.localServerBootstrapFailed(
                "tmux socket directory is not owned by the current user: \(url.path)"
            )
        }
        if (info.st_mode & 0o777) != 0o700, chmod(url.path, 0o700) != 0 {
            throw RemoteTmuxError.localServerBootstrapFailed(
                "could not secure tmux socket directory: \(url.path)"
            )
        }
    }

    private func writeJobPlist(
        to url: URL,
        identity: LocalTmuxLaunchdIdentity,
        environment: [String: String],
        shellExecutablePath: String
    ) throws {
        let resolver = RemoteTmuxHost.tmuxResolverInvocation(
            arguments: ["-D"],
            commandName: "cmux-local-tmux-server"
        )
        let plist: [String: Any] = [
            "Label": identity.serviceLabel,
            "ProgramArguments": [shellExecutablePath] + resolver.arguments,
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
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func waitForSocket(_ identity: LocalTmuxLaunchdIdentity) async throws {
        let waiter = LocalTmuxSocketReadinessWaiter(
            socketPath: identity.socketPath,
            socketDirectoryPath: identity.socketDirectory.path,
            timeout: readinessTimeout,
            fileManager: fileManager
        )
        try await waiter.wait()
    }

    private func runLaunchctl(
        _ arguments: [String],
        environment: [String: String]
    ) async throws -> RemoteTmuxCommandResult {
        try await processExecutor.run(
            executable: "/bin/launchctl",
            arguments: arguments,
            environment: environment
        )
    }

    private nonisolated static func isStoppedService(_ output: String) -> Bool {
        output.contains("state = not running")
    }

    private nonisolated static func launchEnvironment(
        from environment: [String: String]
    ) -> [String: String] {
        let exactKeys = [
            "HOME", "USER", "LOGNAME", "SHELL", "PATH", "LANG", "LC_ALL",
            "LC_CTYPE", "TMPDIR", "TMUX_TMPDIR",
        ]
        var result: [String: String] = [:]
        for key in exactKeys {
            if let value = environment[key], !value.isEmpty {
                result[key] = value
            }
        }
        for (key, value) in environment where key.hasPrefix("LC_") && !value.isEmpty {
            result[key] = value
        }
        if result["PATH"] == nil {
            result["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        return result
    }
}

private struct LocalTmuxLaunchdIdentity {
    let socketDirectory: URL
    let socketPath: String
    let serviceLabel: String

    init(environment: [String: String], userID: uid_t) {
        let root = environment["TMUX_TMPDIR"].flatMap { value in
            value.isEmpty ? nil : value
        } ?? "/tmp"
        socketDirectory = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("tmux-\(userID)", isDirectory: true)
        socketPath = socketDirectory
            .appendingPathComponent("default", isDirectory: false)
            .path
        serviceLabel = LaunchdLocalTmuxServerBootstrapper.serviceLabel(socketPath: socketPath)
    }
}

private final class LocalTmuxSocketReadinessWaiter: @unchecked Sendable {
    private let socketPath: String
    private let socketDirectoryPath: String
    private let timeout: TimeInterval
    private let fileManager: FileManager
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var source: DispatchSourceFileSystemObject?
    private var completedResult: Result<Void, Error>?

    init(
        socketPath: String,
        socketDirectoryPath: String,
        timeout: TimeInterval,
        fileManager: FileManager
    ) {
        self.socketPath = socketPath
        self.socketDirectoryPath = socketDirectoryPath
        self.timeout = timeout
        self.fileManager = fileManager
    }

    func wait() async throws {
        if fileManager.fileExists(atPath: socketPath) { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    private func install(_ continuation: CheckedContinuation<Void, Error>) {
        let descriptor = open(socketDirectoryPath, O_EVTONLY)
        guard descriptor >= 0 else {
            continuation.resume(throwing: RemoteTmuxError.localServerBootstrapFailed(
                "could not watch tmux socket directory: \(socketDirectoryPath)"
            ))
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self, self.fileManager.fileExists(atPath: self.socketPath) else { return }
            self.finish(.success(()))
        }
        source.setCancelHandler { close(descriptor) }

        lock.lock()
        if let completedResult {
            lock.unlock()
            source.cancel()
            continuation.resume(with: completedResult)
            return
        }
        self.continuation = continuation
        self.source = source
        lock.unlock()

        source.resume()
        if fileManager.fileExists(atPath: socketPath) {
            finish(.success(()))
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            if self.fileManager.fileExists(atPath: self.socketPath) {
                self.finish(.success(()))
            } else {
                self.finish(.failure(RemoteTmuxError.localServerBootstrapFailed(
                    "timed out waiting for tmux socket: \(self.socketPath)"
                )))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        let source = source
        self.continuation = nil
        self.source = nil
        lock.unlock()

        source?.cancel()
        continuation?.resume(with: result)
    }
}
