import Foundation

@MainActor
private enum TestDiagnostics {
    static var events: [[String: String]] = []
    static func record(_ event: String, fields: [String: String]) {
        assert(event == "native.command")
        events.append(fields)
    }
}

// The runner appends MusicSession's production deduplication method.
@MainActor
final class CommandDedupFixture {
    var commandTasks: [String: Task<PlaybackOutcome, Never>] = [:]
    var commandFinished: [String: Date] = [:]
    var mutations = 0
    var snapshot = PlaybackSnapshot(state: "playing")

    func outcome(_ reason: PlaybackOutcome.Reason? = nil) -> PlaybackOutcome {
        PlaybackOutcome(status: reason == nil ? .completed : .rejected, reason: reason, snapshot: snapshot)
    }

    func send(_ id: String, name: String) async -> PlaybackOutcome {
        await deduplicated(id, name: name) { [self] in
            await Task.yield()
            mutations += 1
            snapshot.state = name == "play" ? "playing" : "paused"
            return outcome()
        }
    }
}

@main
struct CommandDedupChecks {
    @MainActor
    static func main() async {
        let fixture = CommandDedupFixture()
        for index in 0..<7 {
            let id = String(format: "%032x", index)
            let name = index.isMultiple(of: 2) ? "pause" : "play"
            let result = await fixture.send(id, name: name)
            assert(result.status == .completed && result.snapshot.state == (name == "play" ? "playing" : "paused"))
            let retry = await fixture.send(id, name: name == "play" ? "pause" : "play")
            assert(retry == result, "Only the ID determines a duplicate, including after completion")
            let pair = TestDiagnostics.events.filter { $0["commandId"] == id }
            assert(pair.map { $0["phase"]! } == ["received", "completed"])
            assert(pair.allSatisfy { $0["command"] == name })
        }
        assert(fixture.mutations == 7 && TestDiagnostics.events.count == 14)

        let id = String(repeating: "f", count: 32)
        async let first = fixture.send(id, name: "play")
        async let retry = fixture.send(id, name: "play")
        let results = await [first, retry]
        assert(results[0] == results[1] && fixture.mutations == 8)
        assert(TestDiagnostics.events.filter { $0["commandId"] == id }.count == 2)
        print("Command deduplication checks passed: seven unique IDs produce seven received/completed pairs and alternating simulated states; completed and in-flight retries run once per ID.")
    }
}
