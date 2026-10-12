#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "micro_lighting.h"

static bool apply(const char *json) { return micro_lighting_apply(json, strlen(json)); }

int main(void) {
    uint8_t snapshot[63], before[63];
    micro_lighting_snapshot(snapshot);
    assert(snapshot[0] == 'J' && snapshot[1] == 'H' && snapshot[2] == 1 && snapshot[3] == 0);
    assert(apply("{\"id\":92,\"method\":\"v.oai.thstatus\",\"params\":[{\"id\":5,\"c\":65356,\"b\":1,\"e\":1},{\"id\":1,\"c\":3166206,\"e\":4,\"b\":0.5,\"s\":0.25}],\"meta\":{\"id\":0,\"c\":16711731}}"));
    micro_lighting_snapshot(snapshot);
    assert(snapshot[3] == 0x22);
    assert(snapshot[5 + 5 * 7 + 4] == 0 && snapshot[5 + 5 * 7 + 5] == 255 && snapshot[5 + 5 * 7 + 6] == 76);
    assert(snapshot[5 + 1 * 7 + 4] == 48 && snapshot[5 + 1 * 7 + 5] == 79 && snapshot[5 + 1 * 7 + 6] == 254);
    assert(snapshot[5 + 1 * 7 + 1] == 128 && snapshot[5 + 1 * 7 + 2] == 64);
    assert(apply("{ \"method\" : \"v.oai.thstatus\", \"params\" : [{\"id\":5,\"c\":16777215}] }"));
    micro_lighting_snapshot(snapshot);
    assert(snapshot[5 + 5 * 7] == 1 && snapshot[5 + 5 * 7 + 1] == 255);
    assert(snapshot[5 + 5 * 7 + 4] == 255 && snapshot[5 + 5 * 7 + 5] == 255 && snapshot[5 + 5 * 7 + 6] == 255);
    memcpy(before, snapshot, sizeof(before));
    assert(!apply("{\"method\":\"v.oai.thstatus\",\"params\":[{\"id\":5,\"c\":0},{\"id\":6,\"c\":0}]}"));
    micro_lighting_snapshot(snapshot);
    assert(memcmp(snapshot, before, sizeof(snapshot)) == 0);
    assert(!apply("{\"method\":\"v.oai.thstatus\",\"params\":[{\"id\":1,\"b\":1.2}]}"));
    assert(!apply("{\"method\":\"v.oai.thstatus\",\"params\":[{\"id\":1.5,\"c\":0}]}"));
    assert(!apply("{\"method\":\"v.oai.thstatus\",\"params\":[{\"id\":1,\"c\":0}"));
    assert(!apply("{\"method\":\"lights.preview\",\"params\":[{\"id\":1,\"c\":0}]}"));
    assert(apply("{\"method\":\"v.oai.thstatus\",\"params\":[{\"id\":5,\"e\":0}]}"));
    micro_lighting_snapshot(snapshot);
    assert(snapshot[3] == 0x22 && snapshot[5 + 5 * 7] == 0);
    for (unsigned i = 47; i < 63; i++) assert(snapshot[i] == 0);
    puts("firmware lighting contracts passed");
    return 0;
}
