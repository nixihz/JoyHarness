#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Audio callbacks require lock-free 64-bit atomics");

// A user-space HAL loopback: the app writes stereo Float32, dictation clients
// read the same clocked frames. No networking, disk audio, or kernel extension.
enum { Plugin = kAudioObjectPlugInObject, Device = 2, Input = 3, Output = 4,
       Rate = 48000, Period = 512, RingFrames = 65536 };
static const CFStringRef DeviceUID = CFSTR("tech.keli.joyharness.microphone.device");
static _Atomic uint64_t samples[RingFrames];
static _Atomic uint64_t stamps[RingFrames];
static _Atomic uint32_t references = 1, clients = 0;
static _Atomic uint64_t anchor = 0, clockSeed = 1;
static double ticksPerFrame;
static AudioServerPlugInDriverInterface interface;
static AudioServerPlugInDriverInterface *interfacePointer = &interface;
static AudioServerPlugInDriverRef driver = &interfacePointer;

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
    if (!a || object < Plugin || object > Output) return kAudioHardwareBadObjectError;
    UInt32 number = 0;
    Float64 rate = Rate;
    CFStringRef text = NULL;
    AudioObjectID objects[2];
    UInt32 count = 0;
    bool device = object == Device, stream = object == Input || object == Output;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
            number = kAudioObjectClassID; break;
        case kAudioObjectPropertyClass:
            number = object == Plugin ? kAudioPlugInClassID : device ? kAudioDeviceClassID : kAudioStreamClassID; break;
        case kAudioObjectPropertyOwner:
            number = object == Plugin ? kAudioObjectUnknown : device ? Plugin : Device; break;
        case kAudioObjectPropertyName:
            text = device ? CFSTR("Joy Harness 遥控器麦克风") : stream ? CFSTR("Remote Voice") : CFSTR("Joy Harness Microphone"); break;
        case kAudioObjectPropertyManufacturer:
            text = CFSTR("Joy Harness"); break;
        case kAudioObjectPropertyOwnedObjects:
            if (object == Plugin) objects[count++] = Device;
            if (device) {
                if (a->mScope != kAudioObjectPropertyScopeOutput) objects[count++] = Input;
                if (a->mScope != kAudioObjectPropertyScopeInput) objects[count++] = Output;
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
                number = CFEqual(*(CFStringRef const *)qualifier, DeviceUID) ? Device : kAudioObjectUnknown;
                break;
            case kAudioPlugInPropertyBoxList:
            case kAudioPlugInPropertyClockDeviceList:
                return copyValue(NULL, 0, capacity, size, output);
            case kAudioPlugInPropertyResourceBundle: text = CFSTR(""); break;
            default: return kAudioHardwareUnknownPropertyError;
        }
    } else if (device) {
        switch (a->mSelector) {
            case kAudioDevicePropertyDeviceUID: text = DeviceUID; break;
            case kAudioDevicePropertyModelUID: text = CFSTR("tech.keli.joyharness.microphone.model"); break;
            case kAudioDevicePropertyTransportType: number = kAudioDeviceTransportTypeVirtual; break;
            case kAudioDevicePropertyDeviceIsAlive: number = 1; break;
            case kAudioDevicePropertyDeviceIsRunning: number = atomic_load(&clients) != 0; break;
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
            case kAudioDevicePropertyNominalSampleRate:
                return copyValue(&rate, sizeof(rate), capacity, size, output);
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange range = {Rate, Rate};
                return copyValue(&range, sizeof(range), capacity, size, output);
            }
            case kAudioDevicePropertyStreams:
                if (a->mScope != kAudioObjectPropertyScopeOutput) objects[count++] = Input;
                if (a->mScope != kAudioObjectPropertyScopeInput) objects[count++] = Output;
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
            case kAudioStreamPropertyDirection: number = object == Input; break;
            case kAudioStreamPropertyTerminalType:
                number = object == Input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine; break;
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
    for (int i = 0; i < RingFrames; i++) atomic_store(&stamps[i], UINT64_MAX);
    return noErr;
}
static OSStatus create(AudioServerPlugInDriverRef s, CFDictionaryRef d, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus destroy(AudioServerPlugInDriverRef s, AudioObjectID d) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus client(AudioServerPlugInDriverRef s, AudioObjectID d, const AudioServerPlugInClientInfo *c) { return d == Device ? noErr : kAudioHardwareBadDeviceError; }
static OSStatus configuration(AudioServerPlugInDriverRef s, AudioObjectID d, UInt64 action, void *info) { return d == Device ? noErr : kAudioHardwareBadDeviceError; }
static Boolean has(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a) {
    UInt32 size;
    CFStringRef uid = DeviceUID;
    return property(o, a, sizeof(uid), &uid, 0, &size, NULL) == noErr;
}
static OSStatus settable(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, Boolean *value) {
    if (!a || !value) return kAudioHardwareIllegalOperationError;
    if (!has(s, o, p, a)) return kAudioHardwareUnknownPropertyError;
    *value = a->mSelector == kAudioDevicePropertyNominalSampleRate ||
        a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat;
    return noErr;
}
static OSStatus dataSize(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 q, const void *v, UInt32 *size) { return property(o, a, q, v, 0, size, NULL); }
static OSStatus get(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 q, const void *v, UInt32 capacity, UInt32 *size, void *out) { return property(o, a, q, v, capacity, size, out); }
static OSStatus set(AudioServerPlugInDriverRef s, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 q, const void *v, UInt32 size, const void *data) {
    Boolean allowed;
    OSStatus status = settable(s, o, p, a, &allowed);
    if (status != noErr) return status;
    if (!allowed || !data) return kAudioHardwareIllegalOperationError;
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
    if (d != Device) return kAudioHardwareBadDeviceError;
    if (atomic_fetch_add(&clients, 1) == 0) {
        for (int i = 0; i < RingFrames; i++) atomic_store(&stamps[i], UINT64_MAX);
        atomic_store(&anchor, mach_absolute_time());
        atomic_fetch_add(&clockSeed, 1);
    }
    return noErr;
}
static OSStatus stop(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c) {
    if (d != Device) return kAudioHardwareBadDeviceError;
    uint32_t count = atomic_load(&clients);
    while (count > 0 && !atomic_compare_exchange_weak(&clients, &count, count - 1)) {}
    return noErr;
}
static OSStatus timestamp(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c, Float64 *sample, UInt64 *host, UInt64 *seed) {
    if (d != Device || !sample || !host || !seed) return kAudioHardwareIllegalOperationError;
    uint64_t origin = atomic_load(&anchor), now = mach_absolute_time();
    uint64_t periods = (uint64_t)((now - origin) / (ticksPerFrame * Period));
    *sample = (Float64)(periods * Period);
    *host = origin + (uint64_t)(*sample * ticksPerFrame);
    *seed = atomic_load(&clockSeed);
    return noErr;
}
static OSStatus willDo(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c, UInt32 op, Boolean *will, Boolean *inPlace) {
    if (d != Device || !will || !inPlace) return kAudioHardwareIllegalOperationError;
    *will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = true;
    return noErr;
}
static OSStatus boundary(AudioServerPlugInDriverRef s, AudioObjectID d, UInt32 c, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) { return d == Device ? noErr : kAudioHardwareBadDeviceError; }
static OSStatus io(AudioServerPlugInDriverRef s, AudioObjectID d, AudioObjectID stream, UInt32 c, UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *buffer, void *secondary) {
    if (d != Device || !cycle || !buffer) return kAudioHardwareIllegalOperationError;
    if (frames > RingFrames) return kAudioHardwareBadPropertySizeError;
    bool writing = op == kAudioServerPlugInIOOperationWriteMix;
    if ((!writing && op != kAudioServerPlugInIOOperationReadInput) || stream != (writing ? Output : Input)) return kAudioHardwareUnsupportedOperationError;
    double time = writing ? cycle->mOutputTime.mSampleTime : cycle->mInputTime.mSampleTime;
    if (time < 0) { if (!writing) memset(buffer, 0, frames * 8); return noErr; }
    uint64_t first = (uint64_t)time;
    for (UInt32 i = 0; i < frames; i++) {
        uint64_t frame = first + i, position = frame % RingFrames, bits = 0;
        if (writing) {
            memcpy(&bits, (char *)buffer + i * 8, 8);
            atomic_store_explicit(&stamps[position], UINT64_MAX, memory_order_release);
            atomic_store_explicit(&samples[position], bits, memory_order_release);
            atomic_store_explicit(&stamps[position], frame, memory_order_release);
        } else {
            if (atomic_load_explicit(&stamps[position], memory_order_acquire) == frame) {
                bits = atomic_load_explicit(&samples[position], memory_order_acquire);
                if (atomic_load_explicit(&stamps[position], memory_order_acquire) != frame) bits = 0;
            }
            memcpy((char *)buffer + i * 8, &bits, 8);
        }
    }
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
