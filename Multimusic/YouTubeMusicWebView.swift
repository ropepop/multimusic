import SwiftUI
import WebKit

struct MusicWebsiteWebView: UIViewRepresentable {
    struct NavigationRequest {
        enum Action { case back, home, search }
        let id = UUID()
        let action: Action
    }

    var snapshot: PlaybackSnapshot
    var diagnosticsEnabled = false
    var navigationRequest: NavigationRequest?
    var onSelection: ([SourceTrack], SourceContext?, String) async -> PlaybackOutcome
    var onCommand: (PlaybackCommand, String) async -> PlaybackOutcome
    var onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.preferredContentMode = AppConfiguration.current.prefersDesktopWebsite ? .desktop : .mobile
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        let coordinator = context.coordinator
        let controller = configuration.userContentController
        controller.add(coordinator, contentWorld: Coordinator.world, name: "multimusic")
        guard let url = Bundle.main.url(forResource: AppConfiguration.current.adapterResource, withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8) else {
            let view = WKWebView(frame: .zero, configuration: configuration)
            DispatchQueue.main.async { onStatus("The \(AppConfiguration.current.websiteName) connection is missing from this build.") }
            return view
        }
        if let probeURL = Bundle.main.url(forResource: "QueueProbe", withExtension: "js"),
           let probe = try? String(contentsOf: probeURL, encoding: .utf8) {
            controller.addUserScript(WKUserScript(source: probe, injectionTime: .atDocumentStart,
                                                 forMainFrameOnly: true, in: Coordinator.world))
        }
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true, in: Coordinator.world))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.customUserAgent = AppConfiguration.current.customUserAgent
        coordinator.webView = view
        view.navigationDelegate = coordinator
        view.uiDelegate = coordinator
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = diagnosticsEnabled
        // Suspension is the audio boundary; page event interception is only the controls adapter.
        view.setAllMediaPlaybackSuspended(true) { [weak view] in
            view?.load(URLRequest(url: AppConfiguration.current.startURL))
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.parent = self
        uiView.isInspectable = diagnosticsEnabled
        context.coordinator.navigateIfRequested()
        context.coordinator.updateSnapshot()
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.invalidate()
        uiView.isInspectable = false
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "multimusic", contentWorld: Coordinator.world)
        uiView.navigationDelegate = nil
        uiView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let world = WKContentWorld.world(name: "Multimusic")
        var parent: MusicWebsiteWebView
        weak var webView: WKWebView?
        var active = false
        private var token = UUID().uuidString
        private var lastSequence = 0
        private var lastSnapshot: PlaybackSnapshot?
        private var lastDiagnosticsEnabled = false
        private var explicitlyLoadingMusicURL: URL?
        private var diagnosticDelivery = 0
        private var diagnosticNavigation = 0
        private var documentID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        private var diagnosticNavigationIDs: [ObjectIdentifier: (navigation: WKNavigation, id: Int, documentID: String)] = [:]
        private var currentNavigation: WKNavigation?
        private var provisionalNavigation: WKNavigation?
        private var provisionalURL: URL?
        private var policyCancellation: WebsitePolicyCancellation?
        private var blockedLinkStatus: String?
        private var lastNavigationRequestID: UUID?
        private var desiredSnapshot: PlaybackSnapshot?
        private var sendingSnapshot = false
        private var recoveryAttempted = false
        private var pendingCommands: [String: Task<PlaybackOutcome, Never>] = [:]
        private var completedCommands: [String: PlaybackOutcome] = [:]
        private var completedAt: [String: TimeInterval] = [:]
        private var sampledDeliveries = Set<Int>()
        private var lastSampledDelivery: TimeInterval = -.infinity
        private var sampleNextDelivery = true

        init(_ parent: MusicWebsiteWebView) { self.parent = parent }

        func navigateIfRequested() {
            guard AppConfiguration.current.provider == .spotify, let request = parent.navigationRequest,
                  request.id != lastNavigationRequestID, let webView else { return }
            lastNavigationRequestID = request.id
            if request.action == .back {
                if webView.canGoBack { webView.goBack() }
                return
            }
            let url = request.action == .home ? AppConfiguration.current.startURL : URL(string: "https://open.spotify.com/search")!
            explicitlyLoadingMusicURL = url
            webView.load(URLRequest(url: url))
        }

        func invalidate() {
            active = false
            token = UUID().uuidString
            sendingSnapshot = false
            currentNavigation = nil
            provisionalNavigation = nil
            policyCancellation = nil
            blockedLinkStatus = nil
        }

        private func snapshotObject(_ snapshot: PlaybackSnapshot, delivery: Int? = nil) -> [String: Any] {
            guard let data = try? JSONEncoder().encode(snapshot),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            object["diagnosticsEnabled"] = parent.diagnosticsEnabled
            object["sourceProvider"] = AppConfiguration.current.provider.rawValue
            object["playbackEnabled"] = AppConfiguration.current.playbackEnabled
            if let sourceID = snapshot.sourceID, !AppConfiguration.current.provider.acceptsTrackID(sourceID) {
                object.removeValue(forKey: "sourceID")
                object["title"] = ""
                object["artist"] = ""
                object["synchronized"] = false
            }
            if let delivery { object["deliveryId"] = delivery }
            return object
        }

        private func record(_ event: String, _ fields: [String: String] = [:]) {
            if parent.diagnosticsEnabled {
                var fields = fields
                if fields["documentId"] == nil { fields["documentId"] = documentID }
                TestDiagnostics.record(event, fields: fields)
            }
        }

        private func navigationID(_ navigation: WKNavigation?) -> Int {
            guard let navigation else { return 0 }
            let key = ObjectIdentifier(navigation)
            if let entry = diagnosticNavigationIDs[key] { return entry.id }
            diagnosticNavigation += 1
            if diagnosticNavigationIDs.count >= 64 { diagnosticNavigationIDs.removeAll(keepingCapacity: true) }
            diagnosticNavigationIDs[key] = (navigation, diagnosticNavigation, documentID)
            return diagnosticNavigation
        }

        private func navigationFields(_ navigation: WKNavigation?) -> [String: String] {
            let id = navigationID(navigation)
            let document = navigation.flatMap { diagnosticNavigationIDs[ObjectIdentifier($0)]?.documentID } ?? documentID
            return ["navigation": String(id), "documentId": document]
        }

        func updateSnapshot() {
            offer(parent.snapshot)
            sendLatestSnapshot()
        }

        private func offer(_ snapshot: PlaybackSnapshot) {
            if desiredSnapshot == nil || snapshot.revision >= desiredSnapshot!.revision { desiredSnapshot = snapshot }
        }

        private func sendLatestSnapshot(attempt: Int = 0) {
            guard active, !sendingSnapshot, let webView, let snapshot = desiredSnapshot,
                  snapshot != lastSnapshot || parent.diagnosticsEnabled != lastDiagnosticsEnabled else { return }
            sendingSnapshot = true
            diagnosticDelivery += 1
            let delivery = diagnosticDelivery
            let documentToken = token
            let logging = parent.diagnosticsEnabled
            let started = ProcessInfo.processInfo.systemUptime
            let sampled = sampleNextDelivery || logging != lastDiagnosticsEnabled || started - lastSampledDelivery >= 5
            if sampled {
                sampleNextDelivery = false
                lastSampledDelivery = started
                if sampledDeliveries.count >= 64 { sampledDeliveries.removeAll(keepingCapacity: true) }
                sampledDeliveries.insert(delivery)
                record("web.snapshot.queue", ["delivery": String(delivery), "pending": "1"])
            }
            webView.callAsyncJavaScript("return window.Multimusic?.applySnapshot(snapshot)",
                                        arguments: ["snapshot": snapshotObject(snapshot, delivery: delivery)], in: nil, in: Self.world) { [weak self] result in
                guard let self, self.token == documentToken, self.active else { return }
                self.sendingSnapshot = false
                var fields = ["delivery": String(delivery), "pending": "0",
                              "elapsedMs": String(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))]
                if case .success(let response as [String: Any]) = result, response["accepted"] as? Bool == true {
                    self.lastSnapshot = snapshot
                    self.lastDiagnosticsEnabled = logging
                    self.recoveryAttempted = false
                    if sampled || ProcessInfo.processInfo.systemUptime - started > 0.1 {
                        self.record("web.snapshot.completed", fields)
                    }
                    self.sendLatestSnapshot()
                } else {
                    if case .failure(let error) = result {
                        let error = error as NSError
                        fields["domain"] = [WKError.errorDomain, NSURLErrorDomain].contains(error.domain) ? error.domain : "other"
                        fields["code"] = String(error.code)
                    } else { fields["domain"] = "other"; fields["code"] = "0" }
                    self.record("web.snapshot.failed", fields)
                    if attempt < 2 {
                        self.sendingSnapshot = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.2 : 0.6)) { [weak self] in
                            guard let self, self.token == documentToken, self.active else { return }
                            self.sendingSnapshot = false
                            self.sendLatestSnapshot(attempt: attempt + 1)
                        }
                    } else if !self.recoveryAttempted {
                        self.recoveryAttempted = true
                        self.activateDocument()
                    } else {
                        self.active = false
                        self.parent.onStatus("The website controls lost their connection. Reload \(AppConfiguration.current.websiteName) to reconnect; Music keeps playing.")
                    }
                }
            }
        }

        private func activateDocument() {
            guard let webView, webView.url?.host == AppConfiguration.current.musicHost else { return }
            token = UUID().uuidString
            lastSequence = 0
            lastSnapshot = nil
            sendingSnapshot = false
            active = true
            offer(parent.snapshot)
            let snapshot = desiredSnapshot ?? parent.snapshot
            let documentToken = token
            let logging = parent.diagnosticsEnabled
            webView.callAsyncJavaScript("return window.Multimusic?.activate(token, snapshot) === true",
                                        arguments: ["token": documentToken, "snapshot": snapshotObject(snapshot)], in: nil, in: Self.world) { [weak self] result in
                guard let self, self.token == documentToken else { return }
                let ready: Bool
                if case .success(let value as Bool) = result { ready = value } else { ready = false }
                self.record("web.bridge.activation", ["ready": ready ? "1" : "0"])
                guard ready else {
                    self.active = false
                    self.parent.onStatus("The website controls did not connect. Reload \(AppConfiguration.current.websiteName) to try again.")
                    return
                }
                self.lastSnapshot = snapshot
                self.lastDiagnosticsEnabled = logging
                self.sendLatestSnapshot()
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            currentNavigation = navigation
            provisionalNavigation = navigation
            provisionalURL = webView.url
            policyCancellation = nil
            blockedLinkStatus = nil
            documentID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            record("web.navigation.start", navigationFields(navigation))
            active = false
            token = UUID().uuidString
            lastSequence = 0
            lastSnapshot = nil
            sendingSnapshot = false
            recoveryAttempted = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            record("web.navigation.finish", navigationFields(navigation).merging(["musicOrigin": webView.url?.host == AppConfiguration.current.musicHost ? "1" : "0"]) { _, new in new })
            guard navigation === currentNavigation else { return }
            provisionalNavigation = nil
            policyCancellation = nil
            if webView.url?.host == AppConfiguration.current.musicHost { activateDocument() }
            else if AppConfiguration.current.provider == .youtubeMusic, webView.url?.host == "accounts.google.com" {
                parent.onStatus("Sign in inside this window. Google may refuse sign-in in an embedded browser.")
                let documentToken = token
                webView.callAsyncJavaScript("return /disallowed_useragent|This browser or app may not be secure|Couldn't sign you in/.test(document.body?.innerText || '')",
                                            arguments: [:], in: nil, in: Self.world) { [weak self] result in
                    guard let self, self.token == documentToken else { return }
                    if case .success(let blocked as Bool) = result, blocked {
                        self.parent.onStatus("Google blocked sign-in in this embedded browser. Your Brave sign-in cannot be transferred to the app.")
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard navigation === currentNavigation else { return }
            provisionalNavigation = nil
            policyCancellation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let deliberatelyCancelled = navigation.flatMap { navigation in
                policyCancellation.flatMap { $0.matches(navigation, error: error as NSError) ? $0 : nil }
            }
            record(deliberatelyCancelled != nil || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled) ? "web.navigation.cancel" : "web.navigation.fail",
                   navigationFields(navigation).merging(["code": String((error as NSError).code)]) { _, new in new })
            guard navigation === currentNavigation else { return }
            provisionalNavigation = nil
            policyCancellation = nil
            if let deliberatelyCancelled {
                restoreUnchangedDocument(after: deliberatelyCancelled)
            } else if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
                if !webView.isLoading { activateDocument() }
            } else {
                active = false
                parent.onStatus("\(AppConfiguration.current.websiteName) could not load. Check the connection, then reopen the app.")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            record("web.navigation.fail", navigationFields(navigation).merging(["code": String((error as NSError).code)]) { _, new in new })
            guard navigation === currentNavigation else { return }
            provisionalNavigation = nil
            policyCancellation = nil
            active = false
            parent.onStatus("The \(AppConfiguration.current.websiteName) page stopped loading. Reopen the app to reconnect.")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            record("web.navigation.terminated")
            active = false
            token = UUID().uuidString
            sendingSnapshot = false
            provisionalNavigation = nil
            policyCancellation = nil
            blockedLinkStatus = nil
            parent.onStatus("The \(AppConfiguration.current.websiteName) page closed. Apple Music keeps its prepared queue; reopen the app to reconnect.")
        }

        private func restoreUnchangedDocument(after cancellation: WebsitePolicyCancellation) {
            blockedLinkStatus = cancellation.message
            parent.onStatus(cancellation.message)
            guard let webView, let sourceURL = cancellation.sourceURL,
                  sourceURL.host == AppConfiguration.current.musicHost,
                  Self.allowsNavigation(sourceURL) else { return }
            let documentToken = token
            webView.callAsyncJavaScript("return location.href === sourceURL && !!window.Multimusic",
                                        arguments: ["sourceURL": sourceURL.absoluteString], in: nil, in: Self.world) { [weak self] result in
                guard let self, self.token == documentToken,
                      self.currentNavigation === cancellation.navigation, !webView.isLoading else { return }
                if case .success(let unchanged as Bool) = result, unchanged { self.activateDocument() }
            }
        }

        private func acknowledge(_ commandID: String, status: String, outcome: PlaybackOutcome? = nil, documentToken: String) {
            guard active, token == documentToken, let webView else { return }
            var object: [String: Any] = ["token": token, "commandId": commandID, "status": status]
            if let outcome {
                offer(outcome.snapshot)
                object["snapshot"] = snapshotObject(outcome.snapshot)
                object["reason"] = outcome.reason?.rawValue
            }
            webView.callAsyncJavaScript("return window.Multimusic?.receiveAck(ack) === true", arguments: ["ack": object], in: nil, in: Self.world)
        }

        private func perform(_ commandID: String, operation: @escaping @MainActor () async -> PlaybackOutcome) {
            let documentToken = token
            let now = ProcessInfo.processInfo.systemUptime
            for (id, time) in completedAt where now - time > 60 {
                completedAt[id] = nil
                completedCommands[id] = nil
            }
            if let outcome = completedCommands[commandID] {
                acknowledge(commandID, status: outcome.status.rawValue, outcome: outcome, documentToken: documentToken)
                return
            }
            guard (completedCommands.count + pendingCommands.count < 128 && pendingCommands.count < 64) || pendingCommands[commandID] != nil else {
                acknowledge(commandID, status: "rejected",
                            outcome: PlaybackOutcome(status: .rejected, reason: .nativeFailure, snapshot: desiredSnapshot ?? parent.snapshot),
                            documentToken: documentToken)
                return
            }
            sampleNextDelivery = true
            acknowledge(commandID, status: pendingCommands[commandID] == nil ? "accepted" : "pending", documentToken: documentToken)
            guard pendingCommands[commandID] == nil, pendingCommands.count < 64 else { return }
            let task = Task { @MainActor in
                self.acknowledge(commandID, status: "pending", documentToken: documentToken)
                return await operation()
            }
            pendingCommands[commandID] = task
            Task { @MainActor in
                let outcome = await task.value
                self.pendingCommands[commandID] = nil
                self.completedCommands[commandID] = outcome
                self.completedAt[commandID] = ProcessInfo.processInfo.systemUptime
                self.acknowledge(commandID, status: outcome.status.rawValue, outcome: outcome, documentToken: documentToken)
                self.sendLatestSnapshot()
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            record("web.navigation.policy", ["type": String(navigationAction.navigationType.rawValue),
                                               "mainFrame": navigationAction.targetFrame?.isMainFrame == false ? "0" : "1",
                                               "musicOrigin": url.host == AppConfiguration.current.musicHost ? "1" : "0"])
            // Subframes never receive the native bridge, and cannot replace the signed-in main page.
            if navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
            guard Self.allowsNavigation(url) else {
                let message: String
                if url.scheme == "spotify" {
                    message = "Spotify tried to open the Spotify app. That link was blocked; continue browsing here."
                } else if !["http", "https"].contains(url.scheme ?? "") {
                    message = "This link opens another app and was blocked. Continue browsing \(AppConfiguration.current.websiteName) here."
                } else {
                    message = "This link leaves \(AppConfiguration.current.websiteName) and was blocked."
                }
                blockedLinkStatus = message
                if let navigation = provisionalNavigation, navigation === currentNavigation {
                    policyCancellation = WebsitePolicyCancellation(navigation: navigation, blockedURL: url,
                        sourceURL: navigationAction.sourceFrame.request.url, provisionalURL: provisionalURL, message: message)
                }
                parent.onStatus(message)
                decisionHandler(.cancel)
                return
            }
            webView.customUserAgent = url.host == AppConfiguration.current.musicHost ? AppConfiguration.current.customUserAgent : nil
            let request = navigationAction.request
            if url.host == AppConfiguration.current.musicHost,
               (request.httpMethod ?? "GET").uppercased() == "GET",
               request.httpBody == nil, request.httpBodyStream == nil,
               [.linkActivated, .formSubmitted, .other].contains(navigationAction.navigationType) {
                if explicitlyLoadingMusicURL == url, navigationAction.navigationType == .other {
                    explicitlyLoadingMusicURL = nil
                    decisionHandler(.allow)
                } else {
                    // An explicit load keeps this GET in WebKit instead of opening the YouTube Music app.
                    explicitlyLoadingMusicURL = url
                    decisionHandler(.cancel)
                    webView.load(request)
                }
                return
            }
            explicitlyLoadingMusicURL = nil
            decisionHandler(.allow)
        }

        private static func allowsNavigation(_ url: URL) -> Bool {
            AppConfiguration.current.allowsNavigation(url)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil,
               let url = navigationAction.request.url, Self.allowsNavigation(url) {
                webView.customUserAgent = url.host == AppConfiguration.current.musicHost ? AppConfiguration.current.customUserAgent : nil
                webView.load(navigationAction.request)
            }
            return nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard active, message.webView === webView, message.frameInfo.isMainFrame,
                  origin.protocol == "https", origin.host == AppConfiguration.current.musicHost, origin.port == 0 || origin.port == 443,
                  webView?.url?.host == AppConfiguration.current.musicHost,
                  let body = message.body as? [String: Any], body["token"] as? String == token,
                  body["provider"] as? String == AppConfiguration.current.provider.rawValue,
                  let sequence = body["sequence"] as? Int, sequence > lastSequence,
                  let type = body["type"] as? String else { return }
            lastSequence = sequence
            if type == "status" {
                record("web.bridge.receive", ["sequence": String(sequence), "type": type])
            }
            if !AppConfiguration.current.playbackEnabled, ["selection", "command"].contains(type) {
                if let commandID = body["commandId"] as? String,
                   commandID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil {
                    acknowledge(commandID, status: "rejected",
                                outcome: PlaybackOutcome(status: .rejected, reason: .inactive, snapshot: parent.snapshot),
                                documentToken: token)
                }
                parent.onStatus("Playback is unavailable in this build. You can continue browsing \(AppConfiguration.current.websiteName).")
                return
            }
            switch type {
            case "resync":
                lastSnapshot = nil
                updateSnapshot()
            case "snapshotAck":
                if let delivery = body["deliveryId"] as? Int, sampledDeliveries.contains(delivery) {
                    record("web.snapshot.painted", ["delivery": String(delivery)])
                }
            case "diagnostic":
                guard parent.diagnosticsEnabled, let event = body["event"] as? String,
                      let fields = body["fields"] as? [String: String],
                      (event == "web.aggregate" && WebsiteDiagnosticFields.acceptsAggregate(fields)) ||
                        (event == "web.queueProbe" && WebsiteDiagnosticFields.acceptsQueueProbe(fields)) else { return }
                record(event, fields)
            case "selection":
                blockedLinkStatus = nil
                guard let commandID = body["commandId"] as? String,
                      commandID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
                      let rows = body["tracks"] as? [[String: Any]], !rows.isEmpty, rows.count <= 50,
                      let omitted = body["omitted"] as? Int, (0...50).contains(omitted),
                      let data = try? JSONSerialization.data(withJSONObject: rows),
                      let tracks = try? JSONDecoder().decode([SourceTrack].self, from: data),
                      tracks.allSatisfy({ track in
                          AppConfiguration.current.provider.acceptsTrackID(track.id) &&
                          !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && track.title.count <= 500 &&
                          !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && track.artist.count <= 500 &&
                          (track.duration == nil || (track.duration!.isFinite && track.duration! > 0 && track.duration! <= 86_400))
                      }) else { return }
                let declaredCount = body["declaredCount"] as? Int
                guard body["declaredCount"] == nil || declaredCount.map({ (tracks.count...1_000_000).contains($0) }) == true,
                      body["capped"] == nil || body["capped"] is Bool else { return }
                let capped = body["capped"] as? Bool ?? false
                var context: SourceContext?
                if let object = body["context"] {
                    guard let data = try? JSONSerialization.data(withJSONObject: object),
                          let decoded = try? JSONDecoder().decode(SourceContext.self, from: data),
                          decoded.provider == AppConfiguration.current.provider,
                          decoded.selectedSourceID == tracks.first?.id else { return }
                    context = decoded
                }
                record("web.bridge.receive", ["sequence": String(sequence), "type": type, "commandId": commandID])
                var limits: [String] = []
                if capped { limits.append("50-row limit") }
                if omitted > 0 { limits.append("\(omitted) unreadable") }
                let total = declaredCount.map { " of \($0)" } ?? " rendered songs"
                let details = limits.isEmpty ? "" : " (" + limits.joined(separator: "; ") + ")"
                parent.onStatus("Captured \(tracks.count)\(total)\(details)")
                let handler = parent.onSelection
                perform(commandID) { await handler(tracks, context, commandID) }
            case "command":
                blockedLinkStatus = nil
                guard let commandID = body["commandId"] as? String,
                      commandID.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil,
                      let command = body["command"] as? String else { return }
                let action: PlaybackCommand
                switch command {
                case "play": action = .play
                case "pause": action = .pause
                case "next": action = .next
                case "previous": action = .previous
                case "seek":
                    guard let position = body["position"] as? Double, position.isFinite,
                          position >= 0, position <= 86_400 else { return }
                    action = .seek(position)
                default: return
                }
                record("web.bridge.receive", ["sequence": String(sequence), "type": type, "commandId": commandID])
                let handler = parent.onCommand
                perform(commandID) { await handler(action, commandID) }
            case "status":
                guard let status = body["status"] as? String else { return }
                if status == "ready", let blockedLinkStatus { parent.onStatus(blockedLinkStatus); return }
                blockedLinkStatus = nil
                let statuses = [
                    "ready": AppConfiguration.current.playbackEnabled ? "\(AppConfiguration.current.websiteName) is connected. Choose a song; playback comes from Apple Music." : "\(AppConfiguration.current.websiteName) is connected for browsing.",
                    "choose": "Choose a song again to connect the website controls to Apple Music.",
                    "noMatch": "No reliable match was found. Your previous music is still available.",
                    "unreadable": "This song could not be identified from the page. Open its song page or choose another recording.",
                    "unsupported": "This website control is unavailable with Apple Music playback.",
                    "empty": "No readable songs are rendered here yet. Open the album or playlist, then try Play.",
                    "openCollection": "Press the original Play button inside this collection to prepare its rendered songs.",
                    "controlTimedOut": "Music has not confirmed that action. Its current state is being checked; try again if needed.",
                    "mixOpened": "Mix opened—tap a song in Up next.",
                    "inactive": "Playback is inactive. Return to the app and try again.",
                    "unauthorized": "Connect Apple Music before playing.",
                    "invalidSelection": "The song selection could not be used. Choose a song again.",
                    "unmappedQueue": "Music’s current song is outside the saved queue. Select a song or use Restore.",
                    "awaitingNext": "The next song is not ready yet. Wait for matching, then press Play.",
                    "cancelled": "That request was cancelled by a newer action.",
                    "nativeFailure": "Music could not complete that request.",
                    "nativeNoChange": "Music did not change songs.",
                    "timedOut": "Music’s request is unconfirmed. Check its current state before trying again.",
                    "foreignPlayback": "Music is controlled elsewhere. Select a song or use Restore to take over.",
                    "cleared": "The saved queue is cleared. Choose a song to start again.",
                    "adapterChanged": "\(AppConfiguration.current.websiteName)’s player controls were not found. This page may need an adapter update."
                ]
                if let text = statuses[status] { parent.onStatus(text) }
            default: break
            }
        }
    }
}
