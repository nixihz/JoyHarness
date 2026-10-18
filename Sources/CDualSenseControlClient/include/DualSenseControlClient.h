#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
typedef struct JHDSControlClient JHDSControlClient;
// Always called on the main queue. available=false also invalidates any held gesture.
typedef void (*JHDSControlHandler)(void *context, bool available, bool connected, bool microphone,
                                  const uint8_t *report, size_t length, uint64_t timestamp);
JHDSControlClient *JHDSControlClientCreate(void *context, JHDSControlHandler handler);
// Permanently cancels delivery; create a new handle to start again.
// Service restarts are retried automatically while this handle is running.
void JHDSControlClientStop(JHDSControlClient *client);
