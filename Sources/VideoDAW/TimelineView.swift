import AppKit
import Model
import Session

/// The arrange area: ruler, track headers, lanes, regions and automation, drawn and
/// hit-tested by hand. Every gesture becomes an edit on the project model.
final class TimelineView: NSView {
    private let state: AppState

    private var pixelsPerBeat: CGFloat = 36
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0

    private let headerWidth: CGFloat = 200
    private let rulerHeight: CGFloat = 34
    private let cycleStripHeight: CGFloat = 12
    private let trackHeight: CGFloat = 72
    private let automationHeight: CGFloat = 64
    private let edge: CGFloat = 7

    private enum Zone { case body, left, right, loop, fadeIn, fadeOut }
    private enum HeaderButton { case none, mute, solo, automation }
    private enum Hit {
        case none
        case ruler(cycleStrip: Bool)
        case header(row: Int, button: HeaderButton)
        case region(id: UUID, zone: Zone, row: Int)
        case automation(row: Int)
        case lane(row: Int)
    }
    private enum Drag {
        case none
        case seek
        case cycle(anchor: Ticks, moved: Bool)
        case move(anchor: UUID, grab: Ticks, startRow: Int)
        case trimStart(UUID), trimEnd(UUID), loop(UUID)
        case stretch(UUID, anchorEnd: Bool)
        case fadeIn(UUID), fadeOut(UUID)
        case rubber(origin: CGPoint, keep: Set<UUID>)
        case marquee(anchor: Ticks, row: Int)
        case point(track: UUID, path: ParamPath, index: Int)
    }
    private var drag = Drag.none
    private var base = Project()
    private var rubber: CGRect?

    private var project: Project { state.project }
    private var session: Session { state.session }

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    private struct Row {
        var track: Track
        var index: Int
        var y: CGFloat
        var automationY: CGFloat?
    }

    private func rows() -> [Row] {
        var y = rulerHeight - scrollY
        return project.tracks.enumerated().map { index, track in
            let row = Row(track: track, index: index, y: y,
                          automationY: track.automationShown == nil ? nil : y + trackHeight)
            y += trackHeight + (track.automationShown == nil ? 0 : automationHeight)
            return row
        }
    }

    private func x(_ tick: Ticks) -> CGFloat {
        headerWidth + CGFloat(tick) / CGFloat(ticksPerBeat) * pixelsPerBeat - scrollX
    }

    private func tick(_ x: CGFloat) -> Ticks {
        max(0, Ticks(((x - headerWidth + scrollX) / pixelsPerBeat * CGFloat(ticksPerBeat)).rounded()))
    }

    private func rect(_ region: Region, in row: Row) -> CGRect {
        CGRect(x: x(region.start), y: row.y + 3, width: max(2, x(region.end) - x(region.start)), height: trackHeight - 6)
    }

    private func row(atY y: CGFloat) -> Row? {
        rows().first { y >= $0.y && y < $0.y + trackHeight + ($0.automationY == nil ? 0 : automationHeight) }
    }

    private func automationRect(_ row: Row) -> CGRect? {
        row.automationY.map { CGRect(x: headerWidth, y: $0, width: bounds.width - headerWidth, height: automationHeight) }
    }

    private func valueY(_ value: Double, range: ClosedRange<Double>, lane: CGRect) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        let fraction = span > 0 ? (value - range.lowerBound) / span : 0
        return lane.maxY - 8 - CGFloat(fraction) * (lane.height - 16)
    }

    private func value(atY y: CGFloat, range: ClosedRange<Double>, lane: CGRect) -> Double {
        let fraction = Double((lane.maxY - 8 - y) / (lane.height - 16))
        return range.lowerBound + min(1, max(0, fraction)) * (range.upperBound - range.lowerBound)
    }

    private func headerButtons(_ row: Row) -> [(HeaderButton, CGRect)] {
        [(.mute, CGRect(x: headerWidth - 84, y: row.y + 10, width: 22, height: 18)),
         (.solo, CGRect(x: headerWidth - 58, y: row.y + 10, width: 22, height: 18)),
         (.automation, CGRect(x: headerWidth - 32, y: row.y + 10, width: 22, height: 18))]
    }

    private func hit(at p: CGPoint) -> Hit {
        if p.y < rulerHeight { return p.x >= headerWidth ? .ruler(cycleStrip: p.y < cycleStripHeight) : .none }
        guard let row = row(atY: p.y) else { return .none }
        if p.x < headerWidth {
            let button = headerButtons(row).first { $0.1.contains(p) }?.0 ?? .none
            return .header(row: row.index, button: button)
        }
        if let lane = automationRect(row), lane.contains(p) { return .automation(row: row.index) }
        // Later regions are drawn on top, so they are hit first.
        for region in row.track.regions.sorted(by: { $0.start > $1.start }) {
            let r = rect(region, in: row)
            guard r.contains(p) else { continue }
            var zone = Zone.body
            if r.width >= 24 {
                if p.x - r.minX < edge { zone = .left }
                else if r.maxX - p.x < edge { zone = p.y < r.minY + r.height * 0.4 ? .loop : .right }
            }
            if zone == .body, r.width >= 44, p.y < r.minY + 14 {
                let fadeInX = x(region.start + region.fadeIn), fadeOutX = x(region.end - region.fadeOut)
                if abs(p.x - (fadeInX + 8)) < 8 { zone = .fadeIn }
                else if abs(p.x - (fadeOutX - 8)) < 8 { zone = .fadeOut }
            }
            return .region(id: region.id, zone: zone, row: row.index)
        }
        return .lane(row: row.index)
    }

    // MARK: Drawing

    private let videoColor = NSColor(calibratedRed: 0.27, green: 0.47, blue: 0.75, alpha: 1)
    private let audioColor = NSColor(calibratedRed: 0.25, green: 0.60, blue: 0.42, alpha: 1)
    private let smallFont = NSFont.systemFont(ofSize: 10)
    private let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    private func text(_ string: String, at point: CGPoint, color: NSColor = .white, font: NSFont? = nil) {
        (string as NSString).draw(at: point, withAttributes: [.font: font ?? smallFont, .foregroundColor: color])
    }

    /// How many regions carry each link, so only regions that still have a partner are marked.
    private var linkCounts: [UUID: Int] = [:]

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rows = rows()
        linkCounts = [:]
        for region in project.tracks.flatMap(\.regions) { if let link = region.link { linkCounts[link, default: 0] += 1 } }
        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        bounds.fill()

        ctx.saveGState()
        ctx.clip(to: CGRect(x: headerWidth, y: rulerHeight, width: bounds.width - headerWidth, height: bounds.height - rulerHeight))
        for row in rows {
            NSColor(calibratedWhite: row.index % 2 == 0 ? 0.14 : 0.125, alpha: 1).setFill()
            CGRect(x: headerWidth, y: row.y, width: bounds.width, height: trackHeight).fill()
            if let lane = automationRect(row) {
                NSColor(calibratedWhite: 0.09, alpha: 1).setFill()
                lane.fill()
            }
        }
        drawGrid(ctx, top: rulerHeight, bottom: bounds.height)
        for row in rows {
            for region in row.track.regions.sorted(by: { $0.start < $1.start }) { draw(region, in: row, ctx) }
            if let lane = automationRect(row) { drawAutomation(row, lane, ctx) }
        }
        if let marquee = state.marquee {
            for row in rows where marquee.tracks.contains(row.track.id) {
                let r = CGRect(x: x(marquee.range.lowerBound), y: row.y,
                               width: x(marquee.range.upperBound) - x(marquee.range.lowerBound), height: trackHeight)
                NSColor(calibratedWhite: 1, alpha: 0.22).setFill()
                r.fill()
                NSColor(calibratedWhite: 1, alpha: 0.8).setStroke()
                NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
        if let rubber {
            NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
            rubber.fill()
            NSColor(calibratedWhite: 1, alpha: 0.5).setStroke()
            NSBezierPath(rect: rubber).stroke()
        }
        ctx.restoreGState()

        drawRuler(ctx)
        for row in rows { drawHeader(row) }

        NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: headerWidth, height: rulerHeight).fill()
        text(positionLabel(), at: CGPoint(x: 10, y: 10), font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium))

        let playheadX = x(state.clock.playhead)
        if playheadX >= headerWidth {
            NSColor.white.setFill()
            CGRect(x: playheadX - 0.5, y: 0, width: 1, height: bounds.height).fill()
        }
        if project.tracks.isEmpty {
            text("Drop video or audio files here", at: CGPoint(x: headerWidth + 24, y: rulerHeight + 24),
                 color: NSColor(calibratedWhite: 0.6, alpha: 1), font: NSFont.systemFont(ofSize: 14))
        }
    }

    private func positionLabel() -> String {
        let tick = state.clock.playhead
        let at = project.position(at: tick)
        let seconds = project.seconds(tick)
        // Bar, beat, and sixteenth of the beat, then minutes and seconds.
        return String(format: "%d.%d.%d   %d:%05.2f", at.bar, at.beat, Int(at.ticks * 4 / project.beatTicks) + 1,
                      Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    /// Lines for measures and beats of the time signature, and for the snap division when
    /// it is finer than a beat and there is room.
    private func drawGrid(_ ctx: CGContext, top: CGFloat, bottom: CGFloat) {
        let beat = project.beatTicks
        let beatPixels = pixelsPerBeat * CGFloat(beat) / CGFloat(ticksPerBeat)
        let first = tick(headerWidth) / beat, last = tick(bounds.width) / beat + 1
        let step = project.gridTicks(state.division)
        if step < beat, beatPixels * CGFloat(step) / CGFloat(beat) >= 8 {
            NSColor(calibratedWhite: 1, alpha: 0.035).setFill()
            var t = first * beat
            while t <= last * beat {
                CGRect(x: x(t), y: top, width: 1, height: bottom - top).fill()
                t += step
            }
        }
        for index in first...max(first, last) {
            let isBar = index % Ticks(project.beatsPerBar) == 0
            guard isBar || beatPixels >= 12 else { continue }
            NSColor(calibratedWhite: 1, alpha: isBar ? 0.16 : 0.07).setFill()
            CGRect(x: x(index * beat), y: top, width: 1, height: bottom - top).fill()
        }
    }

    private func drawRuler(_ ctx: CGContext) {
        NSColor(calibratedWhite: 0.17, alpha: 1).setFill()
        CGRect(x: headerWidth, y: 0, width: bounds.width - headerWidth, height: rulerHeight).fill()
        ctx.saveGState()
        ctx.clip(to: CGRect(x: headerWidth, y: 0, width: bounds.width - headerWidth, height: rulerHeight))
        let cycle = CGRect(x: x(project.cycleStart), y: 0, width: x(project.cycleEnd) - x(project.cycleStart), height: cycleStripHeight)
        (project.cycleOn ? NSColor.systemYellow : NSColor(calibratedWhite: 0.35, alpha: 1)).setFill()
        cycle.fill()
        let bar = project.barTicks, beat = project.beatTicks
        let barPixels = pixelsPerBeat * CGFloat(bar) / CGFloat(ticksPerBeat)
        var every: Ticks = 1
        while barPixels * CGFloat(every) < 44 { every *= 2 }
        let firstBar = tick(headerWidth) / bar, lastBar = tick(bounds.width) / bar + 1
        for index in firstBar...max(firstBar, lastBar) {
            let barX = x(index * bar)
            NSColor(calibratedWhite: 1, alpha: 0.4).setFill()
            CGRect(x: barX, y: rulerHeight - 10, width: 1, height: 10).fill()
            if index % every == 0 { text("\(index + 1)", at: CGPoint(x: barX + 4, y: cycleStripHeight + 3), color: NSColor(calibratedWhite: 0.85, alpha: 1)) }
            // Beats inside the measure get short ticks when there is room.
            if barPixels / CGFloat(project.beatsPerBar) >= 12 {
                NSColor(calibratedWhite: 1, alpha: 0.22).setFill()
                for inner in 1..<max(1, project.beatsPerBar) {
                    CGRect(x: x(index * bar + Ticks(inner) * beat), y: rulerHeight - 5, width: 1, height: 5).fill()
                }
            }
        }
        ctx.restoreGState()
    }

    private func drawHeader(_ row: Row) {
        let selected = state.selectedTrack == row.track.id
        let height = trackHeight + (row.automationY == nil ? 0 : automationHeight)
        NSColor(calibratedWhite: selected ? 0.24 : 0.17, alpha: 1).setFill()
        CGRect(x: 0, y: row.y, width: headerWidth, height: height).fill()
        (row.track.kind == .video ? videoColor : audioColor).setFill()
        CGRect(x: 0, y: row.y, width: 4, height: height).fill()
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        CGRect(x: 0, y: row.y + height - 1, width: bounds.width, height: 1).fill()
        text(row.track.name, at: CGPoint(x: 12, y: row.y + 10), font: labelFont)
        text(row.track.kind == .video ? "video" : "audio", at: CGPoint(x: 12, y: row.y + 28),
             color: NSColor(calibratedWhite: 0.6, alpha: 1))
        let lit: [HeaderButton: (Bool, String, NSColor)] = [
            .mute: (row.track.muted, "M", .systemOrange), .solo: (row.track.solo, "S", .systemYellow),
            .automation: (row.track.automationShown != nil, "A", .systemTeal)]
        for (button, r) in headerButtons(row) {
            guard let (on, label, color) = lit[button] else { continue }
            (on ? color : NSColor(calibratedWhite: 0.3, alpha: 1)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            text(label, at: CGPoint(x: r.minX + 7, y: r.minY + 3), color: on ? .black : .white, font: labelFont)
        }
        if let path = row.track.automationShown, let y = row.automationY {
            text(state.paramName(path, track: row.track), at: CGPoint(x: 12, y: y + 8),
                 color: NSColor.systemTeal)
        }
    }

    private func draw(_ region: Region, in row: Row, _ ctx: CGContext) {
        let r = rect(region, in: row)
        guard r.maxX >= headerWidth, r.minX <= bounds.width else { return }
        let selected = state.selection.contains(region.id)
        let color = row.track.kind == .video ? videoColor : audioColor
        let shape = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        ctx.saveGState()
        shape.addClip()
        color.withAlphaComponent(region.muted ? 0.3 : 0.9).setFill()
        r.fill()

        let content = CGRect(x: r.minX, y: r.minY + 15, width: r.width, height: r.height - 15)
        let visible = content.intersection(CGRect(x: headerWidth, y: content.minY, width: bounds.width - headerWidth, height: content.height))
        if !visible.isEmpty, let media = project.media(region.mediaID) {
            if row.track.kind == .video { drawThumbnails(region, media, content, visible, ctx) }
            else { drawWaveform(region, media, content, visible, ctx) }
        }
        if region.muted {
            NSColor(calibratedWhite: 0.1, alpha: 0.55).setFill()
            content.fill()
        }

        // Loop repetitions are marked where each one starts.
        if region.isLooped {
            NSColor(calibratedWhite: 0, alpha: 0.45).setFill()
            var t = region.start + region.contentLength
            while t < region.end {
                CGRect(x: x(t) - 1, y: r.minY, width: 2, height: r.height).fill()
                t += region.contentLength
            }
        }
        // Fades, including the ones an overlap produces.
        let fades = row.track.resolvedFades()[region.id]
        let fadeIn = max(region.fadeIn, fades?.fadeIn ?? 0), fadeOut = max(region.fadeOut, fades?.fadeOut ?? 0)
        NSColor(calibratedWhite: 0, alpha: 0.45).setFill()
        if fadeIn > 0 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: r.minX, y: r.minY))
            path.line(to: CGPoint(x: x(region.start + fadeIn), y: r.minY))
            path.line(to: CGPoint(x: r.minX, y: r.maxY))
            path.close()
            path.fill()
        }
        if fadeOut > 0 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: r.maxX, y: r.minY))
            path.line(to: CGPoint(x: x(region.end - fadeOut), y: r.minY))
            path.line(to: CGPoint(x: r.maxX, y: r.maxY))
            path.close()
            path.fill()
        }
        var title = region.name
        if let link = region.link, linkCounts[link, default: 0] > 1 { title = "∞ " + title }
        if region.reversed { title = "◀ " + title }
        if abs(region.speed - 1) > 0.001 { title += String(format: "  %.0f%%", region.speed * 100) }
        text(title, at: CGPoint(x: max(r.minX, headerWidth) + (selected ? 16 : 5), y: r.minY + 1), font: smallFont)
        ctx.restoreGState()

        if selected, r.width >= 44 {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: CGRect(x: x(region.start + region.fadeIn) + 4, y: r.minY + 3, width: 8, height: 8)).fill()
            NSBezierPath(ovalIn: CGRect(x: x(region.end - region.fadeOut) - 12, y: r.minY + 3, width: 8, height: 8)).fill()
        }
        (selected ? NSColor.white : NSColor(calibratedWhite: 0, alpha: 0.5)).setStroke()
        shape.lineWidth = selected ? 2 : 1
        shape.stroke()
    }

    private func drawThumbnails(_ region: Region, _ media: Media, _ content: CGRect, _ visible: CGRect, _ ctx: CGContext) {
        let tileWidth = max(24, content.height * CGFloat(project.width) / CGFloat(max(1, project.height)))
        var tileX = content.minX + floor((visible.minX - content.minX) / tileWidth) * tileWidth
        while tileX < visible.maxX {
            let at = min(max(tick(tileX), region.start), region.end - 1)
            if let flicks = project.sourceFlicks(of: region, at: at) {
                // Stills are shared between nearby tiles by rounding to half seconds.
                let seconds = (project.seconds(flicks: flicks) * 2).rounded() / 2
                if let image = session.thumbnail(for: media.id, at: seconds) {
                    let tile = CGRect(x: tileX, y: content.minY, width: tileWidth, height: content.height)
                    ctx.saveGState()
                    ctx.translateBy(x: 0, y: tile.maxY + tile.minY)
                    ctx.scaleBy(x: 1, y: -1)
                    ctx.draw(image, in: tile)
                    ctx.restoreGState()
                }
            }
            tileX += tileWidth
        }
    }

    private func drawWaveform(_ region: Region, _ media: Media, _ content: CGRect, _ visible: CGRect, _ ctx: CGContext) {
        guard let peaks = session.peaks(for: media.id), !peaks.isEmpty, media.duration > 0 else { return }
        let path = CGMutablePath()
        let middle = content.midY, half = content.height / 2 - 2
        var px = visible.minX.rounded(.down)
        while px < visible.maxX {
            let at = min(max(tick(px), region.start), region.end - 1)
            if let flicks = project.sourceFlicks(of: region, at: at) {
                let fraction = Double(flicks) / Double(media.duration)
                let index = min(peaks.count - 1, max(0, Int(fraction * Double(peaks.count))))
                let height = max(0.5, CGFloat(peaks[index]) * half)
                path.move(to: CGPoint(x: px + 0.5, y: middle - height))
                path.addLine(to: CGPoint(x: px + 0.5, y: middle + height))
            }
            px += 1
        }
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.75).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
    }

    private func drawAutomation(_ row: Row, _ lane: CGRect, _ ctx: CGContext) {
        guard let path = row.track.automationShown else { return }
        let range = state.paramRange(path, track: row.track)
        let param = project.param(path, track: row.track.id) ?? Param(range.lowerBound)
        let line = NSBezierPath()
        if param.points.isEmpty {
            let y = valueY(param.value, range: range, lane: lane)
            line.move(to: CGPoint(x: lane.minX, y: y))
            line.line(to: CGPoint(x: lane.maxX, y: y))
            NSColor.systemTeal.withAlphaComponent(0.45).setStroke()
        } else {
            let first = param.points[0], last = param.points[param.points.count - 1]
            line.move(to: CGPoint(x: lane.minX, y: valueY(first.value, range: range, lane: lane)))
            for point in param.points { line.line(to: CGPoint(x: x(point.tick), y: valueY(point.value, range: range, lane: lane))) }
            line.line(to: CGPoint(x: lane.maxX, y: valueY(last.value, range: range, lane: lane)))
            NSColor.systemTeal.setStroke()
        }
        line.lineWidth = 1.5
        line.stroke()
        NSColor.systemTeal.setFill()
        for point in param.points {
            let c = CGPoint(x: x(point.tick), y: valueY(point.value, range: range, lane: lane))
            NSBezierPath(ovalIn: CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)).fill()
        }
    }

    // MARK: Mouse

    private func marqueeContains(_ p: CGPoint) -> Bool {
        guard let marquee = state.marquee, let row = row(atY: p.y), p.y < row.y + trackHeight else { return false }
        return marquee.tracks.contains(row.track.id) && marquee.range.contains(tick(p.x))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        let marqueeMode = state.tool == .marquee || flags.contains(.command)
        base = project
        drag = .none
        let target = hit(at: p)

        // Dragging inside a marquee lifts that section out as its own regions.
        if !marqueeMode, marqueeContains(p), let row = row(atY: p.y) {
            let ids = state.commitMarquee()
            base = project
            let under = project.tracks[row.index].regions.first { ids.contains($0.id) && $0.start <= tick(p.x) && $0.end > tick(p.x) }
            if let anchor = under?.id ?? ids.first { drag = .move(anchor: anchor, grab: tick(p.x), startRow: row.index) }
            needsDisplay = true
            return
        }

        switch target {
        case .none:
            break
        case .ruler(let cycleStrip):
            if cycleStrip {
                drag = .cycle(anchor: state.snap(tick(p.x)), moved: false)
            } else {
                drag = .seek
                session.seek(to: state.snap(tick(p.x), bypass: flags.contains(.control)))
            }
        case .header(let index, let button):
            let track = project.tracks[index]
            state.selectedTrack = track.id
            switch button {
            case .none: break
            case .mute: session.perform { $0.setTrackMuted(track.id, !track.muted) }
            case .solo: session.perform { $0.setTrackSolo(track.id, !track.solo) }
            case .automation:
                session.perform {
                    $0.tracks[index].automationShown = track.automationShown == nil
                        ? .track(track.kind == .video ? .opacity : .volume) : nil
                }
            }
        case .automation(let index):
            beginAutomationDrag(at: p, rowIndex: index, doubleClick: event.clickCount == 2, bypassSnap: flags.contains(.control))
        case .region(let id, let zone, let rowIndex):
            if marqueeMode { beginMarquee(at: p, row: rowIndex); break }
            state.marquee = nil
            state.selectedTrack = project.tracks[rowIndex].id
            if flags.contains(.shift) {
                let group = project.linkedRegions([id])
                if state.selection.contains(id) { state.selection.subtract(group) } else { state.selection.formUnion(group) }
                break
            }
            if !state.selection.contains(id) { state.selection = [id] }
            let option = flags.contains(.option)
            switch zone {
            case .left: drag = option ? .stretch(id, anchorEnd: true) : .trimStart(id)
            case .right: drag = option ? .stretch(id, anchorEnd: false) : .trimEnd(id)
            case .loop: drag = .loop(id)
            case .fadeIn: drag = .fadeIn(id)
            case .fadeOut: drag = .fadeOut(id)
            case .body:
                var anchor = id
                if option, let clicked = project.region(id) {
                    // Option-drag leaves the originals where they are and moves copies.
                    let clip = project.copyRegions(state.selection)
                    let earliest = state.selection.compactMap { project.region($0)?.start }.min() ?? clicked.start
                    let copies = session.perform { $0.paste(clip, at: earliest) }
                    state.selection = Set(copies)
                    base = project
                    anchor = copies.first { project.region($0)?.start == clicked.start && project.location(of: $0)?.track == rowIndex } ?? copies.first ?? id
                }
                drag = .move(anchor: anchor, grab: tick(p.x), startRow: rowIndex)
            }
        case .lane(let rowIndex):
            if marqueeMode { beginMarquee(at: p, row: rowIndex); break }
            state.marquee = nil
            state.selectedTrack = project.tracks[rowIndex].id
            if !flags.contains(.shift) { state.selection = [] }
            drag = .rubber(origin: p, keep: state.selection)
        }
        needsDisplay = true
    }

    private func beginMarquee(at p: CGPoint, row: Int) {
        state.selection = []
        state.marquee = nil
        drag = .marquee(anchor: state.snap(tick(p.x)), row: row)
    }

    private func beginAutomationDrag(at p: CGPoint, rowIndex: Int, doubleClick: Bool, bypassSnap: Bool) {
        let rows = rows()
        guard rows.indices.contains(rowIndex), let lane = automationRect(rows[rowIndex]),
              let path = rows[rowIndex].track.automationShown else { return }
        let track = rows[rowIndex].track
        let range = state.paramRange(path, track: track)
        let param = project.param(path, track: track.id) ?? Param(range.lowerBound)
        let near = param.points.firstIndex { point in
            hypot(x(point.tick) - p.x, valueY(point.value, range: range, lane: lane) - p.y) < 8
        }
        if let near {
            if doubleClick { session.perform { $0.removePoint(path, track: track.id, index: near) } }
            else { drag = .point(track: track.id, path: path, index: near) }
            return
        }
        let at = state.snap(tick(p.x), bypass: bypassSnap), value = value(atY: p.y, range: range, lane: lane)
        if let index = session.perform({ $0.addPoint(path, track: track.id, tick: at, value: value) }) {
            base = project
            drag = .point(track: track.id, path: path, index: index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let bypass = event.modifierFlags.contains(.control)
        let t = tick(p.x)
        let base = self.base
        func snapped(_ tick: Ticks) -> Ticks { state.snap(tick, bypass: bypass) }

        switch drag {
        case .none:
            break
        case .seek:
            session.seek(to: snapped(t))
        case .cycle(let anchor, _):
            let other = snapped(t)
            guard other != anchor else { break }
            session.performCoalescing(key: "cycle") {
                $0 = base
                $0.cycleStart = min(anchor, other)
                $0.cycleEnd = max(anchor, other)
                $0.cycleOn = true
            }
            drag = .cycle(anchor: anchor, moved: true)
        case .move(let anchorID, let grab, let startRow):
            guard let anchor = base.region(anchorID) else { break }
            let delta = snapped(anchor.start + (t - grab)) - anchor.start
            let rowDelta = (row(atY: p.y)?.index ?? startRow) - startRow
            let ids = state.selection
            session.performCoalescing(key: "move") {
                $0 = base
                $0.moveRegions(ids, deltaTicks: delta, deltaTracks: rowDelta)
            }
        // Edge edits reach the region's linked partners too, each by the same amount.
        case .trimStart(let id):
            guard let region = base.region(id) else { break }
            let delta = snapped(t) - region.start
            session.performCoalescing(key: "trim") { project in
                project = base
                for partner in partners(of: id, in: base) { project.trimStart(partner.id, to: partner.start + delta) }
            }
        case .trimEnd(let id):
            guard let region = base.region(id) else { break }
            let delta = snapped(t) - region.end
            session.performCoalescing(key: "trim") { project in
                project = base
                for partner in partners(of: id, in: base) { project.trimEnd(partner.id, to: partner.end + delta) }
            }
        case .loop(let id):
            guard let region = base.region(id) else { break }
            let delta = snapped(t) - region.end
            session.performCoalescing(key: "loop") { project in
                project = base
                for partner in partners(of: id, in: base) { project.setLoopEnd(partner.id, to: partner.end + delta) }
            }
        case .stretch(let id, let anchorEnd):
            guard let region = base.region(id) else { break }
            let delta = anchorEnd ? region.start - snapped(t) : snapped(t) - region.end
            guard region.length + delta > 0 else { break }
            session.performCoalescing(key: "stretch") { project in
                project = base
                for partner in partners(of: id, in: base) where partner.length + delta > 0 {
                    project.stretch(partner.id, toLength: partner.length + delta, anchorEnd: anchorEnd)
                }
            }
        case .fadeIn(let id):
            guard let region = base.region(id) else { break }
            let fade = max(0, snapped(t) - region.start)
            session.performCoalescing(key: "fade") { project in
                project = base
                for partner in partners(of: id, in: base) { project.setFadeIn(partner.id, fade) }
            }
        case .fadeOut(let id):
            guard let region = base.region(id) else { break }
            let fade = max(0, region.end - snapped(t))
            session.performCoalescing(key: "fade") { project in
                project = base
                for partner in partners(of: id, in: base) { project.setFadeOut(partner.id, fade) }
            }
        case .rubber(let origin, let keep):
            let box = CGRect(x: min(origin.x, p.x), y: min(origin.y, p.y), width: abs(p.x - origin.x), height: abs(p.y - origin.y))
            rubber = box
            var chosen = keep
            for row in rows() {
                for region in row.track.regions where rect(region, in: row).intersects(box) { chosen.insert(region.id) }
            }
            state.selection = chosen
        case .marquee(let anchor, let startRow):
            let other = snapped(t)
            let endRow = row(atY: p.y)?.index ?? startRow
            let tracks = Set(project.tracks[min(startRow, endRow)...max(startRow, endRow)].map(\.id))
            state.marquee = other == anchor ? nil : MarqueeSelection(range: min(anchor, other)..<max(anchor, other), tracks: tracks)
        case .point(let track, let path, let index):
            guard let row = rows().first(where: { $0.track.id == track }), let lane = automationRect(row) else { break }
            let range = state.paramRange(path, track: row.track)
            let value = value(atY: p.y, range: range, lane: lane)
            session.performCoalescing(key: "point") {
                $0 = base
                $0.movePoint(path, track: track, index: index, to: snapped(t), value: value)
            }
        }
        needsDisplay = true
    }

    /// The region and everything linked to it, as they were when the drag began.
    private func partners(of id: UUID, in project: Project) -> [Region] {
        project.linkedRegions([id]).compactMap { project.region($0) }
    }

    override func mouseUp(with event: NSEvent) {
        session.endCoalescing()
        if case .cycle(_, false) = drag { state.toggleCycle() }
        drag = .none
        rubber = nil
        needsDisplay = true
    }

    // MARK: Scrolling and zoom

    override func scrollWheel(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.command) {
            zoom(by: 1 - event.scrollingDeltaY * 0.01, around: p.x)
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            scrollX = max(0, scrollX - event.scrollingDeltaX * scale)
            let content = rows().last.map { $0.y + scrollY + trackHeight + automationHeight } ?? 0
            scrollY = min(max(0, content - bounds.height + 40), max(0, scrollY - event.scrollingDeltaY * scale))
        }
        needsDisplay = true
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil).x)
        needsDisplay = true
    }

    private func zoom(by factor: CGFloat, around anchorX: CGFloat) {
        let beats = (anchorX - headerWidth + scrollX) / pixelsPerBeat
        pixelsPerBeat = min(600, max(2, pixelsPerBeat * factor))
        scrollX = max(0, beats * pixelsPerBeat - (anchorX - headerWidth))
    }

    /// Pages the view along when playback runs off the right-hand side.
    func followPlayhead() {
        guard state.clock.isPlaying, case .none = drag else { return }
        let at = x(state.clock.playhead)
        if at > bounds.width - 30 || at < headerWidth {
            scrollX = max(0, scrollX + at - headerWidth - 60)
        }
    }

    // MARK: Keyboard and menu commands

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        switch (event.keyCode, event.charactersIgnoringModifiers?.lowercased()) {
        case (49, _) where plain: session.togglePlay()
        case (51, _), (117, _): state.deleteSelection()
        case (36, _) where plain: session.seek(to: 0)
        case (123, _) where plain: session.seek(to: max(0, session.position - project.gridTicks(state.division)))
        case (124, _) where plain: session.seek(to: session.position + project.gridTicks(state.division))
        case (_, "t") where plain: state.splitAtPlayhead()
        case (_, "m") where plain: state.toggleMuteSelection()
        case (_, "r") where plain: state.reverseSelection()
        case (_, "c") where plain: state.toggleCycle()
        case (53, _):
            state.marquee = nil
            state.selection = []
        default: super.keyDown(with: event)
        }
        needsDisplay = true
    }

    @objc func copy(_ sender: Any?) { state.copy() }
    @objc func cut(_ sender: Any?) { state.cut() }
    @objc func paste(_ sender: Any?) { state.paste() }
    @objc func delete(_ sender: Any?) { state.deleteSelection() }
    @objc override func selectAll(_ sender: Any?) { state.selectAll(); needsDisplay = true }

    // MARK: Drops from Finder

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let track = row(atY: p.y)?.track
        state.add(files: urls, at: state.snap(tick(max(p.x, headerWidth))),
                  videoTrack: track?.kind == .video ? track?.id : nil,
                  audioTrack: track?.kind == .audio ? track?.id : nil)
        window?.makeFirstResponder(self)
        return true
    }
}
