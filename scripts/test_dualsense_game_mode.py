#!/usr/bin/env python3
"""Exercise the production lease code against a subprocess fixture, never the real game policy."""
import os
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='joyharness-game-policy-') as temporary:
    root = Path(temporary)
    tool = root / 'gamepolicyctl'
    state = root / 'policy'
    journal = root / 'lease'
    fail = root / 'fail'
    tool.write_text(f'''#!/bin/sh
if [ "$2" = status ]; then
  case "$(cat '{state}')" in
    auto) echo 'policy is currently automatic';;
    on) echo 'Game mode is forced always on.';;
    off) echo 'Game mode is forced always off.';;
    *) exit 1;;
  esac
else
  if [ -f '{fail}' ]; then exit 1; fi
  echo "$3" > '{state}'
fi
''')
    tool.chmod(0o755)
    harness = root / 'test.c'
    harness.write_text('''#include "ds5_game_mode.h"
#include <string.h>
int main(int argc, char **argv) {
 if (!strcmp(argv[1],"acquire")) return ds5_game_mode_acquire() ? 0 : 1;
 if (!strcmp(argv[1],"recover")) { ds5_game_mode_recover(); return 0; }
 if (!ds5_game_mode_acquire() || !ds5_game_mode_acquire()) return 1;
 ds5_game_mode_release(); ds5_game_mode_release(); return 0;
}
''')
    subprocess.run(['clang', '-Wall', '-Wextra', '-I'+str(repo/'Drivers/DualSenseAudio/src/daemon'),
                    '-DTOOL="'+str(tool)+'"', '-DJOURNAL="'+str(journal)+'"',
                    '-DJOURNAL_OWNER='+str(os.getuid()), str(harness),
                    str(repo/'Drivers/DualSenseAudio/src/daemon/ds5_game_mode.c'), '-o', str(root/'test')], check=True)
    def run(op, expected=0):
        result = subprocess.run([str(root/'test'), op])
        assert result.returncode == expected, (op, result.returncode)
    for original in ['auto','off','on']:
        state.write_text(original)
        run('cycle')
        assert state.read_text().strip() == original
        assert not journal.exists()
    state.write_text('auto')
    run('acquire')
    assert state.read_text().strip() == 'on' and journal.exists()
    run('recover') # new process: simulates launchd restart after helper crash
    assert state.read_text().strip() == 'auto' and not journal.exists()
    state.write_text('auto'); run('acquire'); state.write_text('off'); run('recover')
    assert state.read_text().strip() == 'off' and not journal.exists()
    state.write_text('auto'); fail.touch(); run('acquire', 1)
    assert state.read_text().strip() == 'auto'
    fail.unlink()
    state.write_text('auto'); run('acquire'); fail.touch(); run('recover')
    assert journal.exists() and state.read_text().strip() == 'on'
    fail.unlink(); run('recover')
    assert not journal.exists() and state.read_text().strip() == 'auto'
    state.write_text('unknown'); run('acquire', 1)
    assert not journal.exists()
    print('PASS: balanced/repeated start-stop, original auto/on/off, crash recovery, external policy change, command failures and retry')
