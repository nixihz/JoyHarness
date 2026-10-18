#!/bin/bash
# Removes the DualSense audio driver: the HAL plug-in first (restarting coreaudiod), then the helper daemon.
#   sudo ./scripts/uninstall.sh
set -euo pipefail

readonly LABEL="com.psgrok.DualSenseAudio.helper"
readonly DRIVER="/Library/Audio/Plug-Ins/HAL/DualSenseAudio.driver"
readonly SUPPORT_DIR="/Library/Application Support/DualSenseAudio"
readonly DAEMON="${SUPPORT_DIR}/ds5audiod"
readonly PLIST="/Library/LaunchDaemons/${LABEL}.plist"

restart_coreaudiod() {
    if launchctl kickstart -k system/com.apple.audio.coreaudiod 2>/dev/null; then
        return
    fi
    if ! killall coreaudiod 2>/dev/null; then
        echo "warning: could not restart coreaudiod; log out and back in, or reboot" >&2
    fi
}

# Unloads the helper daemon if launchd has it, and waits until it is gone (SIGTERM makes it close the mic
# session and release the controller).
bootout_daemon() {
    launchctl print "system/${LABEL}" >/dev/null 2>&1 || return 0
    launchctl bootout "system/${LABEL}" 2>/dev/null || true
    for _ in {1..150}; do
        launchctl print "system/${LABEL}" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
    echo "error: launchd did not unload ${LABEL}" >&2
    exit 1
}

if [[ ${EUID} -ne 0 ]]; then
    echo "error: must run as root: sudo $0" >&2
    exit 1
fi

# 1. Driver; restarting coreaudiod unloads it, which ends its sessions with the daemon.
rm -rf "${DRIVER}"
restart_coreaudiod

# 2. Daemon.
bootout_daemon
rm -f "${PLIST}" "${DAEMON}"
if [[ -d "${SUPPORT_DIR}" ]] && ! rmdir "${SUPPORT_DIR}" 2>/dev/null; then
    echo "note: ${SUPPORT_DIR} is not empty; left in place" >&2
fi
echo "Uninstalled the DualSense audio driver and helper daemon"
