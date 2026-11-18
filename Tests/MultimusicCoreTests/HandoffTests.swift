import XCTest
import MultimusicCore

final class HandoffTests: XCTestCase {
    func testRestorationRequiresAnUnambiguousSavedOccurrence() throws {
        let first = entry(sourceID: "source-a", catalogID: "apple-a")
        let second = entry(sourceID: "source-b", catalogID: "apple-b")
        let handoff = QueueHandoff(tracks: [first, second, first])
        let restored = try JSONDecoder().decode(QueueHandoff.self, from: JSONEncoder().encode(handoff))

        XCTAssertEqual(restored.revision, handoff.revision)
        XCTAssertEqual(restored.tracks, [first, second, first])
        XCTAssertEqual(restored.reconcile(currentCatalogID: "apple-b"), .matched(index: 1))
        XCTAssertEqual(restored.reconcile(currentCatalogID: "apple-a"), .ambiguous)
        XCTAssertEqual(restored.reconcile(currentCatalogID: "external"), .externalItem)
        XCTAssertEqual(restored.reconcile(currentCatalogID: nil), .noCurrentItem)
        XCTAssertEqual(restored.reconcile(currentCatalogID: ""), .noCurrentItem)
    }

    private func entry(sourceID: String, catalogID: String) -> HandedOffTrack {
        HandedOffTrack(
            source: SourceTrack(id: sourceID, title: "Source Song", artist: "Source Artist", duration: 200, isrc: "USABC1234567", isExplicit: true),
            catalog: CatalogTrack(id: catalogID, title: "Catalog Song", artist: "Catalog Artist", duration: 201, isrc: "USABC1234567", isExplicit: true)
        )
    }
}
