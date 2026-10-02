import AppKit
import Model
import Session

/// Development aids driven by environment variables, for checking the interface from a
/// script. They do nothing unless a variable is set.
///
///   VIDEODAW_IMPORT=/a.mov:/b.wav   place these files on the timeline at launch
///   VIDEODAW_DEMO=1                 add effects, a fade and automation to the first video track
///   VIDEODAW_SIGNATURE=7/8          set the time signature
///   VIDEODAW_PLAY=1                 start playback a second after launch
///   VIDEODAW_MIXER=1                open the mixer window at launch; with a snapshot, the
///                                   mixer is captured instead of the main window
///   VIDEODAW_SNAPSHOT=/out.png      after a few seconds, write a picture of the window here
///                                   and quit
enum DebugHooks {
    static var isCapturing: Bool { ProcessInfo.processInfo.environment["VIDEODAW_SNAPSHOT"] != nil }

    static func run(state: AppState, window: NSWindow) {
        let environment = ProcessInfo.processInfo.environment
        if let list = environment["VIDEODAW_IMPORT"] {
            let urls = list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            state.add(files: urls, at: 0, videoTrack: nil, audioTrack: nil)
            state.selectedTrack = state.project.tracks.first?.id
        }
        if environment["VIDEODAW_DEMO"] != nil, let video = state.project.tracks.first(where: { $0.kind == .video }) {
            func code(_ text: String) -> UInt32 { text.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
            let delay = AudioUnitRef(type: code("aufx"), subType: code("dely"), manufacturer: code("appl"), name: "Apple: AUDelay")
            state.session.perform { project in
                project.addEffect(EffectSlot(kind: .color, params: [2: Param(1.4)]), to: video.id)
                project.addEffect(EffectSlot(kind: .audioUnit, audioUnit: delay), to: video.id)
                project.addPoint(.track(.opacity), track: video.id, tick: 0, value: 0.3)
                project.addPoint(.track(.opacity), track: video.id, tick: 4 * ticksPerBeat, value: 1)
                if let index = project.trackIndex(video.id) { project.tracks[index].automationShown = .track(.opacity) }
                if let first = video.regions.first { project.setFadeOut(first.id, 2 * ticksPerBeat) }
            }
            state.session.seek(to: 6 * ticksPerBeat)
        }
        if let signature = environment["VIDEODAW_SIGNATURE"]?.split(separator: "/").compactMap({ Int($0) }), signature.count == 2 {
            state.session.perform { $0.setTimeSignature(beats: signature[0], unit: signature[1]) }
        }
        if environment["VIDEODAW_PLAY"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { state.session.play() }
        }
        if let path = environment["VIDEODAW_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                // An app may always capture its own window, Metal content included.
                let target = environment["VIDEODAW_MIXER"] != nil ? (state.mixerWindow ?? window) : window
                let image = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(target.windowNumber),
                                                    [.boundsIgnoreFraming, .bestResolution])
                if let image {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }
}
