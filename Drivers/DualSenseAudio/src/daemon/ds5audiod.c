// ds5audiod: root helper daemon (launchd job com.psgrok.DualSenseAudio.helper) that owns the DualSense.
// coreaudiod's _coreaudiod user may not open HID devices, so the HAL plug-in reaches the engine through this
// daemon: control over XPC (ds5_helper.c), audio through one shared region handed out in hello replies.
#include "ds5_engine.h"
#include "ds5_helper.h"
#include "ds5_shared.h"
#include "ds5_controls.h"
#include "ds5_game_mode.h"

#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <os/log.h>
#include <pwd.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <xpc/xpc.h>

static os_log_t g_log;
static dispatch_queue_t g_queue;
static ds5_engine *g_engine; // set before the listener is activated; used on the helper queue only

static ds5_status op_speaker_start(void *ctx) { return ds5_speaker_start(g_engine); }
static void op_speaker_stop(void *ctx) { ds5_speaker_stop(g_engine); }
static ds5_status op_mic_start(void *ctx) {
    if (!ds5_game_mode_acquire()) {
        os_log_error(g_log, "Game Mode could not be enabled; mic not started");
        return DS5_ERR_IO;
    }
    ds5_controls_microphone(true);
    ds5_status result = ds5_mic_start(g_engine);
    if (result != DS5_OK) { ds5_controls_microphone(false); ds5_game_mode_release(); }
    return result;
}
static void op_mic_stop(void *ctx) {
    ds5_mic_stop(g_engine);
    ds5_controls_microphone(false);
    ds5_game_mode_release();
}
static bool op_connected(void *ctx) { return ds5_engine_connected(g_engine); }

// Engine HID thread: never start or stop anything here; ds5_helper_presence only queues the broadcast.
static void on_presence(void *ctx, bool connected) {
    os_log_info(g_log, "DualSense %{public}s", connected ? "connected" : "disconnected");
    ds5_controls_presence(connected);
    if (!connected) dispatch_async(g_queue, ^{ op_mic_stop(NULL); });
    ds5_helper_presence(ctx, connected);
}

// Runs on the helper queue, so no peer request is in flight: closes the mic session, releases exclusive
// access and stops the speaker, then exits.
static void shutdown_and_exit(int code) {
    ds5_engine_destroy(g_engine);
    ds5_game_mode_release();
    g_engine = NULL;
    os_log_info(g_log, "stopped");
    exit(code);
}

static void fatal(const char *msg) {
    os_log_error(g_log, "%{public}s", msg);
    fprintf(stderr, "ds5audiod: %s\n", msg);
}

static void watch_signal(int sig, dispatch_queue_t queue) {
    signal(sig, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)sig, 0, queue);
    dispatch_source_set_event_handler(src, ^{
      os_log_info(g_log, "signal %d: shutting down", sig);
      shutdown_and_exit(EXIT_SUCCESS);
    });
    dispatch_activate(src);
}

int main(void) {
    g_log = os_log_create("com.psgrok.DualSenseAudio", "daemon");

    size_t size = ds5_shm_size();
    mach_vm_address_t addr = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &addr, size, VM_FLAGS_ANYWHERE);
    if (kr != KERN_SUCCESS || !ds5_shm_format((void *)addr, size)) {
        fatal("cannot allocate the shared audio region");
        return EXIT_FAILURE;
    }

    uid_t allowed[2] = {0};
    size_t n_allowed = 1; // root
    struct passwd *pw = getpwnam("_coreaudiod");
    if (pw)
        allowed[n_allowed++] = pw->pw_uid;
    else
        os_log_error(g_log, "no _coreaudiod user; accepting root peers only");

    dispatch_queue_t queue = dispatch_queue_create("com.psgrok.DualSenseAudio.helper", DISPATCH_QUEUE_SERIAL);
    g_queue = queue;
    ds5_game_mode_recover();
    ds5_controls_start(dispatch_queue_create("tech.keli.joyharness.dualsense.controls", DISPATCH_QUEUE_SERIAL));
    static const ds5_helper_ops ops = {
        .speaker_start = op_speaker_start,
        .speaker_stop = op_speaker_stop,
        .mic_start = op_mic_start,
        .mic_stop = op_mic_stop,
        .connected = op_connected,
    };
    ds5_helper *helper = ds5_helper_create(&ops, (void *)addr, size, queue, allowed, n_allowed);
    if (!helper) {
        fatal("cannot create the XPC front-end");
        return EXIT_FAILURE;
    }
    g_engine = ds5_engine_create_shared(on_presence, helper, (void *)addr, size);
    if (!g_engine) {
        fatal("cannot start the audio engine");
        return EXIT_FAILURE;
    }

    ds5_engine_set_control_observer(g_engine, ds5_controls_report);
    dispatch_source_t recovery = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(recovery, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(recovery, ^{
        ds5_stats stats; ds5_engine_get_stats(g_engine, &stats);
        if (!stats.mic_running) ds5_game_mode_recover();
    });
    dispatch_activate(recovery);
    watch_signal(SIGTERM, queue);
    watch_signal(SIGINT, queue);

    xpc_connection_t listener =
        xpc_connection_create_mach_service(DS5_HELPER_MACH_SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
      if (xpc_get_type(event) == XPC_TYPE_CONNECTION) {
          ds5_helper_accept(helper, event);
      } else if (event == XPC_ERROR_CONNECTION_INVALID) {
          fatal("cannot listen on " DS5_HELPER_MACH_SERVICE " (the daemon must be started by launchd)");
          shutdown_and_exit(EXIT_FAILURE);
      }
    });
    xpc_connection_activate(listener);
    os_log_info(g_log, "started (mach service %{public}s); DualSense %{public}s", DS5_HELPER_MACH_SERVICE,
                ds5_engine_connected(g_engine) ? "connected" : "not connected");
    dispatch_main();
}
