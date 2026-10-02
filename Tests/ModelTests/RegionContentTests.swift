import Foundation
import Testing
import Model

@Suite struct SourceMappingTests {
    @Test func forwardRegionMapsLinearly() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        let region = f.region(id)
        #expect(f.project.sourceFlicks(of: region, at: 1920) == 0)
        #expect(f.project.sourceFlicks(of: region, at: 2880) == flicks(0.5))
        #expect(f.project.sourceFlicks(of: region, at: 9599) == flicks(4) - tickFlicks)
    }

    @Test func nilOutsideTheRegion() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        let region = f.region(id)
        #expect(f.project.sourceFlicks(of: region, at: 1919) == nil)
        #expect(f.project.sourceFlicks(of: region, at: 9600) == nil)
        #expect(f.project.sourceFlicks(of: region, at: -1) == nil)
    }

    @Test func reversedRegionRunsFromTheEndOfItsSpan() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        f.project.reverse([id])
        let region = f.region(id)
        #expect(f.project.sourceFlicks(of: region, at: 1920) == flicks(4))
        #expect(f.project.sourceFlicks(of: region, at: 2880) == flicks(3.5))
        #expect(f.project.sourceFlicks(of: region, at: 9599) == tickFlicks)
    }

    @Test func speedScalesSourceTime() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        f.project.stretch(id, toLength: 3840)
        let region = f.region(id)
        #expect(f.project.sourceFlicks(of: region, at: 2880) == flicks(1))
        #expect(f.project.sourceFlicks(of: region, at: 5759) == flicks(4) - 2 * tickFlicks)
    }

    @Test func loopedRegionRepeatsItsIteration() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 6720)
        var region = f.region(id)
        #expect(f.project.sourceFlicks(of: region, at: 0) == 0)
        #expect(f.project.sourceFlicks(of: region, at: 1920) == 0)
        #expect(f.project.sourceFlicks(of: region, at: 2400) == flicks(0.25))
        #expect(f.project.sourceFlicks(of: region, at: 6719) == 959 * tickFlicks)
        #expect(f.project.sourceFlicks(of: region, at: 6720) == nil)

        f.project.reverse([id])
        region = f.region(id)
        #expect(f.project.sourceFlicks(of: region, at: 1920) == flicks(1))
        #expect(f.project.sourceFlicks(of: region, at: 2400) == flicks(0.75))
    }
}

@Suite struct TrimTests {
    @Test func trimStartHidesTheBeginningWithoutMovingContent() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        let before = f.project
        f.project.trimStart(id, to: 2880)

        let region = f.region(id)
        #expect(region.start == 2880)
        #expect(region.length == 6720)
        #expect(region.contentLength == 6720)
        #expect(region.end == 9600)
        #expect(region.sourceOffset == flicks(0.5))
        #expect(drift(before, f.project, track: f.video1, over: 2880..<9600) == 0)
    }

    @Test func trimStartBackOutRevealsContentUpToTheSourceStart() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        let original = f.project
        f.project.trimStart(id, to: 2880)
        f.project.trimStart(id, to: 2400)
        #expect(f.region(id).start == 2400)
        #expect(f.region(id).sourceOffset == flicks(0.25))

        // Dragging past the start of the source stops where the source begins.
        f.project.trimStart(id, to: 0)
        #expect(f.project == original)
    }

    @Test func trimStartNeverGoesBeforeTickZero() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        f.project.trimStart(id, to: 2880)                           // 960 ticks hidden
        f.project.moveRegions([id], deltaTicks: -2380, deltaTracks: 0)   // start 500
        f.project.trimStart(id, to: -100)
        let region = f.region(id)
        #expect(region.start == 0)
        #expect(region.length == 7220)
        #expect(region.sourceOffset == 460 * tickFlicks)
    }

    @Test func trimStartKeepsAtLeastOneTick() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        f.project.trimStart(id, to: 50_000)
        let region = f.region(id)
        #expect(region.start == 9599)
        #expect(region.length == 1)
        #expect(region.contentLength == 1)
        #expect(region.sourceOffset == 7679 * tickFlicks)
    }

    @Test func trimEndHidesAndRevealsTheEnd() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        let original = f.project
        f.project.trimEnd(id, to: 5000)
        var region = f.region(id)
        #expect(region.start == 1920)
        #expect(region.length == 3080)
        #expect(region.contentLength == 3080)
        #expect(region.sourceOffset == 0)
        #expect(!region.isLooped)

        f.project.trimEnd(id, to: 7000)
        region = f.region(id)
        #expect(region.length == 5080 && region.contentLength == 5080)

        // Dragging past the end of the source stops where the source ends.
        f.project.trimEnd(id, to: 100_000)
        #expect(f.project == original)
    }

    @Test func trimEndKeepsAtLeastOneTick() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        f.project.trimEnd(id, to: 0)
        #expect(f.region(id).start == 1920)
        #expect(f.region(id).length == 1)
        #expect(f.region(id).contentLength == 1)
    }

    @Test func trimsRespectTheMediaBoundsOfAStretchedRegion() {
        var f = Fixture()
        let id = f.addClip(at: 0)
        f.project.stretch(id, toLength: 3840)          // speed 2
        f.project.trimStart(id, to: 960)
        #expect(f.region(id).sourceOffset == flicks(1))
        f.project.trimEnd(id, to: 2000)
        #expect(f.region(id).length == 1040)

        f.project.trimEnd(id, to: 99_999)
        #expect(f.region(id).end == 3840)
        f.project.moveRegions([id], deltaTicks: 5000, deltaTracks: 0)
        f.project.trimStart(id, to: 0)
        #expect(f.region(id).start == 5000)
        #expect(f.region(id).length == 3840)
        #expect(f.region(id).sourceOffset == 0)
    }

    @Test func reversedTrimStartHidesTheEndOfTheSource() {
        var f = Fixture()
        let id = f.addClip(at: 10_000)
        f.project.reverse([id])
        let before = f.project
        f.project.trimStart(id, to: 10_960)

        var region = f.region(id)
        #expect(region.start == 10_960)
        #expect(region.length == 6720 && region.contentLength == 6720)
        // The span is now 0 s ... 3.5 s: its start is untouched, its end moved in.
        #expect(region.sourceOffset == 0)
        #expect(f.project.sourceFlicks(of: region, at: 10_960) == flicks(3.5))
        #expect(drift(before, f.project, track: f.video1, over: 10_960..<17_680) == 0)

        // Back out: clamped by the end of the source, not by tick 0.
        f.project.trimStart(id, to: 0)
        region = f.region(id)
        #expect(f.project == before)
        #expect(f.project.sourceFlicks(of: region, at: 10_000) == flicks(4))
    }

    @Test func reversedTrimEndHidesTheStartOfTheSource() {
        var f = Fixture()
        let id = f.addClip(at: 10_000)
        f.project.reverse([id])
        let before = f.project
        f.project.trimEnd(id, to: 16_720)

        var region = f.region(id)
        #expect(region.start == 10_000)
        #expect(region.length == 6720 && region.contentLength == 6720)
        // The span is now 0.5 s ... 4 s.
        #expect(region.sourceOffset == flicks(0.5))
        #expect(f.project.sourceFlicks(of: region, at: 10_000) == flicks(4))
        #expect(f.project.sourceFlicks(of: region, at: 16_719) == flicks(0.5) + tickFlicks)
        #expect(drift(before, f.project, track: f.video1, over: 10_000..<16_720) == 0)

        // Back out: clamped by the start of the source.
        f.project.trimEnd(id, to: 90_000)
        region = f.region(id)
        #expect(f.project == before)
        #expect(region.sourceOffset == 0)
    }

    @Test func reversedTrimsOfAnInnerSpanStayInsideTheMedia() {
        var f = Fixture()
        let id = f.addClip(at: 10_000)
        f.project.reverse([id])
        f.project.trimStart(id, to: 11_000)     // hides 1000 ticks at the source's end
        f.project.trimEnd(id, to: 17_000)       // hides 680 ticks at the source's start
        var region = f.region(id)
        #expect(region.sourceOffset == 680 * tickFlicks)
        #expect(region.contentLength == 6000)

        f.project.trimEnd(id, to: 17_300)
        region = f.region(id)
        #expect(region.sourceOffset == 380 * tickFlicks)
        #expect(region.contentLength == 6300)

        f.project.trimStart(id, to: 10_400)
        region = f.region(id)
        #expect(region.sourceOffset == 380 * tickFlicks)
        #expect(region.contentLength == 6900)
        #expect(f.project.sourceFlicks(of: region, at: 10_400) == (380 + 6900) * tickFlicks)
    }

    @Test func aRegionWhoseLengthRoundedUpIsNotShortenedByExtendingIt() {
        var f = Fixture()
        f.project.setTempo(97.3)                 // 1 s = 1556.8 ticks
        let id = f.addSound(at: 0)
        #expect(f.region(id).length == 1557)
        f.project.trimEnd(id, to: 5000)
        #expect(f.region(id).length == 1557)
        f.project.trimEnd(id, to: 1000)
        f.project.trimEnd(id, to: 5000)
        #expect(f.region(id).length == 1556)
    }

    @Test func aRegionWithMissingMediaCanBeTrimmedInButNotOut() {
        var f = Fixture()
        let orphan = Region(mediaID: UUID(), name: "gone", start: 1000, length: 2000)
        f.project.tracks[0].regions.append(orphan)
        f.project.trimEnd(orphan.id, to: 2500)
        f.project.trimStart(orphan.id, to: 1200)
        #expect(f.region(orphan.id).start == 1200)
        #expect(f.region(orphan.id).length == 1300)
        f.project.trimEnd(orphan.id, to: 9000)
        f.project.trimStart(orphan.id, to: 0)
        #expect(f.region(orphan.id).start == 1200)
        #expect(f.region(orphan.id).length == 1300)
    }

    @Test func unknownRegionIsIgnored() {
        var f = Fixture()
        _ = f.addClip(at: 0)
        let before = f.project
        f.project.trimStart(UUID(), to: 100)
        f.project.trimEnd(UUID(), to: 100)
        f.project.setLoopEnd(UUID(), to: 100)
        f.project.stretch(UUID(), toLength: 100)
        #expect(f.project == before)
    }
}

@Suite struct LoopTests {
    @Test func draggingTheLoopHandleRepeatsTheRegion() {
        var f = Fixture()
        let id = f.addSound(at: 960)
        f.project.setLoopEnd(id, to: 960 + 6720)
        let region = f.region(id)
        #expect(region.isLooped)
        #expect(region.length == 6720)
        #expect(region.contentLength == 1920)
        #expect(region.sourceOffset == 0)
        #expect(region.start == 960)
    }

    @Test func draggingBackToOneIterationUnloops() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        let original = f.project
        f.project.setLoopEnd(id, to: 6720)
        f.project.setLoopEnd(id, to: 1920)
        #expect(!f.region(id).isLooped)
        #expect(f.project == original)
    }

    @Test func loopEndInsideTheFirstIterationTrimsWithoutLosingContent() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 6720)
        f.project.setLoopEnd(id, to: 500)
        var region = f.region(id)
        #expect(!region.isLooped)
        #expect(region.length == 500 && region.contentLength == 500)
        #expect(region.sourceOffset == 0)

        // The hidden content is still there to be revealed.
        f.project.trimEnd(id, to: 5000)
        region = f.region(id)
        #expect(region.length == 1920 && region.contentLength == 1920)
    }

    @Test func loopEndInsideTheFirstIterationOfAReversedRegion() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.reverse([id])
        f.project.setLoopEnd(id, to: 6720)
        let before = f.project
        f.project.setLoopEnd(id, to: 480)
        let region = f.region(id)
        #expect(region.length == 480 && region.contentLength == 480)
        #expect(region.sourceOffset == flicks(0.75))
        #expect(drift(before, f.project, track: f.audio1, over: 0..<480) == 0)
    }

    @Test func loopEndNeverShorterThanOneTick() {
        var f = Fixture()
        let id = f.addSound(at: 960)
        f.project.setLoopEnd(id, to: 0)
        #expect(f.region(id).length == 1)
        #expect(f.region(id).contentLength == 1)
        #expect(f.region(id).start == 960)
    }

    @Test func trimEndOnALoopedRegionChangesOnlyTheRepetitions() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 6720)
        f.project.trimEnd(id, to: 4000)
        var region = f.region(id)
        #expect(region.length == 4000 && region.contentLength == 1920 && region.sourceOffset == 0)

        // No media bound: it just loops for longer.
        f.project.trimEnd(id, to: 100_000)
        region = f.region(id)
        #expect(region.length == 100_000 && region.contentLength == 1920)

        // Inside the first iteration it becomes a plain, trimmed region.
        f.project.trimEnd(id, to: 1000)
        region = f.region(id)
        #expect(!region.isLooped)
        #expect(region.length == 1000 && region.contentLength == 1000)
    }

    @Test func trimStartOnALoopedRegionTrimsTheIterationAndKeepsTheEnd() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 6720)
        f.project.trimStart(id, to: 480)
        var region = f.region(id)
        #expect(region.start == 480)
        #expect(region.end == 6720)
        #expect(region.length == 6240)
        #expect(region.contentLength == 1440)
        #expect(region.sourceOffset == flicks(0.25))
        #expect(region.isLooped)

        // Cannot trim away the whole iteration.
        f.project.trimStart(id, to: 6000)
        region = f.region(id)
        #expect(region.contentLength == 1)
        #expect(region.start == 480 + 1439)
        #expect(region.end == 6720)

        // And back out to the start of the source.
        f.project.trimStart(id, to: 0)
        region = f.region(id)
        #expect(region.start == 0 && region.contentLength == 1920 && region.length == 6720)
        #expect(region.sourceOffset == 0)
    }

    @Test func plainTrimEndDoesNotLoop() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.trimEnd(id, to: 6720)
        #expect(!f.region(id).isLooped)
        #expect(f.region(id).length == 1920)
    }
}

@Suite struct StretchAndReverseTests {
    @Test func stretchingShorterSpeedsUp() {
        var f = Fixture()
        let id = f.addClip(at: 1000)
        f.project.stretch(id, toLength: 3840)
        let region = f.region(id)
        #expect(region.start == 1000)
        #expect(region.length == 3840 && region.contentLength == 3840)
        #expect(region.speed == 2)
        #expect(region.sourceOffset == 0)
        #expect(f.project.seconds(region.contentLength) * region.speed == 4)
    }

    @Test func stretchingLongerSlowsDown() {
        var f = Fixture()
        let id = f.addClip(at: 1000)
        f.project.stretch(id, toLength: 15_360)
        #expect(f.region(id).speed == 0.5)
        #expect(f.region(id).end == 16_360)
    }

    @Test func stretchKeepsTheSourceSpanOfATrimmedRegion() {
        var f = Fixture()
        let id = f.addClip(at: 0)
        f.project.trimStart(id, to: 960)       // span 0.5 s ... 4 s
        f.project.stretch(id, toLength: 3360)
        let region = f.region(id)
        #expect(region.speed == 2)
        #expect(region.sourceOffset == flicks(0.5))
        #expect(f.project.seconds(region.contentLength) * region.speed == 3.5)
        #expect(f.project.sourceFlicks(of: region, at: 960 + 1680) == flicks(0.5 + 1.75))
    }

    @Test func anchoringTheEndMovesTheStart() {
        var f = Fixture()
        let id = f.addClip(at: 1000)
        f.project.stretch(id, toLength: 3840, anchorEnd: true)
        let region = f.region(id)
        #expect(region.end == 8680)
        #expect(region.start == 4840)
        #expect(region.speed == 2)
    }

    @Test func anchoredStretchStopsAtTickZero() {
        var f = Fixture()
        let id = f.addClip(at: 1000)
        f.project.stretch(id, toLength: 20_000, anchorEnd: true)
        let region = f.region(id)
        #expect(region.start == 0)
        #expect(region.end == 8680)
        #expect(region.length == 8680)
        #expect(region.speed == 7680.0 / 8680.0)
    }

    @Test func stretchKeepsAtLeastOneTickAndClampsFades() {
        var f = Fixture()
        let id = f.addClip(at: 1000)
        f.project.setFadeIn(id, 3000)
        f.project.setFadeOut(id, 3000)
        f.project.stretch(id, toLength: 4000)
        #expect(f.region(id).fadeIn == 3000)
        #expect(f.region(id).fadeOut == 1000)

        f.project.stretch(id, toLength: 0)
        #expect(f.region(id).length == 1)
        #expect(abs(f.region(id).speed - 7680) < 1e-6)
        #expect(f.region(id).fadeIn + f.region(id).fadeOut <= 1)
    }

    @Test func stretchingALoopedRegionKeepsItsRepetitions() {
        var f = Fixture()
        let id = f.addSound(at: 960)
        f.project.setLoopEnd(id, to: 960 + 5760)      // three repetitions
        f.project.stretch(id, toLength: 2880)
        let region = f.region(id)
        #expect(region.length == 2880)
        #expect(region.contentLength == 960)
        #expect(region.speed == 2)
        #expect(region.isLooped)
        #expect(f.project.sourceFlicks(of: region, at: 960 + 960 + 480) == flicks(0.5))
    }

    @Test func reverseTogglesAndKeepsTheSourceSpan() {
        var f = Fixture()
        let a = f.addClip(at: 0)
        let b = f.addSound(at: 0)
        f.project.trimStart(a, to: 960)
        let before = f.region(a)

        f.project.reverse([a])
        var after = f.region(a)
        after.reversed.toggle()
        #expect(f.region(a).reversed)
        #expect(after == before)
        #expect(!f.region(b).reversed)
        #expect(f.project.sourceFlicks(of: f.region(a), at: 960) == flicks(4))
        #expect(f.project.sourceFlicks(of: f.region(a), at: 7679) == flicks(0.5) + tickFlicks)

        f.project.reverse([a, b])
        #expect(f.region(a) == before)
        #expect(f.region(b).reversed)
    }
}
