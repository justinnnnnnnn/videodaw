// VideoDAW engine. One engine evaluates a render plan at a time t, producing an audio
// buffer and a video frame. Playback evaluates in real time, slaved to the audio device
// clock; export evaluates the same plan as fast as it can.
//
// All timeline times are sample frames at VD_SAMPLE_RATE. Unless noted, functions are
// called from the main thread.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define VD_SAMPLE_RATE 48000

typedef struct VDEngine VDEngine;

// ---- Plan -----------------------------------------------------------------------------

typedef struct { int64_t time; float value; } VDPoint;

// A parameter over time. With count == 0 the value is `constant`; otherwise points
// (sorted by time) are linearly interpolated and held flat outside their range.
typedef struct { float constant; const VDPoint *points; int32_t count; } VDCurve;

enum { VD_FX_AU = 0, VD_FX_COLOR, VD_FX_BLUR, VD_FX_PIXELATE, VD_FX_FEEDBACK, VD_FX_DISPLACE };
enum { VD_BEND_RASTER = 0, VD_BEND_THROUGH_TIME = 1 };
enum { VD_BLEND_NORMAL = 0, VD_BLEND_ADD, VD_BLEND_MULTIPLY, VD_BLEND_SCREEN, VD_BLEND_DIFFERENCE };

typedef struct { uint64_t address; VDCurve curve; } VDAUParam;

#define VD_FX_PARAMS 4

typedef struct {
    uint64_t id;      // stable across plans, so per-effect state survives a plan swap
    int32_t kind;     // VD_FX_*
    int32_t bypass;
    int32_t au;       // plugin handle from vd_au_create, for VD_FX_AU
    int32_t bendMode; // VD_BEND_*, for VD_FX_AU on a video track
    // Through-time only: how many frames back the effect remembers. Each pixel is processed
    // in chunks of this many frames with the previous chunk as run-up. 0 means 32.
    int32_t memoryFrames;
    VDCurve mix;      // wet/dry for VD_FX_AU on a video track
    VDCurve params[VD_FX_PARAMS]; // built-in effect parameters, by index
    const VDAUParam *auParams;
    int32_t auParamCount;
} VDEffect;

// One iteration lasts `contentLength` and shows the source from `sourceStart` for
// contentLength * speed (backwards if reversed). length > contentLength loops.
typedef struct {
    int32_t media;
    int32_t muted;
    int64_t start, length, contentLength;
    double sourceStart; // seconds into the source
    double speed;
    int32_t reversed;
    int64_t fadeIn, fadeOut;
} VDVideoRegion;

// One iteration lasts `contentLength` and plays the source from `sourceOffset` (in frames
// of the media) for contentLength * speed frames, backwards if reversed. A speed other
// than 1 is time-stretched live with pitch preserved. length > contentLength loops.
typedef struct {
    uint64_t id; // stable across plans, so a stretch in progress carries over a plan swap
    int32_t media;
    int32_t muted;
    int64_t start, length, contentLength;
    int64_t sourceOffset;
    double speed;
    int32_t reversed;
    int64_t fadeIn, fadeOut;
} VDAudioRegion;

typedef struct {
    uint64_t id;
    const VDVideoRegion *regions; // drawn in order, later regions on top
    int32_t regionCount;
    const VDEffect *effects;
    int32_t effectCount;
    VDCurve opacity, x, y, scale, rotation, cropLeft, cropRight, cropTop, cropBottom;
    int32_t blend; // VD_BLEND_*
    int32_t muted;
} VDVideoTrack;

typedef struct {
    uint64_t id;
    const VDAudioRegion *regions;
    int32_t regionCount;
    const VDEffect *effects;
    int32_t effectCount;
    VDCurve volume, pan;
    int32_t muted;
} VDAudioTrack;

typedef struct {
    int32_t width, height;
    double fps;
    int32_t bendWidth, bendHeight;
    const VDVideoTrack *videoTracks; // back to front
    int32_t videoTrackCount;
    const VDAudioTrack *audioTracks;
    int32_t audioTrackCount;
} VDPlan;

// ---- Lifecycle ------------------------------------------------------------------------

// `realtime` false creates an engine with no audio device and no display, for export
// and tests.
VDEngine *vd_create(bool realtime);
void vd_destroy(VDEngine *);

// Deep-copies the plan and swaps it in atomically. Safe during playback.
void vd_set_plan(VDEngine *, const VDPlan *);

// ---- Media ----------------------------------------------------------------------------

// Returns a handle >= 0, or -1 if the file has no decodable video.
int32_t vd_video_open(VDEngine *, const char *path);
bool vd_video_info(VDEngine *, int32_t media, double *duration, int32_t *width, int32_t *height, double *fps);

// Decodes the file's audio to 48 kHz stereo float. Blocks while decoding; call off the
// main thread. The same path returns the same handle. Returns -1 if there is no audio.
int32_t vd_audio_open(VDEngine *, const char *path);
int64_t vd_audio_frames(VDEngine *, int32_t media);
// Fills `out` with `count` peak magnitudes (0...1) spread evenly across the media.
void vd_audio_peaks(VDEngine *, int32_t media, float *out, int32_t count);

// ---- Audio Units ----------------------------------------------------------------------

typedef void (*VDAUReady)(void *ctx, int32_t au); // au < 0 on failure; called on the main thread
// `state` is the plugin's saved state as a binary property list, or NULL.
void vd_au_create(VDEngine *, uint32_t type, uint32_t subType, uint32_t manufacturer,
                  const void *state, int32_t stateLength, VDAUReady ready, void *ctx);
void vd_au_destroy(VDEngine *, int32_t au);
// Returns a malloc'd binary property list; free with vd_free.
void *vd_au_copy_state(VDEngine *, int32_t au, int32_t *length);
void vd_free(void *);
int32_t vd_au_param_count(VDEngine *, int32_t au);
bool vd_au_param_info(VDEngine *, int32_t au, int32_t index, uint64_t *address,
                      char *name, int32_t nameCapacity, float *min, float *max, float *value);
void vd_au_set_param(VDEngine *, int32_t au, uint64_t address, float value);
// The view controller arrives retained (+1); the receiver owns it. NULL if the plugin has no view.
typedef void (*VDAUView)(void *ctx, void *nsViewController);
void vd_au_request_view(VDEngine *, int32_t au, VDAUView ready, void *ctx);

// ---- Transport ------------------------------------------------------------------------

void vd_play(VDEngine *);
void vd_stop(VDEngine *);
bool vd_is_playing(VDEngine *);
void vd_seek(VDEngine *, int64_t time);
int64_t vd_position(VDEngine *);
void vd_set_cycle(VDEngine *, bool on, int64_t start, int64_t end);

// ---- Meters ---------------------------------------------------------------------------

// The loudest sample (linear, 1 = full scale) an audio track has put out since this was
// last asked. Track id 0 is the master output.
float vd_track_level(VDEngine *, uint64_t trackId);

// True while through-time picture bending is still being worked out in the background.
bool vd_bend_busy(VDEngine *);

// ---- Display --------------------------------------------------------------------------

// The engine draws the composited picture into this CAMetalLayer.
void vd_attach_layer(VDEngine *, void *caMetalLayer);

// ---- Export ---------------------------------------------------------------------------

typedef void (*VDProgress)(void *ctx, double fraction);
typedef void (*VDDone)(void *ctx, const char *error); // error is NULL on success
// Renders [start, end) to a QuickTime movie with H.264 video and AAC audio. Runs on a
// background thread; callbacks arrive on the main thread. Playback is stopped first.
void vd_export(VDEngine *, const char *path, int64_t start, int64_t end,
               VDProgress progress, VDDone done, void *ctx);

#ifdef __cplusplus
}
#endif
