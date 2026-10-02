# VideoDAW

A DAW whose regions can be video. Video and audio regions share one beat-gridded timeline, every track has a channel strip, and Audio Units can process the picture itself. What plays in the viewer is what exports.

The spec, with the reasoning behind each decision and the current status, is in `plans/video-daw-prd.md`.

## Build, run, test

No Xcode is needed, only the Command Line Tools.

```sh
Scripts/bundle.sh        # builds an optimised VideoDAW.app in this folder
open VideoDAW.app
Scripts/test.sh          # runs all tests
```

Projects are folders ending in `.vdaw`. The app reopens the last project, or starts `Untitled.vdaw` in `~/Movies/VideoDAW`.

## Using it

| To do this | Do this |
|---|---|
| Import | Drop files on the timeline, or File > Import Media |
| Play / stop | Space |
| Go to start | Return |
| Locate | Click the lower part of the ruler |
| Set the cycle | Drag in the top strip of the ruler; click it to toggle; C |
| Zoom | Pinch, or Command-scroll |
| Select | Click, Shift-click, or drag a box on empty lane |
| Move | Drag a region; drag up or down to change track |
| Copy while dragging | Option-drag a region |
| Trim | Drag a region's left or right edge |
| Loop | Drag the upper part of a region's right edge |
| Stretch | Option-drag an edge |
| Fade | Drag the white dot at a selected region's top corner |
| Crossfade | Overlap two regions on one track |
| Marquee | Command-drag, or pick the marquee tool; then drag inside it, Delete, copy |
| Split at playhead | T |
| Unlink a video's sound from its picture | Select it, Edit > Unlink Regions (Shift-Command-L) |
| Link regions | Select them, Edit > Link Regions (Command-L) |
| Mixer | Window > Mixer (Command-2) |
| Reverse / mute region | R / M |
| Bypass snap | Hold Control while dragging |
| Nudge the selection by one grid division | Option-Left / Option-Right |
| Nudge the selection by one video frame | Shift-Option-Left / Shift-Option-Right |
| Move the playhead by one grid division | Left / Right |
| Time signature | The two controls after the tempo: beats per measure, and the note that counts as a beat |
| Automation lane | A on the track header, or the curve button beside any slider |
| Automation points | Click to add, drag to move, double-click to remove |
| Move the picture | Select a video track, then drag or pinch in the viewer |

## Audio Units on video

Add an Audio Unit to a video track from the inspector's Add Effect menu. Each slot has a signal mode:

- **Raster** reads the frame as one waveform, left to right, top to bottom. Delays echo the picture down the frame, filters smear it, distortion crushes it. Runs live.
- **Through time** reads each pixel across successive frames. Delays become frame echoes, filters become motion blur. Computed ahead of the playhead. Its Memory setting is how far back the effect can reach: about 1, 8 or 34 seconds at 30 fps. Longer memory suits long reverbs and takes longer to catch up after a change.

Both run at the project's bend resolution (Project section of the inspector) and are blended with the sharp picture by the slot's Mix.

## Layout

| Folder | What it is |
|---|---|
| `Sources/Model` | Project model: value types and every edit as a mutation of a project value. No dependencies. |
| `Sources/Engine` | C++ engine behind `include/engine.h`: audio graph, decoders, Metal compositing, picture bending, plugin hosting, export. |
| `Sources/Session` | Plan compiler (project to engine plan), project storage, proxies. |
| `Sources/VideoDAW` | The app: timeline, viewer, inspector, transport. |

`Sources/VideoDAW/DebugHooks.swift` lists environment variables for driving the app from a script.

## Licence

MIT. See `LICENSE`.
