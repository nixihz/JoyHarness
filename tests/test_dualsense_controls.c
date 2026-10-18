#include <xpc/xpc.h>
#include <sys/stat.h>
#include <assert.h>
#include <stdio.h>

static uid_t peer_uid = 501, console_uid = 501;
static int console_available = 1, deliveries, cancellations;
static uid_t test_peer_uid(xpc_connection_t peer) { (void)peer; return peer_uid; }
static int test_console(const char *path, struct stat *value) {
    (void)path;
    value->st_uid = console_uid;
    return console_available ? 0 : -1;
}
static void test_send(xpc_connection_t peer, xpc_object_t message) {
    (void)peer; (void)message; deliveries++;
}
static void test_cancel(xpc_connection_t peer) { (void)peer; cancellations++; }

// Exercise the production delivery path with changing console ownership.
#define xpc_connection_get_euid test_peer_uid
#define stat(...) test_console(__VA_ARGS__)
#define xpc_connection_send_message test_send
#define xpc_connection_cancel test_cancel
#include "../Drivers/DualSenseAudio/src/daemon/ds5_controls.c"

int main(void) {
    xpc_connection_t peer = (xpc_connection_t)&peer_uid;
    send_event(peer, NULL, 0, 0);
    assert(deliveries == 1 && cancellations == 0);
    console_uid = 502;
    send_event(peer, NULL, 0, 0);
    assert(deliveries == 1 && cancellations == 1);
    console_available = 0;
    send_event(peer, NULL, 0, 0);
    assert(deliveries == 1 && cancellations == 2);
    peer_uid = 0;
    send_event(peer, NULL, 0, 0);
    assert(deliveries == 2 && cancellations == 2);
    puts("PASS: control deliveries revoke former console users and retain root access");
}
