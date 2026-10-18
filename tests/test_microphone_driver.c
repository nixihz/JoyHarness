#include "../Drivers/JoyHarnessMicrophone/Driver.c"
#include <assert.h>
#include <stdio.h>
#include <time.h>

static AudioObjectPropertyAddress address(AudioObjectPropertySelector selector, AudioObjectPropertyScope scope) {
    return (AudioObjectPropertyAddress){selector, scope, kAudioObjectPropertyElementMain};
}

static UInt32 readUInt32(AudioObjectID object, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress a = address(selector, kAudioObjectPropertyScopeGlobal);
    UInt32 size = 0, value = UINT32_MAX;
    assert(get(driver, object, 0, &a, 0, NULL, sizeof(value), &size, &value) == noErr);
    assert(size == sizeof(value));
    return value;
}

static void expectString(AudioObjectID object, AudioObjectPropertySelector selector, CFStringRef expected) {
    AudioObjectPropertyAddress a = address(selector, kAudioObjectPropertyScopeGlobal);
    CFStringRef value = NULL;
    UInt32 size = 0;
    assert(get(driver, object, 0, &a, 0, NULL, sizeof(value), &size, &value) == noErr);
    assert(value && CFEqual(value, expected));
    CFRelease(value);
}

static void writeFrames(AudioObjectID device, AudioObjectID stream, double sampleTime, const float *pcm) {
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mOutputTime.mSampleTime = sampleTime;
    assert(io(driver, device, stream, 10, kAudioServerPlugInIOOperationWriteMix, 2, &cycle, (void *)pcm, NULL) == noErr);
}

static void expectFrames(AudioObjectID device, AudioObjectID stream, UInt32 reader, double sampleTime, const float *expected) {
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mInputTime.mSampleTime = sampleTime;
    float received[] = {99, 99, 99, 99};
    assert(io(driver, device, stream, reader, kAudioServerPlugInIOOperationReadInput, 2, &cycle, received, NULL) == noErr);
    assert(memcmp(received, expected, sizeof(received)) == 0);
}

static void flush(AudioObjectID device) {
    AudioObjectPropertyAddress a = address(0x6a68666c, kAudioObjectPropertyScopeGlobal);
    Boolean writable = false;
    assert(has(driver, device, 0, &a));
    assert(settable(driver, device, 0, &a, &writable) == noErr && writable);
    int64_t token = UINT32_MAX;
    CFNumberRef value = CFNumberCreate(NULL, kCFNumberSInt64Type, &token);
    assert(set(driver, device, 0, &a, 0, NULL, sizeof(value), &value) == noErr);
    CFRelease(value);
}

static void checkPublishedDevices(void) {
    AudioObjectPropertyAddress a = address(kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal);
    AudioObjectID listed[2] = {0};
    UInt32 size = 0;
    assert(get(driver, Plugin, 0, &a, 0, NULL, sizeof(listed), &size, listed) == noErr);
    assert(size == sizeof(AudioObjectID) && listed[0] == Device);
    expectString(Device, kAudioDevicePropertyDeviceUID, CFSTR("tech.keli.joyharness.microphone.device"));
    expectString(Device, kAudioObjectPropertyName, CFSTR("Joy Harness 遥控器麦克风"));
    CFStringRef oldUID = CFSTR("tech.keli.joyharness.dualsense.microphone.device");
    AudioObjectID translated = 99;
    a = address(kAudioPlugInPropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal);
    assert(get(driver, Plugin, 0, &a, sizeof(oldUID), &oldUID, sizeof(translated), &size, &translated) == noErr);
    assert(translated == kAudioObjectUnknown);
    assert(start(driver, 5, 10) != noErr);
    assert(readUInt32(Input, kAudioObjectPropertyOwner) == Device);
    assert(readUInt32(Output, kAudioObjectPropertyOwner) == Device);
    a = address(kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal);
    assert(get(driver, Plugin, 0, &a, 0, NULL, sizeof(listed), &size, listed) == noErr);
    assert(size == sizeof(AudioObjectID) && listed[0] == Device);
}

static void checkFormatAndRejectedRequests(void) {
    UInt32 size = 0, value = 1;
    AudioObjectPropertyAddress a = address(kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput);
    assert(get(driver, Device, 0, &a, 0, NULL, sizeof(value), &size, &value) == noErr && value == 0);
    a.mScope = kAudioObjectPropertyScopeInput;
    assert(get(driver, Device, 0, &a, 0, NULL, sizeof(value), &size, &value) == noErr && value == 1);
    a = address(kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal);
    AudioStreamBasicDescription actual = {0};
    assert(get(driver, Input, 0, &a, 0, NULL, sizeof(actual), &size, &actual) == noErr);
    assert(actual.mSampleRate == 48000 && actual.mChannelsPerFrame == 2 && actual.mBitsPerChannel == 32);
    assert(actual.mBytesPerFrame == 8 && actual.mFormatID == kAudioFormatLinearPCM);
    a = address(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal);
    Float64 wrongRate = 16000;
    assert(set(driver, Device, 0, &a, 0, NULL, sizeof(wrongRate), &wrongRate) != noErr);
    assert(set(driver, Device, 0, &a, 0, NULL, sizeof(wrongRate), &wrongRate) != noErr);
    a = address(0x6a68666c, kAudioObjectPropertyScopeGlobal);
    UInt32 raw = 1;
    assert(set(driver, Device, 0, &a, 0, NULL, sizeof(raw), &raw) == kAudioHardwareBadPropertySizeError);
    CFPropertyListRef wrongType = CFSTR("not a token");
    assert(set(driver, Device, 0, &a, 0, NULL, sizeof(wrongType), &wrongType) != noErr);
    assert(!has(driver, Input, 0, &a));
    a.mScope = kAudioObjectPropertyScopeInput;
    assert(!has(driver, Device, 0, &a));
    AudioServerPlugInIOCycleInfo cycle = {0};
    float samples[4] = {1, 1, 1, 1};
    assert(io(driver, Device, Output, 2, kAudioServerPlugInIOOperationReadInput, 2, &cycle, samples, NULL) != noErr);
    assert(io(driver, Device, Input, 2, kAudioServerPlugInIOOperationReadInput, RingFrames + 1, &cycle, samples, NULL) != noErr);
    cycle.mInputTime.mSampleTime = NAN;
    assert(io(driver, Device, Input, 2, kAudioServerPlugInIOOperationReadInput, 2, &cycle, samples, NULL) != noErr);
    assert(samples[0] == 0 && samples[3] == 0);
}

static void checkClockContract(void) {
    const AudioObjectID ids[] = {Device};
    Float64 samples[2];
    UInt64 hosts[2], seeds[2];
    UInt32 periods[2];
    for (size_t i = 0; i < 1; ++i) {
        periods[i] = readUInt32(ids[i], kAudioDevicePropertyZeroTimeStampPeriod);
        // AudioServerPlugIn.h specifies this minimum independently of our
        // chosen period. A property/callback pair agreeing on 512 is invalid.
        assert(periods[i] >= 10923);
        assert(start(driver, ids[i], 99) == noErr);
        assert(timestamp(driver, ids[i], 99, &samples[i], &hosts[i], &seeds[i]) == noErr);
    }
    // Exercise an actual clock advance, without depending on a particular
    // number of periods elapsing while this process is descheduled.
    struct timespec pause = {.tv_sec = 1};
    assert(nanosleep(&pause, NULL) == 0);
    mach_timebase_info_data_t timebase;
    assert(mach_timebase_info(&timebase) == KERN_SUCCESS);
    for (size_t i = 0; i < 1; ++i) {
        Float64 sample;
        UInt64 host, seed;
        assert(timestamp(driver, ids[i], 99, &sample, &host, &seed) == noErr);
        assert(seed == seeds[i] && host > hosts[i] && host <= mach_absolute_time());
        assert(sample > samples[i] && fmod(sample - samples[i], periods[i]) == 0);
        double hostNanoseconds = (double)(host - hosts[i]) * timebase.numer / timebase.denom;
        double sampleNanoseconds = (sample - samples[i]) / 48000.0 * 1e9;
        assert(fabs(hostNanoseconds - sampleNanoseconds) <= (double)timebase.numer / timebase.denom + 1);
        assert(stop(driver, ids[i], 99) == noErr);
    }
}

int main(void) {
    const float silence[] = {0, 0, 0, 0};
    const float pcm[] = {0.25f, -0.5f, 0.75f, -1.0f};
    assert(JoyHarnessMicrophoneFactory(NULL, kAudioServerPlugInTypeUUID) == driver);
    assert(initialize(driver, NULL) == noErr);
    checkPublishedDevices();
    checkFormatAndRejectedRequests();
    checkClockContract();
    assert(start(driver, Device, 20) == noErr);
    assert(start(driver, Device, 21) == noErr);
    expectFrames(Device, Input, 21, 1000, silence);
    writeFrames(Device, Output, 1000, pcm);
    expectFrames(Device, Input, 21, 1000, pcm);
    expectFrames(Device, Input, 22, 1000, pcm); // independent readers
    expectFrames(Device, Input, 21, 1000 + RingFrames, silence);
    Float64 sample;
    UInt64 host, seedBefore, seedAfter;
    assert(timestamp(driver, Device, 21, &sample, &host, &seedBefore) == noErr);
    flush(Device);
    assert(readUInt32(Device, kAudioDevicePropertyDeviceIsRunning) == 1);
    assert(timestamp(driver, Device, 21, &sample, &host, &seedAfter) == noErr && seedBefore == seedAfter);
    expectFrames(Device, Input, 21, 1000, silence);
    expectFrames(Device, Input, 22, 1000, silence);
    writeFrames(Device, Output, 1100, pcm);
    expectFrames(Device, Input, 21, 1100, pcm);
    expectFrames(Device, Input, 21, 1000, silence);
    struct timespec pause = {.tv_nsec = 300000000};
    assert(nanosleep(&pause, NULL) == 0);
    expectFrames(Device, Input, 21, 1100, silence); // producer disappeared
    assert(stop(driver, Device, 20) == noErr);
    assert(readUInt32(Device, kAudioDevicePropertyDeviceIsRunning) == 1);
    assert(start(driver, Device, 20) == noErr);
    writeFrames(Device, Output, 1200, pcm);
    expectFrames(Device, Input, 21, 1200, pcm);
    expectFrames(Device, Input, 21, 1100, silence);
    assert(stop(driver, Device, 20) == noErr);
    assert(stop(driver, Device, 21) == noErr);
    assert(readUInt32(Device, kAudioDevicePropertyDeviceIsRunning) == 0);
    assert(start(driver, Device, 20) == noErr);
    expectFrames(Device, Input, 21, 1200, silence);
    puts("PASS: Xiaomi retained, retired DualSense UID absent, HAL clock, format, multiple readers, live flush and producer loss");
}
