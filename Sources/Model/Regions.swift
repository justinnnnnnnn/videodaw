import Foundation

/// Regions copied from a project, ready to paste.
public struct Clipboard: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var region: Region
        public var kind: TrackKind
        /// Index of the track the region was copied from.
        public var trackIndex: Int
        /// Distance from the earliest region start in the clipboard.
        public var offset: Ticks
    }

    public var items: [Item]
    public var isEmpty: Bool { items.isEmpty }

    public init(items: [Item] = []) { self.items = items }
}

// MARK: Creating and arranging regions

extension Project {
    /// Places the whole of a media item on a track. Returns nil if the media or track is
    /// missing or their kinds differ.
    @discardableResult
    public mutating func addRegion(mediaID: UUID, trackID: UUID, at tick: Ticks) -> UUID? {
        guard let item = media(mediaID), let t = trackIndex(trackID),
              tracks[t].kind == item.kind else { return nil }
        let length = max(1, ticks(seconds: seconds(flicks: item.duration)))
        let region = Region(mediaID: mediaID, name: (item.path as NSString).lastPathComponent,
                            start: max(0, tick), length: length)
        tracks[t].regions.append(region)
        return region.id
    }

    /// Moves regions as a group. The time move is clamped so no region starts before 0.
    /// The track move applies only if every region lands on an existing track of its own
    /// kind; otherwise only the time move applies.
    public mutating func moveRegions(_ ids: Set<UUID>, deltaTicks: Ticks, deltaTracks: Int) {
        var selected: [(track: Int, region: Region)] = []
        for (t, track) in tracks.enumerated() {
            for region in track.regions where ids.contains(region.id) { selected.append((t, region)) }
        }
        guard let earliest = selected.map(\.region.start).min() else { return }
        let delta = max(deltaTicks, -earliest)
        let canChangeTrack = deltaTracks != 0 && selected.allSatisfy {
            let target = $0.track + deltaTracks
            return tracks.indices.contains(target) && tracks[target].kind == tracks[$0.track].kind
        }
        if canChangeTrack {
            for t in tracks.indices { tracks[t].regions.removeAll { ids.contains($0.id) } }
            for (t, region) in selected {
                var moved = region
                moved.start += delta
                tracks[t + deltaTracks].regions.append(moved)
            }
        } else {
            for t in tracks.indices {
                for i in tracks[t].regions.indices where ids.contains(tracks[t].regions[i].id) {
                    tracks[t].regions[i].start += delta
                }
            }
        }
    }

    public mutating func deleteRegions(_ ids: Set<UUID>) {
        for t in tracks.indices { tracks[t].regions.removeAll { ids.contains($0.id) } }
    }

    /// Copies the regions onto their own tracks, the group starting where the latest of
    /// them ends. Returns the ids of the copies.
    @discardableResult
    public mutating func duplicate(_ ids: Set<UUID>) -> [UUID] {
        let selected = tracks.flatMap(\.regions).filter { ids.contains($0.id) }
        guard let earliest = selected.map(\.start).min(), let latest = selected.map(\.end).max()
        else { return [] }
        var newIDs: [UUID] = []
        var links: [UUID: UUID] = [:]
        for t in tracks.indices {
            for region in tracks[t].regions where ids.contains(region.id) {
                var copy = region
                copy.id = UUID()
                copy.start += latest - earliest
                copy.link = relinked(region.link, &links)
                tracks[t].regions.append(copy)
                newIDs.append(copy.id)
            }
        }
        return newIDs
    }

    public mutating func setRegionMuted(_ ids: Set<UUID>, _ muted: Bool) {
        for t in tracks.indices {
            for i in tracks[t].regions.indices where ids.contains(tracks[t].regions[i].id) {
                tracks[t].regions[i].muted = muted
            }
        }
    }

    public mutating func renameRegion(_ id: UUID, to name: String) {
        guard let loc = location(of: id) else { return }
        tracks[loc.track].regions[loc.index].name = name
    }
}

// MARK: Links

/// The link a copy should carry: copies made together of regions that were linked together
/// share one new link, and are not linked to the originals.
func relinked(_ link: UUID?, _ links: inout [UUID: UUID]) -> UUID? {
    guard let link else { return nil }
    if let known = links[link] { return known }
    let fresh = UUID()
    links[link] = fresh
    return fresh
}

extension Project {
    /// `ids` plus every region linked to one of them.
    public func linkedRegions(_ ids: Set<UUID>) -> Set<UUID> {
        let all = tracks.flatMap(\.regions)
        let links = Set(all.filter { ids.contains($0.id) }.compactMap(\.link))
        guard !links.isEmpty else { return ids }
        return ids.union(all.filter { $0.link.map(links.contains) ?? false }.map(\.id))
    }

    /// Links the regions to each other, replacing any links they had. Needs at least two.
    public mutating func link(_ ids: Set<UUID>) {
        guard ids.count >= 2 else { return }
        let shared = UUID()
        for t in tracks.indices {
            for i in tracks[t].regions.indices where ids.contains(tracks[t].regions[i].id) {
                tracks[t].regions[i].link = shared
            }
        }
    }

    /// Frees the regions to be edited on their own.
    public mutating func unlink(_ ids: Set<UUID>) {
        for t in tracks.indices {
            for i in tracks[t].regions.indices where ids.contains(tracks[t].regions[i].id) {
                tracks[t].regions[i].link = nil
            }
        }
    }
}

// MARK: Clipboard

extension Project {
    public func copyRegions(_ ids: Set<UUID>) -> Clipboard {
        var items: [Clipboard.Item] = []
        for (t, track) in tracks.enumerated() {
            for region in track.regions where ids.contains(region.id) {
                items.append(Clipboard.Item(region: region, kind: track.kind, trackIndex: t, offset: 0))
            }
        }
        let earliest = items.map(\.region.start).min() ?? 0
        for i in items.indices { items[i].offset = items[i].region.start - earliest }
        return Clipboard(items: items)
    }

    /// Pastes with the earliest region at `tick`. With `topTrackIndex` the clipboard's
    /// top-most track maps to that index and the others keep their distance from it; with
    /// nil, regions return to the track indices they were copied from. A region whose target
    /// track is missing or of the wrong kind is skipped. Returns the ids of the new regions.
    @discardableResult
    public mutating func paste(_ clipboard: Clipboard, at tick: Ticks, topTrackIndex: Int? = nil) -> [UUID] {
        guard let top = clipboard.items.map(\.trackIndex).min() else { return [] }
        var newIDs: [UUID] = []
        var links: [UUID: UUID] = [:]
        for item in clipboard.items {
            let target = item.trackIndex + ((topTrackIndex ?? top) - top)
            guard tracks.indices.contains(target), tracks[target].kind == item.kind else { continue }
            var region = item.region
            region.id = UUID()
            region.link = relinked(region.link, &links)
            region.start = max(0, tick) + item.offset
            tracks[target].regions.append(region)
            newIDs.append(region.id)
        }
        return newIDs
    }
}

// MARK: Fades

/// A region's fades after crossfades from overlap have been applied.
public struct Fades: Equatable, Sendable {
    public var fadeIn: Ticks
    public var fadeOut: Ticks
    public init(fadeIn: Ticks, fadeOut: Ticks) { self.fadeIn = fadeIn; self.fadeOut = fadeOut }
}

extension Project {
    /// Clamped to `0 ... length - fadeOut`.
    public mutating func setFadeIn(_ id: UUID, _ ticks: Ticks) {
        guard let loc = location(of: id) else { return }
        let region = tracks[loc.track].regions[loc.index]
        tracks[loc.track].regions[loc.index].fadeIn = min(max(0, ticks), region.length - region.fadeOut)
    }

    /// Clamped to `0 ... length - fadeIn`.
    public mutating func setFadeOut(_ id: UUID, _ ticks: Ticks) {
        guard let loc = location(of: id) else { return }
        let region = tracks[loc.track].regions[loc.index]
        tracks[loc.track].regions[loc.index].fadeOut = min(max(0, ticks), region.length - region.fadeIn)
    }
}

extension Track {
    /// Every region's effective fades. Where a region's tail overlaps the head of a region
    /// that starts later and ends no earlier, the pair crossfades: the earlier region's
    /// fade-out and the later region's fade-in are each at least the overlap, bounded by
    /// their own lengths. Muted regions, and a region lying wholly inside another, cause
    /// no crossfade. Other regions keep their own fades.
    public func resolvedFades() -> [UUID: Fades] {
        var result: [UUID: Fades] = [:]
        for region in regions {
            result[region.id] = Fades(fadeIn: region.fadeIn, fadeOut: region.fadeOut)
        }
        let live = regions.filter { !$0.muted }
        for earlier in live {
            for later in live
            where earlier.start < later.start && later.start < earlier.end && earlier.end <= later.end {
                let overlap = earlier.end - later.start
                result[earlier.id]!.fadeOut = max(result[earlier.id]!.fadeOut, min(overlap, earlier.length))
                result[later.id]!.fadeIn = max(result[later.id]!.fadeIn, min(overlap, later.length))
            }
        }
        return result
    }
}
