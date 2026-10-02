import Engine
import Foundation
import Model

public let engineSampleRate = Double(VD_SAMPLE_RATE)

extension UUID {
    /// A stable 64-bit identity for the engine's per-track and per-effect state.
    var engineID: UInt64 {
        withUnsafeBytes(of: uuid) { $0.loadUnaligned(as: UInt64.self) }
    }
}

extension Project {
    /// Timeline ticks as engine sample frames.
    public func samples(_ ticks: Ticks) -> Int64 {
        Int64((seconds(ticks) * engineSampleRate).rounded())
    }

    public func ticks(samples: Int64) -> Ticks {
        ticks(seconds: Double(samples) / engineSampleRate)
    }
}

/// Owns the C arrays a plan points into for as long as the plan is in use.
private final class Arena {
    private var blocks: [UnsafeMutableRawPointer] = []

    func array<T>(_ items: [T]) -> UnsafePointer<T>? {
        guard !items.isEmpty else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: items.count)
        pointer.initialize(from: items, count: items.count)
        blocks.append(UnsafeMutableRawPointer(pointer))
        return UnsafePointer(pointer)
    }

    deinit { blocks.forEach { $0.deallocate() } }
}

/// What the compiler needs to know about media and plugins the engine has already opened.
/// Each lookup returns nil while the thing is still loading; the region or effect is then
/// left out of this plan and a later compile picks it up.
struct EngineHandles {
    var video: (Media) -> Int32?
    var audio: (Media) -> Int32?
    var plugin: (EffectSlot) -> Int32?
}

/// Turns a project into a render plan: ticks become sample frames, overlaps become
/// crossfades, solo becomes mute, automation becomes curves.
enum PlanCompiler {
    /// Builds the plan and passes it to `body`. The plan is only valid during the call.
    static func compile(_ project: Project, handles: EngineHandles, body: (inout VDPlan) -> Void) {
        let arena = Arena()

        func curve(_ param: Param) -> VDCurve {
            let points = param.points.map { VDPoint(time: project.samples($0.tick), value: Float($0.value)) }
            return VDCurve(constant: Float(param.value), points: arena.array(points), count: Int32(points.count))
        }

        func effect(_ slot: EffectSlot) -> VDEffect? {
            var fx = VDEffect()
            fx.id = slot.id.engineID
            fx.bypass = slot.bypass ? 1 : 0
            fx.mix = curve(slot.mix)
            fx.au = -1
            if slot.kind == .audioUnit {
                guard let handle = handles.plugin(slot) else { return nil }
                fx.kind = Int32(VD_FX_AU)
                fx.au = handle
                fx.bendMode = Int32(slot.bendMode == .raster ? VD_BEND_RASTER : VD_BEND_THROUGH_TIME)
                fx.memoryFrames = Int32((slot.bendMemory ?? .short).rawValue)
                // Only automated parameters are driven by the plan; the rest belong to the
                // plugin, so its own window stays in charge of them.
                let automated = slot.params.filter { !$0.value.points.isEmpty }
                    .map { VDAUParam(address: $0.key, curve: curve($0.value)) }
                fx.auParams = arena.array(automated)
                fx.auParamCount = Int32(automated.count)
            } else {
                fx.kind = Int32(EffectKind.allCases.firstIndex(of: slot.kind)!)
                var curves = [VDCurve](repeating: VDCurve(), count: Int(VD_FX_PARAMS))
                for index in slot.kind.paramSpecs.indices.prefix(curves.count) {
                    curves[index] = curve(slot.builtinParam(index))
                }
                fx.params = (curves[0], curves[1], curves[2], curves[3])
            }
            return fx
        }

        var videoTracks: [VDVideoTrack] = []
        var audioTracks: [VDAudioTrack] = []

        // The timeline lists the front-most video track first; the engine draws back to front.
        for track in project.tracks.reversed() {
            let fades = track.resolvedFades()
            let effects = track.effects.compactMap(effect)
            let silent = project.isTrackSilent(track.id)
            let ordered = track.regions.sorted { $0.start < $1.start }

            func span(_ region: Region) -> (start: Int64, length: Int64, content: Int64) {
                let start = project.samples(region.start)
                let length = max(1, project.samples(region.end) - start)
                let content = region.isLooped ? max(1, project.samples(region.contentLength)) : length
                return (start, length, content)
            }

            switch track.kind {
            case .video:
                let regions: [VDVideoRegion] = ordered.compactMap { region in
                    guard let media = project.media(region.mediaID), let handle = handles.video(media) else { return nil }
                    let s = span(region)
                    var r = VDVideoRegion()
                    r.media = handle
                    r.muted = region.muted ? 1 : 0
                    r.start = s.start
                    r.length = s.length
                    r.contentLength = s.content
                    r.sourceStart = project.seconds(flicks: region.sourceOffset)
                    r.speed = region.speed
                    r.reversed = region.reversed ? 1 : 0
                    r.fadeIn = project.samples(fades[region.id]?.fadeIn ?? region.fadeIn)
                    r.fadeOut = project.samples(fades[region.id]?.fadeOut ?? region.fadeOut)
                    return r
                }
                var t = VDVideoTrack()
                t.id = track.id.engineID
                t.regions = arena.array(regions)
                t.regionCount = Int32(regions.count)
                t.effects = arena.array(effects)
                t.effectCount = Int32(effects.count)
                t.opacity = curve(track.param(.opacity))
                t.x = curve(track.param(.x))
                t.y = curve(track.param(.y))
                t.scale = curve(track.param(.scale))
                t.rotation = curve(track.param(.rotation))
                t.cropLeft = curve(track.param(.cropLeft))
                t.cropRight = curve(track.param(.cropRight))
                t.cropTop = curve(track.param(.cropTop))
                t.cropBottom = curve(track.param(.cropBottom))
                t.blend = Int32(BlendMode.allCases.firstIndex(of: track.blend)!)
                t.muted = silent ? 1 : 0
                videoTracks.append(t)

            case .audio:
                let regions: [VDAudioRegion] = ordered.compactMap { region in
                    guard let media = project.media(region.mediaID), let handle = handles.audio(media) else { return nil }
                    let s = span(region)
                    var r = VDAudioRegion()
                    r.id = region.id.engineID
                    r.media = handle
                    r.muted = region.muted ? 1 : 0
                    r.start = s.start
                    r.length = s.length
                    r.contentLength = s.content
                    r.sourceOffset = Int64((project.seconds(flicks: region.sourceOffset) * engineSampleRate).rounded())
                    r.speed = region.speed
                    r.reversed = region.reversed ? 1 : 0
                    r.fadeIn = project.samples(fades[region.id]?.fadeIn ?? region.fadeIn)
                    r.fadeOut = project.samples(fades[region.id]?.fadeOut ?? region.fadeOut)
                    return r
                }
                var t = VDAudioTrack()
                t.id = track.id.engineID
                t.regions = arena.array(regions)
                t.regionCount = Int32(regions.count)
                t.effects = arena.array(effects)
                t.effectCount = Int32(effects.count)
                t.volume = curve(track.param(.volume))
                t.pan = curve(track.param(.pan))
                t.muted = silent ? 1 : 0
                audioTracks.append(t)
            }
        }

        var plan = VDPlan()
        plan.width = Int32(project.width)
        plan.height = Int32(project.height)
        plan.fps = project.fps
        plan.bendHeight = Int32(project.bendHeight)
        let bendWidth = (Double(project.bendHeight) * Double(project.width) / Double(max(1, project.height))).rounded()
        plan.bendWidth = Int32(max(2, Int(bendWidth) / 2 * 2))
        plan.videoTracks = arena.array(videoTracks)
        plan.videoTrackCount = Int32(videoTracks.count)
        plan.audioTracks = arena.array(audioTracks)
        plan.audioTrackCount = Int32(audioTracks.count)
        withExtendedLifetime(arena) { body(&plan) }
    }
}
