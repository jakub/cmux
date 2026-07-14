import CmuxSettings
import Foundation

/// Keeps an XCTest instance's tmux server separate from the developer's.
///
/// The shell integration publishes cmux identity (`CMUX_SOCKET_PATH`,
/// `CMUX_TAB_ID`, `CMUX_BUNDLED_CLI_PATH`, …) into a tmux server's *global*
/// environment whenever a shell starts outside tmux
/// (`_cmux_tmux_publish_cmux_environment`). It does so with a bare
/// `tmux set-environment -g`, and "bare" means the default server: any instance's
/// native surface writes whatever tmux server the developer happens to be
/// running, last writer wins.
///
/// That asymmetry is what makes it damaging. An instance running local-tmux
/// workspaces never publishes — every one of its surfaces is *inside* tmux, so
/// the publish path never runs — while a test instance spawning ordinary
/// surfaces publishes freely. The test instance therefore always wins, and the
/// tmux-primary instance's panes read back a foreign, already-dead socket path,
/// at which point every cmux hook silently stops firing. A test instance that
/// enables local-tmux workspaces is worse still: it discovers and adopts the
/// developer's live sessions as its own workspaces.
///
/// Isolation is by `TMUX_TMPDIR` rather than `tmux -L`, because tmux honors
/// `TMUX_TMPDIR` natively *and* child processes inherit it — so the publishing
/// shells follow this process onto the isolated server without the shell
/// integration needing to know the mechanism exists.
///
/// Scope: this addresses the test vector only. A second non-test instance (a
/// release build spawning native surfaces beside a dev build) still shares — and
/// can still clobber — the default server's global environment.
enum TmuxServerIsolation {
    /// The directory an isolated tmux server should keep its socket in, or `nil`
    /// when this process should use the ambient server.
    ///
    /// An explicit `TMUX_TMPDIR` always wins: a test that already points itself
    /// at a purpose-built server (`RemoteTmuxSizingUITests`) has chosen, and
    /// redirecting it would strand the server it built.
    static func isolatedTmpDirectoryToActivate(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard normalized(environment["TMUX_TMPDIR"]) == nil else { return nil }
        guard let discriminator = XCTestRunIdentity.discriminator(environment: environment) else {
            return nil
        }
        return "/tmp/cmux-xctest-tmux-\(discriminator)"
    }

    /// The directory ``activateIfNeeded()`` redirected this process to, or `nil`
    /// if it did not.
    ///
    /// Written once from the composition root before any concurrency exists, and
    /// read-only thereafter.
    nonisolated(unsafe) private static var activatedTmpDirectory: String?

    /// Points this process — and every shell and tmux command it spawns — at an
    /// isolated tmux server when it is an XCTest instance.
    ///
    /// Call from the composition root, before any surface spawns or any tmux
    /// command runs: `setenv` only reaches children created afterwards, and a
    /// mirror that discovers sessions before this runs would adopt the
    /// developer's live ones.
    static func activateIfNeeded(fileManager: FileManager = .default) {
        guard let directory = isolatedTmpDirectoryToActivate() else { return }
        // tmux creates `<TMUX_TMPDIR>/tmux-<uid>/` but not TMUX_TMPDIR itself,
        // and refuses to start if it is missing.
        try? fileManager.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        setenv("TMUX_TMPDIR", directory, 1)
        activatedTmpDirectory = directory
    }

    /// The `TMUX_TMPDIR` a *remote* tmux command must carry, or `nil` to leave the
    /// remote's own default alone. `ssh` does not forward the environment, so an
    /// isolated server is only reachable if the command states it.
    ///
    /// This is deliberately the directory *this type chose*, not the ambient
    /// `TMUX_TMPDIR`. Someone who exports `TMUX_TMPDIR` in their own shell means
    /// it for their local tmux; projecting it onto a genuinely remote host would
    /// point that host's tmux at an unrelated path and fragment it from the
    /// sessions already running there.
    static func tmuxTmpDirectoryForCommands() -> String? {
        activatedTmpDirectory
    }

    private static func normalized(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
