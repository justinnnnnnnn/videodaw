import Foundation
import Testing

@testable import Model

/// A video track and an audio track, each with a four-beat region of the same file, linked
/// the way an imported video's picture and sound are.
private struct Linked {
    var project = Project()
    let picture: UUID
    let sound: UUID

    init() {
        let duration = flicksPerSecond * 2
        let videoMedia = project.addMedia(Media(path: "/clips/street.mov", kind: .video, duration: duration))
        let audioMedia = project.addMedia(Media(path: "/clips/street.mov", kind: .audio, duration: duration))
        let videoTrack = project.addTrack(kind: .video)
        let audioTrack = project.addTrack(kind: .audio)
        picture = project.addRegion(mediaID: videoMedia, trackID: videoTrack, at: 0)!
        sound = project.addRegion(mediaID: audioMedia, trackID: audioTrack, at: 0)!
        project.link([picture, sound])
    }
}

@Suite struct LinkTests {
    @Test func linkedRegionsComeAlongWithEachOther() {
        let f = Linked()
        #expect(f.project.linkedRegions([f.picture]) == [f.picture, f.sound])
        #expect(f.project.linkedRegions([f.sound]) == [f.picture, f.sound])
        #expect(f.project.linkedRegions([]) == [])
    }

    @Test func unlinkedRegionsStandAlone() {
        var f = Linked()
        f.project.unlink([f.picture])
        #expect(f.project.linkedRegions([f.picture]) == [f.picture])
        // The sound keeps its link but has no partner left.
        #expect(f.project.linkedRegions([f.sound]) == [f.sound])
    }

    @Test func linkingNeedsTwoRegionsAndReplacesOldLinks() {
        var f = Linked()
        let before = f.project.region(f.picture)?.link
        f.project.link([f.picture])
        #expect(f.project.region(f.picture)?.link == before)
        f.project.unlink([f.picture, f.sound])
        f.project.link([f.picture, f.sound])
        #expect(f.project.region(f.picture)?.link != nil)
        #expect(f.project.region(f.picture)?.link == f.project.region(f.sound)?.link)
    }

    @Test func splittingLinkedRegionsLinksLeftWithLeftAndRightWithRight() {
        var f = Linked()
        let rights = f.project.split([f.picture, f.sound], at: 2 * ticksPerBeat)
        #expect(rights.count == 2)
        #expect(f.project.linkedRegions([f.picture]) == [f.picture, f.sound])
        #expect(f.project.linkedRegions([rights[0]]) == Set(rights))
    }

    @Test func splittingOnlyOnePartnerLeavesTheNewPieceOnItsOwn() {
        var f = Linked()
        let rights = f.project.split([f.picture], at: 2 * ticksPerBeat)
        #expect(f.project.linkedRegions([rights[0]]) == [rights[0]])
        #expect(f.project.linkedRegions([f.picture]) == [f.picture, f.sound])
    }

    @Test func duplicatesAreLinkedToEachOtherNotToTheOriginals() {
        var f = Linked()
        let copies = f.project.duplicate([f.picture, f.sound])
        #expect(f.project.linkedRegions([copies[0]]) == Set(copies))
        #expect(f.project.linkedRegions([f.picture]) == [f.picture, f.sound])
    }

    @Test func pastedRegionsAreLinkedToEachOtherNotToTheOriginals() {
        var f = Linked()
        let clipboard = f.project.copyRegions([f.picture, f.sound])
        let first = f.project.paste(clipboard, at: 8 * ticksPerBeat)
        let second = f.project.paste(clipboard, at: 16 * ticksPerBeat)
        #expect(f.project.linkedRegions([first[0]]) == Set(first))
        #expect(f.project.linkedRegions([second[0]]) == Set(second))
    }

    @Test func aProjectSavedBeforeLinksExistedStillOpens() throws {
        let f = Linked()
        let data = try JSONEncoder().encode(f.project)
        var json = try #require(String(data: data, encoding: .utf8))
        let link = try #require(f.project.region(f.picture)?.link)
        json = json.replacingOccurrences(of: "\"link\":\"\(link.uuidString)\",", with: "")
        json = json.replacingOccurrences(of: ",\"link\":\"\(link.uuidString)\"", with: "")
        #expect(!json.contains("\"link\""))
        let reopened = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(reopened.region(f.picture)?.link == nil)
        #expect(reopened.region(f.sound)?.length == f.project.region(f.sound)?.length)
    }
}
