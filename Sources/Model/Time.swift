import Foundation

// MARK: Grid

/// Snap divisions. A beat is one beat of the time signature: a quarter note in 4/4, an
/// eighth note in 6/8. `half` … `sixteenth` are fractions of that beat.
public enum GridDivision: String, Codable, CaseIterable, Sendable {
    case bar, beat, half, quarter, eighth, sixteenth

    public func ticks(beatsPerBar: Int, beatUnit: Int = 4) -> Ticks {
        let beat = ticksPerBeat * 4 / Ticks(beatUnit)
        switch self {
        case .bar: return beat * Ticks(max(1, beatsPerBar))
        case .beat: return beat
        case .half: return beat / 2
        case .quarter: return beat / 4
        case .eighth: return beat / 8
        case .sixteenth: return beat / 16
        }
    }
}

// MARK: Time signature

extension Project {
    /// The signature's lower number, always one of 2, 4, 8 or 16.
    public var signatureUnit: Int { [2, 4, 8, 16].contains(beatUnit ?? 4) ? beatUnit ?? 4 : 4 }

    /// One beat of the time signature.
    public var beatTicks: Ticks { ticksPerBeat * 4 / Ticks(signatureUnit) }

    /// One measure of the time signature.
    public var barTicks: Ticks { beatTicks * Ticks(max(1, beatsPerBar)) }

    /// One video frame at the project's frame rate, to the nearest tick.
    public var frameTicks: Ticks { max(1, ticks(seconds: 1 / fps)) }

    public func gridTicks(_ division: GridDivision) -> Ticks {
        division.ticks(beatsPerBar: beatsPerBar, beatUnit: signatureUnit)
    }

    /// Sets the time signature. Out-of-range values are pulled into range: 1 to 32 beats,
    /// over 2, 4, 8 or 16. Nothing on the timeline moves; only the grid changes.
    public mutating func setTimeSignature(beats: Int, unit: Int) {
        beatsPerBar = min(32, max(1, beats))
        beatUnit = [2, 4, 8, 16].contains(unit) ? unit : 4
    }

    /// Where a tick falls in measures: bar and beat count from 1, `ticks` is what is left
    /// over inside the beat.
    public func position(at tick: Ticks) -> (bar: Int, beat: Int, ticks: Ticks) {
        let tick = max(0, tick)
        let within = tick % barTicks
        return (Int(tick / barTicks) + 1, Int(within / beatTicks) + 1, within % beatTicks)
    }
}

// MARK: Time conversion

extension Project {
    public func seconds(_ ticks: Ticks) -> Double {
        Double(ticks) * 60 / (Double(ticksPerBeat) * tempo)
    }

    public func ticks(seconds: Double) -> Ticks {
        Ticks((seconds * tempo * Double(ticksPerBeat) / 60).rounded())
    }

    public func flicks(seconds: Double) -> Flicks {
        Flicks((seconds * Double(flicksPerSecond)).rounded())
    }

    public func seconds(flicks: Flicks) -> Double {
        Double(flicks) / Double(flicksPerSecond)
    }

    /// End of the last region across all tracks; 0 for an empty project.
    public var lengthTicks: Ticks {
        tracks.lazy.flatMap(\.regions).map(\.end).max() ?? 0
    }

    /// The nearest grid line to `tick` (ties round up), never negative.
    public func snap(_ tick: Ticks, to division: GridDivision) -> Ticks {
        let grid = max(1, gridTicks(division))
        return (max(0, tick) + grid / 2) / grid * grid
    }

    /// Changes the tempo. Region starts and automation points stay at their ticks; region
    /// lengths, content lengths and fades are rescaled so each region lasts the same real time.
    public mutating func setTempo(_ bpm: Double) {
        guard bpm.isFinite, bpm > 0, bpm != tempo else { return }
        let factor = bpm / tempo
        func scaled(_ ticks: Ticks) -> Ticks { Ticks((Double(ticks) * factor).rounded()) }
        for t in tracks.indices {
            for i in tracks[t].regions.indices {
                var region = tracks[t].regions[i]
                region.contentLength = max(1, scaled(region.contentLength))
                region.length = max(region.contentLength, scaled(region.length))
                region.fadeIn = scaled(region.fadeIn)
                region.fadeOut = scaled(region.fadeOut)
                region.clampFades()
                tracks[t].regions[i] = region
            }
        }
        tempo = bpm
    }
}

// MARK: Source arithmetic shared by the region edits

extension Project {
    /// Source time consumed by `ticks` of timeline at `speed`. Symmetric for negative ticks.
    func sourceDelta(_ ticks: Ticks, speed: Double) -> Flicks {
        flicks(seconds: seconds(ticks) * speed)
    }

    /// The most ticks whose source span at `speed` fits inside `available` flicks.
    func maxTicks(fitting available: Flicks, speed: Double) -> Ticks {
        guard available > 0, speed > 0 else { return 0 }
        var count = Ticks((seconds(flicks: available) / speed / seconds(1)).rounded(.down))
        while sourceDelta(count + 1, speed: speed) <= available { count += 1 }
        while count > 0, sourceDelta(count, speed: speed) > available { count -= 1 }
        return count
    }
}

extension Region {
    /// Keeps fades non-negative and within the region: `fadeIn + fadeOut <= length`.
    mutating func clampFades() {
        fadeIn = min(max(0, fadeIn), length)
        fadeOut = min(max(0, fadeOut), length - fadeIn)
    }
}
