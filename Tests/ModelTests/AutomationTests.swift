import Foundation
import Testing
import Model

@Suite struct ParamValueTests {
    @Test func staticParamIsItsValueEverywhere() {
        let param = Param(0.4)
        #expect(param.value(at: 0) == 0.4)
        #expect(param.value(at: 1_000_000) == 0.4)
    }

    @Test func interpolatesLinearlyAndHoldsAtTheEnds() {
        let param = Param(9, points: [
            AutoPoint(tick: 960, value: 0), AutoPoint(tick: 1920, value: 1), AutoPoint(tick: 3840, value: 0.5),
        ])
        #expect(param.value(at: 0) == 0)
        #expect(param.value(at: 960) == 0)
        #expect(param.value(at: 1440) == 0.5)
        #expect(param.value(at: 1200) == 0.25)
        #expect(param.value(at: 1920) == 1)
        #expect(param.value(at: 2880) == 0.75)
        #expect(param.value(at: 3840) == 0.5)
        #expect(param.value(at: 99_999) == 0.5)
    }

    @Test func aSinglePointHoldsEverywhere() {
        let param = Param(9, points: [AutoPoint(tick: 500, value: 0.2)])
        #expect(param.value(at: 0) == 0.2)
        #expect(param.value(at: 500) == 0.2)
        #expect(param.value(at: 501) == 0.2)
    }
}

@Suite struct ParamAccessTests {
    @Test func readsDefaultsAndWritesStaticValues() {
        var f = Fixture()
        #expect(f.project.param(.track(.opacity), track: f.video1) == Param(1))
        #expect(f.project.param(.track(.pan), track: f.audio1) == Param(0))

        #expect(f.project.setValue(.track(.opacity), track: f.video1, 0.5) == true)
        #expect(f.project.param(.track(.opacity), track: f.video1)?.value == 0.5)
        #expect(f.project.track(f.video1)?.params[.opacity] == Param(0.5))
        #expect(f.project.track(f.video2)?.params.isEmpty == true)
    }

    @Test func aTrackParamBackAtItsDefaultIsNotStored() {
        var f = Fixture()
        f.project.setValue(.track(.scale), track: f.video1, 2)
        f.project.setValue(.track(.scale), track: f.video1, 1)
        #expect(f.project.track(f.video1)?.params.isEmpty == true)
        #expect(f.project.param(.track(.scale), track: f.video1) == Param(1))
    }

    @Test func valuesAreClampedToTheParamRange() {
        var f = Fixture()
        f.project.setValue(.track(.opacity), track: f.video1, 7)
        #expect(f.project.param(.track(.opacity), track: f.video1)?.value == 1)
        f.project.setValue(.track(.rotation), track: f.video1, -1000)
        #expect(f.project.param(.track(.rotation), track: f.video1)?.value == -360)
        f.project.setValue(.track(.volume), track: f.audio1, 3)
        #expect(f.project.param(.track(.volume), track: f.audio1)?.value == 2)
        f.project.setValue(.track(.pan), track: f.audio1, -3)
        #expect(f.project.param(.track(.pan), track: f.audio1)?.value == -1)
    }

    @Test func trackParamsOfTheOtherKindDoNotExist() {
        var f = Fixture()
        let before = f.project
        #expect(f.project.param(.track(.volume), track: f.video1) == nil)
        #expect(f.project.param(.track(.opacity), track: f.audio1) == nil)
        #expect(f.project.paramRange(.track(.volume), track: f.video1) == nil)
        #expect(f.project.setValue(.track(.volume), track: f.video1, 0.5) == false)
        #expect(f.project.setParam(.track(.opacity), track: f.audio1, Param(0.5)) == false)
        #expect(f.project.addPoint(.track(.opacity), track: f.audio1, tick: 0, value: 1) == nil)
        #expect(f.project.param(.track(.opacity), track: UUID()) == nil)
        #expect(f.project.setValue(.track(.opacity), track: UUID(), 0.5) == false)
        #expect(f.project == before)
    }

    @Test func builtInEffectParamsUseTheirSpecs() {
        var f = Fixture()
        let blur = EffectSlot(kind: .blur)
        f.project.addEffect(blur, to: f.video1)
        let radius = ParamPath.effect(blur.id, 0)

        #expect(f.project.param(radius, track: f.video1) == Param(8))
        #expect(f.project.paramRange(radius, track: f.video1) == 0...50)
        f.project.setValue(radius, track: f.video1, 80)
        #expect(f.project.param(radius, track: f.video1)?.value == 50)
        #expect(f.project.addPoint(radius, track: f.video1, tick: 960, value: -4) == 0)
        #expect(f.project.param(radius, track: f.video1)?.points == [AutoPoint(tick: 960, value: 0)])
        #expect(f.project.track(f.video1)?.effects[0].builtinParam(0).value == 50)

        // Blur has one parameter; the slot lives on video1 only.
        #expect(f.project.param(.effect(blur.id, 1), track: f.video1) == nil)
        #expect(f.project.setValue(.effect(blur.id, 1), track: f.video1, 1) == false)
        #expect(f.project.param(radius, track: f.video2) == nil)
        #expect(f.project.addPoint(.effect(UUID(), 0), track: f.video1, tick: 0, value: 1) == nil)
    }

    @Test func effectMixIsClampedToZeroToOne() {
        var f = Fixture()
        let slot = EffectSlot(kind: .audioUnit, audioUnit: AudioUnitRef(type: 1, subType: 2, manufacturer: 3, name: "Delay"))
        f.project.addEffect(slot, to: f.video1)
        let mix = ParamPath.effectMix(slot.id)
        #expect(f.project.param(mix, track: f.video1) == Param(1))
        #expect(f.project.paramRange(mix, track: f.video1) == 0...1)
        f.project.setValue(mix, track: f.video1, -2)
        #expect(f.project.param(mix, track: f.video1)?.value == 0)
        f.project.addPoint(mix, track: f.video1, tick: 100, value: 4)
        #expect(f.project.param(mix, track: f.video1)?.points == [AutoPoint(tick: 100, value: 1)])
        #expect(f.project.param(.effectMix(UUID()), track: f.video1) == nil)
    }

    @Test func audioUnitParamsAreUnclampedAndAppearOnceSet() {
        var f = Fixture()
        let slot = EffectSlot(kind: .audioUnit, audioUnit: AudioUnitRef(type: 1, subType: 2, manufacturer: 3, name: "Delay"))
        f.project.addEffect(slot, to: f.audio1)
        let cutoff = ParamPath.effect(slot.id, 0xFFFF_0001)
        let time = ParamPath.effect(slot.id, 7)

        #expect(f.project.param(cutoff, track: f.audio1) == nil)
        #expect(f.project.paramRange(cutoff, track: f.audio1) == nil)

        #expect(f.project.setValue(cutoff, track: f.audio1, 18_000) == true)
        #expect(f.project.param(cutoff, track: f.audio1) == Param(18_000))

        // Automating a parameter that was never set starts from the point's value.
        #expect(f.project.addPoint(time, track: f.audio1, tick: 480, value: -250) == 0)
        #expect(f.project.param(time, track: f.audio1) == Param(-250, points: [AutoPoint(tick: 480, value: -250)]))
        #expect(f.project.track(f.audio1)?.effects[0].params.count == 2)
    }

    @Test func setParamSortsAndClampsWhatItIsGiven() {
        var f = Fixture()
        let messy = Param(3, points: [
            AutoPoint(tick: 960, value: 0.5), AutoPoint(tick: 0, value: -1),
            AutoPoint(tick: 960, value: 0.75), AutoPoint(tick: 480, value: 9),
        ])
        #expect(f.project.setParam(.track(.opacity), track: f.video1, messy) == true)
        #expect(f.project.param(.track(.opacity), track: f.video1) == Param(1, points: [
            AutoPoint(tick: 0, value: 0), AutoPoint(tick: 480, value: 1), AutoPoint(tick: 960, value: 0.75),
        ]))
    }
}

@Suite struct AutomationPointTests {
    let opacity = ParamPath.track(.opacity)

    @Test func pointsStaySortedByTick() {
        var f = Fixture()
        #expect(f.project.addPoint(opacity, track: f.video1, tick: 960, value: 1) == 0)
        #expect(f.project.addPoint(opacity, track: f.video1, tick: 0, value: 0) == 0)
        #expect(f.project.addPoint(opacity, track: f.video1, tick: 480, value: 0.25) == 1)
        #expect(f.project.addPoint(opacity, track: f.video1, tick: 5000, value: 0.5) == 3)
        let param = f.project.param(opacity, track: f.video1)!
        #expect(param.points.map(\.tick) == [0, 480, 960, 5000])
        #expect(param.points.map(\.value) == [0, 0.25, 1, 0.5])
        #expect(param.value(at: 240) == 0.125)
        #expect(param.value(at: 720) == 0.625)
    }

    @Test func aPointAtAnExistingTickReplacesIt() {
        var f = Fixture()
        f.project.addPoint(opacity, track: f.video1, tick: 0, value: 0)
        f.project.addPoint(opacity, track: f.video1, tick: 480, value: 0.25)
        #expect(f.project.addPoint(opacity, track: f.video1, tick: 480, value: 0.9) == 1)
        #expect(f.project.param(opacity, track: f.video1)?.points
                == [AutoPoint(tick: 0, value: 0), AutoPoint(tick: 480, value: 0.9)])
    }

    @Test func pointValuesAndTicksAreClamped() {
        var f = Fixture()
        #expect(f.project.addPoint(opacity, track: f.video1, tick: -300, value: 5) == 0)
        f.project.addPoint(opacity, track: f.video1, tick: 960, value: -5)
        #expect(f.project.param(opacity, track: f.video1)?.points
                == [AutoPoint(tick: 0, value: 1), AutoPoint(tick: 960, value: 0)])
    }

    @Test func theFirstPointLeavesTheStaticValueAlone() {
        var f = Fixture()
        f.project.setValue(opacity, track: f.video1, 0.3)
        let before = f.project
        f.project.addPoint(opacity, track: f.video1, tick: 960, value: 0.8)

        let param = f.project.param(opacity, track: f.video1)!
        #expect(param.value == 0.3)
        #expect(param.value(at: 0) == 0.8)
        // Nothing else in the project moved.
        var expected = before
        expected.tracks[0].params[.opacity] = Param(0.3, points: [AutoPoint(tick: 960, value: 0.8)])
        #expect(f.project == expected)
    }

    @Test func removingTheLastPointRestoresTheStaticValue() {
        var f = Fixture()
        f.project.setValue(opacity, track: f.video1, 0.3)
        let before = f.project
        f.project.addPoint(opacity, track: f.video1, tick: 960, value: 0.8)
        f.project.addPoint(opacity, track: f.video1, tick: 1920, value: 0.1)

        f.project.removePoint(opacity, track: f.video1, index: 0)
        #expect(f.project.param(opacity, track: f.video1)?.points == [AutoPoint(tick: 1920, value: 0.1)])
        f.project.removePoint(opacity, track: f.video1, index: 5)     // out of range: ignored
        f.project.removePoint(opacity, track: f.video1, index: 0)
        #expect(f.project.param(opacity, track: f.video1)?.value(at: 960) == 0.3)
        #expect(f.project == before)
    }

    @Test func removingTheLastPointOfADefaultParamLeavesNothingStored() {
        var f = Fixture()
        f.project.addPoint(opacity, track: f.video1, tick: 960, value: 0.8)
        #expect(f.project.track(f.video1)?.params[.opacity] != nil)
        f.project.removePoint(opacity, track: f.video1, index: 0)
        #expect(f.project.track(f.video1)?.params.isEmpty == true)
    }

    @Test func movingAPointChangesItsTickAndValue() {
        var f = Fixture()
        for (tick, value) in [(0, 0.0), (960, 0.5), (1920, 1.0)] {
            f.project.addPoint(opacity, track: f.video1, tick: Ticks(tick), value: value)
        }
        f.project.movePoint(opacity, track: f.video1, index: 1, to: 1200, value: 0.2)
        #expect(f.project.param(opacity, track: f.video1)?.points[1] == AutoPoint(tick: 1200, value: 0.2))

        f.project.movePoint(opacity, track: f.video1, index: 1, to: 1200, value: 3)
        #expect(f.project.param(opacity, track: f.video1)?.points[1] == AutoPoint(tick: 1200, value: 1))
    }

    @Test func aMovedPointStaysBetweenItsNeighbours() {
        var f = Fixture()
        for (tick, value) in [(0, 0.0), (960, 0.5), (1920, 1.0)] {
            f.project.addPoint(opacity, track: f.video1, tick: Ticks(tick), value: value)
        }
        f.project.movePoint(opacity, track: f.video1, index: 1, to: 5000, value: 0.5)
        #expect(f.project.param(opacity, track: f.video1)?.points.map(\.tick) == [0, 1919, 1920])
        f.project.movePoint(opacity, track: f.video1, index: 1, to: -40, value: 0.5)
        #expect(f.project.param(opacity, track: f.video1)?.points.map(\.tick) == [0, 1, 1920])

        // The ends are free on their open side, but never negative.
        f.project.movePoint(opacity, track: f.video1, index: 2, to: 9000, value: 1)
        f.project.movePoint(opacity, track: f.video1, index: 0, to: -500, value: 0)
        #expect(f.project.param(opacity, track: f.video1)?.points.map(\.tick) == [0, 1, 9000])
        f.project.movePoint(opacity, track: f.video1, index: 0, to: 700, value: 0)
        #expect(f.project.param(opacity, track: f.video1)?.points.map(\.tick) == [0, 1, 9000])
        #expect(f.project.param(opacity, track: f.video1)?.points.count == 3)

        let before = f.project
        f.project.movePoint(opacity, track: f.video1, index: 3, to: 100, value: 0)
        #expect(f.project == before)
    }
}
