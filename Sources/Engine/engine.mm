// C interface, plan copying and plan lifetime.
#include "core.hpp"

// ---- Plan copy ---------------------------------------------------------------------------

static Effect copyEffect(VDEngine *e, const VDEffect &src) {
    Effect fx;
    fx.id = src.id;
    fx.kind = src.kind;
    fx.bypass = src.bypass != 0;
    fx.bendMode = src.bendMode;
    fx.memoryFrames = std::min(4096, std::max(8, src.memoryFrames > 0 ? src.memoryFrames : 32));
    if (src.kind == VD_FX_AU && src.au >= 0 && size_t(src.au) < e->plugins.size()) fx.plugin = e->plugins[src.au];
    if (fx.plugin && fx.plugin->latencyStale.exchange(false)) fx.plugin->refreshLatency();
    fx.mix = Curve(src.mix);
    for (int i = 0; i < VD_FX_PARAMS; i++) fx.params[i] = Curve(src.params[i]);
    for (int i = 0; i < src.auParamCount; i++)
        fx.auParams.emplace_back(src.auParams[i].address, Curve(src.auParams[i].curve));
    return fx;
}

static Plan *copyPlan(VDEngine *e, const VDPlan *src) {
    std::lock_guard<std::mutex> lock(e->tableMutex);
    static std::atomic<uint64_t> serial{0};
    Plan *plan = new Plan;
    plan->serial = ++serial;
    plan->width = src->width;
    plan->height = src->height;
    plan->fps = src->fps > 0 ? src->fps : 30;
    plan->bendWidth = src->bendWidth;
    plan->bendHeight = src->bendHeight;
    for (int t = 0; t < src->videoTrackCount; t++) {
        const VDVideoTrack &in = src->videoTracks[t];
        VideoTrack out;
        out.id = in.id;
        for (int i = 0; i < in.regionCount; i++) {
            const VDVideoRegion &r = in.regions[i];
            if (r.media < 0 || size_t(r.media) >= e->videoMedia.size() || r.contentLength <= 0) continue;
            out.regions.push_back({r, e->videoMedia[r.media]});
        }
        for (int i = 0; i < in.effectCount; i++) out.effects.push_back(copyEffect(e, in.effects[i]));
        out.opacity = Curve(in.opacity);
        out.x = Curve(in.x);
        out.y = Curve(in.y);
        out.scale = Curve(in.scale);
        out.rotation = Curve(in.rotation);
        out.cropLeft = Curve(in.cropLeft);
        out.cropRight = Curve(in.cropRight);
        out.cropTop = Curve(in.cropTop);
        out.cropBottom = Curve(in.cropBottom);
        out.blend = in.blend;
        out.muted = in.muted != 0;
        plan->video.push_back(std::move(out));
    }
    // Meters follow tracks by id; a track that has gone frees its meter.
    for (int m = 1; m < kMeters; m++) {
        uint64_t id = e->meters[m].id.load();
        bool live = false;
        for (int t = 0; t < src->audioTrackCount; t++) live = live || src->audioTracks[t].id == id;
        if (!live) e->meters[m].id.store(0);
    }
    std::unordered_map<uint64_t, std::shared_ptr<Stretcher>> stretchers;
    for (int t = 0; t < src->audioTrackCount; t++) {
        const VDAudioTrack &in = src->audioTracks[t];
        AudioTrack out;
        out.id = in.id;
        for (int i = 0; i < in.regionCount; i++) {
            const VDAudioRegion &r = in.regions[i];
            if (r.media < 0 || size_t(r.media) >= e->audioMedia.size() || r.contentLength <= 0) continue;
            AudioRegion region = {r, e->audioMedia[r.media], nullptr};
            if (std::fabs(r.speed - 1) > 1e-9) {
                // A region keeps its stretcher from plan to plan, so dragging its speed is seamless.
                auto known = e->stretchers.find(r.id);
                region.stretcher = known != e->stretchers.end() ? known->second : std::make_shared<Stretcher>();
                stretchers[r.id] = region.stretcher;
            }
            out.regions.push_back(std::move(region));
        }
        for (int i = 0; i < in.effectCount; i++) {
            out.effects.push_back(copyEffect(e, in.effects[i]));
            const Effect &fx = out.effects.back();
            if (fx.kind == VD_FX_AU && !fx.bypass && fx.plugin) out.latency += fx.plugin->latency.load();
        }
        out.volume = Curve(in.volume);
        out.pan = Curve(in.pan);
        out.muted = in.muted != 0;
        for (int m = 1; m < kMeters && out.meter < 0; m++)
            if (e->meters[m].id.load() == in.id) out.meter = m;
        for (int m = 1; m < kMeters && out.meter < 0; m++) {
            if (e->meters[m].id.load() != 0) continue;
            e->meters[m].id.store(in.id);
            e->meters[m].peak.store(0);
            out.meter = m;
        }
        plan->audio.push_back(std::move(out));
    }
    e->stretchers = std::move(stretchers);
    return plan;
}

// Frees a retired plan once no reader can still hold it.
static void retire(VDEngine *e, Plan *old) {
    if (!old) return;
    dispatch_async(e->reclaimQueue, ^{
        for (Reader *r : {&e->audioReader, &e->videoReader, &e->exportReader}) {
            uint64_t seen = r->epoch.load();
            while ((seen & 1) && r->epoch.load() == seen) usleep(500);
        }
        delete old;
    });
}

// ---- Lifecycle ---------------------------------------------------------------------------

// Engines that have not been destroyed, so a late asynchronous callback can tell.
static std::mutex gLiveMutex;
static std::vector<VDEngine *> gLive;

bool engineIsLive(VDEngine *e) {
    std::lock_guard<std::mutex> lock(gLiveMutex);
    return std::find(gLive.begin(), gLive.end(), e) != gLive.end();
}

VDEngine *vd_create(bool realtime) {
    VDEngine *e = new VDEngine;
    e->realtime = realtime;
    e->reclaimQueue = dispatch_queue_create("videodaw.reclaim", DISPATCH_QUEUE_SERIAL);
    e->live.store(new Plan);
    e->scratch.meters = e->meters;
    e->renderer = makeRenderer(e);
    {
        std::lock_guard<std::mutex> lock(gLiveMutex);
        gLive.push_back(e);
    }
    if (realtime) {
        startAudioOutput(e);
        e->videoThread = std::thread([e] { videoThreadMain(e); });
    }
    return e;
}

void vd_destroy(VDEngine *e) {
    if (!e) return;
    {
        std::lock_guard<std::mutex> lock(gLiveMutex);
        std::erase(gLive, e);
    }
    e->running.store(false);
    e->wake.notify_all();
    if (e->videoThread.joinable()) e->videoThread.join();
    stopAudioOutput(e);
    while (e->exporting.load()) usleep(1000);
    dispatch_sync(e->reclaimQueue, ^{});
    // Media and plugins go before the engine itself: their background work refers to it.
    delete e->live.exchange(nullptr);
    {
        std::lock_guard<std::mutex> lock(e->tableMutex);
        e->videoMedia.clear();
        e->audioMedia.clear();
        e->plugins.clear();
        e->stretchers.clear();
    }
    destroyRenderer(e->renderer);
    delete e;
}

void vd_set_plan(VDEngine *e, const VDPlan *plan) {
    Plan *fresh = copyPlan(e, plan);
    retire(e, e->live.exchange(fresh));
    e->markDirty();
}

// ---- Media -------------------------------------------------------------------------------

int32_t vd_video_open(VDEngine *e, const char *path) {
    std::string key(path);
    {
        std::lock_guard<std::mutex> lock(e->tableMutex);
        auto found = e->videoKeys.find(key);
        if (found != e->videoKeys.end()) return found->second;
    }
    std::shared_ptr<VideoMedia> media = openVideo(@(path), e);
    if (!media) return -1;
    std::lock_guard<std::mutex> lock(e->tableMutex);
    e->videoMedia.push_back(media);
    int handle = int(e->videoMedia.size()) - 1;
    e->videoKeys[key] = handle;
    return handle;
}

bool vd_video_info(VDEngine *e, int32_t media, double *duration, int32_t *width, int32_t *height, double *fps) {
    std::shared_ptr<VideoMedia> m;
    {
        std::lock_guard<std::mutex> lock(e->tableMutex);
        if (media < 0 || size_t(media) >= e->videoMedia.size()) return false;
        m = e->videoMedia[media];
    }
    return videoInfo(*m, duration, width, height, fps);
}

int32_t vd_audio_open(VDEngine *e, const char *path) {
    std::string key(path);
    {
        std::lock_guard<std::mutex> lock(e->tableMutex);
        auto found = e->audioKeys.find(key);
        if (found != e->audioKeys.end()) return found->second;
    }
    std::shared_ptr<AudioMedia> media = decodeAudio(@(path));
    if (!media) return -1;
    std::lock_guard<std::mutex> lock(e->tableMutex);
    auto found = e->audioKeys.find(key);
    if (found != e->audioKeys.end()) return found->second;
    e->audioMedia.push_back(media);
    int handle = int(e->audioMedia.size()) - 1;
    e->audioKeys[key] = handle;
    return handle;
}

static std::shared_ptr<AudioMedia> audioAt(VDEngine *e, int32_t media) {
    std::lock_guard<std::mutex> lock(e->tableMutex);
    if (media < 0 || size_t(media) >= e->audioMedia.size()) return nullptr;
    return e->audioMedia[media];
}

int64_t vd_audio_frames(VDEngine *e, int32_t media) {
    auto m = audioAt(e, media);
    return m ? m->frames() : 0;
}

void vd_audio_peaks(VDEngine *e, int32_t media, float *out, int32_t count) {
    auto m = audioAt(e, media);
    for (int i = 0; i < count; i++) out[i] = 0;
    if (!m || count <= 0 || m->frames() == 0) return;
    int64_t frames = m->frames();
    for (int i = 0; i < count; i++) {
        int64_t a = frames * i / count, b = std::max<int64_t>(a + 1, frames * (i + 1) / count);
        // Stride through long buckets; a waveform overview does not need every sample.
        int64_t step = std::max<int64_t>(1, (b - a) / 256);
        float peak = 0;
        for (int64_t f = a; f < b && f < frames; f += step) {
            peak = std::max(peak, std::fabs(m->left[f]));
            peak = std::max(peak, std::fabs(m->right[f]));
        }
        out[i] = std::min(1.0f, peak);
    }
}

void vd_free(void *p) { free(p); }

float vd_track_level(VDEngine *e, uint64_t trackId) {
    if (trackId == 0) return e->meters[0].peak.exchange(0);
    for (int m = 1; m < kMeters; m++)
        if (e->meters[m].id.load() == trackId) return e->meters[m].peak.exchange(0);
    return 0;
}

bool vd_bend_busy(VDEngine *e) { return bendBusy(e->renderer); }

// ---- Transport ---------------------------------------------------------------------------

void vd_play(VDEngine *e) {
    if (e->exporting.load()) return;
    e->playing.store(true);
    e->markDirty();
}

void vd_stop(VDEngine *e) {
    e->playing.store(false);
    e->markDirty();
}

bool vd_is_playing(VDEngine *e) { return e->playing.load(); }

void vd_seek(VDEngine *e, int64_t time) {
    if (time < 0) time = 0;
    // While playing, the audio thread owns the position and applies the request itself.
    if (e->playing.load() && e->output) e->seekRequest.store(time);
    else e->position.store(time);
    e->markDirty();
}

int64_t vd_position(VDEngine *e) {
    int64_t pending = e->seekRequest.load();
    return pending >= 0 ? pending : e->position.load();
}

void vd_set_cycle(VDEngine *e, bool on, int64_t start, int64_t end) {
    e->cycleStart.store(start);
    e->cycleEnd.store(end);
    e->cycleOn.store(on && end > start);
}

void vd_attach_layer(VDEngine *e, void *caMetalLayer) {
    std::lock_guard<std::mutex> lock(e->layerMutex);
    e->layer = (__bridge CAMetalLayer *)caMetalLayer;
    configureLayer(e->renderer, e->layer);
    e->markDirty();
}

void vd_export(VDEngine *e, const char *path, int64_t start, int64_t end,
               VDProgress progress, VDDone done, void *ctx) {
    NSString *target = @(path);
    e->playing.store(false);
    e->exporting.store(true);
    // The plan is pinned here, on the caller's thread, so the export renders exactly the
    // project as it was when asked, whatever is edited afterwards.
    const Plan *plan = e->enter(e->exportReader);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        runExport(e, plan, target, start, end, progress, done, ctx);
    });
}
