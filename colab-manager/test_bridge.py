"""Exercise stop confirmation and failed startup against a fake CLI, never Colab."""
from pathlib import Path
import os
import subprocess
import tempfile

SOURCE = Path(__file__).with_name('bridge.sh').read_text()
with tempfile.TemporaryDirectory(prefix='colab-manager-test-') as td:
    root = Path(td)
    base = root / 'base'
    (base / 'lib').mkdir(parents=True)
    binpath = root / 'bin'
    binpath.mkdir()
    (base / 'lib/common.sh').write_text('''
COLAB_SESSION=strata
HIGH_MEM=0
stop_tunnel() { :; }
stop_master() { :; }
wait_ssh() { return 1; }
ctl() { return 1; }
''')
    for name, text in {
        'timeout': '#!/bin/bash\n[[ "$1" == -k ]] && shift 2\nshift\nexec "$@"\n',
        'sleep': '#!/bin/bash\nexit 0\n',
        'colab': '''#!/bin/bash
case "$1" in
status)
  if [[ "$MODE" == unknown ]]; then echo 'Authentication unavailable' >&2; exit 1; fi
  if [[ "$MODE" == auth ]]; then echo 'Enter the authorization code:' >&2; exit 1; fi
  if [[ -f "$TEST_ROOT/active" ]]; then echo '[strata] fake | Hardware: A100 | Status: IDLE'
  else echo "[colab] Session 'strata' not found."; fi;;
stop)
  n=$(cat "$TEST_ROOT/attempts" 2>/dev/null || echo 0)
  n=$((n+1)); echo "$n" > "$TEST_ROOT/attempts"
  if [[ "$MODE" != retry || "$n" -ge 2 ]]; then rm -f "$TEST_ROOT/active"; fi;;
new) touch "$TEST_ROOT/active";;
usage) touch "$TEST_ROOT/usage-called"; echo 'Current balance: 100.00 compute units';;
esac
'''
    }.items():
        p = binpath / name
        p.write_text(text)
        p.chmod(0o755)
    script = root / 'bridge.sh'
    script.write_text(SOURCE)
    env = dict(os.environ, PATH=str(binpath)+':'+os.environ['PATH'], TEST_ROOT=str(root), STRATA_CLI_DIR=str(base))

    def run(action, mode):
        return subprocess.run(['bash', str(script), action], env=dict(env, MODE=mode), text=True, capture_output=True, timeout=10)

    (root/'active').touch()
    r = run('stop','retry')
    assert r.returncode == 0 and '[manager] stopped' in r.stdout, r
    assert int((root/'attempts').read_text()) == 2
    r = run('stop','unknown')
    assert r.returncode != 0 and 'stop-unconfirmed' in r.stdout, r
    assert '[manager] stopped' not in r.stdout
    (root/'state/stop.request').unlink()
    r = run('start','normal')  # allocation succeeds; SSH fails
    assert r.returncode != 0 and not (root/'active').exists(), r
    assert 'setup ended' in r.stdout and '[manager] stopped' in r.stdout
    # reconnect は張り直すだけ。SSH が通らなくても、動いているランタイムは止めない（2026-11-09 01:30 にこれで失った）
    (root/'active').touch()
    (root/'attempts').unlink(missing_ok=True)
    r = run('reconnect','normal')  # runtime exists; SSH fails
    assert r.returncode != 0 and (root/'active').exists(), r
    assert '[manager] stopped' not in r.stdout and not (root/'attempts').exists(), r
    # 認証が要るときは、状態を unknown とし、MANAGER_AUTH_REQUIRED を出し、CU の照会はしない
    r = run('status','auth')
    assert 'MANAGER_STATE=unknown' in r.stdout and 'MANAGER_AUTH_REQUIRED' in r.stderr, r
    assert not (root/'usage-called').exists(), r
    r = run('status','normal')
    assert 'MANAGER_STATE=present' in r.stdout and (root/'usage-called').exists(), r
    print('PASS: failed stop retry, unknown is not absent, failed startup cleans up, failed reconnect keeps the runtime, auth-required status (fake CLI only)')
