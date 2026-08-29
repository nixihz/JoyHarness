#ifndef JOY_HARNESS_TRANSPORT_QUEUE_H
#define JOY_HARNESS_TRANSPORT_QUEUE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define TRANSPORT_CHANNEL_RPC 2
#define TRANSPORT_HID_PAYLOAD_SIZE 61
#define TRANSPORT_TX_QUEUE_SIZE 32
#define TRANSPORT_TX_CAPACITY (TRANSPORT_TX_QUEUE_SIZE - 1)

typedef struct {
    uint8_t bytes[63];
} hid_packet_t;

typedef struct {
    hid_packet_t packets[TRANSPORT_TX_QUEUE_SIZE];
    uint8_t head;
    uint8_t tail;
    uint32_t rejected_messages;
} transport_queue_t;

void transport_queue_init(transport_queue_t *queue);
size_t transport_queue_count(const transport_queue_t *queue);
bool transport_queue_enqueue_text(transport_queue_t *queue, const char *text);
const hid_packet_t *transport_queue_peek(const transport_queue_t *queue);
bool transport_queue_pop(transport_queue_t *queue);

#endif
