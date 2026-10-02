// Picture: random-access decoding, the Metal render graph, the display thread and export.
#include "core.hpp"
#include <mach/mach_time.h>
#include <simd/simd.h>
#include <sys/mman.h>
#include <unordered_set>

// ---- Decoding ----------------------------------------------------------------------------

// A video file with random access to any frame. Frames are cached by presentation time.
struct VideoMedia {
    AVURLAsset *asset = nil;
    AVAssetTrack *track = nil;
    AVSampleBufferGenerator *generator = nil;
    VTDecompressionSessionRef session = nullptr;
    VDEngine *engine = nullptr;
    double duration = 0, fps = 30, startSeconds = 0;
    int width = 0, height = 0, quarterTurns = 0;
    int32_t timescale = 600;

    std::mutex cacheMutex;
    std::map<int64_t, CVPixelBufferRef> cache;
    std::unordered_map<int64_t, uint64_t> used;
    uint64_t clock = 0;
    size_t capacity = 16;

    std::mutex decodeMutex;
    AVSampleCursor *next = nil; // the sample after the last one decoded, in decode order

    dispatch_queue_t queue = nil;
    std::atomic<bool> scheduled{false};
    std::atomic<double> wantTime{0};
    std::atomic<int> wantDirection{1};

    ~VideoMedia() {
        if (queue) dispatch_sync(queue, ^{}); // let any read-ahead in flight finish first
        if (session) {
            VTDecompressionSessionInvalidate(session);
            CFRelease(session);
        }
        for (auto &entry : cache) CVPixelBufferRelease(entry.second);
    }

    AVSampleCursor *cursorAt(double seconds, int64_t *key) {
        double last = std::max(0.0, duration - 0.5 / fps);
        seconds = std::min(std::max(seconds, 0.0), last);
        CMTime time = CMTimeMakeWithSeconds(startSeconds + seconds, timescale);
        AVSampleCursor *cursor = [track makeSampleCursorWithPresentationTimeStamp:time];
        if (cursor) *key = CMTimeConvertScale(cursor.presentationTimeStamp, timescale, kCMTimeRoundingMethod_Default).value;
        return cursor;
    }

    CVPixelBufferRef cached(int64_t key) {
        std::lock_guard<std::mutex> lock(cacheMutex);
        auto found = cache.find(key);
        if (found == cache.end()) return nullptr;
        used[key] = ++clock;
        return CVPixelBufferRetain(found->second);
    }

    // The newest cached frame at or before `key`, for when the exact one is not ready.
    CVPixelBufferRef nearest(int64_t key) {
        std::lock_guard<std::mutex> lock(cacheMutex);
        if (cache.empty()) return nullptr;
        auto it = cache.upper_bound(key);
        if (it == cache.begin()) return CVPixelBufferRetain(it->second);
        return CVPixelBufferRetain(std::prev(it)->second);
    }

    void store(int64_t key, CVPixelBufferRef frame) {
        std::lock_guard<std::mutex> lock(cacheMutex);
        auto found = cache.find(key);
        if (found != cache.end()) CVPixelBufferRelease(found->second);
        cache[key] = CVPixelBufferRetain(frame);
        used[key] = ++clock;
        while (cache.size() > capacity) {
            int64_t oldest = 0;
            uint64_t stamp = UINT64_MAX;
            for (auto &entry : used)
                if (entry.second < stamp) {
                    stamp = entry.second;
                    oldest = entry.first;
                }
            CVPixelBufferRelease(cache[oldest]);
            cache.erase(oldest);
            used.erase(oldest);
        }
    }

    bool decodeSample(AVSampleCursor *cursor) {
        AVSampleBufferRequest *request = [[AVSampleBufferRequest alloc] initWithStartCursor:cursor];
        NSError *error = nil;
        CMSampleBufferRef sample = [generator createSampleBufferForRequest:request error:&error];
        if (!sample) return false;
        if (!session) {
            NSDictionary *attributes = @{
                (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferMetalCompatibilityKey : @YES,
            };
            OSStatus status = VTDecompressionSessionCreate(nullptr, CMSampleBufferGetFormatDescription(sample), nullptr,
                                                           (__bridge CFDictionaryRef)attributes, nullptr, &session);
            if (status != noErr) {
                CFRelease(sample);
                session = nullptr;
                return false;
            }
        }
        VideoMedia *me = this;
        VTDecompressionSessionDecodeFrameWithOutputHandler(
            session, sample, 0, nullptr,
            ^(OSStatus status, VTDecodeInfoFlags, CVImageBufferRef image, CMTime pts, CMTime) {
                if (status == noErr && image)
                    me->store(CMTimeConvertScale(pts, me->timescale, kCMTimeRoundingMethod_Default).value, image);
            });
        CFRelease(sample);
        return true;
    }

    // Decodes from the nearest sync sample (or from where the last decode stopped, if that
    // is closer) through `target`. Caller holds decodeMutex.
    void decodeThrough(AVSampleCursor *target) {
        AVSampleCursor *start = [target copy];
        for (int guard = 0; guard < 600 && !start.currentSampleSyncInfo.sampleIsFullSync; guard++)
            if ([start stepInDecodeOrderByCount:-1] != -1) break;
        if (next && [next comparePositionInDecodeOrderWithPositionOfCursor:start] != NSOrderedAscending &&
            [next comparePositionInDecodeOrderWithPositionOfCursor:target] != NSOrderedDescending)
            start = [next copy];
        AVSampleCursor *cursor = start;
        for (int guard = 0; guard < 600; guard++) {
            if (!decodeSample(cursor)) break;
            bool reached = [cursor comparePositionInDecodeOrderWithPositionOfCursor:target] == NSOrderedSame;
            if ([cursor stepInDecodeOrderByCount:1] != 1) {
                cursor = nil;
                break;
            }
            if (reached) break;
        }
        next = cursor;
    }

    // Returns a retained frame for `seconds`, or NULL. With `wait` the frame is decoded
    // before returning; otherwise the decode is queued and the closest ready frame is
    // returned in the meantime.
    CVPixelBufferRef copyFrame(double seconds, bool wait, int direction) {
        @autoreleasepool {
            int64_t key = 0;
            AVSampleCursor *cursor = cursorAt(seconds, &key);
            if (!cursor) return nullptr;
            if (wait) {
                if (CVPixelBufferRef hit = cached(key)) return hit;
                std::lock_guard<std::mutex> lock(decodeMutex);
                decodeThrough(cursor);
                return cached(key);
            }
            wantTime.store(seconds);
            wantDirection.store(direction);
            if (!scheduled.exchange(true)) {
                VideoMedia *me = this;
                dispatch_async(queue, ^{
                    me->scheduled.store(false);
                    me->readAhead();
                });
            }
            if (CVPixelBufferRef hit = cached(key)) return hit;
            return nearest(key);
        }
    }

    // Decodes the wanted frame and a few beyond it in the direction of play.
    void readAhead() {
        const int kAhead = 6;
        double base = wantTime.load();
        int direction = wantDirection.load();
        bool decoded = false;
        for (int i = 0; i <= kAhead; i++) {
            if (wantTime.load() != base && i > 0) break; // the playhead moved; start over
            @autoreleasepool {
                int64_t key = 0;
                AVSampleCursor *cursor = cursorAt(base + direction * i / fps, &key);
                if (!cursor) break;
                if (CVPixelBufferRef hit = cached(key)) {
                    CVPixelBufferRelease(hit);
                    continue;
                }
                std::lock_guard<std::mutex> lock(decodeMutex);
                decodeThrough(cursor);
                decoded = true;
            }
        }
        if (decoded && engine) engine->markDirty();
    }
};

std::shared_ptr<VideoMedia> openVideo(NSString *path, VDEngine *engine) {
    @autoreleasepool {
        NSDictionary *options = @{AVURLAssetPreferPreciseDurationAndTimingKey : @YES};
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:options];
        AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (!track || !track.canProvideSampleCursors) return nullptr;
        auto media = std::make_shared<VideoMedia>();
        media->asset = asset;
        media->track = track;
        media->engine = engine;
        media->generator = [[AVSampleBufferGenerator alloc] initWithAsset:asset timebase:nullptr];
        media->duration = CMTimeGetSeconds(track.timeRange.duration);
        media->startSeconds = CMTimeGetSeconds(track.timeRange.start);
        media->fps = track.nominalFrameRate > 0 ? track.nominalFrameRate : 30;
        media->timescale = track.naturalTimeScale > 0 ? track.naturalTimeScale : 600;
        CGSize size = track.naturalSize;
        media->width = int(size.width);
        media->height = int(size.height);
        CGAffineTransform t = track.preferredTransform;
        int turns = int(lround(atan2(t.b, t.a) / M_PI_2));
        media->quarterTurns = ((turns % 4) + 4) % 4;
        size_t frameBytes = std::max<size_t>(1, size_t(media->width) * size_t(media->height) * 4);
        media->capacity = std::min<size_t>(240, std::max<size_t>(12, (512u << 20) / frameBytes));
        media->queue = dispatch_queue_create("videodaw.decode", DISPATCH_QUEUE_SERIAL);
        if (media->duration <= 0 || media->width <= 0) return nullptr;
        return media;
    }
}

bool videoInfo(VideoMedia &m, double *duration, int32_t *width, int32_t *height, double *fps) {
    bool sideways = m.quarterTurns % 2 == 1;
    *duration = m.duration;
    *width = sideways ? m.height : m.width;
    *height = sideways ? m.width : m.height;
    *fps = m.fps;
    return true;
}

// ---- Shaders -----------------------------------------------------------------------------

static NSString *const kShaders = @R"METAL(
#include <metal_stdlib>
using namespace metal;

struct U { float4x4 m; float2 uv0; float2 uv1; float4 a; float4 b; };
struct V { float4 position [[position]]; float2 uv; };

constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);

// A quad covering the uv rectangle [uv0, uv1] of the unit square, placed by `m`.
vertex V quadVertex(uint id [[vertex_id]], constant U &u [[buffer(0)]]) {
    float2 c = float2((id & 1) ? 1.0 : 0.0, (id & 2) ? 1.0 : 0.0);
    V out;
    out.uv = mix(u.uv0, u.uv1, c);
    out.position = u.m * float4(out.uv.x * 2.0 - 1.0, 1.0 - out.uv.y * 2.0, 0.0, 1.0);
    return out;
}

// a.x opacity, a.y quarter turns of the source picture.
fragment float4 frameFragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]], constant U &u [[buffer(0)]]) {
    float2 uv = in.uv;
    int turns = int(u.a.y);
    if (turns == 1) uv = float2(in.uv.y, 1.0 - in.uv.x);
    else if (turns == 2) uv = float2(1.0 - in.uv.x, 1.0 - in.uv.y);
    else if (turns == 3) uv = float2(1.0 - in.uv.y, in.uv.x);
    float4 c = tex.sample(linearClamp, uv);
    return float4(c.rgb * u.a.x, u.a.x);
}

fragment float4 copyFragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
    return tex.sample(linearClamp, in.uv);
}

// a.x opacity, a.y blend mode. Reads the destination colour to blend.
fragment float4 compositeFragment(V in [[stage_in]], float4 dst [[color(0)]], texture2d<float> tex [[texture(0)]],
                                  constant U &u [[buffer(0)]]) {
    float4 s = tex.sample(linearClamp, in.uv) * u.a.x;
    float3 colour = s.a > 0.0001 ? s.rgb / s.a : float3(0.0);
    int mode = int(u.a.y);
    float3 r;
    if (mode == 1) r = dst.rgb + s.rgb;
    else if (mode == 2) r = mix(dst.rgb, dst.rgb * colour, s.a);
    else if (mode == 3) r = mix(dst.rgb, 1.0 - (1.0 - dst.rgb) * (1.0 - colour), s.a);
    else if (mode == 4) r = mix(dst.rgb, abs(dst.rgb - colour), s.a);
    else r = s.rgb + dst.rgb * (1.0 - s.a);
    return float4(saturate(r), 1.0);
}

// a = brightness, contrast, saturation, hue in degrees.
fragment float4 colorFragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]], constant U &u [[buffer(0)]]) {
    float4 s = tex.sample(linearClamp, in.uv);
    if (s.a < 0.0001) return s;
    float3 c = s.rgb / s.a;
    c += u.a.x;
    c = (c - 0.5) * u.a.y + 0.5;
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    c = mix(float3(luma), c, u.a.z);
    float angle = u.a.w * 0.017453292;
    float3 k = float3(0.57735);
    c = c * cos(angle) + cross(k, c) * sin(angle) + k * dot(k, c) * (1.0 - cos(angle));
    return float4(saturate(c) * s.a, s.a);
}

// a.x radius in pixels, a.yz the step direction in uv per pixel.
fragment float4 blurFragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]], constant U &u [[buffer(0)]]) {
    if (u.a.x < 0.01) return tex.sample(linearClamp, in.uv);
    float4 sum = float4(0.0);
    float weights = 0.0;
    for (int i = -16; i <= 16; i++) {
        float w = exp(-float(i * i) / 128.0);
        sum += tex.sample(linearClamp, in.uv + u.a.yz * (float(i) * u.a.x / 16.0)) * w;
        weights += w;
    }
    return sum / weights;
}

// a.x block size in pixels, b.xy texture size.
fragment float4 pixelateFragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]], constant U &u [[buffer(0)]]) {
    float2 block = max(u.a.x, 1.0) / u.b.xy;
    return tex.sample(linearClamp, (floor(in.uv / block) + 0.5) * block);
}

// tex = this frame, history = this effect's previous output. a = amount, zoom, rotation in
// degrees, aspect ratio.
fragment float4 feedbackFragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]], texture2d<float> history [[texture(1)]],
                                 constant U &u [[buffer(0)]]) {
    float4 s = tex.sample(linearClamp, in.uv);
    float2 p = in.uv - 0.5;
    p.x *= u.a.w;
    float angle = u.a.z * 0.017453292;
    p = float2(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle)) / max(u.a.y, 0.01);
    p.x /= u.a.w;
    // Whatever is brighter wins, so bright shapes leave decaying trails even over a
    // picture that fills the frame.
    float4 old = history.sample(linearClamp, p + 0.5) * u.a.x;
    return max(s, old);
}

// a = amount in pixels, scale, phase. b.xy texture size.
fragment float4 displaceFragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]], constant U &u [[buffer(0)]]) {
    float2 uv = in.uv;
    float t = u.a.z;
    float2 n = float2(sin(uv.y * u.a.y * 6.2832 + t) + sin((uv.x + uv.y) * u.a.y * 3.7 + t * 1.3),
                      cos(uv.x * u.a.y * 6.2832 + t * 0.8) + cos((uv.x - uv.y) * u.a.y * 4.1 - t)) * 0.5;
    return tex.sample(linearClamp, uv + n * u.a.x / u.b.xy);
}

// tex = the track picture, bent = the Audio Unit's output at bend resolution. a.x wet/dry.
fragment float4 bendMixFragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]], texture2d<float> bent [[texture(1)]],
                                constant U &u [[buffer(0)]]) {
    float4 dry = tex.sample(linearClamp, in.uv);
    float4 wet = float4(bent.sample(linearClamp, in.uv).rgb, 1.0);
    return mix(dry, wet, u.a.x);
}
)METAL";

// ---- Renderer ----------------------------------------------------------------------------

struct U {
    simd_float4x4 m;
    simd_float2 uv0, uv1;
    simd_float4 a, b;
};

static U unit() {
    U u = {};
    u.m = matrix_identity_float4x4;
    u.uv0 = simd_make_float2(0, 0);
    u.uv1 = simd_make_float2(1, 1);
    return u;
}

static simd_float4x4 scaling(float x, float y) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0].x = x;
    m.columns[1].y = y;
    return m;
}

static simd_float4x4 translation(float x, float y) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[3].x = x;
    m.columns[3].y = y;
    return m;
}

static simd_float4x4 rotation(float radians) {
    simd_float4x4 m = matrix_identity_float4x4;
    m.columns[0] = simd_make_float4(cosf(radians), sinf(radians), 0, 0);
    m.columns[1] = simd_make_float4(-sinf(radians), cosf(radians), 0, 0);
    return m;
}

// Scales a picture of aspect `inner` to fit inside a frame of aspect `outer`.
static simd_float4x4 fit(double inner, double outer) {
    double ratio = inner / outer;
    return ratio >= 1 ? scaling(1, float(1 / ratio)) : scaling(float(ratio), 1);
}

struct TrackState {
    id<MTLTexture> textures[2] = {nil, nil};
};

// The sample rate a through-time Audio Unit is told it runs at. One frame is one sample,
// so at this rate a 4 ms delay is an echo 32 frames later.
static const double kThroughTimeRate = 8000;

// A large buffer backed by an unlinked temporary file, so chunks of picture measured in
// hundreds of megabytes page out to disk instead of filling memory.
struct Blob {
    uint8_t *bytes = nullptr;
    size_t size = 0;
    bool mapped = false;

    explicit Blob(size_t count) : size(count) {
        std::string path = std::string(NSTemporaryDirectory().fileSystemRepresentation) + "videodaw-bend-XXXXXX";
        int file = mkstemp(path.data());
        if (file >= 0) {
            unlink(path.c_str());
            if (ftruncate(file, off_t(size)) == 0) {
                void *memory = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_SHARED, file, 0);
                if (memory != MAP_FAILED) {
                    bytes = (uint8_t *)memory;
                    mapped = true;
                }
            }
            close(file);
        }
        if (!bytes) bytes = (uint8_t *)calloc(1, size);
    }
    Blob(const Blob &) = delete;
    Blob &operator=(const Blob &) = delete;
    ~Blob() {
        if (mapped) munmap(bytes, size);
        else free(bytes);
    }
};

// Chunks of picture bent through time, shared between the render thread that shows them
// and the background queue that makes them. Each chunk is RGB, frame after frame.
struct ThroughTime {
    std::mutex mutex;
    std::map<int64_t, std::shared_ptr<Blob>> inputs, outputs;
    std::unordered_set<int64_t> pending;
    uint64_t signature = 0;
    std::atomic<uint64_t> generation{0};     // bumped whenever cached chunks stop being valid
    std::atomic<int64_t> wanted{INT64_MIN};  // the chunk the playhead is in
};

struct EffectState {
    id<MTLTexture> history = nil;           // feedback
    id<MTLTexture> bendIn = nil, bendOut = nil;
    std::vector<uint8_t> bytes;
    std::vector<float> left, right;
    int64_t lastFrame = INT64_MIN;
    std::shared_ptr<ThroughTime> throughTime;
};

struct Renderer {
    VDEngine *engine = nullptr;
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    CVMetalTextureCacheRef textureCache = nullptr;
    id<MTLRenderPipelineState> frame, copy, composite, color, blur, pixelate, feedback, displace, bendMix;
    id<MTLTexture> master = nil;
    std::unordered_map<uint64_t, TrackState> tracks;
    std::unordered_map<uint64_t, EffectState> effects;
    uint64_t lastPlan = 0;
    std::mutex mutex; // one frame at a time: the display thread or an export

    // Through-time chunks are made here, one at a time, with their own textures.
    dispatch_queue_t bendQueue = nil;
    std::atomic<int> bendJobs{0};
    CVMetalTextureCacheRef bendCache = nullptr;
    id<MTLTexture> bendScratch[2] = {nil, nil};

    id<MTLRenderPipelineState> pipeline(id<MTLLibrary> library, NSString *fragment, bool blend) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = [library newFunctionWithName:@"quadVertex"];
        d.fragmentFunction = [library newFunctionWithName:fragment];
        d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        if (blend) {
            d.colorAttachments[0].blendingEnabled = YES;
            d.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
            d.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        }
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:d error:&error];
        if (!state) NSLog(@"VideoDAW: pipeline %@ failed: %@", fragment, error);
        return state;
    }

    bool setUp() {
        device = MTLCreateSystemDefaultDevice();
        if (!device) return false;
        queue = [device newCommandQueue];
        CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &textureCache);
        CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &bendCache);
        bendQueue = dispatch_queue_create("videodaw.bend", DISPATCH_QUEUE_SERIAL);
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:kShaders options:nil error:&error];
        if (!library) {
            NSLog(@"VideoDAW: shader compile failed: %@", error);
            return false;
        }
        frame = pipeline(library, @"frameFragment", true);
        copy = pipeline(library, @"copyFragment", false);
        composite = pipeline(library, @"compositeFragment", false);
        color = pipeline(library, @"colorFragment", false);
        blur = pipeline(library, @"blurFragment", false);
        pixelate = pipeline(library, @"pixelateFragment", false);
        feedback = pipeline(library, @"feedbackFragment", false);
        displace = pipeline(library, @"displaceFragment", false);
        bendMix = pipeline(library, @"bendMixFragment", false);
        return frame && copy && composite && color && blur && pixelate && feedback && displace && bendMix;
    }

    id<MTLTexture> target(int width, int height) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:width
                                                                                    height:height
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModeShared;
        return [device newTextureWithDescriptor:d];
    }

    void pass(id<MTLCommandBuffer> cb, id<MTLTexture> into, bool clear, double alpha,
              void (^body)(id<MTLRenderCommandEncoder>)) {
        MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
        d.colorAttachments[0].texture = into;
        d.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
        d.colorAttachments[0].storeAction = MTLStoreActionStore;
        d.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, alpha);
        id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:d];
        body(encoder);
        [encoder endEncoding];
    }

    void quad(id<MTLRenderCommandEncoder> encoder, id<MTLRenderPipelineState> state, const U &u,
              id<MTLTexture> first, id<MTLTexture> second = nil) {
        [encoder setRenderPipelineState:state];
        [encoder setVertexBytes:&u length:sizeof u atIndex:0];
        [encoder setFragmentBytes:&u length:sizeof u atIndex:0];
        [encoder setFragmentTexture:first atIndex:0];
        if (second) [encoder setFragmentTexture:second atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }

    // One full-frame effect pass from `from` into `into`.
    void filter(id<MTLCommandBuffer> cb, id<MTLRenderPipelineState> state, const U &u, id<MTLTexture> from,
                id<MTLTexture> into, id<MTLTexture> second = nil) {
        pass(cb, into, true, 0, ^(id<MTLRenderCommandEncoder> encoder) {
            quad(encoder, state, u, from, second);
        });
    }

    void resetState() {
        std::lock_guard<std::mutex> lock(mutex);
        effects.clear();
    }

    // Drops per-track and per-effect state for anything no longer in the plan.
    void collect(const Plan &plan) {
        std::unordered_set<uint64_t> liveTracks, liveEffects;
        for (const VideoTrack &track : plan.video) {
            liveTracks.insert(track.id);
            for (const Effect &fx : track.effects) liveEffects.insert(fx.id);
        }
        std::erase_if(tracks, [&](const auto &entry) { return !liveTracks.count(entry.first); });
        std::erase_if(effects, [&](const auto &entry) { return !liveEffects.count(entry.first); });
    }

    // Draws a track's regions at `time`, later ones on top, each with its fade as opacity.
    void drawRegions(id<MTLRenderCommandEncoder> encoder, const VideoTrack &track, int64_t time, bool wait,
                     double aspect, CVMetalTextureCacheRef cache, NSMutableArray *keep) {
        for (const VideoRegion &region : track.regions) {
            const VDVideoRegion &r = region.r;
            int64_t local = time - r.start;
            if (r.muted || local < 0 || local >= r.length) continue;
            double within = double(local % r.contentLength) / VD_SAMPLE_RATE;
            double span = double(r.contentLength) / VD_SAMPLE_RATE * r.speed;
            double source = r.reversed ? r.sourceStart + span - within * r.speed : r.sourceStart + within * r.speed;
            VideoMedia &media = *region.media;
            CVPixelBufferRef pixels = media.copyFrame(source, wait, r.reversed ? -1 : 1);
            if (!pixels) continue;
            CVMetalTextureRef wrapped = nullptr;
            CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, pixels, nullptr, MTLPixelFormatBGRA8Unorm,
                                                      CVPixelBufferGetWidth(pixels), CVPixelBufferGetHeight(pixels), 0,
                                                      &wrapped);
            CVPixelBufferRelease(pixels);
            if (!wrapped) continue;
            [keep addObject:CFBridgingRelease(wrapped)];
            float opacity = 1;
            if (local < r.fadeIn) opacity = float(local) / float(r.fadeIn);
            int64_t remaining = r.length - local;
            if (remaining < r.fadeOut) opacity *= float(remaining) / float(r.fadeOut);
            bool sideways = media.quarterTurns % 2 == 1;
            double shown = sideways ? double(media.height) / media.width : double(media.width) / media.height;
            U u = unit();
            u.m = fit(shown, aspect);
            u.a = simd_make_float4(opacity, float(media.quarterTurns), 0, 0);
            quad(encoder, frame, u, CVMetalTextureGetTexture(wrapped));
        }
    }

    // Runs one of the effects that keep no state between frames. `pixelScale` shrinks
    // pixel-sized parameters when the picture is being drawn smaller than the project.
    // Returns false if `fx` is not such an effect.
    bool runStateless(id<MTLCommandBuffer> cb, const Effect &fx, int64_t time, id<MTLTexture> __strong *textures,
                      int &current, float pixelScale) {
        id<MTLTexture> from = textures[current], into = textures[1 - current];
        float width = float(from.width), height = float(from.height);
        U u = unit();
        u.b = simd_make_float4(width, height, 0, 0);
        float p0 = fx.params[0].at(time), p1 = fx.params[1].at(time);
        float p2 = fx.params[2].at(time), p3 = fx.params[3].at(time);
        switch (fx.kind) {
        case VD_FX_COLOR:
            u.a = simd_make_float4(p0, p1, p2, p3);
            filter(cb, color, u, from, into);
            current = 1 - current;
            return true;
        case VD_FX_BLUR:
            u.a = simd_make_float4(p0 * pixelScale, 1.0f / width, 0, 0);
            filter(cb, blur, u, from, into);
            u.a = simd_make_float4(p0 * pixelScale, 0, 1.0f / height, 0);
            filter(cb, blur, u, into, from);
            return true;
        case VD_FX_PIXELATE:
            u.a = simd_make_float4(std::max(1.0f, p0 * pixelScale), 0, 0, 0);
            filter(cb, pixelate, u, from, into);
            current = 1 - current;
            return true;
        case VD_FX_DISPLACE:
            u.a = simd_make_float4(p0 * pixelScale, p1, float(double(time) / VD_SAMPLE_RATE * p2), 0);
            filter(cb, displace, u, from, into);
            current = 1 - current;
            return true;
        default:
            return false;
        }
    }

    static void unpack(const uint8_t *bgra, uint8_t *rgb, size_t pixels) {
        for (size_t p = 0; p < pixels; p++) {
            rgb[p * 3] = bgra[p * 4 + 2];
            rgb[p * 3 + 1] = bgra[p * 4 + 1];
            rgb[p * 3 + 2] = bgra[p * 4];
        }
    }

    static void pack(const uint8_t *rgb, uint8_t *bgra, size_t pixels) {
        for (size_t p = 0; p < pixels; p++) {
            bgra[p * 4] = rgb[p * 3 + 2];
            bgra[p * 4 + 1] = rgb[p * 3 + 1];
            bgra[p * 4 + 2] = rgb[p * 3];
            bgra[p * 4 + 3] = 255;
        }
    }

    // Runs an Audio Unit over the picture as one raster-scanned waveform.
    void bendRaster(const Plan &plan, const Effect &fx, EffectState &state, int64_t time, int64_t frameIndex) {
        int width = plan.bendWidth, height = plan.bendHeight;
        size_t pixels = size_t(width) * size_t(height), samples = pixels * 3;
        state.bytes.resize(pixels * 4);
        state.left.resize(samples);
        state.right.resize(samples);
        [state.bendIn getBytes:state.bytes.data()
                   bytesPerRow:width * 4
                    fromRegion:MTLRegionMake2D(0, 0, width, height)
                   mipmapLevel:0];
        const uint8_t *in = state.bytes.data();
        float *signal = state.left.data();
        for (size_t p = 0; p < pixels; p++) { // BGRA in memory, RGB in the signal
            signal[p * 3] = in[p * 4 + 2] / 127.5f - 1;
            signal[p * 3 + 1] = in[p * 4 + 1] / 127.5f - 1;
            signal[p * 3 + 2] = in[p * 4] / 127.5f - 1;
        }
        memcpy(state.right.data(), signal, samples * sizeof(float));
        // The signal is continuous from frame to frame; any jump starts it afresh.
        if (frameIndex != state.lastFrame + 1) fx.plugin->reset();
        state.lastFrame = frameIndex;
        for (const auto &param : fx.auParams) fx.plugin->setParam(param.first, param.second.at(time));
        fx.plugin->process(signal, state.right.data(), int(samples));
        // A unit that delays its output would shift the picture along the scan. Rotating
        // the scan back puts it in place; what wraps round is the same spot one frame ago.
        int64_t delay = fx.plugin->latency.load();
        if (delay > 0 && size_t(delay) < samples) std::rotate(signal, signal + delay, signal + samples);
        uint8_t *out = state.bytes.data();
        for (size_t p = 0; p < pixels; p++) {
            for (int c = 0; c < 3; c++) {
                float v = (signal[p * 3 + c] + 1) * 127.5f;
                out[p * 4 + 2 - c] = uint8_t(v < 0 ? 0 : v > 255 ? 255 : v);
            }
            out[p * 4 + 3] = 255;
        }
        [state.bendOut replaceRegion:MTLRegionMake2D(0, 0, width, height)
                         mipmapLevel:0
                           withBytes:out
                         bytesPerRow:width * 4];
    }

    // ---- Through-time bending. Chunks are made on bendQueue. ----

    struct Frame {
        int bendWidth, bendHeight, height;
        double fps;
        int n; // frames per chunk: how far back the effect remembers
    };

    static int64_t chunkTime(int64_t frameIndex, double fps) {
        return int64_t(ceil(double(frameIndex) * VD_SAMPLE_RATE / fps));
    }

    static void fold(uint64_t &hash, const void *data, size_t size) {
        const uint8_t *bytes = (const uint8_t *)data;
        for (size_t i = 0; i < size; i++) hash = (hash ^ bytes[i]) * 1099511628211ull;
    }

    template <typename T> static void fold(uint64_t &hash, T value) { fold(hash, &value, sizeof value); }

    static void fold(uint64_t &hash, const Curve &curve) {
        fold(hash, curve.constant);
        for (const VDPoint &point : curve.points) {
            fold(hash, point.time);
            fold(hash, point.value);
        }
    }

    // Everything a through-time slot's picture depends on. While this stays the same,
    // chunks already made stay good, whatever else in the project changes.
    static uint64_t signature(const Plan &plan, const VideoTrack &track, int index) {
        uint64_t hash = 14695981039346656037ull;
        fold(hash, plan.bendWidth);
        fold(hash, plan.bendHeight);
        fold(hash, plan.height);
        fold(hash, plan.fps);
        for (const VideoRegion &region : track.regions) {
            const VDVideoRegion &r = region.r;
            fold(hash, r.media);
            fold(hash, r.muted);
            fold(hash, r.start);
            fold(hash, r.length);
            fold(hash, r.contentLength);
            fold(hash, r.sourceStart);
            fold(hash, r.speed);
            fold(hash, r.reversed);
            fold(hash, r.fadeIn);
            fold(hash, r.fadeOut);
        }
        for (int e = 0; e <= index; e++) {
            const Effect &fx = track.effects[e];
            fold(hash, fx.id);
            fold(hash, fx.kind);
            fold(hash, fx.bypass);
            for (const Curve &curve : fx.params) fold(hash, curve);
        }
        const Effect &fx = track.effects[index];
        fold(hash, fx.memoryFrames);
        for (const auto &param : fx.auParams) {
            fold(hash, param.first);
            fold(hash, param.second);
        }
        return hash;
    }

    // The picture going into effect `index` of `track` for every frame of chunk `k`, at
    // bend resolution. Effects before it that carry state from frame to frame (feedback,
    // other Audio Units) are left out: they cannot be evaluated out of order. Returns
    // null if `alive` says the work is no longer wanted.
    std::shared_ptr<Blob> chunkInput(const VideoTrack &track, int index, int64_t k, Frame f, bool (^alive)(void)) {
        size_t pixels = size_t(f.bendWidth) * size_t(f.bendHeight);
        auto input = std::make_shared<Blob>(pixels * 3 * f.n);
        if (!bendScratch[0] || int(bendScratch[0].width) != f.bendWidth || int(bendScratch[0].height) != f.bendHeight) {
            bendScratch[0] = target(f.bendWidth, f.bendHeight);
            bendScratch[1] = target(f.bendWidth, f.bendHeight);
        }
        std::vector<uint8_t> bgra(pixels * 4);
        double aspect = double(f.bendWidth) / double(f.bendHeight);
        float pixelScale = float(f.bendHeight) / float(f.height);
        for (int i = 0; i < f.n; i++) {
            if (i % 8 == 0 && !alive()) return nullptr;
            @autoreleasepool {
                int64_t time = chunkTime(k * f.n + i, f.fps);
                NSMutableArray *keep = [NSMutableArray array];
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                pass(cb, bendScratch[0], true, 0, ^(id<MTLRenderCommandEncoder> encoder) {
                    if (time >= 0) drawRegions(encoder, track, time, true, aspect, bendCache, keep);
                });
                int current = 0;
                for (int e = 0; e < index; e++)
                    if (!track.effects[e].bypass) runStateless(cb, track.effects[e], time, bendScratch, current, pixelScale);
                [cb commit];
                [cb waitUntilCompleted];
                [bendScratch[current] getBytes:bgra.data()
                                   bytesPerRow:f.bendWidth * 4
                                    fromRegion:MTLRegionMake2D(0, 0, f.bendWidth, f.bendHeight)
                                   mipmapLevel:0];
                unpack(bgra.data(), input->bytes + size_t(i) * pixels * 3, pixels);
            }
        }
        return input;
    }

    // Bends chunk `k`. Every pixel's values across the chunk's frames pass through the
    // Audio Unit as one run of samples, with the same pixel's values across the previous
    // chunk in front as run-up, so the effect's memory reaches a whole chunk back. If the
    // unit delays its output, the run continues into the next chunk by that much and the
    // output is read that much later, which puts it back in time. The unit starts each
    // chunk from silence, so a chunk depends only on the plan, never on playback history.
    std::shared_ptr<Blob> chunkOutput(const Effect &fx, int64_t k, Frame f, int delay, const Blob &before,
                                      const Blob &now, const Blob *after, bool (^alive)(void)) {
        const int n = f.n, run = 2 * n + delay;
        size_t streams = size_t(f.bendWidth) * size_t(f.bendHeight) * 3;
        auto output = std::make_shared<Blob>(streams * n);
        Plugin &plugin = *fx.plugin;
        plugin.reset();
        int64_t time = chunkTime(k * n, f.fps);
        for (const auto &param : fx.auParams) plugin.setParam(param.first, param.second.at(time));
        const size_t batch = std::max<size_t>(1, 262144 / size_t(run));
        std::vector<float> left(batch * run), right(batch * run);
        for (size_t first = 0; first < streams; first += batch) {
            if (!alive()) return nullptr;
            size_t count = std::min(batch, streams - first);
            for (size_t s = 0; s < count; s++) {
                float *samples = left.data() + s * run;
                size_t stream = first + s;
                for (int i = 0; i < n; i++) {
                    samples[i] = before.bytes[size_t(i) * streams + stream] / 127.5f - 1;
                    samples[n + i] = now.bytes[size_t(i) * streams + stream] / 127.5f - 1;
                }
                for (int i = 0; i < delay; i++)
                    samples[2 * n + i] = after ? after->bytes[size_t(i) * streams + stream] / 127.5f - 1 : samples[2 * n - 1];
            }
            memcpy(right.data(), left.data(), count * run * sizeof(float));
            plugin.process(left.data(), right.data(), int(count * run));
            for (size_t s = 0; s < count; s++) {
                const float *samples = left.data() + s * run + n + delay;
                size_t stream = first + s;
                for (int i = 0; i < n; i++) {
                    float v = (samples[i] + 1) * 127.5f;
                    output->bytes[size_t(i) * streams + stream] = uint8_t(v < 0 ? 0 : v > 255 ? 255 : v);
                }
            }
        }
        return output;
    }

    // Makes chunk `k` and files it, unless it stopped being wanted on the way.
    void makeChunk(std::shared_ptr<ThroughTime> tt, uint64_t generation, const VideoTrack &track, int index,
                   int64_t k, Frame f) {
        bool (^alive)(void) = ^bool {
            int64_t wanted = tt->wanted.load();
            return tt->generation.load() == generation && (k == wanted || k == wanted + 1);
        };
        auto inputFor = [&](int64_t chunk) -> std::shared_ptr<Blob> {
            {
                std::lock_guard<std::mutex> lock(tt->mutex);
                auto found = tt->inputs.find(chunk);
                if (found != tt->inputs.end()) return found->second;
            }
            auto made = chunkInput(track, index, chunk, f, alive);
            std::lock_guard<std::mutex> lock(tt->mutex);
            if (made && tt->generation.load() == generation) tt->inputs[chunk] = made;
            return made;
        };
        const Effect &fx = track.effects[index];
        fx.plugin->setRate(kThroughTimeRate);
        int delay = int(std::min<int64_t>(f.n, std::max<int64_t>(0, fx.plugin->latency.load())));
        std::shared_ptr<Blob> output;
        std::shared_ptr<Blob> none;
        auto before = alive() ? inputFor(k - 1) : none;
        auto now = before ? inputFor(k) : none;
        auto after = now && delay > 0 ? inputFor(k + 1) : none;
        if (now && (delay == 0 || after)) output = chunkOutput(fx, k, f, delay, *before, *now, after.get(), alive);
        std::lock_guard<std::mutex> lock(tt->mutex);
        tt->pending.erase(k);
        if (output && tt->generation.load() == generation) tt->outputs[k] = output;
    }

    // Puts the bent frame for `frameIndex` into the effect's bendOut texture. Returns
    // false if its chunk is not ready yet (it has been queued); with `wait` it is made now.
    bool bendThroughTime(const Plan &plan, const VideoTrack &track, int index, EffectState &state,
                         int64_t frameIndex, bool wait) {
        const Effect &fx = track.effects[index];
        if (!state.throughTime) state.throughTime = std::make_shared<ThroughTime>();
        std::shared_ptr<ThroughTime> tt = state.throughTime;
        Frame f = {plan.bendWidth, plan.bendHeight, plan.height, plan.fps, fx.memoryFrames};
        int64_t k = frameIndex >= 0 ? frameIndex / f.n : -((-frameIndex + f.n - 1) / f.n);
        size_t pixels = size_t(f.bendWidth) * size_t(f.bendHeight);
        bool knobTurned = fx.plugin->changed.exchange(false);
        uint64_t now = signature(plan, track, index);
        uint64_t generation;
        std::shared_ptr<Blob> ready;
        std::vector<int64_t> wanted;
        {
            std::lock_guard<std::mutex> lock(tt->mutex);
            // A change to what this slot sees, or a turned knob, makes every chunk stale.
            if (tt->signature != now || knobTurned) {
                tt->signature = now;
                tt->generation.fetch_add(1);
                tt->inputs.clear();
                tt->outputs.clear();
                tt->pending.clear();
            }
            generation = tt->generation.load();
            tt->wanted.store(k);
            std::erase_if(tt->inputs, [&](const auto &entry) { return entry.first < k - 1 || entry.first > k + 2; });
            std::erase_if(tt->outputs, [&](const auto &entry) { return entry.first < k || entry.first > k + 1; });
            auto found = tt->outputs.find(k);
            if (found != tt->outputs.end()) ready = found->second;
            // The next chunk is made ahead of the playhead: always for short memory, and
            // for long memory only while playing, since it is a lot of work to throw away.
            bool ahead = !wait && (f.n <= 64 || (engine && engine->playing.load()));
            for (int64_t chunk : {k, k + 1}) {
                if (chunk != k && !ahead) continue;
                if (!tt->outputs.count(chunk) && !tt->pending.count(chunk)) {
                    tt->pending.insert(chunk);
                    wanted.push_back(chunk);
                }
            }
        }
        for (int64_t chunk : wanted) {
            VideoTrack copy = track; // the plan may be retired before the queue gets to this
            Renderer *me = this;
            me->bendJobs.fetch_add(1);
            void (^work)(void) = ^{
                me->makeChunk(tt, generation, copy, index, chunk, f);
                me->bendJobs.fetch_sub(1);
                if (me->engine) me->engine->markDirty();
            };
            if (wait) dispatch_sync(bendQueue, work);
            else dispatch_async(bendQueue, work);
        }
        if (!ready && wait) {
            std::lock_guard<std::mutex> lock(tt->mutex);
            auto found = tt->outputs.find(k);
            if (found != tt->outputs.end()) ready = found->second;
        }
        if (!ready) return false;
        state.bytes.resize(pixels * 4);
        size_t within = size_t(frameIndex - k * f.n);
        pack(ready->bytes + within * pixels * 3, state.bytes.data(), pixels);
        [state.bendOut replaceRegion:MTLRegionMake2D(0, 0, f.bendWidth, f.bendHeight)
                         mipmapLevel:0
                           withBytes:state.bytes.data()
                         bytesPerRow:f.bendWidth * 4];
        return true;
    }

    // Evaluates the picture at `time` and returns the master texture. With `wait`, every
    // frame is decoded exactly (export); without, the closest ready frames are used.
    id<MTLTexture> render(const Plan &plan, int64_t time, bool wait) {
        int width = plan.width, height = plan.height;
        if (!master || int(master.width) != width || int(master.height) != height) {
            master = target(width, height);
            tracks.clear();
            effects.clear();
        }
        if (plan.serial != lastPlan) {
            collect(plan);
            lastPlan = plan.serial;
        }
        double aspect = double(width) / double(height);
        int64_t frameIndex = llround(double(time) * plan.fps / VD_SAMPLE_RATE);
        NSMutableArray *keep = [NSMutableArray array]; // decoded frames stay alive until the GPU is done
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        std::vector<std::pair<const VideoTrack *, id<MTLTexture>>> layers;

        for (const VideoTrack &track : plan.video) {
            if (track.muted || track.regions.empty()) continue;
            TrackState &state = tracks[track.id];
            if (!state.textures[0]) {
                state.textures[0] = target(width, height);
                state.textures[1] = target(width, height);
            }
            int current = 0;
            pass(cb, state.textures[0], true, 0, ^(id<MTLRenderCommandEncoder> encoder) {
                drawRegions(encoder, track, time, wait, aspect, textureCache, keep);
            });

            for (int index = 0; index < int(track.effects.size()); index++) {
                const Effect &fx = track.effects[index];
                if (fx.bypass) continue;
                if (runStateless(cb, fx, time, state.textures, current, 1)) continue;
                id<MTLTexture> from = state.textures[current], into = state.textures[1 - current];
                U u = unit();
                if (fx.kind == VD_FX_FEEDBACK) {
                    EffectState &fs = effects[fx.id];
                    if (!fs.history) {
                        fs.history = target(width, height);
                        pass(cb, fs.history, true, 0, ^(id<MTLRenderCommandEncoder>) {});
                    }
                    u.a = simd_make_float4(fx.params[0].at(time), fx.params[1].at(time), fx.params[2].at(time), float(aspect));
                    filter(cb, feedback, u, from, into, fs.history);
                    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                    [blit copyFromTexture:into toTexture:fs.history];
                    [blit endEncoding];
                    current = 1 - current;
                } else if (fx.kind == VD_FX_AU && fx.plugin) {
                    EffectState &fs = effects[fx.id];
                    if (!fs.bendIn || int(fs.bendIn.width) != plan.bendWidth || int(fs.bendIn.height) != plan.bendHeight) {
                        fs.bendIn = target(plan.bendWidth, plan.bendHeight);
                        fs.bendOut = target(plan.bendWidth, plan.bendHeight);
                    }
                    bool bent;
                    if (fx.bendMode == VD_BEND_RASTER) {
                        // The picture has to come back to the CPU for the Audio Unit.
                        if (fs.throughTime) { // the slot was in through-time mode a moment ago
                            dispatch_sync(bendQueue, ^{});
                            fs.throughTime = nullptr;
                        }
                        fx.plugin->setRate(VD_SAMPLE_RATE);
                        fx.plugin->changed.store(false);
                        filter(cb, copy, unit(), from, fs.bendIn);
                        [cb commit];
                        [cb waitUntilCompleted];
                        bendRaster(plan, fx, fs, time, frameIndex);
                        cb = [queue commandBuffer];
                        bent = true;
                    } else {
                        bent = bendThroughTime(plan, track, index, fs, frameIndex, wait);
                    }
                    if (bent) {
                        u.a = simd_make_float4(fx.mix.at(time), 0, 0, 0);
                        filter(cb, bendMix, u, from, into, fs.bendOut);
                        current = 1 - current;
                    }
                }
            }
            layers.emplace_back(&track, state.textures[current]);
        }

        pass(cb, master, true, 1, ^(id<MTLRenderCommandEncoder> encoder) {
            for (const auto &layer : layers) {
                const VideoTrack &track = *layer.first;
                U u = unit();
                float degrees = track.rotation.at(time), scale = track.scale.at(time);
                simd_float4x4 m = scaling(scale, scale);
                m = simd_mul(scaling(float(aspect), 1), m);
                m = simd_mul(rotation(-degrees * float(M_PI) / 180), m);
                m = simd_mul(scaling(float(1 / aspect), 1), m);
                m = simd_mul(translation(track.x.at(time) * 2, -track.y.at(time) * 2), m);
                u.m = m;
                u.uv0 = simd_make_float2(track.cropLeft.at(time), track.cropTop.at(time));
                u.uv1 = simd_make_float2(1 - track.cropRight.at(time), 1 - track.cropBottom.at(time));
                u.a = simd_make_float4(track.opacity.at(time), float(track.blend), 0, 0);
                quad(encoder, composite, u, layer.second);
            }
        });
        [cb addCompletedHandler:^(id<MTLCommandBuffer>) {
            (void)keep;
        }];
        [cb commit];
        return master;
    }
};

void configureLayer(Renderer *r, CAMetalLayer *layer) {
    if (!r || !layer) return;
    layer.device = r->device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
}

bool bendBusy(Renderer *r) { return r && r->bendJobs.load() > 0; }

Renderer *makeRenderer(VDEngine *engine) {
    Renderer *r = new Renderer;
    r->engine = engine;
    if (!r->setUp()) {
        delete r;
        return nullptr;
    }
    return r;
}

void destroyRenderer(Renderer *r) {
    if (!r) return;
    if (r->bendQueue) dispatch_sync(r->bendQueue, ^{}); // let a chunk in the making finish
    if (r->textureCache) CFRelease(r->textureCache);
    if (r->bendCache) CFRelease(r->bendCache);
    delete r;
}

// ---- Display thread ----------------------------------------------------------------------

// The timeline position that is audible right now.
static int64_t clockPosition(VDEngine *e) {
    if (!e->playing.load() || !e->output) return vd_position(e);
    uint64_t seq, host;
    int64_t position;
    do {
        seq = e->anchorSeq.load();
        host = e->anchorHost.load();
        position = e->anchorPosition.load();
    } while ((seq & 1) || seq != e->anchorSeq.load());
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);
    double seconds = double(int64_t(mach_absolute_time()) - int64_t(host)) * timebase.numer / timebase.denom / 1e9;
    seconds = std::min(0.5, std::max(-0.5, seconds));
    return std::max<int64_t>(0, position + int64_t(seconds * VD_SAMPLE_RATE));
}

void videoThreadMain(VDEngine *e) {
    pthread_setname_np("videodaw.display");
    int64_t shown = -1;
    while (e->running.load()) {
        bool playing = e->playing.load();
        if (e->exporting.load() || !e->renderer || (!playing && !e->dirty.load())) {
            std::unique_lock<std::mutex> lock(e->wakeMutex);
            e->wake.wait_for(lock, std::chrono::milliseconds(50));
            continue;
        }
        CAMetalLayer *layer;
        {
            std::lock_guard<std::mutex> lock(e->layerMutex);
            layer = e->layer;
        }
        if (!layer || layer.drawableSize.width < 1) {
            usleep(20000);
            continue;
        }
        bool wasDirty = e->dirty.exchange(false);
        @autoreleasepool {
            const Plan *plan = e->enter(e->videoReader);
            int64_t frameIndex = int64_t(floor(double(clockPosition(e)) * plan->fps / VD_SAMPLE_RATE));
            if (frameIndex == shown && !wasDirty) {
                e->exit(e->videoReader);
                usleep(2000);
                continue;
            }
            shown = frameIndex;
            int64_t time = int64_t(ceil(double(frameIndex) * VD_SAMPLE_RATE / plan->fps));
            std::lock_guard<std::mutex> lock(e->renderer->mutex);
            Renderer &r = *e->renderer;
            id<MTLTexture> picture = r.render(*plan, time, false);
            double aspect = double(plan->width) / double(plan->height);
            e->exit(e->videoReader);
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (!drawable) continue;
            id<MTLCommandBuffer> cb = [r.queue commandBuffer];
            CGSize size = layer.drawableSize;
            U u = unit();
            u.m = fit(aspect, size.width / size.height);
            r.pass(cb, drawable.texture, true, 1, ^(id<MTLRenderCommandEncoder> encoder) {
                r.quad(encoder, r.copy, u, picture);
            });
            [cb presentDrawable:drawable];
            [cb commit];
        }
    }
}

// ---- Export ------------------------------------------------------------------------------

static CMSampleBufferRef audioSample(const float *left, const float *right, int frames, int64_t at) {
    AudioStreamBasicDescription f = {};
    f.mSampleRate = VD_SAMPLE_RATE;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBitsPerChannel = 32;
    f.mChannelsPerFrame = 2;
    f.mBytesPerFrame = 8;
    f.mFramesPerPacket = 1;
    f.mBytesPerPacket = 8;
    CMAudioFormatDescriptionRef format = nullptr;
    CMAudioFormatDescriptionCreate(nullptr, &f, 0, nullptr, 0, nullptr, nullptr, &format);
    size_t bytes = size_t(frames) * 8;
    CMBlockBufferRef block = nullptr;
    CMBlockBufferCreateWithMemoryBlock(nullptr, nullptr, bytes, nullptr, nullptr, 0, bytes,
                                       kCMBlockBufferAssureMemoryNowFlag, &block);
    std::vector<float> interleaved(size_t(frames) * 2);
    for (int i = 0; i < frames; i++) {
        interleaved[size_t(i) * 2] = left[i];
        interleaved[size_t(i) * 2 + 1] = right[i];
    }
    CMBlockBufferReplaceDataBytes(interleaved.data(), block, 0, bytes);
    CMSampleBufferRef sample = nullptr;
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(nullptr, block, format, frames,
                                                         CMTimeMake(at, VD_SAMPLE_RATE), nullptr, &sample);
    CFRelease(block);
    CFRelease(format);
    return sample;
}

void runExport(VDEngine *e, const Plan *plan, NSString *path, int64_t start, int64_t end, VDProgress progress,
               VDDone done, void *ctx) {
    __block NSString *failure = nil;
    @autoreleasepool {
        do {
            if (!e->renderer) { failure = @"No graphics device is available."; break; }
            if (end <= start) { failure = @"There is nothing to export."; break; }
            Renderer &r = *e->renderer;
            int width = plan->width, height = plan->height;
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            NSError *error = nil;
            AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:[NSURL fileURLWithPath:path]
                                                              fileType:AVFileTypeQuickTimeMovie
                                                                 error:&error];
            if (!writer) { failure = error.localizedDescription; break; }
            NSDictionary *videoSettings = @{
                AVVideoCodecKey : AVVideoCodecTypeH264,
                AVVideoWidthKey : @(width),
                AVVideoHeightKey : @(height),
                AVVideoCompressionPropertiesKey :
                    @{AVVideoAverageBitRateKey : @(int(double(width) * height * plan->fps * 0.2))},
                AVVideoColorPropertiesKey : @{
                    AVVideoColorPrimariesKey : AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey : AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey : AVVideoYCbCrMatrix_ITU_R_709_2,
                },
            };
            AVAssetWriterInput *video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
                                                                           outputSettings:videoSettings];
            video.expectsMediaDataInRealTime = NO;
            NSDictionary *pixelAttributes = @{
                (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
                (id)kCVPixelBufferWidthKey : @(width),
                (id)kCVPixelBufferHeightKey : @(height),
                (id)kCVPixelBufferMetalCompatibilityKey : @YES,
            };
            AVAssetWriterInputPixelBufferAdaptor *adaptor =
                [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:video
                                                                                 sourcePixelBufferAttributes:pixelAttributes];
            NSDictionary *audioSettings = @{
                AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                AVSampleRateKey : @(VD_SAMPLE_RATE),
                AVNumberOfChannelsKey : @2,
                AVEncoderBitRateKey : @256000,
            };
            AVAssetWriterInput *audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
                                                                           outputSettings:audioSettings];
            audio.expectsMediaDataInRealTime = NO;
            [writer addInput:video];
            [writer addInput:audio];
            if (![writer startWriting]) { failure = writer.error.localizedDescription; break; }
            [writer startSessionAtSourceTime:kCMTimeZero];

            // Start every stateful effect from silence so an export is repeatable.
            r.resetState();
            for (const AudioTrack &track : plan->audio)
                for (const Effect &fx : track.effects)
                    if (fx.plugin) fx.plugin->reset();

            AudioScratch scratch;
            std::vector<float> left(1024), right(1024);
            int64_t frames = int64_t(ceil(double(end - start) * plan->fps / VD_SAMPLE_RATE));
            int64_t audioAt = start;
            // Feed whichever stream is behind and ready. The writer interleaves the two and
            // refuses data on one input until the other catches up, so neither may block.
            int64_t videoIndex = 0;
            bool videoOpen = true, audioOpen = true;
            while ((videoOpen || audioOpen) && !failure) {
                if (writer.status != AVAssetWriterStatusWriting) {
                    failure = writer.error.localizedDescription ?: @"The movie writer stopped.";
                    break;
                }
                double videoSeconds = double(videoIndex) / plan->fps;
                double audioSeconds = double(audioAt - start) / VD_SAMPLE_RATE;
                bool videoFirst = videoOpen && (!audioOpen || videoSeconds <= audioSeconds);
                bool wroteSomething = false;
                for (int attempt = 0; attempt < 2 && !wroteSomething && !failure; attempt++) {
                    bool doVideo = attempt == 0 ? videoFirst : !videoFirst;
                    if (doVideo && videoOpen && video.readyForMoreMediaData) {
                        @autoreleasepool {
                            int64_t time = start + llround(double(videoIndex) * VD_SAMPLE_RATE / plan->fps);
                            CVPixelBufferRef pixels = nullptr;
                            CVPixelBufferPoolCreatePixelBuffer(nullptr, adaptor.pixelBufferPool, &pixels);
                            if (!pixels) { failure = @"Could not allocate a frame."; break; }
                            {
                                std::lock_guard<std::mutex> lock(r.mutex);
                                id<MTLTexture> picture = r.render(*plan, time, true);
                                CVMetalTextureRef wrapped = nullptr;
                                CVMetalTextureCacheCreateTextureFromImage(nullptr, r.textureCache, pixels, nullptr,
                                                                          MTLPixelFormatBGRA8Unorm, width, height, 0,
                                                                          &wrapped);
                                if (wrapped) {
                                    id<MTLCommandBuffer> cb = [r.queue commandBuffer];
                                    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
                                    [blit copyFromTexture:picture toTexture:CVMetalTextureGetTexture(wrapped)];
                                    [blit endEncoding];
                                    [cb commit];
                                    [cb waitUntilCompleted];
                                    CFRelease(wrapped);
                                }
                            }
                            CMTime stamp = CMTimeMake(llround(double(videoIndex) * 60000 / plan->fps), 60000);
                            if (![adaptor appendPixelBuffer:pixels withPresentationTime:stamp])
                                failure = writer.error.localizedDescription ?: @"Could not write a frame.";
                            CVPixelBufferRelease(pixels);
                            videoIndex++;
                            wroteSomething = true;
                            if (videoIndex >= frames) {
                                [video markAsFinished];
                                videoOpen = false;
                            }
                            if (progress && videoIndex % 5 == 0) {
                                double fraction = double(videoIndex) / double(frames);
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    progress(ctx, fraction);
                                });
                            }
                        }
                    } else if (!doVideo && audioOpen && audio.readyForMoreMediaData) {
                        int n = int(std::min<int64_t>(1024, end - audioAt));
                        renderAudio(*plan, audioAt, n, left.data(), right.data(), scratch);
                        CMSampleBufferRef sample = audioSample(left.data(), right.data(), n, audioAt - start);
                        if (![audio appendSampleBuffer:sample])
                            failure = writer.error.localizedDescription ?: @"Could not write audio.";
                        CFRelease(sample);
                        audioAt += n;
                        wroteSomething = true;
                        if (audioAt >= end) {
                            [audio markAsFinished];
                            audioOpen = false;
                        }
                    }
                }
                if (!wroteSomething) usleep(1000);
            }
            if (videoOpen) [video markAsFinished];
            if (audioOpen) [audio markAsFinished];
            dispatch_semaphore_t finished = dispatch_semaphore_create(0);
            [writer finishWritingWithCompletionHandler:^{
                dispatch_semaphore_signal(finished);
            }];
            dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
            if (!failure && writer.status != AVAssetWriterStatusCompleted)
                failure = writer.error.localizedDescription ?: @"The movie could not be finished.";
        } while (false);
    }
    e->exit(e->exportReader);
    if (e->renderer) e->renderer->resetState();
    e->exporting.store(false);
    e->markDirty();
    NSString *message = failure;
    dispatch_async(dispatch_get_main_queue(), ^{
        done(ctx, message.UTF8String);
    });
}
