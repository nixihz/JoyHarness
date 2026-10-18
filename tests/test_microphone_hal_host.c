#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

static AudioDeviceID resolve(CFStringRef expected) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    assert(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size) == noErr);
    AudioDeviceID *ids = malloc(size);
    assert(ids != NULL);
    assert(AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, ids) == noErr);
    AudioDeviceID result = 0;
    for (size_t i = 0; i < size / sizeof(AudioDeviceID); ++i) {
        AudioObjectPropertyAddress uidAddress = {kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        CFStringRef uid = NULL;
        UInt32 uidSize = sizeof(uid);
        if (AudioObjectGetPropertyData(ids[i], &uidAddress, 0, NULL, &uidSize, &uid) == noErr && uid != NULL) {
            if (CFEqual(uid, expected)) result = ids[i];
            CFRelease(uid);
        }
    }
    free(ids);
    return result;
}

static UInt32 epoch(AudioDeviceID device) {
    AudioObjectPropertyAddress a = {0x6a68666c, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    CFPropertyListRef value = NULL;
    UInt32 size = sizeof(value);
    assert(AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &value) == noErr);
    assert(value != NULL && CFGetTypeID(value) == CFNumberGetTypeID());
    SInt64 number = 0;
    assert(CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number));
    CFRelease(value);
    return (UInt32)number;
}

int main(void) {
    assert(resolve(CFSTR("tech.keli.joyharness.dualsense.microphone.device")) == 0);
    AudioDeviceID xiaomi = resolve(CFSTR("tech.keli.joyharness.microphone.device"));
    assert(xiaomi != 0);
    UInt32 before = epoch(xiaomi);
    AudioObjectPropertyAddress a = {0x6a68666c, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    SInt32 one = 1;
    CFNumberRef token = CFNumberCreate(NULL, kCFNumberSInt32Type, &one);
    OSStatus status = AudioObjectSetPropertyData(xiaomi, &a, 0, NULL, sizeof(token), &token);
    CFRelease(token);
    assert(status == noErr && epoch(xiaomi) != before);
    puts("PASS: retired DualSense input absent; Xiaomi live HAL flush works; no recording or default change");
    return 0;
}
