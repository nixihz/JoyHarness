#include "DualSenseControlClient.h"
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
struct JHDSControlClient {
    xpc_connection_t connection;
    dispatch_queue_t queue;
    dispatch_source_t timer;
    void *context;
    JHDSControlHandler handler;
    _Atomic bool stopped;
};
static void connect_service(JHDSControlClient *c) {
    if (c->connection || atomic_load(&c->stopped)) return;
    xpc_connection_t connection = xpc_connection_create_mach_service(
        "tech.keli.joyharness.dualsense.controls", c->queue,
        XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    c->connection = connection;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t message) {
        if (atomic_load(&c->stopped) || c->connection != connection) return;
        bool available = xpc_get_type(message) == XPC_TYPE_DICTIONARY &&
            xpc_connection_get_euid(connection) == 0 && xpc_dictionary_get_int64(message, "version") == 1;
        bool connected = available && xpc_dictionary_get_bool(message, "connected");
        bool microphone = available && xpc_dictionary_get_bool(message, "microphone");
        size_t length = 0;
        const void *bytes = available ? xpc_dictionary_get_data(message, "report", &length) : NULL;
        struct { uint8_t bytes[78]; } copy = {0};
        if (bytes && length == 78) memcpy(copy.bytes, bytes, 78); else length = 0;
        uint64_t timestamp = available ? xpc_dictionary_get_uint64(message, "timestamp") : 0;
        if (message == XPC_ERROR_CONNECTION_INVALID) {
            // An absent service creates a permanently invalid connection. The
            // next timer tick must create a fresh one (also covers upgrades).
            c->connection = NULL;
            xpc_release(connection);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!atomic_load(&c->stopped)) c->handler(c->context, available, connected, microphone,
                                                     length ? copy.bytes : NULL, length, timestamp);
        });
    });
    xpc_connection_activate(connection);
}
static void subscribe(JHDSControlClient *c) {
    if (atomic_load(&c->stopped)) return;
    connect_service(c);
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_int64(message, "subscribe", 1);
    xpc_connection_send_message(c->connection, message);
    xpc_release(message);
}
JHDSControlClient *JHDSControlClientCreate(void *context, JHDSControlHandler handler) {
    JHDSControlClient *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    atomic_init(&c->stopped, false);
    c->context = context; c->handler = handler;
    c->queue = dispatch_queue_create("tech.keli.joyharness.dualsense.controls.client", DISPATCH_QUEUE_SERIAL);
    c->timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, c->queue);
    dispatch_source_set_timer(c->timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(c->timer, ^{ subscribe(c); });
    dispatch_activate(c->timer);
    return c;
}
void JHDSControlClientStop(JHDSControlClient *c) {
    if (!c || atomic_exchange(&c->stopped, true)) return;
    dispatch_source_cancel(c->timer);
    dispatch_async(c->queue, ^{
        if (c->connection) {
            xpc_connection_cancel(c->connection);
            xpc_release(c->connection);
            c->connection = NULL;
        }
    });
    // The runtime owns one handle for its process lifetime. Keeping it alive
    // also makes already queued main-thread deliveries safe during shutdown.
}
