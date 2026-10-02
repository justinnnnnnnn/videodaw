import Foundation

// MARK: Lookup

extension Project {
    public func trackIndex(_ id: UUID) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    public func track(_ id: UUID) -> Track? {
        tracks.first { $0.id == id }
    }

    public func media(_ id: UUID) -> Media? {
        media.first { $0.id == id }
    }

    /// Where a region lives: index into `tracks` and into that track's `regions`.
    public func location(of regionID: UUID) -> (track: Int, index: Int)? {
        for (t, track) in tracks.enumerated() {
            if let i = track.regions.firstIndex(where: { $0.id == regionID }) { return (t, i) }
        }
        return nil
    }

    public func region(_ id: UUID) -> Region? {
        location(of: id).map { tracks[$0.track].regions[$0.index] }
    }
}

// MARK: Tracks

extension Project {
    /// Adds a track at `index` (clamped; nil appends). With no name it is called
    /// "Video N" / "Audio N", N counting tracks of that kind.
    @discardableResult
    public mutating func addTrack(kind: TrackKind, name: String? = nil, at index: Int? = nil) -> UUID {
        let ordinal = tracks.filter { $0.kind == kind }.count + 1
        let track = Track(name: name ?? "\(kind == .video ? "Video" : "Audio") \(ordinal)", kind: kind)
        tracks.insert(track, at: min(max(0, index ?? tracks.count), tracks.count))
        return track.id
    }

    public mutating func removeTrack(_ id: UUID) {
        tracks.removeAll { $0.id == id }
    }

    /// Moves the track at index `from` so that it ends up at index `to`.
    public mutating func moveTrack(from: Int, to: Int) {
        guard tracks.indices.contains(from), tracks.indices.contains(to), from != to else { return }
        tracks.insert(tracks.remove(at: from), at: to)
    }

    public mutating func renameTrack(_ id: UUID, to name: String) {
        guard let t = trackIndex(id) else { return }
        tracks[t].name = name
    }

    public mutating func setTrackMuted(_ id: UUID, _ muted: Bool) {
        guard let t = trackIndex(id) else { return }
        tracks[t].muted = muted
    }

    public mutating func setTrackSolo(_ id: UUID, _ solo: Bool) {
        guard let t = trackIndex(id) else { return }
        tracks[t].solo = solo
    }

    /// Blend modes apply to video tracks only; ignored on audio tracks.
    public mutating func setBlend(_ id: UUID, _ blend: BlendMode) {
        guard let t = trackIndex(id), tracks[t].kind == .video else { return }
        tracks[t].blend = blend
    }

    /// Tracks that are heard or seen. A muted track never is; if any track of a kind is
    /// soloed, only the soloed tracks of that kind are.
    public var audibleTrackIDs: Set<UUID> {
        let soloKinds = Set(tracks.filter(\.solo).map(\.kind))
        return Set(tracks.filter { !$0.muted && ($0.solo || !soloKinds.contains($0.kind)) }.map(\.id))
    }

    /// True if mute and solo leave the track silent (or the track does not exist).
    public func isTrackSilent(_ id: UUID) -> Bool {
        !audibleTrackIDs.contains(id)
    }
}

// MARK: Media

extension Project {
    /// Adds a media item, replacing any existing item with the same id.
    @discardableResult
    public mutating func addMedia(_ item: Media) -> UUID {
        if let i = media.firstIndex(where: { $0.id == item.id }) {
            media[i] = item
        } else {
            media.append(item)
        }
        return item.id
    }
}
