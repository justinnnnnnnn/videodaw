import Foundation
import Model

/// One tick at 120 bpm, in flicks. At 120 bpm one second is 1920 ticks.
let tickFlicks: Flicks = 367_500

func flicks(_ seconds: Double) -> Flicks {
    Flicks((seconds * Double(flicksPerSecond)).rounded())
}

/// Two video tracks above two audio tracks, a 4 s video clip and a 1 s sound, at 120 bpm.
struct Fixture {
    var project = Project()
    let video1: UUID
    let video2: UUID
    let audio1: UUID
    let audio2: UUID
    /// 4 s of video: 7680 ticks at 120 bpm.
    let clip: UUID
    /// 1 s of audio: 1920 ticks at 120 bpm.
    let sound: UUID

    init() {
        video1 = project.addTrack(kind: .video)
        video2 = project.addTrack(kind: .video)
        audio1 = project.addTrack(kind: .audio)
        audio2 = project.addTrack(kind: .audio)
        clip = project.addMedia(Media(path: "/footage/street.mov", kind: .video, duration: flicks(4)))
        sound = project.addMedia(Media(path: "/samples/kick.wav", kind: .audio, duration: flicks(1)))
    }

    mutating func addClip(at tick: Ticks, on track: UUID? = nil) -> UUID {
        project.addRegion(mediaID: clip, trackID: track ?? video1, at: tick)!
    }

    mutating func addSound(at tick: Ticks, on track: UUID? = nil) -> UUID {
        project.addRegion(mediaID: sound, trackID: track ?? audio1, at: tick)!
    }

    func region(_ id: UUID) -> Region { project.region(id)! }

    func regions(on track: UUID) -> [Region] {
        project.track(track)!.regions.sorted { $0.start < $1.start }
    }
}

/// The source time shown on a track at a tick: nil where no region covers it. Overlapping
/// regions are reported as `Flicks.min` so they never compare equal by accident.
func shown(_ project: Project, track: UUID, at tick: Ticks) -> Flicks? {
    let covering = project.track(track)!.regions.filter { $0.start <= tick && tick < $0.end }
    if covering.count > 1 { return .min }
    return covering.first.flatMap { project.sourceFlicks(of: $0, at: tick) }
}

/// The largest difference, in flicks, between what two projects show on a track over a
/// span of ticks. `Flicks.max` if one shows something where the other shows nothing.
func drift(_ a: Project, _ b: Project, track: UUID, over ticks: Range<Ticks>) -> Flicks {
    var worst: Flicks = 0
    for tick in ticks {
        switch (shown(a, track: track, at: tick), shown(b, track: track, at: tick)) {
        case (nil, nil): continue
        case let (x?, y?): worst = max(worst, abs(x - y))
        default: return .max
        }
    }
    return worst
}
