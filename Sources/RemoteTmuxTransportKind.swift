/// Selects how cmux reaches the tmux server behind a mirrored endpoint.
enum RemoteTmuxTransportKind: Sendable {
    case local
    case ssh
}
