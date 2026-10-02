import AVFoundation
import CryptoKit
import Foundation

/// Makes all-intra editing copies of video files. Every frame of a proxy decodes on its
/// own, so scrubbing and reverse play stay smooth where a camera or phone file would
/// stutter. Proxies carry picture only and are disposable: export reads the originals.
enum ProxyMaker {
    /// Where the proxy for `path` lives inside a project's cache.
    static func url(for path: String, in package: URL) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return package.appendingPathComponent("cache/proxies/\(digest).mov")
    }

    /// True if the file's video is long-GOP (H.264, HEVC and the like) and so worth a proxy.
    static func needsProxy(_ path: String) -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .video).first,
              let format = track.formatDescriptions.first else { return false }
        let codec = CMFormatDescriptionGetMediaSubType(format as! CMFormatDescription)
        let intra: Set<FourCharCode> = [
            kCMVideoCodecType_AppleProRes422Proxy, kCMVideoCodecType_AppleProRes422LT, kCMVideoCodecType_AppleProRes422,
            kCMVideoCodecType_AppleProRes422HQ, kCMVideoCodecType_AppleProRes4444, kCMVideoCodecType_JPEG,
        ]
        return !intra.contains(codec)
    }

    /// Transcodes `source` to ProRes Proxy at `target`, at most 1920 pixels on its long
    /// side. Blocks until done; returns false if the file could not be read or written.
    static func make(from source: String, to target: URL) -> Bool {
        let asset = AVURLAsset(url: URL(fileURLWithPath: source))
        guard let track = asset.tracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)

        let size = track.naturalSize
        let scale = min(1, 1920 / max(size.width, size.height))
        let width = Int((size.width * scale / 2).rounded()) * 2, height = Int((size.height * scale / 2).rounded()) * 2
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written under a temporary name so a half-made proxy is never mistaken for a whole one.
        let partial = target.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partial)
        guard let writer = try? AVAssetWriter(outputURL: partial, fileType: .mov) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes422Proxy, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = track.preferredTransform
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        guard reader.startReading(), writer.startWriting(), var sample = output.copyNextSampleBuffer() else { return false }
        // The proxy starts where the original's first frame does, so times match exactly.
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
        while true {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            guard input.append(sample), let next = output.copyNextSampleBuffer() else { break }
            sample = next
        }
        input.markAsFinished()
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        finished.wait()
        guard reader.status == .completed, writer.status == .completed else {
            try? FileManager.default.removeItem(at: partial)
            return false
        }
        try? FileManager.default.removeItem(at: target)
        return (try? FileManager.default.moveItem(at: partial, to: target)) != nil
    }
}
