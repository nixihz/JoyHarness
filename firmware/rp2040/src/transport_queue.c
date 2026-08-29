#include "transport_queue.h"

#include <string.h>

void transport_queue_init(transport_queue_t *queue) {
    memset(queue, 0, sizeof(*queue));
}

size_t transport_queue_count(const transport_queue_t *queue) {
    return (queue->head + TRANSPORT_TX_QUEUE_SIZE - queue->tail) %
           TRANSPORT_TX_QUEUE_SIZE;
}

bool transport_queue_enqueue_text(transport_queue_t *queue, const char *text) {
    size_t length = strlen(text);
    size_t needed = length / TRANSPORT_HID_PAYLOAD_SIZE;
    if (length % TRANSPORT_HID_PAYLOAD_SIZE != 0) needed++;
    size_t available = TRANSPORT_TX_CAPACITY - transport_queue_count(queue);
    if (needed > available) {
        queue->rejected_messages++;
        return false;
    }

    size_t offset = 0;
    while (offset < length) {
        size_t chunk = length - offset;
        if (chunk > TRANSPORT_HID_PAYLOAD_SIZE) chunk = TRANSPORT_HID_PAYLOAD_SIZE;
        hid_packet_t *packet = &queue->packets[queue->head];
        memset(packet, 0, sizeof(*packet));
        packet->bytes[0] = TRANSPORT_CHANNEL_RPC;
        packet->bytes[1] = (uint8_t)chunk;
        memcpy(packet->bytes + 2, text + offset, chunk);
        queue->head = (uint8_t)((queue->head + 1) % TRANSPORT_TX_QUEUE_SIZE);
        offset += chunk;
    }
    return true;
}

const hid_packet_t *transport_queue_peek(const transport_queue_t *queue) {
    if (queue->tail == queue->head) return NULL;
    return &queue->packets[queue->tail];
}

bool transport_queue_pop(transport_queue_t *queue) {
    if (queue->tail == queue->head) return false;
    queue->tail = (uint8_t)((queue->tail + 1) % TRANSPORT_TX_QUEUE_SIZE);
    return true;
}
