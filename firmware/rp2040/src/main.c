#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bsp/board_api.h"
#include "pico/stdlib.h"
#include "transport_queue.h"
#include "tusb.h"

#define REPORT_ID 6
#define RPC_BUFFER_SIZE 4096
#define CDC_LINE_SIZE 128

static transport_queue_t tx_queue;
static char rpc_buffer[RPC_BUFFER_SIZE];
static size_t rpc_length;
static char cdc_line[CDC_LINE_SIZE];
static size_t cdc_length;

static void flush_hid(void) {
    const hid_packet_t *packet = transport_queue_peek(&tx_queue);
    if (packet == NULL || !tud_hid_ready()) return;
    if (tud_hid_report(REPORT_ID, packet->bytes, sizeof(packet->bytes))) {
        transport_queue_pop(&tx_queue);
    }
}

static bool json_complete(const char *json, size_t length) {
    int depth = 0;
    bool in_string = false;
    bool escaped = false;
    bool started = false;
    for (size_t i = 0; i < length; i++) {
        char c = json[i];
        if (in_string) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') in_string = true;
        else if (c == '{' || c == '[') {
            depth++;
            started = true;
        } else if (c == '}' || c == ']') {
            depth--;
        }
    }
    return started && depth == 0 && !in_string;
}

static int parse_id(const char *json) {
    int depth = 0;
    for (size_t i = 0; json[i] != '\0'; i++) {
        if (json[i] == '{' || json[i] == '[') {
            depth++;
            continue;
        }
        if (json[i] == '}' || json[i] == ']') {
            depth--;
            continue;
        }
        if (json[i] != '"') continue;

        size_t start = ++i;
        bool escaped = false;
        while (json[i] != '\0') {
            if (escaped) {
                escaped = false;
            } else if (json[i] == '\\') {
                escaped = true;
            } else if (json[i] == '"') {
                break;
            }
            i++;
        }

        if (depth != 1 || i - start != 2 ||
            json[start] != 'i' || json[start + 1] != 'd') {
            continue;
        }

        const char *value = json + i + 1;
        while (*value == ' ' || *value == '\t' ||
               *value == '\r' || *value == '\n') {
            value++;
        }
        if (*value++ != ':') continue;
        while (*value == ' ' || *value == '\t' ||
               *value == '\r' || *value == '\n') {
            value++;
        }

        char *end = NULL;
        long id = strtol(value, &end, 10);
        return end != value ? (int)id : -1;
    }
    return -1;
}

static bool has_method(const char *json, const char *method) {
    char needle[96];
    snprintf(needle, sizeof(needle), "\"method\":\"%s\"", method);
    return strstr(json, needle) != NULL;
}

static void reply_to_rpc(const char *json) {
    int id = parse_id(json);
    if (id < 0) return;
    char response[256];
    if (has_method(json, "device.status")) {
        snprintf(response, sizeof(response),
                 "{\"id\":%d,\"result\":{\"version\":\"0.1.0-agentdeck\",\"profile_index\":0,\"layer_index\":0}}\n",
                 id);
    } else if (has_method(json, "sys.version")) {
        snprintf(response, sizeof(response),
                 "{\"id\":%d,\"result\":{\"version\":\"0.1.0-agentdeck\"}}\n", id);
    } else if (has_method(json, "v.oai.rgbcfg") ||
               has_method(json, "v.oai.thstatus") ||
               has_method(json, "lights.preview")) {
        snprintf(response, sizeof(response), "{\"id\":%d,\"result\":null}\n", id);
    } else {
        snprintf(response, sizeof(response),
                 "{\"id\":%d,\"error\":{\"code\":-32601,\"message\":\"Method not implemented\"}}\n",
                 id);
    }
    (void)transport_queue_enqueue_text(&tx_queue, response);
}

static void consume_rpc_chunk(const uint8_t *buffer, uint16_t size) {
    if (size < 2 || buffer[0] != TRANSPORT_CHANNEL_RPC) return;
    size_t payload_length = buffer[1];
    if (payload_length > size - 2) payload_length = size - 2;
    if (rpc_length + payload_length >= sizeof(rpc_buffer)) {
        rpc_length = 0;
        return;
    }
    memcpy(rpc_buffer + rpc_length, buffer + 2, payload_length);
    rpc_length += payload_length;
    rpc_buffer[rpc_length] = '\0';
    if (json_complete(rpc_buffer, rpc_length)) {
        reply_to_rpc(rpc_buffer);
        rpc_length = 0;
    }
}

static void notify_key(const char *key, int action, int agent) {
    char json[160];
    if (agent >= 0) {
        snprintf(json, sizeof(json),
                 "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"%s\",\"act\":%d,\"ag\":%d}}\n",
                 key, action, agent);
    } else {
        snprintf(json, sizeof(json),
                 "{\"method\":\"v.oai.hid\",\"params\":{\"k\":\"%s\",\"act\":%d}}\n",
                 key, action);
    }
    (void)transport_queue_enqueue_text(&tx_queue, json);
}

static void notify_joystick(int angle, int distance) {
    char json[144];
    snprintf(json, sizeof(json),
             "{\"method\":\"v.oai.rad\",\"params\":{\"a\":%.3f,\"d\":%.3f}}\n",
             angle / 1000.0, distance / 1000.0);
    (void)transport_queue_enqueue_text(&tx_queue, json);
}

static void handle_cdc_line(char *line) {
    char key[24];
    int action;
    int agent;
    int angle;
    int distance;
    if (sscanf(line, "H %23s %d %d", key, &action, &agent) == 3) {
        notify_key(key, action, agent);
    } else if (sscanf(line, "J %d %d", &angle, &distance) == 2) {
        if (angle < 0) angle = 0;
        if (angle > 1000) angle = 1000;
        if (distance < 0) distance = 0;
        if (distance > 1000) distance = 1000;
        notify_joystick(angle, distance);
    } else if (strcmp(line, "P") == 0) {
        tud_cdc_write_str("READY agentdeck-rp2040 0.1.0\n");
        tud_cdc_write_flush();
    }
}

static void read_cdc(void) {
    while (tud_cdc_available()) {
        char c = (char)tud_cdc_read_char();
        if (c == '\n' || c == '\r') {
            if (cdc_length > 0) {
                cdc_line[cdc_length] = '\0';
                handle_cdc_line(cdc_line);
                cdc_length = 0;
            }
        } else if (cdc_length + 1 < sizeof(cdc_line)) {
            cdc_line[cdc_length++] = c;
        } else {
            cdc_length = 0;
        }
    }
}

int main(void) {
    board_init();
    tusb_init();
    transport_queue_init(&tx_queue);
    while (true) {
        tud_task();
        read_cdc();
        flush_hid();
    }
}

uint16_t tud_hid_get_report_cb(uint8_t instance, uint8_t report_id,
                               hid_report_type_t report_type, uint8_t *buffer,
                               uint16_t requested_length) {
    (void)instance;
    (void)report_id;
    (void)report_type;
    (void)buffer;
    (void)requested_length;
    return 0;
}

void tud_hid_set_report_cb(uint8_t instance, uint8_t report_id,
                           hid_report_type_t report_type, const uint8_t *buffer,
                           uint16_t buffer_size) {
    (void)instance;
    (void)report_type;
    if (report_id == REPORT_ID) consume_rpc_chunk(buffer, buffer_size);
}
