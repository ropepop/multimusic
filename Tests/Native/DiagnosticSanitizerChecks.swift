extension DiagnosticSanitizer {
    static func check() {
        assert(allowedEvents.contains("native.queueProbe"))
        assert(allowedEvents.contains("web.queueProbe"))
        var probe = Dictionary(uniqueKeysWithValues: queueProbeNativeFields.map { ($0, "0") })
        for key in queueProbeHashes where queueProbeNativeFields.contains(key) { probe[key] = "abcdef123456" }
        probe.merge(["qpTrigger": "itemNotification", "qpClass": "sequential", "qpOwnState": "uncertain",
            "qpMKS": "songs", "qpMKR": "none", "qpAction": "Restore"]) { _, new in new }
        assert(probe.count <= 48)
        assert(hasRequiredFields("native.queueProbe", fields: probe))
        assert(probe.allSatisfy { safeField($0.key, $0.value) && permitsField($0.key, event: "native.queueProbe") })
        assert(try! JSONSerialization.data(withJSONObject: probe).count <= 1024)
        assert(safeField("qpDelta", "-3"))
        assert(!safeField("qpStore", "raw-store-id"))
        assert(!safeField("qpAction", "Song title"))
        assert(!permitsField("qpStore", event: "native.state"))
        assert(!permitsField("qpKind", event: "native.queueProbe"))
        assert(!permitsField("qpStore", event: "web.queueProbe"))
        assert(allowedEvents.contains("native.match"))
        let fields = ["durationlessGuard": "tiedDurationGroups", "durationGroupCounts": "3,3", "distinctISRCCount": "6"]
        assert(hasRequiredFields("native.match", fields: fields))
        assert(!hasRequiredFields("native.match", fields: ["durationlessGuard": "tiedDurationGroups"]))
        assert(fields.allSatisfy { safeField($0.key, $0.value) && permitsField($0.key, event: "native.match") })
        for guardName in ["invalidDuration", "tiedDurationGroups", "recordingAgreement"] {
            assert(safeField("durationlessGuard", guardName))
        }
        assert(!safeField("durationlessGuard", "song title"))
        for counts in ["0", "2", "3,3", "200,1"] { assert(safeField("durationGroupCounts", counts)) }
        for counts in ["", "1,", "01", "-1", "1.5", "1000", String(repeating: "1,", count: 16) + "1"] {
            assert(!safeField("durationGroupCounts", counts))
        }
        for count in ["0", "1", "200"] { assert(safeField("distinctISRCCount", count)) }
        for count in ["-1", "201", "01", "NaN"] { assert(!safeField("distinctISRCCount", count)) }
        for span in ["0", "15.0", "48.6", "2.001"] {
            assert(safeField("tiedSpanSeconds", span))
            assert(permitsField("tiedSpanSeconds", event: "native.match"))
        }
        for span in ["-1", "NaN", "inf", "01", "1e2", "1.2345", ""] { assert(!safeField("tiedSpanSeconds", span)) }
        assert(safeField("collapsePath", "arrow"))
        assert(permitsField("collapsePath", event: "web.aggregate"))
        assert(!safeField("collapsePath", "song title"))
        let hitFields = ["hitX": "156", "hitY": "582", "seekResolved": "true", "sliderVis": "false",
            "seekRectX": "0", "seekRectY": "578", "seekRectWidth": "402", "seekRectHeight": "8",
            "aggregateRoot": "ytmusic-player-bar", "seekMissReason": "none",
            "hitStack0": "div#progressContainer.track@0,578,402,8^tp-yt-paper-slider",
            "hitStack1": "tp-yt-paper-slider#progress-bar[slider]@0,578,402,8^div",
            "hitStack2": "div@0,578,402,8^none", "hitStack3": "ytmusic-player-bar@0,582,402,80^none", "hitStack4": "none"]
        assert(hitFields.allSatisfy { safeField($0.key, $0.value) && permitsField($0.key, event: "web.aggregate") })
        let miniAggregate = ["aggregateRoot": "ytmusic-miniplayer", "barWidth": "402", "barHeight": "64"]
        assert(hasRequiredFields("web.aggregate", fields: miniAggregate))
        assert(miniAggregate.allSatisfy { safeField($0.key, $0.value) && permitsField($0.key, event: "web.aggregate") })
        for key in ["barWidth", "barHeight"] {
            assert(!safeField(key, "ytmusic-miniplayer"))
        }
        assert(try! JSONSerialization.data(withJSONObject: hitFields.merging(["documentId": String(repeating: "a", count: 32)]) { first, _ in first }).count <= 1024)
        for key in ["hitStack0", "hitStack1", "hitStack2", "hitStack3", "hitStack4"] {
            for bad in ["song title", "div[href=secret]@0,0,1,1^none", "div@0,0,1,1^none\n", String(repeating: "a", count: 65)] {
                assert(!safeField(key, bad))
            }
        }
        for reason in ["row", "volume", "transportOther", "notVisible", "noRoot", "narrow", "outside", "navigation", "none"] {
            assert(safeField("seekMissReason", reason))
        }
        assert(!safeField("seekMissReason", "song title"))
        assert(!safeField("aggregateRoot", "song title"))
        assert(!safeField("seekResolved", "1"))
        assert(!safeField("sliderVis", "yes"))
    }
}

@main
struct DiagnosticSanitizerChecks {
    static func main() {
        DiagnosticSanitizer.check()
        print("Diagnostic sanitizer checks passed: matching guards, group counts, distinct ISRC counts, tied spans, collapse arrows, Round 6 hit diagnostics and ytmusic-miniplayer 402x64 aggregates survive; nonnumeric geometry and invalid values reject.")
    }
}
