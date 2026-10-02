// Audio: media decoding, the audio graph, the output device and Audio Unit hosting.
#include "core.hpp"
#import <CoreAudioKit/CoreAudioKit.h>
#include <mach/mach_time.h>

// ---- Decoding ----------------------------------------------------------------------------

static AudioStreamBasicDescription planarFloat() {
    AudioStreamBasicDescription f = {};
    f.mSampleRate = VD_SAMPLE_RATE;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = 2;
    f.mBytesPerFrame = 4;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = 4;
    return f;
}

std::shared_ptr<AudioMedia> decodeAudio(NSString *path) {
    @autoreleasepool {
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
        NSArray<AVAssetTrack *> *tracks = [asset tracksWithMediaType:AVMediaTypeAudio];
        if (tracks.count == 0) return nullptr;
        NSError *error = nil;
        AVAssetReader *reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
        if (!reader) return nullptr;
        NSDictionary *settings = @{
            AVFormatIDKey : @(kAudioFormatLinearPCM),
            AVSampleRateKey : @(VD_SAMPLE_RATE),
            AVNumberOfChannelsKey : @2,
            AVLinearPCMBitDepthKey : @32,
            AVLinearPCMIsFloatKey : @YES,
            AVLinearPCMIsNonInterleaved : @NO,
            AVLinearPCMIsBigEndianKey : @NO,
        };
        AVAssetReaderAudioMixOutput *output =
            [AVAssetReaderAudioMixOutput assetReaderAudioMixOutputWithAudioTracks:tracks audioSettings:settings];
        if (![reader canAddOutput:output]) return nullptr;
        [reader addOutput:output];
        if (![reader startReading]) return nullptr;

        auto media = std::make_shared<AudioMedia>();
        std::vector<float> chunk;
        while (CMSampleBufferRef sample = [output copyNextSampleBuffer]) {
            CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sample);
            size_t bytes = block ? CMBlockBufferGetDataLength(block) : 0;
            chunk.resize(bytes / 4);
            if (bytes) CMBlockBufferCopyDataBytes(block, 0, bytes, chunk.data());
            size_t frames = chunk.size() / 2;
            size_t base = media->left.size();
            media->left.resize(base + frames);
            media->right.resize(base + frames);
            for (size_t i = 0; i < frames; i++) {
                media->left[base + i] = chunk[i * 2];
                media->right[base + i] = chunk[i * 2 + 1];
            }
            CFRelease(sample);
        }
        return media->frames() > 0 ? media : nullptr;
    }
}

// ---- Live time-stretch -------------------------------------------------------------------

// Apple's time-pitch unit pulls as much source as it needs for each block of output.
static OSStatus stretchInput(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *, UInt32,
                             UInt32 frames, AudioBufferList *io) {
    Stretcher *s = (Stretcher *)ref;
    int64_t total = s->media ? s->media->frames() : 0;
    for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
        float *dst = (float *)io->mBuffers[b].mData;
        if (!dst) continue;
        int64_t at = s->readAt;
        if (total == 0) {
            memset(dst, 0, frames * sizeof(float));
            continue;
        }
        const std::vector<float> &src = b == 0 ? s->media->left : s->media->right;
        for (UInt32 i = 0; i < frames; i++, at += s->direction) dst[i] = at >= 0 && at < total ? src[at] : 0;
    }
    s->readAt += int64_t(frames) * s->direction;
    return noErr;
}

Stretcher::Stretcher() : left(Plugin::kMaxFrames), right(Plugin::kMaxFrames) {
    AudioComponentDescription d = {kAudioUnitType_FormatConverter, kAudioUnitSubType_NewTimePitch,
                                   kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &d);
    if (!component || AudioComponentInstanceNew(component, &unit) != noErr) {
        unit = nullptr;
        return;
    }
    AudioStreamBasicDescription f = planarFloat();
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
    AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, sizeof f);
    UInt32 slice = Plugin::kMaxFrames;
    AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &slice, sizeof slice);
    AURenderCallbackStruct cb = {stretchInput, this};
    AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (AudioUnitInitialize(unit) != noErr) {
        AudioComponentInstanceDispose(unit);
        unit = nullptr;
        return;
    }
    Float64 seconds = 0;
    UInt32 size = sizeof seconds;
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &seconds, &size) == noErr)
        latency = int64_t(llround(seconds * VD_SAMPLE_RATE));
    out = (AudioBufferList *)calloc(1, offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer));
}

Stretcher::~Stretcher() {
    if (unit) {
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
    }
    free(out);
}

static void pullStretched(Stretcher &s, int frames, double &sampleTime) {
    s.out->mNumberBuffers = 2;
    s.out->mBuffers[0] = {1, UInt32(frames * 4), s.left.data()};
    s.out->mBuffers[1] = {1, UInt32(frames * 4), s.right.data()};
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp ts = {};
    ts.mSampleTime = sampleTime;
    ts.mFlags = kAudioTimeStampSampleTimeValid;
    if (AudioUnitRender(s.unit, &flags, &ts, 0, UInt32(frames), s.out) != noErr) {
        memset(s.left.data(), 0, frames * sizeof(float));
        memset(s.right.data(), 0, frames * sizeof(float));
    } else if (s.out->mBuffers[0].mData != s.left.data()) {
        memcpy(s.left.data(), s.out->mBuffers[0].mData, frames * sizeof(float));
        memcpy(s.right.data(), s.out->mBuffers[1].mData, frames * sizeof(float));
    }
    sampleTime += frames;
}

void Stretcher::render(const VDAudioRegion &r, const AudioMedia &source, int64_t time, int64_t within, int frames) {
    media = &source;
    double speed = std::min(32.0, std::max(1.0 / 32, r.speed));
    if (speed != rate) {
        AudioUnitSetParameter(unit, kNewTimePitchParam_Rate, kAudioUnitScope_Global, 0, AudioUnitParameterValue(speed), 0);
        rate = speed;
    }
    direction = r.reversed ? -1 : 1;
    // A jump (a seek, a loop coming round) restarts the unit at the right place in the
    // source; otherwise it simply carries on, even while the speed is being changed.
    if (time != expectedTime || within != expectedWithin) {
        AudioUnitReset(unit, kAudioUnitScope_Global, 0);
        int64_t into = int64_t(double(within) * r.speed);
        int64_t span = int64_t(double(r.contentLength) * r.speed);
        readAt = r.reversed ? r.sourceOffset + span - 1 - into : r.sourceOffset + into;
        // Run the unit's own delay out of the way, so what follows starts on that frame.
        for (int64_t skip = latency; skip > 0;) {
            int n = int(std::min<int64_t>(skip, 1024));
            pullStretched(*this, n, sampleTime);
            skip -= n;
        }
    }
    pullStretched(*this, frames, sampleTime);
    expectedTime = time + frames;
    expectedWithin = within + frames;
    media = nullptr;
}

// ---- The audio graph ---------------------------------------------------------------------

// Adds a region's sound for [position, position + frames) into left/right.
static void mixRegion(const AudioRegion &region, int64_t position, int frames, float *left, float *right,
                      AudioScratch &scratch) {
    const VDAudioRegion &r = region.r;
    if (r.muted) return;
    int64_t first = std::max<int64_t>(position, r.start);
    int64_t last = std::min<int64_t>(position + frames, r.start + r.length);
    if (first >= last) return;
    const AudioMedia &m = *region.media;
    int64_t total = m.frames();
    bool atSpeed = std::fabs(r.speed - 1) < 1e-9;
    bool stretch = !atSpeed && region.stretcher && region.stretcher->ok();

    // One run per loop iteration the block touches.
    for (int64_t t = first; t < last;) {
        int64_t local = t - r.start, within = local % r.contentLength;
        int n = int(std::min<int64_t>(last - t, r.contentLength - within));
        const float *sourceLeft = scratch.regionLeft.data(), *sourceRight = scratch.regionRight.data();
        if (stretch) {
            region.stretcher->render(r, m, t, within, n);
            sourceLeft = region.stretcher->left.data();
            sourceRight = region.stretcher->right.data();
        } else {
            int64_t span = int64_t(double(r.contentLength) * r.speed);
            for (int i = 0; i < n; i++) {
                // Without a stretcher a changed speed is plain resampling: pitch follows.
                int64_t into = atSpeed ? within + i : int64_t(double(within + i) * r.speed);
                int64_t source = r.reversed ? r.sourceOffset + span - 1 - into : r.sourceOffset + into;
                bool inside = source >= 0 && source < total;
                scratch.regionLeft[i] = inside ? m.left[source] : 0;
                scratch.regionRight[i] = inside ? m.right[source] : 0;
            }
        }
        float *outLeft = left + (t - position), *outRight = right + (t - position);
        for (int i = 0; i < n; i++) {
            int64_t at = local + i;
            float gain = 1;
            if (at < r.fadeIn) gain = float(at) / float(r.fadeIn);
            int64_t remaining = r.length - at;
            if (remaining < r.fadeOut) gain *= float(remaining) / float(r.fadeOut);
            outLeft[i] += sourceLeft[i] * gain;
            outRight[i] += sourceRight[i] * gain;
        }
        t += n;
    }
}

static void raise(Meter &meter, float peak) {
    if (peak > meter.peak.load(std::memory_order_relaxed)) meter.peak.store(peak, std::memory_order_relaxed);
}

// Renders `frames` (at most Plugin::kMaxFrames) of the plan at `position`. Real-time safe.
void renderAudio(const Plan &plan, int64_t position, int frames, float *left, float *right, AudioScratch &scratch) {
    memset(left, 0, frames * sizeof(float));
    memset(right, 0, frames * sizeof(float));
    float *trackLeft = scratch.left.data(), *trackRight = scratch.right.data();
    for (const AudioTrack &track : plan.audio) {
        if (track.muted) continue;
        // The track's regions through its plugins, for n frames of source starting at `at`.
        auto chain = [&](int64_t at, int n) {
            memset(trackLeft, 0, n * sizeof(float));
            memset(trackRight, 0, n * sizeof(float));
            for (const AudioRegion &region : track.regions) mixRegion(region, at, n, trackLeft, trackRight, scratch);
            for (const Effect &fx : track.effects) {
                if (fx.kind != VD_FX_AU || fx.bypass || !fx.plugin) continue;
                for (const auto &param : fx.auParams) fx.plugin->setParam(param.first, param.second.at(position));
                fx.plugin->process(trackLeft, trackRight, n);
            }
        };
        // Latency compensation: plugins that delay their sound are fed that much early, so
        // what comes out is on time. After a jump the chain is first run up on the source
        // just ahead, which the plugins then hold in their delay.
        if (track.latency > 0) {
            TrackClock &clock = scratch.clock(track.id);
            if (clock.expected != position) {
                for (int64_t at = position, remaining = track.latency; remaining > 0;) {
                    int n = int(std::min<int64_t>(remaining, Plugin::kMaxFrames));
                    chain(at, n);
                    at += n;
                    remaining -= n;
                }
            }
            clock.expected = position + frames;
        }
        chain(position + track.latency, frames);

        // Volume and pan ramp linearly across the block.
        float v0 = track.volume.at(position), v1 = track.volume.at(position + frames);
        float p0 = track.pan.at(position), p1 = track.pan.at(position + frames);
        float peak = 0;
        for (int i = 0; i < frames; i++) {
            float f = float(i) / float(frames);
            float volume = v0 + (v1 - v0) * f, pan = p0 + (p1 - p0) * f;
            float l = trackLeft[i] * volume * (pan <= 0 ? 1 : 1 - pan);
            float r = trackRight[i] * volume * (pan >= 0 ? 1 : 1 + pan);
            left[i] += l;
            right[i] += r;
            peak = std::max(peak, std::max(std::fabs(l), std::fabs(r)));
        }
        if (scratch.meters && track.meter > 0) raise(scratch.meters[track.meter], peak);
    }
    if (scratch.meters) {
        float peak = 0;
        for (int i = 0; i < frames; i++) peak = std::max(peak, std::max(std::fabs(left[i]), std::fabs(right[i])));
        raise(scratch.meters[0], peak);
    }
}

// Renders the next `frames` at the transport position and advances it, honouring the cycle.
void advanceTransport(VDEngine *e, const Plan *plan, int frames, float *left, float *right) {
    int done = 0;
    while (done < frames) {
        int64_t position = e->position.load();
        int n = std::min(frames - done, int(Plugin::kMaxFrames));
        bool wrap = false;
        if (e->cycleOn.load()) {
            int64_t end = e->cycleEnd.load();
            if (position < end && position + n >= end) {
                n = int(end - position);
                wrap = true;
            }
        }
        if (n > 0) renderAudio(*plan, position, n, left + done, right + done, e->scratch);
        e->position.store(wrap ? e->cycleStart.load() : position + n);
        done += n;
    }
}

// ---- Output device -----------------------------------------------------------------------

static OSStatus outputCallback(void *ref, AudioUnitRenderActionFlags *, const AudioTimeStamp *ts, UInt32,
                               UInt32 frames, AudioBufferList *io) {
    VDEngine *e = (VDEngine *)ref;
    float *left = (float *)io->mBuffers[0].mData;
    float *right = io->mNumberBuffers > 1 ? (float *)io->mBuffers[1].mData : left;

    int64_t seek = e->seekRequest.exchange(-1);
    if (seek >= 0) e->position.store(seek);

    // Publish where the clock is at this buffer's output time, for the picture to follow.
    e->anchorSeq.fetch_add(1);
    e->anchorHost.store(ts->mHostTime);
    e->anchorPosition.store(e->position.load());
    e->anchorSeq.fetch_add(1);

    if (!e->playing.load() || e->exporting.load()) {
        for (UInt32 b = 0; b < io->mNumberBuffers; b++) memset(io->mBuffers[b].mData, 0, io->mBuffers[b].mDataByteSize);
        return noErr;
    }
    const Plan *plan = e->enter(e->audioReader);
    advanceTransport(e, plan, int(frames), left, right);
    e->exit(e->audioReader);
    return noErr;
}

void startAudioOutput(VDEngine *e) {
    AudioComponentDescription d = {kAudioUnitType_Output, kAudioUnitSubType_DefaultOutput,
                                   kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &d);
    if (!component || AudioComponentInstanceNew(component, &e->output) != noErr) {
        e->output = nullptr;
        return;
    }
    AudioStreamBasicDescription f = planarFloat();
    AudioUnitSetProperty(e->output, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f);
    AURenderCallbackStruct cb = {outputCallback, e};
    AudioUnitSetProperty(e->output, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb);
    if (AudioUnitInitialize(e->output) != noErr || AudioOutputUnitStart(e->output) != noErr) {
        AudioComponentInstanceDispose(e->output);
        e->output = nullptr;
    }
}

void stopAudioOutput(VDEngine *e) {
    if (!e->output) return;
    AudioOutputUnitStop(e->output);
    AudioUnitUninitialize(e->output);
    AudioComponentInstanceDispose(e->output);
    e->output = nullptr;
}

// ---- Audio Unit hosting ------------------------------------------------------------------

Plugin::~Plugin() {
    if (observer) [unit.parameterTree removeParameterObserver:observer];
    if (unit.renderResourcesAllocated) [unit deallocateRenderResources];
    free(out);
}

static bool applyRate(AUAudioUnit *unit, double rate) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:2];
    return [unit.inputBusses[0] setFormat:format error:nil] && [unit.outputBusses[0] setFormat:format error:nil];
}

void Plugin::refreshLatency() {
    latency.store(int64_t(llround(unit.latency * rate)));
}

bool Plugin::setRate(double newRate) {
    if (newRate == rate) return true;
    if (unit.renderResourcesAllocated) [unit deallocateRenderResources];
    bool accepted = applyRate(unit, newRate);
    if (!accepted) applyRate(unit, rate);
    else rate = newRate;
    [unit allocateRenderResourcesAndReturnError:nil];
    render = unit.renderBlock;
    schedule = unit.scheduleParameterBlock;
    sampleTime = 0;
    refreshLatency(); // a delay counted in samples is a different one at another rate
    return accepted;
}

void Plugin::process(float *left, float *right, int frames) {
    if (!render) return;
    int done = 0;
    while (done < frames) {
        int n = std::min(frames - done, int(kMaxFrames));
        memcpy(inLeft.data(), left + done, n * sizeof(float));
        memcpy(inRight.data(), right + done, n * sizeof(float));
        out->mNumberBuffers = 2;
        out->mBuffers[0] = {1, UInt32(n * 4), left + done};
        out->mBuffers[1] = {1, UInt32(n * 4), right + done};
        AudioUnitRenderActionFlags flags = 0;
        AudioTimeStamp ts = {};
        ts.mSampleTime = sampleTime;
        ts.mFlags = kAudioTimeStampSampleTimeValid;
        AUAudioUnitStatus status = render(&flags, &ts, AUAudioFrameCount(n), 0, out, pull);
        if (status != noErr) {
            memcpy(left + done, inLeft.data(), n * sizeof(float));
            memcpy(right + done, inRight.data(), n * sizeof(float));
        } else {
            // The unit may have answered with its own buffers.
            if (out->mBuffers[0].mData != left + done) memcpy(left + done, out->mBuffers[0].mData, n * sizeof(float));
            if (out->mBuffers[1].mData != right + done) memcpy(right + done, out->mBuffers[1].mData, n * sizeof(float));
        }
        sampleTime += n;
        done += n;
    }
}

void Plugin::setParam(uint64_t address, float value) {
    if (schedule) schedule(AUEventSampleTimeImmediate, 0, AUParameterAddress(address), value);
}

void Plugin::reset() {
    [unit reset];
    sampleTime = 0;
}

static std::shared_ptr<Plugin> configure(VDEngine *e, AUAudioUnit *unit, NSData *state) {
    if (unit.inputBusses.count == 0 || unit.outputBusses.count == 0) return nullptr;
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:VD_SAMPLE_RATE channels:2];
    NSError *error = nil;
    if (![unit.inputBusses[0] setFormat:format error:&error]) return nullptr;
    if (![unit.outputBusses[0] setFormat:format error:&error]) return nullptr;
    unit.inputBusses[0].enabled = YES;
    unit.outputBusses[0].enabled = YES;
    unit.maximumFramesToRender = Plugin::kMaxFrames;
    if (state.length) {
        id plist = [NSPropertyListSerialization propertyListWithData:state options:0 format:nil error:nil];
        if ([plist isKindOfClass:NSDictionary.class]) unit.fullState = plist;
    }
    if (![unit allocateRenderResourcesAndReturnError:&error]) return nullptr;

    auto plugin = std::make_shared<Plugin>();
    plugin->unit = unit;
    plugin->render = unit.renderBlock;
    plugin->schedule = unit.scheduleParameterBlock;
    plugin->inLeft.resize(Plugin::kMaxFrames);
    plugin->inRight.resize(Plugin::kMaxFrames);
    plugin->out = (AudioBufferList *)calloc(1, offsetof(AudioBufferList, mBuffers) + 2 * sizeof(AudioBuffer));
    Plugin *raw = plugin.get();
    // A knob turned in the plugin's window should show in a paused picture straight away.
    plugin->observer = [unit.parameterTree tokenByAddingParameterObserver:^(AUParameterAddress, AUValue) {
        raw->changed.store(true);
        raw->latencyStale.store(true); // some plugins change their delay with their settings
        if (engineIsLive(e)) e->markDirty();
    }];
    plugin->pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *, const AudioTimeStamp *, AUAudioFrameCount n,
                                      NSInteger, AudioBufferList *io) {
        for (UInt32 b = 0; b < io->mNumberBuffers; b++) {
            float *source = b == 0 ? raw->inLeft.data() : raw->inRight.data();
            if (io->mBuffers[b].mData) memcpy(io->mBuffers[b].mData, source, n * sizeof(float));
            else io->mBuffers[b].mData = source;
            io->mBuffers[b].mDataByteSize = UInt32(n * sizeof(float));
        }
        return noErr;
    };
    return plugin;
}

void vd_au_create(VDEngine *e, uint32_t type, uint32_t subType, uint32_t manufacturer,
                  const void *state, int32_t stateLength, VDAUReady ready, void *ctx) {
    AudioComponentDescription d = {type, subType, manufacturer, 0, 0};
    NSData *saved = state && stateLength > 0 ? [NSData dataWithBytes:state length:stateLength] : nil;
    void (^finish)(AUAudioUnit *) = ^(AUAudioUnit *unit) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!engineIsLive(e)) return;
            std::shared_ptr<Plugin> plugin = unit ? configure(e, unit, saved) : nullptr;
            if (!plugin) {
                ready(ctx, -1);
                return;
            }
            int handle;
            {
                std::lock_guard<std::mutex> lock(e->tableMutex);
                e->plugins.push_back(plugin);
                handle = int(e->plugins.size()) - 1;
            }
            ready(ctx, handle);
        });
    };
    // Out of process first, so a plugin crash cannot take the app down; in process if refused.
    [AUAudioUnit instantiateWithComponentDescription:d
                                             options:kAudioComponentInstantiation_LoadOutOfProcess
                                   completionHandler:^(AUAudioUnit *unit, NSError *error) {
        if (unit) {
            finish(unit);
            return;
        }
        [AUAudioUnit instantiateWithComponentDescription:d
                                                 options:kAudioComponentInstantiation_LoadInProcess
                                       completionHandler:^(AUAudioUnit *fallback, NSError *again) {
            finish(fallback);
        }];
    }];
}

static std::shared_ptr<Plugin> pluginAt(VDEngine *e, int32_t au) {
    std::lock_guard<std::mutex> lock(e->tableMutex);
    if (au < 0 || size_t(au) >= e->plugins.size()) return nullptr;
    return e->plugins[au];
}

void vd_au_destroy(VDEngine *e, int32_t au) {
    // The slot is cleared; the plugin itself dies when the last plan using it is freed.
    std::lock_guard<std::mutex> lock(e->tableMutex);
    if (au >= 0 && size_t(au) < e->plugins.size()) e->plugins[au] = nullptr;
}

void *vd_au_copy_state(VDEngine *e, int32_t au, int32_t *length) {
    *length = 0;
    auto plugin = pluginAt(e, au);
    if (!plugin) return nullptr;
    NSDictionary *state = plugin->unit.fullState;
    if (!state) return nullptr;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:state
                                                              format:NSPropertyListBinaryFormat_v1_0
                                                             options:0
                                                               error:nil];
    if (!data.length) return nullptr;
    void *copy = malloc(data.length);
    memcpy(copy, data.bytes, data.length);
    *length = int32_t(data.length);
    return copy;
}

int32_t vd_au_param_count(VDEngine *e, int32_t au) {
    auto plugin = pluginAt(e, au);
    return plugin ? int32_t(plugin->unit.parameterTree.allParameters.count) : 0;
}

bool vd_au_param_info(VDEngine *e, int32_t au, int32_t index, uint64_t *address,
                      char *name, int32_t nameCapacity, float *min, float *max, float *value) {
    auto plugin = pluginAt(e, au);
    if (!plugin) return false;
    NSArray<AUParameter *> *all = plugin->unit.parameterTree.allParameters;
    if (index < 0 || NSUInteger(index) >= all.count) return false;
    AUParameter *p = all[index];
    *address = p.address;
    *min = p.minValue;
    *max = p.maxValue;
    *value = p.value;
    if (name && nameCapacity > 0) strlcpy(name, p.displayName.UTF8String ?: "", nameCapacity);
    return true;
}

void vd_au_set_param(VDEngine *e, int32_t au, uint64_t address, float value) {
    auto plugin = pluginAt(e, au);
    if (!plugin) return;
    [[plugin->unit.parameterTree parameterWithAddress:address] setValue:value];
}

void vd_au_request_view(VDEngine *e, int32_t au, VDAUView ready, void *ctx) {
    auto plugin = pluginAt(e, au);
    if (!plugin) {
        ready(ctx, nullptr);
        return;
    }
    [plugin->unit requestViewControllerWithCompletionHandler:^(NSViewController *controller) {
        dispatch_async(dispatch_get_main_queue(), ^{
            ready(ctx, (__bridge_retained void *)controller);
        });
    }];
}
