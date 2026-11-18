import Foundation

@main
struct WebsiteDiagnosticsChecks {
    static func main() {
        let probe = ["qpKind": "capture", "qpCapture": "1", "qpHash": "abcdef12", "qpSelected": "-1", "qpPaused": "true"]
        assert(WebsiteDiagnosticFields.acceptsQueueProbe(probe))
        for (key, value) in [("qpHash", "raw-song"), ("qpKind", "title"), ("documentId", String(repeating: "a", count: 32)), ("qpRows", "NaN")] {
            assert(!WebsiteDiagnosticFields.acceptsQueueProbe(probe.merging([key: value]) { _, new in new }))
        }
        assert(!WebsiteDiagnosticFields.acceptsQueueProbe(["qpKind": "row"]))
        for path in ["title", "cover", "keyboard"] {
            assert(WebsiteDiagnosticFields.acceptsAggregate(["expandPath": path]))
        }
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["expandPath": "song title"]))
        assert(WebsiteDiagnosticFields.acceptsAggregate(["collapsePath": "arrow"]))
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["collapsePath": "song title"]))
        assert(WebsiteDiagnosticFields.acceptsAggregate(["miniTapUnmapped": "1", "composedPathTags": "button,yt-icon-button,ytmusic-player-bar"]))
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["composedPathTags": String(repeating: "a", count: 65)]))
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["composedPathTags": "a[href] "]))
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["commandStartedMs": "1"]))
        assert(WebsiteDiagnosticFields.acceptsAggregate(["commandStartedMs": "1", "commandId": String(repeating: "a", count: 32)]))
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["documentId": String(repeating: "a", count: 32)]))
        let hitFields = ["hitX": "156", "hitY": "582", "seekResolved": "true", "sliderVis": "false",
            "seekRectX": "0", "seekRectY": "578", "seekRectWidth": "402", "seekRectHeight": "8",
            "aggregateRoot": "ytmusic-player-bar", "seekMissReason": "none",
            "hitStack0": "div#progressContainer.track@0,578,402,8^tp-yt-paper-slider",
            "hitStack1": "tp-yt-paper-slider#progress-bar[slider]@0,578,402,8^div",
            "hitStack2": "div@0,578,402,8^none", "hitStack3": "ytmusic-player-bar@0,582,402,80^none", "hitStack4": "none"]
        assert(WebsiteDiagnosticFields.acceptsAggregate(hitFields))
        let miniAggregate = ["aggregateRoot": "ytmusic-miniplayer", "barWidth": "402", "barHeight": "64"]
        assert(WebsiteDiagnosticFields.acceptsAggregate(miniAggregate))
        for key in ["barWidth", "barHeight"] {
            assert(!WebsiteDiagnosticFields.acceptsAggregate(miniAggregate.merging([key: "ytmusic-miniplayer"]) { _, new in new }))
        }
        for key in ["hitStack0", "hitStack1", "hitStack2", "hitStack3", "hitStack4"] {
            for bad in ["song title", "div[href=secret]@0,0,1,1^none", "div@0,0,1,1^none\n", String(repeating: "a", count: 65)] {
                assert(!WebsiteDiagnosticFields.acceptsAggregate([key: bad]))
            }
        }
        for reason in ["row", "volume", "transportOther", "notVisible", "noRoot", "narrow", "outside", "navigation", "none"] {
            assert(WebsiteDiagnosticFields.acceptsAggregate(["seekMissReason": reason]))
        }
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["seekMissReason": "song title"]))
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["aggregateRoot": "song title"]))
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["seekResolved": "1"]))
        assert(!WebsiteDiagnosticFields.acceptsAggregate(["sliderVis": "yes"]))
        print("Website diagnostic checks passed: expansion paths, bounded unmapped tags, Round 6 hit diagnostics and ytmusic-miniplayer 402x64 aggregates cross the production bridge; arbitrary text, nonnumeric geometry, oversized tags and unpaired timing fields reject.")
    }
}
