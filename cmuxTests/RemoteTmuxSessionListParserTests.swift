import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for parsing remote `tmux list-sessions -F` output into
/// ``RemoteTmuxSession`` values. Exercises the real parser, not source text.
@Suite struct RemoteTmuxSessionListParserTests {
    @Test func parsesColonSeparatedSessions() {
        // Format is id:windows:attached:created:name (name last).
        let output = "$0:3:1:1780000000:main\n$1:2:0:1780000001:scratch\n"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 2)
        #expect(sessions[0] == RemoteTmuxSession(
            id: "$0", name: "main", windowCount: 3, attached: true, createdUnix: 1780000000
        ))
        #expect(sessions[1] == RemoteTmuxSession(
            id: "$1", name: "scratch", windowCount: 2, attached: false, createdUnix: 1780000001
        ))
    }

    @Test func attachedReflectsNonZeroCount() {
        // tmux reports session_attached as a client count, not a 0/1 boolean.
        let output = "$5:1:2:1780000002:work"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 1)
        #expect(sessions[0].attached == true)
    }

    @Test func emptyOutputYieldsNoSessions() {
        #expect(RemoteTmuxSessionListParser.parse("").isEmpty)
        #expect(RemoteTmuxSessionListParser.parse("\n\n").isEmpty)
    }

    @Test func skipsMalformedLinesButKeepsValidOnes() {
        // A short line (too few fields) is skipped; the valid line remains.
        let output = "garbage-without-delimiters\n$2:1:0:1780000003:cmux-probe\n"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 1)
        #expect(sessions[0].id == "$2")
        #expect(sessions[0].name == "cmux-probe")
    }

    @Test func preservesNameContainingDelimiter() {
        // The name is the remainder after the 4th delimiter, so a name that
        // somehow contains the delimiter is reproduced verbatim rather than
        // truncated. (tmux itself rewrites `:` in names to `_`; this is defense
        // in depth against a name surviving with a delimiter byte.)
        let output = "$7:1:0:1780000004:a:b:c"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 1)
        #expect(sessions[0].name == "a:b:c")
    }

    @Test func preservesNameContainingSpaces() {
        let output = "$8:2:0:1780000005:my long session"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 1)
        #expect(sessions[0].name == "my long session")
    }

    @Test func preservesNameWhitespaceAndStripsLineTerminator() {
        let output = "$9:2:0:1780000006:  padded  \n$10:1:0:1780000007:crlf\r\n"
        let sessions = RemoteTmuxSessionListParser.parse(output)
        #expect(sessions.count == 2)
        #expect(sessions[0].name == "  padded  ")
        #expect(sessions[1].name == "crlf")
    }

    @Test func parsesPersistedCmuxSessionOrderWithoutCorruptingNames() {
        let output = "$0:1:0:1780000000:1:A\n$1:1:0:1780000001:0:B\n$2:1:0:1780000002:2:C\n"
        let sessions = RemoteTmuxSessionListParser.parse(output)

        #expect(sessions.map(\.name) == ["A", "B", "C"])
        #expect(sessions.map(\.cmuxOrder) == [1, 0, 2])
    }

    @Test func persistedCmuxSessionOrderSortsStablyAheadOfUnorderedSessions() {
        let sessions = [
            RemoteTmuxSession(
                id: "$0", name: "A", windowCount: 1, attached: false,
                createdUnix: 1780000000, cmuxOrder: 1
            ),
            RemoteTmuxSession(
                id: "$1", name: "B", windowCount: 1, attached: false,
                createdUnix: 1780000001, cmuxOrder: 0
            ),
            RemoteTmuxSession(
                id: "$2", name: "C", windowCount: 1, attached: false,
                createdUnix: 1780000002, cmuxOrder: 2
            ),
            RemoteTmuxSession(
                id: "$3", name: "new", windowCount: 1, attached: false,
                createdUnix: 1780000003, cmuxOrder: nil
            ),
        ]

        #expect(RemoteTmuxSession.orderedForCmux(sessions).map(\.name) == ["B", "A", "C", "new"])
    }

    @Test func persistedOrderMutationTargetsStableSessionId() {
        let update = RemoteTmuxSessionOrderUpdate(
            sessionId: "$7",
            sessionName: "mutable-name",
            order: 2
        )

        #expect(update.tmuxArguments == [
            "set-option", "-t", "$7", "@cmux_order", "2",
        ])
    }

    @Test func rejectsControlCharSubstitutedOutput() {
        // Regression: against a non-UTF-8 remote tmux client, tmux sanitizes
        // control bytes in `-F` output to `_`. The previous tab-delimited format
        // therefore arrived as a single `_`-joined field per line, which the
        // parser must NOT mistake for a session — it has no usable fields. With
        // the `:` delimiter the real format is unaffected, but a tab-era line
        // (now `_`-collapsed) is rightly skipped instead of yielding a bogus
        // session.
        let collapsed = "$0_3_1_1780000000_main\n$1_2_0_1780000001_scratch\n"
        #expect(RemoteTmuxSessionListParser.parse(collapsed).isEmpty)
    }
}
