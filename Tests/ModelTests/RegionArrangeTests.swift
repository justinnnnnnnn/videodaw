import Foundation
import Testing
import Model

@Suite struct RegionArrangeTests {
    @Test func addRegionCoversTheWholeMedia() {
        var f = Fixture()
        let id = f.addClip(at: 960)
        let region = f.region(id)
        #expect(region.name == "street.mov")
        #expect(region.mediaID == f.clip)
        #expect(region.start == 960)
        #expect(region.length == 7680)
        #expect(region.contentLength == 7680)
        #expect(region.sourceOffset == 0)
        #expect(region.speed == 1)
        #expect(!region.reversed && !region.isLooped && !region.muted)
        #expect(f.project.location(of: id)?.track == 0)
        let early = f.project.addRegion(mediaID: f.clip, trackID: f.video1, at: -50)!
        #expect(f.region(early).start == 0)
    }

    @Test func addRegionRejectsMismatchedKindsAndMissingThings() {
        var f = Fixture()
        #expect(f.project.addRegion(mediaID: f.clip, trackID: f.audio1, at: 0) == nil)
        #expect(f.project.addRegion(mediaID: f.sound, trackID: f.video1, at: 0) == nil)
        #expect(f.project.addRegion(mediaID: UUID(), trackID: f.video1, at: 0) == nil)
        #expect(f.project.addRegion(mediaID: f.clip, trackID: UUID(), at: 0) == nil)
        #expect(f.project.tracks.allSatisfy { $0.regions.isEmpty })
    }

    @Test func addMediaReplacesAnItemWithTheSameID() {
        var f = Fixture()
        var item = f.project.media(f.clip)!
        item.path = "/moved/street.mov"
        f.project.addMedia(item)
        #expect(f.project.media.count == 2)
        #expect(f.project.media(f.clip)?.path == "/moved/street.mov")
    }

    @Test func movesRegionsInTime() {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        let b = f.addSound(at: 500)
        let c = f.addSound(at: 9000)
        f.project.moveRegions([a, b], deltaTicks: 240, deltaTracks: 0)
        #expect(f.region(a).start == 1240)
        #expect(f.region(b).start == 740)
        #expect(f.region(c).start == 9000)
    }

    @Test func moveClampsTheGroupAtZero() {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        let b = f.addSound(at: 500)
        f.project.moveRegions([a, b], deltaTicks: -2000, deltaTracks: 0)
        #expect(f.region(b).start == 0)
        #expect(f.region(a).start == 500)
    }

    @Test func movesRegionsBetweenTracksOfTheSameKind() {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        let b = f.addSound(at: 500)
        f.project.moveRegions([a, b], deltaTicks: 100, deltaTracks: 1)
        #expect(f.project.location(of: a)?.track == 1)
        #expect(f.project.location(of: b)?.track == 3)
        #expect(f.region(a).start == 1100)
        #expect(f.region(b).start == 600)
        #expect(f.project.track(f.video1)?.regions.isEmpty == true)

        f.project.moveRegions([a, b], deltaTicks: 0, deltaTracks: -1)
        #expect(f.project.location(of: a)?.track == 0)
        #expect(f.project.location(of: b)?.track == 2)
    }

    @Test func trackMoveIsDroppedWhenAnyRegionWouldLandOnTheWrongKind() {
        var f = Fixture()
        let a = f.addClip(at: 1000, on: f.video2)
        let b = f.addSound(at: 500)
        // a would land on audio1.
        f.project.moveRegions([a, b], deltaTicks: 100, deltaTracks: 1)
        #expect(f.project.location(of: a)?.track == 1)
        #expect(f.project.location(of: b)?.track == 2)
        #expect(f.region(a).start == 1100)
        #expect(f.region(b).start == 600)
    }

    @Test func trackMoveIsDroppedWhenOutOfRange() {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        f.project.moveRegions([a], deltaTicks: 50, deltaTracks: -1)
        #expect(f.project.location(of: a)?.track == 0)
        #expect(f.region(a).start == 1050)
        let b = f.addSound(at: 0, on: f.audio2)
        f.project.moveRegions([b], deltaTicks: 50, deltaTracks: 1)
        #expect(f.project.location(of: b)?.track == 3)
        #expect(f.region(b).start == 50)
    }

    @Test func deletesMutesAndRenamesRegions() {
        var f = Fixture()
        let a = f.addClip(at: 0)
        let b = f.addSound(at: 0)
        let c = f.addSound(at: 4000)

        f.project.setRegionMuted([a, c], true)
        #expect(f.region(a).muted && f.region(c).muted && !f.region(b).muted)
        f.project.setRegionMuted([a], false)
        #expect(!f.region(a).muted)

        f.project.renameRegion(b, to: "Kick 2")
        #expect(f.region(b).name == "Kick 2")

        f.project.deleteRegions([a, c])
        #expect(f.project.region(a) == nil)
        #expect(f.project.region(c) == nil)
        #expect(f.project.region(b) != nil)
    }

    @Test func duplicatePlacesCopiesAfterTheLatestEnd() {
        var f = Fixture()
        let a = f.addClip(at: 1000)        // ends 8680
        let b = f.addSound(at: 1500)       // ends 3420
        let copies = f.project.duplicate([a, b])
        #expect(copies.count == 2)
        #expect(Set(copies).isDisjoint(with: [a, b]))

        let copyA = f.region(copies[0]), copyB = f.region(copies[1])
        #expect(copyA.start == 8680)
        #expect(copyB.start == 9180)
        #expect(f.project.location(of: copies[0])?.track == 0)
        #expect(f.project.location(of: copies[1])?.track == 2)
        #expect(copyA.length == 7680 && copyA.mediaID == f.clip && copyA.name == "street.mov")
        #expect(f.region(a).start == 1000)
        #expect(f.project.duplicate([]).isEmpty)
    }
}

@Suite struct ClipboardTests {
    @Test func copyRecordsTrackIndexAndOffsetFromTheEarliestStart() {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        let b = f.addSound(at: 1500)
        _ = f.addSound(at: 0)
        let clipboard = f.project.copyRegions([a, b])
        #expect(clipboard.items.count == 2)
        #expect(clipboard.items.map(\.trackIndex) == [0, 2])
        #expect(clipboard.items.map(\.offset) == [0, 500])
        #expect(clipboard.items.map(\.kind) == [.video, .audio])
        #expect(clipboard.items.map(\.region.id) == [a, b])
        #expect(f.project.copyRegions([]).isEmpty)
    }

    @Test func pasteReturnsRegionsToTheirOriginalTracks() {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        let b = f.addSound(at: 1500)
        f.project.trimStart(a, to: 1960)
        let clipboard = f.project.copyRegions([a, b])

        let pasted = f.project.paste(clipboard, at: 20_000)
        #expect(pasted.count == 2)
        #expect(Set(pasted).isDisjoint(with: [a, b]))
        // b (at 1500) is now the earliest; a starts 460 after it.
        let pastedA = f.region(pasted[0]), pastedB = f.region(pasted[1])
        #expect(pastedB.start == 20_000)
        #expect(pastedA.start == 20_460)
        #expect(f.project.location(of: pasted[0])?.track == 0)
        #expect(f.project.location(of: pasted[1])?.track == 2)
        #expect(pastedA.sourceOffset == f.region(a).sourceOffset)
        #expect(pastedA.length == f.region(a).length)
    }

    @Test func pasteOntoAChosenTopTrack() {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        let b = f.addSound(at: 1500)
        let clipboard = f.project.copyRegions([a, b])

        let pasted = f.project.paste(clipboard, at: 0, topTrackIndex: 1)
        #expect(pasted.count == 2)
        #expect(f.project.location(of: pasted[0])?.track == 1)
        #expect(f.project.location(of: pasted[1])?.track == 3)
        #expect(f.region(pasted[0]).start == 0)
        #expect(f.region(pasted[1]).start == 500)
    }

    @Test func pasteSkipsWrongKindAndMissingTracks() {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        let b = f.addSound(at: 1500)
        let clipboard = f.project.copyRegions([a, b])
        let before = f.project

        // a -> audio1 (wrong kind), b -> index 4 (missing).
        #expect(f.project.paste(clipboard, at: 0, topTrackIndex: 2).isEmpty)
        #expect(f.project == before)

        // With audio2 gone, a -> video2 still fits but b -> index 3 is missing.
        f.project.removeTrack(f.audio2)
        let pasted = f.project.paste(clipboard, at: 0, topTrackIndex: 1)
        #expect(pasted.count == 1)
        #expect(f.region(pasted[0]).mediaID == f.clip)
        #expect(f.project.location(of: pasted[0])?.track == 1)
    }

    @Test func clipboardSurvivesCoding() throws {
        var f = Fixture()
        let a = f.addClip(at: 1000)
        let clipboard = f.project.copyRegions([a])
        let decoded = try JSONDecoder().decode(Clipboard.self, from: JSONEncoder().encode(clipboard))
        #expect(decoded == clipboard)
    }
}

@Suite struct FadeTests {
    @Test func fadesAreClampedToTheRegion() {
        var f = Fixture()
        let a = f.addSound(at: 0)   // 1920 long
        f.project.setFadeIn(a, 500)
        #expect(f.region(a).fadeIn == 500)
        f.project.setFadeOut(a, 5000)
        #expect(f.region(a).fadeOut == 1420)
        f.project.setFadeIn(a, 5000)
        #expect(f.region(a).fadeIn == 500)
        f.project.setFadeOut(a, -10)
        #expect(f.region(a).fadeOut == 0)
        f.project.setFadeIn(a, 5000)
        #expect(f.region(a).fadeIn == 1920)
        f.project.setFadeIn(a, -1)
        #expect(f.region(a).fadeIn == 0)
    }

    @Test func trimmingShorterClampsFades() {
        var f = Fixture()
        let a = f.addSound(at: 0)
        f.project.setFadeIn(a, 900)
        f.project.setFadeOut(a, 900)
        f.project.trimEnd(a, to: 1000)
        #expect(f.region(a).fadeIn == 900)
        #expect(f.region(a).fadeOut == 100)
    }

    @Test func overlapBecomesACrossfade() {
        var f = Fixture()
        let a = f.addSound(at: 0)        // 0 ..< 1920
        let b = f.addSound(at: 1440)     // 1440 ..< 3360, overlap 480
        let c = f.addSound(at: 5000)     // alone
        f.project.setFadeIn(a, 100)
        f.project.setFadeOut(a, 200)     // shorter than the overlap
        f.project.setFadeOut(b, 300)
        f.project.setFadeIn(c, 50)
        f.project.setFadeOut(c, 60)

        let fades = f.project.track(f.audio1)!.resolvedFades()
        #expect(fades[a] == Fades(fadeIn: 100, fadeOut: 480))
        #expect(fades[b] == Fades(fadeIn: 480, fadeOut: 300))
        #expect(fades[c] == Fades(fadeIn: 50, fadeOut: 60))
        #expect(fades.count == 3)
        // The regions' own fades are untouched.
        #expect(f.region(a).fadeOut == 200)
        #expect(f.region(b).fadeIn == 0)
    }

    @Test func aLongerOwnFadeWinsOverTheCrossfade() {
        var f = Fixture()
        let a = f.addSound(at: 0)
        let b = f.addSound(at: 1440)
        f.project.setFadeOut(a, 900)
        f.project.setFadeIn(b, 700)
        let fades = f.project.track(f.audio1)!.resolvedFades()
        #expect(fades[a]?.fadeOut == 900)
        #expect(fades[b]?.fadeIn == 700)
    }

    @Test func aRegionOverlappedOnBothSidesCrossfadesAtBothEnds() {
        var f = Fixture()
        let a = f.addSound(at: 0)        // 0 ..< 1920
        let b = f.addSound(at: 1620)     // 1620 ..< 3540
        let c = f.addSound(at: 3040)     // 3040 ..< 4960
        let fades = f.project.track(f.audio1)!.resolvedFades()
        #expect(fades[a] == Fades(fadeIn: 0, fadeOut: 300))
        #expect(fades[b] == Fades(fadeIn: 300, fadeOut: 500))
        #expect(fades[c] == Fades(fadeIn: 500, fadeOut: 0))
    }

    @Test func mutedAndContainedRegionsCauseNoCrossfade() {
        var f = Fixture()
        let a = f.addClip(at: 0)                       // 0 ..< 7680
        let inside = f.addClip(at: 1000)
        f.project.trimEnd(inside, to: 3000)            // 1000 ..< 3000, wholly inside a
        let muted = f.addClip(at: 7000)                // overlaps a's tail
        f.project.setRegionMuted([muted], true)
        f.project.setFadeIn(inside, 10)

        let fades = f.project.track(f.video1)!.resolvedFades()
        #expect(fades[a] == Fades(fadeIn: 0, fadeOut: 0))
        #expect(fades[inside] == Fades(fadeIn: 10, fadeOut: 0))
        #expect(fades[muted] == Fades(fadeIn: 0, fadeOut: 0))

        f.project.setRegionMuted([muted], false)
        let unmuted = f.project.track(f.video1)!.resolvedFades()
        #expect(unmuted[a]?.fadeOut == 680)
        #expect(unmuted[muted]?.fadeIn == 680)
    }

    @Test func regionsOnDifferentTracksDoNotCrossfade() {
        var f = Fixture()
        let a = f.addSound(at: 0, on: f.audio1)
        let b = f.addSound(at: 1000, on: f.audio2)
        #expect(f.project.track(f.audio1)!.resolvedFades()[a] == Fades(fadeIn: 0, fadeOut: 0))
        #expect(f.project.track(f.audio2)!.resolvedFades()[b] == Fades(fadeIn: 0, fadeOut: 0))
    }
}
