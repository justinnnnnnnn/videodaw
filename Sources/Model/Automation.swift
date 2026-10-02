import Foundation

extension Param {
    /// The value at a tick: `value` when there are no points; otherwise linear interpolation
    /// between points, held flat before the first and after the last.
    public func value(at tick: Ticks) -> Double {
        guard let first = points.first, let last = points.last else { return value }
        if tick <= first.tick { return first.value }
        if tick >= last.tick { return last.value }
        var low = 0, high = points.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if points[mid].tick <= tick { low = mid } else { high = mid }
        }
        let a = points[low], b = points[high]
        return a.value + (b.value - a.value) * Double(tick - a.tick) / Double(b.tick - a.tick)
    }
}

// MARK: Parameter access

extension Project {
    /// The parameter at `path` on a track. Nil if the track or effect slot is missing, a
    /// track parameter belongs to the other kind of track, a built-in effect index is out of
    /// range, or an Audio Unit parameter has not been set or automated yet.
    public func param(_ path: ParamPath, track trackID: UUID) -> Param? {
        guard let track = track(trackID) else { return nil }
        switch path {
        case .track(let p):
            return p.kind == track.kind ? track.param(p) : nil
        case .effectMix(let slotID):
            return track.effects.first { $0.id == slotID }?.mix
        case .effect(let slotID, let address):
            guard let slot = track.effects.first(where: { $0.id == slotID }) else { return nil }
            if slot.kind == .audioUnit { return slot.params[address] }
            guard address < UInt64(slot.kind.paramSpecs.count) else { return nil }
            return slot.builtinParam(Int(address))
        }
    }

    /// The legal values of the parameter at `path`: the track parameter's range, 0...1 for
    /// an effect mix, the spec range for a built-in effect parameter. Nil for Audio Unit
    /// parameters (only the plugin knows) and for paths that do not exist.
    public func paramRange(_ path: ParamPath, track trackID: UUID) -> ClosedRange<Double>? {
        guard let track = track(trackID) else { return nil }
        switch path {
        case .track(let p):
            return p.kind == track.kind ? p.range : nil
        case .effectMix(let slotID):
            return track.effects.contains { $0.id == slotID } ? 0...1 : nil
        case .effect(let slotID, let address):
            guard let slot = track.effects.first(where: { $0.id == slotID }),
                  address < UInt64(slot.kind.paramSpecs.count) else { return nil }
            return slot.kind.paramSpecs[Int(address)].range
        }
    }

    /// Writes the parameter at `path`. Points are sorted by tick (a later point at the same
    /// tick wins) and values are clamped to the parameter's range where one is known.
    /// Returns false, changing nothing, if the path does not exist on that track.
    @discardableResult
    public mutating func setParam(_ path: ParamPath, track trackID: UUID, _ param: Param) -> Bool {
        guard let t = trackIndex(trackID) else { return false }
        let range = paramRange(path, track: trackID)
        func clamped(_ value: Double) -> Double {
            range.map { min(max(value, $0.lowerBound), $0.upperBound) } ?? value
        }
        var points: [AutoPoint] = []
        for point in param.points.enumerated().sorted(by: {
            ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset)
        }).map(\.element) {
            let point = AutoPoint(tick: max(0, point.tick), value: clamped(point.value))
            if points.last?.tick == point.tick { points[points.count - 1] = point } else { points.append(point) }
        }
        let param = Param(clamped(param.value), points: points)

        switch path {
        case .track(let p):
            guard p.kind == tracks[t].kind else { return false }
            tracks[t].params[p] = param == Param(p.defaultValue) ? nil : param
        case .effectMix(let slotID):
            guard let s = tracks[t].effects.firstIndex(where: { $0.id == slotID }) else { return false }
            tracks[t].effects[s].mix = param
        case .effect(let slotID, let address):
            guard let s = tracks[t].effects.firstIndex(where: { $0.id == slotID }) else { return false }
            let kind = tracks[t].effects[s].kind
            guard kind == .audioUnit || address < UInt64(kind.paramSpecs.count) else { return false }
            tracks[t].effects[s].params[address] = param
        }
        return true
    }

    /// Sets the static value, which applies whenever the parameter has no points.
    @discardableResult
    public mutating func setValue(_ path: ParamPath, track trackID: UUID, _ value: Double) -> Bool {
        var param = self.param(path, track: trackID) ?? Param(value)
        param.value = value
        return setParam(path, track: trackID, param)
    }
}

// MARK: Automation points

extension Project {
    /// Adds a point, replacing any point already at that tick. The static value is left
    /// alone. Returns the point's index, or nil if the path does not exist.
    @discardableResult
    public mutating func addPoint(_ path: ParamPath, track trackID: UUID, tick: Ticks, value: Double) -> Int? {
        var param = self.param(path, track: trackID) ?? Param(value)
        let tick = max(0, tick)
        param.points.removeAll { $0.tick == tick }
        param.points.append(AutoPoint(tick: tick, value: value))
        guard setParam(path, track: trackID, param) else { return nil }
        return self.param(path, track: trackID)?.points.firstIndex { $0.tick == tick }
    }

    /// Moves a point. Its tick is kept strictly between its neighbours (and at or after 0),
    /// so the point keeps its index and never swallows another point.
    public mutating func movePoint(_ path: ParamPath, track trackID: UUID, index: Int,
                                   to tick: Ticks, value: Double) {
        guard var param = self.param(path, track: trackID), param.points.indices.contains(index) else { return }
        let lowest = index > 0 ? param.points[index - 1].tick + 1 : 0
        let highest = index < param.points.count - 1 ? param.points[index + 1].tick - 1 : Ticks.max
        if lowest <= highest { param.points[index].tick = min(max(tick, lowest), highest) }
        param.points[index].value = value
        setParam(path, track: trackID, param)
    }

    /// Removes a point. With the last point gone the parameter is its static value again.
    public mutating func removePoint(_ path: ParamPath, track trackID: UUID, index: Int) {
        guard var param = self.param(path, track: trackID), param.points.indices.contains(index) else { return }
        param.points.remove(at: index)
        setParam(path, track: trackID, param)
    }
}

// MARK: Effects

extension Project {
    /// Adds an effect slot at `index` in the track's chain (clamped; nil appends). Built-in
    /// video effects are rejected on audio tracks, as is a slot id already on the track.
    @discardableResult
    public mutating func addEffect(_ slot: EffectSlot, to trackID: UUID, at index: Int? = nil) -> Bool {
        guard let t = trackIndex(trackID),
              slot.kind == .audioUnit || tracks[t].kind == .video,
              !tracks[t].effects.contains(where: { $0.id == slot.id }) else { return false }
        let count = tracks[t].effects.count
        tracks[t].effects.insert(slot, at: min(max(0, index ?? count), count))
        return true
    }

    /// Removes a slot, and closes the track's automation lane if it was showing that slot.
    public mutating func removeEffect(_ slotID: UUID, track trackID: UUID) {
        guard let t = trackIndex(trackID) else { return }
        tracks[t].effects.removeAll { $0.id == slotID }
        switch tracks[t].automationShown {
        case .effectMix(slotID), .effect(slotID, _): tracks[t].automationShown = nil
        default: break
        }
    }

    /// Moves the slot at index `from` so that it ends up at index `to`.
    public mutating func moveEffect(track trackID: UUID, from: Int, to: Int) {
        guard let t = trackIndex(trackID), tracks[t].effects.indices.contains(from),
              tracks[t].effects.indices.contains(to), from != to else { return }
        tracks[t].effects.insert(tracks[t].effects.remove(at: from), at: to)
    }

    public mutating func setEffectBypass(_ slotID: UUID, track trackID: UUID, _ bypass: Bool) {
        guard let t = trackIndex(trackID),
              let s = tracks[t].effects.firstIndex(where: { $0.id == slotID }) else { return }
        tracks[t].effects[s].bypass = bypass
    }

    /// Bend mode applies to video tracks only. Returns false if it was not set.
    @discardableResult
    public mutating func setBendMode(_ slotID: UUID, track trackID: UUID, _ mode: BendMode) -> Bool {
        guard let t = trackIndex(trackID), tracks[t].kind == .video,
              let s = tracks[t].effects.firstIndex(where: { $0.id == slotID }) else { return false }
        tracks[t].effects[s].bendMode = mode
        return true
    }
}
