import AppKit
import Model
import QuartzCore
import Session
import SwiftUI

/// The composited picture. The engine draws into this view's Metal layer.
final class ViewerView: NSView {
    private let state: AppState

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.backgroundColor = NSColor.black.cgColor
        return layer
    }

    override func layout() {
        super.layout()
        attach()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        attach()
    }

    func attach() {
        guard let metal = layer as? CAMetalLayer, bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? 2
        metal.contentsScale = scale
        metal.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        state.session.attach(layer: metal)
    }

    /// The selected video track, if there is one to move around in the picture.
    private var movableTrack: Track? {
        state.selectedTrack.flatMap { state.project.track($0) }.flatMap { $0.kind == .video ? $0 : nil }
    }

    /// The size of the project's picture as shown, letterboxed inside this view.
    private var pictureSize: CGSize {
        let aspect = CGFloat(state.project.width) / CGFloat(max(1, state.project.height))
        return bounds.width / bounds.height > aspect
            ? CGSize(width: bounds.height * aspect, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / aspect)
    }

    // Dragging moves the selected video track's picture; pinching scales it.
    override func mouseDragged(with event: NSEvent) {
        guard let track = movableTrack else { return }
        let size = pictureSize
        state.session.performCoalescing(key: "viewer move") { project in
            project.setValue(.track(.x), track: track.id, track.param(.x).value + Double(event.deltaX / size.width))
            project.setValue(.track(.y), track: track.id, track.param(.y).value + Double(event.deltaY / size.height))
        }
    }

    override func mouseUp(with event: NSEvent) { state.session.endCoalescing() }

    override func magnify(with event: NSEvent) {
        guard let track = movableTrack else { return }
        state.session.performCoalescing(key: "viewer scale") { project in
            project.setValue(.track(.scale), track: track.id, track.param(.scale).value * Double(1 + event.magnification))
        }
        if event.phase == .ended || event.phase == .cancelled { state.session.endCoalescing() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var state: AppState!
    private var timeline: TimelineView!
    private var viewer: ViewerView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A project folder given on the command line opens (or is created) instead of the last project.
        let argument = CommandLine.arguments.dropFirst().first { $0.hasSuffix(".\(Session.packageExtension)") }
        let session = argument.flatMap { path -> Session? in
            let url = URL(fileURLWithPath: path)
            return (try? Session.open(url)) ?? (try? Session.create(at: url))
        } ?? AppState.startupSession()
        state = AppState(session: session)
        timeline = TimelineView(state: state)
        viewer = ViewerView(state: state)

        let transport = NSHostingView(rootView: TransportBar(state: state, clock: state.clock))
        let inspector = NSHostingView(rootView: InspectorView(state: state))

        let top = NSSplitView()
        top.isVertical = true
        top.dividerStyle = .thin
        top.addArrangedSubview(viewer)
        top.addArrangedSubview(inspector)
        top.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        top.setHoldingPriority(.defaultHigh, forSubviewAt: 1)

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(top)
        split.addArrangedSubview(timeline)

        let root = NSView()
        for view in [transport, split] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            transport.topAnchor.constraint(equalTo: root.topAnchor),
            transport.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            transport.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            transport.heightAnchor.constraint(equalToConstant: 44),
            split.topAnchor.constraint(equalTo: transport.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            inspector.widthAnchor.constraint(equalToConstant: 320),
        ])

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = root
        window.center()
        window.setFrameAutosaveName("VideoDAW Main")
        // A scripted capture stays behind whatever the person is working in.
        if DebugHooks.isCapturing { window.orderBack(nil) } else { window.makeKeyAndOrderFront(nil) }
        split.setPosition(430, ofDividerAt: 0)
        window.makeFirstResponder(timeline)
        retitle()

        state.onRedraw = { [weak self] in
            self?.timeline.followPlayhead()
            self?.timeline.needsDisplay = true
        }
        state.onSessionChange = { [weak self] in
            self?.viewer.attach()
            self?.retitle()
        }
        NSApp.mainMenu = buildMenu()
        if !DebugHooks.isCapturing { NSApp.activate(ignoringOtherApps: true) }
        if ProcessInfo.processInfo.environment["VIDEODAW_MIXER"] != nil { toggleMixer() }
        DebugHooks.run(state: state, window: window)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        state.session.stop()
        try? state.session.save()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard state != nil else { return false }
        state.open(URL(fileURLWithPath: filename))
        return true
    }

    private func retitle() {
        window.title = state.project.name
        window.representedURL = state.session.packageURL
    }

    // MARK: Menus

    private func buildMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let parent = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            parent.submenu = menu
            return parent
        }
        let main = NSMenu()
        main.addItem(menu("VideoDAW", [
            item("Hide VideoDAW", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("Quit VideoDAW", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("New Project…", #selector(newProject), "n"),
            item("Open Project…", #selector(openProject), "o"),
            .separator(),
            item("Import Media…", #selector(importMedia), "i"),
            item("Export Movie…", #selector(exportMovie), "e"),
            .separator(),
            item("Save", #selector(save), "s"),
            item("Collect Media into Project", #selector(collectMedia)),
            item("Locate Missing Media…", #selector(relinkMissing)),
        ]))
        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Duplicate", #selector(duplicate), "d"),
            item("Delete", #selector(NSText.delete(_:))),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Split at Playhead", #selector(splitAtPlayhead), "t"),
            item("Reverse", #selector(reverseSelection), "r"),
            item("Mute Region", #selector(toggleMute), "m"),
            .separator(),
            item("Nudge Left by Grid Division", #selector(nudgeLeft), "\u{F702}", [.option]),
            item("Nudge Right by Grid Division", #selector(nudgeRight), "\u{F703}", [.option]),
            item("Nudge Left by One Frame", #selector(nudgeLeftFrame), "\u{F702}", [.option, .shift]),
            item("Nudge Right by One Frame", #selector(nudgeRightFrame), "\u{F703}", [.option, .shift]),
            .separator(),
            item("Link Regions", #selector(linkRegions), "l"),
            item("Unlink Regions", #selector(unlinkRegions), "l", [.command, .shift]),
        ]))
        main.addItem(menu("Track", [
            item("New Video Track", #selector(newVideoTrack), "v", [.command, .option]),
            item("New Audio Track", #selector(newAudioTrack), "a", [.command, .option]),
            .separator(),
            item("Delete Track", #selector(deleteTrack), "\u{8}", [.command, .shift]),
        ]))
        main.addItem(menu("Window", [
            item("Mixer", #selector(toggleMixer), "2"),
        ]))
        return main
    }

    @objc func undo(_ sender: Any?) { state.session.undo() }
    @objc func redo(_ sender: Any?) { state.session.redo() }
    @objc private func newProject() { state.newProject() }
    @objc private func openProject() { state.openProject() }
    @objc private func importMedia() { state.importMedia() }
    @objc private func exportMovie() { state.exportMovie() }
    @objc private func save() { try? state.session.save() }
    @objc private func collectMedia() { state.collectMedia() }
    @objc private func relinkMissing() { state.relinkMissing() }
    @objc private func duplicate() { state.duplicate() }
    @objc private func splitAtPlayhead() { state.splitAtPlayhead() }
    @objc private func reverseSelection() { state.reverseSelection() }
    @objc private func toggleMute() { state.toggleMuteSelection() }
    @objc private func newVideoTrack() { state.addTrack(.video) }
    @objc private func newAudioTrack() { state.addTrack(.audio) }
    @objc private func deleteTrack() { state.deleteSelectedTrack() }
    @objc private func nudgeLeft() { state.nudgeSelection(by: -state.project.gridTicks(state.division)) }
    @objc private func nudgeRight() { state.nudgeSelection(by: state.project.gridTicks(state.division)) }
    @objc private func nudgeLeftFrame() { state.nudgeSelection(by: -state.project.frameTicks) }
    @objc private func nudgeRightFrame() { state.nudgeSelection(by: state.project.frameTicks) }
    @objc private func linkRegions() { state.linkSelection() }
    @objc private func unlinkRegions() { state.unlinkSelection() }

    @objc private func toggleMixer() {
        if let mixer = state.mixerWindow {
            if mixer.isVisible { mixer.orderOut(nil) } else { mixer.makeKeyAndOrderFront(nil) }
            return
        }
        let mixer = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        mixer.title = "Mixer"
        mixer.appearance = NSAppearance(named: .darkAqua)
        mixer.isReleasedWhenClosed = false
        mixer.contentView = NSHostingView(rootView: MixerView(state: state, meters: state.meters))
        mixer.setFrameAutosaveName("VideoDAW Mixer")
        state.mixerWindow = mixer
        if DebugHooks.isCapturing { mixer.orderBack(nil) } else { mixer.makeKeyAndOrderFront(nil) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
