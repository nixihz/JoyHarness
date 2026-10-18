#pragma once
#include <dispatch/dispatch.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#define DS5_CONTROL_SERVICE "tech.keli.joyharness.dualsense.controls"
void ds5_controls_start(dispatch_queue_t queue);
void ds5_controls_report(const uint8_t *report, size_t length, uint64_t timestamp);
void ds5_controls_presence(bool connected);
void ds5_controls_microphone(bool active);
