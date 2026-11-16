#!/usr/bin/env bash
# Only session "strata" is managed. Never infer absence from an auth/network error.
set -euo pipefail
APP="$(cd "$(dirname "$0")" && pwd)"
# strata-colab-cli は colab-manager と同じフォルダに並べて置く（STRATA_CLI_DIR で変えられる）
BASE="${STRATA_CLI_DIR:-$(cd "$APP/../strata-colab-cli" && pwd)}"
source "$BASE/lib/common.sh"
[[ "$COLAB_SESSION" == strata ]] || { echo 'Unexpected session; refusing.' >&2; exit 2; }
export NO_COLOR=1
export TERM=dumb
mkdir -p "$APP/state"
STOP="$APP/state/stop.request"
PHASE="$APP/state/phase"
audit() { { printf '%s [WSL] ' "$(date -Is)"; printf '%q ' "$@"; printf '\n'; } >> "$APP/state/commands.log"; }
phase() { printf '%s\n' "$1" > "$PHASE"; echo "[manager] $1"; }
state() {
  local out rc
  set +e; out="$(timeout -k 5 45 colab status -s strata </dev/null 2>&1)"; rc=$?; set -e
  if [[ $rc == 0 ]] && grep -q "Session 'strata' not found" <<<"$out"; then echo absent
  elif [[ $rc == 0 ]] && grep -q '\[strata\].*Status:' <<<"$out"; then echo present
  elif grep -Eq 'Enter the authorization code|Could not (read|save) the OAuth token|keyring.*locked' <<<"$out"; then
    echo MANAGER_AUTH_REQUIRED >&2
    echo unknown
  elif [[ "$rc" == 124 || "$rc" == 137 ]]; then
    echo MANAGER_STATUS_TIMEOUT >&2
    echo unknown
  else echo "$out" >&2; echo unknown; fi
}
stop_confirmed() {
  # Retry authoritative status; a disconnected tunnel is NOT a stopped runtime.
  local s
  for attempt in 1 2 3; do
    s="$(state)"
    if [[ "$s" == absent ]]; then phase stopped; return 0; fi
    echo "[manager] stop attempt $attempt"
    audit timeout 90 colab stop -s strata
    timeout -k 5 90 colab stop -s strata </dev/null || true
    sleep 3
  done
  s="$(state)"
  [[ "$s" == absent ]] && { phase stopped; return 0; }
  phase stop-unconfirmed
  echo 'Runtime stop could not be confirmed. Keep retrying; do not assume billing ended.' >&2
  return 1
}
cancel_check() { [[ ! -f "$STOP" ]] || { phase cancelling; exit 130; }; }
# Keep the complete setup log, including lines between status polls.
# Failed reads never replace the last successful snapshot.
capture_log() {
  local qlog tmp="$APP/state/strata-detail.$$.tmp"
  qlog="$(printf '%q' "$REMOTE_LOG")"
  if rssh "cat $qlog" > "$tmp" 2>/dev/null; then
    tr '\r' '\n' < "$tmp" > "$tmp.normalized"
    if ! cmp -s "$tmp.normalized" "$APP/state/strata-detail.log"; then
      mv "$tmp.normalized" "$APP/state/strata-detail.log"
    fi
    date -Is > "$APP/state/detail-checked.txt"
    rm -f "$tmp" "$tmp.normalized"
    # 工程ごとの時刻 (strata_fast.py)。取れなければ前回の写しを残す
    if rssh "cat $(printf '%q' "$TIMELINE_LOG")" > "$tmp.timeline" 2>/dev/null && [[ -s "$tmp.timeline" ]]; then
      mv "$tmp.timeline" "$APP/state/strata-timeline.log"
    else
      rm -f "$tmp.timeline"
    fi
  else
    rm -f "$tmp" "$tmp.normalized"
    echo '[manager] Detailed log retrieval failed; retaining last snapshot.' >&2
  fi
}
# 推論の利用を見張るColab側のコマンド。GPU使用率が IDLE_GPU_UTIL %以上の秒を「使われた」とみなす。
IDLE_GPU_UTIL="${IDLE_GPU_UTIL:-10}"
read -r -d '' IDLE_PROBE <<EOF || true
f=/tmp/strata-active; p=/tmp/strata-active.pid
if ! { [ -s \$p ] && kill -0 "\$(cat \$p)" 2>/dev/null; }; then
  date +%s > \$f
  nohup setsid bash -c 'echo \$\$ > /tmp/strata-active.pid; exec > /dev/null 2>&1; nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -lms 1000 | while read -r u; do u=\${u%%.*}; [ "\$u" -ge $IDLE_GPU_UTIL ] 2>/dev/null && date +%s > /tmp/strata-active; done' < /dev/null > /dev/null 2>&1 &
fi
[ -s \$f ] && echo "STRATA_IDLE_SECONDS=\$(( \$(date +%s) - \$(cat \$f) ))"
EOF

case "${1:-}" in
  logs)
    capture_log
    ;;
  status)
    s="$(state)"; printf 'MANAGER_STATE=%s\n' "$s"
    if [[ "$s" != unknown ]]; then timeout -k 5 45 colab usage </dev/null || true; fi
    if [[ "$s" == present ]] && ctl check >/dev/null 2>&1; then
      timeout 12 ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'nvidia-smi --query-gpu=name,memory.used,memory.total --format=csv,noheader; free -g | sed -n 2p' || true
      # 使われているかどうか: Colab側でGPU使用率を1秒ごとに見て、推論が動いた最後の時刻を残す（初回に見張りを起動）。
      # Managerはこの秒数で「無操作で停止」を判断する。取れなければ何も出さない（Manager側では更新されないまま）。
      timeout 12 ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$IDLE_PROBE" || true
    fi
    ;;
  stop)
    touch "$STOP"
    phase stopping
    # Setup owns this lock until provisioning completes. Do not kill colab new:
    # the assignment could otherwise be created without its ID being saved.
    exec 8>"$APP/state/setup.lock"
    flock -w 240 8 || { phase stop-unconfirmed; echo 'Provisioning still active; retry stop.' >&2; exit 1; }
    stop_tunnel || true
    stop_master || true
    stop_confirmed
    ;;
  start|restart|reconnect)
    action="$1"
    exec 8>"$APP/state/setup.lock"
    flock -n 8 || { echo 'Another setup is active.' >&2; exit 2; }
    # The GUI clears stop.request BEFORE it starts a new operation.
    cancel_check
    setup_ok=0
    # reconnect はトンネルを張り直すだけ。SSH が一時的に通らなくても、動いているランタイム（と読み込み済みのモデル）は止めない。
    # 以前はここでも失敗時に止めていて、2026-11-09 01:30 に切断の試験の後の再接続でランタイムを失った。
    [[ "$action" == reconnect ]] && setup_ok=1
    on_exit() {
      rc=$?
      if [[ "$setup_ok" == 0 ]]; then
        echo "[manager] setup ended ($rc); stopping runtime"
        stop_confirmed || true
      fi
    }
    trap on_exit EXIT
    phase checking
    s="$(state)"
    [[ "$s" != unknown ]] || { echo 'Cannot establish runtime state.' >&2; exit 3; }
    if [[ "$s" == absent ]]; then
      [[ "$action" == start ]] || { echo 'No runtime. Use Start.' >&2; setup_ok=1; exit 4; }
      phase allocating
      args=(-s strata --gpu A100)
      [[ "$HIGH_MEM" == 1 ]] && args+=(--high-mem)
      audit colab new "${args[@]}"
      colab new "${args[@]}"
    fi
    cancel_check
    phase ssh
    audit function:wait_ssh "source=$BASE/lib/common.sh"
    wait_ssh
    cancel_check
    gpu="$(rssh 'nvidia-smi --query-gpu=name,memory.total --format=csv,noheader')"
    echo "[manager] GPU: $gpu"
    [[ "$gpu" == *A100* ]] || { echo 'Unexpected GPU; stopping.' >&2; exit 5; }
    if [[ "$action" != reconnect ]]; then
      stop_tunnel || true
      phase preparing
      # Provisioning can reset the SSH transport while apt/python are installed.
      # The setup is idempotent: retry without forcing another restart.
      force=0; [[ "$action" == restart ]] && force=2
      # 変換済み MTP のキャッシュ用に Google Drive を並行してマウントする。失敗してもキャッシュなしで進む
      audit function:drive_mount "token=${DRIVE_TOKEN:-}"
      (drive_mount) &
      started=0
      for attempt in 1 2 3; do
        cancel_check
        audit function:remote_start "$force" "source=$BASE/lib/common.sh" "model=$MODEL" "context=$CONTEXT" "port=$REMOTE_PORT"
        if (remote_start "$force"); then started=1; break; fi
        echo "[manager] SSH/setup interrupted; retry $attempt/3"
        force=0
        sleep 5
        (wait_ssh) || true
      done
      [[ "$started" == 1 ]] || exit 6
      deadline=$((SECONDS + HEALTH_TIMEOUT_MIN * 60))
      while ! remote_healthy; do
        cancel_check
        capture_log
        status="$(remote_poll || true)"
        echo "[manager] $status"
        [[ "$status" != EXITED && "$status" != NOT_RUNNING && "$status" != PORT_IN_USE ]] || exit 6
        (( SECONDS < deadline )) || { echo 'Startup timeout.' >&2; exit 7; }
        sleep 15
      done
      capture_log
    else
      remote_healthy || { echo 'Runtime exists but inference is not ready. Use Start.' >&2; setup_ok=1; exit 8; }
    fi
    cancel_check
    setup_ok=1
    trap - EXIT
    flock -u 8
    phase ready
    audit function:run_tunnel_foreground "source=$BASE/lib/common.sh"
    run_tunnel_foreground
    ;;
  *) echo 'Usage: bridge.sh status|start|restart|reconnect|stop' >&2; exit 2;;
esac
