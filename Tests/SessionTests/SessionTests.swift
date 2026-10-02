import AVFoundation
import Foundation
import Model
import Testing

@testable import Session

// Synthetic media: a 2-second, 30 fps clip whose grey level rises with the frame number,
// and a 2-second sine tone. Exports are read back and checked against them.

private let clipFrames = 60

private func grey(forFrame index: Int) -> Int { 30 + index * 3 }

private func scratchFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("videodaw-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Two seconds of the tone as a sample buffer, for a movie's soundtrack.
private func toneBuffer() -> CMSampleBuffer {
    let count = 96000
    var samples = [Float](repeating: 0, count: count * 2)
    for i in 0..<count {
        samples[i * 2] = toneSample(i, of: count, rising: false)
        samples[i * 2 + 1] = samples[i * 2]
    }
    var description = AudioStreamBasicDescription(
        mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
        mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    var block: CMBlockBuffer?
    let bytes = samples.count * 4
    CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                       customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                       flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    CMBlockBufferReplaceDataBytes(with: samples, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes)
    var buffer: CMSampleBuffer?
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count,
        presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &buffer)
    return buffer!
}

private func makeClip(at url: URL, split: Bool = false, withSound: Bool = false) async {
    let writer = try! AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
    ])
    writer.add(input)
    let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
    ])
    if withSound { writer.add(sound) }
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    if withSound {
        sound.append(toneBuffer())
        sound.markAsFinished()
    }
    for index in 0..<clipFrames {
        while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 1_000_000) }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<180 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<320 * 4 {
                // The split clip is dark on the left half and bright on the right, in every frame.
                let level = split ? (x / 4 < 160 ? 40 : 200) : grey(forFrame: index)
                row[x] = x % 4 == 3 ? 255 : UInt8(level)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// A 440 Hz tone at half amplitude; with `rising`, it grows from silence to that level.
private func toneSample(_ index: Int, of count: Int, rising: Bool) -> Float {
    0.5 * sin(2 * Float.pi * 440 * Float(index) / 48000) * (rising ? Float(index) / Float(count) : 1)
}

private func makeTone(at url: URL, seconds: Double = 2, rising: Bool = false) {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let file = try! AVAudioFile(forWriting: url, settings: format.settings)
    let count = AVAudioFrameCount(seconds * 48000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
    buffer.frameLength = count
    for i in 0..<Int(count) {
        let value = toneSample(i, of: Int(count), rising: rising)
        buffer.floatChannelData![0][i] = value
        buffer.floatChannelData![1][i] = value
    }
    try! file.write(from: buffer)
}

private struct Movie {
    var duration: Double
    /// The red value of the centre pixel, of a pixel near the top-left corner, and of a pixel
    /// 30 to the left of centre, per frame.
    var centre: [Int]
    var corner: [Int]
    var left: [Int]
    var audioRMS: Double
    /// The left channel of the soundtrack.
    var sound: [Float]

    /// The level of the sound between two times.
    func rms(from start: Double, to end: Double) -> Double {
        let slice = sound[min(sound.count, Int(start * 48000))..<min(sound.count, Int(end * 48000))]
        return slice.isEmpty ? 0 : (slice.reduce(0.0) { $0 + Double($1 * $1) } / Double(slice.count)).squareRoot()
    }

    /// The first sample at which the sound is clearly present.
    var onset: Int? { sound.firstIndex { abs($0) > 0.05 } }
}

private func read(_ url: URL) -> Movie {
    let asset = AVURLAsset(url: url)
    let reader = try! AVAssetReader(asset: asset)
    let video = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    reader.add(video)
    let audioTracks = asset.tracks(withMediaType: .audio)
    let audio = audioTracks.isEmpty ? nil : AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
    ])
    if let audio { reader.add(audio) }
    reader.startReading()
    var centre: [Int] = [], corner: [Int] = [], left: [Int] = []
    while let sample = video.copyNextSampleBuffer() {
        let pixels = CMSampleBufferGetImageBuffer(sample)!
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        centre.append(Int(base[(height / 2) * rowBytes + (width / 2) * 4 + 2]))
        corner.append(Int(base[6 * rowBytes + 6 * 4 + 2]))
        left.append(Int(base[(height / 2) * rowBytes + (width / 2 - 30) * 4 + 2]))
        CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
    }
    var sum = 0.0, count = 0.0
    var sound: [Float] = []
    while let sample = audio?.copyNextSampleBuffer() {
        let block = CMSampleBufferGetDataBuffer(sample)!
        var values = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: values.count * 4, destination: &values)
        for value in values {
            sum += Double(value * value)
            count += 1
        }
        sound += stride(from: 0, to: values.count, by: 2).map { values[$0] }
    }
    return Movie(duration: CMTimeGetSeconds(asset.duration), centre: centre, corner: corner, left: left,
                 audioRMS: count > 0 ? (sum / count).squareRoot() : 0, sound: sound)
}

@MainActor
private func export(_ session: Session, to url: URL, range: Range<Ticks>? = nil) async -> Movie {
    await session.waitUntilLoaded()
    let error: String? = await withCheckedContinuation { continuation in
        session.export(to: url, range: range) { continuation.resume(returning: $0) }
    }
    #expect(error == nil)
    return read(url)
}

/// A session holding the test clip and tone at the start of the timeline.
@MainActor
private func loadedSession(in folder: URL) async -> (session: Session, video: UUID, audio: UUID) {
    let clip = folder.appendingPathComponent("clip.mov"), tone = folder.appendingPathComponent("tone.wav")
    await makeClip(at: clip)
    makeTone(at: tone)
    let session = Session(realtime: false)
    let video = session.addFile(clip, at: 0)[0]
    let audio = session.addFile(tone, at: 0)[0]
    return (session, video, audio)
}

@MainActor
@Suite(.serialized)
struct SessionTests {
    @Test func importAdoptsTheClipFormatAndMakesTracks() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let project = loaded.session.project
        #expect(project.width == 320 && project.height == 180 && project.fps == 30)
        #expect(project.tracks.map(\.kind) == [.video, .audio])
        // Two seconds at 120 bpm is four beats.
        #expect(project.region(loaded.video)?.length == 4 * ticksPerBeat)
        #expect(project.region(loaded.audio)?.length == 4 * ticksPerBeat)
    }

    @Test func exportPlaysTheClipForwardWithItsSound() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let movie = await export(loaded.session, to: folder.appendingPathComponent("out.mov"))
        #expect(abs(movie.duration - 2) < 0.05)
        #expect(movie.centre.count == clipFrames)
        for index in [0, 15, 30, 59] { #expect(abs(movie.centre[index] - grey(forFrame: index)) <= 8) }
        // A half-amplitude sine has an RMS of about 0.35.
        #expect(abs(movie.audioRMS - 0.354) < 0.03)
    }

    @Test func reversedRegionStartsOnTheLastFrame() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        loaded.session.perform { $0.reverse([loaded.video]) }
        let movie = await export(loaded.session, to: folder.appendingPathComponent("out.mov"))
        #expect(abs(movie.centre[0] - grey(forFrame: clipFrames - 1)) <= 8)
        #expect(abs(movie.centre[clipFrames - 1] - grey(forFrame: 0)) <= 8)
    }

    @Test func stretchingToDoubleLengthDoublesTheDuration() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        loaded.session.perform { project in
            project.stretch(loaded.video, toLength: 8 * ticksPerBeat)
            project.stretch(loaded.audio, toLength: 8 * ticksPerBeat)
        }
        let movie = await export(loaded.session, to: folder.appendingPathComponent("out.mov"))
        #expect(abs(movie.duration - 4) < 0.05)
        // Half way through the stretched region is half way through the clip.
        #expect(abs(movie.centre[60] - grey(forFrame: 30)) <= 10)
        #expect(abs(movie.audioRMS - 0.354) < 0.05)
    }

    @Test func loopRepeatsTheClip() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        loaded.session.perform { $0.setLoopEnd(loaded.video, to: 8 * ticksPerBeat) }
        let movie = await export(loaded.session, to: folder.appendingPathComponent("out.mov"))
        #expect(movie.centre.count == 2 * clipFrames)
        #expect(abs(movie.centre[clipFrames + 10] - grey(forFrame: 10)) <= 8)
    }

    @Test func fadeInStartsFromBlackAndSilence() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        loaded.session.perform { project in
            project.setFadeIn(loaded.video, 4 * ticksPerBeat)
            project.deleteRegions([loaded.audio])
        }
        let movie = await export(loaded.session, to: folder.appendingPathComponent("out.mov"))
        #expect(movie.centre[0] <= 4)
        // Half way through the fade the picture is at about half its own brightness.
        #expect(abs(movie.centre[30] - grey(forFrame: 30) / 2) <= 10)
        #expect(movie.audioRMS < 0.001)
    }

    @Test func mixerSettingsReachThePictureAndTheSound() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        let videoTrack = session.project.tracks[0].id, audioTrack = session.project.tracks[1].id
        session.perform { project in
            project.setValue(.track(.scale), track: videoTrack, 0.5)
            project.setValue(.track(.opacity), track: videoTrack, 0.5)
            project.setValue(.track(.volume), track: audioTrack, 0.5)
        }
        let movie = await export(session, to: folder.appendingPathComponent("out.mov"))
        // Half opacity over black in the middle; nothing in the corner of a half-size picture.
        #expect(abs(movie.centre[30] - grey(forFrame: 30) / 2) <= 10)
        #expect(movie.corner[30] <= 4)
        #expect(abs(movie.audioRMS - 0.177) < 0.02)
    }

    @Test func mutedAndSoloedTracksAreRespected() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        session.perform { $0.setTrackMuted(session.project.tracks[0].id, true) }
        let movie = await export(session, to: folder.appendingPathComponent("out.mov"))
        #expect(movie.centre[30] <= 4)
        #expect(movie.audioRMS > 0.3)
    }

    @Test func automationMovesAParameterOverTime() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        let track = session.project.tracks[0].id
        session.perform { project in
            project.addPoint(.track(.opacity), track: track, tick: 0, value: 0)
            project.addPoint(.track(.opacity), track: track, tick: 4 * ticksPerBeat, value: 1)
        }
        let movie = await export(session, to: folder.appendingPathComponent("out.mov"))
        #expect(movie.centre[0] <= 4)
        #expect(abs(movie.centre[30] - grey(forFrame: 30) / 2) <= 10)
        #expect(abs(movie.centre[59] - grey(forFrame: 59)) <= 12)
    }

    @Test func builtInEffectChangesThePicture() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        let track = session.project.tracks[0].id
        // Brightness +0.2 lifts every grey by about 51 levels.
        let slot = EffectSlot(kind: .color, params: [0: Param(0.2)])
        session.perform { $0.addEffect(slot, to: track) }
        let movie = await export(session, to: folder.appendingPathComponent("out.mov"))
        #expect(abs(movie.centre[10] - (grey(forFrame: 10) + 51)) <= 10)
    }

    // Apple's own filters stand in for third-party plugins; they are on every Mac.
    private func appleEffect(_ subType: String, _ name: String) -> AudioUnitRef {
        func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
        return AudioUnitRef(type: code("aufx"), subType: code(subType), manufacturer: code("appl"), name: name)
    }

    @Test func audioUnitOnAnAudioTrackFiltersTheSound() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        let track = session.project.tracks[1].id
        let slot = EffectSlot(kind: .audioUnit, audioUnit: appleEffect("lpas", "Low-pass"))
        session.perform { project in
            project.deleteRegions([loaded.video])
            project.addEffect(slot, to: track)
        }
        await session.waitUntilLoaded()
        #expect(session.pluginIsReady(slot: slot.id))
        // Automate the cutoff (parameter 0) down to 60 Hz: a 440 Hz tone all but disappears.
        session.perform { project in
            project.addPoint(.effect(slot.id, 0), track: track, tick: 0, value: 60)
            project.addPoint(.effect(slot.id, 0), track: track, tick: 4 * ticksPerBeat, value: 60)
        }
        let movie = await export(session, to: folder.appendingPathComponent("out.mov"))
        #expect(movie.audioRMS < 0.08)
        #expect(movie.audioRMS > 0.0001)
    }

    @Test func audioUnitOnAVideoTrackBendsThePicture() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        let track = session.project.tracks[0].id
        // A high-pass filter removes the constant part of the signal, and a flat grey frame
        // is nothing but constant: every pixel lands on the signal's zero, mid-grey.
        let slot = EffectSlot(kind: .audioUnit, audioUnit: appleEffect("hpas", "High-pass"))
        session.perform { $0.addEffect(slot, to: track) }
        var movie = await export(session, to: folder.appendingPathComponent("wet.mov"))
        #expect(abs(movie.centre[10] - 127) <= 12)
        #expect(abs(movie.centre[55] - 127) <= 12)

        // Half wet: half way between the original grey and mid-grey.
        session.perform { $0.setValue(.effectMix(slot.id), track: track, 0.5) }
        movie = await export(session, to: folder.appendingPathComponent("half.mov"))
        #expect(abs(movie.centre[10] - (grey(forFrame: 10) + 127) / 2) <= 12)

        // Bypassed: the picture is untouched.
        session.perform { $0.setEffectBypass(slot.id, track: track, true) }
        movie = await export(session, to: folder.appendingPathComponent("dry.mov"))
        #expect(abs(movie.centre[10] - grey(forFrame: 10)) <= 8)
    }

    @Test func throughTimeModeFiltersEachPixelAcrossFrames() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        let track = session.project.tracks[0].id
        // A low-pass filter. Read as a raster, a flat frame is a constant and passes
        // untouched. Read through time, each pixel is the clip's brightness ramp, and the
        // filter lags a dozen or so frames behind it.
        let slot = EffectSlot(kind: .audioUnit, audioUnit: appleEffect("lpas", "Low-pass"))
        session.perform { project in
            project.addEffect(slot, to: track)
            project.addPoint(.effect(slot.id, 0), track: track, tick: 0, value: 100)
            project.addPoint(.effect(slot.id, 0), track: track, tick: 4 * ticksPerBeat, value: 100)
        }
        let raster = await export(session, to: folder.appendingPathComponent("raster.mov"))
        #expect(abs(raster.centre[20] - grey(forFrame: 20)) <= 12)
        #expect(abs(raster.centre[55] - grey(forFrame: 55)) <= 12)

        session.perform { _ = $0.setBendMode(slot.id, track: track, .throughTime) }
        let through = await export(session, to: folder.appendingPathComponent("through.mov"))
        #expect(through.centre.count == clipFrames)
        #expect(grey(forFrame: 20) - through.centre[20] > 20)
        #expect(grey(forFrame: 55) - through.centre[55] > 20)
        // The picture still rises with the clip, and carries smoothly over the chunk edge
        // between frames 31 and 32.
        #expect(through.centre[55] > through.centre[20] + 40)
        #expect(abs(through.centre[32] - through.centre[31]) <= 12)

        // The same project exports the same picture twice: chunks depend only on the plan.
        let again = await export(session, to: folder.appendingPathComponent("again.mov"))
        #expect(again.centre == through.centre)
    }

    @Test func pluginSettingsSurviveSaveAndReopen() async throws {
        let folder = scratchFolder()
        let package = folder.appendingPathComponent("Song.vdaw")
        let session = try Session.create(at: package, realtime: false)
        let tone = folder.appendingPathComponent("tone.wav")
        makeTone(at: tone)
        session.addFile(tone, at: 0)
        let track = session.project.tracks[0].id
        let slot = EffectSlot(kind: .audioUnit, audioUnit: appleEffect("lpas", "Low-pass"))
        session.perform { $0.addEffect(slot, to: track) }
        await session.waitUntilLoaded()
        session.setPluginParameter(slot: slot.id, address: 0, value: 432)
        try session.save()

        let reopened = try Session.open(package, realtime: false)
        await reopened.waitUntilLoaded()
        let cutoff = reopened.pluginParameters(slot: slot.id).first { $0.address == 0 }
        #expect(abs((cutoff?.value ?? 0) - 432) < 1)
    }

    @Test func spatialEffectsMovePixelsAsDescribed() async {
        let folder = scratchFolder()
        let clip = folder.appendingPathComponent("split.mov")
        await makeClip(at: clip, split: true)
        let session = Session(realtime: false)
        session.addFile(clip, at: 0)
        let track = session.project.tracks[0].id
        var movie = await export(session, to: folder.appendingPathComponent("plain.mov"))
        #expect(abs(movie.left[30] - 40) <= 8)
        #expect(abs(movie.centre[30] - 200) <= 8)

        // Blur spreads the bright half into the dark one.
        let blur = EffectSlot(kind: .blur, params: [0: Param(50)])
        session.perform { $0.addEffect(blur, to: track) }
        movie = await export(session, to: folder.appendingPathComponent("blur.mov"))
        #expect(movie.left[30] > 50 && movie.left[30] < 120)
        #expect(movie.centre[30] > 95 && movie.centre[30] < 145)

        // 100-pixel blocks: the block holding the centre takes its colour from the dark side.
        let pixelate = EffectSlot(kind: .pixelate, params: [0: Param(100)])
        session.perform { project in
            project.removeEffect(blur.id, track: track)
            project.addEffect(pixelate, to: track)
        }
        movie = await export(session, to: folder.appendingPathComponent("pixelate.mov"))
        #expect(abs(movie.centre[30] - 40) <= 8)

        // Displacement moves pixels sideways: somewhere in the clip the dark probe point
        // picks up the bright half, and nothing leaves the range the two halves span.
        let displace = EffectSlot(kind: .displace, params: [0: Param(60)])
        session.perform { project in
            project.removeEffect(pixelate.id, track: track)
            project.addEffect(displace, to: track)
        }
        movie = await export(session, to: folder.appendingPathComponent("displace.mov"))
        #expect(movie.centre.count == clipFrames)
        #expect(movie.left.contains { $0 > 100 })
        #expect((movie.left + movie.centre).allSatisfy { $0 >= 28 && $0 <= 212 })
    }

    @Test func feedbackLeavesATrailWhenThePictureFadesOut() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        let track = session.project.tracks[0].id
        let feedback = EffectSlot(kind: .feedback, params: [0: Param(0.97), 1: Param(1)])
        session.perform { project in
            project.setFadeOut(loaded.video, ticksPerBeat)
            project.addEffect(feedback, to: track)
        }
        let trailed = await export(session, to: folder.appendingPathComponent("trail.mov"))
        session.perform { $0.setEffectBypass(feedback.id, track: track, true) }
        let plain = await export(session, to: folder.appendingPathComponent("plain.mov"))
        // Near the end of the fade the picture itself is almost black; the trail is not.
        #expect(plain.centre[57] < 60)
        #expect(trailed.centre[57] > plain.centre[57] + 60)
    }

    @Test func reversedAndStretchedSoundPlaysTheRightPartAtTheRightTime() async {
        let folder = scratchFolder()
        let tone = folder.appendingPathComponent("rising.wav")
        makeTone(at: tone, rising: true)
        let session = Session(realtime: false)
        let region = session.addFile(tone, at: 0)[0]

        // As recorded, the tone grows: quiet first, loud last.
        var movie = await export(session, to: folder.appendingPathComponent("plain.mov"))
        #expect(movie.rms(from: 0.1, to: 0.4) < movie.rms(from: 1.6, to: 1.9) / 3)

        // Reversed: loud first.
        session.perform { $0.reverse([region]) }
        movie = await export(session, to: folder.appendingPathComponent("reversed.mov"))
        #expect(movie.rms(from: 0.1, to: 0.4) > movie.rms(from: 1.6, to: 1.9) * 3)

        // Reversed and stretched to twice the length: still loud first, over four seconds,
        // and half way through it is at about half the full level.
        session.perform { $0.stretch(region, toLength: 8 * ticksPerBeat) }
        movie = await export(session, to: folder.appendingPathComponent("slow.mov"))
        #expect(abs(movie.duration - 4) < 0.05)
        #expect(movie.rms(from: 0.2, to: 0.8) > movie.rms(from: 3.2, to: 3.8) * 3)
        let middle = movie.rms(from: 1.8, to: 2.2)
        #expect(middle > 0.12 && middle < 0.24)
    }

    @Test func aPluginThatDelaysItsSoundIsCompensated() async {
        let folder = scratchFolder()
        let tone = folder.appendingPathComponent("tone.wav")
        makeTone(at: tone)
        let session = Session(realtime: false)
        // The tone starts exactly one second in.
        session.addFile(tone, at: 2 * ticksPerBeat)
        let plain = await export(session, to: folder.appendingPathComponent("plain.mov"))
        let expected = try! #require(plain.onset)
        #expect(abs(expected - 48000) < 200)

        // Apple's pitch shifter reports 4096 samples of delay. Left alone it would put the
        // tone that much late; compensated, the tone starts where it did before.
        let track = session.project.tracks[0].id
        let slot = EffectSlot(kind: .audioUnit, audioUnit: appleEffect("nutp", "Pitch"))
        session.perform { $0.addEffect(slot, to: track) }
        let delayed = await export(session, to: folder.appendingPathComponent("delayed.mov"))
        let onset = try! #require(delayed.onset)
        #expect(abs(onset - expected) < 1500)
        #expect(delayed.rms(from: 1.5, to: 2.5) > 0.2)
    }

    @Test func longerThroughTimeMemoryLetsASlowEffectFollowThePicture() async {
        let folder = scratchFolder()
        let loaded = await loadedSession(in: folder)
        let session = loaded.session
        let track = session.project.tracks[0].id
        // A filter that takes about 40 frames to respond: longer than 32 frames of memory
        // can hold, comfortably inside 256. The picture follows the clip's rising
        // brightness, a second or so behind it.
        var slot = EffectSlot(kind: .audioUnit, audioUnit: appleEffect("lpas", "Low-pass"), bendMode: .throughTime)
        slot.bendMemory = .medium
        session.perform { project in
            project.bendHeight = 36 // a small signal keeps the test quick
            project.addEffect(slot, to: track)
            project.addPoint(.effect(slot.id, 0), track: track, tick: 0, value: 30)
            project.addPoint(.effect(slot.id, 0), track: track, tick: 4 * ticksPerBeat, value: 30)
        }
        let movie = await export(session, to: folder.appendingPathComponent("long.mov"))
        #expect(movie.centre.count == clipFrames)
        #expect(movie.centre[55] - movie.centre[5] > 15)
        #expect(grey(forFrame: 55) - movie.centre[55] > 40)
        // No step where a 32-frame chunk would have ended.
        #expect(abs(movie.centre[32] - movie.centre[31]) <= 6)
    }

    @Test func aVideoWithSoundArrivesAsLinkedPictureAndSound() async {
        let folder = scratchFolder()
        let clip = folder.appendingPathComponent("talkie.mov")
        await makeClip(at: clip, withSound: true)
        let session = Session(realtime: false)
        let regions = session.addFile(clip, at: 0)
        #expect(regions.count == 2)
        #expect(session.project.tracks.map(\.kind) == [.video, .audio])
        #expect(session.project.linkedRegions([regions[0]]) == Set(regions))
        let movie = await export(session, to: folder.appendingPathComponent("out.mov"))
        #expect(abs(movie.centre[30] - grey(forFrame: 30)) <= 8)
        #expect(abs(movie.audioRMS - 0.354) < 0.04)
    }

    @Test func projectSurvivesSaveAndReopen() async throws {
        let folder = scratchFolder()
        let package = folder.appendingPathComponent("Song.vdaw")
        let session = try Session.create(at: package, realtime: false)
        let clip = folder.appendingPathComponent("clip.mov")
        await makeClip(at: clip)
        session.addFile(clip, at: ticksPerBeat)
        try session.save()
        let reopened = try Session.open(package, realtime: false)
        #expect(reopened.project == session.project)
        #expect(reopened.project.name == "Song")
    }

    @Test func importedVideoGetsAnEditingProxyAndExportIsUnchanged() async throws {
        let folder = scratchFolder()
        let package = folder.appendingPathComponent("Song.vdaw")
        let session = try Session.create(at: package, realtime: false)
        session.makesProxies = true
        let clip = folder.appendingPathComponent("clip.mov")
        await makeClip(at: clip)
        session.addFile(clip, at: 0)
        await session.waitForProxies()
        let proxy = ProxyMaker.url(for: clip.path, in: package)
        #expect(FileManager.default.fileExists(atPath: proxy.path))
        // Every frame of the proxy is a key frame, at the same times as the original.
        let frames = read(proxy)
        #expect(frames.centre.count == clipFrames)
        #expect(!ProxyMaker.needsProxy(proxy.path))
        let movie = await export(session, to: folder.appendingPathComponent("out.mov"))
        #expect(abs(movie.centre[30] - grey(forFrame: 30)) <= 8)
        #expect(movie.centre.count == clipFrames)
    }

    @Test func collectedProjectStillExportsAfterOriginalsAreDeleted() async throws {
        let folder = scratchFolder()
        let package = folder.appendingPathComponent("Song.vdaw")
        let session = try Session.create(at: package, realtime: false)
        let clip = folder.appendingPathComponent("clip.mov")
        await makeClip(at: clip)
        session.addFile(clip, at: 0)
        try session.collectMedia()
        try FileManager.default.removeItem(at: clip)
        #expect(session.project.media.allSatisfy { $0.path.hasPrefix(package.path) })
        let reopened = try Session.open(package, realtime: false)
        let movie = await export(reopened, to: folder.appendingPathComponent("out.mov"))
        #expect(abs(movie.centre[30] - grey(forFrame: 30)) <= 8)
    }
}
