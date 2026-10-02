import Foundation
import Testing

@testable import Model

@Suite struct SignatureTests {
    @Test func fourFourIsTheDefault() {
        let project = Project()
        #expect(project.signatureUnit == 4)
        #expect(project.beatTicks == ticksPerBeat)
        #expect(project.barTicks == 4 * ticksPerBeat)
    }

    @Test func sixEightHasEighthNoteBeatsAndThreeQuarterNoteBars() {
        var project = Project()
        project.setTimeSignature(beats: 6, unit: 8)
        #expect(project.beatTicks == ticksPerBeat / 2)
        #expect(project.barTicks == 3 * ticksPerBeat)
        #expect(project.gridTicks(.bar) == 3 * ticksPerBeat)
        #expect(project.gridTicks(.beat) == ticksPerBeat / 2)
        #expect(project.gridTicks(.half) == ticksPerBeat / 4)
    }

    @Test func snappingFollowsTheSignature() {
        var project = Project()
        project.setTimeSignature(beats: 7, unit: 8)
        let bar = 7 * ticksPerBeat / 2
        #expect(project.snap(bar + 100, to: .bar) == bar)
        #expect(project.snap(2 * bar - 100, to: .bar) == 2 * bar)
        #expect(project.snap(ticksPerBeat / 2 + 10, to: .beat) == ticksPerBeat / 2)
    }

    @Test func positionCountsBarsAndBeatsFromOne() {
        var project = Project()
        project.setTimeSignature(beats: 3, unit: 4)
        #expect(project.position(at: 0) == (1, 1, 0))
        #expect(project.position(at: 2 * ticksPerBeat + 5) == (1, 3, 5))
        #expect(project.position(at: 3 * ticksPerBeat) == (2, 1, 0))
        project.setTimeSignature(beats: 6, unit: 8)
        #expect(project.position(at: 5 * ticksPerBeat / 2) == (1, 6, 0))
        #expect(project.position(at: 3 * ticksPerBeat) == (2, 1, 0))
    }

    @Test func signatureValuesArePulledIntoRange() {
        var project = Project()
        project.setTimeSignature(beats: 0, unit: 5)
        #expect(project.beatsPerBar == 1 && project.signatureUnit == 4)
        project.setTimeSignature(beats: 99, unit: 16)
        #expect(project.beatsPerBar == 32 && project.signatureUnit == 16)
        #expect(project.gridTicks(.sixteenth) == 15)
    }

    @Test func changingTheSignatureMovesNothing() {
        var project = Project()
        let media = project.addMedia(Media(path: "/clips/a.mov", kind: .video, duration: flicksPerSecond * 2))
        let track = project.addTrack(kind: .video)
        let region = project.addRegion(mediaID: media, trackID: track, at: 1000)!
        let before = project.region(region)
        project.setTimeSignature(beats: 5, unit: 8)
        #expect(project.region(region) == before)
    }

    @Test func aFrameIsSixtyFourTicksAtThirtyFramesAndOneTwentyBeats() {
        let project = Project()
        #expect(project.frameTicks == 64)
    }
}
