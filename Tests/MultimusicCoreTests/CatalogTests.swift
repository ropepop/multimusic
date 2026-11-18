import XCTest
import MultimusicCore

final class CatalogTests: XCTestCase {
    func testAlbumLookupRequiresExactEditionAndPreservesSourceOrderIncludingRepeats() throws {
        let data = Data(#"""
        {"results":[
          {"wrapperType":"collection","collectionType":"Album","collectionId":10,"collectionName":"Record (Deluxe Edition)","artistName":"Artist"},
          {"kind":"song","trackId":1,"trackName":"One","artistName":"Artist","trackTimeMillis":200000,"trackExplicitness":"notExplicit","collectionId":10,"collectionName":"Record (Deluxe Edition)"},
          {"kind":"song","trackId":2,"trackName":"Two","artistName":"Artist","trackTimeMillis":220000,"trackExplicitness":"notExplicit","collectionId":10,"collectionName":"Record (Deluxe Edition)"},
          {"kind":"song","trackId":3,"trackName":"Foreign","artistName":"Artist","trackTimeMillis":200000,"trackExplicitness":"notExplicit","collectionId":99,"collectionName":"Other Album"}
        ]}
        """#.utf8)
        let album = try XCTUnwrap(ITunesCatalog.album(from: data))
        let one = SourceTrack(id: "AAAAAAAAAAA", title: "One", artist: "Artist")
        let two = SourceTrack(id: "BBBBBBBBBBB", title: "Two", artist: "Artist")
        let foreign = SourceTrack(id: "CCCCCCCCCCC", title: "Foreign", artist: "Artist")
        let context = SourceContext(kind: .album, title: "Record", artist: "Artist", edition: "Deluxe Edition", selectedSourceID: two.id)
        let decisions = try XCTUnwrap(album.resolve([two, one, two, foreign], context: context))

        XCTAssertEqual(decisions.map { $0?.track.id }, ["2", "1", "2", nil])
        XCTAssertEqual(decisions[0]?.track.collectionID, "10")
        XCTAssertEqual(decisions[0]?.confidence, .metadataOnly)
        for context in [
            SourceContext(kind: .album, title: "Record", artist: "Artist", selectedSourceID: two.id),
            SourceContext(kind: .album, title: "Record (Deluxe Edition)", artist: "Other Artist", selectedSourceID: two.id),
            SourceContext(kind: .playlist, title: "Record (Deluxe Edition)", artist: "Artist", selectedSourceID: two.id)
        ] {
            XCTAssertNil(album.resolve([two], context: context))
        }
    }

    func testSourceContextDecodeBoundsTheUntrustedSelection() throws {
        let valid = Data(#"{"kind":"album","title":"Record","artist":"Artist","selectedSourceID":"AAAAAAAAAAA","selectedOrdinal":600}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(SourceContext.self, from: valid).selectedOrdinal, 600)
        let invalid = [
            #"{"kind":"album","title":"Record","selectedSourceID":"AAAAAAAAAAA"}"#,
            #"{"kind":"home","selectedSourceID":"bad"}"#,
            #"{"kind":"home","selectedSourceID":"AAAAAAAAAAA\n"}"#,
            #"{"kind":"search","selectedSourceID":"AAAAAAAAAAA","selectedOrdinal":10000}"#,
            #"{"kind":"radio","selectedSourceID":"AAAAAAAAAAA","selectedOrdinal":-1}"#,
            #"{"kind":"unknown","selectedSourceID":"AAAAAAAAAAA","collectionID":"https://example.com"}"#,
            #"{"kind":"home","selectedSourceID":"AAAAAAAAAAA","title":"TITLE"}"#.replacingOccurrences(of: "TITLE", with: String(repeating: "x", count: 501))
        ]
        for json in invalid {
            XCTAssertThrowsError(try JSONDecoder().decode(SourceContext.self, from: Data(json.utf8)))
        }
    }

    func testSourceContextMigratesLegacyProviderAndValidatesEachProvidersIdentifiers() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(SourceContext.self, from: Data(#"{"kind":"home","selectedSourceID":"AAAAAAAAAAA"}"#.utf8))
        let migrated = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertEqual(migrated["provider"] as? String, "youtubeMusic")
        let spotify = try decoder.decode(SourceContext.self, from: Data(#"{"provider":"spotify","kind":"playlist","collectionID":"1234567890ABCDEFGHIJKL","selectedSourceID":"ABCDEFGHIJKLMNOPQRSTUV"}"#.utf8))
        XCTAssertEqual(spotify.selectedSourceID, "ABCDEFGHIJKLMNOPQRSTUV")
        for json in [
            #"{"provider":"spotify","kind":"home","selectedSourceID":"AAAAAAAAAAA"}"#,
            #"{"provider":"youtubeMusic","kind":"home","selectedSourceID":"ABCDEFGHIJKLMNOPQRSTUV"}"#,
            #"{"provider":"spotify","kind":"home","selectedSourceID":"ABCDEFGHIJ_KLMNOPQRSTU"}"#,
            #"{"provider":"spotify","kind":"playlist","collectionID":"bad_id","selectedSourceID":"ABCDEFGHIJKLMNOPQRSTUV"}"#,
            #"{"provider":"unknown","kind":"home","selectedSourceID":"AAAAAAAAAAA"}"#
        ] {
            XCTAssertThrowsError(try decoder.decode(SourceContext.self, from: Data(json.utf8)))
        }
    }

    func testPositiveCacheExpiresSeparatesStorefrontsAndEvictsOldestAtItsBound() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let source = SourceTrack(id: "first", title: "Song", artist: "Artist", duration: 200)
        let track = CatalogTrack(id: "catalog", title: "Song", artist: "Artist", duration: 200, isExplicit: false)
        let decision = MatchDecision(track: track, confidence: .metadataAndDuration)
        var cache = CatalogMatchCache()
        cache.store(decision, source: source, country: "US", now: now)
        cache = try JSONDecoder().decode(CatalogMatchCache.self, from: JSONEncoder().encode(cache))

        XCTAssertEqual(cache.decision(source: source, country: "us", now: now.addingTimeInterval(86_399)), decision)
        XCTAssertNil(cache.decision(source: source, country: "GB", now: now))
        XCTAssertNil(cache.decision(source: source, country: "US", now: now.addingTimeInterval(86_400)))
        XCTAssertNil(cache.decision(source: source, country: "US", now: now.addingTimeInterval(-1)))
        XCTAssertNil(cache.decision(source: SourceTrack(id: "first", title: "Other Song", artist: "Artist", duration: 200), country: "US", now: now))
        for index in 1...500 {
            cache.store(decision, source: SourceTrack(id: "source-\(index)", title: "Song", artist: "Artist", duration: 200), country: "US", now: now)
        }
        XCTAssertNil(cache.decision(source: source, country: "US", now: now))
        XCTAssertEqual(cache.decision(source: SourceTrack(id: "source-500", title: "Song", artist: "Artist", duration: 200), country: "US", now: now), decision)
    }
}
