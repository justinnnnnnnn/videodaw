import Foundation

// Edits that change which part of the source a region shows: trim, split, loop, stretch
// and reverse. None of them touch the media.

// MARK: Source mapping

extension Project {
    /// The source time a region shows at a timeline tick, honouring loop, speed and reverse.
    /// Nil outside `region.start ..< region.end`.
    ///
    /// A forward iteration runs from `sourceOffset` up towards the end of its span. A
    /// reversed iteration runs from the end of its span down towards `sourceOffset`, so at
    /// the first tick of an iteration it returns the span's (exclusive) end.
    public func sourceFlicks(of region: Region, at tick: Ticks) -> Flicks? {
        guard tick >= region.start, tick < region.end, region.contentLength > 0 else { return nil }
        let local = (tick - region.start) % region.contentLength
        let position = sourceDelta(local, speed: region.speed)
        if region.reversed {
            return region.sourceOffset + sourceDelta(region.contentLength, speed: region.speed) - position
        }
        return region.sourceOffset + position
    }

    /// Removes `ticks` from the front of the iteration (the part shown first on the
    /// timeline), or with negative `ticks` reveals that much more in front of it.
    private func dropContentHead(_ region: inout Region, _ ticks: Ticks) {
        if !region.reversed {
            region.sourceOffset = max(0, region.sourceOffset + sourceDelta(ticks, speed: region.speed))
        }
        region.contentLength -= ticks
    }

    /// Sets the iteration to `ticks` long by removing from, or revealing at, its back (the
    /// part shown last on the timeline).
    private func resizeContentTail(_ region: inout Region, to ticks: Ticks) {
        if region.reversed {
            let spanEnd = region.sourceOffset + sourceDelta(region.contentLength, speed: region.speed)
            region.sourceOffset = max(0, spanEnd - sourceDelta(ticks, speed: region.speed))
        }
        region.contentLength = ticks
    }

    /// How far the front and back of the iteration can be extended before running out of
    /// source. Zero if the media is missing.
    private func room(around region: Region) -> (head: Ticks, tail: Ticks) {
        guard let item = media(region.mediaID) else { return (0, 0) }
        let before = maxTicks(fitting: region.sourceOffset, speed: region.speed)
        let after = max(0, maxTicks(fitting: item.duration - region.sourceOffset, speed: region.speed)
                            - region.contentLength)
        return region.reversed ? (after, before) : (before, after)
    }
}

// MARK: Trim and loop

extension Project {
    /// Moves a region's start without moving its content on the timeline. Dragging right
    /// hides the beginning; dragging left reveals it again, as far as the source and tick 0
    /// allow. On a looped region this trims the repeated iteration and keeps the region's end.
    public mutating func trimStart(_ id: UUID, to newStart: Ticks) {
        guard let loc = location(of: id) else { return }
        var region = tracks[loc.track].regions[loc.index]
        let lowest = -min(room(around: region).head, region.start)
        let delta = min(max(newStart - region.start, lowest), region.contentLength - 1)
        guard delta != 0 else { return }
        dropContentHead(&region, delta)
        region.start += delta
        region.length -= delta
        region.clampFades()
        tracks[loc.track].regions[loc.index] = region
    }

    /// Moves a region's end. Dragging left hides the end of the content; dragging right
    /// reveals it again as far as the source allows. On a looped region only the number of
    /// repetitions changes, unless the new end falls inside the first iteration, which
    /// un-loops the region and trims it.
    public mutating func trimEnd(_ id: UUID, to newEnd: Ticks) {
        resizeEnd(id, to: newEnd, looping: false)
    }

    /// Drags the loop handle: the region repeats until `newEnd`. An end inside the first
    /// iteration un-loops the region and trims it like `trimEnd`, keeping its content.
    public mutating func setLoopEnd(_ id: UUID, to newEnd: Ticks) {
        resizeEnd(id, to: newEnd, looping: true)
    }

    private mutating func resizeEnd(_ id: UUID, to newEnd: Ticks, looping: Bool) {
        guard let loc = location(of: id) else { return }
        var region = tracks[loc.track].regions[loc.index]
        let length = max(1, newEnd - region.start)
        if length >= region.contentLength && (looping || region.isLooped) {
            region.length = length
        } else {
            let longest = region.contentLength + room(around: region).tail
            resizeContentTail(&region, to: min(length, longest))
            region.length = region.contentLength
        }
        region.clampFades()
        tracks[loc.track].regions[loc.index] = region
    }
}

// MARK: Split

extension Project {
    /// Splits the given regions that strictly contain `tick`. The original keeps its id and
    /// becomes the left piece; returns the ids of the new pieces to its right. What plays
    /// is unchanged. A looped region split inside an iteration yields three pieces: the
    /// loop up to the split, the rest of that iteration, and a loop from the next iteration
    /// boundary on.
    @discardableResult
    public mutating func split(_ ids: Set<UUID>, at tick: Ticks) -> [UUID] {
        var newIDs: [UUID] = []
        // Linked regions cut together stay linked piece by piece: left with left, right
        // with right. One link table per piece position keeps the positions apart.
        var links: [[UUID: UUID]] = []
        for t in tracks.indices {
            var regions: [Region] = []
            for region in tracks[t].regions {
                guard ids.contains(region.id), region.start < tick, tick < region.end else {
                    regions.append(region)
                    continue
                }
                var pieces = splitPieces(of: region, at: tick)
                for i in pieces.indices.dropFirst() {
                    while links.count < i { links.append([:]) }
                    pieces[i].link = relinked(region.link, &links[i - 1])
                }
                regions += pieces
                newIDs += pieces.dropFirst().map(\.id)
            }
            tracks[t].regions = regions
        }
        return newIDs
    }

    private func splitPieces(of region: Region, at tick: Ticks) -> [Region] {
        /// A piece of `region` beginning on an iteration boundary.
        func piece(from start: Ticks, to end: Ticks, id: UUID) -> Region {
            var piece = region
            piece.id = id
            piece.start = start
            piece.length = end - start
            if piece.length < piece.contentLength { resizeContentTail(&piece, to: piece.length) }
            return piece
        }

        var pieces = [piece(from: region.start, to: tick, id: region.id)]
        let phase = (tick - region.start) % region.contentLength
        var cursor = tick
        if phase != 0 {
            // The remainder of the iteration the split falls in.
            var rest = region
            rest.id = UUID()
            rest.start = tick
            dropContentHead(&rest, phase)
            rest.length = min(rest.contentLength, region.end - tick)
            if rest.length < rest.contentLength { resizeContentTail(&rest, to: rest.length) }
            pieces.append(rest)
            cursor = rest.end
        }
        if cursor < region.end {
            pieces.append(piece(from: cursor, to: region.end, id: UUID()))
        }
        for i in pieces.indices {
            if i > 0 { pieces[i].fadeIn = 0 }
            if i < pieces.count - 1 { pieces[i].fadeOut = 0 }
            pieces[i].clampFades()
        }
        return pieces
    }

    /// Splits every region on the given tracks at both ends of `range` and returns the ids
    /// of the regions that then lie inside it. An empty range changes nothing.
    @discardableResult
    public mutating func splitRange(_ range: Range<Ticks>, trackIDs: Set<UUID>) -> Set<UUID> {
        guard !range.isEmpty else { return [] }
        func regionsOnTracks() -> [Region] {
            tracks.filter { trackIDs.contains($0.id) }.flatMap(\.regions)
        }
        split(Set(regionsOnTracks().map(\.id)), at: range.lowerBound)
        split(Set(regionsOnTracks().map(\.id)), at: range.upperBound)
        return Set(regionsOnTracks()
            .filter { $0.start >= range.lowerBound && $0.end <= range.upperBound }
            .map(\.id))
    }

    /// Removes everything inside `range` on the given tracks, cutting regions at its ends.
    public mutating func deleteRange(_ range: Range<Ticks>, trackIDs: Set<UUID>) {
        deleteRegions(splitRange(range, trackIDs: trackIDs))
    }
}

// MARK: Stretch and reverse

extension Project {
    /// Plays the same source span in `newLength` ticks by changing the region's speed. A
    /// looped region keeps its number of repetitions. With `anchorEnd` the end stays put and
    /// the start moves, not past tick 0.
    public mutating func stretch(_ id: UUID, toLength newLength: Ticks, anchorEnd: Bool = false) {
        guard let loc = location(of: id) else { return }
        var region = tracks[loc.track].regions[loc.index]
        let end = region.end
        let length = anchorEnd ? min(max(1, newLength), max(1, end)) : max(1, newLength)
        guard length != region.length else { return }
        let content = region.isLooped
            ? max(1, Ticks((Double(region.contentLength) * Double(length) / Double(region.length)).rounded()))
            : length
        region.speed *= Double(region.contentLength) / Double(content)
        region.contentLength = content
        region.length = length
        if anchorEnd { region.start = end - length }
        region.clampFades()
        tracks[loc.track].regions[loc.index] = region
    }

    /// Toggles backwards playback. The visible source span is unchanged.
    public mutating func reverse(_ ids: Set<UUID>) {
        for t in tracks.indices {
            for i in tracks[t].regions.indices where ids.contains(tracks[t].regions[i].id) {
                tracks[t].regions[i].reversed.toggle()
            }
        }
    }
}
