import Foundation

// Compile beside the production outcome factory to prove a no-match carries
// its checkpoint skip reasons into the reported PlaybackOutcome.
@MainActor
final class SkipReasonsFixture {
    var active = true, authorized = true, nativeBusy = false
    var problem: String?
    var status = ""
    var snapshot = PlaybackSnapshot()
    var synchronized = false
    func currentIndex() -> Int? { 0 }
    func publishSnapshot(synchronized: Bool) { self.synchronized = synchronized }
}

@main
struct SkipReasonsChecks {
    @MainActor
    static func main() throws {
        let fixture = SkipReasonsFixture()
        let reasons = ["thirdPartyEdit", "noResults", "ambiguousRecording"]
        let rejected = fixture.outcome(.noMatch, skipReasons: reasons)
        assert(rejected.status == .rejected && rejected.reason == .noMatch)
        assert(rejected.skipReasons == reasons, "no-match outcome must carry the checkpoint skip reasons")

        let completed = fixture.outcome()
        assert(completed.status == .completed && completed.skipReasons.isEmpty)

        let encoded = try JSONEncoder().encode(rejected)
        let decoded = try JSONDecoder().decode(PlaybackOutcome.self, from: encoded)
        assert(decoded == rejected)
        assert(decoded.skipReasons.filter { $0 == MatchSkipReason.thirdPartyEdit.rawValue }.count == 1)

        let old = try JSONDecoder().decode(PlaybackOutcome.self, from: Data(
            #"{"status":"completed","snapshot":{"title":"","artist":"","duration":0,"position":0,"state":"stopped","synchronized":false,"revision":0}}"#.utf8))
        assert(old.skipReasons.isEmpty)
        print("Skip-reason propagation checks passed: no-match outcomes retain ordered reasons and round-trip through Codable.")
    }
}
