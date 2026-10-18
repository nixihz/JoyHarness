// DualSenseAudio: Core Audio HAL plug-in (AudioServerPlugIn) that publishes a Bluetooth DualSense's
// speaker as an output device and its microphone as an input device.
//
// The plug-in runs as _coreaudiod in coreaudiod's sandboxed driver host, which may not open HID devices.
// The root helper daemon ds5audiod owns the controller, and this plug-in is its client (see ds5_shared.h):
//   - control over XPC: hello, presence events, speaker/mic start and stop;
//   - audio through the shared-memory region from the hello reply, accessed with a ds5_port.
//
// Objects (fixed IDs). Both devices are owned by the plug-in and are published only while the daemon
// reports a connected controller:
//   1  plug-in
//   2  "DualSense Speaker"     3 output stream (2 ch float32), 4 volume control, 5 mute control
//   6  "DualSense Microphone"  7 input stream (1 ch float32)
//
// Threads:
//   - HAL control threads: property calls, client bookkeeping, and StartIO/StopIO, which wait for the
//     daemon's reply.
//   - HAL IO threads: GetZeroTimeStamp and the IO operations. No locks, logging, allocation or XPC.
//   - g_xpc_queue (serial): the daemon connection's events and replies, hello, shared-memory ports.
//   - g_notify_queue (serial): presence follow-ups (ending orphaned IO sessions, notifying the host).
//     It is separate because the host may call back into the plug-in from PropertiesChanged, and
//     StopIO waits for an XPC reply, which must never happen on the connection's own queue.

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <xpc/xpc.h>

#include "ds5_shared.h"

// The HAL fixes every vtable signature, so most entry points ignore some parameters (the CMake build
// passes -Wno-unused-parameter for the same reason).
#pragma clang diagnostic ignored "-Wunused-parameter"

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Speaker = 2,
    kObjectID_SpeakerStream = 3,
    kObjectID_SpeakerVolume = 4,
    kObjectID_SpeakerMute = 5,
    kObjectID_Mic = 6,
    kObjectID_MicStream = 7,
};

// A daemon request that produced no ds5_status: no connection, an XPC error or a malformed reply.
enum { kRequestFailed = -1000 };

static const Float64 kSampleRate = DS5_SAMPLE_RATE;
static const UInt32 kZeroTimeStampPeriod = 16384;
static const UInt32 kClockDomain = 0x44533541; // 'DS5A': both devices are timed by the host clock
static const Float32 kVolumeMinDB = -64.0f;
static const Float32 kVolumeMaxDB = 0.0f;
static const uint32_t kHelloRetryMaxMs = 30000;
#define kManufacturer CFSTR("PSGrok")
#define kModelUID CFSTR("com.psgrok.DualSenseAudio.Model")

typedef struct {
    UInt32 id;     // HAL client ID
    UInt32 starts; // StartIO calls not yet balanced by StopIO
} io_client;

typedef struct {
    // Description.
    AudioObjectID id;
    AudioObjectID stream_id;
    bool input;
    UInt32 channels;
    UInt32 latency; // frames
    CFStringRef name;
    CFStringRef uid;
    const char *label;
    const char *start_op;
    const char *stop_op;

    // IO session, guarded by g_io_mutex. The daemon stream runs while `clients` is non-empty.
    io_client *clients;
    UInt32 client_count;
    UInt32 client_capacity;
    uint64_t session_epoch; // presence epoch in which the daemon stream was started
    int logged_error;       // last start failure logged, so each reason is logged once

    // Read without locks.
    _Atomic uint64_t anchor_host_time; // host time of sample 0 of the current session
    _Atomic bool running;
    _Atomic bool stream_active;
} hal_device;

static hal_device g_speaker = {
    .id = kObjectID_Speaker,
    .stream_id = kObjectID_SpeakerStream,
    .input = false,
    .channels = 2,
    .latency = 2048,
    .name = CFSTR("DualSense Speaker"),
    .uid = CFSTR("com.psgrok.DualSenseAudio.Speaker"),
    .label = "speaker",
    .start_op = DS5_OP_SPEAKER_START,
    .stop_op = DS5_OP_SPEAKER_STOP,
    .stream_active = true,
};

static hal_device g_mic = {
    .id = kObjectID_Mic,
    .stream_id = kObjectID_MicStream,
    .input = true,
    .channels = 1,
    .latency = 1920,
    .name = CFSTR("DualSense Microphone"),
    .uid = CFSTR("com.psgrok.DualSenseAudio.Microphone"),
    .label = "microphone",
    .start_op = DS5_OP_MIC_START,
    .stop_op = DS5_OP_MIC_STOP,
    .stream_active = true,
};

static AudioServerPlugInHostRef g_host;
static os_log_t g_log;
static Float64 g_host_ticks_per_frame;
static _Atomic ULONG g_refcount;

// Controller presence as last reported by the daemon (disconnected while there is no daemon): bit 0 is
// the connected flag, the upper bits an epoch that advances on every change. Written on g_xpc_queue.
static _Atomic uint64_t g_presence;

static pthread_mutex_t g_io_mutex = PTHREAD_MUTEX_INITIALIZER; // IO sessions of both devices

// Speaker controls, never persisted. g_control_mutex serializes setters so the gain matches the volume.
static pthread_mutex_t g_control_mutex = PTHREAD_MUTEX_INITIALIZER;
static _Atomic float g_volume = 1.0f; // scalar 0..1
static _Atomic float g_gain = 1.0f;   // linear gain passed to ds5_port_speaker_write
static _Atomic bool g_muted;

// Daemon connection. Confined to g_xpc_queue, except that other threads copy g_conn under g_conn_mutex.
static dispatch_queue_t g_xpc_queue;
static dispatch_queue_t g_notify_queue;
static pthread_mutex_t g_conn_mutex = PTHREAD_MUTEX_INITIALIZER;
static xpc_connection_t g_conn;
static uint64_t g_conn_serial; // tells the events and replies of a replaced connection apart
static bool g_ready;           // hello succeeded and the daemon has not gone away since
static bool g_hello_in_flight;
static bool g_hello_timer_armed;
static uint32_t g_hello_retry_ms; // delay before the next hello; reset by a successful one
static bool g_outage_logged;

// Shared memory. IO threads use g_port between port_acquire and port_release. A replaced port is
// detached and unmapped only once no IO call is inside that window.
typedef struct mapped_port {
    ds5_port *port;
    void *mem;
    size_t size;
    struct mapped_port *next;
} mapped_port;
static _Atomic(ds5_port *) g_port;
static _Atomic uint32_t g_port_users;
static mapped_port *g_mapped;  // backs g_port (g_xpc_queue)
static mapped_port *g_retired; // replaced, awaiting detach (g_xpc_queue)
static bool g_reclaim_armed;

// The vtable is filled in at the end of the file.
static AudioServerPlugInDriverInterface g_interface;
static AudioServerPlugInDriverInterface *g_interface_ptr = &g_interface;
static AudioServerPlugInDriverRef const g_driver = &g_interface_ptr;

#pragma mark Helpers

static bool presence_connected(uint64_t presence) { return (presence & 1) != 0; }
static uint64_t presence_epoch(uint64_t presence) { return presence >> 1; }
static bool controller_connected(void) { return presence_connected(atomic_load(&g_presence)); }

static hal_device *device_for_id(AudioObjectID id) {
    return id == kObjectID_Speaker ? &g_speaker : id == kObjectID_Mic ? &g_mic : NULL;
}

static hal_device *device_for_stream(AudioObjectID id) {
    return id == kObjectID_SpeakerStream ? &g_speaker : id == kObjectID_MicStream ? &g_mic : NULL;
}

static AudioObjectPropertyScope device_scope(const hal_device *d) {
    return d->input ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
}

static bool is_io_scope(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeInput || scope == kAudioObjectPropertyScopeOutput;
}

// Global scope or the device's own direction.
static bool scope_covers(const hal_device *d, AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal || scope == device_scope(d);
}

static AudioStreamBasicDescription stream_format(const hal_device *d) {
    UInt32 frame_bytes = d->channels * (UInt32)sizeof(Float32);
    return (AudioStreamBasicDescription){
        .mSampleRate = kSampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = frame_bytes,
        .mFramesPerPacket = 1,
        .mBytesPerFrame = frame_bytes,
        .mChannelsPerFrame = d->channels,
        .mBitsPerChannel = 32,
    };
}

static bool format_supported(const hal_device *d, const AudioStreamBasicDescription *f) {
    AudioStreamBasicDescription ours = stream_format(d);
    return f->mSampleRate == ours.mSampleRate && f->mFormatID == ours.mFormatID &&
           f->mFormatFlags == ours.mFormatFlags && f->mBytesPerPacket == ours.mBytesPerPacket &&
           f->mFramesPerPacket == ours.mFramesPerPacket && f->mBytesPerFrame == ours.mBytesPerFrame &&
           f->mChannelsPerFrame == ours.mChannelsPerFrame && f->mBitsPerChannel == ours.mBitsPerChannel;
}

static const char *status_text(int st) {
    switch (st) {
    case DS5_OK: return "ok";
    case DS5_ERR_NO_DEVICE: return "no DualSense connected";
    case DS5_ERR_EXCLUSIVE: return "could not take exclusive access to the controller";
    case DS5_ERR_IO: return "HID report I/O failed";
    case kRequestFailed: return "helper daemon unavailable";
    }
    return "unknown helper error";
}

#pragma mark Volume

static Float32 clamp_scalar(Float32 x) { return x > 0.0f ? (x < 1.0f ? x : 1.0f) : 0.0f; } // NaN -> 0

// Squared taper: the slider position is squared, then mapped linearly onto the dB range.
static Float32 scalar_to_db(Float32 scalar) {
    scalar = clamp_scalar(scalar);
    return kVolumeMinDB + scalar * scalar * (kVolumeMaxDB - kVolumeMinDB);
}

static Float32 db_to_scalar(Float32 db) {
    if (!(db > kVolumeMinDB)) return 0.0f; // also NaN
    if (db >= kVolumeMaxDB) return 1.0f;
    return sqrtf((db - kVolumeMinDB) / (kVolumeMaxDB - kVolumeMinDB));
}

static float volume_gain(Float32 scalar) {
    return scalar > 0.0f ? powf(10.0f, scalar_to_db(scalar) / 20.0f) : 0.0f;
}

// Return whether the value changed.
static bool set_volume_scalar(Float32 scalar) {
    pthread_mutex_lock(&g_control_mutex);
    bool changed = scalar != atomic_load(&g_volume);
    if (changed) {
        atomic_store(&g_volume, scalar);
        atomic_store(&g_gain, volume_gain(scalar));
    }
    pthread_mutex_unlock(&g_control_mutex);
    return changed;
}

static bool set_speaker_muted(bool muted) { return atomic_exchange(&g_muted, muted) != muted; }

#pragma mark Daemon requests

static xpc_connection_t copy_connection(void) {
    pthread_mutex_lock(&g_conn_mutex);
    xpc_connection_t conn = g_conn ? xpc_retain(g_conn) : NULL;
    pthread_mutex_unlock(&g_conn_mutex);
    return conn;
}

static xpc_object_t request_message(const char *op) {
    xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(msg, DS5_XPC_OP, op);
    return msg;
}

// The ds5_status carried by a reply; kRequestFailed for an XPC error or a reply without a status.
static int reply_status(xpc_object_t reply) {
    if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY) return kRequestFailed;
    xpc_object_t status = xpc_dictionary_get_value(reply, DS5_XPC_STATUS);
    if (!status || xpc_get_type(status) != XPC_TYPE_INT64) return kRequestFailed;
    return (int)xpc_int64_get_value(status);
}

// Sends a request and waits for the daemon's status. Never on g_xpc_queue: a synchronous send from the
// connection's target queue can deadlock.
static int daemon_request(const char *op) {
    xpc_connection_t conn = copy_connection();
    if (!conn) return kRequestFailed;
    xpc_object_t msg = request_message(op);
    xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, msg);
    int status = reply_status(reply);
    xpc_release(reply);
    xpc_release(msg);
    xpc_release(conn);
    return status;
}

// Queues a request without waiting. One connection delivers messages in order, so a later request is
// never overtaken by it.
static void daemon_post(const char *op) {
    xpc_connection_t conn = copy_connection();
    if (!conn) return;
    xpc_object_t msg = request_message(op);
    xpc_connection_send_message_with_reply(conn, msg, g_xpc_queue, ^(xpc_object_t reply) {
        int status = reply_status(reply);
        if (status != DS5_OK) os_log(g_log, "%{public}s: %{public}s", op, status_text(status));
    });
    xpc_release(msg);
    xpc_release(conn);
}

#pragma mark Shared memory

// IO threads. A port loaded here stays attached until the matching port_release.
static ds5_port *port_acquire(void) {
    atomic_fetch_add(&g_port_users, 1);
    return atomic_load(&g_port);
}

static void port_release(void) { atomic_fetch_sub(&g_port_users, 1); }

static void reclaim_ports(void *unused);

static void arm_reclaim(void) {
    if (g_reclaim_armed) return;
    g_reclaim_armed = true;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_MSEC)), g_xpc_queue, NULL,
                     reclaim_ports);
}

// g_xpc_queue. An IO call can only hold a replaced port while it is between port_acquire and
// port_release, so once no call is, every retired port is free.
static void reclaim_ports(void *unused) {
    g_reclaim_armed = false;
    if (!g_retired) return;
    if (atomic_load(&g_port_users) != 0) {
        arm_reclaim();
        return;
    }
    while (g_retired) {
        mapped_port *m = g_retired;
        g_retired = m->next;
        ds5_port_detach(m->port);
        munmap(m->mem, m->size);
        free(m);
    }
}

// g_xpc_queue. Maps the region from a hello reply and hands its port to the IO threads.
static bool attach_region(xpc_object_t reply) {
    xpc_object_t shm = xpc_dictionary_get_value(reply, DS5_XPC_SHM);
    if (!shm || xpc_get_type(shm) != XPC_TYPE_SHMEM) return false;
    void *mem = NULL;
    size_t size = xpc_shmem_map(shm, &mem);
    if (!size) return false;
    ds5_port *port = ds5_port_attach(mem, size);
    mapped_port *m = port ? malloc(sizeof *m) : NULL;
    if (!m) {
        if (port) ds5_port_detach(port);
        munmap(mem, size);
        return false;
    }
    *m = (mapped_port){.port = port, .mem = mem, .size = size};
    atomic_store(&g_port, port);
    if (g_mapped) {
        g_mapped->next = g_retired;
        g_retired = g_mapped;
        arm_reclaim();
    }
    g_mapped = m;
    return true;
}

#pragma mark IO sessions

static io_client *find_client(hal_device *d, UInt32 id) {
    for (UInt32 i = 0; i < d->client_count; i++)
        if (d->clients[i].id == id) return &d->clients[i];
    return NULL;
}

static bool reserve_client(hal_device *d) {
    if (d->client_count < d->client_capacity) return true;
    UInt32 capacity = d->client_capacity ? d->client_capacity * 2 : 8;
    io_client *grown = realloc(d->clients, capacity * sizeof *grown);
    if (!grown) return false;
    d->clients = grown;
    d->client_capacity = capacity;
    return true;
}

static void remove_client(hal_device *d, io_client *c) { *c = d->clients[--d->client_count]; }

// Stops the daemon stream and forgets every client. g_io_mutex held. With `wait` the daemon's reply is
// awaited; otherwise the stop is only queued.
static void end_session(hal_device *d, bool wait) {
    d->client_count = 0;
    atomic_store(&d->running, false);
    if (!wait) {
        daemon_post(d->stop_op);
        return;
    }
    int status = daemon_request(d->stop_op);
    if (status != DS5_OK) os_log(g_log, "%{public}s: %{public}s", d->stop_op, status_text(status));
}

// Ends a session started before `epoch`. The controller or the daemon went away since then, which removes
// the devices from the HAL, and the HAL may never call StopIO for their clients. Without this the daemon
// would resume the stream on reconnect (re-seizing the controller for the mic) with nobody listening.
// Later StopIO calls from those clients find nothing to stop. g_io_mutex held.
static void end_orphaned_session(hal_device *d, uint64_t epoch) {
    if (d->client_count == 0 || d->session_epoch >= epoch) return;
    os_log(g_log, "%{public}s: DualSense gone during IO; ending the session of %u client(s)", d->label,
           d->client_count);
    end_session(d, false);
}

static OSStatus start_failed(hal_device *d, int st) {
    if (st != d->logged_error) {
        d->logged_error = st;
        os_log_error(g_log, "%{public}s: cannot start IO: %{public}s", d->label, status_text(st));
    }
    return st == DS5_ERR_NO_DEVICE || st == kRequestFailed ? kAudioHardwareNotRunningError
                                                           : kAudioHardwareUnspecifiedError;
}

#pragma mark Presence

// g_notify_queue.
static void presence_notify(void *ctx) {
    uint64_t presence = (uint64_t)(uintptr_t)ctx;
    bool connected = presence_connected(presence);
    os_log(g_log, "%{public}s devices", connected ? "publishing" : "removing");
    if (!connected) {
        pthread_mutex_lock(&g_io_mutex);
        end_orphaned_session(&g_speaker, presence_epoch(presence));
        end_orphaned_session(&g_mic, presence_epoch(presence));
        pthread_mutex_unlock(&g_io_mutex);
    }
    static const AudioObjectPropertyAddress changed[] = {
        {kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
        {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
    };
    g_host->PropertiesChanged(g_host, kObjectID_PlugIn, 2, changed);
}

// g_xpc_queue. Records the state and leaves everything else to g_notify_queue.
static void set_presence(bool connected) {
    uint64_t current = atomic_load(&g_presence);
    if (presence_connected(current) == connected) return;
    uint64_t next = ((presence_epoch(current) + 1) << 1) | (connected ? 1u : 0u);
    atomic_store(&g_presence, next);
    dispatch_async_f(g_notify_queue, (void *)(uintptr_t)next, presence_notify);
}

#pragma mark Daemon link (g_xpc_queue)

static void send_hello(void);
static void connection_event(uint64_t serial, xpc_object_t event);

static void hello_timer_fired(void *unused) {
    g_hello_timer_armed = false;
    send_hello();
}

// Sends hello again, after a delay that grows while attempts keep failing: 0, 0.25 s, 0.5 s ... 30 s.
static void schedule_hello(void) {
    if (g_hello_in_flight || g_hello_timer_armed) return;
    g_hello_timer_armed = true;
    uint32_t delay_ms = g_hello_retry_ms;
    g_hello_retry_ms = delay_ms == 0 ? 250 : delay_ms < kHelloRetryMaxMs / 2 ? delay_ms * 2 : kHelloRetryMaxMs;
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay_ms * NSEC_PER_MSEC)), g_xpc_queue, NULL,
                     hello_timer_fired);
}

// The daemon lost our state (it exited, dropped us, or cannot be reached): nothing is published until
// a new hello succeeds.
static void link_lost(const char *why) {
    g_ready = false;
    if (!g_outage_logged) {
        g_outage_logged = true;
        os_log_error(g_log, "helper daemon %{public}s %{public}s; retrying", DS5_HELPER_MACH_SERVICE, why);
    }
    set_presence(false);
}

static void hello_replied(uint64_t serial, xpc_object_t reply) {
    if (serial != g_conn_serial) return; // sent on a replaced connection
    g_hello_in_flight = false;
    if (xpc_get_type(reply) == XPC_TYPE_ERROR) { // the connection's event handler records the loss
        schedule_hello();
        return;
    }
    int status = reply_status(reply);
    if (status != DS5_OK || !attach_region(reply)) {
        link_lost(status != DS5_OK ? "rejected hello" : "sent unusable shared memory");
        schedule_hello();
        return;
    }
    bool connected = xpc_dictionary_get_bool(reply, DS5_XPC_CONNECTED);
    g_ready = true;
    g_hello_retry_ms = 0;
    g_outage_logged = false;
    os_log(g_log, "helper daemon ready; DualSense %{public}s", connected ? "connected" : "not connected");
    set_presence(connected);
}

// Installs `conn` (NULL drops the current one). The caller has advanced g_conn_serial, so the old
// connection's remaining events and replies are ignored.
static void replace_connection(xpc_connection_t conn) {
    pthread_mutex_lock(&g_conn_mutex);
    xpc_connection_t old = g_conn;
    g_conn = conn;
    pthread_mutex_unlock(&g_conn_mutex);
    g_hello_in_flight = false; // a hello sent on the old connection is never answered
    if (old) {
        xpc_connection_cancel(old);
        xpc_release(old);
    }
}

static void connect_daemon(void) {
    uint64_t serial = ++g_conn_serial;
    // The daemon's service lives in the system bootstrap (it is a LaunchDaemon): look it up there only.
    xpc_connection_t conn = xpc_connection_create_mach_service(DS5_HELPER_MACH_SERVICE, g_xpc_queue,
                                                               XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
        connection_event(serial, event);
    });
    xpc_connection_activate(conn);
    replace_connection(conn);
}

// Connects first if the last connection was dropped, so new connections follow the hello backoff.
static void send_hello(void) {
    if (g_ready || g_hello_in_flight) return;
    if (!g_conn) connect_daemon();
    g_hello_in_flight = true;
    uint64_t serial = g_conn_serial;
    xpc_object_t msg = request_message(DS5_OP_HELLO);
    xpc_connection_send_message_with_reply(g_conn, msg, g_xpc_queue, ^(xpc_object_t reply) {
        hello_replied(serial, reply);
    });
    xpc_release(msg);
}

static void connection_event(uint64_t serial, xpc_object_t event) {
    if (serial != g_conn_serial) return; // a replaced connection winding down
    if (xpc_get_type(event) == XPC_TYPE_DICTIONARY) {
        const char *op = xpc_dictionary_get_string(event, DS5_XPC_OP);
        if (g_ready && op && strcmp(op, DS5_OP_PRESENCE) == 0)
            set_presence(xpc_dictionary_get_bool(event, DS5_XPC_CONNECTED));
        return;
    }
    if (event == XPC_ERROR_CONNECTION_INTERRUPTED) {
        // The daemon exited or dropped us; this connection reaches its next instance.
        link_lost("went away");
    } else if (event == XPC_ERROR_CONNECTION_INVALID) {
        // The service could not be looked up (not loaded, or not allowed): the next hello reconnects.
        link_lost("is not reachable");
        g_conn_serial++;
        replace_connection(NULL);
    } else {
        return;
    }
    schedule_hello();
}

static void link_start(void *unused) { send_hello(); }

#pragma mark Property values

typedef struct {
    UInt32 size;      // bytes in the full value
    UInt32 item_size; // nonzero for arrays: a smaller buffer receives a prefix of whole items
    union {
        AudioObjectID ids[3];
        AudioValueRange range;
        AudioStreamBasicDescription format;
        AudioStreamRangedDescription ranged;
        UInt8 bytes[64];
    } v;
} prop_value;

static OSStatus put(prop_value *p, const void *src, UInt32 size, UInt32 item_size) {
    if (size) memcpy(&p->v, src, size);
    p->size = size;
    p->item_size = item_size;
    return noErr;
}

static OSStatus put_u32(prop_value *p, UInt32 x) { return put(p, &x, sizeof x, 0); }
static OSStatus put_f32(prop_value *p, Float32 x) { return put(p, &x, sizeof x, 0); }
static OSStatus put_f64(prop_value *p, Float64 x) { return put(p, &x, sizeof x, 0); }
static OSStatus put_string(prop_value *p, CFStringRef s) { return put(p, &s, sizeof s, 0); }

static OSStatus put_ids(prop_value *p, const AudioObjectID *ids, UInt32 n) {
    return put(p, ids, n * (UInt32)sizeof *ids, sizeof *ids);
}

static OSStatus put_range(prop_value *p, Float64 lo, Float64 hi, bool list) {
    AudioValueRange range = {lo, hi};
    return put(p, &range, sizeof range, list ? sizeof range : 0);
}

// Published devices: both while the controller is connected, none otherwise.
static OSStatus put_devices(prop_value *p) {
    static const AudioObjectID devices[] = {kObjectID_Speaker, kObjectID_Mic};
    return put_ids(p, devices, controller_connected() ? 2 : 0);
}

static OSStatus put_channel_layout(prop_value *p, const hal_device *d) {
    memset(p->v.bytes, 0, sizeof p->v.bytes);
    AudioChannelLayout *layout = (AudioChannelLayout *)p->v.bytes;
    AudioChannelDescription *channels =
        (AudioChannelDescription *)(p->v.bytes + offsetof(AudioChannelLayout, mChannelDescriptions));
    layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    layout->mNumberChannelDescriptions = d->channels;
    for (UInt32 i = 0; i < d->channels; i++)
        channels[i].mChannelLabel = d->input ? kAudioChannelLabel_Mono : kAudioChannelLabel_Left + i;
    p->size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) +
                       d->channels * sizeof(AudioChannelDescription));
    p->item_size = 0;
    return noErr;
}

#pragma mark Property tables

// Each getter fills `out` or returns kAudioHardwareUnknownPropertyError. With `fetch` false (property
// probes and size queries) qualifier and input data are not read and only the size is meaningful.

static OSStatus plugin_property(const AudioObjectPropertyAddress *a, UInt32 qualifier_size,
                                const void *qualifier, bool fetch, prop_value *out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: return put_u32(out, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return put_u32(out, kAudioPlugInClassID);
    case kAudioObjectPropertyOwner: return put_u32(out, kAudioObjectUnknown);
    case kAudioObjectPropertyManufacturer: return put_string(out, kManufacturer);
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList: return put_devices(out);
    case kAudioPlugInPropertyBoxList: return put_ids(out, NULL, 0);
    case kAudioPlugInPropertyTranslateUIDToBox: return put_u32(out, kAudioObjectUnknown);
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        AudioObjectID device = kAudioObjectUnknown;
        if (fetch) {
            if (qualifier_size != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)qualifier;
            if (uid && controller_connected()) {
                if (CFEqual(uid, g_speaker.uid))
                    device = kObjectID_Speaker;
                else if (CFEqual(uid, g_mic.uid))
                    device = kObjectID_Mic;
            }
        }
        return put_u32(out, device);
    }
    case kAudioPlugInPropertyResourceBundle: return put_string(out, CFSTR(""));
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus device_property(const hal_device *d, const AudioObjectPropertyAddress *a, prop_value *out) {
    AudioObjectPropertyScope scope = a->mScope;
    bool own_scope = scope == device_scope(d);
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: return put_u32(out, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return put_u32(out, kAudioDeviceClassID);
    case kAudioObjectPropertyOwner: return put_u32(out, kObjectID_PlugIn);
    case kAudioObjectPropertyName: return put_string(out, d->name);
    case kAudioObjectPropertyManufacturer: return put_string(out, kManufacturer);
    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID ids[3];
        UInt32 n = 0;
        if (scope_covers(d, scope)) {
            ids[n++] = d->stream_id;
            if (!d->input) {
                ids[n++] = kObjectID_SpeakerVolume;
                ids[n++] = kObjectID_SpeakerMute;
            }
        }
        return put_ids(out, ids, n);
    }
    case kAudioObjectPropertyControlList: {
        static const AudioObjectID controls[] = {kObjectID_SpeakerVolume, kObjectID_SpeakerMute};
        return put_ids(out, controls, d->input ? 0 : 2);
    }
    case kAudioDevicePropertyDeviceUID: return put_string(out, d->uid);
    case kAudioDevicePropertyModelUID: return put_string(out, kModelUID);
    case kAudioDevicePropertyTransportType: return put_u32(out, kAudioDeviceTransportTypeVirtual);
    case kAudioDevicePropertyRelatedDevices: return put_devices(out); // two halves of one controller
    case kAudioDevicePropertyClockDomain: return put_u32(out, kClockDomain);
    case kAudioDevicePropertyDeviceIsAlive: return put_u32(out, controller_connected());
    case kAudioDevicePropertyDeviceIsRunning: return put_u32(out, atomic_load(&d->running));
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        if (!is_io_scope(scope)) break;
        return put_u32(out, own_scope);
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        if (!is_io_scope(scope)) break;
        return put_u32(out, 0);
    case kAudioDevicePropertyLatency:
        if (!is_io_scope(scope)) break;
        return put_u32(out, own_scope ? d->latency : 0);
    case kAudioDevicePropertySafetyOffset:
        if (!is_io_scope(scope)) break;
        return put_u32(out, 0);
    case kAudioDevicePropertyStreams: return put_ids(out, &d->stream_id, scope_covers(d, scope) ? 1 : 0);
    case kAudioDevicePropertyNominalSampleRate: return put_f64(out, kSampleRate);
    case kAudioDevicePropertyAvailableNominalSampleRates: return put_range(out, kSampleRate, kSampleRate, true);
    case kAudioDevicePropertyIsHidden: return put_u32(out, 0);
    case kAudioDevicePropertyZeroTimeStampPeriod: return put_u32(out, kZeroTimeStampPeriod);
    case kAudioDevicePropertyConfigurationApplication:
        return put_string(out, CFSTR("com.apple.audio.AudioMIDISetup"));
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        if (d->input || !own_scope) break;
        static const UInt32 stereo[2] = {1, 2};
        return put(out, stereo, sizeof stereo, 0);
    }
    case kAudioDevicePropertyPreferredChannelLayout:
        if (!own_scope) break;
        return put_channel_layout(out, d);
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus stream_property(const hal_device *d, const AudioObjectPropertyAddress *a, prop_value *out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: return put_u32(out, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return put_u32(out, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: return put_u32(out, d->id);
    case kAudioObjectPropertyOwnedObjects: return put_ids(out, NULL, 0);
    case kAudioStreamPropertyIsActive: return put_u32(out, atomic_load(&d->stream_active));
    case kAudioStreamPropertyDirection: return put_u32(out, d->input ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
        return put_u32(out, d->input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
    case kAudioStreamPropertyStartingChannel: return put_u32(out, 1);
    case kAudioStreamPropertyLatency: return put_u32(out, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: {
        AudioStreamBasicDescription format = stream_format(d);
        return put(out, &format, sizeof format, 0);
    }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription ranged = {stream_format(d), {kSampleRate, kSampleRate}};
        return put(out, &ranged, sizeof ranged, sizeof ranged);
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

// `io` is the caller's buffer: the conversion properties read their input from it.
static OSStatus volume_property(const AudioObjectPropertyAddress *a, bool fetch, const void *io, UInt32 io_size,
                                prop_value *out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: return put_u32(out, kAudioLevelControlClassID);
    case kAudioObjectPropertyClass: return put_u32(out, kAudioVolumeControlClassID);
    case kAudioObjectPropertyOwner: return put_u32(out, kObjectID_Speaker);
    case kAudioObjectPropertyOwnedObjects: return put_ids(out, NULL, 0);
    case kAudioControlPropertyScope: return put_u32(out, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: return put_u32(out, kAudioObjectPropertyElementMain);
    case kAudioLevelControlPropertyScalarValue: return put_f32(out, atomic_load(&g_volume));
    case kAudioLevelControlPropertyDecibelValue: return put_f32(out, scalar_to_db(atomic_load(&g_volume)));
    case kAudioLevelControlPropertyDecibelRange: return put_range(out, kVolumeMinDB, kVolumeMaxDB, false);
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar: {
        Float32 value = 0.0f;
        if (fetch) {
            if (!io || io_size < sizeof value) return kAudioHardwareBadPropertySizeError;
            memcpy(&value, io, sizeof value);
            value = a->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels ? scalar_to_db(value)
                                                                                     : db_to_scalar(value);
        }
        return put_f32(out, value);
    }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus mute_property(const AudioObjectPropertyAddress *a, prop_value *out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: return put_u32(out, kAudioBooleanControlClassID);
    case kAudioObjectPropertyClass: return put_u32(out, kAudioMuteControlClassID);
    case kAudioObjectPropertyOwner: return put_u32(out, kObjectID_Speaker);
    case kAudioObjectPropertyOwnedObjects: return put_ids(out, NULL, 0);
    case kAudioControlPropertyScope: return put_u32(out, kAudioObjectPropertyScopeOutput);
    case kAudioControlPropertyElement: return put_u32(out, kAudioObjectPropertyElementMain);
    case kAudioBooleanControlPropertyValue: return put_u32(out, atomic_load(&g_muted));
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus get_property(AudioObjectID object, const AudioObjectPropertyAddress *a, UInt32 qualifier_size,
                             const void *qualifier, bool fetch, const void *io, UInt32 io_size, prop_value *out) {
    const hal_device *d;
    if (object == kObjectID_PlugIn) return plugin_property(a, qualifier_size, qualifier, fetch, out);
    if ((d = device_for_id(object))) return device_property(d, a, out);
    if ((d = device_for_stream(object))) return stream_property(d, a, out);
    if (object == kObjectID_SpeakerVolume) return volume_property(a, fetch, io, io_size, out);
    if (object == kObjectID_SpeakerMute) return mute_property(a, out);
    return kAudioHardwareBadObjectError;
}

static bool is_settable(AudioObjectID object, AudioObjectPropertySelector selector) {
    switch (object) {
    case kObjectID_Speaker:
    case kObjectID_Mic: return selector == kAudioDevicePropertyNominalSampleRate;
    case kObjectID_SpeakerStream:
    case kObjectID_MicStream:
        return selector == kAudioStreamPropertyIsActive || selector == kAudioStreamPropertyVirtualFormat ||
               selector == kAudioStreamPropertyPhysicalFormat;
    case kObjectID_SpeakerVolume:
        return selector == kAudioLevelControlPropertyScalarValue || selector == kAudioLevelControlPropertyDecibelValue;
    case kObjectID_SpeakerMute: return selector == kAudioBooleanControlPropertyValue;
    }
    return false;
}

#pragma mark IUnknown

static HRESULT DS5_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != g_driver) return kAudioHardwareBadObjectError;
    if (!outInterface) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (!requested) return kAudioHardwareIllegalOperationError;
    bool known = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!known) return E_NOINTERFACE;
    atomic_fetch_add(&g_refcount, 1);
    *outInterface = g_driver;
    return S_OK;
}

static ULONG DS5_AddRef(void *inDriver) {
    if (inDriver != g_driver) return 0;
    return atomic_fetch_add(&g_refcount, 1) + 1;
}

// The driver is static and the host never unloads it, so nothing is freed at zero.
static ULONG DS5_Release(void *inDriver) {
    if (inDriver != g_driver) return 0;
    ULONG count = atomic_load(&g_refcount);
    while (count > 0 && !atomic_compare_exchange_weak(&g_refcount, &count, count - 1)) {
    }
    return count > 0 ? count - 1 : 0;
}

#pragma mark Basic operations

static OSStatus DS5_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != g_driver) return kAudioHardwareBadObjectError;
    g_host = inHost;
    g_log = os_log_create("com.psgrok.DualSenseAudio", "plugin");

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    g_host_ticks_per_frame = (Float64)timebase.denom / (Float64)timebase.numer * 1e9 / kSampleRate;

    // Device-list notifications wait in the inactive queue until initialization is complete. The devices
    // appear once the helper daemon answers hello; Initialize never waits for it.
    g_notify_queue = dispatch_queue_create("com.psgrok.DualSenseAudio.notify",
                                           dispatch_queue_attr_make_initially_inactive(DISPATCH_QUEUE_SERIAL));
    g_xpc_queue = dispatch_queue_create("com.psgrok.DualSenseAudio.xpc", DISPATCH_QUEUE_SERIAL);
    dispatch_async_f(g_xpc_queue, NULL, link_start);
    os_log(g_log, "initialized; connecting to %{public}s", DS5_HELPER_MACH_SERVICE);
    dispatch_activate(g_notify_queue);
    return noErr;
}

static OSStatus DS5_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    return inDriver == g_driver ? kAudioHardwareUnsupportedOperationError : kAudioHardwareBadObjectError;
}

static OSStatus DS5_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    return inDriver == g_driver ? kAudioHardwareUnsupportedOperationError : kAudioHardwareBadObjectError;
}

static OSStatus DS5_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo *inClientInfo) {
    return inDriver == g_driver && device_for_id(inDeviceObjectID) ? noErr : kAudioHardwareBadObjectError;
}

// A client that goes away with IO still started is treated as stopped.
static OSStatus DS5_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo *inClientInfo) {
    hal_device *d = device_for_id(inDeviceObjectID);
    if (inDriver != g_driver || !d) return kAudioHardwareBadObjectError;
    if (!inClientInfo) return kAudioHardwareIllegalOperationError;
    pthread_mutex_lock(&g_io_mutex);
    io_client *c = find_client(d, inClientInfo->mClientID);
    if (c) {
        os_log(g_log, "%{public}s: client %u removed with IO started", d->label, c->id);
        remove_client(d, c);
        if (d->client_count == 0) end_session(d, true);
    }
    pthread_mutex_unlock(&g_io_mutex);
    return noErr;
}

// The devices never request configuration changes.
static OSStatus DS5_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                     AudioObjectID inDeviceObjectID, UInt64 inChangeAction,
                                                     void *inChangeInfo) {
    return inDriver == g_driver && device_for_id(inDeviceObjectID) ? noErr : kAudioHardwareBadObjectError;
}

static OSStatus DS5_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver,
                                                   AudioObjectID inDeviceObjectID, UInt64 inChangeAction,
                                                   void *inChangeInfo) {
    return inDriver == g_driver && device_for_id(inDeviceObjectID) ? noErr : kAudioHardwareBadObjectError;
}

#pragma mark Property operations

static Boolean DS5_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                               pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    prop_value value;
    return inDriver == g_driver && inAddress &&
           get_property(inObjectID, inAddress, 0, NULL, false, NULL, 0, &value) == noErr;
}

static OSStatus DS5_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                       Boolean *outIsSettable) {
    if (inDriver != g_driver) return kAudioHardwareBadObjectError;
    if (!inAddress || !outIsSettable) return kAudioHardwareIllegalOperationError;
    prop_value value;
    OSStatus err = get_property(inObjectID, inAddress, 0, NULL, false, NULL, 0, &value);
    if (err) return err;
    *outIsSettable = is_settable(inObjectID, inAddress->mSelector);
    return noErr;
}

static OSStatus DS5_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                        pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                        UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    if (inDriver != g_driver) return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize) return kAudioHardwareIllegalOperationError;
    prop_value value;
    OSStatus err = get_property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, false, NULL, 0, &value);
    if (err) return err;
    *outDataSize = value.size;
    return noErr;
}

static OSStatus DS5_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize,
                                    UInt32 *outDataSize, void *outData) {
    if (inDriver != g_driver) return kAudioHardwareBadObjectError;
    if (!inAddress || !outDataSize) return kAudioHardwareIllegalOperationError;
    prop_value value;
    OSStatus err = get_property(inObjectID, inAddress, inQualifierDataSize, inQualifierData, true, outData,
                                inDataSize, &value);
    if (err) return err;
    UInt32 size = value.size;
    if (inDataSize < size) {
        if (!value.item_size) return kAudioHardwareBadPropertySizeError;
        size = inDataSize / value.item_size * value.item_size;
    }
    if (size) {
        if (!outData) return kAudioHardwareIllegalOperationError;
        memcpy(outData, &value.v, size);
    }
    *outDataSize = size;
    return noErr;
}

static OSStatus DS5_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress,
                                    UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize,
                                    const void *inData) {
    if (inDriver != g_driver) return kAudioHardwareBadObjectError;
    if (!inAddress || !inData) return kAudioHardwareIllegalOperationError;
    prop_value current;
    OSStatus err = get_property(inObjectID, inAddress, 0, NULL, false, NULL, 0, &current);
    if (err) return err;
    if (!is_settable(inObjectID, inAddress->mSelector)) return kAudioHardwareUnknownPropertyError;
    if (inDataSize != current.size) return kAudioHardwareBadPropertySizeError;

    AudioObjectPropertyAddress changed[2];
    UInt32 changed_count = 0;
    switch (inObjectID) {
    case kObjectID_Speaker:
    case kObjectID_Mic: {
        // 48 kHz is the only rate; setting it again is a no-op.
        Float64 rate;
        memcpy(&rate, inData, sizeof rate);
        return rate == kSampleRate ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    case kObjectID_SpeakerStream:
    case kObjectID_MicStream: {
        hal_device *d = device_for_stream(inObjectID);
        if (inAddress->mSelector == kAudioStreamPropertyIsActive) {
            UInt32 active;
            memcpy(&active, inData, sizeof active);
            if (atomic_exchange(&d->stream_active, active != 0) != (active != 0))
                changed[changed_count++] = *inAddress;
            break;
        }
        // One fixed format per stream; setting it again is a no-op.
        AudioStreamBasicDescription format;
        memcpy(&format, inData, sizeof format);
        return format_supported(d, &format) ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    case kObjectID_SpeakerVolume: {
        Float32 value;
        memcpy(&value, inData, sizeof value);
        Float32 scalar = inAddress->mSelector == kAudioLevelControlPropertyScalarValue ? clamp_scalar(value)
                                                                                      : db_to_scalar(value);
        if (set_volume_scalar(scalar)) {
            changed[changed_count++] = (AudioObjectPropertyAddress){
                kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            changed[changed_count++] = (AudioObjectPropertyAddress){
                kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        }
        break;
    }
    case kObjectID_SpeakerMute: {
        UInt32 muted;
        memcpy(&muted, inData, sizeof muted);
        if (set_speaker_muted(muted != 0))
            changed[changed_count++] = (AudioObjectPropertyAddress){
                kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        break;
    }
    }
    if (changed_count) g_host->PropertiesChanged(g_host, inObjectID, changed_count, changed);
    return noErr;
}

#pragma mark IO operations

// g_io_mutex held.
static OSStatus start_io_locked(hal_device *d, UInt32 client) {
    uint64_t presence = atomic_load(&g_presence);
    if (!presence_connected(presence)) return start_failed(d, DS5_ERR_NO_DEVICE);
    // A session from before the latest reconnect is dead even if its disconnect is still queued.
    end_orphaned_session(d, presence_epoch(presence));

    io_client *c = find_client(d, client);
    if (c) {
        c->starts++;
        return noErr;
    }
    if (!reserve_client(d)) return kAudioHardwareUnspecifiedError;
    if (d->client_count == 0) {
        int st = daemon_request(d->start_op);
        if (st != DS5_OK) return start_failed(d, st);
        d->logged_error = DS5_OK;
        d->session_epoch = presence_epoch(presence);
        atomic_store(&d->anchor_host_time, mach_absolute_time());
        atomic_store(&d->running, true);
        os_log(g_log, "%{public}s: IO started", d->label);
    }
    d->clients[d->client_count++] = (io_client){client, 1};
    return noErr;
}

// The first client starts the daemon stream, the last one stops it. Both wait for the daemon's reply;
// the HAL calls these on a non-IO thread. A failed start leaves the client count unchanged.
static OSStatus DS5_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    hal_device *d = device_for_id(inDeviceObjectID);
    if (inDriver != g_driver || !d) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&g_io_mutex);
    OSStatus err = start_io_locked(d, inClientID);
    pthread_mutex_unlock(&g_io_mutex);
    return err;
}

static OSStatus DS5_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    hal_device *d = device_for_id(inDeviceObjectID);
    if (inDriver != g_driver || !d) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&g_io_mutex);
    // Unknown clients belong to a session already ended because the controller or daemon went away.
    io_client *c = find_client(d, inClientID);
    if (c && --c->starts == 0) {
        remove_client(d, c);
        if (d->client_count == 0) {
            end_session(d, true);
            os_log(g_log, "%{public}s: IO stopped", d->label);
        }
    }
    pthread_mutex_unlock(&g_io_mutex);
    return noErr;
}

// Host-clock timeline anchored at the first StartIO: one zero time stamp every kZeroTimeStampPeriod
// frames at exactly 48 kHz. Lock-free; the anchor only changes while the device is stopped.
static OSStatus DS5_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime,
                                     UInt64 *outSeed) {
    hal_device *d = device_for_id(inDeviceObjectID);
    if (inDriver != g_driver || !d) return kAudioHardwareBadObjectError;
    uint64_t anchor = atomic_load_explicit(&d->anchor_host_time, memory_order_acquire);
    uint64_t now = mach_absolute_time();
    Float64 ticks_per_period = g_host_ticks_per_frame * kZeroTimeStampPeriod;
    uint64_t periods = now > anchor ? (uint64_t)((Float64)(now - anchor) / ticks_per_period) : 0;
    *outSampleTime = (Float64)(periods * kZeroTimeStampPeriod);
    *outHostTime = anchor + (uint64_t)((Float64)periods * ticks_per_period);
    *outSeed = 1;
    return noErr;
}

static OSStatus DS5_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo,
                                      Boolean *outWillDoInPlace) {
    hal_device *d = device_for_id(inDeviceObjectID);
    if (inDriver != g_driver || !d) return kAudioHardwareBadObjectError;
    UInt32 operation = d->input ? kAudioServerPlugInIOOperationReadInput : kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = inOperationID == operation;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus DS5_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return inDriver == g_driver && device_for_id(inDeviceObjectID) ? noErr : kAudioHardwareBadObjectError;
}

// Real-time: the port calls are lock-free. Without a port (no daemon yet) the speaker's audio is dropped
// and the mic reads silence; a stopped or disconnected daemon stream does the same through the port.
static OSStatus DS5_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo,
                                  void *ioMainBuffer, void *ioSecondaryBuffer) {
    hal_device *d = device_for_stream(inStreamObjectID);
    if (inDriver != g_driver || !d || d->id != inDeviceObjectID) return kAudioHardwareBadObjectError;
    if (!ioMainBuffer) return noErr;
    ds5_port *port = port_acquire();
    if (d->input) {
        if (inOperationID == kAudioServerPlugInIOOperationReadInput)
            ds5_port_mic_read(port, ioMainBuffer, inIOBufferFrameSize);
    } else if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        ds5_port_speaker_write(port, ioMainBuffer, inIOBufferFrameSize,
                               atomic_load_explicit(&g_gain, memory_order_relaxed),
                               atomic_load_explicit(&g_muted, memory_order_relaxed));
    }
    port_release();
    return noErr;
}

static OSStatus DS5_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    return inDriver == g_driver && device_for_id(inDeviceObjectID) ? noErr : kAudioHardwareBadObjectError;
}

#pragma mark Factory

static AudioServerPlugInDriverInterface g_interface = {
    ._reserved = NULL,
    .QueryInterface = DS5_QueryInterface,
    .AddRef = DS5_AddRef,
    .Release = DS5_Release,
    .Initialize = DS5_Initialize,
    .CreateDevice = DS5_CreateDevice,
    .DestroyDevice = DS5_DestroyDevice,
    .AddDeviceClient = DS5_AddDeviceClient,
    .RemoveDeviceClient = DS5_RemoveDeviceClient,
    .PerformDeviceConfigurationChange = DS5_PerformDeviceConfigurationChange,
    .AbortDeviceConfigurationChange = DS5_AbortDeviceConfigurationChange,
    .HasProperty = DS5_HasProperty,
    .IsPropertySettable = DS5_IsPropertySettable,
    .GetPropertyDataSize = DS5_GetPropertyDataSize,
    .GetPropertyData = DS5_GetPropertyData,
    .SetPropertyData = DS5_SetPropertyData,
    .StartIO = DS5_StartIO,
    .StopIO = DS5_StopIO,
    .GetZeroTimeStamp = DS5_GetZeroTimeStamp,
    .WillDoIOOperation = DS5_WillDoIOOperation,
    .BeginIOOperation = DS5_BeginIOOperation,
    .DoIOOperation = DS5_DoIOOperation,
    .EndIOOperation = DS5_EndIOOperation,
};

// CFPlugIn factory named in Info.plist (CFPlugInFactories).
__attribute__((visibility("default"))) void *DualSenseAudio_Create(CFAllocatorRef allocator,
                                                                   CFUUIDRef requestedTypeUUID);

void *DualSenseAudio_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    return requestedTypeUUID && CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID) ? (void *)g_driver : NULL;
}
