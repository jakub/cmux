import Foundation

/// Parses the delimited output of `tmux list-sessions -F` into sessions.
///
/// The expected per-line format (set by ``RemoteTmuxTransport``) is:
/// `#{session_id}:#{session_windows}:#{session_attached}:#{session_created}:#{@cmux_order}:#{session_name}`
///
/// `session_name` is placed **last** because it is the only free-text field;
/// the leading fields are a `$N` id, integer counts, a unix timestamp, and an
/// optional cmux order, none of which contain the `:` delimiter. The name is
/// therefore parsed as the whole remainder after the fifth delimiter, so it is
/// reproduced verbatim even
/// if it somehow contained a `:` (tmux already rewrites `:` in session names to
/// `_`, so this is defense in depth).
///
/// The delimiter is the printable `:` rather than a control character such as
/// tab: when the remote tmux client is not flagged UTF-8, tmux runs `-F` output
/// through `utf8_sanitize()`, which rewrites every non-printable-ASCII byte —
/// including tab — to `_`. The client is non-UTF-8 whenever the remote
/// `LC_ALL`/`LC_CTYPE`/`LANG` lacks "UTF-8" (and `$TMUX` is unset and `-u` is not
/// passed), which is the default on a non-interactive SSH command to a host with
/// no UTF-8 locale (e.g. Amazon Linux 2023). That collapsed the old tab-delimited
/// line into a single field and made every session unparseable. A printable
/// delimiter is preserved under any locale.
///
/// Parsing is deliberately lenient: malformed or short lines are skipped rather
/// than failing the whole listing, so a single odd session never hides the rest
/// of the sidebar.
enum RemoteTmuxSessionListParser {
    /// The field delimiter. A printable byte tmux preserves in `-F` output (it
    /// rewrites control bytes like tab to `_`), and one tmux forbids inside a
    /// session name (it rewrites `:` in names to `_`), so it cannot collide with
    /// any leading field value.
    static let fieldDelimiter = ":"

    /// The `-F` format string this parser expects, ordered to match ``parse(_:)``
    /// with the free-text `session_name` last.
    static let formatString =
        "#{session_id}:#{session_windows}:#{session_attached}:#{session_created}:#{@cmux_order}:#{session_name}"

    /// Parses raw `list-sessions` stdout into structured sessions.
    ///
    /// - Parameter output: the raw stdout from the remote `tmux list-sessions`.
    /// - Returns: one ``RemoteTmuxSession`` per well-formed line, in input order.
    static func parse(_ output: String) -> [RemoteTmuxSession] {
        var sessions: [RemoteTmuxSession] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            // Unbounded split: the leading fields are id/windows/attached/
            // created/order, and the name (which may itself contain `:`) is
            // reassembled from the remainder below.
            let fields = line.components(separatedBy: fieldDelimiter)
            // Accept the old five-field format so cached fixtures and older
            // cooperating clients remain readable during rolling upgrades.
            guard fields.count >= 5 else { continue }
            let id = fields[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty else { continue }
            let windowCount = Int(fields[1].trimmingCharacters(in: .whitespaces)) ?? 0
            let attached = (Int(fields[2].trimmingCharacters(in: .whitespaces)) ?? 0) > 0
            let createdUnix = Int(fields[3].trimmingCharacters(in: .whitespaces))
            let hasOrderField = fields.count >= 6
                && (fields[4].trimmingCharacters(in: .whitespaces).isEmpty
                    || Int(fields[4].trimmingCharacters(in: .whitespaces)) != nil)
            let cmuxOrder = hasOrderField
                ? Int(fields[4].trimmingCharacters(in: .whitespaces))
                : nil
            let nameStartIndex = hasOrderField ? 5 : 4
            // The name is the remainder, rejoined so an embedded delimiter
            // (should one ever survive) is preserved rather than truncated.
            let name = fields[nameStartIndex...].joined(separator: fieldDelimiter)
            sessions.append(
                RemoteTmuxSession(
                    id: id,
                    name: name,
                    windowCount: windowCount,
                    attached: attached,
                    createdUnix: createdUnix,
                    cmuxOrder: cmuxOrder
                )
            )
        }
        return sessions
    }
}
