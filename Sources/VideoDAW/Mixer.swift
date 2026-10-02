import Model
import Session
import SwiftUI

/// Every track as a channel strip, side by side. A video track's fader is its opacity; an
/// audio track's is its volume.
struct MixerView: View {
    @ObservedObject var state: AppState
    @ObservedObject var meters: Meters

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 1) {
                ForEach(state.project.tracks) { track in
                    ChannelStrip(state: state, track: track, level: meters.levels[track.id] ?? 0)
                }
                OutputStrip(level: meters.master)
            }
            .padding(8)
        }
        .frame(minWidth: 420, minHeight: 430)
    }
}

/// A slider turned on its end.
private struct Fader: View {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let disabled: Bool
    let onRelease: () -> Void
    private let length: CGFloat = 170

    var body: some View {
        Slider(value: value, in: range, onEditingChanged: { editing in if !editing { onRelease() } })
            .disabled(disabled)
            .frame(width: length)
            .rotationEffect(.degrees(-90))
            .frame(width: 26, height: length)
    }
}

private struct MeterBar: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.white.opacity(0.08))
                Rectangle()
                    .fill(level > 0.97 ? Color.red : level > 0.8 ? Color.yellow : Color.green)
                    .frame(height: geometry.size.height * level)
            }
        }
        .frame(width: 8, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }
}

private struct ChannelStrip: View {
    @ObservedObject var state: AppState
    let track: Track
    let level: Double

    private var main: TrackParam { track.kind == .video ? .opacity : .volume }
    private var selected: Bool { state.selectedTrack == track.id }

    var body: some View {
        let param = track.param(main)
        let automated = !param.points.isEmpty
        VStack(spacing: 8) {
            Text(track.name)
                .font(.callout).fontWeight(.medium).lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(track.kind == .video ? Color.blue.opacity(0.45) : Color.green.opacity(0.4))

            // The effect chain, top to bottom. Clicking an Audio Unit opens its window.
            VStack(spacing: 2) {
                ForEach(track.effects) { slot in
                    Button {
                        state.selectedTrack = track.id
                        if slot.kind == .audioUnit { state.openPluginWindow(slot: slot.id, title: slot.displayName) }
                    } label: {
                        Text(slot.displayName)
                            .font(.caption).lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(slot.bypass ? 0.04 : 0.14)))
                            .foregroundStyle(slot.bypass ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                }
                AddEffectMenu(state: state, track: track, title: "+")
                    .menuStyle(.borderlessButton)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 96, alignment: .top)

            if track.kind == .audio {
                Slider(value: Binding(
                    get: { track.param(.pan).value },
                    set: { pan in state.session.performCoalescing(key: "mixer pan") { _ = $0.setValue(.track(.pan), track: track.id, pan) } }),
                    in: -1...1, onEditingChanged: { editing in if !editing { state.session.endCoalescing() } })
                    .controlSize(.mini)
                    .help("Pan")
            } else {
                Picker("", selection: Binding(
                    get: { track.blend },
                    set: { blend in state.session.perform { $0.setBlend(track.id, blend) } })) {
                    ForEach(BlendMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden()
                .controlSize(.mini)
                .help("Blend mode")
            }

            HStack(spacing: 6) {
                Fader(value: Binding(
                    get: { param.value },
                    set: { new in state.session.performCoalescing(key: "mixer fader") { _ = $0.setValue(.track(main), track: track.id, new) } }),
                      range: main.range, disabled: automated, onRelease: { state.session.endCoalescing() })
                if track.kind == .audio { MeterBar(level: level) }
            }
            Text(automated ? "auto" : String(format: "%.2f", param.value))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Toggle("M", isOn: Binding(
                    get: { track.muted },
                    set: { muted in state.session.perform { $0.setTrackMuted(track.id, muted) } }))
                Toggle("S", isOn: Binding(
                    get: { track.solo },
                    set: { solo in state.session.perform { $0.setTrackSolo(track.id, solo) } }))
            }
            .toggleStyle(.button)
            .controlSize(.small)
        }
        .padding(.bottom, 8)
        .frame(width: 96)
        .background(Color.white.opacity(selected ? 0.1 : 0.04))
        .contentShape(Rectangle())
        .onTapGesture { state.selectedTrack = track.id }
    }
}

/// The level of everything together, as it leaves for the speakers.
private struct OutputStrip: View {
    let level: Double

    var body: some View {
        VStack(spacing: 8) {
            Text("Output")
                .font(.callout).fontWeight(.medium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.14))
            Spacer().frame(height: 96 + 22 + 8)
            HStack(spacing: 3) {
                MeterBar(level: level)
                MeterBar(level: level)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 64)
        .background(Color.white.opacity(0.04))
    }
}
