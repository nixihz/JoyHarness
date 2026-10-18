#include "ds5_controls.h"
#include <xpc/xpc.h>
#include <sys/stat.h>
#include <unistd.h>
#include <string.h>
// Separate, read-only endpoint: no audio, shared memory or mic start/stop commands.
static dispatch_queue_t control_queue;
static xpc_connection_t peers[8];
static bool connected, microphone;
static bool peer_is_authorized(xpc_connection_t peer) {
    struct stat console;
    uid_t uid = xpc_connection_get_euid(peer);
    return uid == 0 || (stat("/dev/console", &console) == 0 && uid == console.st_uid);
}
static void send_event(xpc_connection_t peer, const uint8_t *report, size_t length, uint64_t timestamp) {
    // A subscription outlives a login session. Recheck before each delivery;
    // a former console user must not receive the next user's input reports.
    if (!peer_is_authorized(peer)) {
        xpc_connection_cancel(peer);
        return;
    }
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(message, "version", 1);
    xpc_dictionary_set_bool(message, "connected", connected);
    xpc_dictionary_set_bool(message, "microphone", microphone);
    xpc_dictionary_set_uint64(message, "timestamp", timestamp);
    if (report) xpc_dictionary_set_data(message, "report", report, length);
    xpc_connection_send_message(peer, message);
    xpc_release(message);
}
static void broadcast(const uint8_t *report, size_t length, uint64_t timestamp) {
    for (int i = 0; i < 8; i++) if (peers[i]) send_event(peers[i], report, length, timestamp);
}
void ds5_controls_start(dispatch_queue_t queue) {
    control_queue = queue;
    xpc_connection_t listener = xpc_connection_create_mach_service(DS5_CONTROL_SERVICE, queue, XPC_CONNECTION_MACH_SERVICE_LISTENER);
    xpc_connection_set_event_handler(listener, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_CONNECTION) return;
        xpc_connection_t peer = event;
        xpc_connection_set_target_queue(peer, queue);
        xpc_retain(peer);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            if (xpc_get_type(message) == XPC_TYPE_DICTIONARY) {
                if (!peer_is_authorized(peer) ||
                    xpc_dictionary_get_int64(message, "subscribe") != 1) {
                    xpc_connection_cancel(peer); return;
                }
                int slot = -1;
                for (int i = 0; i < 8; i++) { if (peers[i] == peer) { send_event(peer, NULL, 0, 0); return; } if (!peers[i]) slot = i; }
                if (slot < 0) { xpc_connection_cancel(peer); return; }
                peers[slot] = peer;
                send_event(peer, NULL, 0, 0);
            } else if (message == XPC_ERROR_CONNECTION_INVALID) {
                for (int i = 0; i < 8; i++) if (peers[i] == peer) peers[i] = NULL;
                xpc_release(peer);
            }
        });
        xpc_connection_activate(peer);
    });
    xpc_connection_activate(listener);
}
void ds5_controls_report(const uint8_t *report, size_t length, uint64_t timestamp) {
    if (!control_queue || length != 78) return;
    // Input has already passed report subtype, length and CRC validation.
    struct { uint8_t bytes[78]; } copy; memcpy(copy.bytes, report, sizeof copy.bytes);
    dispatch_async(control_queue, ^{ broadcast(copy.bytes, 78, timestamp); });
}
void ds5_controls_presence(bool value) {
    if (control_queue) dispatch_async(control_queue, ^{ connected = value; broadcast(NULL, 0, 0); });
}
void ds5_controls_microphone(bool value) {
    // Input delivery must not wait behind gamepolicyctl or HAL handshakes.
    if (control_queue) dispatch_async(control_queue, ^{ microphone = value; broadcast(NULL, 0, 0); });
}
