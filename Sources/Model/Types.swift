import Foundation

// MARK: Time

/// Musical time. 960 ticks per quarter note.
public typealias Ticks = Int64
/// Media time. 705,600,000 flicks per second; divides evenly by common frame and sample rates.
public typealias Flicks = Int64

public let ticksPerBeat: Ticks = 960
public let flicksPerSecond: Flicks = 705_600_000

public enum TrackKind: String, Codable, Sendable { case video, audio }

// MARK: Media

public struct Media: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var path: String
    public var kind: TrackKind
    public var duration: Flicks

    public init(id: UUID = UUID(), path: String, kind: TrackKind, duration: Flicks) {
        self.id = id; self.path = path; self.kind = kind; self.duration = duration
    }
}

// MARK: Parameters and automation

public struct AutoPoint: Codable, Equatable, Sendable {
    public var tick: Ticks
    public var value: Double
    public init(tick: Ticks, value: Double) { self.tick = tick; self.value = value }
}

/// A value that is either static or automated. With no points, `value` applies everywhere.
/// With points (kept sorted by tick), the value is linearly interpolated and held flat
/// before the first and after the last point.
public struct Param: Codable, Equatable, Sendable {
    public var value: Double
    public var points: [AutoPoint]
    public init(_ value: Double, points: [AutoPoint] = []) { self.value = value; self.points = points }
}

public enum TrackParam: String, Codable, CaseIterable, Sendable {
    // Video. x/y are offsets in frame widths/heights (0 = centred), scale 1 = fit,
    // rotation in degrees, crops are fractions 0...1 of the track's picture.
    case opacity, x, y, scale, rotation, cropLeft, cropRight, cropTop, cropBottom
    // Audio. volume is linear gain (1 = unity), pan is -1...1.
    case volume, pan

    public var kind: TrackKind { self == .volume || self == .pan ? .audio : .video }

    public var range: ClosedRange<Double> {
        switch self {
        case .opacity, .cropLeft, .cropRight, .cropTop, .cropBottom: return 0...1
        case .x, .y: return -2...2
        case .scale: return 0...4
        case .rotation: return -360...360
        case .volume: return 0...2
        case .pan: return -1...1
        }
    }

    public var defaultValue: Double {
        switch self {
        case .opacity, .scale, .volume: return 1
        default: return 0
        }
    }
}

public enum BlendMode: String, Codable, CaseIterable, Sendable {
    case normal, add, multiply, screen, difference
}

// MARK: Effects

public enum EffectKind: String, Codable, CaseIterable, Sendable {
    case audioUnit, color, blur, pixelate, feedback, displace
}

public struct ParamSpec: Equatable, Sendable {
    public var name: String
    public var range: ClosedRange<Double>
    public var defaultValue: Double
    public init(_ name: String, _ range: ClosedRange<Double>, _ defaultValue: Double) {
        self.name = name; self.range = range; self.defaultValue = defaultValue
    }
}

extension EffectKind {
    /// Parameters of the built-in video effects, addressed by index. Empty for Audio Units,
    /// whose parameters are addressed by the plugin's own parameter address.
    public var paramSpecs: [ParamSpec] {
        switch self {
        case .audioUnit: return []
        case .color: return [
            ParamSpec("Brightness", -1...1, 0), ParamSpec("Contrast", 0...2, 1),
            ParamSpec("Saturation", 0...2, 1), ParamSpec("Hue", -180...180, 0)]
        case .blur: return [ParamSpec("Radius", 0...50, 8)]
        case .pixelate: return [ParamSpec("Size", 1...200, 16)]
        case .feedback: return [
            ParamSpec("Amount", 0...0.98, 0.7), ParamSpec("Zoom", 0.9...1.1, 1.02),
            ParamSpec("Rotate", -10...10, 0)]
        case .displace: return [
            ParamSpec("Amount", 0...200, 30), ParamSpec("Scale", 1...50, 8),
            ParamSpec("Speed", 0...5, 1)]
        }
    }
}

/// Identifies an installed Audio Unit and carries its saved state.
public struct AudioUnitRef: Codable, Equatable, Sendable {
    public var type: UInt32
    public var subType: UInt32
    public var manufacturer: UInt32
    public var name: String
    /// The plugin's full state as a binary property list.
    public var state: Data?
    public init(type: UInt32, subType: UInt32, manufacturer: UInt32, name: String, state: Data? = nil) {
        self.type = type; self.subType = subType; self.manufacturer = manufacturer
        self.name = name; self.state = state
    }
}

/// How an Audio Unit on a video track reads the picture.
public enum BendMode: String, Codable, CaseIterable, Sendable { case raster, throughTime }

/// How far back a through-time Audio Unit remembers, in frames. Each pixel's history is
/// processed in chunks of this length with the previous chunk as run-up, so anything the
/// effect does over a longer stretch than this is cut short. Longer memory takes longer to
/// catch up after a change: short follows edits at once, long renders ahead in the background.
public enum BendMemory: Int, Codable, CaseIterable, Sendable {
    case short = 32, medium = 256, long = 1024
}

public struct EffectSlot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: EffectKind
    public var audioUnit: AudioUnitRef?
    public var bendMode: BendMode
    /// Through-time memory; nil means short.
    public var bendMemory: BendMemory?
    public var bypass: Bool
    /// Wet/dry, 0...1. Applies to Audio Units on video tracks.
    public var mix: Param
    /// Built-in effects: keyed by index into `kind.paramSpecs`.
    /// Audio Units: keyed by parameter address; only automated or overridden parameters appear.
    public var params: [UInt64: Param]

    public init(id: UUID = UUID(), kind: EffectKind, audioUnit: AudioUnitRef? = nil,
                bendMode: BendMode = .raster, bypass: Bool = false,
                mix: Param = Param(1), params: [UInt64: Param] = [:]) {
        self.id = id; self.kind = kind; self.audioUnit = audioUnit; self.bendMode = bendMode
        self.bypass = bypass; self.mix = mix; self.params = params
    }

    /// The parameter at a built-in index, falling back to the spec's default.
    public func builtinParam(_ index: Int) -> Param {
        params[UInt64(index)] ?? Param(kind.paramSpecs[index].defaultValue)
    }
}

/// Addresses any automatable parameter on a track.
public enum ParamPath: Codable, Hashable, Sendable {
    case track(TrackParam)
    case effectMix(UUID)
    case effect(UUID, UInt64)
}

// MARK: Regions

/// A piece of media on a track.
///
/// One iteration occupies `contentLength` ticks and shows the source span that begins at
/// `sourceOffset` and lasts `seconds(contentLength) * speed`. If `reversed`, that same span
/// plays backwards. When `length > contentLength` the region loops: iteration k begins at
/// `start + k * contentLength`. When not looped, `length == contentLength`.
public struct Region: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var mediaID: UUID
    public var name: String
    public var start: Ticks
    public var length: Ticks
    public var contentLength: Ticks
    public var sourceOffset: Flicks
    /// Source seconds consumed per timeline second. 2 = double speed.
    public var speed: Double
    public var reversed: Bool
    public var fadeIn: Ticks
    public var fadeOut: Ticks
    public var muted: Bool
    /// Regions sharing a link are edited together, as a video's picture and sound are.
    public var link: UUID?

    public init(id: UUID = UUID(), mediaID: UUID, name: String, start: Ticks, length: Ticks,
                contentLength: Ticks? = nil, sourceOffset: Flicks = 0, speed: Double = 1,
                reversed: Bool = false, fadeIn: Ticks = 0, fadeOut: Ticks = 0, muted: Bool = false) {
        self.id = id; self.mediaID = mediaID; self.name = name; self.start = start
        self.length = length; self.contentLength = contentLength ?? length
        self.sourceOffset = sourceOffset; self.speed = speed; self.reversed = reversed
        self.fadeIn = fadeIn; self.fadeOut = fadeOut; self.muted = muted
    }

    public var end: Ticks { start + length }
    public var isLooped: Bool { length > contentLength }
}

// MARK: Tracks and project

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var regions: [Region]
    public var effects: [EffectSlot]
    /// Only parameters that differ from their default or are automated appear here.
    public var params: [TrackParam: Param]
    public var blend: BlendMode
    public var muted: Bool
    public var solo: Bool
    /// Which parameter this track's automation lane shows, if the lane is open.
    public var automationShown: ParamPath?

    public init(id: UUID = UUID(), name: String, kind: TrackKind) {
        self.id = id; self.name = name; self.kind = kind
        regions = []; effects = []; params = [:]; blend = .normal
        muted = false; solo = false; automationShown = nil
    }

    public func param(_ p: TrackParam) -> Param { params[p] ?? Param(p.defaultValue) }
}

public struct Project: Codable, Equatable, Sendable {
    public var name: String
    /// Quarter notes per minute, whatever the time signature.
    public var tempo: Double
    /// The time signature's upper number.
    public var beatsPerBar: Int
    /// The time signature's lower number: the note value that counts as one beat (2, 4, 8
    /// or 16). Nil means 4.
    public var beatUnit: Int?
    public var width: Int
    public var height: Int
    public var fps: Double
    /// Height of the picture-bending signal; width follows the project aspect ratio.
    public var bendHeight: Int
    public var media: [Media]
    /// Top of the list is the front-most video layer, as in the timeline.
    public var tracks: [Track]
    public var cycleOn: Bool
    public var cycleStart: Ticks
    public var cycleEnd: Ticks

    public init(name: String = "Untitled", tempo: Double = 120, beatsPerBar: Int = 4,
                width: Int = 1920, height: Int = 1080, fps: Double = 30) {
        self.name = name; self.tempo = tempo; self.beatsPerBar = beatsPerBar
        self.width = width; self.height = height; self.fps = fps; bendHeight = 180
        media = []; tracks = []
        cycleOn = false; cycleStart = 0; cycleEnd = ticksPerBeat * 16
    }
}
