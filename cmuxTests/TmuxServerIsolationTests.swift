import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for keeping an XCTest instance's tmux server off the developer's.
///
/// The failure this prevents is silent: a test instance's shells publish their
/// (dead, per-run) `CMUX_SOCKET_PATH` into the shared tmux server's global
/// environment, and a local-tmux-workspaces instance then reads it back and
/// stops firing every cmux hook.
@Suite struct TmuxServerIsolationTests {
    private static let xctestEnvironment = ["XCTestSessionIdentifier": "A2E1-SESSION"]

    @Test func isolatesWhenRunningUnderXCTestWithNoAmbientTmpDir() {
        let directory = TmuxServerIsolation.isolatedTmpDirectoryToActivate(
            environment: Self.xctestEnvironment
        )
        #expect(directory?.hasPrefix("/tmp/cmux-xctest-tmux-") == true)
    }

    /// One test run must agree with itself across processes, and separate runs
    /// must not collide.
    @Test func isolatedDirectoryIsStablePerRunAndDistinctAcrossRuns() {
        let first = TmuxServerIsolation.isolatedTmpDirectoryToActivate(
            environment: Self.xctestEnvironment
        )
        let repeated = TmuxServerIsolation.isolatedTmpDirectoryToActivate(
            environment: Self.xctestEnvironment
        )
        let other = TmuxServerIsolation.isolatedTmpDirectoryToActivate(
            environment: ["XCTestSessionIdentifier": "B7F3-SESSION"]
        )

        #expect(first == repeated)
        #expect(first != other)
        #expect(other != nil)
    }

    /// A suite that built its own lab server has already chosen; redirecting it
    /// would strand that server (`RemoteTmuxSizingUITests`).
    @Test func explicitTmuxTmpDirWins() {
        let directory = TmuxServerIsolation.isolatedTmpDirectoryToActivate(
            environment: Self.xctestEnvironment.merging(
                ["TMUX_TMPDIR": "/tmp/lab-server"],
                uniquingKeysWith: { _, new in new }
            )
        )
        #expect(directory == nil)
    }

    /// A developer's own run must keep using their ambient tmux server.
    @Test func doesNotIsolateOutsideXCTest() {
        #expect(TmuxServerIsolation.isolatedTmpDirectoryToActivate(environment: [:]) == nil)
    }

    /// `DYLD_INSERT_LIBRARIES` is set by profilers and sanitizers too, so it
    /// only indicates XCTest when it actually injects XCTest.
    @Test func doesNotIsolateForUnrelatedDyldInsertions() {
        #expect(
            TmuxServerIsolation.isolatedTmpDirectoryToActivate(
                environment: ["DYLD_INSERT_LIBRARIES": "/usr/lib/libSomeProfiler.dylib"]
            ) == nil
        )
    }

    @Test func ambientTmuxTmpDirIsNotIsolation() {
        // A blank value is not a choice, so it must not suppress isolation.
        #expect(
            TmuxServerIsolation.isolatedTmpDirectoryToActivate(
                environment: Self.xctestEnvironment.merging(
                    ["TMUX_TMPDIR": "   "],
                    uniquingKeysWith: { _, new in new }
                )
            ) != nil
        )
    }
}

/// The remote command must carry `TMUX_TMPDIR` explicitly, because `ssh` does
/// not forward the environment.
@Suite struct RemoteTmuxCommandTmpDirTests {
    @Test func remoteCommandIsUnchangedWithoutIsolation() {
        let command = RemoteTmuxHost.tmuxRemoteCommand(
            arguments: ["list-sessions"],
            tmuxTmpDirectory: nil
        )
        #expect(!command.contains("TMUX_TMPDIR"))
        #expect(command.hasPrefix("'/bin/sh' '-c'"))
    }

    @Test func remoteCommandCarriesIsolatedTmpDir() {
        let command = RemoteTmuxHost.tmuxRemoteCommand(
            arguments: ["list-sessions"],
            tmuxTmpDirectory: "/tmp/cmux-xctest-tmux-abc123"
        )
        #expect(command.hasPrefix("TMUX_TMPDIR='/tmp/cmux-xctest-tmux-abc123' '/bin/sh' '-c'"))
    }

    /// The assignment is a shell word in a string the remote login shell parses,
    /// so its value has to survive quoting like every other argument does.
    @Test func remoteCommandQuotesHostileTmpDir() {
        let command = RemoteTmuxHost.tmuxRemoteCommand(
            arguments: ["list-sessions"],
            tmuxTmpDirectory: "/tmp/it's here; rm -rf /"
        )
        #expect(command.hasPrefix("TMUX_TMPDIR='/tmp/it'\\''s here; rm -rf /' '/bin/sh'"))
    }
}
