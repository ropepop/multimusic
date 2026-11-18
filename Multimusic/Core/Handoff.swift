import Foundation

public struct HandedOffTrack: Codable, Equatable, Sendable {
    public let source: SourceTrack
    public let catalog: CatalogTrack

    public init(source: SourceTrack, catalog: CatalogTrack) {
        self.source = source
        self.catalog = catalog
    }
}

public enum HandoffReconciliation: Equatable, Sendable {
    case matched(index: Int)
    case externalItem
    case ambiguous
    case noCurrentItem
}

public struct QueueHandoff: Codable, Equatable, Sendable {
    public let revision: UUID
    public let tracks: [HandedOffTrack]

    public init(revision: UUID = UUID(), tracks: [HandedOffTrack]) {
        self.revision = revision
        self.tracks = tracks
    }

    // This identifies saved metadata, not the origin or remaining contents of the live system queue.
    public func reconcile(currentCatalogID: String?) -> HandoffReconciliation {
        guard let currentCatalogID, !currentCatalogID.isEmpty else { return .noCurrentItem }
        let indices = tracks.indices.filter { tracks[$0].catalog.id == currentCatalogID }
        guard indices.count < 2 else { return .ambiguous }
        return indices.first.map { .matched(index: $0) } ?? .externalItem
    }
}
