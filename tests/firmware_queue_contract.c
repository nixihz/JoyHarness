#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "transport_queue.h"

static void test_cross_packet_text_round_trips(void) {
    transport_queue_t queue;
    transport_queue_init(&queue);
    char text[63];
    memset(text, 'A', 62);
    text[62] = '\0';

    assert(transport_queue_enqueue_text(&queue, text));
    assert(transport_queue_count(&queue) == 2);
    const hid_packet_t *first = transport_queue_peek(&queue);
    assert(first != NULL);
    assert(first->bytes[0] == TRANSPORT_CHANNEL_RPC);
    assert(first->bytes[1] == TRANSPORT_HID_PAYLOAD_SIZE);
    transport_queue_pop(&queue);
    const hid_packet_t *second = transport_queue_peek(&queue);
    assert(second != NULL);
    assert(second->bytes[1] == 1);
    assert(second->bytes[2] == 'A');
}

static void test_message_is_rejected_atomically_when_capacity_is_insufficient(void) {
    transport_queue_t queue;
    transport_queue_init(&queue);
    for (size_t index = 0; index < TRANSPORT_TX_CAPACITY - 1; index++) {
        char text[2] = {(char)('A' + (index % 26)), '\0'};
        assert(transport_queue_enqueue_text(&queue, text));
    }
    assert(transport_queue_count(&queue) == TRANSPORT_TX_CAPACITY - 1);

    char two_packets[63];
    memset(two_packets, 'Z', 62);
    two_packets[62] = '\0';
    assert(!transport_queue_enqueue_text(&queue, two_packets));
    assert(transport_queue_count(&queue) == TRANSPORT_TX_CAPACITY - 1);

    for (size_t index = 0; index < TRANSPORT_TX_CAPACITY - 1; index++) {
        const hid_packet_t *packet = transport_queue_peek(&queue);
        assert(packet != NULL);
        assert(packet->bytes[1] == 1);
        assert(packet->bytes[2] == (uint8_t)('A' + (index % 26)));
        transport_queue_pop(&queue);
    }
    assert(transport_queue_count(&queue) == 0);
}

static void test_full_capacity_and_oversized_messages_are_atomic(void) {
    transport_queue_t queue;
    transport_queue_init(&queue);
    char full_capacity[TRANSPORT_TX_CAPACITY * TRANSPORT_HID_PAYLOAD_SIZE + 1];
    memset(full_capacity, 'F', sizeof(full_capacity) - 1);
    full_capacity[sizeof(full_capacity) - 1] = '\0';
    assert(transport_queue_enqueue_text(&queue, full_capacity));
    assert(transport_queue_count(&queue) == TRANSPORT_TX_CAPACITY);

    assert(!transport_queue_enqueue_text(&queue, "x"));
    assert(queue.rejected_messages == 1);
    assert(transport_queue_count(&queue) == TRANSPORT_TX_CAPACITY);

    transport_queue_init(&queue);
    char oversized[TRANSPORT_TX_CAPACITY * TRANSPORT_HID_PAYLOAD_SIZE + 2];
    memset(oversized, 'O', sizeof(oversized) - 1);
    oversized[sizeof(oversized) - 1] = '\0';
    assert(!transport_queue_enqueue_text(&queue, oversized));
    assert(queue.rejected_messages == 1);
    assert(transport_queue_count(&queue) == 0);
}

int main(void) {
    test_cross_packet_text_round_trips();
    test_message_is_rejected_atomically_when_capacity_is_insufficient();
    test_full_capacity_and_oversized_messages_are_atomic();
    puts("firmware queue contracts passed");
    return 0;
}
