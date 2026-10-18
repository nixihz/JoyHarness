// ds5audio: diagnostics CLI for the DualSense Bluetooth audio engine (status, tone, play, record).
#define _DARWIN_C_SOURCE

#include <errno.h>
#include <math.h>
#include <signal.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>

#include "ds5_engine.h"

enum {
    RC_OK = 0,
    RC_FAIL = 1,
    RC_EXCLUSIVE = 2,
    RC_START = 3,
    RC_INTERRUPTED = 130,
};

#define FEED_CUSHION_FRAMES 1024u
#define FEED_CHUNK_FRAMES 480u
#define MIC_CHUNK_FRAMES 480u
#define TICK_NS 10000000ull
#define MAX_LAG_NS 50000000ull
#define POLL_NS 20000000ull
#define SECOND_NS 1000000000ull
#define CONNECT_TIMEOUT_NS (3 * SECOND_NS)
#define DRAIN_NS 100000000ull
#define MAX_SECONDS 3600.0
#define TONE_AMPLITUDE 0.3
#define WAVE_FORMAT_PCM 1u
#define WAVE_FORMAT_FLOAT 3u
#define WAVE_FORMAT_EXTENSIBLE 0xFFFEu

static volatile sig_atomic_t g_interrupted;
static sigset_t g_signals;
static os_log_t g_log;
static mach_timebase_info_data_t g_timebase;

// ---------------------------------------------------------------------------------------------
// Diagnostics

static void report_error(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void report_error(const char *fmt, ...)
{
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    fprintf(stderr, "ds5audio: %s\n", msg);
    os_log_error(g_log, "%{public}s", msg);
}

static const char *status_name(ds5_status st)
{
    switch (st) {
    case DS5_OK: return "DS5_OK";
    case DS5_ERR_NO_DEVICE: return "DS5_ERR_NO_DEVICE";
    case DS5_ERR_EXCLUSIVE: return "DS5_ERR_EXCLUSIVE";
    case DS5_ERR_IO: return "DS5_ERR_IO";
    }
    return "unknown status";
}

static const char *yes_no(bool b) { return b ? "yes" : "no"; }

static void print_stats_line(const ds5_stats *s)
{
    printf("connected=%s speaker_running=%s mic_running=%s exclusive=%s input_reports_per_sec=%.1f "
           "speaker_reports_sent=%llu speaker_send_errors=%llu speaker_late_ticks=%llu "
           "speaker_underrun_frames=%llu mic_frames_received=%llu mic_frames_concealed=%llu mic_loss=%.1f%%\n",
           yes_no(s->connected), yes_no(s->speaker_running), yes_no(s->mic_running), yes_no(s->exclusive),
           s->input_reports_per_sec, (unsigned long long)s->speaker_reports_sent,
           (unsigned long long)s->speaker_send_errors, (unsigned long long)s->speaker_late_ticks,
           (unsigned long long)s->speaker_underrun_frames, (unsigned long long)s->mic_frames_received,
           (unsigned long long)s->mic_frames_concealed, s->mic_loss_ratio * 100.0);
}

static void print_stats(ds5_engine *e)
{
    ds5_stats s;
    ds5_engine_get_stats(e, &s);
    print_stats_line(&s);
}

static void on_presence(void *ctx, bool connected)
{
    fprintf(stderr, "[presence] DualSense %s\n", connected ? "connected" : "disconnected");
}

// ---------------------------------------------------------------------------------------------
// Signals and time

static void on_signal(int sig) { g_interrupted = 1; }

static void install_signals(void)
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND; // a second Ctrl-C kills the process
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigemptyset(&g_signals);
    sigaddset(&g_signals, SIGINT);
    sigaddset(&g_signals, SIGTERM);
}

// Threads inherit the creator's mask: block around calls that may spawn threads so signals always
// land on the main thread instead of interrupting engine or feeder timing.
static void block_signals(bool block)
{
    pthread_sigmask(block ? SIG_BLOCK : SIG_UNBLOCK, &g_signals, NULL);
}

static uint64_t ns_to_abs(uint64_t ns) { return ns * g_timebase.denom / g_timebase.numer; }

static uint64_t min_u64(uint64_t a, uint64_t b) { return a < b ? a : b; }

// Sleeps until `deadline`, polling the interrupt flag every 20 ms. Returns false if interrupted.
static bool wait_until(uint64_t deadline)
{
    uint64_t step = ns_to_abs(POLL_NS);
    for (;;) {
        if (g_interrupted)
            return false;
        uint64_t now = mach_absolute_time();
        if (now >= deadline)
            return true;
        mach_wait_until(min_u64(now + step, deadline));
    }
}

static bool sleep_ns(uint64_t ns) { return wait_until(mach_absolute_time() + ns_to_abs(ns)); }

// Absolute 10 ms schedule; re-anchors instead of bursting when more than 50 ms behind.
typedef struct {
    uint64_t next;
    uint64_t tick;
    uint64_t max_lag;
} pacer;

static void pacer_init(pacer *p)
{
    p->tick = ns_to_abs(TICK_NS);
    p->max_lag = ns_to_abs(MAX_LAG_NS);
    p->next = mach_absolute_time() + p->tick;
}

static void pacer_wait(pacer *p)
{
    mach_wait_until(p->next);
    uint64_t now = mach_absolute_time();
    if (now > p->next + p->max_lag)
        p->next = now;
    p->next += p->tick;
}

static bool wait_for_connection(ds5_engine *e)
{
    uint64_t deadline = mach_absolute_time() + ns_to_abs(CONNECT_TIMEOUT_NS);
    uint64_t step = ns_to_abs(POLL_NS);
    while (!ds5_engine_connected(e)) {
        uint64_t now = mach_absolute_time();
        if (g_interrupted || now >= deadline)
            return false;
        mach_wait_until(min_u64(now + step, deadline));
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// Little-endian helpers

static uint16_t get_le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

static uint32_t get_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static float get_le_f32(const uint8_t *p)
{
    uint32_t bits = get_le32(p);
    float f;
    memcpy(&f, &bits, sizeof f);
    return f;
}

static void put_le16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
}

static void put_le32(uint8_t *p, uint32_t v)
{
    for (int i = 0; i < 4; i++)
        p[i] = (uint8_t)(v >> (8 * i));
}

// ---------------------------------------------------------------------------------------------
// WAV reader (streams the data chunk)

typedef struct {
    FILE *f;
    const char *path;
    uint16_t format; // WAVE_FORMAT_PCM or WAVE_FORMAT_FLOAT (subformat resolved for extensible)
    uint16_t channels;
    uint16_t bits;
    uint16_t block_align;
    uint64_t frames;
    uint64_t remaining;
    uint64_t played;
    bool read_error;
    uint8_t scratch[FEED_CUSHION_FRAMES * 2 * 4];
} wav_reader;

static void chunk_id_text(const uint8_t *id, char out[5])
{
    for (int i = 0; i < 4; i++)
        out[i] = (id[i] >= 0x20 && id[i] < 0x7F) ? (char)id[i] : '?';
    out[4] = '\0';
}

static void describe_format(char *buf, size_t n, uint16_t tag, uint16_t format)
{
    const char *name = format == WAVE_FORMAT_PCM ? "PCM" : format == WAVE_FORMAT_FLOAT ? "float" : NULL;
    if (tag == WAVE_FORMAT_EXTENSIBLE && name)
        snprintf(buf, n, "%s (extensible)", name);
    else if (tag == WAVE_FORMAT_EXTENSIBLE)
        snprintf(buf, n, "extensible subformat 0x%04X", format);
    else if (name)
        snprintf(buf, n, "%s", name);
    else
        snprintf(buf, n, "format 0x%04X", tag);
}

// Walks the RIFF chunks; leaves the file positioned at the data chunk payload.
static bool wav_find_chunks(wav_reader *w, uint8_t fmt[40], uint32_t *fmt_size, uint64_t *data_pos,
                            uint64_t *data_size)
{
    struct stat st;
    if (fstat(fileno(w->f), &st) != 0 || !S_ISREG(st.st_mode)) {
        report_error("%s is not a regular file", w->path);
        return false;
    }
    uint64_t size = (uint64_t)st.st_size;
    uint8_t riff[12];
    if (fread(riff, 1, sizeof riff, w->f) != sizeof riff || memcmp(riff, "RIFF", 4) != 0 ||
        memcmp(riff + 8, "WAVE", 4) != 0) {
        report_error("%s is not a WAV file (no RIFF/WAVE header)", w->path);
        return false;
    }
    bool have_fmt = false, have_data = false;
    uint64_t pos = sizeof riff;
    while (!(have_fmt && have_data)) {
        uint8_t hdr[8];
        size_t n = fread(hdr, 1, sizeof hdr, w->f);
        if (n == 0)
            break;
        if (n != sizeof hdr) {
            report_error("truncated WAV: incomplete chunk header at offset %llu", (unsigned long long)pos);
            return false;
        }
        char id[5];
        chunk_id_text(hdr, id);
        uint32_t csize = get_le32(hdr + 4);
        pos += sizeof hdr;
        if (csize > size - pos) {
            report_error("truncated WAV: '%s' chunk declares %u bytes but only %llu remain in the file", id,
                         csize, (unsigned long long)(size - pos));
            return false;
        }
        if (memcmp(hdr, "fmt ", 4) == 0) {
            if (csize < 16) {
                report_error("invalid WAV: fmt chunk is %u bytes; need at least 16", csize);
                return false;
            }
            size_t take = csize < 40 ? csize : 40;
            if (fread(fmt, 1, take, w->f) != take) {
                report_error("truncated WAV: could not read the fmt chunk");
                return false;
            }
            *fmt_size = csize;
            have_fmt = true;
        } else if (memcmp(hdr, "data", 4) == 0) {
            *data_pos = pos;
            *data_size = csize;
            have_data = true;
        }
        pos += (uint64_t)csize + (csize & 1u); // chunks are padded to even sizes
        if (fseeko(w->f, (off_t)pos, SEEK_SET) != 0) {
            report_error("cannot seek in %s: %s", w->path, strerror(errno));
            return false;
        }
    }
    if (!have_fmt || !have_data) {
        report_error("invalid WAV: no %s chunk", have_fmt ? "data" : "fmt ");
        return false;
    }
    if (fseeko(w->f, (off_t)*data_pos, SEEK_SET) != 0) {
        report_error("cannot seek in %s: %s", w->path, strerror(errno));
        return false;
    }
    return true;
}

static bool wav_parse(wav_reader *w)
{
    uint8_t fmt[40] = {0};
    uint32_t fmt_size = 0;
    uint64_t data_pos = 0, data_size = 0;
    if (!wav_find_chunks(w, fmt, &fmt_size, &data_pos, &data_size))
        return false;

    uint16_t tag = get_le16(fmt);
    uint32_t rate = get_le32(fmt + 4);
    w->channels = get_le16(fmt + 2);
    w->block_align = get_le16(fmt + 12);
    w->bits = get_le16(fmt + 14);
    w->format = tag;
    if (tag == WAVE_FORMAT_EXTENSIBLE) {
        if (fmt_size < 40) {
            report_error("invalid WAV: WAVE_FORMAT_EXTENSIBLE fmt chunk is %u bytes; need 40", fmt_size);
            return false;
        }
        w->format = get_le16(fmt + 24); // first two bytes of the subformat GUID
    }

    bool type_ok = (w->format == WAVE_FORMAT_PCM && w->bits == 16) ||
                   (w->format == WAVE_FORMAT_FLOAT && w->bits == 32);
    if (!type_ok || w->channels < 1 || w->channels > 2 || rate != DS5_SAMPLE_RATE) {
        char desc[48];
        describe_format(desc, sizeof desc, tag, w->format);
        report_error("unsupported WAV: %u Hz, %u-bit %s, %u ch; need 48000 Hz PCM16 or float32, mono or stereo",
                     rate, w->bits, desc, w->channels);
        return false;
    }
    unsigned expected_align = w->channels * w->bits / 8u;
    if (w->block_align != expected_align) {
        report_error("invalid WAV: block align %u, expected %u for %u ch x %u-bit", w->block_align,
                     expected_align, w->channels, w->bits);
        return false;
    }
    w->frames = data_size / w->block_align;
    w->remaining = w->frames;
    return true;
}

static bool wav_open(wav_reader *w, const char *path)
{
    memset(w, 0, sizeof *w);
    w->path = path;
    w->f = fopen(path, "rb");
    if (!w->f) {
        report_error("cannot open %s: %s", path, strerror(errno));
        return false;
    }
    if (!wav_parse(w)) {
        fclose(w->f);
        w->f = NULL;
        return false;
    }
    return true;
}

static const char *wav_format_name(const wav_reader *w)
{
    return w->format == WAVE_FORMAT_PCM ? "PCM16" : "float32";
}

// Feeder source: reads and converts up to `frames` frames to interleaved stereo float.
static uint32_t wav_fill(void *ctx, float *stereo, uint32_t frames)
{
    wav_reader *w = ctx;
    if (frames > w->remaining)
        frames = (uint32_t)w->remaining;
    size_t want = (size_t)frames * w->block_align;
    size_t got = fread(w->scratch, 1, want, w->f);
    if (got < want) {
        w->read_error = true;
        w->remaining = 0;
        frames = (uint32_t)(got / w->block_align);
    } else {
        w->remaining -= frames;
    }
    for (uint32_t i = 0; i < frames; i++) {
        const uint8_t *p = w->scratch + (size_t)i * w->block_align;
        float l, r;
        if (w->format == WAVE_FORMAT_PCM) {
            l = (int16_t)get_le16(p) / 32768.0f;
            r = w->channels == 2 ? (int16_t)get_le16(p + 2) / 32768.0f : l;
        } else {
            l = get_le_f32(p);
            r = w->channels == 2 ? get_le_f32(p + 4) : l;
        }
        stereo[2 * i] = l;
        stereo[2 * i + 1] = r;
    }
    w->played += frames;
    return frames;
}

// ---------------------------------------------------------------------------------------------
// WAV writer

static bool write_wav(FILE *f, const uint8_t *pcm, uint64_t frames)
{
    uint32_t data_bytes = (uint32_t)(frames * 2);
    uint8_t h[44];
    memcpy(h, "RIFF", 4);
    put_le32(h + 4, 36 + data_bytes);
    memcpy(h + 8, "WAVE", 4);
    memcpy(h + 12, "fmt ", 4);
    put_le32(h + 16, 16);
    put_le16(h + 20, WAVE_FORMAT_PCM);
    put_le16(h + 22, 1);
    put_le32(h + 24, DS5_SAMPLE_RATE);
    put_le32(h + 28, DS5_SAMPLE_RATE * 2);
    put_le16(h + 32, 2);
    put_le16(h + 34, 16);
    memcpy(h + 36, "data", 4);
    put_le32(h + 40, data_bytes);
    return fwrite(h, 1, sizeof h, f) == sizeof h && fwrite(pcm, 1, data_bytes, f) == data_bytes &&
           fflush(f) == 0;
}

// ---------------------------------------------------------------------------------------------
// Real-time speaker feeder

typedef uint32_t (*fill_fn)(void *ctx, float *stereo, uint32_t frames);

typedef struct {
    ds5_engine *engine;
    fill_fn fill;
    void *ctx;
    atomic_bool stop;
    atomic_bool done; // source exhausted
    pthread_t thread;
} feeder;

static void *feeder_main(void *arg)
{
    feeder *f = arg;
    float buf[FEED_CUSHION_FRAMES * 2];
    uint32_t want = FEED_CUSHION_FRAMES;
    pacer p;
    pacer_init(&p);
    while (!atomic_load(&f->stop)) {
        uint32_t n = f->fill(f->ctx, buf, want);
        if (n > 0)
            ds5_speaker_write(f->engine, buf, n);
        if (n < want) {
            atomic_store(&f->done, true);
            break;
        }
        want = FEED_CHUNK_FRAMES;
        pacer_wait(&p);
    }
    return NULL;
}

typedef struct {
    double phase;
    double step;
} tone_source;

static uint32_t tone_fill(void *ctx, float *stereo, uint32_t frames)
{
    tone_source *t = ctx;
    for (uint32_t i = 0; i < frames; i++) {
        float v = (float)(TONE_AMPLITUDE * sin(t->phase));
        stereo[2 * i] = v;
        stereo[2 * i + 1] = v;
        t->phase += t->step;
        if (t->phase >= 2.0 * M_PI)
            t->phase -= 2.0 * M_PI;
    }
    return frames;
}

// Feeds the speaker until `seconds` elapse (0 = no limit), the source ends, or an interrupt;
// prints stats once per second, then drains and stops the speaker.
static int run_playback(ds5_engine *e, fill_fn fill, void *ctx, double seconds)
{
    block_signals(true);
    ds5_status st = ds5_speaker_start(e);
    block_signals(false);
    if (st != DS5_OK) {
        report_error("speaker start failed: %s", status_name(st));
        return RC_START;
    }

    feeder f = {.engine = e, .fill = fill, .ctx = ctx};
    atomic_init(&f.stop, false);
    atomic_init(&f.done, false);
    block_signals(true);
    int err = pthread_create(&f.thread, NULL, feeder_main, &f);
    block_signals(false);
    if (err != 0) {
        report_error("cannot start feeder thread: %s", strerror(err));
        ds5_speaker_stop(e);
        return RC_FAIL;
    }

    uint64_t start = mach_absolute_time();
    uint64_t second = ns_to_abs(SECOND_NS);
    uint64_t poll = ns_to_abs(POLL_NS);
    uint64_t end = seconds > 0 ? start + ns_to_abs((uint64_t)(seconds * 1e9)) : UINT64_MAX;
    uint64_t next_stats = start + second;
    while (!g_interrupted && !atomic_load(&f.done)) {
        uint64_t now = mach_absolute_time();
        if (now >= end)
            break;
        if (now >= next_stats) {
            print_stats(e);
            next_stats += second;
        }
        mach_wait_until(min_u64(min_u64(now + poll, next_stats), end));
    }

    atomic_store(&f.stop, true);
    pthread_join(f.thread, NULL);
    mach_wait_until(mach_absolute_time() + ns_to_abs(DRAIN_NS)); // let the queued tail play out
    ds5_speaker_stop(e);
    print_stats(e);
    return RC_OK;
}

// ---------------------------------------------------------------------------------------------
// Commands

typedef enum { CMD_STATUS, CMD_TONE, CMD_PLAY, CMD_RECORD } command;

typedef struct {
    command cmd;
    double seconds;
    double hz;
    const char *path;
} options;

static void usage(void)
{
    fprintf(stderr, "usage:\n"
                    "  ds5audio status\n"
                    "  ds5audio tone [seconds=5] [hz=440]\n"
                    "  ds5audio play <file.wav>\n"
                    "  ds5audio record <seconds> <out.wav>\n");
}

static bool parse_number(const char *s, double *out)
{
    char *end;
    errno = 0;
    double v = strtod(s, &end);
    if (end == s || *end != '\0' || errno != 0 || !isfinite(v))
        return false;
    *out = v;
    return true;
}

static bool parse_seconds(const char *s, double *out)
{
    if (!parse_number(s, out) || *out <= 0 || *out > MAX_SECONDS) {
        report_error("seconds must be a number in (0, 3600], got '%s'", s);
        return false;
    }
    return true;
}

// Returns RC_OK, or RC_FAIL after printing the problem.
static int parse_args(int argc, char **argv, options *o)
{
    memset(o, 0, sizeof *o);
    if (argc < 2) {
        usage();
        return RC_FAIL;
    }
    const char *cmd = argv[1];
    if (strcmp(cmd, "status") == 0 && argc == 2) {
        o->cmd = CMD_STATUS;
    } else if (strcmp(cmd, "tone") == 0 && argc <= 4) {
        o->cmd = CMD_TONE;
        o->seconds = 5;
        o->hz = 440;
        if (argc >= 3 && !parse_seconds(argv[2], &o->seconds))
            return RC_FAIL;
        if (argc >= 4 && (!parse_number(argv[3], &o->hz) || o->hz <= 0 || o->hz >= 24000)) {
            report_error("hz must be a number in (0, 24000), got '%s'", argv[3]);
            return RC_FAIL;
        }
    } else if (strcmp(cmd, "play") == 0 && argc == 3) {
        o->cmd = CMD_PLAY;
        o->path = argv[2];
    } else if (strcmp(cmd, "record") == 0 && argc == 4) {
        o->cmd = CMD_RECORD;
        o->path = argv[3];
        if (!parse_seconds(argv[2], &o->seconds))
            return RC_FAIL;
    } else {
        usage();
        return RC_FAIL;
    }
    return RC_OK;
}

static int require_connected(bool connected)
{
    if (connected)
        return RC_OK;
    report_error("no DualSense connected over Bluetooth within 3 s");
    return RC_FAIL;
}

static int cmd_status(ds5_engine *e, bool connected)
{
    printf(connected ? "connected=yes\n" : "connected=no (no DualSense found over Bluetooth within 3 s)\n");
    for (int i = 0; i < 2; i++) {
        if (!sleep_ns(SECOND_NS))
            return RC_INTERRUPTED;
        print_stats(e);
    }
    return connected ? RC_OK : RC_FAIL;
}

static int cmd_tone(ds5_engine *e, bool connected, const options *o)
{
    if (require_connected(connected) != RC_OK)
        return RC_FAIL;
    tone_source t = {.phase = 0, .step = 2.0 * M_PI * o->hz / DS5_SAMPLE_RATE};
    printf("tone: %.1f Hz for %.1f s at amplitude %.1f\n", o->hz, o->seconds, TONE_AMPLITUDE);
    return run_playback(e, tone_fill, &t, o->seconds);
}

static int cmd_play(ds5_engine *e, bool connected, wav_reader *w)
{
    if (require_connected(connected) != RC_OK)
        return RC_FAIL;
    printf("playing %s: %.2f s, %s, %u ch, 48000 Hz\n", w->path, (double)w->frames / DS5_SAMPLE_RATE,
           wav_format_name(w), w->channels);
    int rc = run_playback(e, wav_fill, w, 0);
    printf("played %.2f s of %.2f s\n", (double)w->played / DS5_SAMPLE_RATE, (double)w->frames / DS5_SAMPLE_RATE);
    if (rc == RC_OK && w->read_error) {
        report_error("read error in %s; playback ended early", w->path);
        rc = RC_FAIL;
    }
    return rc;
}

static void print_record_summary(const ds5_stats *s)
{
    uint64_t total = s->mic_frames_received + s->mic_frames_concealed;
    double loss = total ? 100.0 * (double)s->mic_frames_concealed / (double)total : 0.0;
    printf("received=%llu concealed=%llu loss=%.1f%% (last 2 s: %.1f%%) input_reports_per_sec=%.1f\n",
           (unsigned long long)s->mic_frames_received, (unsigned long long)s->mic_frames_concealed, loss,
           s->mic_loss_ratio * 100.0, s->input_reports_per_sec);
}

static void store_samples(uint8_t *pcm, const float *mono, uint32_t frames)
{
    for (uint32_t i = 0; i < frames; i++) {
        long v = lrintf(mono[i] * 32767.0f);
        v = v > 32767 ? 32767 : v < -32768 ? -32768 : v;
        put_le16(pcm + 2 * (size_t)i, (uint16_t)(int16_t)v);
    }
}

// Polls the mic in real time until `target` frames (the requested duration) are stored, an interrupt or a
// disconnect. Zero-filled shortfall is kept so the file stays time-aligned with the capture; `audio_frames`
// counts the frames that carried received or concealed audio. Returns frames stored.
static uint64_t capture_mic(ds5_engine *e, uint8_t *pcm, uint64_t target, uint64_t *audio_frames,
                            bool *disconnected)
{
    float buf[MIC_CHUNK_FRAMES];
    uint64_t captured = 0;
    uint64_t second = ns_to_abs(SECOND_NS);
    uint64_t next_stats = mach_absolute_time() + second;
    pacer p;
    pacer_init(&p);
    while (captured < target && !g_interrupted) {
        pacer_wait(&p);
        if (!ds5_engine_connected(e)) {
            *disconnected = true;
            break;
        }
        uint32_t want = (uint32_t)min_u64(MIC_CHUNK_FRAMES, target - captured);
        *audio_frames += ds5_mic_read(e, buf, want);
        store_samples(pcm + 2 * captured, buf, want);
        captured += want;
        if (mach_absolute_time() >= next_stats) {
            print_stats(e);
            next_stats += second;
        }
    }
    return captured;
}

static int cmd_record(ds5_engine *e, bool connected, const options *o, FILE *out)
{
    if (require_connected(connected) != RC_OK)
        return RC_FAIL;
    uint64_t target = (uint64_t)llround(o->seconds * DS5_SAMPLE_RATE);
    if (target == 0)
        target = 1;
    uint8_t *pcm = malloc(target * 2);
    if (!pcm) {
        report_error("cannot allocate %llu bytes for the recording", (unsigned long long)(target * 2));
        return RC_FAIL;
    }

    block_signals(true);
    ds5_status st = ds5_mic_start(e);
    block_signals(false);
    if (st != DS5_OK) {
        free(pcm);
        if (st == DS5_ERR_EXCLUSIVE) {
            report_error("could not take exclusive access to the controller; mic not opened");
            return RC_EXCLUSIVE;
        }
        report_error("mic start failed: %s", status_name(st));
        return RC_START;
    }

    bool disconnected = false;
    uint64_t audio_frames = 0;
    uint64_t captured = capture_mic(e, pcm, target, &audio_frames, &disconnected);
    ds5_stats s;
    ds5_engine_get_stats(e, &s); // before stopping, while the mic counters are live
    ds5_mic_stop(e);

    int rc = RC_OK;
    if (disconnected) {
        report_error("controller disconnected; keeping the partial recording");
        rc = RC_FAIL;
    }
    if (!write_wav(out, pcm, captured)) {
        report_error("cannot write %s: %s", o->path, strerror(errno));
        rc = RC_FAIL;
    }
    free(pcm);
    print_record_summary(&s);
    printf("wrote %s: %.2f s captured, %.2f s carried audio\n", o->path, (double)captured / DS5_SAMPLE_RATE,
           (double)audio_frames / DS5_SAMPLE_RATE);
    return rc;
}

// ---------------------------------------------------------------------------------------------

static int run_command(ds5_engine *e, const options *o, wav_reader *w, FILE *out)
{
    bool connected = wait_for_connection(e);
    if (g_interrupted)
        return RC_INTERRUPTED;
    switch (o->cmd) {
    case CMD_STATUS: return cmd_status(e, connected);
    case CMD_TONE: return cmd_tone(e, connected, o);
    case CMD_PLAY: return cmd_play(e, connected, w);
    case CMD_RECORD: return cmd_record(e, connected, o, out);
    }
    return RC_FAIL;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IOLBF, 0);
    g_log = os_log_create("com.psgrok.DualSenseAudio", "cli");
    mach_timebase_info(&g_timebase);

    options o;
    if (parse_args(argc, argv, &o) != RC_OK)
        return RC_FAIL;

    // Validate inputs before touching the controller.
    static wav_reader wav;
    FILE *out = NULL;
    if (o.cmd == CMD_PLAY && !wav_open(&wav, o.path))
        return RC_FAIL;
    if (o.cmd == CMD_RECORD && !(out = fopen(o.path, "wb"))) {
        report_error("cannot create %s: %s", o.path, strerror(errno));
        return RC_FAIL;
    }

    install_signals();
    block_signals(true);
    ds5_engine *e = ds5_engine_create(on_presence, NULL);
    block_signals(false);
    int rc = RC_FAIL;
    if (e) {
        rc = run_command(e, &o, &wav, out);
        ds5_engine_destroy(e);
    } else {
        report_error("cannot create the audio engine");
    }

    if (wav.f)
        fclose(wav.f);
    if (out) {
        long written = ftell(out);
        if (fclose(out) != 0 && rc == RC_OK) {
            report_error("cannot write %s: %s", o.path, strerror(errno));
            rc = RC_FAIL;
        }
        if (written <= 0)
            remove(o.path); // nothing was recorded; do not leave an empty file behind
    }
    return g_interrupted ? RC_INTERRUPTED : rc;
}
