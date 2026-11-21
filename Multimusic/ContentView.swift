import SwiftUI

struct ContentView: View {
    @ObservedObject var music: MusicSession
    @ObservedObject private var diagnostics = TestDiagnostics.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSetup = false
    @State private var webStatus = "Opening \(AppConfiguration.current.websiteName)…"
    @State private var webRevision = UUID()
    @State private var webNavigation: MusicWebsiteWebView.NavigationRequest?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform")
                    .foregroundStyle(.pink)
                Text(AppConfiguration.current.displayName).font(.headline)
                Spacer()
                if music.preparing { ProgressView().controlSize(.small) }
                Button("Reload \(AppConfiguration.current.websiteName)", systemImage: "arrow.clockwise") {
                    webStatus = "Reopening \(AppConfiguration.current.websiteName)…"
                    webNavigation = nil
                    webRevision = UUID()
                }
                .labelStyle(.iconOnly)
                Button("Setup", systemImage: "gearshape") { showingSetup = true }
                    .labelStyle(.iconOnly)
            }
            .padding(.horizontal).padding(.vertical, 10)
            Divider()
            MusicWebsiteWebView(
                snapshot: music.snapshot,
                diagnosticsEnabled: diagnostics.isEnabled,
                navigationRequest: webNavigation,
                onSelection: { tracks, context, commandID in
                    await music.select(tracks, context: context, commandID: commandID)
                },
                onCommand: { command, commandID in
                    await music.command(command, commandID: commandID)
                },
                onStatus: { webStatus = $0 }
            )
            .id(webRevision)
            if AppConfiguration.current.provider == .spotify {
                NativePlaybackControls(music: music, diagnosticsEnabled: diagnostics.isEnabled,
                    visible: scenePhase == .active && !showingSetup)
                Divider()
                HStack(spacing: 24) {
                    Button("Back", systemImage: "chevron.left") { webNavigation = .init(action: .back) }
                    Button("Home", systemImage: "house") { webNavigation = .init(action: .home) }
                    Button("Search", systemImage: "magnifyingglass") { webNavigation = .init(action: .search) }
                }
                .font(.subheadline)
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                SessionStrip(music: music, showSetup: { showingSetup = true })
                Text(webStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.vertical, 7)
            .accessibilityElement(children: .contain)
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(isPresented: $showingSetup) { setup }
        .onAppear {
            guard !SharedPlaybackOwnership.runLaunchProbeIfRequested() else { return }
            if AppConfiguration.current.playbackEnabled { music.resume() }
        }
        .onChange(of: scenePhase) { _, phase in
            if AppConfiguration.current.playbackEnabled {
                if phase == .active { music.resume() } else { music.suspend() }
            }
        }
    }

    private var setup: some View {
        NavigationStack {
            List {
                Section {
                    Label("\(AppConfiguration.current.websiteName) chooses. Apple Music plays.", systemImage: "music.note")
                    Text(AppConfiguration.current.provider == .spotify
                         ? "Browse Spotify and choose a song. Use the controls below the browser for Apple Music playback. Songs without a confident match are skipped."
                         : "Browse and use YouTube Music’s own controls. The website’s audio stays blocked. Songs without a confident Apple Music match are skipped.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if AppConfiguration.current.playbackEnabled {
                    Section("Queue & recovery") {
                        Text(music.queueStatus).font(.subheadline).textSelection(.enabled)
                        Button("Restore saved queue") { Task { _ = await music.restoreSavedQueue() } }
                            .disabled(!music.canRestore)
                        Button("Clear queue", role: .destructive) { Task { _ = await music.clearQueue() } }
                        Text("Your prepared queue is saved automatically. Restore resumes its remaining songs. Choosing a new song or album replaces Music’s queue.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !music.skipped.isEmpty {
                    Section("Skipped songs") {
                        ForEach(Array(music.skipped.enumerated()), id: \.offset) { _, item in
                            Text(item).font(.subheadline)
                        }
                    }
                }
                Section("Diagnostics") {
                    Toggle("Diagnostic logging", isOn: $diagnostics.isEnabled)
                    Text(diagnostics.status).font(.caption).foregroundStyle(.secondary)
                    Text(AppConfiguration.current.diagnosticsUpload == nil
                         ? "Optional logs stay on this phone. Logging is off by default; stored logs are limited to 2 MB, 5,000 events and five days."
                         : "This private build uploads optional logs to its configured diagnostic service. Logging is off by default.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Logs contain playback states and timings. Turning this off stops new recording and any uploads.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if AppConfiguration.current.playbackEnabled {
                    Section("Apple Music") {
                        Text(music.status).font(.subheadline).textSelection(.enabled)
                        Button("Allow Apple Music Access") { Task { await music.authorize() } }
                        Button("Play three reference songs") { Task { await music.playReferenceQueue() } }
                            .disabled(music.preparing)
                        Text("The reference test replaces Music’s current queue. Turn off Autoplay (∞) and Repeat in Music so a prepared queue can finish.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(AppConfiguration.current.sharedPlaybackPrivate
                             ? "Queue protection: this app only. Its signature has no keychain group shared with the other Multimusic app, so they cannot see each other’s queue ownership."
                             : "Queue protection: \(AppConfiguration.current.sharedPlaybackDescription).")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                Section(AppConfiguration.current.websiteName) {
                    Text(webStatus).font(.subheadline).textSelection(.enabled)
                    Text("Sign in on the website. The app preserves that session. A captured batch contains only the upcoming songs the page has actually made available.")
                        .font(.caption).foregroundStyle(.secondary)
                }

            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(8)
                    .background(.bar)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingSetup = false } } }
        }
    }
}

private struct SessionStrip: View {
    @ObservedObject var music: MusicSession
    var showSetup: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingSkipped = false
    @State private var confirmingClear = false
    @State private var confirmingReset = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                HStack(spacing: 8) { message; Spacer(minLength: 0); controls }
                    .frame(minHeight: 44)
            }
            stacked
        }
        .font(.caption)
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showingSkipped) { SkippedSheet(music: music) }
        .confirmationDialog("Clear the saved queue and stop Music?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear queue", role: .destructive) { Task { _ = await music.clearQueue() } }
        }
        .confirmationDialog("Reset the unconfirmed request and clear Music’s queue?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Music", role: .destructive) { Task { _ = await music.clearQueue() } }
        }
        .onChange(of: music.footer) { _, value in
            if value.announce { UIAccessibility.post(notification: .announcement, argument: value.accessibilityText) }
        }
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            message
            HStack { Spacer(minLength: 0); controls }
        }
    }

    private var message: some View {
        Text(music.footer.text)
            .lineLimit(1).minimumScaleFactor(0.85).layoutPriority(1)
            .accessibilityLabel(music.footer.accessibilityText)
            .accessibilityIdentifier("strip.text")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            if music.footer.skippedCount > 0 {
                Button("\(music.footer.skippedCount) skipped") { showingSkipped = true }
                    .padding(.horizontal, 8).frame(minHeight: 44)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("\(music.footer.skippedCount) skipped songs. Show skipped songs.")
                    .accessibilityIdentifier("strip.chip")
            }
            if let action = music.footer.action {
                Button(action.rawValue) {
                    switch action {
                    case .retry: Task { await music.retryMatching() }
                    case .connect: Task { await music.authorize() }
                    case .restore, .replay: Task { _ = await music.restoreSavedQueue() }
                    case .details: showSetup()
                    case .reset: confirmingReset = true
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("strip.action")
            }
            Menu {
                Button("Skipped songs (\(music.skippedRows.count))") { showingSkipped = true }
                    .disabled(music.skippedRows.isEmpty)
                Button("Restore saved queue") { Task { _ = await music.restoreSavedQueue() } }
                    .disabled(!music.canRestore)
                Button("Setup", action: showSetup)
                Button("Clear queue…", role: .destructive) { confirmingClear = true }
            } label: {
                Image(systemName: "ellipsis").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Queue options")
            .accessibilityIdentifier("strip.menu")
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SkippedSheet: View {
    @ObservedObject var music: MusicSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(music.skippedRows) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(row.source.title) — \(row.source.artist)").font(.subheadline)
                        Text(reason(row.reason)).font(.caption).foregroundStyle(.secondary)
                        if let state = row.retryState { Text(state.rawValue).font(.caption) }
                    }
                }
                if music.retryableSkippedCount > 0 {
                    Button("Retry \(music.retryableSkippedCount)") { Task { await music.retrySkipped() } }
                }
            }
            .navigationTitle("Skipped songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func reason(_ reason: MatchSkipReason?) -> String {
        switch reason {
        case .invalidSource: "Song details unavailable"
        case .noResults: "No catalog results"
        case .unavailableInStorefront: "Unavailable in your Apple Music storefront"
        case .thirdPartyEdit: "Unverified third-party edit"
        case .noCompatibleMetadata: "No compatible recording"
        case .contentConflict: "Clean or explicit version conflict"
        case .insufficientDurationlessAgreement: "Recording details could not be confirmed. Open the song page and press Play."
        case .ambiguousRecording: "More than one possible recording"
        case nil: "No confident match"
        }
    }
}

private struct NativePlaybackControls: View {
    @ObservedObject var music: MusicSession
    var diagnosticsEnabled: Bool
    var visible: Bool
    @StateObject private var timing = NativeControlTiming()
    @State private var seekPosition: Double?
    @State private var capturedSeekTarget: MusicSession.SeekTarget?
    @State private var toggleIntent: (id: UUID, playing: Bool)?

    private var enabled: Bool {
        AppConfiguration.current.playbackEnabled && music.authorized && music.snapshot.synchronized
    }
    private var playing: Bool {
        toggleIntent?.playing ?? ((music.preparing || music.canPausePreparation)
            ? music.intendedPlaying : music.snapshot.state == "playing")
    }
    private var canToggle: Bool {
        enabled || music.canPausePreparation || (AppConfiguration.current.playbackEnabled && music.authorized &&
            (music.preparing || toggleIntent != nil))
    }
    private var duration: Double { max(0, music.snapshot.duration) }
    private var position: Double { min(max(0, seekPosition ?? music.snapshot.position), duration) }
    private var title: String { music.snapshot.title.isEmpty ? "Choose a song in Spotify" : music.snapshot.title }
    private var artist: String { AppConfiguration.current.playbackEnabled ? music.snapshot.artist : "Browsing Spotify" }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(artist)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button { send(.previous) } label: { Image(systemName: "backward.end.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous song")
                    .disabled(!enabled)
                Button(action: toggle) {
                    Image(systemName: playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 44, height: 44)
                }
                .accessibilityLabel(playing ? "Pause" : "Play")
                .disabled(!canToggle)
                Button { send(.next) } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel("Next song")
                    .disabled(!enabled)
            }
            .buttonStyle(.plain)
            HStack(spacing: 8) {
                Text(time(position))
                Slider(value: Binding(get: { position }, set: { seekPosition = $0 }), in: 0...max(duration, 1)) { editing in
                    let started = diagnosticsEnabled && visible ? TestDiagnostics.nativeControlClockMillis() : 0
                    if editing {
                        capturedSeekTarget = music.seekTarget
                        if seekPosition == nil { seekPosition = music.snapshot.position }
                    } else {
                        let value = seekPosition
                        let target = capturedSeekTarget
                        seekPosition = nil
                        capturedSeekTarget = nil
                        if enabled, let value, let target {
                            let id = commandID()
                            timing.begin(id: id, command: "seek", initialPlaying: playing, started: started, eligible: diagnosticsEnabled && visible)
                            Task {
                                let result = await music.command(.seek(value), commandID: id, expectedSeekTarget: target)
                                timing.returned(id: id, result: result)
                            }
                        }
                    }
                }
                .accessibilityLabel("Playback position")
                .disabled(!enabled || duration <= 0)
                Text(time(duration))
            }
            .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(.bar)
        .background(NativeControlFrameProbe(timing: timing, version: timing.version,
            presentation: NativeControlPresentation(snapshot: music.snapshot, title: title, artist: artist,
                playing: playing, position: position, seeking: seekPosition != nil),
            eligible: diagnosticsEnabled && visible, currentSnapshot: { music.snapshot }))
        .onChange(of: diagnosticsEnabled && visible) { _, eligible in
            if !eligible { timing.cancel() }
        }
        .onDisappear { timing.cancel() }
        .onChange(of: music.snapshot.sourceID) { _, _ in
            seekPosition = nil
            capturedSeekTarget = nil
            toggleIntent = nil
        }
    }

    private func send(_ command: PlaybackCommand) {
        let started = diagnosticsEnabled && visible ? TestDiagnostics.nativeControlClockMillis() : 0
        guard enabled else { return }
        let id = commandID()
        timing.begin(id: id, command: command == .next ? "next" : "previous", initialPlaying: playing, started: started,
            eligible: diagnosticsEnabled && visible)
        Task {
            let result = await music.command(command, commandID: id)
            timing.returned(id: id, result: result)
        }
    }

    private func toggle() {
        let started = diagnosticsEnabled && visible ? TestDiagnostics.nativeControlClockMillis() : 0
        guard canToggle else { return }
        let intent = (id: UUID(), playing: !playing)
        let id = intent.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        timing.begin(id: id, command: intent.playing ? "play" : "pause", initialPlaying: playing, started: started,
            eligible: diagnosticsEnabled && visible)
        toggleIntent = intent
        Task {
            let result = await music.command(intent.playing ? .play : .pause, commandID: id)
            timing.returned(id: id, result: result)
            if toggleIntent?.id == intent.id { toggleIntent = nil }
        }
    }

    private func commandID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    private func time(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

private struct NativeControlPresentation {
    let snapshot: PlaybackSnapshot
    let title: String
    let artist: String
    let playing: Bool
    let position: Double
    let seeking: Bool

    func matches(_ expected: PlaybackSnapshot) -> Bool {
        !seeking && Self.matches(snapshot, expected) &&
            title == (expected.title.isEmpty ? "Choose a song in Spotify" : expected.title) &&
            artist == expected.artist && playing == (expected.state == "playing") && abs(position - expected.position) <= 2
    }

    static func matches(_ value: PlaybackSnapshot, _ expected: PlaybackSnapshot) -> Bool {
        value.synchronized && expected.synchronized && value.revision >= expected.revision &&
            value.sourceID == expected.sourceID && value.title == expected.title && value.artist == expected.artist &&
            value.duration == expected.duration && value.state == expected.state && abs(value.position - expected.position) <= 2
    }
}

@MainActor
private final class NativeControlTiming: ObservableObject {
    @Published private(set) var version: UInt64 = 0
    private struct Sample {
        let id: String
        let command: String
        let revision: UInt64
        let started: Double
        let feedbackPlaying: Bool?
        var feedback: Double?
        var nativeConfirmed: Double?
        var expected: PlaybackSnapshot?
    }
    private var sample: Sample?
    private var deadline: Task<Void, Never>?
    var activeID: String? { sample?.id }

    func begin(id: String, command: String, initialPlaying: Bool, started: Double, eligible: Bool) {
        guard eligible, let revision = TestDiagnostics.nativeControlRevision() else { cancel(); return }
        finish(outcome: 4)
        guard started.isFinite, (0...604_800_000).contains(started) else { return }
        let desired = command == "play" ? true : command == "pause" ? false : nil
        sample = Sample(id: id, command: command, revision: revision, started: started,
            feedbackPlaying: desired == initialPlaying ? nil : desired)
        version &+= 1
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            guard let self, self.sample?.id == id else { return }
            self.finish(outcome: self.sample?.nativeConfirmed == nil ? 3 : 6)
        }
    }

    func returned(id: String, result: PlaybackOutcome) {
        guard var current = sample, current.id == id else { return }
        guard TestDiagnostics.nativeControlRevision() == current.revision else { cancel(); return }
        let returnedAt = TestDiagnostics.nativeControlClockMillis()
        if result.status == .rejected {
            finish(outcome: result.reason == .timedOut ? 3 : 2)
            return
        }
        let elapsed = returnedAt - current.started
        guard elapsed.isFinite, (0...60_000).contains(elapsed) else { finish(outcome: 6); return }
        current.nativeConfirmed = elapsed
        current.expected = result.snapshot
        sample = current
        version &+= 1
    }

    func frameNeeded(_ presentation: NativeControlPresentation) -> String? {
        guard let current = sample else { return nil }
        guard TestDiagnostics.nativeControlRevision() == current.revision else { cancel(); return nil }
        if current.feedback == nil, current.feedbackPlaying == presentation.playing { return current.id }
        if let expected = current.expected, presentation.matches(expected) { return current.id }
        return nil
    }

    func refreshed(id: String, presentation: NativeControlPresentation, native: PlaybackSnapshot, updatedAt: Double) {
        guard var current = sample, current.id == id else { return }
        guard TestDiagnostics.nativeControlRevision() == current.revision else { cancel(); return }
        let refreshedAt = TestDiagnostics.nativeControlClockMillis()
        let elapsed = refreshedAt - current.started
        guard refreshedAt > updatedAt, elapsed.isFinite, (0...60_000).contains(elapsed) else { finish(outcome: 6); return }
        if current.feedback == nil, current.feedbackPlaying == presentation.playing { current.feedback = elapsed }
        sample = current
        if let expected = current.expected {
            guard NativeControlPresentation.matches(native, expected) else { finish(outcome: 6); return }
            guard presentation.matches(expected), let confirmed = current.nativeConfirmed,
                  updatedAt >= current.started + confirmed else { return }
            finish(outcome: 1, completedFrame: elapsed)
        }
    }

    func cancel(id: String? = nil) {
        guard id == nil || sample?.id == id else { return }
        finish(outcome: 5)
    }

    private func finish(outcome: Int, completedFrame: Double? = nil) {
        deadline?.cancel(); deadline = nil
        guard let current = sample else { return }
        sample = nil
        var fields = ["commandId": current.id, "command": current.command,
            "commandStartedMs": milliseconds(current.started), "commandFrameOutcome": String(outcome)]
        if let feedback = current.feedback { fields["feedbackFrameMs"] = milliseconds(feedback) }
        if let confirmed = current.nativeConfirmed { fields["nativeConfirmedMs"] = milliseconds(confirmed) }
        if let completedFrame { fields["completedFrameMs"] = milliseconds(completedFrame) }
        TestDiagnostics.recordNativeControl(fields: fields, revision: current.revision)
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

private struct NativeControlFrameProbe: UIViewRepresentable {
    let timing: NativeControlTiming
    let version: UInt64
    let presentation: NativeControlPresentation
    let eligible: Bool
    let currentSnapshot: @MainActor () -> PlaybackSnapshot

    func makeUIView(context: Context) -> NativeControlFrameView {
        let view = NativeControlFrameView()
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        return view
    }

    func updateUIView(_ view: NativeControlFrameView, context: Context) {
        view.update(timing: timing, presentation: presentation, eligible: eligible, currentSnapshot: currentSnapshot)
    }

    static func dismantleUIView(_ view: NativeControlFrameView, coordinator: ()) { view.cancel() }
}

@MainActor
private final class NativeControlFrameView: UIView {
    private var link: CADisplayLink?
    private weak var timing: NativeControlTiming?
    private var presentation: NativeControlPresentation?
    private var currentSnapshot: (@MainActor () -> PlaybackSnapshot)?
    private var sampleID: String?
    private var updatedAt = 0.0

    func update(timing: NativeControlTiming, presentation: NativeControlPresentation, eligible: Bool,
                currentSnapshot: @escaping @MainActor () -> PlaybackSnapshot) {
        link?.invalidate(); link = nil
        self.timing = timing
        self.presentation = presentation
        self.currentSnapshot = currentSnapshot
        guard eligible else { timing.cancel(); return }
        sampleID = timing.activeID
        guard timing.frameNeeded(presentation) != nil else { return }
        updatedAt = TestDiagnostics.nativeControlClockMillis()
        // This following refresh opportunity is a proxy, not evidence of physical pixels or compositor latency.
        let next = CADisplayLink(target: self, selector: #selector(refreshed(_:)))
        link = next
        next.add(to: .main, forMode: .common)
    }

    @objc private func refreshed(_ sender: CADisplayLink) {
        guard sender === link else { sender.invalidate(); return }
        link?.invalidate(); link = nil
        guard let window, window.windowScene?.activationState == .foregroundActive,
              !window.isHidden, window.rootViewController?.presentedViewController == nil,
              bounds.width > 0, bounds.height > 0, convert(bounds, to: window).intersects(window.bounds),
              let id = sampleID, let presentation, let currentSnapshot else { cancel(); return }
        var node: UIView? = self
        while let current = node {
            guard !current.isHidden, current.alpha > 0 else { cancel(); return }
            node = current.superview
        }
        timing?.refreshed(id: id, presentation: presentation, native: currentSnapshot(), updatedAt: updatedAt)
    }

    func cancel() {
        link?.invalidate(); link = nil
        if let sampleID { timing?.cancel(id: sampleID) }
        sampleID = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancel() }
    }
}
