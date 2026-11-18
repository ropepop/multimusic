import Foundation

public struct CatalogMatchCache: Codable, Sendable {
    private struct Entry: Codable, Sendable {
        let source: SourceTrack
        let country: String
        let decision: MatchDecision
        let createdAt: Date
    }
    private var entries: [Entry] = []

    public init() {}

    public func decision(source: SourceTrack, country: String, now: Date = Date()) -> MatchDecision? {
        entries.last {
            $0.source == source && $0.country == country.lowercased() &&
            $0.createdAt <= now && now.timeIntervalSince($0.createdAt) < 86_400
        }?.decision
    }

    public mutating func store(_ decision: MatchDecision, source: SourceTrack, country: String, now: Date = Date()) {
        let country = country.lowercased()
        entries.removeAll {
            ($0.source == source && $0.country == country) ||
            $0.createdAt > now || now.timeIntervalSince($0.createdAt) >= 86_400
        }
        entries.append(Entry(source: source, country: country, decision: decision, createdAt: now))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }

    private enum CodingKeys: CodingKey { case entries }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        entries = Array(try values.decode([Entry].self, forKey: .entries).suffix(500))
    }
}
