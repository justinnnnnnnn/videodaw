// Internal engine types shared by the engine's translation units.
#pragma once
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>

#include "engine.h"
#include <algorithm>
#include <atomic>
#include <condition_variable>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

// ---- Plan (the engine's own deep copy, with handles resolved to objects) ---------------

struct Curve {
    float constant = 0;
    std::vector<VDPoint> points;

    Curve() = default;
    explicit Curve(const VDCurve &c) : constant(c.constant) {
        if (c.points && c.count > 0) points.assign(c.points, c.points + c.count);
    }
    // Real-time safe.
    float at(int64_t t) const {
        if (points.empty()) return constant;
        if (t <= points.front().time) return points.front().value;
        if (t >= points.back().time) return points.back().value;
        size_t lo = 0, hi = points.size() - 1;
        while (hi - lo > 1) {
            size_t mid = (lo + hi) / 2;
            if (points[mid].time <= t) lo = mid; else hi = mid;
        }
        const VDPoint &a = points[lo], &b = points[hi];
        double f = double(t - a.time) / double(b.time - a.time);
        return float(a.value + (b.value - a.value) * f);
    }
};

struct AudioMedia {
    std::vector<float> left, right;
    int64_t frames() const { return int64_t(left.size()); }
};

struct VideoMedia;
struct Plugin;
struct Stretcher;

struct Effect {
    uint64_t id = 0;
    int kind = 0;
    bool bypass = false;
    int bendMode = 0;
    int memoryFrames = 32;
    std::shared_ptr<Plugin> plugin;
    Curve mix;
    Curve params[VD_FX_PARAMS];
    std::vector<std::pair<uint64_t, Curve>> auParams;
};

struct AudioRegion {
    VDAudioRegion r;
    std::shared_ptr<AudioMedia> media;
    std::shared_ptr<Stretcher> stretcher; // set when the region's speed is not 1
};

struct VideoRegion {
    VDVideoRegion r;
    std::shared_ptr<VideoMedia> media;
};

struct AudioTrack {
    uint64_t id = 0;
    std::vector<AudioRegion> regions;
    std::vector<Effect> effects;
    Curve volume, pan;
    bool muted = false;
    int64_t latency = 0; // samples the track's plugins delay its sound by
    int meter = -1;      // index into the engine's meters
};

struct VideoTrack {
    uint64_t id = 0;
    std::vector<VideoRegion> regions;
    std::vector<Effect> effects;
    Curve opacity, x, y, scale, rotation, cropLeft, cropRight, cropTop, cropBottom;
    int blend = 0;
    bool muted = false;
};

struct Plan {
    uint64_t serial = 0; // unique per plan, so cached work can tell plans apart
    int width = 1920, height = 1080;
    double fps = 30;
    int bendWidth = 320, bendHeight = 180;
    std::vector<VideoTrack> video;
    std::vector<AudioTrack> audio;
};

// ---- Audio Unit hosting ----------------------------------------------------------------

struct Plugin {
    static constexpr int kMaxFrames = 4096;
    AUAudioUnit *unit = nil;
    AURenderBlock render = nil;
    AUScheduleParameterBlock schedule = nil;
    AURenderPullInputBlock pull = nil;
    std::vector<float> inLeft, inRight;
    AudioBufferList *out = nullptr;
    double sampleTime = 0;
    double rate = VD_SAMPLE_RATE;
    // What the unit reports as its delay, in samples at `rate`. Refreshed on the main
    // thread whenever a plan is made.
    std::atomic<int64_t> latency{0};
    std::atomic<bool> latencyStale{true};
    void refreshLatency();
    AUParameterObserverToken observer = nullptr;
    // Set when a parameter is changed from outside the plan (the plugin's own window).
    std::atomic<bool> changed{false};

    ~Plugin();
    // Re-prepares the unit at another sample rate. Returns false, keeping the old rate,
    // if the unit refuses it.
    bool setRate(double newRate);
    // Processes stereo audio in place. Real-time safe.
    void process(float *left, float *right, int frames);
    void setParam(uint64_t address, float value);
    void reset();
};

// ---- Plan readers -----------------------------------------------------------------------

// A thread that reads the live plan brackets each use with enter/exit. A retired plan is
// freed only once every reader has been seen outside or moved on, so readers never lock.
struct Reader {
    std::atomic<uint64_t> epoch{0}; // odd while inside
};

struct Renderer;

// Live time-stretch for one audio region, pitch preserved.
struct Stretcher {
    AudioUnit unit = nullptr;
    AudioBufferList *out = nullptr;
    const AudioMedia *media = nullptr; // set for the duration of a render
    int64_t readAt = 0;                // the next source frame the unit will pull
    int direction = 1;
    int64_t latency = 0;
    double rate = 1;
    double sampleTime = 0;
    int64_t expectedTime = INT64_MIN, expectedWithin = INT64_MIN;
    std::vector<float> left, right;

    Stretcher();
    ~Stretcher();
    bool ok() const { return unit != nullptr; }
    // Produces `frames` of the region's sound starting `within` frames into an iteration,
    // for timeline position `time`. Real-time safe.
    void render(const VDAudioRegion &r, const AudioMedia &source, int64_t time, int64_t within, int frames);
};

// A track's peak output since it was last read.
struct Meter {
    std::atomic<uint64_t> id{0};
    std::atomic<float> peak{0};
};
static const int kMeters = 128; // meter 0 is the master output

// Where each latent track's plugin chain has got to, so a jump can be told from playing on.
struct TrackClock {
    uint64_t id = 0;
    int64_t expected = INT64_MIN;
};

// The working state of one audio render context: the device callback, or an export.
struct AudioScratch {
    std::vector<float> left, right, regionLeft, regionRight;
    TrackClock clocks[64];
    Meter *meters = nullptr;
    AudioScratch()
        : left(Plugin::kMaxFrames), right(Plugin::kMaxFrames), regionLeft(Plugin::kMaxFrames),
          regionRight(Plugin::kMaxFrames) {}
    TrackClock &clock(uint64_t id) {
        TrackClock *spare = &clocks[0];
        for (TrackClock &c : clocks) {
            if (c.id == id) return c;
            if (c.id == 0) spare = &c;
        }
        spare->id = id;
        spare->expected = INT64_MIN;
        return *spare;
    }
};

struct VDEngine {
    bool realtime = false;

    std::atomic<Plan *> live{nullptr};
    Reader audioReader, videoReader, exportReader;
    dispatch_queue_t reclaimQueue = nil;

    std::mutex tableMutex;
    std::vector<std::shared_ptr<AudioMedia>> audioMedia;
    std::map<std::string, int> audioKeys;
    std::vector<std::shared_ptr<VideoMedia>> videoMedia;
    std::map<std::string, int> videoKeys;
    std::vector<std::shared_ptr<Plugin>> plugins;
    std::unordered_map<uint64_t, std::shared_ptr<Stretcher>> stretchers; // by audio region id
    Meter meters[kMeters];

    // Transport. Written by the main thread and the audio thread.
    std::atomic<bool> playing{false};
    std::atomic<int64_t> position{0};
    std::atomic<int64_t> seekRequest{-1};
    std::atomic<bool> cycleOn{false};
    std::atomic<int64_t> cycleStart{0}, cycleEnd{0};

    // Where the audio clock was at a known host time, published by the audio thread.
    std::atomic<uint64_t> anchorSeq{0};
    std::atomic<uint64_t> anchorHost{0};
    std::atomic<int64_t> anchorPosition{0};

    AudioUnit output = nullptr;
    AudioScratch scratch;

    Renderer *renderer = nullptr;
    std::thread videoThread;
    std::atomic<bool> running{true};
    std::atomic<bool> dirty{true};
    std::atomic<bool> exporting{false};
    std::mutex wakeMutex;
    std::condition_variable wake;
    std::mutex layerMutex;
    CAMetalLayer *layer = nil;

    const Plan *enter(Reader &r) {
        r.epoch.fetch_add(1);
        return live.load();
    }
    void exit(Reader &r) { r.epoch.fetch_add(1); }
    void markDirty() {
        dirty.store(true);
        wake.notify_all();
    }
};

// engine.mm
bool engineIsLive(VDEngine *engine);

// audio.mm
void renderAudio(const Plan &plan, int64_t position, int frames, float *left, float *right, AudioScratch &scratch);
std::shared_ptr<AudioMedia> decodeAudio(NSString *path);
void startAudioOutput(VDEngine *engine);
void stopAudioOutput(VDEngine *engine);
void advanceTransport(VDEngine *engine, const Plan *plan, int frames, float *left, float *right);

// video.mm
std::shared_ptr<VideoMedia> openVideo(NSString *path, VDEngine *engine);
bool videoInfo(VideoMedia &media, double *duration, int32_t *width, int32_t *height, double *fps);
Renderer *makeRenderer(VDEngine *engine);
void destroyRenderer(Renderer *);
void configureLayer(Renderer *, CAMetalLayer *);
bool bendBusy(Renderer *);
void videoThreadMain(VDEngine *engine);
void runExport(VDEngine *engine, const Plan *plan, NSString *path, int64_t start, int64_t end,
               VDProgress progress, VDDone done, void *ctx);
