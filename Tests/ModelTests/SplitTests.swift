import Foundation
import Testing
import Model

@Suite struct SplitTests {
    @Test func splitsAPlainRegionInTwo() {
        var f = Fixture()
        let id = f.addClip(at: 1920)
        f.project.setFadeIn(id, 100)
        f.project.setFadeOut(id, 200)
        let before = f.project

        let new = f.project.split([id], at: 4800)
        #expect(new.count == 1)
        let left = f.region(id), right = f.region(new[0])
        #expect(left.start == 1920 && left.length == 2880 && left.contentLength == 2880)
        #expect(left.sourceOffset == 0)
        #expect(left.fadeIn == 100 && left.fadeOut == 0)
        #expect(right.start == 4800 && right.length == 4800 && right.contentLength == 4800)
        #expect(right.sourceOffset == flicks(1.5))
        #expect(right.fadeIn == 0 && right.fadeOut == 200)
        #expect(right.name == left.name && right.mediaID == left.mediaID)
        #expect(f.project.location(of: new[0])?.track == 0)
        #expect(f.project.track(f.video1)?.regions.count == 2)
        #expect(drift(before, f.project, track: f.video1, over: 0..<12_000) == 0)
    }

    @Test func onlyRegionsStrictlyContainingTheTickAreSplit() {
        var f = Fixture()
        let a = f.addClip(at: 1920)             // 1920 ..< 9600
        let b = f.addSound(at: 1920)            // 1920 ..< 3840
        let c = f.addSound(at: 3000, on: f.audio2)
        let before = f.project

        #expect(f.project.split([a, b, c], at: 1920).isEmpty)
        #expect(f.project.split([a], at: 9600).isEmpty)
        #expect(f.project.split([a, b, c], at: 100).isEmpty)
        #expect(f.project.split([a, b, c], at: 50_000).isEmpty)
        #expect(f.project.split([], at: 3000).isEmpty)
        #expect(f.project == before)

        // c contains the tick but is not selected; b ends exactly on it.
        let new = f.project.split([a, b], at: 3840)
        #expect(new.count == 1)
        #expect(f.region(a).end == 3840)
        #expect(f.region(b) == before.region(b))
        #expect(f.region(c) == before.region(c))
    }

    @Test func splitClampsFadesToThePieces() {
        var f = Fixture()
        let id = f.addClip(at: 0)
        f.project.setFadeIn(id, 5000)
        f.project.setFadeOut(id, 2680)
        let new = f.project.split([id], at: 2880)
        #expect(f.region(id).fadeIn == 2880)
        #expect(f.region(id).fadeOut == 0)
        #expect(f.region(new[0]).fadeIn == 0)
        #expect(f.region(new[0]).fadeOut == 2680)
    }

    @Test func splitsAReversedRegion() {
        var f = Fixture()
        let id = f.addClip(at: 0)
        f.project.reverse([id])
        let before = f.project

        let new = f.project.split([id], at: 1920)
        let left = f.region(id), right = f.region(new[0])
        // The left piece shows the last second of the source, the right piece the first three.
        #expect(left.sourceOffset == flicks(3) && left.contentLength == 1920 && left.reversed)
        #expect(right.sourceOffset == 0 && right.contentLength == 5760 && right.reversed)
        #expect(f.project.sourceFlicks(of: left, at: 0) == flicks(4))
        #expect(f.project.sourceFlicks(of: right, at: 1920) == flicks(3))
        #expect(drift(before, f.project, track: f.video1, over: 0..<7680) == 0)
    }

    @Test func splittingALoopedRegionMidIterationYieldsThreePieces() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 6720)       // 3.5 iterations of 1920
        f.project.setFadeIn(id, 50)
        f.project.setFadeOut(id, 70)
        let before = f.project

        let new = f.project.split([id], at: 2400)
        #expect(new.count == 2)
        let left = f.region(id), rest = f.region(new[0]), tail = f.region(new[1])

        #expect(left.start == 0 && left.length == 2400 && left.contentLength == 1920)
        #expect(left.isLooped && left.sourceOffset == 0)

        #expect(rest.start == 2400 && rest.length == 1440 && rest.contentLength == 1440)
        #expect(!rest.isLooped && rest.sourceOffset == flicks(0.25))

        #expect(tail.start == 3840 && tail.length == 2880 && tail.contentLength == 1920)
        #expect(tail.isLooped && tail.sourceOffset == 0)

        #expect(left.fadeIn == 50 && left.fadeOut == 0)
        #expect(rest.fadeIn == 0 && rest.fadeOut == 0)
        #expect(tail.fadeIn == 0 && tail.fadeOut == 70)
        #expect(f.regions(on: f.audio1).map(\.id) == [id, new[0], new[1]])
        #expect(drift(before, f.project, track: f.audio1, over: 0..<7000) == 0)
    }

    @Test func splittingALoopedRegionOnAnIterationBoundaryYieldsTwoLoops() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 6720)
        let before = f.project

        let new = f.project.split([id], at: 3840)
        #expect(new.count == 1)
        let left = f.region(id), right = f.region(new[0])
        #expect(left.length == 3840 && left.contentLength == 1920 && left.isLooped)
        #expect(right.start == 3840 && right.length == 2880 && right.contentLength == 1920 && right.isLooped)
        #expect(right.sourceOffset == 0)
        #expect(drift(before, f.project, track: f.audio1, over: 0..<7000) == 0)
    }

    @Test func splittingInTheLastPartialIterationLeavesNoThirdPiece() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 2400)       // 1.25 iterations
        let before = f.project

        let new = f.project.split([id], at: 2100)
        #expect(new.count == 1)
        let left = f.region(id), rest = f.region(new[0])
        #expect(left.length == 2100 && left.contentLength == 1920 && left.isLooped)
        #expect(rest.start == 2100 && rest.length == 300 && rest.contentLength == 300 && !rest.isLooped)
        #expect(rest.sourceOffset == 180 * tickFlicks)
        #expect(drift(before, f.project, track: f.audio1, over: 0..<2500) == 0)
    }

    @Test func splittingAfterTheFirstIterationLeavesPlainPieces() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 2400)
        let before = f.project

        let new = f.project.split([id], at: 1920)
        #expect(new.count == 1)
        let left = f.region(id), right = f.region(new[0])
        #expect(left.length == 1920 && left.contentLength == 1920 && !left.isLooped)
        #expect(right.start == 1920 && right.length == 480 && right.contentLength == 480 && !right.isLooped)
        #expect(right.sourceOffset == 0)
        #expect(drift(before, f.project, track: f.audio1, over: 0..<2500) == 0)
    }

    /// Every combination of tempo, stretch, reverse and loop: after any split, every tick
    /// shows the same source time as before (to within a few flicks of rounding).
    @Test(arguments: SplitCase.all)
    func splitNeverChangesWhatPlays(_ splitCase: SplitCase) {
        let (tempo, stretched, reversed, looped) =
            (splitCase.tempo, splitCase.stretched, splitCase.reversed, splitCase.looped)
        var f = Fixture()
        f.project.setTempo(tempo)
        let id = f.addSound(at: 300)
        f.project.trimStart(id, to: 511)
        f.project.trimEnd(id, to: f.region(id).end - 97)
        if stretched { f.project.stretch(id, toLength: f.region(id).length * 3 / 5 + 1) }
        if reversed { f.project.reverse([id]) }
        if looped { f.project.setLoopEnd(id, to: 511 + f.region(id).contentLength * 10 / 3) }
        let base = f.project
        let region = f.region(id)
        let content = region.contentLength
        let window = (region.start - 5)..<(region.end + 5)
        let exact = tempo == 120 && !stretched
        let tolerance: Flicks = exact ? 0 : 4

        var ticks = [region.start + 1, region.start + content / 3, region.end - 1]
        if looped {
            ticks += [region.start + content, region.start + content + 7,
                      region.start + 2 * content, region.start + 3 * content + 5]
        }
        for tick in ticks {
            var project = base
            let new = project.split([id], at: tick)
            #expect(!new.isEmpty)
            #expect(drift(base, project, track: f.audio1, over: window) <= tolerance)
            #expect(project.track(f.audio1)!.regions.allSatisfy(isWellFormed))
        }

        // All the cuts together.
        var project = base
        for tick in ticks.sorted() {
            project.split(Set(project.track(f.audio1)!.regions.map(\.id)), at: tick)
        }
        #expect(project.track(f.audio1)!.regions.count > ticks.count)
        #expect(drift(base, project, track: f.audio1, over: window) <= tolerance * 2)
        #expect(project.track(f.audio1)!.regions.allSatisfy(isWellFormed))
        #expect(project.lengthTicks == base.lengthTicks)
    }

    private func isWellFormed(_ region: Region) -> Bool {
        region.start >= 0 && region.contentLength >= 1 && region.length >= region.contentLength
            && region.sourceOffset >= 0 && region.fadeIn >= 0 && region.fadeOut >= 0
            && region.fadeIn + region.fadeOut <= region.length
    }
}

struct SplitCase: Sendable, CustomTestStringConvertible {
    var tempo: Double
    var stretched: Bool
    var reversed: Bool
    var looped: Bool

    var testDescription: String {
        "\(tempo) bpm" + (stretched ? ", stretched" : "") + (reversed ? ", reversed" : "")
            + (looped ? ", looped" : "")
    }

    static let all: [SplitCase] = [120.0, 97.3].flatMap { tempo in
        [false, true].flatMap { stretched in
            [false, true].flatMap { reversed in
                [false, true].map { looped in
                    SplitCase(tempo: tempo, stretched: stretched, reversed: reversed, looped: looped)
                }
            }
        }
    }
}

@Suite struct MarqueeTests {
    @Test func splitRangeCutsAtBothEndsAndReturnsOnlyTheInsidePieces() {
        var f = Fixture()
        let a = f.addClip(at: 0, on: f.video1)          // 0 ..< 7680: cut twice
        let b = f.addClip(at: 3840, on: f.video2)       // 3840 ..< 11520: cut once
        let c = f.addSound(at: 2000, on: f.audio1)      // 2000 ..< 3920: wholly inside
        let d = f.addSound(at: 6000, on: f.audio1)      // outside
        let e = f.addSound(at: 2000, on: f.audio2)      // track not in the marquee
        let before = f.project

        let inside = f.project.splitRange(1920..<5760, trackIDs: [f.video1, f.video2, f.audio1])

        #expect(inside.count == 3)
        #expect(inside.contains(c))
        let pieces = inside.map(f.region)
        #expect(pieces.allSatisfy { $0.start >= 1920 && $0.end <= 5760 })
        #expect(f.regions(on: f.video1).map(\.start) == [0, 1920, 5760])
        #expect(f.regions(on: f.video1).map(\.end) == [1920, 5760, 7680])
        #expect(f.regions(on: f.video2).map(\.start) == [3840, 5760])
        #expect(inside.contains(f.regions(on: f.video1)[1].id))
        #expect(inside.contains(f.regions(on: f.video2)[0].id))
        #expect(f.region(a).end == 1920)
        #expect(f.region(b).end == 5760)
        #expect(f.region(d) == before.region(d))
        #expect(f.region(e) == before.region(e))
        #expect(f.project.track(f.audio1)?.regions.count == 2)
        for track in [f.video1, f.video2, f.audio1, f.audio2] {
            #expect(drift(before, f.project, track: track, over: 0..<12_000) == 0)
        }
    }

    @Test func splitRangeThroughALoopedRegion() {
        var f = Fixture()
        let id = f.addSound(at: 0)
        f.project.setLoopEnd(id, to: 6720)
        let before = f.project

        let inside = f.project.splitRange(2400..<4000, trackIDs: [f.audio1])
        let regions = f.regions(on: f.audio1)
        #expect(regions.map(\.start) == [0, 2400, 3840, 4000, 5760])
        #expect(regions.map(\.end) == [2400, 3840, 4000, 5760, 6720])
        #expect(inside == Set(regions[1...2].map(\.id)))
        #expect(drift(before, f.project, track: f.audio1, over: 0..<7000) == 0)
    }

    @Test func emptyRangeOrNoTracksChangesNothing() {
        var f = Fixture()
        _ = f.addClip(at: 0)
        let before = f.project
        #expect(f.project.splitRange(1000..<1000, trackIDs: [f.video1]).isEmpty)
        #expect(f.project.splitRange(1000..<2000, trackIDs: []).isEmpty)
        #expect(f.project.splitRange(1000..<2000, trackIDs: [f.video2]).isEmpty)
        #expect(f.project == before)
    }

    @Test func deleteRangeRemovesOnlyWhatIsInside() {
        var f = Fixture()
        let a = f.addClip(at: 0, on: f.video1)
        let b = f.addClip(at: 3840, on: f.video2)
        let c = f.addSound(at: 2000, on: f.audio1)
        let e = f.addSound(at: 2000, on: f.audio2)
        let before = f.project

        f.project.deleteRange(1920..<5760, trackIDs: [f.video1, f.video2, f.audio1])

        let top = f.regions(on: f.video1)
        #expect(top.map(\.start) == [0, 5760])
        #expect(top.map(\.end) == [1920, 7680])
        #expect(top[0].id == a)
        #expect(top[1].sourceOffset == flicks(3))
        #expect(f.regions(on: f.video2).map(\.start) == [5760])
        #expect(f.regions(on: f.video2).map(\.end) == [11_520])
        #expect(f.project.region(b) == nil)     // b's left piece kept the id and was inside
        #expect(f.project.region(c) == nil)
        #expect(f.region(e) == before.region(e))
        // Outside the range nothing changed.
        #expect(drift(before, f.project, track: f.video1, over: 0..<1920) == 0)
        #expect(drift(before, f.project, track: f.video1, over: 5760..<8000) == 0)
        #expect(drift(before, f.project, track: f.video2, over: 5760..<12_000) == 0)
        #expect(shown(f.project, track: f.video1, at: 3000) == nil)
    }
}
