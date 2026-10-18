// XPC front-end of the helper daemon (protocol in ds5_shared.h): validates peers, keeps exactly one active peer (the
// latest to complete hello, since the shared rings are single-producer/single-consumer), answers its requests with
// engine calls, stops what it started when it is superseded or goes away, and sends it presence events.
// The engine is reached through an ops table so the tests can drive this file with a fake engine.
#pragma once

#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>
#include <xpc/xpc.h>

#include "ds5_shared.h"

typedef struct {
    ds5_status (*speaker_start)(void *ctx);
    void (*speaker_stop)(void *ctx);
    ds5_status (*mic_start)(void *ctx);
    void (*mic_stop)(void *ctx);
    bool (*connected)(void *ctx);
    void *ctx;
} ds5_helper_ops;

typedef struct ds5_helper ds5_helper;

enum { DS5_HELPER_MAX_UIDS = 4 };

// queue: serial queue that runs every peer event, every engine call and every presence broadcast.
// shm/size: the formatted region handed out in hello replies; it must outlive the helper.
// allowed_uids: effective uids a peer may have (at most DS5_HELPER_MAX_UIDS). NULL on bad arguments.
ds5_helper *ds5_helper_create(const ds5_helper_ops *ops, void *shm, size_t size, dispatch_queue_t queue,
                              const uid_t *allowed_uids, size_t n_allowed);
// Listener event handler for a new peer connection; call on `queue`. Accepts it or cancels it.
void ds5_helper_accept(ds5_helper *h, xpc_connection_t peer);
// Any thread (the engine's presence callback): sends a presence event to the active peer, if any.
void ds5_helper_presence(ds5_helper *h, bool connected);
