import Foundation

@main
struct AppConfigurationChecks {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        func configuration(_ values: [String: Any]) throws -> AppConfiguration {
            let directory = root.appendingPathComponent(UUID().uuidString + ".bundle")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
                .write(to: directory.appendingPathComponent("Info.plist"))
            return AppConfiguration(bundle: Bundle(path: directory.path)!)
        }

        for base in ["org.multimusic.app", "com.example.listener"] {
            for provider in [SourceProvider.youtubeMusic, .spotify] {
                let bundleID = provider == .spotify ? base + ".Spotify" : base
                let sharedGroup = "TESTPREFIX." + base + ".playback"
                let config = try configuration(["CFBundleIdentifier": bundleID,
                    "MultimusicSourceProvider": provider.rawValue,
                    "SharedPlaybackKeychainAccessGroup": sharedGroup,
                    "MultimusicPrimaryBundleIdentifier": base, "MultimusicPlaybackEnabled": true])
                precondition(config.provider == provider && config.bundleIdentifier == bundleID)
                precondition(config.primaryBundleIdentifier == base && config.playbackEnabled)
                precondition(config.sharedPlaybackAccessGroup == sharedGroup)
                precondition(config.diagnosticsUpload == nil)
                precondition(config.diagnosticsKeychainService == bundleID + ".testDiagnostics")
                precondition(config.prefersDesktopWebsite == (provider == .youtubeMusic))
                precondition(config.allowsNavigation(config.startURL))
                for url in ["http://\(config.musicHost)/", "https://\(config.musicHost).example.com/",
                            "https://\(config.musicHost):444/", "https://example.com/"] {
                    precondition(!config.allowsNavigation(URL(string: url)!))
                }
                let foreignOrigin = provider == .spotify ? "https://music.youtube.com/" : "https://open.spotify.com/"
                precondition(!config.allowsNavigation(URL(string: foreignOrigin)!))
            }
        }
        let fallback = try configuration(["MultimusicSourceProvider": SourceProvider.spotify.rawValue])
        precondition(fallback.primaryBundleIdentifier == "org.multimusic.app"
                     && fallback.bundleIdentifier == "org.multimusic.app.Spotify")
        let valid = ["MultimusicDiagnosticsOrigin": "https://diagnostics.example.invalid",
                     "MultimusicDiagnosticsDatabase": "private-test"]
        let upload = try configuration(valid).diagnosticsUpload
        precondition(upload?.origin.host == "diagnostics.example.invalid" && upload?.database == "private-test")
        for (key, value) in [("MultimusicDiagnosticsOrigin", ""),
                             ("MultimusicDiagnosticsOrigin", "http://diagnostics.example.invalid"),
                             ("MultimusicDiagnosticsOrigin", "https://user:secret@diagnostics.example.invalid"),
                             ("MultimusicDiagnosticsOrigin", "https://diagnostics.example.invalid/path"),
                             ("MultimusicDiagnosticsOrigin", "https://diagnostics.example.invalid/?query=yes"),
                             ("MultimusicDiagnosticsDatabase", ""), ("MultimusicDiagnosticsDatabase", "../private")] {
            let config = try configuration(valid.merging([key: value]) { _, new in new })
            precondition(config.diagnosticsUpload == nil)
        }
        let incomplete = try configuration(["MultimusicDiagnosticsOrigin": valid["MultimusicDiagnosticsOrigin"]!])
        precondition(incomplete.diagnosticsUpload == nil)
        print("Configuration checks passed: both providers keep their identity/navigation after renaming; default diagnostics are local and private upload requires a valid explicit endpoint/database pair.")
    }
}
