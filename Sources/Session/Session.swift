import AppKit
import AVFoundation
import Combine
import Engine
import Model

private final class Box<T> {
    let value: T
    init(_ value: T) { self.value = value }
}

public struct PluginParameter: Identifiable, Equatable {
    public var address: UInt64
    public var name: String
    public var range: ClosedRange<Double>
    public var value: Double
    public var id: UInt64 { address }
}

/// One open project: its undo history, its engine, and its folder on disk. Every edit goes
/// through `perform`, which recompiles the render plan and schedules an autosave.
public final class Session: ObservableObject {
    public let engine: OpaquePointer
    @Published public private(set) var history: History
    /// 0...1 while a movie is being exported, nil otherwise.
    @Published public private(set) var exportProgress: Double?
    /// How many editing proxies are being made in the background.
    @Published public private(set) var proxiesInProgress = 0
    /// Whether imported video gets an all-intra editing copy in the project's cache.
    public var makesProxies: Bool
    public private(set) var packageURL: URL?
    /// Called after every change, for views that are not SwiftUI.
    public var onChange: (() -> Void)?

    public var project: Project { history.project }

    private var videoHandles: [String: Int32] = [:]
    private var audioHandles: [String: Int32] = [:]
    private var audioPending: Set<String> = []
    private var plugins: [UUID: Int32] = [:]
    private var pluginPending: Set<UUID> = []
    private var retiredPluginStates: [UUID: Data] = [:]
    private var saveWork: DispatchWorkItem?
    private let mediaQueue = DispatchQueue(label: "videodaw.media", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "videodaw.thumbnails", qos: .utility)
    private var peakCache: [UUID: [Float]] = [:]
    private var peakPending: Set<UUID> = []
    private var thumbnailCache: [String: CGImage] = [:]
    private var thumbnailPending: Set<String> = []
    private var generators: [String: AVAssetImageGenerator] = [:]
    private var proxyPending: Set<String> = []
    private let proxyQueue = DispatchQueue(label: "videodaw.proxies", qos: .utility)
    private var useOriginals = false

    public init(project: Project = Project(), packageURL: URL? = nil, realtime: Bool = true) {
        engine = vd_create(realtime)
        history = History(project)
        self.packageURL = packageURL
        makesProxies = realtime
        compile()
    }

    deinit {
        saveWork?.cancel()
        mediaQueue.sync {} // background opens still refer to the engine
        vd_destroy(engine)
    }

    // MARK: Editing

    @discardableResult
    public func perform<T>(_ edit: (inout Project) -> T) -> T {
        let result = history.perform(edit)
        changed()
        return result
    }

    /// For continuous gestures: calls with the same key form one undo step.
    @discardableResult
    public func performCoalescing<T>(key: String, _ edit: (inout Project) -> T) -> T {
        let result = history.performCoalescing(key: key, edit)
        changed()
        return result
    }

    public func endCoalescing() {
        history.endCoalescing()
    }

    public func undo() {
        if history.undo() { changed() }
    }

    public func redo() {
        if history.redo() { changed() }
    }

    private func changed() {
        retirePlugins()
        compile()
        vd_set_cycle(engine, project.cycleOn, project.samples(project.cycleStart), project.samples(project.cycleEnd))
        scheduleSave()
        onChange?()
    }

    // MARK: Plan

    private func compile() {
        let handles = EngineHandles(
            video: { [unowned self] media in self.videoHandle(media) },
            audio: { [unowned self] media in self.audioHandle(media) },
            plugin: { [unowned self] slot in self.pluginHandle(slot) })
        PlanCompiler.compile(project, handles: handles) { plan in
            vd_set_plan(engine, &plan)
        }
    }

    private func videoHandle(_ media: Media) -> Int32? {
        let path = playbackPath(media)
        if let known = videoHandles[path] { return known >= 0 ? known : nil }
        let handle = vd_video_open(engine, path)
        videoHandles[path] = handle
        return handle >= 0 ? handle : nil
    }

    /// The file the engine should decode for this media: its editing proxy once that
    /// exists, except while exporting, which always reads the original.
    private func playbackPath(_ media: Media) -> String {
        guard !useOriginals, let packageURL else { return media.path }
        let proxy = ProxyMaker.url(for: media.path, in: packageURL)
        if FileManager.default.fileExists(atPath: proxy.path) { return proxy.path }
        requestProxy(for: media.path, at: proxy)
        return media.path
    }

    private func requestProxy(for path: String, at proxy: URL) {
        guard makesProxies, !proxyPending.contains(path) else { return }
        proxyPending.insert(path)
        proxiesInProgress += 1
        proxyQueue.async { [weak self] in
            let made = ProxyMaker.needsProxy(path) && ProxyMaker.make(from: path, to: proxy)
            DispatchQueue.main.async {
                guard let self else { return }
                self.proxiesInProgress -= 1
                // A file that needs no proxy, or could not get one, stays in the pending
                // set so it is not tried again this session.
                if made {
                    self.proxyPending.remove(path)
                    self.compile()
                    self.onChange?()
                }
            }
        }
    }

    public func waitForProxies() async {
        while proxiesInProgress > 0 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func audioHandle(_ media: Media) -> Int32? {
        let path = media.path
        if let known = audioHandles[path] { return known >= 0 ? known : nil }
        guard !audioPending.contains(path) else { return nil }
        audioPending.insert(path)
        let engine = self.engine
        mediaQueue.async { [weak self] in
            let handle = vd_audio_open(engine, path)
            DispatchQueue.main.async {
                guard let self else { return }
                self.objectWillChange.send()
                self.audioHandles[path] = handle
                self.audioPending.remove(path)
                self.compile()
                self.onChange?()
            }
        }
        return nil
    }

    /// True while audio or plugins referenced by the project are still being opened.
    public var isLoading: Bool { !audioPending.isEmpty || !pluginPending.isEmpty }

    public func waitUntilLoaded() async {
        compile()
        while isLoading { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: Plugins

    private func pluginHandle(_ slot: EffectSlot) -> Int32? {
        if let known = plugins[slot.id] { return known >= 0 ? known : nil }
        guard let ref = slot.audioUnit, !pluginPending.contains(slot.id) else { return nil }
        pluginPending.insert(slot.id)
        let state = retiredPluginStates.removeValue(forKey: slot.id) ?? ref.state ?? Data()
        let box = Unmanaged.passRetained(Box<(Int32) -> Void> { [weak self] handle in
            guard let self else { return }
            self.objectWillChange.send()
            self.plugins[slot.id] = handle
            self.pluginPending.remove(slot.id)
            self.compile()
            self.onChange?()
        })
        state.withUnsafeBytes { bytes in
            vd_au_create(engine, ref.type, ref.subType, ref.manufacturer, bytes.baseAddress, Int32(state.count),
                         { ctx, handle in
                             Unmanaged<Box<(Int32) -> Void>>.fromOpaque(ctx!).takeRetainedValue().value(handle)
                         }, box.toOpaque())
        }
        return nil
    }

    private func pluginState(_ handle: Int32) -> Data? {
        var length: Int32 = 0
        guard let bytes = vd_au_copy_state(engine, handle, &length), length > 0 else { return nil }
        defer { vd_free(bytes) }
        return Data(bytes: bytes, count: Int(length))
    }

    /// Shuts down plugins whose slot has left the project, keeping their settings in case
    /// an undo brings the slot back.
    private func retirePlugins() {
        let live = Set(project.tracks.flatMap { $0.effects.map(\.id) })
        for (slotID, handle) in plugins where !live.contains(slotID) {
            if handle >= 0 {
                retiredPluginStates[slotID] = pluginState(handle)
                vd_au_destroy(engine, handle)
            }
            plugins[slotID] = nil
        }
    }

    /// Copies each plugin's current settings into the project, without an undo step.
    private func capturePluginStates() {
        var states: [UUID: Data] = [:]
        for (slotID, handle) in plugins where handle >= 0 { states[slotID] = pluginState(handle) }
        guard !states.isEmpty else { return }
        history.amend { project in
            for t in project.tracks.indices {
                for e in project.tracks[t].effects.indices {
                    if let state = states[project.tracks[t].effects[e].id] {
                        project.tracks[t].effects[e].audioUnit?.state = state
                    }
                }
            }
        }
    }

    public static func installedEffects() -> [AudioUnitRef] {
        var found: [AudioUnitRef] = []
        for type in [kAudioUnitType_Effect, kAudioUnitType_MusicEffect] {
            let description = AudioComponentDescription(componentType: type, componentSubType: 0,
                                                        componentManufacturer: 0, componentFlags: 0, componentFlagsMask: 0)
            for component in AVAudioUnitComponentManager.shared().components(matching: description) {
                let d = component.audioComponentDescription
                found.append(AudioUnitRef(type: d.componentType, subType: d.componentSubType,
                                          manufacturer: d.componentManufacturer,
                                          name: "\(component.manufacturerName): \(component.name)"))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func pluginParameters(slot: UUID) -> [PluginParameter] {
        guard let handle = plugins[slot], handle >= 0 else { return [] }
        var result: [PluginParameter] = []
        var name = [CChar](repeating: 0, count: 128)
        for index in 0..<vd_au_param_count(engine, handle) {
            var address: UInt64 = 0
            var low: Float = 0, high: Float = 0, value: Float = 0
            guard vd_au_param_info(engine, handle, index, &address, &name, Int32(name.count), &low, &high, &value),
                  high > low else { continue }
            result.append(PluginParameter(address: address, name: String(cString: name),
                                          range: Double(low)...Double(high), value: Double(value)))
        }
        return result
    }

    public func setPluginParameter(slot: UUID, address: UInt64, value: Double) {
        guard let handle = plugins[slot], handle >= 0 else { return }
        vd_au_set_param(engine, handle, address, Float(value))
    }

    public func pluginIsReady(slot: UUID) -> Bool { (plugins[slot] ?? -1) >= 0 }

    /// The plugin's own interface, or nil if it has none.
    public func pluginViewController(slot: UUID, completion: @escaping (NSViewController?) -> Void) {
        guard let handle = plugins[slot], handle >= 0 else { return completion(nil) }
        let box = Unmanaged.passRetained(Box(completion))
        vd_au_request_view(engine, handle, { ctx, controller in
            let done = Unmanaged<Box<(NSViewController?) -> Void>>.fromOpaque(ctx!).takeRetainedValue().value
            done(controller.map { Unmanaged<NSViewController>.fromOpaque($0).takeRetainedValue() })
        }, box.toOpaque())
    }

    // MARK: Meters

    /// The loudest sample an audio track has put out since this was last asked (1 = full scale).
    public func level(of track: UUID) -> Float { vd_track_level(engine, track.engineID) }
    public func masterLevel() -> Float { vd_track_level(engine, 0) }
    /// True while through-time picture bending is being worked out in the background.
    public var isBending: Bool { vd_bend_busy(engine) }

    // MARK: Transport

    public var isPlaying: Bool { vd_is_playing(engine) }
    public func play() { vd_play(engine) }
    public func stop() { vd_stop(engine) }
    public func togglePlay() { isPlaying ? stop() : play() }

    public var position: Ticks { project.ticks(samples: vd_position(engine)) }
    public func seek(to tick: Ticks) { vd_seek(engine, project.samples(max(0, tick))) }

    public func attach(layer: CAMetalLayer) {
        vd_attach_layer(engine, Unmanaged.passUnretained(layer).toOpaque())
    }

    // MARK: Media

    /// Places a file on the timeline at `tick` as one undo step. A video's picture and its
    /// soundtrack become separate regions. Each goes on the given track if it is the right
    /// kind, else on the first track of that kind with room, else on a new track.
    @discardableResult
    public func addFile(_ url: URL, at tick: Ticks, videoTrack: UUID? = nil, audioTrack: UUID? = nil) -> [UUID] {
        let path = url.path
        let asset = AVURLAsset(url: url)
        var picture: (duration: Double, width: Int32, height: Int32, fps: Double)?
        let handle = videoHandles[path] ?? vd_video_open(engine, path)
        videoHandles[path] = handle
        if handle >= 0 {
            var duration = 0.0, fps = 0.0
            var width: Int32 = 0, height: Int32 = 0
            if vd_video_info(engine, handle, &duration, &width, &height, &fps) {
                picture = (duration, width, height, fps)
            }
        }
        let sound = asset.tracks(withMediaType: .audio).first.map { CMTimeGetSeconds($0.timeRange.duration) }
        guard picture != nil || sound != nil else { return [] }

        return perform { project in
            var created: [UUID] = []
            let firstMedia = project.media.isEmpty

            func place(kind: TrackKind, seconds: Double, preferred: UUID?) {
                let media = project.media.first { $0.path == path && $0.kind == kind }
                    ?? Media(path: path, kind: kind, duration: project.flicks(seconds: seconds))
                project.addMedia(media)
                let length = project.ticks(seconds: seconds)
                var target = preferred.flatMap { id in project.track(id)?.kind == kind ? id : nil }
                if target == nil {
                    target = project.tracks.first { track in
                        track.kind == kind && !track.regions.contains { $0.start < tick + length && $0.end > tick }
                    }?.id
                }
                // New video tracks go in front; new audio tracks go to the bottom.
                let trackID = target ?? project.addTrack(kind: kind, at: kind == .video ? 0 : nil)
                if let id = project.addRegion(mediaID: media.id, trackID: trackID, at: tick) { created.append(id) }
            }

            if let picture {
                if firstMedia, picture.width > 0, picture.height > 0 {
                    project.width = Int(picture.width)
                    project.height = Int(picture.height)
                    if picture.fps > 0 { project.fps = picture.fps.rounded() == picture.fps ? picture.fps : (picture.fps * 100).rounded() / 100 }
                }
                place(kind: .video, seconds: picture.duration, preferred: videoTrack)
            }
            if let sound, sound > 0 { place(kind: .audio, seconds: sound, preferred: audioTrack) }
            // A video's picture and sound start out linked, so they move and cut together.
            project.link(Set(created))
            return created
        }
    }

    /// Waveform peaks across the whole media, or nil while they are being computed.
    public func peaks(for mediaID: UUID) -> [Float]? {
        if let cached = peakCache[mediaID] { return cached }
        guard let media = project.media(mediaID), !peakPending.contains(mediaID),
              let handle = audioHandle(media) else { return nil }
        peakPending.insert(mediaID)
        let engine = self.engine
        let count = min(20_000, max(200, Int(vd_audio_frames(engine, handle) / 480)))
        mediaQueue.async { [weak self] in
            var buffer = [Float](repeating: 0, count: count)
            vd_audio_peaks(engine, handle, &buffer, Int32(count))
            DispatchQueue.main.async {
                self?.peakCache[mediaID] = buffer
                self?.peakPending.remove(mediaID)
                self?.onChange?()
            }
        }
        return nil
    }

    /// A small still of the media near `seconds`, or nil while it is being made.
    public func thumbnail(for mediaID: UUID, at seconds: Double) -> CGImage? {
        guard let media = project.media(mediaID) else { return nil }
        let key = "\(media.path)|\(Int((seconds * 2).rounded()))"
        if let cached = thumbnailCache[key] { return cached }
        guard !thumbnailPending.contains(key) else { return nil }
        thumbnailPending.insert(key)
        let generator = generators[media.path] ?? {
            let made = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: media.path)))
            made.appliesPreferredTrackTransform = true
            made.maximumSize = CGSize(width: 240, height: 160)
            generators[media.path] = made
            return made
        }()
        thumbnailQueue.async { [weak self] in
            let image = try? generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
            DispatchQueue.main.async {
                guard let self else { return }
                self.thumbnailPending.remove(key)
                if let image {
                    self.thumbnailCache[key] = image
                    self.onChange?()
                }
            }
        }
        return nil
    }

    /// Media whose file is no longer where the project says it is.
    public var missingMedia: [Media] {
        project.media.filter { !FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Points a media item at a new file, then looks beside it for any other missing files.
    public func relink(_ mediaID: UUID, to url: URL) {
        let folder = url.deletingLastPathComponent()
        let missing = Set(missingMedia.map(\.id))
        perform { project in
            for index in project.media.indices {
                let item = project.media[index]
                if item.id == mediaID || project.media[index].path == project.media(mediaID)?.path {
                    project.media[index].path = url.path
                } else if missing.contains(item.id) {
                    let candidate = folder.appendingPathComponent(URL(fileURLWithPath: item.path).lastPathComponent)
                    if FileManager.default.fileExists(atPath: candidate.path) { project.media[index].path = candidate.path }
                }
            }
        }
    }

    // MARK: Export

    /// Renders the range (the whole timeline by default) to a movie. `completion` receives
    /// nil on success or a message describing what went wrong.
    public func export(to url: URL, range: Range<Ticks>? = nil, completion: @escaping (String?) -> Void) {
        let range = range ?? 0..<project.lengthTicks
        // The engine pins the plan when the export is asked for, so the originals only
        // need to be in the plan for that one call.
        useOriginals = true
        compile()
        defer {
            useOriginals = false
            compile()
        }
        exportProgress = 0
        typealias Callbacks = (progress: (Double) -> Void, done: (String?) -> Void)
        let box = Unmanaged.passRetained(Box<Callbacks>((
            progress: { [weak self] fraction in self?.exportProgress = fraction },
            done: { [weak self] error in
                self?.exportProgress = nil
                completion(error)
            })))
        vd_export(engine, url.path, project.samples(range.lowerBound), project.samples(range.upperBound),
                  { ctx, fraction in
                      Unmanaged<Box<Callbacks>>.fromOpaque(ctx!).takeUnretainedValue().value.progress(fraction)
                  },
                  { ctx, error in
                      let callbacks = Unmanaged<Box<Callbacks>>.fromOpaque(ctx!).takeRetainedValue().value
                      callbacks.done(error.map { String(cString: $0) })
                  }, box.toOpaque())
    }

    // MARK: Storage

    public static let packageExtension = "vdaw"
    private static let documentName = "project.json"

    /// Creates a new project folder at `url` and opens it.
    public static func create(at url: URL, realtime: Bool = true) throws -> Session {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var project = Project()
        project.name = url.deletingPathExtension().lastPathComponent
        let session = Session(project: project, packageURL: url, realtime: realtime)
        try session.save()
        return session
    }

    public static func open(_ url: URL, realtime: Bool = true) throws -> Session {
        let data = try Data(contentsOf: url.appendingPathComponent(documentName))
        let project = try JSONDecoder().decode(Project.self, from: data)
        return Session(project: project, packageURL: url, realtime: realtime)
    }

    public func save() throws {
        guard let packageURL else { return }
        saveWork?.cancel()
        capturePluginStates()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(project).write(to: packageURL.appendingPathComponent(Self.documentName), options: .atomic)
    }

    private func scheduleSave() {
        guard packageURL != nil else { return }
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in try? self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Copies every file the project uses into the project folder and points the project at
    /// the copies, so the folder can be moved or archived on its own.
    public func collectMedia() throws {
        guard let packageURL else { return }
        let folder = packageURL.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var moved: [String: String] = [:]
        for path in Set(project.media.map(\.path)) where !path.hasPrefix(folder.path) {
            let source = URL(fileURLWithPath: path)
            var target = folder.appendingPathComponent(source.lastPathComponent)
            var suffix = 2
            while FileManager.default.fileExists(atPath: target.path) {
                let name = source.deletingPathExtension().lastPathComponent + " \(suffix)"
                target = folder.appendingPathComponent(name).appendingPathExtension(source.pathExtension)
                suffix += 1
            }
            try FileManager.default.copyItem(at: source, to: target)
            moved[path] = target.path
        }
        perform { project in
            for index in project.media.indices {
                if let target = moved[project.media[index].path] { project.media[index].path = target }
            }
        }
        try save()
    }
}
