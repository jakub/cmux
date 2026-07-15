import Foundation

/// Owns one command/control transport per tmux endpoint.
@MainActor
final class RemoteTmuxTransportRegistry {
    private let directLocalConnectionHash: String?
    private var transports: [String: any RemoteTmuxTransport] = [:]

    init(directLocalHost: RemoteTmuxHost?) {
        directLocalConnectionHash = directLocalHost?.connectionHash
    }

    func transport(for host: RemoteTmuxHost) -> any RemoteTmuxTransport {
        if let existing = transports[host.connectionHash] {
            return existing
        }
        let transport: any RemoteTmuxTransport
        if host.connectionHash == directLocalConnectionHash {
            transport = LocalTmuxTransport(host: host)
        } else {
            transport = RemoteTmuxSSHTransport(host: host)
        }
        transports[host.connectionHash] = transport
        return transport
    }

    func disconnect(host: RemoteTmuxHost) async {
        let transport = transports.removeValue(forKey: host.connectionHash)
        await transport?.shutdown()
    }

    func contains(connectionHash: String) -> Bool {
        transports[connectionHash] != nil
    }

    @discardableResult
    func remove(connectionHash: String) -> (any RemoteTmuxTransport)? {
        transports.removeValue(forKey: connectionHash)
    }

    func removeAll() -> [any RemoteTmuxTransport] {
        let removed = Array(transports.values)
        transports.removeAll()
        return removed
    }
}
