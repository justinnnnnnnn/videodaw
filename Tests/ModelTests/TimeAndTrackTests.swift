import Foundation
import Testing
import Model

@Suite struct TimeTests {
    @Test func convertsBetweenTicksSecondsAndFlicks() {
        var project = Project()
        #expect(project.seconds(1920) == 1)
        #expect(project.ticks(seconds: 1) == 1920)
        #expect(project.ticks(seconds: 0.5) == 960)
        #expect(project.flicks(seconds: 1) == flicksPerSecond)
        #expect(project.seconds(flicks: flicksPerSecond * 3) == 3)
        #expect(project.flicks(seconds: project.seconds(1)) == tickFlicks)

        project.setTempo(60)
        #expect(project.seconds(960) == 1)
        #expect(project.ticks(seconds: 2) == 1920)
    }

    @Test func ticksFromSecondsRounds() {
        let project = Project()
        #expect(project.ticks(seconds: 1.0002) == 1920)
        #expect(project.ticks(seconds: 1.0003) == 1921)
    }

    @Test func lengthIsTheEndOfTheLastRegion() {
        var f = Fixture()
        #expect(f.project.lengthTicks == 0)
        _ = f.addClip(at: 1000)
        _ = f.addSound(at: 20_000)
        #expect(f.project.lengthTicks == 21_920)
    }

    @Test func tempoChangeKeepsEachRegionsRealTimeDuration() {
        var f = Fixture()
        let clip = f.addClip(at: 1920)
        let loop = f.addSound(at: 960)
        f.project.setLoopEnd(loop, to: 960 + 1920 * 3)
        f.project.setFadeIn(clip, 960)
        f.project.setFadeOut(clip, 480)
        f.project.addPoint(.track(.opacity), track: f.video1, tick: 960, value: 0.5)
        let before = f.project

        f.project.setTempo(60)

        #expect(f.project.tempo == 60)
        let after = f.region(clip)
        #expect(after.start == 1920)
        #expect(after.length == 3840)
        #expect(after.contentLength == 3840)
        #expect(after.fadeIn == 480)
        #expect(after.fadeOut == 240)
        #expect(f.project.seconds(after.length) == before.seconds(7680))
        #expect(after.speed == 1)
        #expect(after.sourceOffset == 0)

        let looped = f.region(loop)
        #expect(looped.start == 960)
        #expect(looped.contentLength == 960)
        #expect(looped.length == 2880)
        #expect(f.project.seconds(looped.length) == 3)

        #expect(f.project.param(.track(.opacity), track: f.video1)?.points == [AutoPoint(tick: 960, value: 0.5)])
    }

    @Test func tempoChangeToAnAwkwardTempoStaysWithinHalfATick() {
        var f = Fixture()
        let clip = f.addClip(at: 0)
        f.project.setTempo(97.3)
        let region = f.region(clip)
        #expect(region.length == region.contentLength)
        #expect(abs(f.project.seconds(region.length) - 4) <= f.project.seconds(1) / 2)
    }

    @Test func invalidTempoIsIgnored() {
        var f = Fixture()
        _ = f.addClip(at: 0)
        let before = f.project
        f.project.setTempo(0)
        f.project.setTempo(-10)
        f.project.setTempo(.nan)
        f.project.setTempo(.infinity)
        #expect(f.project == before)
    }
}

@Suite struct GridTests {
    @Test func divisionLengths() {
        #expect(GridDivision.bar.ticks(beatsPerBar: 4) == 3840)
        #expect(GridDivision.bar.ticks(beatsPerBar: 3) == 2880)
        #expect(GridDivision.beat.ticks(beatsPerBar: 4) == 960)
        #expect(GridDivision.half.ticks(beatsPerBar: 4) == 480)
        #expect(GridDivision.quarter.ticks(beatsPerBar: 4) == 240)
        #expect(GridDivision.eighth.ticks(beatsPerBar: 4) == 120)
        #expect(GridDivision.sixteenth.ticks(beatsPerBar: 4) == 60)
        #expect(GridDivision.allCases.count == 6)
    }

    @Test func snapsToTheNearestGridLine() {
        let project = Project()
        #expect(project.snap(0, to: .beat) == 0)
        #expect(project.snap(479, to: .beat) == 0)
        #expect(project.snap(480, to: .beat) == 960)
        #expect(project.snap(1400, to: .beat) == 960)
        #expect(project.snap(1441, to: .beat) == 1920)
        #expect(project.snap(100, to: .sixteenth) == 120)
        #expect(project.snap(89, to: .sixteenth) == 60)
        #expect(project.snap(5000, to: .bar) == 3840)
        #expect(project.snap(6000, to: .bar) == 7680)
    }

    @Test func snapIsNeverNegative() {
        let project = Project()
        #expect(project.snap(-1, to: .beat) == 0)
        #expect(project.snap(-5000, to: .bar) == 0)
    }

    @Test func barSnapFollowsTheTimeSignature() {
        let project = Project(beatsPerBar: 3)
        #expect(project.snap(2800, to: .bar) == 2880)
        #expect(project.snap(4400, to: .bar) == 5760)
    }
}

@Suite struct TrackTests {
    @Test func addsTracksWithDefaultNamesAtAnIndex() {
        var project = Project()
        let a = project.addTrack(kind: .video)
        let b = project.addTrack(kind: .audio)
        let c = project.addTrack(kind: .video, name: "Overlay", at: 0)
        let d = project.addTrack(kind: .audio, at: 99)
        #expect(project.tracks.map(\.id) == [c, a, b, d])
        #expect(project.tracks.map(\.name) == ["Overlay", "Video 1", "Audio 1", "Audio 2"])
        #expect(project.tracks.map(\.kind) == [.video, .video, .audio, .audio])
        #expect(project.track(c)?.name == "Overlay")
        #expect(project.trackIndex(b) == 2)
    }

    @Test func removesMovesAndRenamesTracks() {
        var f = Fixture()
        f.project.moveTrack(from: 0, to: 2)
        #expect(f.project.tracks.map(\.id) == [f.video2, f.audio1, f.video1, f.audio2])
        f.project.moveTrack(from: 3, to: 0)
        #expect(f.project.tracks.map(\.id) == [f.audio2, f.video2, f.audio1, f.video1])
        let before = f.project
        f.project.moveTrack(from: 0, to: 4)
        f.project.moveTrack(from: -1, to: 0)
        #expect(f.project == before)

        f.project.renameTrack(f.video1, to: "Main")
        #expect(f.project.track(f.video1)?.name == "Main")

        let region = f.addClip(at: 0)
        f.project.removeTrack(f.video1)
        #expect(f.project.track(f.video1) == nil)
        #expect(f.project.region(region) == nil)
        #expect(f.project.tracks.count == 3)
    }

    @Test func soloSilencesOtherTracksOfTheSameKindOnly() {
        var f = Fixture()
        #expect(f.project.audibleTrackIDs == [f.video1, f.video2, f.audio1, f.audio2])

        f.project.setTrackSolo(f.audio1, true)
        #expect(f.project.audibleTrackIDs == [f.video1, f.video2, f.audio1])
        #expect(f.project.isTrackSilent(f.audio2))
        #expect(!f.project.isTrackSilent(f.audio1))
        #expect(!f.project.isTrackSilent(f.video1))

        f.project.setTrackSolo(f.video2, true)
        #expect(f.project.audibleTrackIDs == [f.video2, f.audio1])

        f.project.setTrackSolo(f.audio1, false)
        f.project.setTrackSolo(f.video2, false)
        #expect(f.project.audibleTrackIDs.count == 4)
    }

    @Test func muteSilencesATrackEvenWhenSoloed() {
        var f = Fixture()
        f.project.setTrackMuted(f.video1, true)
        #expect(f.project.isTrackSilent(f.video1))
        #expect(!f.project.isTrackSilent(f.video2))

        f.project.setTrackSolo(f.video1, true)
        #expect(f.project.isTrackSilent(f.video1))
        #expect(f.project.isTrackSilent(f.video2))
        #expect(f.project.audibleTrackIDs == [f.audio1, f.audio2])
    }

    @Test func unknownTrackIsSilent() {
        #expect(Fixture().project.isTrackSilent(UUID()))
    }

    @Test func blendAppliesToVideoTracksOnly() {
        var f = Fixture()
        f.project.setBlend(f.video1, .screen)
        f.project.setBlend(f.audio1, .screen)
        #expect(f.project.track(f.video1)?.blend == .screen)
        #expect(f.project.track(f.audio1)?.blend == .normal)
    }
}

@Suite struct EffectTests {
    @Test func addsEffectsInOrder() {
        var f = Fixture()
        let blur = EffectSlot(kind: .blur)
        let color = EffectSlot(kind: .color)
        let feedback = EffectSlot(kind: .feedback)
        #expect(f.project.addEffect(blur, to: f.video1) == true)
        #expect(f.project.addEffect(color, to: f.video1) == true)
        #expect(f.project.addEffect(feedback, to: f.video1, at: 0) == true)
        #expect(f.project.track(f.video1)?.effects.map(\.id) == [feedback.id, blur.id, color.id])
        #expect(f.project.addEffect(blur, to: f.video1) == false)
        #expect(f.project.addEffect(EffectSlot(kind: .blur), to: UUID()) == false)
    }

    @Test func builtInVideoEffectsAreRejectedOnAudioTracks() {
        var f = Fixture()
        for kind in EffectKind.allCases where kind != .audioUnit {
            #expect(f.project.addEffect(EffectSlot(kind: kind), to: f.audio1) == false)
        }
        #expect(f.project.track(f.audio1)?.effects.isEmpty == true)

        let unit = AudioUnitRef(type: 1, subType: 2, manufacturer: 3, name: "Delay")
        #expect(f.project.addEffect(EffectSlot(kind: .audioUnit, audioUnit: unit), to: f.audio1) == true)
        #expect(f.project.addEffect(EffectSlot(kind: .audioUnit, audioUnit: unit), to: f.video1) == true)
    }

    @Test func removesMovesAndBypassesEffects() {
        var f = Fixture()
        let a = EffectSlot(kind: .blur), b = EffectSlot(kind: .color), c = EffectSlot(kind: .pixelate)
        for slot in [a, b, c] { f.project.addEffect(slot, to: f.video1) }

        f.project.moveEffect(track: f.video1, from: 0, to: 2)
        #expect(f.project.track(f.video1)?.effects.map(\.id) == [b.id, c.id, a.id])
        f.project.moveEffect(track: f.video1, from: 0, to: 3)
        #expect(f.project.track(f.video1)?.effects.map(\.id) == [b.id, c.id, a.id])

        f.project.setEffectBypass(c.id, track: f.video1, true)
        #expect(f.project.track(f.video1)?.effects[1].bypass == true)

        f.project.removeEffect(c.id, track: f.video1)
        #expect(f.project.track(f.video1)?.effects.map(\.id) == [b.id, a.id])
    }

    @Test func removingAnEffectClosesItsAutomationLane() {
        var f = Fixture()
        let blur = EffectSlot(kind: .blur)
        f.project.addEffect(blur, to: f.video1)
        f.project.tracks[0].automationShown = .effect(blur.id, 0)
        f.project.tracks[1].automationShown = .track(.opacity)
        f.project.removeEffect(blur.id, track: f.video1)
        #expect(f.project.tracks[0].automationShown == nil)
        #expect(f.project.tracks[1].automationShown == .track(.opacity))
    }

    @Test func bendModeAppliesOnVideoTracksOnly() {
        var f = Fixture()
        let unit = AudioUnitRef(type: 1, subType: 2, manufacturer: 3, name: "Delay")
        let onVideo = EffectSlot(kind: .audioUnit, audioUnit: unit)
        let onAudio = EffectSlot(kind: .audioUnit, audioUnit: unit)
        f.project.addEffect(onVideo, to: f.video1)
        f.project.addEffect(onAudio, to: f.audio1)

        #expect(f.project.setBendMode(onVideo.id, track: f.video1, .throughTime) == true)
        #expect(f.project.setBendMode(onAudio.id, track: f.audio1, .throughTime) == false)
        #expect(f.project.track(f.video1)?.effects[0].bendMode == .throughTime)
        #expect(f.project.track(f.audio1)?.effects[0].bendMode == .raster)
    }
}
