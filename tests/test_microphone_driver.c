#include "../Drivers/JoyHarnessMicrophone/Driver.c"
#include <assert.h>
#include <stdio.h>

int main(void) {
    assert(JoyHarnessMicrophoneFactory(NULL, kAudioServerPlugInTypeUUID) == driver);
    assert(initialize(driver, NULL) == noErr);
    assert(start(driver, Device, 1) == noErr);
    AudioServerPlugInIOCycleInfo cycle = {0};
    cycle.mOutputTime.mSampleTime = 1000;
    cycle.mInputTime.mSampleTime = 1000;
    float source[] = {0.25f, -0.5f, 0.75f, -1.0f}, received[4] = {1, 1, 1, 1};
    assert(io(driver, Device, Input, 2, kAudioServerPlugInIOOperationReadInput, 2, &cycle, received, NULL) == noErr);
    assert(received[0] == 0 && received[3] == 0);
    assert(io(driver, Device, Output, 1, kAudioServerPlugInIOOperationWriteMix, 2, &cycle, source, NULL) == noErr);
    assert(io(driver, Device, Input, 2, kAudioServerPlugInIOOperationReadInput, 2, &cycle, received, NULL) == noErr);
    assert(memcmp(source, received, sizeof(source)) == 0);
    cycle.mInputTime.mSampleTime += RingFrames;
    assert(io(driver, Device, Input, 2, kAudioServerPlugInIOOperationReadInput, 2, &cycle, received, NULL) == noErr);
    assert(received[0] == 0 && received[3] == 0); // wrapped stale audio is never replayed
    assert(stop(driver, Device, 1) == noErr);
    assert(start(driver, Device, 1) == noErr);
    cycle.mInputTime.mSampleTime = 1000;
    assert(io(driver, Device, Input, 2, kAudioServerPlugInIOOperationReadInput, 2, &cycle, received, NULL) == noErr);
    assert(received[0] == 0 && received[3] == 0); // restart clears old session
    Float64 sample;
    UInt64 host, seed;
    assert(timestamp(driver, Device, 1, &sample, &host, &seed) == noErr);
    assert(sample >= 0 && host <= mach_absolute_time() && seed > 1);
    AudioObjectPropertyAddress address = {kAudioDevicePropertyDeviceCanBeDefaultDevice, kAudioObjectPropertyScopeOutput, 0};
    UInt32 size = 0, value = 1;
    assert(get(driver, Device, 0, &address, 0, NULL, sizeof(value), &size, &value) == noErr && value == 0);
    address.mScope = kAudioObjectPropertyScopeInput;
    assert(get(driver, Device, 0, &address, 0, NULL, sizeof(value), &size, &value) == noErr && value == 1);
    address.mSelector = kAudioDevicePropertyNominalSampleRate;
    Float64 wrongRate = 16000;
    assert(set(driver, Device, 0, &address, 0, NULL, sizeof(wrongRate), &wrongRate) != noErr);
    assert(io(driver, Device, Input, 2, kAudioServerPlugInIOOperationReadInput, RingFrames + 1, &cycle, received, NULL) != noErr);
    puts("PASS: microphone PCM loopback, silence, ring wrap, restart, clock and format contract");
}
