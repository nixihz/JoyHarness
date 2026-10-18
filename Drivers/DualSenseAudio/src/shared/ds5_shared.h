// Shared contract between the HAL plug-in (runs as _coreaudiod inside coreaudiod's sandboxed driver host) and the
// root helper daemon ds5audiod (owns the DualSense HID device; _coreaudiod is not allowed to open HID devices:
// IOHIDDeviceOpen returns kIOReturnNotPrivileged there).
//
// Transport:
//   - Control: XPC over the mach service DS5_HELPER_MACH_SERVICE (declared in the plug-in Info.plist under
//     AudioServerPlugIn_MachServices and in the daemon's launchd plist under MachServices).
//   - Audio: one shared memory region created and formatted by the daemon, handed to the plug-in as an xpc_shmem
//     object in the "hello" reply. It holds two lock-free SPSC rings plus control fields, all position-independent.
//
// XPC messages are dictionaries with a string under DS5_XPC_OP.
//   plug-in -> daemon (each expects a reply dictionary):
//     "hello"          reply: DS5_XPC_SHM (xpc_shmem), DS5_XPC_CONNECTED (bool), DS5_XPC_STATUS (int64)
//     "speaker_start"  reply: DS5_XPC_STATUS (int64, a ds5_status)
//     "speaker_stop"   reply: DS5_XPC_STATUS
//     "mic_start"      reply: DS5_XPC_STATUS (DS5_ERR_EXCLUSIVE => the mic was not opened)
//     "mic_stop"       reply: DS5_XPC_STATUS
//   daemon -> plug-in (no reply):
//     "presence"       DS5_XPC_CONNECTED (bool)
//   The daemon only accepts peers whose effective uid is _coreaudiod's or root's. One peer is active at a time: the
//   latest to complete hello. A newer hello stops whatever the previous active peer started (mic: close session,
//   release exclusive access) and cancels its connection (that client sees XPC_ERROR_CONNECTION_INTERRUPTED; its
//   next message arrives as a new, non-active peer). Start/stop requests from a non-active peer get DS5_ERR_IO and
//   change nothing; presence events go only to the active peer. When the active peer's connection is invalidated,
//   the daemon stops whatever it started.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "ds5_engine.h" // ds5_status

#ifdef __cplusplus
extern "C" {
#endif

#define DS5_HELPER_MACH_SERVICE "com.psgrok.DualSenseAudio.helper"

#define DS5_XPC_OP "op"
#define DS5_XPC_STATUS "status"
#define DS5_XPC_CONNECTED "connected"
#define DS5_XPC_SHM "shm"

#define DS5_OP_HELLO "hello"
#define DS5_OP_SPEAKER_START "speaker_start"
#define DS5_OP_SPEAKER_STOP "speaker_stop"
#define DS5_OP_MIC_START "mic_start"
#define DS5_OP_MIC_STOP "mic_stop"
#define DS5_OP_PRESENCE "presence"

// ---- Shared memory region -------------------------------------------------------------------------------------
// Byte size of the region (a multiple of the VM page size). Allocate with mmap/mach_vm_allocate, page-aligned.
size_t ds5_shm_size(void);
// Daemon (or an in-process engine): initialize a zeroed region of ds5_shm_size() bytes. Returns false on bad size.
bool ds5_shm_format(void *mem, size_t size);
// Plug-in: validate a mapped region (magic, version, size) before attaching.
bool ds5_shm_check(const void *mem, size_t size);

// ---- Plug-in side real-time port --------------------------------------------------------------------------------
// A process-local view over a formatted region. attach/detach allocate and are NOT real-time safe.
// The region must stay mapped until after ds5_port_detach.
typedef struct ds5_port ds5_port;
ds5_port *ds5_port_attach(void *mem, size_t size); // NULL if ds5_shm_check fails
void ds5_port_detach(ds5_port *p);

// Real-time safe (no locks, allocation, logging or syscalls). One writer thread and one reader thread.
// Speaker: interleaved stereo float32 @ 48 kHz -> mono downmix (L+R)/2 * gain (0 when muted) -> +6 dB makeup gain
// through a tanh soft limiter -> speaker ring.
void ds5_port_speaker_write(ds5_port *p, const float *stereo, uint32_t frames, float gain, bool mute);
// Mic: copies up to `frames` mono samples; zero-fills the shortfall; applies the 1920-frame prebuffer after each
// new mic session or underrun. Returns the number of frames that carried audio.
uint32_t ds5_port_mic_read(ds5_port *p, float *mono, uint32_t frames);

#ifdef __cplusplus
}
#endif
