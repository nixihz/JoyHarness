"""Physical RC003 test: mapped volume input must not alter system volume."""
import json
import subprocess
import threading
from pathlib import Path

PROBE = r'''
import Foundation
import CoreAudio
func sampleVolume() {
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var device = AudioDeviceID(0)
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { fatalError("no default output") }
var volumes: [String: Float32] = [:]
for channel: UInt32 in [0, 1, 2] {
 var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioDevicePropertyScopeOutput, mElement: channel)
 var volume: Float32 = 0
 var count = UInt32(MemoryLayout<Float32>.size)
 if AudioObjectGetPropertyData(device, &property, 0, nil, &count, &volume) == noErr { volumes[String(channel)] = volume }
}
let data = try! JSONSerialization.data(withJSONObject: ["device":device,"volumes":volumes], options: .sortedKeys)
print(String(data: data, encoding: .utf8)!)
fflush(stdout)
}
while true {
 sampleVolume()
 usleep(20000)
}
'''

log = Path.home() / ".agent-deck/runtime.log"
monitor = subprocess.Popen(["swift", "-"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True)
monitor.stdin.write(PROBE)
monitor.stdin.close()
samples = []
try:
    first = monitor.stdout.readline()
    assert first, "CoreAudio monitor failed: " + monitor.stderr.read()
    before = json.loads(first)
    assert before["volumes"], "No readable system output volume"
    samples.append(before)
    def collect():
        for line in monitor.stdout:
            samples.append(json.loads(line))
    reader = threading.Thread(target=collect, daemon=True)
    reader.start()
    offset = log.stat().st_size
    print("BEFORE", before, flush=True)
    input("请短按音量加，再短按音量减，完成后按 Enter：")
finally:
    monitor.terminate()
    monitor.wait(timeout=5)
    if "reader" in locals():
        reader.join(timeout=2)
with log.open("rb") as stream:
    stream.seek(offset)
    lines = stream.read().decode().splitlines()
events = [s for s in lines if "mapped=rightShoulder:" in s or "mapped=leftShoulder:" in s]
changes = [sample for sample in samples if sample != before]
print("SAMPLES", len(samples), "CHANGED", len(changes))
print("MAPPED_EVENTS", events)
for button in ["rightShoulder", "leftShoulder"]:
    for edge in ["down", "up"]:
        assert any(f"mapped={button}:{edge}" in x for x in events), f"Missing {button}:{edge}"
assert not changes, f"FAIL: system volume changed during remote input: {changes[:3]}"
print("PASS: both remote volume buttons received press/release; system volume unchanged throughout")
