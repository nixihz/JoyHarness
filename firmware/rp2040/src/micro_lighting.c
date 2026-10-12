#include "micro_lighting.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

// 使用有界 JSON 遍历，防止嵌套对象的 id 被误认作六槽编号。
typedef struct { const char *cursor; const char *end; } reader_t;
typedef struct { const char *begin; const char *end; } slice_t;
typedef struct { uint8_t effect, brightness, speed, magic, r, g, b, known; } light_t;
static light_t slots[6];

static void whitespace(reader_t *reader) {
    while (reader->cursor < reader->end && strchr(" \t\r\n", *reader->cursor)) reader->cursor++;
}

static bool string(reader_t *reader, slice_t *value) {
    whitespace(reader);
    if (reader->cursor == reader->end || *reader->cursor++ != '"') return false;
    value->begin = reader->cursor;
    while (reader->cursor < reader->end) {
        char c = *reader->cursor++;
        if (c == '"') { value->end = reader->cursor - 1; return true; }
        if ((unsigned char)c < 32) return false;
        if (c == '\\') {
            if (reader->cursor == reader->end) return false;
            reader->cursor++;
        }
    }
    return false;
}

static bool equal(slice_t value, const char *text) {
    return (size_t)(value.end - value.begin) == strlen(text) && memcmp(value.begin, text, strlen(text)) == 0;
}

static bool take(reader_t *reader, char c) {
    whitespace(reader);
    if (reader->cursor == reader->end || *reader->cursor != c) return false;
    reader->cursor++;
    return true;
}

static bool skip(reader_t *reader, unsigned depth) {
    whitespace(reader);
    if (depth > 12 || reader->cursor == reader->end) return false;
    char c = *reader->cursor;
    if (c == '"') { slice_t ignored; return string(reader, &ignored); }
    if (c == '{' || c == '[') {
        reader->cursor++;
        char close = c == '{' ? '}' : ']';
        if (take(reader, close)) return true;
        do {
            if (c == '{') { slice_t key; if (!string(reader, &key) || !take(reader, ':')) return false; }
            if (!skip(reader, depth + 1)) return false;
            if (take(reader, close)) return true;
        } while (take(reader, ','));
        return false;
    }
    const char *begin = reader->cursor;
    while (reader->cursor < reader->end && !strchr(",}] \t\r\n", *reader->cursor)) reader->cursor++;
    return reader->cursor > begin;
}

static bool number(slice_t value, double minimum, double maximum, bool integer, double *output) {
    char text[48];
    size_t length = (size_t)(value.end - value.begin);
    if (length == 0 || length >= sizeof(text)) return false;
    memcpy(text, value.begin, length); text[length] = '\0';
    char *end;
    double parsed = strtod(text, &end);
    if (end == text || *end != '\0' || !isfinite(parsed) || parsed < minimum || parsed > maximum || (integer && floor(parsed) != parsed)) return false;
    *output = parsed;
    return true;
}

static bool entry(reader_t *reader, light_t pending[6]) {
    if (!take(reader, '{')) return false;
    int id = -1;
    light_t patch = {0};
    uint8_t fields = 0;
    if (!take(reader, '}')) {
        do {
            slice_t key;
            if (!string(reader, &key) || !take(reader, ':')) return false;
            whitespace(reader);
            slice_t value = {.begin = reader->cursor};
            if (!skip(reader, 0)) return false;
            value.end = reader->cursor;
            double n;
            if (equal(key, "id")) {
                if (!number(value, 0, 5, true, &n)) return false;
                id = (int)n;
            } else if (equal(key, "c")) {
                if (!number(value, 0, 16777215, true, &n)) return false;
                uint32_t color = (uint32_t)n;
                patch.r = (uint8_t)(color >> 16); patch.g = (uint8_t)(color >> 8); patch.b = (uint8_t)color;
                fields |= 1;
            } else if (equal(key, "e")) {
                if (!number(value, 0, 6, true, &n)) return false;
                patch.effect = (uint8_t)n; fields |= 2;
            } else if (equal(key, "b") || equal(key, "s") || equal(key, "m")) {
                if (!number(value, 0, 1, false, &n)) return false;
                uint8_t byte = (uint8_t)(n * 255 + 0.5);
                if (equal(key, "b")) { patch.brightness = byte; fields |= 4; }
                else if (equal(key, "s")) { patch.speed = byte; fields |= 8; }
                else { patch.magic = byte; fields |= 16; }
            }
            if (take(reader, '}')) break;
            if (!take(reader, ',')) return false;
        } while (true);
    }
    if (id < 0) return false;
    light_t *light = &pending[id];
    if (fields & 1) { light->r = patch.r; light->g = patch.g; light->b = patch.b; }
    if (fields & 2) light->effect = patch.effect;
    if (fields & 4) light->brightness = patch.brightness;
    if (fields & 8) light->speed = patch.speed;
    if (fields & 16) light->magic = patch.magic;
    light->known |= fields;
    return true;
}

bool micro_lighting_apply(const char *json, size_t length) {
    reader_t reader = {json, json + length};
    if (!take(&reader, '{')) return false;
    bool method = false, found_params = false;
    slice_t params = {0};
    do {
        slice_t key;
        if (!string(&reader, &key) || !take(&reader, ':')) return false;
        whitespace(&reader);
        slice_t value = {.begin = reader.cursor};
        if (!skip(&reader, 0)) return false;
        value.end = reader.cursor;
        if (equal(key, "method")) method = equal(value, "\"v.oai.thstatus\"");
        if (equal(key, "params")) { params = value; found_params = true; }
        if (take(&reader, '}')) break;
        if (!take(&reader, ',')) return false;
    } while (true);
    whitespace(&reader);
    if (!method || !found_params || reader.cursor != reader.end) return false;
    reader_t array = {params.begin, params.end};
    if (!take(&array, '[')) return false;
    light_t pending[6];
    memcpy(pending, slots, sizeof(slots));
    if (!take(&array, ']')) {
        do {
            if (!entry(&array, pending)) return false;
            if (take(&array, ']')) break;
            if (!take(&array, ',')) return false;
        } while (true);
    }
    whitespace(&array);
    if (array.cursor != array.end) return false;
    // 完整解析后一次提交，坏包不能只更新前半部分槽位。
    memcpy(slots, pending, sizeof(slots));
    return true;
}

void micro_lighting_snapshot(uint8_t payload[63]) {
    memset(payload, 0, 63);
    payload[0] = 'J'; payload[1] = 'H'; payload[2] = 1;
    for (unsigned i = 0; i < 6; i++) {
        const light_t *light = &slots[i];
        if ((light->known & 7) == 7) payload[3] |= (uint8_t)(1U << i);
        uint8_t *record = &payload[5 + i * 7];
        record[0] = light->effect; record[1] = light->brightness; record[2] = light->speed;
        record[3] = light->magic; record[4] = light->r; record[5] = light->g; record[6] = light->b;
    }
}
