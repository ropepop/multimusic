import Foundation

@main
@MainActor
struct LocalDiagnosticsChecks {
    static func main() async throws {
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]!
        precondition(NSHomeDirectory() == home && URL.documentsDirectory.path.hasPrefix(home + "/"))
        let preferences = Bundle.main.bundleIdentifier!
        precondition(preferences.hasPrefix("org.multimusic.app.checks."))
        defer { UserDefaults.standard.removePersistentDomain(forName: preferences) }
        precondition(AppConfiguration.current.diagnosticsUpload == nil)
        let diagnostics = TestDiagnostics.shared
        precondition(!diagnostics.isEnabled)
        diagnostics.isEnabled = true
        try await waitFor { diagnostics.status == "Diagnostics stored on this phone" }
        let fields = ["phase": "resume", "active": "true", "preparing": "false", "queueCount": "0"]
        TestDiagnostics.record("native.lifecycle", fields: fields)
        let directory = URL.documentsDirectory.appendingPathComponent("Diagnostics")
        let events = directory.appendingPathComponent("events.jsonl")
        try await waitFor { (try? Data(contentsOf: events).isEmpty) == false }
        try await Task.sleep(for: .milliseconds(2200))
        precondition(diagnostics.status == "Diagnostics stored on this phone" && diagnostics.publicIdentity.isEmpty)
        let before = try Data(contentsOf: events)
        precondition(before.split(separator: 10).count == 1)
        diagnostics.isEnabled = false
        try await waitFor { diagnostics.status == "Diagnostics off" }
        TestDiagnostics.record("native.lifecycle", fields: fields)
        try await Task.sleep(for: .milliseconds(100))
        let after = try Data(contentsOf: events)
        precondition(after == before)
        print("Local diagnostics checks passed: public configuration has no upload destination, explicit opt-in keeps an event locally, and disabling preserves a quiet log.")
    }

    private static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        preconditionFailure("Diagnostics did not reach the expected state")
    }
}
