public import Darwin
public import Foundation

extension SocketControlSettings {
    /// The default socket path for the current build variant (before override handling).
    public static func defaultSocketPath(
        bundleIdentifier: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isDebugBuild: Bool,
        currentUserID: uid_t = getuid(),
        probeStableDefaultPathEntry: (String) -> StableDefaultSocketPathEntry = inspectStableDefaultSocketPathEntry
    ) -> String {
        if isDebugBuild,
           isBareDebugBundleIdentifier(
               bundleIdentifier,
               baseDebugBundleIdentifier: baseDebugBundleIdentifier
           ),
           launchTag(environment: environment) == nil,
           environment["CMUX_SOCKET_PATH"]?.isEmpty != false,
           let xctestPath = xctestDebugSocketPath(environment: environment) {
            return xctestPath
        }

        return SocketPathMarkerFiles.defaultSocketPath(
            bundleIdentifier: bundleIdentifier,
            environment: environment,
            isDebugBuild: isDebugBuild,
            stableSocketPath: resolvedStableDefaultSocketPath(
                currentUserID: currentUserID,
                probeStableDefaultPathEntry: probeStableDefaultPathEntry
            ),
            baseDebugBundleIdentifier: baseDebugBundleIdentifier
        )
    }
}

private func isBareDebugBundleIdentifier(
    _ bundleIdentifier: String?,
    baseDebugBundleIdentifier: String
) -> Bool {
    bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) == baseDebugBundleIdentifier
}

private func xctestDebugSocketPath(environment: [String: String]) -> String? {
    guard let discriminator = XCTestRunIdentity.discriminator(environment: environment) else {
        return nil
    }
    return "/tmp/cmux-xctest-\(discriminator).sock"
}
