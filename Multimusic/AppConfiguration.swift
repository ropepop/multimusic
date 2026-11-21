import Foundation
import Security

/// Xcode and `sign.sh` write the team-prefixed shared group into Info.plist. On-device signers such as
/// Feather keep the unsigned, unprefixed name and embed the provisioning profile's keychain groups as-is,
/// so the configured group may be refused with errSecMissingEntitlement. Resolution order:
/// configured group → configured group under the app's team prefix → the app's own default (private) group.
/// Private mode keeps each app's queue protection working but cannot coordinate between the two apps.
enum SharedAccessGroup {
    enum Resolution: Equatable, Sendable {
        case shared(String)
        case privateDefault
        case unavailable(String?)
    }

    static func teamPrefix(ofGroup group: String) -> String? {
        guard let dot = group.firstIndex(of: ".") else { return nil }
        let prefix = String(group[..<dot])
        return prefix.range(of: "^[A-Z0-9]{10}\\z", options: .regularExpression) != nil ? prefix : nil
    }

    /// `isAccessible(nil)` tests the app's default keychain group.
    static func resolve(configured: String?, teamPrefix: () -> String?, isAccessible: (String?) -> Bool) -> Resolution {
        if let configured, !configured.isEmpty {
            if isAccessible(configured) { return .shared(configured) }
            if Self.teamPrefix(ofGroup: configured) == nil, let prefix = teamPrefix(),
               Self.teamPrefix(ofGroup: prefix + ".x") == prefix {
                let candidate = prefix + "." + configured
                if isAccessible(candidate) { return .shared(candidate) }
            }
        }
        return isAccessible(nil) ? .privateDefault : .unavailable(configured)
    }

    #if os(iOS)
    private static func probeItem(service: String, group: String?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: "probe", kSecAttrSynchronizable as String: false]
        if let group { query[kSecAttrAccessGroup as String] = group }
        return query
    }

    /// Adding (not reading) is what reliably reports errSecMissingEntitlement for a group outside the signature.
    static func keychainAllows(_ group: String?) -> Bool {
        let query = probeItem(service: "org.multimusic.accessGroupProbe", group: group)
        var item = query
        item[kSecValueData as String] = Data()
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return false }
        SecItemDelete(query as CFDictionary)
        return true
    }

    /// An item added without an access group lands in the app's default group, which carries its team prefix.
    static func keychainTeamPrefix() -> String? {
        let query = probeItem(service: "org.multimusic.teamPrefixProbe", group: nil)
        defer { SecItemDelete(query as CFDictionary) }
        var item = query
        item[kSecValueData as String] = Data()
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        var status = SecItemAdd(item as CFDictionary, &result)
        if status == errSecDuplicateItem {
            var lookup = query
            lookup[kSecReturnAttributes as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            status = SecItemCopyMatching(lookup as CFDictionary, &result)
        }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let group = attributes[kSecAttrAccessGroup as String] as? String else { return nil }
        return teamPrefix(ofGroup: group)
    }
    #endif
}

struct AppConfiguration: Sendable {
    static let current = AppConfiguration()
    private static let defaultBundleBase = "org.multimusic.app"

    let provider: SourceProvider
    let bundleIdentifier: String
    let primaryBundleIdentifier: String
    let sharedPlaybackAccessGroup: String?
    /// True when no shared group is granted and ownership uses this app's own keychain group.
    let sharedPlaybackPrivate: Bool
    let playbackEnabled: Bool
    let diagnosticsUpload: DiagnosticsUpload?

    struct DiagnosticsUpload: Sendable {
        let origin: URL
        let database: String
    }

    init(bundle: Bundle = .main) {
        provider = SourceProvider(rawValue: bundle.object(forInfoDictionaryKey: "MultimusicSourceProvider") as? String ?? "") ?? .youtubeMusic
        let base = bundle.object(forInfoDictionaryKey: "MultimusicPrimaryBundleIdentifier") as? String ?? Self.defaultBundleBase
        primaryBundleIdentifier = base
        bundleIdentifier = bundle.bundleIdentifier ?? (provider == .spotify ? base + ".Spotify" : base)
        let configuredGroup = bundle.object(forInfoDictionaryKey: "SharedPlaybackKeychainAccessGroup") as? String
        var resolution = SharedAccessGroup.Resolution.unavailable(configuredGroup)
        if let configuredGroup, !configuredGroup.isEmpty { resolution = .shared(configuredGroup) }
        #if os(iOS)
        if bundle == .main {
            resolution = SharedAccessGroup.resolve(configured: configuredGroup,
                teamPrefix: SharedAccessGroup.keychainTeamPrefix, isAccessible: SharedAccessGroup.keychainAllows)
        }
        #endif
        switch resolution {
        case .shared(let group): sharedPlaybackAccessGroup = group; sharedPlaybackPrivate = false
        case .privateDefault: sharedPlaybackAccessGroup = nil; sharedPlaybackPrivate = true
        case .unavailable(let group): sharedPlaybackAccessGroup = group; sharedPlaybackPrivate = false
        }
        playbackEnabled = bundle.object(forInfoDictionaryKey: "MultimusicPlaybackEnabled") as? Bool ?? (provider == .youtubeMusic)
        if let value = bundle.object(forInfoDictionaryKey: "MultimusicDiagnosticsOrigin") as? String,
           let origin = URL(string: value), origin.scheme == "https", origin.host != nil,
           origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
           origin.path.isEmpty || origin.path == "/",
           let database = bundle.object(forInfoDictionaryKey: "MultimusicDiagnosticsDatabase") as? String,
           database.range(of: "^[A-Za-z0-9_-]{1,128}\\z", options: .regularExpression) != nil {
            diagnosticsUpload = DiagnosticsUpload(origin: origin, database: database)
        } else {
            diagnosticsUpload = nil
        }
    }

    var displayName: String { provider == .spotify ? "Multimusic Spotify" : "Multimusic" }
    var websiteName: String { provider == .spotify ? "Spotify" : "YouTube Music" }
    var musicHost: String { provider == .spotify ? "open.spotify.com" : "music.youtube.com" }
    var startURL: URL { URL(string: "https://\(musicHost)/")! }
    var adapterResource: String { provider == .spotify ? "Spotify" : "YouTubeMusic" }
    var prefersDesktopWebsite: Bool { provider == .youtubeMusic }
    var customUserAgent: String? {
        // YouTube rejects WebKit's unbranded desktop agent; Spotify uses its native mobile site.
        provider == .youtubeMusic ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15" : nil
    }
    /// In private mode nothing is shared, so this app adopts its own journal even if a signer renamed it.
    var ownershipPrimaryBundleIdentifier: String { sharedPlaybackPrivate ? bundleIdentifier : primaryBundleIdentifier }
    var sharedPlaybackDescription: String {
        sharedPlaybackPrivate ? "private keychain (no shared group in this signature)" : "shared group \(sharedPlaybackAccessGroup ?? "none")"
    }
    var diagnosticsKeychainService: String { bundleIdentifier + ".testDiagnostics" }
    var diagnosticsBuildPrefix: String { provider == .spotify ? "ios-spotify" : "ios" }

    func allowsNavigation(_ url: URL) -> Bool {
        guard url.scheme == "https", url.port == nil || url.port == 443, let host = url.host else { return false }
        switch provider {
        case .youtubeMusic:
            return [musicHost, "accounts.google.com", "accounts.youtube.com", "consent.google.com", "consent.youtube.com"].contains(host)
                || (host == "www.youtube.com" && url.path == "/signin")
        case .spotify:
            return [musicHost, "accounts.spotify.com", "www.spotify.com"].contains(host)
        }
    }
}

struct WebsitePolicyCancellation {
    let navigation: AnyObject
    let blockedURL: URL
    let sourceURL: URL?
    let provisionalURL: URL?
    let message: String

    func matches(_ navigation: AnyObject, error: NSError) -> Bool {
        guard navigation === self.navigation,
              (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
                || (error.domain == "WebKitErrorDomain" && error.code == 102) else { return false }
        let failedURL = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        return failedURL.map { [blockedURL, sourceURL, provisionalURL].compactMap { $0 }.contains($0) } ?? true
    }
}

enum WebsiteDiagnosticFields {
    static func acceptsQueueProbe(_ fields: [String: String]) -> Bool {
        guard fields.count <= 16, fields["qpKind"] != nil, fields["qpCapture"] != nil else { return false }
        return fields.allSatisfy { key, value in
            if key == "qpKind" { return ["poll", "enabled", "capture", "plus1", "plus10", "row", "readError", "headerPlay", "headerShuffle", "queueTap"].contains(value) }
            if key == "qpPaused" { return ["true", "false", "none"].contains(value) }
            if ["qpHash", "qpSelectedID", "qpV", "qpList", "qpRowID"].contains(key) {
                return value.range(of: "^(?:none|[a-f0-9]{8})$", options: .regularExpression) != nil
            }
            return ["qpCapture", "qpRows", "qpSelected", "qpTime", "qpRendered", "qpRow"].contains(key) &&
                (Int64(value).map { (-1...1_000_000_000_000).contains($0) && String($0) == value } ?? false)
        }
    }

    static func acceptsAggregate(_ fields: [String: String]) -> Bool {
        guard fields.count <= 47, fields["documentId"] == nil else { return false }
        let timingKeys: Set<String> = ["commandStartedMs", "feedbackFrameMs", "completedFrameMs", "commandFrameOutcome"]
        if !timingKeys.isDisjoint(with: fields.keys), fields["commandId"] == nil { return false }
        return fields.allSatisfy { key, value in
            guard key.range(of: "^[A-Za-z][A-Za-z0-9]{0,63}\\z", options: .regularExpression) != nil else { return false }
            if key == "commandId" {
                return value.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil
            }
            if ["hitStack0", "hitStack1", "hitStack2", "hitStack3", "hitStack4"].contains(key) {
                return value.utf8.count <= 64 && value.range(of: "^(?:none|[a-z][a-z0-9-]*(?:#[A-Za-z0-9_-]+)?(?:\\.[A-Za-z0-9_-]+)*(?:\\[[A-Za-z0-9_-]+\\])?@-?[0-9]+,-?[0-9]+,[0-9]+,[0-9]+\\^[a-z][a-z0-9-]*)\\z", options: .regularExpression) != nil
            }
            if key == "aggregateRoot" { return ["ytmusic-player-bar", "ytmusic-player-page", "ytmusic-player", "ytmusic-miniplayer", "none"].contains(value) }
            if key == "seekMissReason" { return ["row", "volume", "transportOther", "notVisible", "noRoot", "narrow", "outside", "navigation", "none"].contains(value) }
            if key == "seekResolved" || key == "sliderVis" { return value == "true" || value == "false" }
            if key == "composedPathTags" {
                return value.utf8.count <= 64 && value.range(of: "^[a-z][a-z0-9-]*(,[a-z][a-z0-9-]*){0,7}\\z", options: .regularExpression) != nil
            }
            if key == "collapsePath" { return value == "arrow" }
            if key == "expandPath" { return ["title", "cover", "keyboard"].contains(value) }
            return value.count <= 32 && Double(value).map { $0.isFinite && abs($0) < 1e12 } == true
        }
    }
}
