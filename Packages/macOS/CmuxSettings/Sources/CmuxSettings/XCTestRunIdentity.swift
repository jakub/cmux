public import Foundation

/// Identifies the current XCTest run so a test-only instance can isolate the
/// resources it shares with a developer's live instance.
///
/// Two such resources exist, and both are process-external: the control socket
/// (``SocketControlSettings/defaultSocketPath(bundleIdentifier:environment:isDebugBuild:currentUserID:probeStableDefaultPathEntry:)``)
/// and the tmux server (`TmuxServerIsolation`). Both derive their isolation from
/// ``discriminator(environment:)`` so "am I an isolated instance?" has a single
/// answer per process.
public enum XCTestRunIdentity {
    /// Environment keys XCTest sets in a host application it launches. The first
    /// non-empty one seeds the discriminator, so every process in one test run
    /// agrees while separate runs diverge.
    private static let indicators = [
        "XCTestSessionIdentifier",
        "XCTestConfigurationFilePath",
        "XCTestBundlePath",
        "XCInjectBundle",
        "XCInjectBundleInto",
        "DYLD_INSERT_LIBRARIES",
    ]

    /// A stable per-test-run discriminator, or `nil` when not under XCTest.
    ///
    /// `DYLD_INSERT_LIBRARIES` is set outside XCTest too (profilers, sanitizers),
    /// so it only counts when it actually injects XCTest.
    public static func discriminator(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let source = indicators.compactMap({ key -> String? in
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return nil
            }
            if key == "DYLD_INSERT_LIBRARIES",
               !value.contains("libXCTest") {
                return nil
            }
            return value
        }).first else {
            return nil
        }

        let hash = source.utf8.reduce(UInt64(0xcbf29ce484222325)) { partial, byte in
            (partial ^ UInt64(byte)) &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
