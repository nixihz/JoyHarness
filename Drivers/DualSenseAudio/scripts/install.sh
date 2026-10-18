#!/bin/bash
# Installs the DualSense audio driver: the root helper daemon ds5audiod, which owns the controller, and the
# Core Audio HAL plug-in DualSenseAudio.driver, which talks to it. Build first, then run from Terminal:
#   sudo ./scripts/install.sh
set -euo pipefail

readonly LABEL="com.psgrok.DualSenseAudio.helper"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DRIVER_SRC="${repo_root}/build/DualSenseAudio.driver"
readonly DAEMON_SRC="${repo_root}/build/ds5audiod"
readonly PLIST_SRC="${repo_root}/src/daemon/${LABEL}.plist"
readonly HAL_DIR="/Library/Audio/Plug-Ins/HAL"
readonly DRIVER="${HAL_DIR}/DualSenseAudio.driver"
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
for file in "${DRIVER_SRC}/Contents/MacOS/DualSenseAudio" "${DAEMON_SRC}"; do
    if [[ ! -x "${file}" ]]; then
        echo "error: ${file} is missing; build first (see README.md)" >&2
        exit 1
    fi
done
if [[ ! -f "${PLIST_SRC}" ]]; then
    echo "error: ${PLIST_SRC} is missing" >&2
    exit 1
fi

# 1. Stop any running daemon.
bootout_daemon

# 2. Daemon binary and launchd job. install(1) unlinks the old binary first, so its code signature is
#    never overwritten in place.
mkdir -p "${SUPPORT_DIR}"
chown root:wheel "${SUPPORT_DIR}"
chmod 755 "${SUPPORT_DIR}"
install -o root -g wheel -m 755 "${DAEMON_SRC}" "${DAEMON}"
install -o root -g wheel -m 644 "${PLIST_SRC}" "${PLIST}"

# 3. Start the daemon (re-enabling it in case it was disabled with launchctl disable).
launchctl enable "system/${LABEL}"
launchctl bootstrap system "${PLIST}"

# 4. Driver bundle.
mkdir -p "${HAL_DIR}"
rm -rf "${DRIVER}"
ditto "${DRIVER_SRC}" "${DRIVER}"
chown -R root:wheel "${DRIVER}"
find "${DRIVER}" -type d -exec chmod 755 {} +
find "${DRIVER}" -type f -exec chmod 644 {} +
chmod 755 "${DRIVER}/Contents/MacOS/DualSenseAudio"

# 5. coreaudiod loads the new driver.
restart_coreaudiod
echo "Installed ${DAEMON}, ${PLIST} and ${DRIVER}"
