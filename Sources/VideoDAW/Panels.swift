import Model
import Session
import SwiftUI

// MARK: Names and ranges shared by the timeline and the inspector

extension TrackParam {
    var displayName: String {
        switch self {
        case .opacity: return "Opacity"
        case .x: return "X"
        case .y: return "Y"
        case .scale: return "Scale"
        case .rotation: return "Rotation"
        case .cropLeft: return "Crop Left"
        case .cropRight: return "Crop Right"
        case .cropTop: return "Crop Top"
        case .cropBottom: return "Crop Bottom"
        case .volume: return "Volume"
        case .pan: return "Pan"
        }
    }
}

extension GridDivision {
    /// Bar and Beat by name; finer divisions as the note value they are in this signature
    /// (half a beat of 4/4 is an eighth note, of 6/8 a sixteenth).
    func displayName(beatUnit: Int) -> String {
        switch self {
        case .bar: return "Bar"
        case .beat: return "Beat"
        case .half: return "1/\(beatUnit * 2)"
        case .quarter: return "1/\(beatUnit * 4)"
        case .eighth: return "1/\(beatUnit * 8)"
        case .sixteenth: return "1/\(beatUnit * 16)"
        }
    }
}

extension EffectSlot {
    var displayName: String {
        kind == .audioUnit ? (audioUnit?.name ?? "Audio Unit") : kind.rawValue.capitalized
    }
}

extension AppState {
    func paramName(_ path: ParamPath, track: Track) -> String {
        switch path {
        case .track(let param):
            return param.displayName
        case .effectMix(let slotID):
            return (track.effects.first { $0.id == slotID }?.displayName ?? "Effect") + " Mix"
        case .effect(let slotID, let address):
            guard let slot = track.effects.first(where: { $0.id == slotID }) else { return "Effect" }
            if slot.kind == .audioUnit {
                let name = session.pluginParameters(slot: slotID).first { $0.address == address }?.name
                return name ?? "Parameter \(address)"
            }
            return slot.kind.paramSpecs.indices.contains(Int(address)) ? slot.kind.paramSpecs[Int(address)].name : "Parameter"
        }
    }

    /// The range a parameter is drawn and edited in. Audio Unit parameters ask the plugin.
    func paramRange(_ path: ParamPath, track: Track) -> ClosedRange<Double> {
        if let known = project.paramRange(path, track: track.id) { return known }
        if case .effect(let slotID, let address) = path,
           let parameter = session.pluginParameters(slot: slotID).first(where: { $0.address == address }) {
            return parameter.range
        }
        return 0...1
    }
}

// MARK: Transport bar

struct TransportBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var clock: Clock

    var body: some View {
        HStack(spacing: 12) {
            Button { state.session.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                .help("Go to the start (Return)")
            Button { state.session.togglePlay() } label: {
                Image(systemName: clock.isPlaying ? "stop.fill" : "play.fill").frame(width: 18)
            }
            .help("Play or stop (Space)")
            Toggle(isOn: Binding(get: { state.project.cycleOn }, set: { _ in state.toggleCycle() })) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .help("Cycle (C). Drag in the top strip of the ruler to set the range.")

            Divider().frame(height: 20)

            TextField("Tempo", value: Binding(
                get: { state.project.tempo },
                set: { tempo in state.session.perform { $0.setTempo(tempo) } }), format: .number.precision(.fractionLength(0...2)))
                .frame(width: 64)
                .textFieldStyle(.roundedBorder)
            Text("bpm").foregroundStyle(.secondary)
            Stepper("\(state.project.beatsPerBar)", value: Binding(
                get: { state.project.beatsPerBar },
                set: { beats in state.session.perform { $0.setTimeSignature(beats: beats, unit: $0.signatureUnit) } }), in: 1...32)
                .help("Beats in a measure")
            Picker("", selection: Binding(
                get: { state.project.signatureUnit },
                set: { unit in state.session.perform { $0.setTimeSignature(beats: $0.beatsPerBar, unit: unit) } })) {
                ForEach([2, 4, 8, 16], id: \.self) { Text("/ \($0)").tag($0) }
            }
            .labelsHidden()
            .frame(width: 64)
            .help("The note value that counts as one beat. Tempo is always in quarter notes per minute.")

            Divider().frame(height: 20)

            Toggle("Snap", isOn: $state.snapOn).toggleStyle(.button)
                .help("Hold Control while dragging to bypass")
            Picker("", selection: $state.division) {
                ForEach(GridDivision.allCases, id: \.self) { Text($0.displayName(beatUnit: state.project.signatureUnit)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 80)

            Picker("", selection: $state.tool) {
                Image(systemName: "cursorarrow").tag(Tool.pointer)
                Image(systemName: "rectangle.dashed").tag(Tool.marquee)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 84)
            .help("Pointer or marquee. Hold Command for the marquee.")

            Spacer()

            if let progress = state.session.exportProgress {
                ProgressView(value: progress).frame(width: 140)
                Text("Exporting").foregroundStyle(.secondary)
            } else if state.session.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading media").foregroundStyle(.secondary)
            } else if clock.isBending {
                ProgressView().controlSize(.small)
                Text("Bending picture").foregroundStyle(.secondary)
                    .help("A through-time effect is being worked out ahead of the playhead. Until it is ready the track shows unbent.")
            }
            Button("Export") { state.exportMovie() }.disabled(state.session.exportProgress != nil)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .onChange(of: state.snapOn) { _, _ in state.onRedraw?() }
        .onChange(of: state.division) { _, _ in state.onRedraw?() }
    }
}

// MARK: Inspector

struct InspectorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let id = state.selectedTrack, let track = state.project.track(id) {
                    TrackSection(state: state, track: track)
                }
                if let region = focusedRegion { RegionSection(state: state, region: region) }
                ProjectSection(state: state)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 300)
    }

    /// The region the inspector describes: the only one selected, or the picture of a
    /// selection that is a single linked group.
    private var focusedRegion: Region? {
        guard let any = state.selection.first, state.project.linkedRegions([any]) == state.selection else { return nil }
        let regions = state.selection.compactMap { state.project.region($0) }
        let picture = regions.first { region in
            state.project.location(of: region.id).map { state.project.tracks[$0.track].kind == .video } ?? false
        }
        return picture ?? regions.first
    }
}

private struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased()).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
    }
}

/// A slider for one parameter. Disabled while the parameter is automated; the button opens
/// its automation lane.
private struct ParamRow: View {
    @ObservedObject var state: AppState
    let track: Track
    let path: ParamPath
    let label: String
    let range: ClosedRange<Double>
    let fallback: Double

    var body: some View {
        let param = state.project.param(path, track: track.id)
        let automated = !(param?.points.isEmpty ?? true)
        let value = param?.value ?? fallback
        HStack(spacing: 6) {
            Text(label).frame(width: 76, alignment: .leading)
            Slider(value: Binding(
                get: { value },
                set: { new in state.session.performCoalescing(key: "param \(path)") { _ = $0.setValue(path, track: track.id, new) } }),
                in: range, onEditingChanged: { editing in if !editing { state.session.endCoalescing() } })
                .disabled(automated)
            Text(automated ? "auto" : String(format: "%.2f", value))
                .monospacedDigit().frame(width: 40, alignment: .trailing).foregroundStyle(.secondary)
            Button {
                state.session.perform { project in
                    guard let index = project.trackIndex(track.id) else { return }
                    project.tracks[index].automationShown = track.automationShown == path ? nil : path
                }
            } label: {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .foregroundStyle(track.automationShown == path ? Color.teal : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Show this parameter's automation lane")
        }
        .font(.callout)
    }
}

private struct TrackSection: View {
    @ObservedObject var state: AppState
    let track: Track

    private var params: [TrackParam] {
        track.kind == .video
            ? [.opacity, .x, .y, .scale, .rotation, .cropLeft, .cropRight, .cropTop, .cropBottom]
            : [.volume, .pan]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(track.kind == .video ? "Video track" : "Audio track")
            HStack {
                TextField("Name", text: Binding(
                    get: { track.name },
                    set: { name in state.session.performCoalescing(key: "rename track") { $0.renameTrack(track.id, to: name) } }))
                    .textFieldStyle(.roundedBorder)
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.help("Move the track up")
                Button { move(1) } label: { Image(systemName: "arrow.down") }.help("Move the track down")
            }
            if track.kind == .video {
                Picker("Blend", selection: Binding(
                    get: { track.blend },
                    set: { blend in state.session.perform { $0.setBlend(track.id, blend) } })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            ForEach(params, id: \.self) { param in
                ParamRow(state: state, track: track, path: .track(param), label: param.displayName,
                         range: param.range, fallback: param.defaultValue)
            }

            SectionTitle("Effects").padding(.top, 6)
            ForEach(track.effects) { slot in
                EffectCard(state: state, track: track, slot: slot)
            }
            AddEffectMenu(state: state, track: track)
        }
    }

    private func move(_ by: Int) {
        guard let index = state.project.trackIndex(track.id) else { return }
        let target = index + by
        guard state.project.tracks.indices.contains(target) else { return }
        state.session.perform { $0.moveTrack(from: index, to: target) }
    }
}

/// The menu of effects a track can take: the built-in picture effects on video tracks, and
/// every installed Audio Unit effect.
struct AddEffectMenu: View {
    @ObservedObject var state: AppState
    let track: Track
    var title = "Add Effect"
    @State private var installed: [AudioUnitRef] = []

    var body: some View {
        Menu(title) {
            if track.kind == .video {
                ForEach([EffectKind.color, .blur, .pixelate, .feedback, .displace], id: \.self) { kind in
                    Button(kind.rawValue.capitalized) { add(EffectSlot(kind: kind)) }
                }
                Divider()
            }
            Menu(track.kind == .video ? "Audio Unit (bends the picture)" : "Audio Unit") {
                ForEach(installed, id: \.name) { unit in
                    Button(unit.name) { add(EffectSlot(kind: .audioUnit, audioUnit: unit)) }
                }
            }
        }
        .onAppear { if installed.isEmpty { installed = Session.installedEffects() } }
    }

    private func add(_ slot: EffectSlot) {
        state.session.perform { _ = $0.addEffect(slot, to: track.id) }
    }
}

private struct EffectCard: View {
    @ObservedObject var state: AppState
    let track: Track
    let slot: EffectSlot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: Binding(
                    get: { !slot.bypass },
                    set: { on in state.session.perform { $0.setEffectBypass(slot.id, track: track.id, !on) } }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Text(slot.displayName).fontWeight(.medium).lineLimit(1)
                Spacer()
                Button { move(-1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.plain)
                Button { move(1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.plain)
                Button {
                    state.closePluginWindow(slot: slot.id)
                    state.session.perform { $0.removeEffect(slot.id, track: track.id) }
                } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            if slot.kind == .audioUnit {
                if !state.session.pluginIsReady(slot: slot.id) {
                    Text("Loading plugin…").foregroundStyle(.secondary).font(.callout)
                } else {
                    HStack {
                        Button("Open Plugin Window") { state.openPluginWindow(slot: slot.id, title: slot.displayName) }
                        Menu("Automate") {
                            ForEach(state.session.pluginParameters(slot: slot.id)) { parameter in
                                Button(parameter.name) { showLane(.effect(slot.id, parameter.address)) }
                            }
                        }
                        .frame(width: 100)
                    }
                    if track.kind == .video {
                        Picker("Signal", selection: Binding(
                            get: { slot.bendMode },
                            set: { mode in state.session.perform { _ = $0.setBendMode(slot.id, track: track.id, mode) } })) {
                            Text("Raster").tag(BendMode.raster)
                            Text("Through time").tag(BendMode.throughTime)
                        }
                        .pickerStyle(.segmented)
                        if slot.bendMode == .throughTime {
                            Picker("Memory", selection: Binding(
                                get: { slot.bendMemory ?? .short },
                                set: { memory in
                                    state.session.perform { project in
                                        guard let t = project.trackIndex(track.id),
                                              let e = project.tracks[t].effects.firstIndex(where: { $0.id == slot.id }) else { return }
                                        project.tracks[t].effects[e].bendMemory = memory
                                    }
                                })) {
                                ForEach(BendMemory.allCases, id: \.self) { memory in
                                    Text(String(format: "%.0f s", Double(memory.rawValue) / state.project.fps)).tag(memory)
                                }
                            }
                            .help("How far back in time the effect remembers. Longer memory suits long reverbs and slow filters, and takes longer to catch up after a change.")
                        }
                        ParamRow(state: state, track: track, path: .effectMix(slot.id), label: "Mix", range: 0...1, fallback: 1)
                    }
                }
            } else {
                ForEach(Array(slot.kind.paramSpecs.enumerated()), id: \.offset) { index, spec in
                    ParamRow(state: state, track: track, path: .effect(slot.id, UInt64(index)), label: spec.name,
                             range: spec.range, fallback: spec.defaultValue)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
    }

    private func showLane(_ path: ParamPath) {
        state.session.perform { project in
            guard let index = project.trackIndex(track.id) else { return }
            project.tracks[index].automationShown = path
        }
    }

    private func move(_ by: Int) {
        guard let index = track.effects.firstIndex(where: { $0.id == slot.id }) else { return }
        let target = index + by
        guard track.effects.indices.contains(target) else { return }
        state.session.perform { $0.moveEffect(track: track.id, from: index, to: target) }
    }
}

private struct RegionSection: View {
    @ObservedObject var state: AppState
    let region: Region

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Region")
            TextField("Name", text: Binding(
                get: { region.name },
                set: { name in state.session.performCoalescing(key: "rename region") { $0.renameRegion(region.id, to: name) } }))
                .textFieldStyle(.roundedBorder)
            HStack {
                Toggle("Reversed", isOn: Binding(
                    get: { region.reversed },
                    set: { _ in state.reverseSelection() }))
                Toggle("Muted", isOn: Binding(
                    get: { region.muted },
                    set: { _ in state.toggleMuteSelection() }))
            }
            if state.selection.count > 1 {
                HStack {
                    Text("Linked").font(.callout).foregroundStyle(.secondary)
                    Button("Unlink") { state.unlinkSelection() }
                        .help("Let the picture and the sound be moved and cut separately. Select both and choose Edit > Link Regions to join them again.")
                }
            }
            let beats = Double(region.length) / Double(state.project.beatTicks)
            Text(String(format: "Length %.2f beats · Speed %.0f%%%@", beats, region.speed * 100,
                        region.isLooped ? " · Looped" : ""))
                .font(.callout).foregroundStyle(.secondary)
            if abs(region.speed - 1) > 0.001 {
                Button("Reset Speed") {
                    let ids = state.selection
                    state.session.perform { project in
                        for id in ids {
                            guard let each = project.region(id) else { continue }
                            project.stretch(id, toLength: max(1, Ticks((Double(each.length) * each.speed).rounded())))
                        }
                    }
                }
            }
        }
    }
}

private struct ProjectSection: View {
    @ObservedObject var state: AppState

    private let sizes: [(String, Int, Int)] = [
        ("1920 × 1080", 1920, 1080), ("1280 × 720", 1280, 720), ("3840 × 2160", 3840, 2160),
        ("1080 × 1920", 1080, 1920), ("1080 × 1080", 1080, 1080),
    ]

    var body: some View {
        let project = state.project
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Project")
            Text(project.name).fontWeight(.medium)
            Menu("Frame: \(project.width) × \(project.height)") {
                ForEach(sizes, id: \.0) { size in
                    Button(size.0) { state.session.perform { $0.width = size.1; $0.height = size.2 } }
                }
            }
            Picker("Frame rate", selection: Binding(
                get: { project.fps },
                set: { fps in state.session.perform { $0.fps = fps } })) {
                ForEach([24.0, 25, 30, 50, 60], id: \.self) { Text("\(Int($0)) fps").tag($0) }
                if ![24.0, 25, 30, 50, 60].contains(project.fps) {
                    Text(String(format: "%.2f fps", project.fps)).tag(project.fps)
                }
            }
            Picker("Bend resolution", selection: Binding(
                get: { project.bendHeight },
                set: { height in state.session.perform { $0.bendHeight = height } })) {
                Text("180 lines").tag(180)
                Text("270 lines").tag(270)
                Text("360 lines").tag(360)
            }
            .help("The size of the signal Audio Units see when they process the picture. Smaller runs smoother.")
            if !state.session.missingMedia.isEmpty {
                Button("Locate Missing Media (\(state.session.missingMedia.count))") { state.relinkMissing() }
            }
        }
    }
}
