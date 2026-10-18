#include "ds5_helper.h"

#include <os/log.h>
#include <stdlib.h>
#include <string.h>

typedef struct peer {
    struct peer *next;
    xpc_connection_t conn;
    bool superseded; // another peer took over; this connection was cancelled and never becomes active again
    bool speaker;    // this (active) peer started the speaker
    bool mic;        // this (active) peer started the mic
} peer;

struct ds5_helper {
    ds5_helper_ops ops;
    void *shm;
    size_t shm_size;
    dispatch_queue_t queue;
    uid_t allowed[DS5_HELPER_MAX_UIDS];
    size_t n_allowed;
    // Everything below is touched only on `queue`.
    peer *peers;  // every accepted connection until it is invalidated
    peer *active; // the one peer that owns the shared rings: the latest to complete hello; NULL if none
};

static os_log_t helper_log(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      log = os_log_create("com.psgrok.DualSenseAudio", "daemon");
    });
    return log;
}

ds5_helper *ds5_helper_create(const ds5_helper_ops *ops, void *shm, size_t size, dispatch_queue_t queue,
                              const uid_t *allowed_uids, size_t n_allowed) {
    if (!ops || !shm || !queue || n_allowed > DS5_HELPER_MAX_UIDS || (n_allowed && !allowed_uids))
        return NULL;
    ds5_helper *h = calloc(1, sizeof *h);
    if (!h)
        return NULL;
    h->ops = *ops;
    h->shm = shm;
    h->shm_size = size;
    h->queue = queue;
    dispatch_retain(queue);
    if (n_allowed)
        memcpy(h->allowed, allowed_uids, n_allowed * sizeof *allowed_uids);
    h->n_allowed = n_allowed;
    return h;
}

static bool uid_allowed(const ds5_helper *h, uid_t uid) {
    for (size_t i = 0; i < h->n_allowed; i++)
        if (h->allowed[i] == uid)
            return true;
    return false;
}

// MARK: - Sessions. Only the active peer starts anything, so the engine has at most one owner.

static ds5_status peer_speaker_start(ds5_helper *h, peer *p) {
    if (p->speaker)
        return DS5_OK;
    ds5_status s = h->ops.speaker_start(h->ops.ctx);
    p->speaker = s == DS5_OK;
    return s;
}

static void peer_speaker_stop(ds5_helper *h, peer *p) {
    if (!p->speaker)
        return;
    p->speaker = false;
    h->ops.speaker_stop(h->ops.ctx);
}

static ds5_status peer_mic_start(ds5_helper *h, peer *p) {
    if (p->mic)
        return DS5_OK;
    ds5_status s = h->ops.mic_start(h->ops.ctx);
    p->mic = s == DS5_OK;
    return s;
}

static void peer_mic_stop(ds5_helper *h, peer *p) {
    if (!p->mic)
        return;
    p->mic = false;
    h->ops.mic_stop(h->ops.ctx); // closes the mic session and releases exclusive access
}

// Stops whatever the peer started.
static void peer_release(ds5_helper *h, peer *p) {
    peer_mic_stop(h, p);
    peer_speaker_stop(h, p);
}

static bool is_session_op(const char *op) {
    return strcmp(op, DS5_OP_SPEAKER_START) == 0 || strcmp(op, DS5_OP_SPEAKER_STOP) == 0 ||
           strcmp(op, DS5_OP_MIC_START) == 0 || strcmp(op, DS5_OP_MIC_STOP) == 0;
}

// MARK: - Peer events

// The rings are single-producer/single-consumer, so the peer completing hello becomes the only active one: a
// previous active peer (e.g. the plug-in of a coreaudiod that restarted before its connection went away) has its
// sessions stopped and its connection cancelled.
static ds5_status handle_hello(ds5_helper *h, peer *p, xpc_object_t reply) {
    if (p->superseded)
        return DS5_ERR_IO;
    peer *old = h->active;
    if (old && old != p) {
        os_log_info(helper_log(), "peer pid %d takes over from pid %d (cancelled%{public}s%{public}s)",
                    xpc_connection_get_pid(p->conn), xpc_connection_get_pid(old->conn),
                    old->speaker ? "; speaker stopped" : "", old->mic ? "; mic stopped" : "");
        peer_release(h, old);
        old->superseded = true;
        xpc_connection_cancel(old->conn);
    }
    h->active = p;
    if (!reply)
        return DS5_OK;
    xpc_dictionary_set_bool(reply, DS5_XPC_CONNECTED, h->ops.connected(h->ops.ctx));
    xpc_object_t shm = xpc_shmem_create(h->shm, h->shm_size);
    if (!shm) {
        os_log_error(helper_log(), "xpc_shmem_create failed");
        return DS5_ERR_IO;
    }
    xpc_dictionary_set_value(reply, DS5_XPC_SHM, shm);
    xpc_release(shm);
    return DS5_OK;
}

static void handle_message(ds5_helper *h, peer *p, xpc_object_t msg) {
    const char *op = xpc_dictionary_get_string(msg, DS5_XPC_OP);
    xpc_object_t reply = xpc_dictionary_create_reply(msg);
    ds5_status status = DS5_ERR_IO;
    if (!op) {
        os_log_error(helper_log(), "message without an op from pid %d", xpc_connection_get_pid(p->conn));
    } else if (strcmp(op, DS5_OP_HELLO) == 0) {
        status = handle_hello(h, p, reply);
    } else if (!is_session_op(op)) {
        os_log_error(helper_log(), "unknown op \"%{public}s\" from pid %d", op, xpc_connection_get_pid(p->conn));
    } else if (p != h->active) {
        os_log_error(helper_log(), "pid %d: %{public}s refused: not the active peer", xpc_connection_get_pid(p->conn),
                     op);
    } else if (strcmp(op, DS5_OP_SPEAKER_START) == 0) {
        status = peer_speaker_start(h, p);
    } else if (strcmp(op, DS5_OP_SPEAKER_STOP) == 0) {
        peer_speaker_stop(h, p);
        status = DS5_OK;
    } else if (strcmp(op, DS5_OP_MIC_START) == 0) {
        status = peer_mic_start(h, p);
    } else {
        peer_mic_stop(h, p);
        status = DS5_OK;
    }
    if (op)
        os_log_info(helper_log(), "pid %d: %{public}s -> %d", xpc_connection_get_pid(p->conn), op, status);
    if (!reply)
        return;
    xpc_dictionary_set_int64(reply, DS5_XPC_STATUS, status);
    xpc_connection_send_message(p->conn, reply);
    xpc_release(reply);
}

// The connection is invalid: no more events will arrive for it.
static void peer_gone(ds5_helper *h, peer *p) {
    os_log_info(helper_log(), "peer pid %d gone%{public}s%{public}s", xpc_connection_get_pid(p->conn),
                p->speaker ? "; stopping its speaker" : "", p->mic ? "; stopping its mic" : "");
    peer_release(h, p);
    if (h->active == p)
        h->active = NULL;
    for (peer **link = &h->peers; *link; link = &(*link)->next) {
        if (*link == p) {
            *link = p->next;
            break;
        }
    }
    xpc_release(p->conn);
    free(p);
}

static void handle_peer_event(ds5_helper *h, peer *p, xpc_object_t event) {
    xpc_type_t type = xpc_get_type(event);
    if (type == XPC_TYPE_DICTIONARY)
        handle_message(h, p, event);
    else if (event == XPC_ERROR_CONNECTION_INVALID)
        peer_gone(h, p);
}

void ds5_helper_accept(ds5_helper *h, xpc_connection_t conn) {
    uid_t euid = xpc_connection_get_euid(conn);
    pid_t pid = xpc_connection_get_pid(conn);
    peer *p = uid_allowed(h, euid) ? calloc(1, sizeof *p) : NULL;
    if (!p) {
        os_log_error(helper_log(), "rejecting peer pid %d (euid %d)", pid, euid);
        xpc_connection_set_event_handler(conn, ^(xpc_object_t event){
        });
        xpc_connection_activate(conn);
        xpc_connection_cancel(conn);
        return;
    }
    p->conn = xpc_retain(conn);
    p->next = h->peers;
    h->peers = p;
    os_log_info(helper_log(), "accepted peer pid %d (euid %d)", pid, euid);
    xpc_connection_set_target_queue(conn, h->queue);
    xpc_connection_set_event_handler(conn, ^(xpc_object_t event) {
      handle_peer_event(h, p, event);
    });
    xpc_connection_activate(conn);
}

// Only the active peer hears about the controller.
void ds5_helper_presence(ds5_helper *h, bool connected) {
    dispatch_async(h->queue, ^{
      peer *p = h->active;
      if (!p)
          return;
      xpc_object_t msg = xpc_dictionary_create(NULL, NULL, 0);
      xpc_dictionary_set_string(msg, DS5_XPC_OP, DS5_OP_PRESENCE);
      xpc_dictionary_set_bool(msg, DS5_XPC_CONNECTED, connected);
      xpc_connection_send_message(p->conn, msg);
      xpc_release(msg);
    });
}
