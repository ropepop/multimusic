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

        // Shared keychain group: configured name → team-prefixed name → the app's private default group.
        var probed = false
        let prefix: () -> String? = { probed = true; return "ABCDE12345" }
        let prefixed = "XYZ9876543.org.multimusic.app.playback", plain = "org.multimusic.app.playback"
        precondition(SharedAccessGroup.resolve(configured: prefixed, teamPrefix: prefix, isAccessible: { _ in true }) == .shared(prefixed) && !probed)
        precondition(SharedAccessGroup.resolve(configured: plain, teamPrefix: prefix,
                                               isAccessible: { $0 == "ABCDE12345." + plain }) == .shared("ABCDE12345." + plain))
        // A refused prefixed name is never re-prefixed; with only the default group granted, ownership goes private.
        precondition(SharedAccessGroup.resolve(configured: prefixed, teamPrefix: prefix, isAccessible: { $0 == nil }) == .privateDefault)
        precondition(SharedAccessGroup.resolve(configured: plain, teamPrefix: prefix, isAccessible: { $0 == nil }) == .privateDefault)
        precondition(SharedAccessGroup.resolve(configured: plain, teamPrefix: prefix, isAccessible: { _ in false }) == .unavailable(plain))
        for bad in [nil, "", "abc", "ABCDE1234", "ABCDE12345.x"] as [String?] {
            precondition(SharedAccessGroup.resolve(configured: plain, teamPrefix: { bad },
                                                   isAccessible: { $0 != nil && $0 != plain }) == .unavailable(plain))
        }
        precondition(SharedAccessGroup.resolve(configured: nil, teamPrefix: prefix, isAccessible: { _ in true }) == .privateDefault)
        precondition(SharedAccessGroup.teamPrefix(ofGroup: "ABCDE12345.*") == "ABCDE12345")
        precondition(SharedAccessGroup.teamPrefix(ofGroup: "org.multimusic.app") == nil)
        // Non-main bundles (checks, macOS) keep the configured group and shared mode.
        let shared = try configuration(["SharedPlaybackKeychainAccessGroup": prefixed, "MultimusicPrimaryBundleIdentifier": "org.multimusic.app"])
        precondition(!shared.sharedPlaybackPrivate && shared.sharedPlaybackAccessGroup == prefixed)
        precondition(shared.ownershipPrimaryBundleIdentifier == "org.multimusic.app")
        print("Configuration checks passed: both providers keep their identity/navigation after renaming; default diagnostics are local and private upload requires a valid explicit endpoint/database pair; an unprefixed shared group resolves under the signer's team prefix, else private mode.")
    }
}
