#pragma once
#include <stdbool.h>
typedef enum { DS5_POLICY_UNKNOWN, DS5_POLICY_AUTO, DS5_POLICY_ON, DS5_POLICY_OFF } ds5_game_policy;
ds5_game_policy ds5_game_policy_parse(const char *text);
bool ds5_game_mode_acquire(void);
void ds5_game_mode_release(void);
// Recovers a persisted lease after a helper crash, and retries failed restoration.
void ds5_game_mode_recover(void);
