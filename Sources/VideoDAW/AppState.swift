import AppKit
import Combine
import Model
import Session
import UniformTypeIdentifiers

enum Tool: String, CaseIterable {
    case pointer, marquee
}

/// A time range across some tracks, made with the marquee tool.
struct MarqueeSelection: Equatable {
    var range: Range<Ticks>
    var tracks: Set<UUID>
}

/// The playhead, published separately so only the views that show it redraw as it moves.
final class Clock: ObservableObject {
    @Published var playhead: Ticks = 0
    @Published var isPlaying = false
    /// Through-time bending is still being worked out in the background.
    @Published var isBending = false
}

/// Track output levels for the mixer, 0...1 on a decibel scale, falling back smoothly.
final class Meters: ObservableObject {
    @Published var levels: [UUID: Double] = [:]
    @Published var master: Double = 0

    /// Maps a linear peak to meter height: -60 dB and below is empty, full scale is full.
    static func height(_ peak: Float) -> Double {
        peak <= 0.001 ? 0 : min(1, max(0, (20 * log10(Double(peak)) + 60) / 60))
    }
}

/// What the interface shares: the open session, what is selected, and the editing commands.
final class AppState: ObservableObject {
    @Published private(set) var session: Session
    /// Selecting a region selects everything linked to it, so linked regions are always
    /// moved, cut and deleted together.
    @Published var selection: Set<UUID> = [] {
        didSet {
            let whole = project.linkedRegions(selection)
            if whole != selection { selection = whole }
        }
    }
    @Published var selectedTrack: UUID?
    @Published var tool: Tool = .pointer
    @Published var snapOn = true
    @Published var division: GridDivision = .beat
    @Published var marquee: MarqueeSelection?
    let clock = Clock()
    let meters = Meters()
    /// The mixer window, once it has been opened. Meters are only read while it shows.
    var mixerWindow: NSWindow?

    /// Asks the timeline to redraw.
    var onRedraw: (() -> Void)?
    /// Called when a different project has been opened.
    var onSessionChange: (() -> Void)?

    private var clipboard = Clipboard()
    private var sessionSink: AnyCancellable?
    private var timer: Timer?
    private var pluginWindows: [UUID: NSWindow] = [:]

    var project: Project { session.project }

    init(session: Session) {
        self.session = session
        adopt(session)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func adopt(_ session: Session) {
        sessionSink = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        session.onChange = { [weak self] in
            self?.pruneSelection()
            self?.onRedraw?()
        }
    }

    func use(_ session: Session) {
        self.session.stop()
        try? self.session.save()
        pluginWindows.values.forEach { $0.close() }
        pluginWindows.removeAll()
        selection = []
        selectedTrack = nil
        marquee = nil
        self.session = session
        adopt(session)
        UserDefaults.standard.set(session.packageURL?.path, forKey: "lastProject")
        onSessionChange?()
        onRedraw?()
    }

    private func tick() {
        let position = session.position, playing = session.isPlaying
        if playing != clock.isPlaying { clock.isPlaying = playing }
        if position != clock.playhead {
            clock.playhead = position
            onRedraw?()
        }
        let bending = session.isBending
        if bending != clock.isBending { clock.isBending = bending }
        if mixerWindow?.isVisible == true {
            var levels: [UUID: Double] = [:]
            for track in project.tracks where track.kind == .audio {
                levels[track.id] = max(Meters.height(session.level(of: track.id)), (meters.levels[track.id] ?? 0) - 0.04)
            }
            let master = max(Meters.height(session.masterLevel()), meters.master - 0.04)
            if levels != meters.levels { meters.levels = levels }
            if master != meters.master { meters.master = master }
        }
    }

    private func pruneSelection() {
        let live = Set(project.tracks.flatMap { $0.regions.map(\.id) })
        if !selection.isSubset(of: live) { selection.formIntersection(live) }
        if let track = selectedTrack, project.track(track) == nil { selectedTrack = nil }
    }

    /// The grid position nearest `tick`, unless snapping is off or bypassed.
    func snap(_ tick: Ticks, bypass: Bool = false) -> Ticks {
        snapOn && !bypass ? project.snap(tick, to: division) : max(0, tick)
    }

    // MARK: Editing commands

    /// Turns a marquee into a selection of the pieces inside it, splitting at its edges.
    @discardableResult
    func commitMarquee() -> Set<UUID> {
        guard let marquee else { return selection }
        let inside = session.perform { $0.splitRange(marquee.range, trackIDs: marquee.tracks) }
        self.marquee = nil
        selection = inside
        return inside
    }

    func deleteSelection() {
        if let marquee {
            session.perform { $0.deleteRange(marquee.range, trackIDs: marquee.tracks) }
            self.marquee = nil
        } else if !selection.isEmpty {
            let doomed = selection
            session.perform { $0.deleteRegions(doomed) }
        }
    }

    func splitAtPlayhead() {
        let at = session.position
        let targets = selection.isEmpty ? Set(project.tracks.flatMap { $0.regions.map(\.id) }) : selection
        session.perform { _ = $0.split(targets, at: at) }
    }

    func copy() {
        let ids = commitMarquee()
        clipboard = project.copyRegions(ids)
    }

    func cut() {
        copy()
        deleteSelection()
    }

    func paste() {
        guard !clipboard.isEmpty else { return }
        let at = session.position, clip = clipboard
        selection = Set(session.perform { $0.paste(clip, at: at) })
    }

    func duplicate() {
        let ids = commitMarquee()
        guard !ids.isEmpty else { return }
        selection = Set(session.perform { $0.duplicate(ids) })
    }

    func selectAll() {
        marquee = nil
        selection = Set(project.tracks.flatMap { $0.regions.map(\.id) })
    }

    func reverseSelection() {
        let ids = commitMarquee()
        session.perform { $0.reverse(ids) }
    }

    func toggleMuteSelection() {
        let ids = commitMarquee()
        let anyAudible = ids.contains { project.region($0)?.muted == false }
        session.perform { $0.setRegionMuted(ids, anyAudible) }
    }

    /// Moves the selection in time by a small step, off the grid if need be.
    func nudgeSelection(by ticks: Ticks) {
        let ids = commitMarquee()
        guard !ids.isEmpty else { return }
        session.perform { $0.moveRegions(ids, deltaTicks: ticks, deltaTracks: 0) }
    }

    /// Ties the selected regions together so they are edited as one.
    func linkSelection() {
        let ids = selection
        session.perform { $0.link(ids) }
        selection = ids
    }

    /// Frees the selected regions from each other, as when a video's sound should go its own way.
    func unlinkSelection() {
        let ids = selection
        session.perform { $0.unlink(ids) }
    }

    func addTrack(_ kind: TrackKind) {
        selectedTrack = session.perform { $0.addTrack(kind: kind, at: kind == .video ? 0 : nil) }
    }

    func deleteSelectedTrack() {
        guard let track = selectedTrack else { return }
        session.perform { $0.removeTrack(track) }
    }

    func toggleCycle() {
        session.perform { $0.cycleOn.toggle() }
    }

    // MARK: Files

    private static var projectsFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("VideoDAW")
    }

    /// Reopens the last project, or starts an untitled one in Movies/VideoDAW.
    static func startupSession() -> Session {
        if let path = UserDefaults.standard.string(forKey: "lastProject"),
           let session = try? Session.open(URL(fileURLWithPath: path)) {
            return session
        }
        var index = 1
        var url = projectsFolder.appendingPathComponent("Untitled.\(Session.packageExtension)")
        while FileManager.default.fileExists(atPath: url.path) {
            index += 1
            url = projectsFolder.appendingPathComponent("Untitled \(index).\(Session.packageExtension)")
        }
        if let session = try? Session.create(at: url) {
            UserDefaults.standard.set(url.path, forKey: "lastProject")
            return session
        }
        return Session()
    }

    func newProject() {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.nameFieldStringValue = "Untitled.\(Session.packageExtension)"
        panel.directoryURL = Self.projectsFolder
        try? FileManager.default.createDirectory(at: Self.projectsFolder, withIntermediateDirectories: true)
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension != Session.packageExtension { url.appendPathExtension(Session.packageExtension) }
        do { use(try Session.create(at: url)) } catch { report(error.localizedDescription) }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.title = "Open Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = Self.projectsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do { use(try Session.open(url)) } catch { report("That folder is not a VideoDAW project.") }
    }

    func importMedia() {
        let panel = NSOpenPanel()
        panel.title = "Import Media"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio]
        guard panel.runModal() == .OK else { return }
        add(files: panel.urls, at: session.position, videoTrack: nil, audioTrack: nil)
    }

    /// Adds files one after another starting at `tick`.
    func add(files: [URL], at tick: Ticks, videoTrack: UUID?, audioTrack: UUID?) {
        var at = tick
        var added: [UUID] = []
        for url in files {
            let ids = session.addFile(url, at: at, videoTrack: videoTrack, audioTrack: audioTrack)
            added += ids
            if let end = ids.compactMap({ project.region($0)?.end }).max() { at = end }
        }
        if added.isEmpty, !files.isEmpty { report("None of those files contain video or audio that can be read.") }
        selection = Set(added)
    }

    func exportMovie() {
        guard project.lengthTicks > 0 else { return report("There is nothing on the timeline to export.") }
        let panel = NSSavePanel()
        panel.title = "Export Movie"
        panel.nameFieldStringValue = "\(project.name).mov"
        panel.allowedContentTypes = [.quickTimeMovie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let range: Range<Ticks>? = project.cycleOn && project.cycleEnd > project.cycleStart
            ? project.cycleStart..<project.cycleEnd : nil
        session.stop()
        Task { @MainActor in
            await session.waitUntilLoaded()
            session.export(to: url, range: range) { [weak self] error in
                if let error { self?.report("The export failed: \(error)") }
                else { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
    }

    func collectMedia() {
        do { try session.collectMedia() } catch { report(error.localizedDescription) }
    }

    func relinkMissing() {
        guard let first = session.missingMedia.first else { return report("No media is missing.") }
        let panel = NSOpenPanel()
        panel.title = "Locate \(URL(fileURLWithPath: first.path).lastPathComponent)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        session.relink(first.id, to: url)
    }

    func report(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }

    // MARK: Plugin windows

    func openPluginWindow(slot: UUID, title: String) {
        if let window = pluginWindows[slot] { return window.makeKeyAndOrderFront(nil) }
        session.pluginViewController(slot: slot) { [weak self] controller in
            guard let self else { return }
            guard let controller else { return self.report("\(title) has no window of its own. Its parameters can still be automated.") }
            let window = NSWindow(contentViewController: controller)
            window.title = title
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.pluginWindows[slot] = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    func closePluginWindow(slot: UUID) {
        pluginWindows.removeValue(forKey: slot)?.close()
    }
}
