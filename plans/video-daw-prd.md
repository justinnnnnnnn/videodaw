# PRD: VideoDAW (working name)

## Problem Statement

I make music in Logic and want to cut video the same way I cut audio: regions on lanes, a beat grid, a marquee tool, a mixer, automation. I also want to run my own Audio Units on the picture itself, the way you can push an analog video signal through audio gear.

Nothing I have does this. Logic's Movie track is a reference strip that can't be edited. CamOrder edits in a plugin window and ends in an export/import round trip, with no effects beyond framing. Conventional video editors don't think in beats and can't host Audio Units on video.

## Solution

A standalone Mac app that is a DAW whose regions can be video.

- Video tracks and audio tracks share one beat-gridded timeline.
- Regions on both kinds of track respond to the same Logic-style editing gestures.
- Every track has a channel strip. Audio strips hold Audio Units. Video strips hold an opacity fader, blend mode, transform, built-in GPU effects, and Audio Unit slots that bend the picture.
- Anything on a strip can be automated.
- What plays in the viewer is exactly what exports.
- A project is a folder on disk that autosaves.

Music is still written in Logic and brought in as bounces or stems.

## User Stories

### Project and files

1. As a musician, I want to create a new project and pick where it lives, so that my work sits with the rest of my files.
2. As a musician, I want a project to be one folder I can move or back up, so that file management is obvious.
3. As a musician, I want every edit autosaved, so that a crash never costs me work.
4. As a musician, I want to drag video and audio files in from Finder, so that importing takes no dialog.
5. As a musician, I want imported media referenced in place by default, so that projects stay small and originals stay untouched.
6. As a musician, I want a "Collect media" command that copies all used media into the project folder, so that I can archive or move a project safely.
7. As a musician, I want to relink missing media by pointing at one file and having the rest found in the same folder, so that moved footage is a one-step fix.
8. As a musician, I want a video file's soundtrack to land as its own audio region at the same position, so that I can edit picture and sound separately.
9. As a musician, I want to reopen a project and find every Audio Unit with its settings intact, so that sessions are repeatable.

### Timeline and grid

10. As a musician, I want to set the project tempo and time signature, so that the grid matches my song.
11. As a musician, I want a bars-and-beats ruler with a timecode readout, so that I can think musically and still see real time.
12. As a musician, I want to choose a snap division (bar, beat, 1/2, 1/4, 1/8, 1/16), so that edits land on the grid I care about.
13. As a musician, I want to hold a modifier to bypass snap temporarily, so that fine placement doesn't need a settings change.
14. As a musician, I want to add, rename, reorder and delete video and audio tracks, so that the arrangement matches my project.
15. As a musician, I want video thumbnails and audio waveforms drawn inside regions, so that I can see what I'm cutting.
16. As a musician, I want to zoom horizontally with a pinch and scroll freely, so that I can work at any scale.
17. As a musician, I want space bar play/stop, a draggable playhead and click-to-locate in the ruler, so that transport feels like Logic.
18. As a musician, I want a cycle range, so that I can loop a section while I adjust it.

### Region editing (video and audio alike)

19. As a musician, I want to click, shift-click and rubber-band select regions, so that I can act on several at once.
20. As a musician, I want to drag regions in time and between tracks of the same kind, so that arranging is direct.
21. As a musician, I want to drag either edge of a region to trim it, and drag back out to reveal trimmed content, so that trims are non-destructive.
22. As a musician, I want to split selected regions at the playhead, so that I can cut on the beat.
23. As a musician, I want a marquee tool that selects a time range across tracks, so that I can treat a section as an object.
24. As a musician, I want acting on a marquee selection to split at both boundaries automatically, so that I can drag, copy or delete just that section.
25. As a musician, I want copy, paste at the playhead, and duplicate, so that I can repeat material.
26. As a musician, I want to mute a region, so that I can audition without deleting.
27. As a musician, I want to delete regions, so that I can remove material.
28. As a musician, I want to drag a region's upper-right corner to loop it, so that a short clip repeats for as long as I drag.
29. As a musician, I want to drag a fade handle at either end of a region, so that video fades its opacity and audio fades its volume.
30. As a musician, I want overlapping regions on one track to crossfade over their overlap, so that transitions need no extra track.
31. As a musician, I want to option-drag a region edge to stretch or compress it, so that its contents play faster or slower to fit the new length.
32. As a musician, I want stretched audio to keep its pitch, so that retiming doesn't detune it.
33. As a musician, I want to reverse a region, so that it plays backwards.
34. As a musician, I want to rename a region, so that the arrangement is readable.
35. As a musician, I want unlimited undo and redo across every edit, so that I can experiment freely.

### Mixer and video channel strip

36. As a musician, I want each video track's fader to be its opacity, so that mixing video feels like mixing audio.
37. As a musician, I want a blend mode per video track (normal, add, multiply, screen, difference), so that layers can combine instead of only covering each other.
38. As a musician, I want track order to decide stacking, top track in front, so that layering is predictable.
39. As a musician, I want position, scale, rotation and crop per video track, so that I can build picture-in-picture and split screens.
40. As a musician, I want to drag and resize a track's picture directly in the viewer, so that framing is visual.
41. As a musician, I want built-in effects on video tracks (colour adjust, blur, pixelate, feedback, displacement), so that I have full-resolution effects that always run live.
42. As a musician, I want mute and solo on every track, so that I can isolate layers.
43. As a musician, I want each audio track to have a volume fader and pan, so that I can balance the mix.

### Audio Units

44. As a musician, I want to insert any of my installed Audio Unit effects on an audio track, so that I can process sound as in Logic.
45. As a musician, I want to open an Audio Unit's own window, so that I use the interface I know.
46. As a musician, I want to insert an Audio Unit on a video track, so that it processes the picture as a signal.
47. As a musician, I want each video Audio Unit slot to offer raster mode, so that the frame is read as one long waveform and delay, distortion and filters smear, crush and ring the image.
48. As a musician, I want raster mode to run live during playback, so that I can twist knobs and watch the picture move.
49. As a musician, I want each video Audio Unit slot to offer through-time mode, so that delay and reverb become motion trails and frame echoes.
50. As a musician, I want a wet/dry mix on each video Audio Unit slot, so that I can blend the bent picture with the sharp original.
51. As a musician, I want to bypass, reorder and remove effect slots, so that I can compare and rearrange a chain.
52. As a musician, I want a project "bend resolution" setting, so that I can trade live smoothness against finer detail.

### Automation

53. As a musician, I want to show an automation lane under any track and pick which parameter it shows, so that I can see and edit change over time.
54. As a musician, I want to click to add automation points and drag them, snapping to the grid, so that moves land on the beat.
55. As a musician, I want to automate opacity, transform, built-in effect parameters, audio volume and pan, so that the whole strip can move.
56. As a musician, I want to automate any Audio Unit parameter on audio and video tracks, so that effect moves are part of the arrangement.

### Viewer and export

57. As a musician, I want a viewer showing the composited picture at the playhead, so that I see the result of every layer and effect.
58. As a musician, I want playback to stay in sync between picture and sound, so that cutting to the beat is trustworthy.
59. As a musician, I want to export the whole timeline or the cycle range to a movie file, so that I get a finished video with sound.
60. As a musician, I want the export to look and sound exactly like the preview, so that there are no surprises.
61. As a musician, I want to choose the project's frame size and frame rate, so that output matches where it's going.

## Implementation Decisions

### Platform and languages

- Standalone macOS app, Apple silicon, built with Swift Package Manager and assembled into an app bundle by a script. Xcode is not installed on this machine, only the Command Line Tools, so nothing may depend on Xcode.
- **C++ (with Objective-C++ where it calls Apple frameworks)** for the whole engine: render graph, audio thread, plugin hosting, picture bender, decoders and frame cache.
- **Metal Shading Language** for compositing and built-in effects, compiled at runtime from source, which needs no Xcode.
- **Swift** for the project model, the plan compiler, project storage and the interface (AppKit timeline, SwiftUI panels).
- The seam between Swift and the engine is a plain C header. Swift hands the engine a compiled plan as plain data.
- Written from scratch. CamOrder is not forked.

### The engine owns playback

- The project compiles into an immutable **render plan**. One engine evaluates the plan at a given time and produces an audio buffer and a video frame.
- Playback evaluates in real time with the audio device as master clock; the picture follows the audio clock. Export runs the same evaluation as fast as it can. Preview and export are therefore the same code.
- An edit compiles a new plan and swaps it in atomically. The audio thread never locks, allocates or waits; retired plans are freed off the audio thread.
- AVFoundation and VideoToolbox are used only to decode and encode media. AVFoundation's composition, player and export session are not used.
- The engine timeline unit is audio sample frames at 48 kHz.

### Media

- Video is decoded by random-access decoders (sample cursor plus a decompression session) into a frame cache, with read-ahead in the direction of play. Any frame can be fetched in any order, so scrub, reverse and stretch are live.
- On import, long-GOP video (H.264, HEVC) is transcoded in the background to an all-intra editing proxy (ProRes Proxy, at most 1920 pixels on its long side) in the project cache. Playback uses the proxy once it exists; export uses the original. The proxy's place is derived from the original's path, so the project file does not record it.
- Audio files are decoded to 48 kHz float PCM when opened. A stretched region is time-stretched live, pitch preserved, as it plays.

### Picture pipeline

- Each video track renders its regions into its own texture, runs its effect chain, then is composited onto the master with opacity, blend mode and transform. Blend modes are computed in the fragment shader by reading the destination colour.
- Built-in effects (colour, blur, pixelate, feedback, displacement) are shaders at full project resolution. Feedback keeps whichever is brighter, this frame or the decayed previous output, so bright shapes leave trails even over a full-frame picture.

### Picture bending (Audio Units on video)

- A video frame is converted to a signal at a fixed **bend resolution**, processed by the Audio Unit, converted back and scaled up to the frame, then blended by the slot's wet/dry mix.
- The bend resolution is the same in preview and export. Default 320x180, with 480x270 and 640x360 available per project. A fixed size keeps what you see equal to what you export: time-based effects are measured in samples, so the same delay would move the picture five lines at one size and under one line at another, and Audio Units do not accept the megahertz sample rates that would compensate.
- **Raster mode:** the frame's red, green and blue values are read in scan order as one mono waveform. Because colours are interleaved, filters and delays also shift and bleed colour, like composite video. Runs live. Audio Unit state carries from frame to frame and resets on seek.
- **Through-time mode:** each pixel's values across successive frames form the signal. The engine reads ahead a chunk of frames (32 by default), runs the Audio Unit across each pixel's history, and caches the bent chunk before the playhead reaches it. Each chunk is preceded by the previous chunk as pre-roll so trails carry across chunk edges. Costs about twice raster mode. Until a chunk is ready (right after a seek or an edit) the track shows unbent.
- In through-time mode the Audio Unit is told it runs at 8 kHz, so one frame is one sample and a 4 ms delay is an echo 32 frames later. A reverb tail of two seconds is therefore 16,000 frames, about nine minutes of video. The slot's memory setting (32, 256 or 1024 frames) is how much of that the picture gets; whatever the effect does beyond it bleeds between neighbouring pixels instead. Effects earlier in the chain that carry state from frame to frame (feedback, another Audio Unit) are not seen by a through-time slot.
- Cost estimate for raster mode at the default bend resolution: about 5 million samples per second, roughly 100 times audio rate. Light plugins run live; heavy oversampling plugins may drop preview frames. Export is unaffected because it is not real-time.

### Audio Units

- Hosted out of process where the plugin allows it, so a plugin crash cannot take down the app, with in-process loading as the fallback.
- An Audio Unit on an audio track and an Audio Unit on a video track are separate instances of the same hosting code.
- Parameter automation is delivered through the plugin's real-time-safe scheduling call.
- Plugin latency is compensated per track by feeding the track early.

### Time

- Timeline positions and lengths are integer ticks, 960 per quarter note.
- Media time is integer flicks (1/705,600,000 of a second), which divides evenly by every common frame rate and sample rate.
- The plan compiler converts both to sample frames. One tempo per project is exposed; changing it keeps each region's real-time duration.

### Modules

Five deep modules. No protocol is introduced unless two adapters exist.

1. **Project model (Swift).** Value types for project, tracks, regions, effect slots and automation, plus every edit as a pure mutation of a project value. No framework dependencies. Undo is a stack of project values. This is the main test surface.
2. **Engine (C++).** Interface: open media, create plugins, set plan, transport, attach a display layer, export. Hides the audio thread, decoders, frame cache, Metal compositing, the picture bender and plugin hosting.
3. **Plan compiler (Swift).** Takes a project, returns a render plan. Hides tick-to-sample conversion, loops, stretch, crossfades from overlap, solo logic and automation curves.
4. **Project store (Swift).** Create, open, autosave, proxy generation, collect media, relink.
5. **App interface (Swift).** Timeline, viewer, mixer, inspector. Sends edits to the project model and redraws from the result.

### Model decisions

- A project is a folder package holding one JSON document and a disposable cache (proxies, thumbnails, waveforms).
- Loop is repetition at evaluation time; stretch is a speed on the region; reverse is a flag; trims and fades are region fields. None of these touch the source media.
- Crossfades are computed from overlap; there is no separate crossfade object.
- Automation is a list of tick/value points per parameter with linear interpolation. Audio Unit parameters are addressed by the plugin's own parameter address.
- Video tracks carry picture only. A video file's soundtrack is imported as a separate, unlinked audio region.
- Media is referenced by path; Collect copies files into the package and rewrites references.

### Build order

Timeline editing comes first, then the rest in this order:

1. Project model with all region operations; engine core (audio and video playback, transport, export); app shell with tracks, import, thumbnails and waveforms, grid, viewer and autosave.
2. Mixer: opacity, blend modes, transform, fades and crossfades, mute/solo, audio volume and pan.
3. Automation lanes.
4. Built-in GPU effects.
5. Audio Units on audio tracks.
6. Audio Units on video: raster mode, then through-time.
7. Editing proxies, collect media and relink.

## Testing Decisions

- A good test exercises a module through its interface and asserts on what a caller can observe. No test reaches into a module's internals.
- **Project model:** unit tests for every region operation, including marquee splitting, loop, stretch, fades, overlap crossfades, snap and undo. Pure functions, no fixtures beyond a small project value.
- **Engine, through the plan compiler:** tests generate small synthetic clips (solid colours, a tone), compile and export a project, then read the output back and assert on frame colours, duration and audio level at chosen times.
- **Picture bender:** tests run a frame through Apple's built-in Audio Units (delay, low-pass) and assert the output differs in the expected direction, and that an identity pass returns the input.
- **Reverse and stretch:** a reversed clip's first exported frame equals the source's last; a clip stretched to double length exports at double duration.
- **Project store:** save, reopen and compare; collect then delete originals and reopen.
- Tests use Swift Testing, which ships with the Command Line Tools. XCTest does not.
- The interface is verified by launching the app and checking behaviour by hand and by screenshot, not by automated UI tests.
- There is no prior art; this is a new codebase.

## Out of Scope

- MIDI, software instruments and audio recording.
- Camera or screen capture.
- Any sync with Logic. Audio arrives as bounced files.
- Buses, sends and group tracks.
- Tempo changes within a project.
- Recording automation by moving controls during playback. Automation is drawn.
- Audio Unit instruments and MIDI effects.
- Flex-style editing inside a region, quantise, glue/join, folders, take comping.
- Titles, text and transitions other than crossfade.
- Windows, Intel Macs, App Store distribution, code signing beyond what's needed to run locally.

## Status (2 October 2026)

Built and covered by tests (161 passing): the project model and every region operation, including links; the engine's audio graph with live pitch-preserving stretch, reverse and plugin latency compensation; random-access decoding, compositing, all five built-in effects, export; Audio Units on audio tracks and on video in both bend modes, with automation, saved settings and selectable through-time memory; the plan compiler; project storage, proxies and collect.

Built and seen working in the running app: import, timeline drawing with thumbnails and waveforms, playback with the picture following the audio clock, moving regions, linked selection, the inspector, automation lanes, live raster bending, the mixer window with moving meters.

Built but not exercised by hand: the trim, loop, stretch and fade handles; the marquee tool; rubber-band selection; option-drag copy; keyboard shortcuts and menus, including Link, Unlink and the nudge commands; plugin windows; drops from Finder; the export and project panels; dragging the picture in the viewer.

Decisions made while building the second round:

- **Live stretch:** a stretched region runs through Apple's time-pitch unit on the audio thread, one unit per region, kept from plan to plan so a speed drag is continuous. Reverse at normal speed is a plain backwards read. The engine no longer makes stretched or reversed copies of audio.
- **Latency compensation:** a track whose plugins delay their sound is fed that much early, so its output lands on time; after a jump the chain is first run up on the audio just ahead. No delay lines and no added output latency. Latency is read when a plan is made and after a plugin parameter changes.
- **Picture latency:** in raster mode the scan is rotated back by the plugin's delay; in through-time mode the run continues into the next chunk by the delay and is read that much later.
- **Through-time memory:** selectable per slot as 32, 256 or 1024 frames. Longer chunks give the effect a longer run-up for the same work per frame, at the price of a longer wait after a change (the track shows unbent until the chunk is ready). Chunks live in unlinked temporary files, not in memory, and are remade only when something the slot can see changes.
- **Linked picture and sound:** regions carry an optional link. Selecting a region selects what it is linked to, and edge edits reach linked partners by the same amount. An imported video's picture and sound start linked; Unlink and Link are the whole feature.
- **Mixer:** a separate window of channel strips with meters. There is no master fader; the output strip only shows level.
- **Time signature:** the project has beats per measure and a beat unit (2, 4, 8 or 16). Measures, beats, snapping and the position readout all follow it; finer snap divisions are fractions of the signature's beat and are named as note values. Tempo stays in quarter notes per minute, as in Logic. One signature per project.
- **Nudge:** Option-arrow moves the selection by one grid division, Shift-Option-arrow by one video frame, both off the grid if need be.

## Further Notes

- Working name and location are placeholders: "VideoDAW" in the visuals folder. Rename freely.
- The interleaved-colour raster signal is a look decision. Processing brightness only would give a cleaner, less colour-shifting result and is a small change inside the engine's picture bender.
- Third-party Audio Units vary in how they behave when rendered faster than real time. Any that refuse will be reported per slot, not crash the app.
- The build order means that if time runs short, the unfinished work is at the end of the list, and everything before it works.
