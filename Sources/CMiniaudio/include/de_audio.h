/*
 * DoublEnder capture shim over miniaudio.
 *
 * Swift never runs on the real-time audio thread. The miniaudio data
 * callback lives in de_audio.c: it copies whole frames, in the device's
 * native format, into a lock-free single-producer/single-consumer ring
 * buffer, and counts what it could not fit. AudioEngine drains the ring on
 * its own pump thread. This is the cross-platform stand-in for the Mac
 * build's AVCaptureAudioDataOutput, which also delivers native-format
 * buffers with no conversion in the capture path.
 */
#ifndef DE_AUDIO_H
#define DE_AUDIO_H

/* Capture only: leave out miniaudio's decoders, encoders and engine. These
   must be identical in every translation unit that includes miniaudio.h,
   which is why they live here rather than in build settings. */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE

#include "miniaudio.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---- Context: one per app run ------------------------------------------ */

typedef struct de_context de_context;

/* NULL when no audio backend could be initialised. */
de_context* de_context_create(void);
/* miniaudio's null backend only: one capture device that delivers silence at
   real time, with no hardware or permission needed. For tests. */
de_context* de_context_create_null(void);
void de_context_destroy(de_context* ctx);
/* "PulseAudio", "WASAPI", "ALSA", ... */
const char* de_context_backend_name(const de_context* ctx);

typedef struct {
    ma_device_id id;
    char name[256];
    /* Stable per physical device and backend: the backend id's bytes as
       hex, prefixed with the backend number. Never shown to the user. */
    char uid[528];
    ma_bool32 isDefault;
} de_device_entry;

/* Fills `out` with up to `cap` capture devices. Returns the count, or a
   negative ma_result on failure. */
int de_context_capture_devices(de_context* ctx, de_device_entry* out, int cap);

/* The Plug and Play instance ID of the controller behind a device, as UTF-8
   in `out`: "USB\VID_…" for USB, "BTHENUM\…" or "BTHHFENUM\…" for Bluetooth,
   "HDAUDIO\…" for built-in audio. WASAPI only, where device names don't say
   reliably what a device is; elsewhere, or when Windows can't say, "". Can
   take a few milliseconds, so call it once per device. */
void de_context_device_controller(de_context* ctx, const ma_device_id* id, char* out, size_t capacity);

/* ---- Capture ------------------------------------------------------------- */

typedef struct de_capture de_capture;

enum {
    DE_NOTE_STOPPED     = 1,
    DE_NOTE_REROUTED    = 2,
    DE_NOTE_INTERRUPTED = 4,
    DE_NOTE_RESUMED     = 8
};

/* Opens `id` (NULL = system default) in its native format, rate and
   channel count, with a ring buffer holding `ringSeconds` of audio. Does
   not start it. */
ma_result de_capture_open(de_context* ctx, const ma_device_id* id,
                          ma_uint32 ringSeconds, de_capture** out);
ma_result de_capture_start(de_capture* cap);
/* Stops, uninitialises and frees. Safe on NULL. */
void de_capture_close(de_capture* cap);

ma_format de_capture_format(const de_capture* cap);
ma_uint32 de_capture_channels(const de_capture* cap);
ma_uint32 de_capture_sample_rate(const de_capture* cap);
ma_uint32 de_capture_bytes_per_frame(const de_capture* cap);
/* Copies the channel map into `out` (up to `capacity`), returns channels. */
ma_uint32 de_capture_channel_map(const de_capture* cap, ma_channel* out, ma_uint32 capacity);
/* The backend's name for the open device. */
void de_capture_device_name(const de_capture* cap, char* out, size_t capacity);

/* Consumer side, one thread only. Copies whole frames, at most `maxBytes`,
   and returns the byte count (a multiple of the frame size). */
size_t de_capture_read(de_capture* cap, void* dst, size_t maxBytes);

/* Cumulative counters, safe from any thread. */
ma_uint64 de_capture_frames_delivered(de_capture* cap);
ma_uint64 de_capture_frames_dropped(de_capture* cap);
/* Returns the DE_NOTE_* flags raised since the last call, and clears them. */
ma_uint32 de_capture_take_notifications(de_capture* cap);

#ifdef __cplusplus
}
#endif

#endif /* DE_AUDIO_H */
