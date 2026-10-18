// DualSense Bluetooth audio engine.
//
// Threads and ownership:
//   - HID thread (own CFRunLoop): owns the IOHIDManager, the attached device and every open/close/seize
//     transition; decodes mic frames into the mic ring; runs the presence callback. Control-plane calls run
//     their device work on it through hid_call(), so API calls and (re)connect handling never interleave.
//   - Sender thread (while the speaker runs): real-time paced speaker reports fed from the speaker ring.
//   - send_lock: serializes every SetReport and guards the shared report counters, the send handle and the
//     live mic-session state that every speaker report carries.
//   - ctl_lock: serializes the blocking control API (sender thread creation/join, teardown).
//   - Audio crosses through the rings of a shared region (ds5_shm.h): the engine reads the mono speaker ring
//     and writes the mic ring. The peer side is a ds5_port: the HAL plug-in's (ds5_engine_create_shared) or
//     the engine's own (ds5_engine_create, used by ds5_speaker_write / ds5_mic_read).
#include "ds5_engine.h"

#include "ds5_codec.h"
#include "ds5_protocol.h"
#include "ds5_shm.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDDevice.h>
#include <IOKit/hid/IOHIDKeys.h>
#include <IOKit/hid/IOHIDManager.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

enum {
    MIC_OPEN_MAX_RESENDS = 4,
    INPUT_RATE_SLOTS = 512, // input report timestamps kept (> 1 s at 133/s)
    MIC_EVENT_SLOTS = 512,  // mic frame events kept (> 2 s at 100/s)
};

#define HOUSEKEEPING_PERIOD_S 0.25
#define MIC_OPEN_TIMEOUT_NS NSEC_PER_SEC
#define MIC_CLOSE_GAP_US 20000
#define ATTACH_RETRY_NS NSEC_PER_SEC
#define INPUT_RATE_WINDOW_NS NSEC_PER_SEC
#define MIC_LOSS_WINDOW_NS (2 * NSEC_PER_SEC)
#define SENDER_COMPUTATION_NS 2000000ull
#define SENDER_CONSTRAINT_NS 10000000ull
#define SENDER_MAX_LATE_TICKS 2

typedef struct {
    uint64_t t_ns;
    uint32_t received;
    uint32_t concealed;
} mic_event;

// Speaker counters logged per session at speaker stop.
typedef struct {
    uint64_t sent, late, underrun, rebuffers;
} speaker_counts;

struct ds5_engine {
    _Atomic(ds5_control_fn) control_observer;
    ds5_presence_fn presence;
    void *presence_ctx;
    pthread_mutex_t ctl_lock;

    // HID thread; everything in this block is touched only on it (after creation).
    pthread_t hid_thread;
    CFRunLoopRef hid_runloop;
    dispatch_semaphore_t hid_ready;
    bool hid_ok;
    bool hid_quit;
    CFRunLoopSourceRef keepalive;
    CFRunLoopTimerRef housekeeping;
    IOHIDManagerRef manager;
    IOHIDDeviceRef device; // attached controller (retained)
    IOReturn last_open_error;
    uint64_t next_scan_ns;
    bool seized;
    uint8_t *input_buf;
    ds5_mic_decoder mic_dec;
    bool mic_decoding; // our mic session is open: decode mic frames
    bool mic_frame_seen;
    bool mic_gave_up;
    uint32_t mic_open_resends;
    uint64_t mic_open_sent_ns;

    // Output path, guarded by send_lock.
    pthread_mutex_t send_lock;
    IOHIDDeviceRef send_dev; // NULL while disconnected
    ds5_counters counters;
    bool mic_open; // live mic session state carried by every speaker report

    // Shared region and its rings (engine side: speaker reader, mic writer).
    void *shm;
    size_t shm_size;
    bool owns_shm;  // ds5_engine_create: the engine allocated the region and owns `port`
    ds5_port *port; // peer side for ds5_speaker_write / ds5_mic_read; NULL for a shared engine
    ds5_ring spk_ring;
    ds5_ring mic_ring;

    // Speaker.
    pthread_t sender;
    bool sender_started; // ctl_lock
    atomic_bool sender_run;
    OpusEncoder *encoder; // used by the sender thread while it runs
    _Atomic float gain;   // ds5_speaker_write only
    atomic_bool mute;
    speaker_counts spk_session_base; // ctl_lock: counters when the running speaker session started

    // Public state and counters.
    atomic_bool connected;
    atomic_bool speaker_running;
    atomic_bool mic_running;
    atomic_bool exclusive;
    _Atomic uint64_t spk_sent, spk_errors, spk_late, spk_underrun, spk_rebuffers;
    _Atomic uint64_t mic_received, mic_concealed;

    // Sliding windows, guarded by stats_lock.
    pthread_mutex_t stats_lock;
    uint64_t input_ts[INPUT_RATE_SLOTS];
    uint32_t input_head, input_count;
    mic_event mic_events[MIC_EVENT_SLOTS];
    uint32_t mic_event_head, mic_event_count;
};

static os_log_t g_log;
static mach_timebase_info_data_t g_timebase;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;

static void engine_once(void) {
    g_log = os_log_create("com.psgrok.DualSenseAudio", "engine");
    mach_timebase_info(&g_timebase);
}

static uint64_t now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static uint64_t ns_to_abs(uint64_t ns) {
    return (uint64_t)((__uint128_t)ns * g_timebase.denom / g_timebase.numer);
}

// Offset of speaker tick k from the schedule anchor: k * 1024/48000 s in mach absolute units, computed
// exactly so the schedule never accumulates rounding drift.
static uint64_t tick_offset_abs(uint64_t k) {
    __uint128_t num = (__uint128_t)k * DS5_SPEAKER_FRAMES_PER_REPORT * NSEC_PER_SEC * g_timebase.denom;
    return (uint64_t)(num / ((__uint128_t)DS5_SAMPLE_RATE * g_timebase.numer));
}

// MARK: - Stats windows

static void stats_note_input(ds5_engine *e, uint64_t t) {
    pthread_mutex_lock(&e->stats_lock);
    e->input_ts[e->input_head] = t;
    e->input_head = (e->input_head + 1) % INPUT_RATE_SLOTS;
    if (e->input_count < INPUT_RATE_SLOTS)
        e->input_count++;
    pthread_mutex_unlock(&e->stats_lock);
}

static void stats_note_mic(ds5_engine *e, uint64_t t, ds5_mic_result r) {
    pthread_mutex_lock(&e->stats_lock);
    e->mic_events[e->mic_event_head] = (mic_event){t, r.received, r.concealed};
    e->mic_event_head = (e->mic_event_head + 1) % MIC_EVENT_SLOTS;
    if (e->mic_event_count < MIC_EVENT_SLOTS)
        e->mic_event_count++;
    pthread_mutex_unlock(&e->stats_lock);
}

static void stats_reset_mic_window(ds5_engine *e) {
    pthread_mutex_lock(&e->stats_lock);
    e->mic_event_count = 0;
    pthread_mutex_unlock(&e->stats_lock);
}

// MARK: - Output reports (any thread)

static IOReturn send_config(ds5_engine *e) {
    uint8_t rep[DS5_CONFIG_REPORT_LEN];
    IOReturn r = kIOReturnNotAttached;
    pthread_mutex_lock(&e->send_lock);
    if (e->send_dev) {
        ds5_build_config(rep, &e->counters);
        r = IOHIDDeviceSetReport(e->send_dev, kIOHIDReportTypeOutput, DS5_CONFIG_REPORT_ID, rep, sizeof rep);
    }
    pthread_mutex_unlock(&e->send_lock);
    if (r != kIOReturnSuccess)
        os_log_error(g_log, "config report failed: 0x%08x", r);
    return r;
}

// Opening marks the session open only if the report was sent; closing marks it closed regardless, so every
// later speaker report says "closed" too.
static IOReturn send_mic_toggle(ds5_engine *e, bool open) {
    uint8_t rep[DS5_MIC_TOGGLE_REPORT_LEN];
    IOReturn r = kIOReturnNotAttached;
    pthread_mutex_lock(&e->send_lock);
    if (e->send_dev) {
        ds5_build_mic_toggle(rep, &e->counters, open);
        r = IOHIDDeviceSetReport(e->send_dev, kIOHIDReportTypeOutput, DS5_MIC_TOGGLE_REPORT_ID, rep, sizeof rep);
    }
    if (!open)
        e->mic_open = false;
    else if (r == kIOReturnSuccess)
        e->mic_open = true;
    pthread_mutex_unlock(&e->send_lock);
    if (r != kIOReturnSuccess)
        os_log_error(g_log, "mic %{public}s report failed: 0x%08x", open ? "open" : "close", r);
    return r;
}

// Returns false if no device is attached (nothing sent).
static bool send_speaker_report(ds5_engine *e, const uint8_t *frame1, const uint8_t *frame2, IOReturn *result) {
    uint8_t rep[DS5_SPEAKER_REPORT_LEN];
    pthread_mutex_lock(&e->send_lock);
    if (!e->send_dev) {
        pthread_mutex_unlock(&e->send_lock);
        return false;
    }
    ds5_build_speaker(rep, &e->counters, e->mic_open, frame1, frame2);
    *result = IOHIDDeviceSetReport(e->send_dev, kIOHIDReportTypeOutput, DS5_SPEAKER_REPORT_ID, rep, sizeof rep);
    pthread_mutex_unlock(&e->send_lock);
    return true;
}

// MARK: - HID thread: device transitions

static void mic_sink(void *ctx, const float *pcm, uint32_t frames) {
    ds5_engine *e = ctx;
    ds5_ring_write(&e->mic_ring, pcm, frames);
}

static void on_input_report(void *ctx, IOReturn result, void *sender, IOHIDReportType type, uint32_t report_id,
                            uint8_t *report, CFIndex len) {
    ds5_engine *e = ctx;
    if (result != kIOReturnSuccess || !report || len <= 0)
        return;
    uint64_t t = now_ns();
    stats_note_input(e, t);
    // Audio bytes must never be interpreted as controller buttons.
    if (len == 78 && report_id == 0x31 && report[0] == 0x31 && (report[1] & 0x0f) == 1) {
        uint8_t prefix = 0xa1;
        uint32_t crc = ds5_crc32(ds5_crc32(0, &prefix, 1), report, 74);
        uint32_t expected = (uint32_t)report[74] | (uint32_t)report[75] << 8 |
                            (uint32_t)report[76] << 16 | (uint32_t)report[77] << 24;
        ds5_control_fn observer = atomic_load(&e->control_observer);
        if (observer && crc == expected) observer(report, 78, t);
    }
    if (!e->mic_decoding || !ds5_is_mic_report(report, (size_t)len))
        return;
    ds5_mic_result r = ds5_mic_decoder_push(&e->mic_dec, report, (size_t)len, mic_sink, e);
    e->mic_frame_seen = true;
    atomic_fetch_add_explicit(&e->mic_received, r.received, memory_order_relaxed);
    atomic_fetch_add_explicit(&e->mic_concealed, r.concealed, memory_order_relaxed);
    stats_note_mic(e, t, r);
}

static void register_input(ds5_engine *e, IOHIDDeviceRef dev) {
    IOHIDDeviceRegisterInputReportCallback(dev, e->input_buf, DS5_INPUT_REPORT_BUFFER, on_input_report, e);
}

// Shared -> exclusive. The send lock keeps speaker reports off the device while it is reopened.
static bool seize_device(ds5_engine *e) {
    IOHIDDeviceRef dev = e->device;
    pthread_mutex_lock(&e->send_lock);
    IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeSeizeDevice);
    IOReturn shared = kIOReturnSuccess;
    if (r != kIOReturnSuccess) {
        // IOKit counts an open refused because another client holds the seize as open; undo it first.
        if (r == kIOReturnExclusiveAccess)
            IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
        shared = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    }
    register_input(e, dev);
    pthread_mutex_unlock(&e->send_lock);
    e->seized = r == kIOReturnSuccess;
    atomic_store(&e->exclusive, e->seized);
    if (!e->seized)
        os_log_error(g_log, "exclusive access failed: 0x%08x (shared reopen 0x%08x); mic not opened", r, shared);
    return e->seized;
}

// Exclusive -> shared.
static void release_device(ds5_engine *e) {
    if (!e->seized || !e->device)
        return;
    IOHIDDeviceRef dev = e->device;
    pthread_mutex_lock(&e->send_lock);
    IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    register_input(e, dev);
    pthread_mutex_unlock(&e->send_lock);
    e->seized = false;
    atomic_store(&e->exclusive, false);
    if (r != kIOReturnSuccess)
        os_log_error(g_log, "shared reopen after exclusive access failed: 0x%08x", r);
}

// Seize -> config (A) -> mic open (B). The session counts as open only if the open report was sent.
static ds5_status mic_open_sequence(ds5_engine *e) {
    if (!seize_device(e))
        return DS5_ERR_EXCLUSIVE;
    ds5_mic_decoder_reset(&e->mic_dec);
    ds5_shm_set_mic_session(e->shm, ds5_ring_write_pos(&e->mic_ring));
    stats_reset_mic_window(e);
    if (send_config(e) != kIOReturnSuccess) {
        release_device(e);
        return DS5_ERR_IO;
    }
    if (send_mic_toggle(e, true) != kIOReturnSuccess) {
        send_mic_toggle(e, false); // in case the controller acted on it anyway
        release_device(e);
        return DS5_ERR_IO;
    }
    e->mic_decoding = true;
    e->mic_frame_seen = false;
    e->mic_gave_up = false;
    e->mic_open_resends = 0;
    e->mic_open_sent_ns = now_ns();
    os_log_info(g_log, "mic session open (exclusive access held)");
    return DS5_OK;
}

// Mic close (B) twice ~20 ms apart -> release the seize -> back to shared.
static void mic_close_sequence(ds5_engine *e) {
    e->mic_decoding = false;
    if (!e->device)
        return;
    send_mic_toggle(e, false);
    usleep(MIC_CLOSE_GAP_US);
    send_mic_toggle(e, false);
    release_device(e);
    os_log_info(g_log, "mic session closed, exclusive access released");
}

static bool attach_device(ds5_engine *e, IOHIDDeviceRef dev) {
    IOReturn r = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
    if (r != kIOReturnSuccess) {
        // Another client holds the seize: IOKit counts the open anyway; undo it and retry later.
        if (r == kIOReturnExclusiveAccess)
            IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
        if (r != e->last_open_error)
            os_log_error(g_log, "DualSense open failed: 0x%08x%{public}s", r,
                         r == kIOReturnExclusiveAccess ? " (held exclusively by another client); retrying" : "");
        e->last_open_error = r;
        e->next_scan_ns = now_ns() + ATTACH_RETRY_NS;
        return false;
    }
    e->last_open_error = kIOReturnSuccess;
    e->device = (IOHIDDeviceRef)CFRetain(dev);
    e->seized = false;
    register_input(e, dev);

    // Calibration feature read: harmless, and it switches a Bluetooth DualSense to full 0x31 reports.
    uint8_t feature[DS5_FEATURE_CALIBRATION_LEN] = {DS5_FEATURE_CALIBRATION_ID};
    CFIndex feature_len = sizeof feature;
    r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, DS5_FEATURE_CALIBRATION_ID, feature, &feature_len);
    if (r != kIOReturnSuccess)
        os_log_error(g_log, "feature 0x05 read failed: 0x%08x", r);

    pthread_mutex_lock(&e->send_lock);
    e->send_dev = dev;
    e->mic_open = false;
    pthread_mutex_unlock(&e->send_lock);

    // Scrub: close a mic session a crashed process may have left streaming.
    send_mic_toggle(e, false);

    // Resume sessions that were running across a disconnect. The mic sequence sends the config report
    // itself; the speaker needs it on its own if the mic is not running or could not be reopened.
    ds5_status mic = DS5_ERR_NO_DEVICE;
    if (atomic_load(&e->mic_running)) {
        mic = mic_open_sequence(e);
        if (mic != DS5_OK)
            os_log_error(g_log, "mic resume after reconnect failed: %d", mic);
    }
    if (atomic_load(&e->speaker_running) && mic != DS5_OK)
        send_config(e);

    atomic_store(&e->connected, true);
    os_log_info(g_log, "DualSense connected");
    if (e->presence)
        e->presence(e->presence_ctx, true);
    return true;
}

static void detach_device(ds5_engine *e, bool notify) {
    IOHIDDeviceRef dev = e->device;
    if (!dev)
        return;
    atomic_store(&e->connected, false);
    pthread_mutex_lock(&e->send_lock); // waits out an in-flight speaker report
    e->send_dev = NULL;
    e->mic_open = false;
    pthread_mutex_unlock(&e->send_lock);
    e->mic_decoding = false;
    e->seized = false;
    atomic_store(&e->exclusive, false);

    IOHIDDeviceRegisterInputReportCallback(dev, e->input_buf, DS5_INPUT_REPORT_BUFFER, NULL, e);
    IOHIDDeviceUnscheduleFromRunLoop(dev, e->hid_runloop, kCFRunLoopDefaultMode);
    IOHIDDeviceClose(dev, kIOHIDOptionsTypeNone);
    CFRelease(dev);
    e->device = NULL;
    e->next_scan_ns = now_ns() + ATTACH_RETRY_NS;

    if (notify) {
        os_log_info(g_log, "DualSense disconnected");
        if (e->presence)
            e->presence(e->presence_ctx, false);
    }
}

// Attaches the first matching controller that opens.
static void attach_any(ds5_engine *e) {
    if (e->device || !e->manager)
        return;
    e->next_scan_ns = now_ns() + ATTACH_RETRY_NS;
    CFSetRef set = IOHIDManagerCopyDevices(e->manager);
    if (!set)
        return;
    CFIndex n = CFSetGetCount(set);
    if (n > 0) {
        const void **devs = calloc((size_t)n, sizeof *devs);
        if (devs) {
            CFSetGetValues(set, devs);
            for (CFIndex i = 0; i < n && !e->device; i++)
                attach_device(e, (IOHIDDeviceRef)devs[i]);
            free(devs);
        }
    }
    CFRelease(set);
}

static void on_device_matched(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    ds5_engine *e = ctx;
    if (e->hid_quit || e->device)
        return; // one controller at a time; others are picked up if the attached one goes away
    attach_device(e, dev);
}

static void on_device_removed(void *ctx, IOReturn result, void *sender, IOHIDDeviceRef dev) {
    ds5_engine *e = ctx;
    if (dev == e->device)
        detach_device(e, true);
}

static void on_housekeeping(CFRunLoopTimerRef timer, void *info) {
    ds5_engine *e = info;
    uint64_t t = now_ns();
    if (!e->device) {
        if (t >= e->next_scan_ns)
            attach_any(e);
        return;
    }
    if (!e->mic_decoding || e->mic_frame_seen || t - e->mic_open_sent_ns < MIC_OPEN_TIMEOUT_NS)
        return;
    if (e->mic_open_resends < MIC_OPEN_MAX_RESENDS) {
        e->mic_open_resends++;
        os_log_info(g_log, "no mic frame within 1 s; resending mic open (%u/%u)", e->mic_open_resends,
                    (unsigned)MIC_OPEN_MAX_RESENDS);
        send_mic_toggle(e, true);
        e->mic_open_sent_ns = t;
    } else if (!e->mic_gave_up) {
        e->mic_gave_up = true;
        os_log_error(g_log, "no mic frames after %u open resends", (unsigned)MIC_OPEN_MAX_RESENDS);
    }
}

static void keepalive_perform(void *info) {
}

static bool manager_start(ds5_engine *e) {
    e->manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    if (!e->manager)
        return false;
    CFMutableDictionaryRef match = CFDictionaryCreateMutable(kCFAllocatorDefault, 3, &kCFTypeDictionaryKeyCallBacks,
                                                             &kCFTypeDictionaryValueCallBacks);
    if (!match)
        return false;
    int vid = DS5_VENDOR_ID, pid = DS5_PRODUCT_ID;
    CFNumberRef vid_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vid);
    CFNumberRef pid_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &pid);
    CFDictionarySetValue(match, CFSTR(kIOHIDVendorIDKey), vid_num);
    CFDictionarySetValue(match, CFSTR(kIOHIDProductIDKey), pid_num);
    CFDictionarySetValue(match, CFSTR(kIOHIDTransportKey), CFSTR(kIOHIDTransportBluetoothValue));
    CFRelease(vid_num);
    CFRelease(pid_num);
    // The manager is never opened: the engine opens, seizes and closes the device itself.
    IOHIDManagerSetDeviceMatching(e->manager, match);
    CFRelease(match);
    IOHIDManagerRegisterDeviceMatchingCallback(e->manager, on_device_matched, e);
    IOHIDManagerRegisterDeviceRemovalCallback(e->manager, on_device_removed, e);
    IOHIDManagerScheduleWithRunLoop(e->manager, e->hid_runloop, kCFRunLoopDefaultMode);
    return true;
}

static int op_shutdown(ds5_engine *e) {
    if (e->housekeeping) {
        CFRunLoopTimerInvalidate(e->housekeeping);
        CFRelease(e->housekeeping);
        e->housekeeping = NULL;
    }
    detach_device(e, false);
    if (e->manager) {
        IOHIDManagerRegisterDeviceMatchingCallback(e->manager, NULL, NULL);
        IOHIDManagerRegisterDeviceRemovalCallback(e->manager, NULL, NULL);
        IOHIDManagerUnscheduleFromRunLoop(e->manager, e->hid_runloop, kCFRunLoopDefaultMode);
        CFRelease(e->manager);
        e->manager = NULL;
    }
    if (e->keepalive) {
        CFRunLoopSourceInvalidate(e->keepalive);
        CFRelease(e->keepalive);
        e->keepalive = NULL;
    }
    e->hid_quit = true;
    CFRunLoopStop(e->hid_runloop);
    return 0;
}

static void *hid_thread_main(void *arg) {
    ds5_engine *e = arg;
    pthread_setname_np("com.psgrok.ds5.hid");
    e->hid_runloop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());

    CFRunLoopSourceContext source_ctx = {.info = e, .perform = keepalive_perform};
    e->keepalive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &source_ctx);
    CFRunLoopTimerContext timer_ctx = {.info = e};
    e->housekeeping = CFRunLoopTimerCreate(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + HOUSEKEEPING_PERIOD_S,
                                           HOUSEKEEPING_PERIOD_S, 0, 0, on_housekeeping, &timer_ctx);
    e->hid_ok = e->keepalive && e->housekeeping;
    if (e->hid_ok) {
        CFRunLoopAddSource(e->hid_runloop, e->keepalive, kCFRunLoopDefaultMode);
        CFRunLoopAddTimer(e->hid_runloop, e->housekeeping, kCFRunLoopDefaultMode);
        e->hid_ok = manager_start(e);
    }
    if (!e->hid_ok) {
        op_shutdown(e);
        dispatch_semaphore_signal(e->hid_ready);
        return NULL;
    }
    // Attach an already-connected controller before ds5_engine_create returns.
    attach_any(e);
    dispatch_semaphore_signal(e->hid_ready);

    while (!e->hid_quit)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 3600.0, false);
    return NULL;
}

// Runs fn on the HID thread and waits for its result.
static int hid_call(ds5_engine *e, int (*fn)(ds5_engine *)) {
    if (pthread_equal(pthread_self(), e->hid_thread))
        return fn(e);
    __block int result = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    CFRunLoopPerformBlock(e->hid_runloop, kCFRunLoopDefaultMode, ^{
      result = fn(e);
      dispatch_semaphore_signal(done);
    });
    CFRunLoopWakeUp(e->hid_runloop);
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    dispatch_release(done);
    return result;
}

// MARK: - Speaker

static void make_sender_realtime(void) {
    thread_time_constraint_policy_data_t policy = {
        .period = (uint32_t)tick_offset_abs(1),
        .computation = (uint32_t)ns_to_abs(SENDER_COMPUTATION_NS),
        .constraint = (uint32_t)ns_to_abs(SENDER_CONSTRAINT_NS),
        .preemptible = TRUE,
    };
    kern_return_t kr = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                                         (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    if (kr != KERN_SUCCESS)
        os_log_error(g_log, "speaker thread: time-constraint policy failed (%d); staying at user-interactive QoS", kr);
}

static void *sender_main(void *arg) {
    ds5_engine *e = arg;
    pthread_setname_np("com.psgrok.ds5.speaker");
    make_sender_realtime();

    float mono[DS5_SPEAKER_FRAMES_PER_REPORT];
    uint8_t frame1[DS5_SPEAKER_OPUS_BYTES], frame2[DS5_SPEAKER_OPUS_BYTES];
    const uint64_t period = tick_offset_abs(1);
    bool send_failing = false, encode_failing = false;

    // The first report goes out one period after start. Reports stay silent, consuming nothing, until the ring
    // holds DS5_SPEAKER_PREBUFFER_FRAMES, and again after every underrun (ds5_speaker_tick_decide).
    bool primed = false;
    uint64_t anchor = mach_absolute_time();
    uint64_t k = 0;
    while (atomic_load_explicit(&e->sender_run, memory_order_acquire)) {
        uint64_t due = anchor + tick_offset_abs(++k);
        uint64_t now = mach_absolute_time();
        if (now > due) {
            atomic_fetch_add_explicit(&e->spk_late, 1, memory_order_relaxed);
            if (now - due > SENDER_MAX_LATE_TICKS * period) {
                anchor = now; // re-anchor instead of bursting to catch up
                k = 0;
            }
        } else {
            mach_wait_until(due);
        }
        if (!atomic_load_explicit(&e->sender_run, memory_order_acquire))
            break;

        ds5_speaker_tick tick = ds5_speaker_tick_decide(primed, ds5_ring_available(&e->spk_ring));
        uint32_t got = tick.read ? ds5_ring_read(&e->spk_ring, mono, tick.read) : 0;
        if (got < DS5_SPEAKER_FRAMES_PER_REPORT) {
            memset(mono + got, 0, (DS5_SPEAKER_FRAMES_PER_REPORT - got) * sizeof *mono);
            if (tick.play)
                atomic_fetch_add_explicit(&e->spk_underrun, DS5_SPEAKER_FRAMES_PER_REPORT - got, memory_order_relaxed);
        }
        if (tick.play && !tick.primed)
            atomic_fetch_add_explicit(&e->spk_rebuffers, 1, memory_order_relaxed);
        primed = tick.primed;
        bool encoded = ds5_speaker_encode_report(e->encoder, mono, frame1, frame2);
        if (encoded == encode_failing) {
            encode_failing = !encoded;
            if (encode_failing)
                os_log_error(g_log, "speaker Opus frame did not encode to %d bytes", DS5_SPEAKER_OPUS_BYTES);
        }
        if (!atomic_load_explicit(&e->connected, memory_order_acquire))
            continue;
        IOReturn r;
        if (!send_speaker_report(e, frame1, frame2, &r))
            continue;
        if (r == kIOReturnSuccess) {
            atomic_fetch_add_explicit(&e->spk_sent, 1, memory_order_relaxed);
        } else {
            atomic_fetch_add_explicit(&e->spk_errors, 1, memory_order_relaxed);
            if (!send_failing)
                os_log_error(g_log, "speaker report failed: 0x%08x", r);
        }
        send_failing = r != kIOReturnSuccess;
    }
    return NULL;
}

static int op_speaker_prepare(ds5_engine *e) {
    if (!e->device)
        return DS5_ERR_NO_DEVICE;
    if (send_config(e) != kIOReturnSuccess)
        return DS5_ERR_IO;
    atomic_store(&e->speaker_running, true);
    return DS5_OK;
}

static speaker_counts speaker_counts_now(ds5_engine *e) {
    return (speaker_counts){
        .sent = atomic_load_explicit(&e->spk_sent, memory_order_relaxed),
        .late = atomic_load_explicit(&e->spk_late, memory_order_relaxed),
        .underrun = atomic_load_explicit(&e->spk_underrun, memory_order_relaxed),
        .rebuffers = atomic_load_explicit(&e->spk_rebuffers, memory_order_relaxed),
    };
}

ds5_status ds5_speaker_start(ds5_engine *e) {
    if (!e)
        return DS5_ERR_NO_DEVICE;
    pthread_mutex_lock(&e->ctl_lock);
    ds5_status s = DS5_OK;
    if (!e->sender_started) {
        s = (ds5_status)hid_call(e, op_speaker_prepare);
        if (s == DS5_OK) {
            ds5_speaker_encoder_reset(e->encoder);
            // No sender runs now, so this thread may act as the ring's reader: audio written before this
            // start belongs to an earlier stream.
            ds5_ring_skip_to(&e->spk_ring, ds5_ring_write_pos(&e->spk_ring));
            e->spk_session_base = speaker_counts_now(e);
            atomic_store(&e->sender_run, true);
            pthread_attr_t attr;
            pthread_attr_init(&attr);
            pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
            int rc = pthread_create(&e->sender, &attr, sender_main, e);
            pthread_attr_destroy(&attr);
            if (rc == 0) {
                e->sender_started = true;
                os_log_info(g_log, "speaker started");
            } else {
                atomic_store(&e->sender_run, false);
                atomic_store(&e->speaker_running, false);
                os_log_error(g_log, "speaker thread creation failed: %d", rc);
                s = DS5_ERR_IO;
            }
        }
    }
    pthread_mutex_unlock(&e->ctl_lock);
    return s;
}

void ds5_speaker_stop(ds5_engine *e) {
    if (!e)
        return;
    pthread_mutex_lock(&e->ctl_lock);
    if (e->sender_started) {
        atomic_store(&e->sender_run, false);
        pthread_join(e->sender, NULL);
        e->sender_started = false;
        speaker_counts end = speaker_counts_now(e), base = e->spk_session_base;
        os_log_info(g_log,
                    "speaker stopped: session sent %llu reports, %llu late ticks, %llu underrun frames, %llu rebuffers",
                    end.sent - base.sent, end.late - base.late, end.underrun - base.underrun,
                    end.rebuffers - base.rebuffers);
    }
    atomic_store(&e->speaker_running, false);
    pthread_mutex_unlock(&e->ctl_lock);
}

void ds5_speaker_write(ds5_engine *e, const float *stereo, uint32_t frames) {
    if (!e || !e->port)
        return;
    ds5_port_speaker_write(e->port, stereo, frames, atomic_load_explicit(&e->gain, memory_order_relaxed),
                           atomic_load_explicit(&e->mute, memory_order_relaxed));
}

void ds5_speaker_set_gain(ds5_engine *e, float linear) {
    if (e && isfinite(linear))
        atomic_store_explicit(&e->gain, linear, memory_order_relaxed);
}

void ds5_speaker_set_mute(ds5_engine *e, bool mute) {
    if (e)
        atomic_store_explicit(&e->mute, mute, memory_order_relaxed);
}

// MARK: - Mic

static int op_mic_start(ds5_engine *e) {
    if (atomic_load(&e->mic_running))
        return DS5_OK;
    if (!e->device)
        return DS5_ERR_NO_DEVICE;
    ds5_status s = mic_open_sequence(e);
    if (s == DS5_OK)
        atomic_store(&e->mic_running, true);
    return s;
}

static int op_mic_stop(ds5_engine *e) {
    if (!atomic_load(&e->mic_running))
        return 0;
    atomic_store(&e->mic_running, false);
    mic_close_sequence(e);
    return 0;
}

ds5_status ds5_mic_start(ds5_engine *e) {
    if (!e)
        return DS5_ERR_NO_DEVICE;
    pthread_mutex_lock(&e->ctl_lock);
    ds5_status s = (ds5_status)hid_call(e, op_mic_start);
    pthread_mutex_unlock(&e->ctl_lock);
    return s;
}

void ds5_mic_stop(ds5_engine *e) {
    if (!e)
        return;
    pthread_mutex_lock(&e->ctl_lock);
    hid_call(e, op_mic_stop);
    pthread_mutex_unlock(&e->ctl_lock);
}

uint32_t ds5_mic_read(ds5_engine *e, float *mono, uint32_t frames) {
    return ds5_port_mic_read(e ? e->port : NULL, mono, frames);
}

// MARK: - Lifecycle and stats

static void engine_free(ds5_engine *e) {
    if (e->hid_runloop)
        CFRelease(e->hid_runloop);
    if (e->hid_ready)
        dispatch_release(e->hid_ready);
    if (e->encoder)
        opus_encoder_destroy(e->encoder);
    ds5_mic_decoder_free(&e->mic_dec);
    free(e->input_buf);
    ds5_port_detach(e->port);
    if (e->owns_shm)
        munmap(e->shm, e->shm_size);
    pthread_mutex_destroy(&e->ctl_lock);
    pthread_mutex_destroy(&e->send_lock);
    pthread_mutex_destroy(&e->stats_lock);
    free(e);
}

// Takes ownership of the region when owns_shm (it is unmapped on failure too).
static ds5_engine *engine_create(ds5_presence_fn presence, void *ctx, void *shm, size_t shm_size, bool owns_shm) {
    pthread_once(&g_once, engine_once);
    ds5_engine *e = calloc(1, sizeof *e);
    if (!e) {
        if (owns_shm)
            munmap(shm, shm_size);
        return NULL;
    }
    e->presence = presence;
    e->presence_ctx = ctx;
    e->shm = shm;
    e->shm_size = shm_size;
    e->owns_shm = owns_shm;
    pthread_mutex_init(&e->ctl_lock, NULL);
    pthread_mutex_init(&e->stats_lock, NULL);
    pthread_mutexattr_t attr;
    pthread_mutexattr_init(&attr);
    pthread_mutexattr_setprotocol(&attr, PTHREAD_PRIO_INHERIT); // shared with the real-time sender
    pthread_mutex_init(&e->send_lock, &attr);
    pthread_mutexattr_destroy(&attr);
    atomic_init(&e->control_observer, NULL);
    atomic_init(&e->gain, 1.0f);
    atomic_init(&e->mute, false);
    atomic_init(&e->sender_run, false);
    atomic_init(&e->connected, false);
    atomic_init(&e->speaker_running, false);
    atomic_init(&e->mic_running, false);
    atomic_init(&e->exclusive, false);
    atomic_init(&e->spk_sent, 0);
    atomic_init(&e->spk_errors, 0);
    atomic_init(&e->spk_late, 0);
    atomic_init(&e->spk_underrun, 0);
    atomic_init(&e->spk_rebuffers, 0);
    atomic_init(&e->mic_received, 0);
    atomic_init(&e->mic_concealed, 0);
    e->last_open_error = kIOReturnSuccess;
    ds5_shm_speaker_view(shm, &e->spk_ring);
    ds5_shm_mic_view(shm, &e->mic_ring);

    e->input_buf = calloc(1, DS5_INPUT_REPORT_BUFFER);
    e->encoder = ds5_speaker_encoder_create();
    e->hid_ready = dispatch_semaphore_create(0);
    bool ok = e->input_buf && e->encoder && e->hid_ready && ds5_mic_decoder_init(&e->mic_dec);
    if (ok && owns_shm)
        ok = (e->port = ds5_port_attach(shm, shm_size)) != NULL;
    if (!ok) {
        os_log_error(g_log, "engine allocation failed");
        engine_free(e);
        return NULL;
    }

    pthread_attr_t tattr;
    pthread_attr_init(&tattr);
    pthread_attr_set_qos_class_np(&tattr, QOS_CLASS_USER_INTERACTIVE, 0);
    int rc = pthread_create(&e->hid_thread, &tattr, hid_thread_main, e);
    pthread_attr_destroy(&tattr);
    if (rc != 0) {
        os_log_error(g_log, "HID thread creation failed: %d", rc);
        engine_free(e);
        return NULL;
    }
    dispatch_semaphore_wait(e->hid_ready, DISPATCH_TIME_FOREVER);
    if (!e->hid_ok) {
        os_log_error(g_log, "HID manager setup failed");
        pthread_join(e->hid_thread, NULL);
        engine_free(e);
        return NULL;
    }
    return e;
}

ds5_engine *ds5_engine_create(ds5_presence_fn presence, void *ctx) {
    pthread_once(&g_once, engine_once);
    size_t size = ds5_shm_size();
    void *shm = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (shm == MAP_FAILED) {
        os_log_error(g_log, "audio region allocation failed");
        return NULL;
    }
    if (!ds5_shm_format(shm, size)) {
        munmap(shm, size);
        return NULL;
    }
    return engine_create(presence, ctx, shm, size, true);
}

ds5_engine *ds5_engine_create_shared(ds5_presence_fn presence, void *ctx, void *shm, size_t size) {
    pthread_once(&g_once, engine_once);
    if (!ds5_shm_check(shm, size)) {
        os_log_error(g_log, "shared audio region is not formatted");
        return NULL;
    }
    return engine_create(presence, ctx, shm, size, false);
}

void ds5_engine_destroy(ds5_engine *e) {
    if (!e)
        return;
    ds5_mic_stop(e);
    ds5_speaker_stop(e);
    pthread_mutex_lock(&e->ctl_lock);
    hid_call(e, op_shutdown);
    pthread_join(e->hid_thread, NULL);
    pthread_mutex_unlock(&e->ctl_lock);
    engine_free(e);
}

bool ds5_engine_connected(ds5_engine *e) {
    return e && atomic_load(&e->connected);
}

void ds5_engine_get_stats(ds5_engine *e, ds5_stats *out) {
    if (!out)
        return;
    memset(out, 0, sizeof *out);
    if (!e)
        return;
    out->connected = atomic_load(&e->connected);
    out->speaker_running = atomic_load(&e->speaker_running);
    out->mic_running = atomic_load(&e->mic_running);
    out->exclusive = atomic_load(&e->exclusive);
    out->speaker_reports_sent = atomic_load_explicit(&e->spk_sent, memory_order_relaxed);
    out->speaker_send_errors = atomic_load_explicit(&e->spk_errors, memory_order_relaxed);
    out->speaker_late_ticks = atomic_load_explicit(&e->spk_late, memory_order_relaxed);
    out->speaker_underrun_frames = atomic_load_explicit(&e->spk_underrun, memory_order_relaxed);
    out->mic_frames_received = atomic_load_explicit(&e->mic_received, memory_order_relaxed);
    out->mic_frames_concealed = atomic_load_explicit(&e->mic_concealed, memory_order_relaxed);

    uint64_t t = now_ns();
    pthread_mutex_lock(&e->stats_lock);
    uint32_t reports = 0;
    for (uint32_t i = 0; i < e->input_count; i++) {
        uint64_t ts = e->input_ts[(e->input_head + INPUT_RATE_SLOTS - 1 - i) % INPUT_RATE_SLOTS];
        if (ts + INPUT_RATE_WINDOW_NS < t)
            break;
        reports++;
    }
    out->input_reports_per_sec = reports * ((double)NSEC_PER_SEC / INPUT_RATE_WINDOW_NS);

    // Loss over the last ~2 s of mic activity: the window ends at the newest mic event, not at "now".
    uint64_t received = 0, concealed = 0;
    if (e->mic_event_count > 0) {
        uint64_t newest = e->mic_events[(e->mic_event_head + MIC_EVENT_SLOTS - 1) % MIC_EVENT_SLOTS].t_ns;
        for (uint32_t i = 0; i < e->mic_event_count; i++) {
            const mic_event *ev = &e->mic_events[(e->mic_event_head + MIC_EVENT_SLOTS - 1 - i) % MIC_EVENT_SLOTS];
            if (ev->t_ns + MIC_LOSS_WINDOW_NS < newest)
                break;
            received += ev->received;
            concealed += ev->concealed;
        }
    }
    pthread_mutex_unlock(&e->stats_lock);
    if (received + concealed > 0)
        out->mic_loss_ratio = (double)concealed / (double)(received + concealed);
}

void ds5_engine_set_control_observer(ds5_engine *e, ds5_control_fn observer) {
    atomic_store(&e->control_observer, observer);
}
