#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio callbacks require lock-free 64-bit atomics");

// A user-space HAL loopback: the app writes stereo Float32, dictation clients
// read the same clocked frames. No networking, disk audio, or kernel extension.
enum { Plugin = kAudioObjectPlugInObject, Device = 2, Input = 3, Output = 4,
       DualSenseDevice = 5, DualSenseInput = 6, DualSenseOutput = 7,
       // AudioServerPlugIn requires at least 10923 frames between zero time
       // stamps. This clock quantum is independent of the host's I/O size.
       Rate = 48000, Period = 16384, RingFrames = 65536,
       FlushProperty = 0x6a68666c }; // 'jhfl', global/main, CFNumber in a CFPropertyListRef.

typedef struct {
    AudioObjectID device, input, output;
    _Atomic uint64_t samples[RingFrames], stamps[RingFrames];
    _Atomic uint64_t epochs[RingFrames], writtenAt[RingFrames];
    _Atomic uint32_t clients;
    _Atomic uint64_t anchor, clockSeed, epoch;
} MicrophoneDevice;

static MicrophoneDevice devices[] = {
    {.device = Device, .input = Input, .output = Output, .clockSeed = 1, .epoch = 1},
};
static _Atomic uint32_t references = 1;
static double ticksPerFrame;
static uint64_t maximumFrameAge;
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer = &interface;
static AudioServerPlugInDriverRef driver = &interfacePointer;

static MicrophoneDevice *deviceForObject(AudioObjectID object) {
    for (size_t i = 0; i < sizeof(devices) / sizeof(devices[0]); i++) {
        MicrophoneDevice *device = &devices[i];
        if (object == device->device || object == device->input || object == device->output) return device;
    }
    return NULL;
}

static MicrophoneDevice *deviceForID(AudioObjectID object) {
    MicrophoneDevice *device = deviceForObject(object);
    return device && device->device == object ? device : NULL;
}

static CFStringRef deviceUID(const MicrophoneDevice *device) {
    return device->device == Device ? CFSTR("tech.keli.joyharness.microphone.device")
        : CFSTR("tech.keli.joyharness.dualsense.microphone.device");
}

static void invalidate(MicrophoneDevice *device) {
    // Do not reset the clock or stop consumers. An in-flight writer retains
    // its old epoch, so a flush also invalidates writes that finish afterward.
    atomic_fetch_add_explicit(&device->epoch, 1, memory_order_acq_rel);
}

static AudioStreamBasicDescription format(void) {
    return (AudioStreamBasicDescription) {
        .mSampleRate = Rate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked,
        .mBytesPerPacket = 8, .mFramesPerPacket = 1, .mBytesPerFrame = 8,
        .mChannelsPerFrame = 2, .mBitsPerChannel = 32,
    };
}

static OSStatus copyValue(const void *value, UInt32 bytes, UInt32 capacity, UInt32 *size, void *output) {
    if (!size) return kAudioHardwareIllegalOperationError;
    *size = bytes;
    if (!output) return noErr; // GetPropertyDataSize
    if (capacity < bytes) return kAudioHardwareBadPropertySizeError;
    if (bytes) memcpy(output, value, bytes);
    return noErr;
}

static OSStatus property(AudioObjectID object, const AudioObjectPropertyAddress *a,
    UInt32 qualifierSize, const void *qualifier, UInt32 capacity, UInt32 *size, void *output) {
    MicrophoneDevice *state = deviceForObject(object);
    if (!a || (object != Plugin && !state)) return kAudioHardwareBadObjectError;
    UInt32 number = 0;
    Float64 rate = Rate;
    CFStringRef text = NULL;
    AudioObjectID objects[2];
    UInt32 count = 0;
    bool device = state && object == state->device, stream = state && !device;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
            number = kAudioObjectClassID; break;
        case kAudioObjectPropertyClass:
            number = object == Plugin ? kAudioPlugInClassID : device ? kAudioDeviceClassID : kAudioStreamClassID; break;
        case kAudioObjectPropertyOwner:
            number = object == Plugin ? kAudioObjectUnknown : device ? Plugin : state->device; break;
        case kAudioObjectPropertyName:
            if (device) text = object == Device ? CFSTR("Joy Harness 遥控器麦克风") : CFSTR("Joy Harness DualSense 麦克风");
            else text = stream ? (state->device == Device ? CFSTR("Remote Voice") : CFSTR("DualSense Voice")) : CFSTR("Joy Harness Microphone");
            break;
        case kAudioObjectPropertyManufacturer:
            text = CFSTR("Joy Harness"); break;
        case kAudioObjectPropertyOwnedObjects:
            if (object == Plugin) { objects[count++] = Device; }
            if (device) {
                if (a->mScope != kAudioObjectPropertyScopeOutput) objects[count++] = state->input;
                if (a->mScope != kAudioObjectPropertyScopeInput) objects[count++] = state->output;
            }
            return copyValue(objects, count * sizeof(AudioObjectID), capacity, size, output);
        default: goto specific;
    }
    goto result;

specific:
    if (object == Plugin) {
        switch (a->mSelector) {
            case kAudioPlugInPropertyBundleID: text = CFSTR("tech.keli.joyharness.microphone"); break;
            case kAudioPlugInPropertyDeviceList:
                objects[0] = Device;
                return copyValue(objects, sizeof(AudioObjectID), capacity, size, output);
            case kAudioPlugInPropertyTranslateUIDToDevice:
                if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
                if (!*(CFStringRef const *)qualifier) return kAudioHardwareIllegalOperationError;
                number = kAudioObjectUnknown;
                for (size_t i = 0; i < sizeof(devices) / sizeof(devices[0]); i++) {
                    if (CFEqual(*(CFStringRef const *)qualifier, deviceUID(&devices[i]))) number = devices[i].device;
                }
                break;
            case kAudioPlugInPropertyBoxList:
            case kAudioPlugInPropertyClockDeviceList:
                return copyValue(NULL, 0, capacity, size, output);
            case kAudioPlugInPropertyResourceBundle: text = CFSTR(""); break;
            default: return kAudioHardwareUnknownPropertyError;
        }
    } else if (device) {
        switch (a->mSelector) {
            case kAudioDevicePropertyDeviceUID: text = deviceUID(state); break;
            case kAudioDevicePropertyModelUID:
                text = object == Device ? CFSTR("tech.keli.joyharness.microphone.model") : CFSTR("tech.keli.joyharness.dualsense.microphone.model"); break;
            case kAudioDevicePropertyTransportType: number = kAudioDeviceTransportTypeVirtual; break;
            case kAudioDevicePropertyDeviceIsAlive: number = 1; break;
            case kAudioDevicePropertyDeviceIsRunning: number = atomic_load(&state->clients) != 0; break;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                number = a->mScope == kAudioObjectPropertyScopeInput; break;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset: number = 0; break;
            case kAudioDevicePropertyZeroTimeStampPeriod: number = Period; break;
            case kAudioObjectPropertyControlList:
                return copyValue(NULL, 0, capacity, size, output);
            case kAudioObjectPropertyCustomPropertyInfoList: {
                AudioServerPlugInCustomPropertyInfo info = {
                    FlushProperty, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList,
                    kAudioServerPlugInCustomPropertyDataTypeNone,
                };
                return copyValue(&info, sizeof(info), capacity, size, output);
            }
            case FlushProperty: {
                if (a->mScope != kAudioObjectPropertyScopeGlobal || a->mElement != kAudioObjectPropertyElementMain)
                    return kAudioHardwareUnknownPropertyError;
                int64_t epoch = (uint32_t)atomic_load_explicit(&state->epoch, memory_order_acquire);
                CFNumberRef value = CFNumberCreate(NULL, kCFNumberSInt64Type, &epoch);
                OSStatus status = copyValue(&value, sizeof(value), capacity, size, output);
                if (!output || status != noErr) CFRelease(value);
                return status;
            }
            case kAudioDevicePropertyNominalSampleRate:
                return copyValue(&rate, sizeof(rate), capacity, size, output);
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange range = {Rate, Rate};
                return copyValue(&range, sizeof(range), capacity, size, output);
            }
            case kAudioDevicePropertyStreams:
                if (a->mScope != kAudioObjectPropertyScopeOutput) objects[count++] = state->input;
                if (a->mScope != kAudioObjectPropertyScopeInput) objects[count++] = state->output;
                return copyValue(objects, count * sizeof(AudioObjectID), capacity, size, output);
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32 channels[] = {1, 2};
                return copyValue(channels, sizeof(channels), capacity, size, output);
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                AudioChannelLayout layout = {.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo};
                return copyValue(&layout, offsetof(AudioChannelLayout, mChannelDescriptions), capacity, size, output);
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    } else {
        switch (a->mSelector) {
            case kAudioStreamPropertyIsActive: number = 1; break;
            case kAudioStreamPropertyDirection: number = object == state->input; break;
            case kAudioStreamPropertyTerminalType:
                number = object == state->input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine; break;
            case kAudioStreamPropertyStartingChannel: number = 1; break;
            case kAudioStreamPropertyLatency: number = 0; break;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: {
                AudioStreamBasicDescription value = format();
                return copyValue(&value, sizeof(value), capacity, size, output);
            }
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription value = {.mFormat = format(), .mSampleRateRange = {Rate, Rate}};
                return copyValue(&value, sizeof(value), capacity, size, output);
            }
            default: return kAudioHardwareUnknownPropertyError;
        }
    }
result:
    if (text) {
        OSStatus status = copyValue(&text, sizeof(text), capacity, size, output);
        if (status == noErr && output) CFRetain(text);
        return status;
    }
    return copyValue(&number, sizeof(number), capacity, size, output);
}

static HRESULT query(void *self, REFIID uuid, LPVOID *result) {
    if (!result) return E_POINTER;
    *result = NULL;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    bool matches = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!matches) return E_NOINTERFACE;
    atomic_fetch_add(&references, 1);
    *result = driver;
    return S_OK;
}
static ULONG addRef(void *self) { return atomic_fetch_add(&references, 1) + 1; }
static ULONG release(void *self) {
    uint32_t count = atomic_load(&references);
    while (count > 0 && !atomic_compare_exchange_weak(&references, &count, count - 1)) {}
    return count > 0 ? count - 1 : 0;
}
static OSStatus initialize(AudioServerPlugInDriverRef self, AudioServerPlugInHostRef host) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    ticksPerFrame = 1e9 * timebase.denom / timebase.numer / Rate;
    maximumFrameAge = (uint64_t)(250e6 * timebase.denom / timebase.numer);
    for (size_t i = 0; i < sizeof(devices) / sizeof(devices[0]); i++) invalidate(&devices[i]);
    return noErr;
}
static OSStatus create(AudioServerPlugInDriverRef s, CFDictionaryRef d, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus destroy(AudioServerPlugInDriverRef s, AudioObjectID d) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus client(AudioServerPlugInDriverRef s, AudioObjectID d, const AudioServerPlugInClientInfo *c) { return deviceForID(d) ? noErr : kAudioHardwareBadDeviceError; }
static OSStatus configuration(AudioServerPlugInDriverRef s, AudioObjectID d, UInt64 action, void *info) { return deviceForID(d) ? noErr : kAudioHardwareBadDeviceError; }
static Boolean has(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a) {
    UInt32 size;
    CFStringRef uid = deviceUID(&devices[0]);
    return property(o, a, sizeof(uid), &uid, 0, &size, NULL) == noErr;
}
static OSStatus settable(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, Boolean *value) {
    if (!a || !value) return kAudioHardwareIllegalOperationError;
    if (!has(s, o, p, a)) return kAudioHardwareUnknownPropertyError;
    *value = a->mSelector == kAudioDevicePropertyNominalSampleRate ||
        a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat ||
        a->mSelector == FlushProperty;
    return noErr;
}
static OSStatus dataSize(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 q, const void *v, UInt32 *size) { return property(o, a, q, v, 0, size, NULL); }
static OSStatus get(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 q, const void *v, UInt32 capacity, UInt32 *size, void *out) { return property(o, a, q, v, capacity, size, out); }
static OSStatus set(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 q, const void *v, UInt32 size, const void *data) {
    Boolean allowed;
    OSStatus status = settable(s, o, p, a, &allowed);
    if (status != noErr) return status;
    if (!allowed || !data) return kAudioHardwareIllegalOperationError;
    if (a->mSelector == FlushProperty) {
        // Core Audio marshals custom properties as CFPropertyList, not raw
        // integers. The caller writes a CFNumberRef containing any UInt32.
        if (size != sizeof(CFPropertyListRef) || q != 0) return kAudioHardwareBadPropertySizeError;
        CFPropertyListRef value;
        memcpy(&value, data, sizeof(value));
        int64_t token;
        if (!value || CFGetTypeID(value) != CFNumberGetTypeID() ||
            CFNumberIsFloatType((CFNumberRef)value) ||
            !CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &token) ||
            token < 0 || token > UINT32_MAX) return kAudioHardwareIllegalOperationError;
        invalidate(deviceForID(o));
        return noErr;
    }
    if (a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)data == Rate ? noErr : kAudioHardwareUnsupportedOperationError;
    }
    if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
    AudioStreamBasicDescription expected = format();
    const AudioStreamBasicDescription *requested = data;
    return requested->mSampleRate == expected.mSampleRate && requested->mFormatID == expected.mFormatID &&
        requested->mFormatFlags == expected.mFormatFlags && requested->mBytesPerPacket == 8 &&
        requested->mFramesPerPacket == 1 && requested->mBytesPerFrame == 8 &&
        requested->mChannelsPerFrame == 2 && requested->mBitsPerChannel == 32
        ? noErr : kAudioDeviceUnsupportedFormatError;
}
static OSStatus start(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c) {
    MicrophoneDevice *device = deviceForID(d);
    if (!device) return kAudioHardwareBadDeviceError;
    if (atomic_fetch_add(&device->clients, 1) == 0) {
        invalidate(device);
        atomic_store(&device->anchor, mach_absolute_time());
        atomic_fetch_add(&device->clockSeed, 1);
    }
    return noErr;
}
static OSStatus stop(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c) {
    MicrophoneDevice *device = deviceForID(d);
    if (!device) return kAudioHardwareBadDeviceError;
    uint32_t count = atomic_load(&device->clients);
    while (count > 0 && !atomic_compare_exchange_weak(&device->clients, &count, count - 1)) {}
    if (count == 1) invalidate(device);
    return noErr;
}
static OSStatus timestamp(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c, Float64 *sample, UInt64 *host, UInt64 *seed) {
    MicrophoneDevice *device = deviceForID(d);
    if (!device || !sample || !host || !seed) return kAudioHardwareIllegalOperationError;
    uint64_t origin = atomic_load(&device->anchor), now = mach_absolute_time();
    uint64_t periods = (uint64_t)((now - origin) / (ticksPerFrame * Period));
    *sample = (Float64)(periods * Period);
    *host = origin + (uint64_t)(*sample * ticksPerFrame);
    *seed = atomic_load(&device->clockSeed);
    return noErr;
}
static OSStatus willDo(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c, UInt32 op, Boolean *will, Boolean *inPlace) {
    if (!deviceForID(d) || !will || !inPlace) return kAudioHardwareIllegalOperationError;
    *will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = true;
    return noErr;
}
static OSStatus boundary(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) { return deviceForID(d) ? noErr : kAudioHardwareBadDeviceError; }
static OSStatus io(AudioServerPlugInDriverRef s, AudioObjectID d, AudioObjectID stream, UInt32 c, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *buffer, void *secondary) {
    MicrophoneDevice *device = deviceForID(d);
    if (!device || !cycle || !buffer) return kAudioHardwareIllegalOperationError;
    if (frames > RingFrames) return kAudioHardwareBadPropertySizeError;
    bool writing = op == kAudioServerPlugInIOOperationWriteMix;
    if ((!writing && op != kAudioServerPlugInIOOperationReadInput) || stream != (writing ? device->output : device->input)) return kAudioHardwareUnsupportedOperationError;
    double time = writing ? cycle->mOutputTime.mSampleTime : cycle->mInputTime.mSampleTime;
    if (time < 0) { if (!writing) memset(buffer, 0, frames * 8); return noErr; }
    if (!isfinite(time) || time >= 0x1p64 - RingFrames) {
        if (!writing) memset(buffer, 0, frames * 8);
        return kAudioHardwareIllegalOperationError;
    }
    uint64_t first = (uint64_t)time;
    uint64_t epoch = atomic_load_explicit(&device->epoch, memory_order_acquire);
    // Unlike the Core Audio clock, freshness must include time spent asleep.
    uint64_t now = mach_continuous_time();
    for (UInt32 i = 0; i < frames; i++) {
        uint64_t frame = first + i, position = frame % RingFrames, bits = 0;
        if (writing) {
            memcpy(&bits, (char *)buffer + i * 8, 8);
            atomic_store_explicit(&device->stamps[position], UINT64_MAX, memory_order_release);
            atomic_store_explicit(&device->samples[position], bits, memory_order_release);
            atomic_store_explicit(&device->epochs[position], epoch, memory_order_release);
            atomic_store_explicit(&device->writtenAt[position], now, memory_order_release);
            atomic_store_explicit(&device->stamps[position], frame, memory_order_release);
        } else {
            if (atomic_load_explicit(&device->stamps[position], memory_order_acquire) == frame &&
                atomic_load_explicit(&device->epochs[position], memory_order_acquire) == epoch) {
                uint64_t written = atomic_load_explicit(&device->writtenAt[position], memory_order_acquire);
                // Expire each frame independently: a producer restart cannot
                // make old future-stamped frames audible again. No timer or
                // producer cleanup is needed when the app crashes.
                if (now >= written && now - written <= maximumFrameAge)
                    bits = atomic_load_explicit(&device->samples[position], memory_order_acquire);
                if (atomic_load_explicit(&device->stamps[position], memory_order_acquire) != frame ||
                    atomic_load_explicit(&device->epochs[position], memory_order_acquire) != epoch) bits = 0;
            }
            memcpy((char *)buffer + i * 8, &bits, 8);
        }
    }
    if (!writing && atomic_load_explicit(&device->epoch, memory_order_acquire) != epoch)
        memset(buffer, 0, frames * 8);
    return noErr;
}

static AudioServerPlugInDriverInterface interface = {
    NULL, query, addRef, release, initialize, create, destroy, client, client,
    configuration, configuration, has, settable, dataSize, get, set,
    start, stop, timestamp, willDo, boundary, io, boundary,
};

__attribute__((visibility("default")))
void *JoyHarnessMicrophoneFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    return type && CFEqual(type, kAudioServerPlugInTypeUUID) ? driver : NULL;
}
