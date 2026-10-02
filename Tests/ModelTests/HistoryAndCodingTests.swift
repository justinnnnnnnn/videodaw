import Foundation
import Testing
import Model

@Suite struct HistoryTests {
    @Test func startsWithNothingToUndo() {
        var history = History(Fixture().project)
        #expect(!history.canUndo && !history.canRedo)
        #expect(history.undo() == false)
        #expect(history.redo() == false)
        #expect(History().project == Project())
    }

    @Test func undoAndRedoStepThroughEdits() {
        let f = Fixture()
        var history = History(f.project)
        let empty = history.project

        let region = history.perform { $0.addRegion(mediaID: f.clip, trackID: f.video1, at: 0) }!
        let added = history.project
        history.perform { $0.moveRegions([region], deltaTicks: 960, deltaTracks: 0) }
        let moved = history.project
        #expect(moved.region(region)?.start == 960)
        #expect(history.canUndo && !history.canRedo)

        #expect(history.undo() == true)
        #expect(history.project == added)
        #expect(history.canRedo)
        #expect(history.undo() == true)
        #expect(history.project == empty)
        #expect(!history.canUndo)
        #expect(history.undo() == false)

        #expect(history.redo() == true)
        #expect(history.project == added)
        #expect(history.redo() == true)
        #expect(history.project == moved)
        #expect(!history.canRedo)
        #expect(history.redo() == false)
    }

    @Test func performReturnsTheEditsResult() {
        let f = Fixture()
        var history = History(f.project)
        let region = history.perform { $0.addRegion(mediaID: f.clip, trackID: f.video1, at: 0) }!
        let pieces = history.perform { $0.split([region], at: 1000) }
        #expect(pieces.count == 1)
        #expect(history.project.region(pieces[0])?.start == 1000)
    }

    @Test func anEditThatChangesNothingRecordsNothing() {
        let f = Fixture()
        var history = History(f.project)
        history.perform { $0.renameTrack(f.video1, to: "Main") }
        history.undo()
        #expect(history.canRedo && !history.canUndo)

        history.perform { $0.renameTrack(f.video1, to: $0.track(f.video1)!.name) }
        history.perform { $0.deleteRegions([UUID()]) }
        #expect(!history.canUndo)
        #expect(history.canRedo)
    }

    @Test func aNewEditClearsRedo() {
        let f = Fixture()
        var history = History(f.project)
        history.perform { $0.renameTrack(f.video1, to: "A") }
        history.perform { $0.renameTrack(f.video1, to: "B") }
        history.undo()
        #expect(history.canRedo)
        history.perform { $0.renameTrack(f.video1, to: "C") }
        #expect(!history.canRedo)
        history.undo()
        #expect(history.project.track(f.video1)?.name == "A")
    }

    @Test func coalescedEditsShareOneUndoStep() {
        var f = Fixture()
        let region = f.addClip(at: 0)
        var history = History(f.project)
        let start = history.project

        for step in 1...20 {
            history.performCoalescing(key: "drag") {
                $0.moveRegions([region], deltaTicks: 10, deltaTracks: 0)
            }
            #expect(history.project.region(region)?.start == Ticks(step * 10))
        }
        history.endCoalescing()
        let dragged = history.project

        #expect(history.undo() == true)
        #expect(history.project == start)
        #expect(!history.canUndo)
        #expect(history.redo() == true)
        #expect(history.project == dragged)
    }

    @Test func endingAGroupStartsANewUndoStep() {
        var f = Fixture()
        let region = f.addClip(at: 0)
        var history = History(f.project)

        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: 100, deltaTracks: 0) }
        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: 100, deltaTracks: 0) }
        history.endCoalescing()
        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: 100, deltaTracks: 0) }
        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: 100, deltaTracks: 0) }

        history.undo()
        #expect(history.project.region(region)?.start == 200)
        history.undo()
        #expect(history.project.region(region)?.start == 0)
        #expect(!history.canUndo)
    }

    @Test func aDifferentKeyOrAPlainPerformEndsTheGroup() {
        var f = Fixture()
        let region = f.addClip(at: 0)
        var history = History(f.project)

        history.performCoalescing(key: "move") { $0.moveRegions([region], deltaTicks: 100, deltaTracks: 0) }
        history.performCoalescing(key: "fade") { $0.setFadeIn(region, 50) }
        history.performCoalescing(key: "fade") { $0.setFadeIn(region, 80) }
        history.perform { $0.renameRegion(region, to: "x") }
        history.performCoalescing(key: "fade") { $0.setFadeIn(region, 120) }

        history.undo()
        #expect(history.project.region(region)?.fadeIn == 80)
        #expect(history.project.region(region)?.name == "x")
        history.undo()
        #expect(history.project.region(region)?.name == "street.mov")
        history.undo()
        #expect(history.project.region(region)?.fadeIn == 0)
        #expect(history.project.region(region)?.start == 100)
        history.undo()
        #expect(history.project.region(region)?.start == 0)
        #expect(!history.canUndo)
    }

    @Test func undoInsideAGroupClosesIt() {
        var f = Fixture()
        let region = f.addClip(at: 0)
        var history = History(f.project)
        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: 100, deltaTracks: 0) }
        history.undo()
        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: 300, deltaTracks: 0) }
        #expect(history.canUndo && !history.canRedo)
        history.undo()
        #expect(history.project.region(region)?.start == 0)
    }

    @Test func aDragThatReturnsToWhereItBeganLeavesNoUndoStep() {
        var f = Fixture()
        let region = f.addClip(at: 500)
        var history = History(f.project)
        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: 100, deltaTracks: 0) }
        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: -100, deltaTracks: 0) }
        history.endCoalescing()
        #expect(!history.canUndo)

        // A coalescing edit that changes nothing does not open a step either.
        history.performCoalescing(key: "drag") { $0.moveRegions([region], deltaTicks: 0, deltaTracks: 0) }
        history.endCoalescing()
        #expect(!history.canUndo)
    }

    @Test func theUndoStackIsCapped() {
        var history = History(Project())
        for i in 0..<(History.limit + 100) {
            history.perform { $0.name = "Project \(i)" }
        }
        var undone = 0
        while history.undo() { undone += 1 }
        #expect(undone == History.limit)
        #expect(history.project.name == "Project 99")
    }
}

@Suite struct CodingTests {
    @Test func aPopulatedProjectSurvivesJSON() throws {
        var f = Fixture()
        f.project.name = "Round trip"
        f.project.setTempo(97.3)
        f.project.beatsPerBar = 3
        f.project.cycleOn = true
        f.project.cycleStart = 960
        f.project.cycleEnd = 7680

        let clip = f.addClip(at: 1000)
        f.project.trimStart(clip, to: 1300)
        f.project.stretch(clip, toLength: 4000)
        f.project.reverse([clip])
        f.project.setFadeIn(clip, 120)
        f.project.setFadeOut(clip, 240)
        f.project.split([clip], at: 2500)
        let loop = f.addSound(at: 0)
        f.project.setLoopEnd(loop, to: 9000)
        f.project.setRegionMuted([loop], true)
        f.project.renameRegion(loop, to: "Kick loop")

        f.project.setBlend(f.video1, .difference)
        f.project.setTrackMuted(f.video2, true)
        f.project.setTrackSolo(f.audio1, true)
        f.project.setValue(.track(.scale), track: f.video1, 1.5)
        f.project.addPoint(.track(.opacity), track: f.video1, tick: 0, value: 0)
        f.project.addPoint(.track(.opacity), track: f.video1, tick: 1920, value: 1)
        f.project.addPoint(.track(.pan), track: f.audio1, tick: 480, value: -0.5)

        let feedback = EffectSlot(kind: .feedback, bypass: true)
        let unit = EffectSlot(
            kind: .audioUnit,
            audioUnit: AudioUnitRef(type: 0x61756678, subType: 0x646c6179, manufacturer: 0x6170706c,
                                    name: "AUDelay", state: Data([0, 1, 2, 250, 255])),
            bendMode: .throughTime)
        f.project.addEffect(feedback, to: f.video1)
        f.project.addEffect(unit, to: f.video1)
        f.project.setValue(.effect(feedback.id, 1), track: f.video1, 1.05)
        f.project.addPoint(.effect(feedback.id, 0), track: f.video1, tick: 960, value: 0.9)
        f.project.addPoint(.effect(unit.id, 0xFFFF_FFFF_0000_0001), track: f.video1, tick: 0, value: 1234.5)
        f.project.addPoint(.effectMix(unit.id), track: f.video1, tick: 240, value: 0.4)
        f.project.tracks[0].automationShown = .effect(unit.id, 0xFFFF_FFFF_0000_0001)
        f.project.tracks[2].automationShown = .track(.pan)

        let data = try JSONEncoder().encode(f.project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)
        #expect(decoded == f.project)
        #expect(decoded.track(f.video1)?.effects.count == 2)
        #expect(decoded.track(f.video1)?.regions.count == 2)
        #expect(decoded.region(loop)?.isLooped == true)

        // And again, to be sure the encoding itself is stable.
        let again = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(decoded))
        #expect(again == decoded)
    }

    @Test func gridDivisionAndClipboardAreCodable() throws {
        let division = try JSONDecoder().decode([GridDivision].self,
                                                from: JSONEncoder().encode(GridDivision.allCases))
        #expect(division == GridDivision.allCases)
    }
}
