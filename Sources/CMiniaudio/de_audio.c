/*
 * miniaudio's implementation and the DoublEnder capture shim share this one
 * translation unit, so the shim can use miniaudio's portable atomics.
 */
#define MINIAUDIO_IMPLEMENTATION
#include "de_audio.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Context ------------------------------------------------------------- */

struct de_context {
    ma_context ctx;
};

de_context* de_context_create(void)
{
    de_context* c = (de_context*)calloc(1, sizeof(*c));
    if (c == NULL) {
        return NULL;
    }
    ma_context_config config = ma_context_config_init();
    /* Never start a PulseAudio daemon on the user's behalf. */
    config.pulse.tryAutoSpawn = MA_FALSE;
    config.pulse.pApplicationName = "DoublEnder";
    if (ma_context_init(NULL, 0, &config, &c->ctx) != MA_SUCCESS) {
        free(c);
        return NULL;
    }
    return c;
}

de_context* de_context_create_null(void)
{
    ma_backend backend = ma_backend_null;
    de_context* c = (de_context*)calloc(1, sizeof(*c));
    if (c == NULL) {
        return NULL;
    }
    if (ma_context_init(&backend, 1, NULL, &c->ctx) != MA_SUCCESS) {
        free(c);
        return NULL;
    }
    return c;
}

void de_context_destroy(de_context* ctx)
{
    if (ctx == NULL) {
        return;
    }
    ma_context_uninit(&ctx->ctx);
    free(ctx);
}

const char* de_context_backend_name(const de_context* ctx)
{
    return ma_get_backend_name(ctx->ctx.backend);
}

/* miniaudio zeroes each device info before filling it, so the id's bytes
   past the backend's own field are zero and the trimmed hex is stable. */
static void de_make_uid(ma_backend backend, const ma_device_id* id, char* out, size_t capacity)
{
    static const char hex[] = "0123456789abcdef";
    const unsigned char* bytes = (const unsigned char*)id;
    size_t length = sizeof(*id);
    size_t o;
    size_t i;

    while (length > 0 && bytes[length - 1] == 0) {
        length -= 1;
    }
    o = (size_t)snprintf(out, capacity, "%d:", (int)backend);
    for (i = 0; i < length && o + 2 < capacity; i += 1) {
        out[o++] = hex[bytes[i] >> 4];
        out[o++] = hex[bytes[i] & 15];
    }
    out[o < capacity ? o : capacity - 1] = '\0';
}

int de_context_capture_devices(de_context* ctx, de_device_entry* out, int cap)
{
    ma_device_info* captureInfos;
    ma_uint32 captureCount;
    ma_uint32 i;
    int n = 0;
    ma_result result = ma_context_get_devices(&ctx->ctx, NULL, NULL, &captureInfos, &captureCount);
    if (result != MA_SUCCESS) {
        return (int)result < 0 ? (int)result : -1;
    }
    for (i = 0; i < captureCount && n < cap; i += 1) {
        de_device_entry* e = &out[n++];
        memset(e, 0, sizeof(*e));
        e->id = captureInfos[i].id;
        ma_strncpy_s(e->name, sizeof(e->name), captureInfos[i].name, (size_t)-1);
        e->isDefault = captureInfos[i].isDefault;
        de_make_uid(ctx->ctx.backend, &captureInfos[i].id, e->uid, sizeof(e->uid));
    }
    return n;
}

#if defined(_WIN32)
/* de_audio_win.c: kept apart because it needs the Windows SDK's audio
   headers, whose COM declarations would collide with miniaudio's own. */
void de_win_endpoint_controller(const wchar_t* endpointID, char* out, size_t capacity);
#endif

void de_context_device_controller(de_context* ctx, const ma_device_id* id, char* out, size_t capacity)
{
    if (capacity == 0) {
        return;
    }
    out[0] = '\0';
#if defined(_WIN32)
    if (ctx->ctx.backend == ma_backend_wasapi) {
        de_win_endpoint_controller((const wchar_t*)id->wasapi, out, capacity);
    }
#else
    (void)ctx;
    (void)id;
#endif
}

/* ---- Capture ------------------------------------------------------------- */

struct de_capture {
    ma_device device;
    ma_rb ring;
    ma_bool32 ringReady;
    ma_uint32 bytesPerFrame;
    ma_uint64 framesDropped;    /* atomic */
    ma_uint32 notifications;    /* atomic DE_NOTE_* bits */
};

/* Real-time thread. No allocation, no locks, no Swift. */
static void de_data_callback(ma_device* device, void* output, const void* input, ma_uint32 frameCount)
{
    de_capture* cap = (de_capture*)device->pUserData;
    const ma_uint8* src = (const ma_uint8*)input;
    ma_uint32 bpf;
    ma_uint32 framesFit;
    size_t remaining;
    (void)output;

    if (cap == NULL || !cap->ringReady || src == NULL || frameCount == 0) {
        return;
    }
    bpf = cap->bytesPerFrame;
    framesFit = ma_rb_available_write(&cap->ring) / bpf;
    if (framesFit > frameCount) {
        framesFit = frameCount;
    }
    /* The ring holds a whole number of frames, so a wrap never splits one. */
    remaining = (size_t)framesFit * bpf;
    while (remaining > 0) {
        size_t chunk = remaining;
        void* dst;
        if (ma_rb_acquire_write(&cap->ring, &chunk, &dst) != MA_SUCCESS || chunk == 0) {
            break;
        }
        memcpy(dst, src, chunk);
        ma_rb_commit_write(&cap->ring, chunk);
        src += chunk;
        remaining -= chunk;
    }
    if (framesFit < frameCount) {
        ma_atomic_fetch_add_64(&cap->framesDropped, (ma_uint64)(frameCount - framesFit));
    }
}

static void de_notification_callback(const ma_device_notification* notification)
{
    de_capture* cap = (de_capture*)notification->pDevice->pUserData;
    ma_uint32 bit = 0;
    if (cap == NULL) {
        return;
    }
    switch (notification->type) {
        case ma_device_notification_type_stopped:            bit = DE_NOTE_STOPPED; break;
        case ma_device_notification_type_rerouted:           bit = DE_NOTE_REROUTED; break;
        case ma_device_notification_type_interruption_began: bit = DE_NOTE_INTERRUPTED; break;
        case ma_device_notification_type_interruption_ended: bit = DE_NOTE_RESUMED; break;
        default: break;
    }
    if (bit != 0) {
        ma_atomic_fetch_or_32(&cap->notifications, bit);
    }
}

ma_result de_capture_open(de_context* ctx, const ma_device_id* id,
                          ma_uint32 ringSeconds, de_capture** out)
{
    ma_device_config config;
    ma_result result;
    size_t ringBytes;
    de_capture* cap;

    *out = NULL;
    cap = (de_capture*)calloc(1, sizeof(*cap));
    if (cap == NULL) {
        return MA_OUT_OF_MEMORY;
    }

    config = ma_device_config_init(ma_device_type_capture);
    config.capture.pDeviceID = id;
    /* Native format, channel count and rate: no conversion in the capture
       path, as on the Mac. The pump thread mixes to mono itself. */
    config.capture.format = ma_format_unknown;
    config.capture.channels = 0;
    config.sampleRate = 0;
    config.capture.shareMode = ma_share_mode_shared;
    config.performanceProfile = ma_performance_profile_conservative;
    config.dataCallback = de_data_callback;
    config.notificationCallback = de_notification_callback;
    config.pUserData = cap;
    /* WASAPI: never let Windows resample the stream. */
    config.wasapi.noAutoConvertSRC = MA_TRUE;
    config.wasapi.noDefaultQualitySRC = MA_TRUE;
    config.pulse.pStreamNameCapture = "DoublEnder recording";

    result = ma_device_init(&ctx->ctx, &config, &cap->device);
    if (result != MA_SUCCESS) {
        free(cap);
        return result;
    }

    cap->bytesPerFrame = ma_get_bytes_per_frame(cap->device.capture.format, cap->device.capture.channels);
    if (cap->bytesPerFrame == 0 || cap->device.sampleRate == 0) {
        ma_device_uninit(&cap->device);
        free(cap);
        return MA_FORMAT_NOT_SUPPORTED;
    }
    if (ringSeconds == 0) {
        ringSeconds = 1;
    }
    ringBytes = (size_t)cap->device.sampleRate * ringSeconds * cap->bytesPerFrame;
    result = ma_rb_init(ringBytes, NULL, NULL, &cap->ring);
    if (result != MA_SUCCESS) {
        ma_device_uninit(&cap->device);
        free(cap);
        return result;
    }
    cap->ringReady = MA_TRUE;
    *out = cap;
    return MA_SUCCESS;
}

ma_result de_capture_start(de_capture* cap)
{
    return ma_device_start(&cap->device);
}

void de_capture_close(de_capture* cap)
{
    if (cap == NULL) {
        return;
    }
    /* Uninit stops the device and joins its thread, so the callback can no
       longer touch the ring when it is freed below. */
    ma_device_uninit(&cap->device);
    if (cap->ringReady) {
        ma_rb_uninit(&cap->ring);
    }
    free(cap);
}

ma_format de_capture_format(const de_capture* cap)       { return cap->device.capture.format; }
ma_uint32 de_capture_channels(const de_capture* cap)     { return cap->device.capture.channels; }
ma_uint32 de_capture_sample_rate(const de_capture* cap)  { return cap->device.sampleRate; }

ma_uint32 de_capture_channel_map(const de_capture* cap, ma_channel* out, ma_uint32 capacity)
{
    ma_uint32 channels = cap->device.capture.channels;
    ma_uint32 i;
    for (i = 0; i < channels && i < capacity; i += 1) {
        out[i] = cap->device.capture.channelMap[i];
    }
    return channels;
}

size_t de_capture_read(de_capture* cap, void* dst, size_t maxBytes)
{
    ma_uint32 bpf = cap->bytesPerFrame;
    size_t want = (ma_rb_available_read(&cap->ring) / bpf) * bpf;
    size_t done = 0;
    ma_uint8* out = (ma_uint8*)dst;

    if (want > maxBytes) {
        want = (maxBytes / bpf) * bpf;
    }
    while (done < want) {
        size_t chunk = want - done;
        void* src;
        if (ma_rb_acquire_read(&cap->ring, &chunk, &src) != MA_SUCCESS || chunk == 0) {
            break;
        }
        memcpy(out + done, src, chunk);
        ma_rb_commit_read(&cap->ring, chunk);
        done += chunk;
    }
    return done;
}

ma_uint64 de_capture_frames_dropped(de_capture* cap)
{
    return ma_atomic_load_64(&cap->framesDropped);
}

ma_uint32 de_capture_take_notifications(de_capture* cap)
{
    return ma_atomic_exchange_32(&cap->notifications, 0);
}
