#!/usr/bin/env bash
set -uo pipefail
APP="$(cd "$(dirname "$0")" && pwd)"; BASE="${STRATA_CLI_DIR:-$(cd "$APP/../strata-colab-cli" && pwd)}"; source "$BASE/lib/common.sh"
eval "$(sed -n '/^IDLE_GPU_UTIL=/,/^EOF$/p' "$APP/bridge.sh")"
r() { timeout 30 ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"; }
echo "== idle GPU utilization, 15 samples"; r 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -lms 1000 & p=$!; sleep 15; kill $p' | tr '\n' ' '; echo
echo "== probe (starts watcher)"; r "$IDLE_PROBE"
sleep 40; echo "== probe after 40s idle"; r "$IDLE_PROBE"
echo "== request + utilization during it"
r 'nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -lms 1000 & p=$!; sleep 25; kill $p' > /tmp/util-during.txt &
sleep 2
t0=$(date +%s); curl -s --noproxy '*' -m 120 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"qwen3.8-flash-next-iq3_s","messages":[{"role":"user","content":"1から30まで日本語の数詞で書いてください。"}],"max_tokens":300}' | python3 -c 'import sys,json; d=json.load(sys.stdin); print("tokens", d.get("usage"))' 2>&1 | head -2; echo "request secs $(( $(date +%s)-t0 ))"
wait; echo "util during: $(tr '\n' ' ' < /tmp/util-during.txt)"
echo "== probe right after request"; r "$IDLE_PROBE"
echo "== a short request (max_tokens 5)"; curl -s --noproxy '*' -m 60 http://127.0.0.1:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{"model":"qwen3.8-flash-next-iq3_s","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' >/dev/null; sleep 3
r "$IDLE_PROBE"
echo "== watcher processes"; r 'pgrep -fc strata-active.pid; cat /tmp/strata-active.pid'
