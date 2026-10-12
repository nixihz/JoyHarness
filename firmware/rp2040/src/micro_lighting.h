#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool micro_lighting_apply(const char *json, size_t length);
void micro_lighting_snapshot(uint8_t payload[63]);
