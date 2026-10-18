#include "ds5_game_mode.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <os/log.h>

#ifndef TOOL
#define TOOL "/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl"
#endif
#ifndef JOURNAL
#define JOURNAL "/Library/Application Support/DualSenseAudio/game-mode-lease"
#endif
#ifndef JOURNAL_OWNER
#define JOURNAL_OWNER 0
#endif
extern char **environ;
static ds5_game_policy previous;
static bool leased;

ds5_game_policy ds5_game_policy_parse(const char *text) {
    if (strstr(text, "policy is currently automatic")) return DS5_POLICY_AUTO;
    if (strstr(text, "forced always on")) return DS5_POLICY_ON;
    if (strstr(text, "forced always off")) return DS5_POLICY_OFF;
    return DS5_POLICY_UNKNOWN;
}

static bool command(const char *mode, char *output, size_t capacity) {
    int fds[2];
    if (pipe(fds)) return false;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    char *args[] = {TOOL, "game-mode", mode ? "set" : "status", (char *)mode, NULL};
    pid_t pid = 0;
    int error = posix_spawn(&pid, TOOL, &actions, NULL, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    if (error) { close(fds[0]); return false; }
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    size_t used = 0;
    int status = 0;
    bool exited = false;
    for (int i = 0; i < 200; i++) {
        char buffer[1024];
        ssize_t n;
        while ((n = read(fds[0], buffer, sizeof buffer)) > 0) {
            size_t take = (size_t)n < capacity - 1 - used ? (size_t)n : capacity - 1 - used;
            memcpy(output + used, buffer, take); used += take;
        }
        pid_t got = waitpid(pid, &status, WNOHANG);
        if (got == pid) { exited = true; break; }
        if (got < 0 && errno != EINTR) break;
        usleep(10000);
    }
    if (!exited) { kill(pid, SIGKILL); waitpid(pid, &status, 0); }
    ssize_t tail;
    while (used < capacity - 1 && (tail = read(fds[0], output + used, capacity - 1 - used)) > 0) used += (size_t)tail;
    close(fds[0]); output[used] = 0;
    return exited && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}
static ds5_game_policy policy(void) {
    char output[4096];
    return command(NULL, output, sizeof output) ? ds5_game_policy_parse(output) : DS5_POLICY_UNKNOWN;
}
static bool set_policy(ds5_game_policy p) {
    const char *mode = p == DS5_POLICY_AUTO ? "auto" : p == DS5_POLICY_ON ? "on" : "off";
    char output[4096];
    return command(mode, output, sizeof output) && policy() == p;
}
static bool save_policy(ds5_game_policy p) {
    int fd = open(JOURNAL, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    char value = '0' + p;
    bool ok = write(fd, &value, 1) == 1 && fsync(fd) == 0;
    close(fd); return ok;
}
void ds5_game_mode_release(void) {
    if (!leased) return;
    ds5_game_policy current = policy();
    // Respect a user's explicit policy change during recording.
    if (current == DS5_POLICY_UNKNOWN || (current == DS5_POLICY_ON && !set_policy(previous))) {
        os_log_error(OS_LOG_DEFAULT, "DualSense: Game Mode restoration failed; will retry");
        return;
    }
    leased = false; previous = DS5_POLICY_UNKNOWN;
    unlink(JOURNAL);
}
void ds5_game_mode_recover(void) {
    if (!leased) {
        int fd = open(JOURNAL, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        if (fd < 0) return;
        char value = 0; struct stat st;
        bool ok = !fstat(fd, &st) && st.st_uid == JOURNAL_OWNER && S_ISREG(st.st_mode) && read(fd, &value, 1) == 1;
        close(fd);
        if (!ok || (value != '1' && value != '2' && value != '3')) return;
        previous = (ds5_game_policy)(value - '0'); leased = true;
    }
    ds5_game_mode_release();
}
bool ds5_game_mode_acquire(void) {
    if (leased) return true;
    previous = policy();
    if (previous == DS5_POLICY_UNKNOWN) return false;
    // A pre-existing forced-on setting belongs to its owner; never undo it.
    if (previous == DS5_POLICY_ON) return true;
    if (!save_policy(previous)) return false;
    leased = true;
    if (set_policy(DS5_POLICY_ON)) return true;
    ds5_game_mode_release();
    return false;
}
