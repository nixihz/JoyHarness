// DualSense Bluetooth audio engine: speaker output and microphone input over the controller's BT HID link.
//
// Threading contract:
//   - ds5_engine_create/create_shared/destroy and every *_start/*_stop call are blocking and must be called
//     from a non-real-time thread. They must NOT be called from inside the presence callback.
//   - ds5_speaker_write and ds5_mic_read are real-time safe: no locks, allocation, logging or syscalls.
//   - The presence callback runs on the engine's internal HID thread.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DS5_SAMPLE_RATE 48000u

typedef struct ds5_engine ds5_engine;
typedef void (*ds5_control_fn)(const uint8_t *, size_t, uint64_t);
void ds5_engine_set_control_observer(ds5_engine *e, ds5_control_fn observer);

typedef enum {
    DS5_OK = 0,
    DS5_ERR_NO_DEVICE = -1, // no DualSense connected
    DS5_ERR_EXCLUSIVE = -2, // could not take exclusive access; the mic was NOT opened
    DS5_ERR_IO = -3,        // HID report I/O failed
} ds5_status;

// connected == true when a DualSense (VID 0x054C, PID 0x0CE6) over Bluetooth is opened and ready.
typedef void (*ds5_presence_fn)(void *ctx, bool connected);

typedef struct {
    bool connected;
    bool speaker_running;
    bool mic_running;
    bool exclusive;                   // engine currently holds exclusive (seize) access
    uint64_t speaker_reports_sent;
    uint64_t speaker_send_errors;
    uint64_t speaker_late_ticks;      // sender ticks that started after their deadline
    uint64_t speaker_underrun_frames; // input frames zero-filled because the writer supplied too few while playing
                                      // (the silent prebuffer at start and after each underrun is not counted)
    uint64_t mic_frames_received;
    uint64_t mic_frames_concealed;    // frames synthesized by Opus PLC for counter gaps
    double input_reports_per_sec;     // all input reports, last ~1 s: ~67 => 15 ms link, ~133 => 7.5 ms (Game Mode)
    double mic_loss_ratio;            // concealed / (received + concealed) over the last ~2 s of mic activity
} ds5_stats;

// Starts the internal HID thread and device matching. presence may be NULL. The engine allocates its own audio
// region and feeds it through ds5_speaker_write / ds5_mic_read (used by the CLI).
ds5_engine *ds5_engine_create(ds5_presence_fn presence, void *ctx);
// Same, but the audio flows through the rings of a region the caller formatted with ds5_shm_format (see
// ds5_shared.h); another process drives the other side of it with a ds5_port. The region must stay mapped until
// after ds5_engine_destroy. On such an engine ds5_speaker_write, ds5_mic_read, ds5_speaker_set_gain and
// ds5_speaker_set_mute do nothing (ds5_mic_read zero-fills). NULL if the region is not formatted.
ds5_engine *ds5_engine_create_shared(ds5_presence_fn presence, void *ctx, void *shm, size_t size);
// Stops speaker and mic (closing the mic session and releasing exclusive access), then tears down.
void ds5_engine_destroy(ds5_engine *e);
bool ds5_engine_connected(ds5_engine *e);
void ds5_engine_get_stats(ds5_engine *e, ds5_stats *out);

// Speaker. Accepts interleaved stereo float32 at 48 kHz; downmixed to mono for the controller's mono speaker, then
// given a +6 dB soft-limited boost (see ds5_port_speaker_write).
ds5_status ds5_speaker_start(ds5_engine *e);
void ds5_speaker_stop(ds5_engine *e);
void ds5_speaker_write(ds5_engine *e, const float *stereo, uint32_t frames);
void ds5_speaker_set_gain(ds5_engine *e, float linear); // applied in ds5_speaker_write; default 1.0
void ds5_speaker_set_mute(ds5_engine *e, bool mute);

// Microphone. Takes exclusive access to the controller for the whole session (other apps and the
// GameController framework stop receiving its input), then opens the mic session.
ds5_status ds5_mic_start(ds5_engine *e);
// Closes the mic session, then releases exclusive access.
void ds5_mic_stop(ds5_engine *e);
// Copies up to `frames` mono float32 samples at 48 kHz; zero-fills any shortfall.
// Returns the number of frames that carried received or concealed audio.
uint32_t ds5_mic_read(ds5_engine *e, float *mono, uint32_t frames);

#ifdef __cplusplus
}
#endif
