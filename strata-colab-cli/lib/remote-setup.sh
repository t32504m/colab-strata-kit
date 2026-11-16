#!/usr/bin/env bash
# Colab VM 上で実行される。手元の lib/common.sh が lib/messages.sh と一緒に ssh 経由で標準入力から流し込む。
# 受け取る変数: STRATA_REPO REMOTE_DIR DATA_DIR MODEL CONTEXT REMOTE_PORT STRATA_EXTRA_ARGS REMOTE_LOG
#               MODEL_FAMILY MODEL_REPO MODEL_FILES MODEL_REVISION
#               FORCE_RESTART: 1 なら進行中でも止めてやり直す。2 なら起動済みでも止めて、新しい設定で起動し直す
#               MSG_LANG: 表示する言語。ja か en
#               FAST_SETUP: 1 なら setup.sh の代わりに strata_fast.py で、モデルの取得を先に並行して始める
#               TIMELINE_LOG: 各工程の時刻を記録するファイル
#               MTP_CACHE_REPO: 変換済み MTP を置く Hugging Face の非公開リポジトリ。auto なら <ユーザー名>/strata-colab-cache
#               DRIVE_CACHE DRIVE_CACHE_DIR DRIVE_STATUS DRIVE_TOKEN: 変換済み MTP の Google Drive キャッシュ (lib/common.sh の drive_mount)
# 秘密の値 API_KEY と HF_TOKEN と MTP_CACHE_TOKEN は、コマンドラインに出さないよう、流し込む本体の先頭に代入文として付けて送られる。
# strata_fast.py の中身は FAST_PY_B64 に base64 で入って、同じく本体の先頭に付けて送られる。
set -euo pipefail

TMUX_SESSION=strata
EXIT_MARK='[strata-colab-cli] setup.sh exited'
PORT_ERR_RE='already in use|address in use|eaddrinuse'
FORCE_RESTART="${FORCE_RESTART:-0}"
FAST_SETUP="${FAST_SETUP:-0}"
FAST_PY_B64="${FAST_PY_B64:-}"
TIMELINE_LOG="${TIMELINE_LOG:-/content/strata-timeline.log}"
WORK_DIR="$(dirname "$REMOTE_DIR")/.strata-colab"
PREFETCH_LOG_DIR="$(dirname "$REMOTE_LOG")/strata-prefetch"
REMOTE_T0="$(date +%s.%N)"

rmsg() { echo "[remote] $(msg "$@")"; }

# 工程の時刻を strata_fast.py と同じ形式 (JSON Lines) で残す。tl イベント名 [追加の項目名 値]
tl() {
    local now extra=""
    now="$(date +%s.%N)"
    [[ $# -ge 3 ]] && extra=", \"$2\": \"${3//\"/}\""
    printf '{"t": "%s", "s": %s, "pid": %s, "event": "%s"%s}\n' \
        "$(date +%Y-%m-%dT%H:%M:%S.%3N)" "$(awk -v a="$now" -v b="$REMOTE_T0" 'BEGIN{printf "%.1f", a-b}')" "$$" "$1" \
        "$extra" >> "$TIMELINE_LOG" 2>/dev/null || true
}

if [[ "$FORCE_RESTART" == 2 ]]; then
    rmsg r_restart
elif curl -sf -m 5 "http://127.0.0.1:$REMOTE_PORT/health" >/dev/null 2>&1; then
    rmsg r_already_running
    exit 0
elif command -v tmux >/dev/null 2>&1 && tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    if [[ "$FORCE_RESTART" == 1 ]]; then
        rmsg r_redo
    elif tail -n 5 "$REMOTE_LOG" 2>/dev/null | grep -qF "$EXIT_MARK"; then
        rmsg r_prev_exited
    elif tail -n 40 "$REMOTE_LOG" 2>/dev/null | grep -qiE "$PORT_ERR_RE"; then
        rmsg r_port_fail_restart "$REMOTE_PORT"
    else
        rmsg r_in_progress
        exit 0
    fi
fi

# ここから起動し直す。前回の時刻記録と先行取得のログは .prev に残す
[[ -f "$TIMELINE_LOG" ]] && mv -f "$TIMELINE_LOG" "$TIMELINE_LOG.prev"
if [[ -d "$PREFETCH_LOG_DIR" ]]; then
    rm -rf "$PREFETCH_LOG_DIR.prev"
    mv -f "$PREFETCH_LOG_DIR" "$PREFETCH_LOG_DIR.prev"
fi
tl remote-setup-begin

need_pkg() {
    command -v "$1" >/dev/null 2>&1 && return 0
    rmsg r_installing "$2"
    apt-get -qq update >/dev/null
    apt-get -qq install -y "$2" >/dev/null
}
need_pkg tmux tmux
need_pkg ss iproute2

# ---- 前回の Strata を片付けて、ポートを空ける ----
# 止めるのは、作業フォルダか実行ファイルが Strata のフォルダの中にあるプロセスだけ。
under_strata() {
    [[ -n "$1" ]] || return 1
    [[ "$1" == "$REMOTE_DIR" || "$1" == "$REMOTE_DIR"/* || "$1" == "$DATA_DIR" || "$1" == "$DATA_DIR"/* ]]
}
is_strata_pid() {
    local cwd exe
    cwd="$(readlink "/proc/$1/cwd" 2>/dev/null)" || return 1
    exe="$(readlink "/proc/$1/exe" 2>/dev/null)" || true
    under_strata "$cwd" || under_strata "$exe"
}
strata_pids() {
    local d p
    for d in /proc/[0-9]*; do
        p="${d#/proc/}"
        [[ "$p" == "$$" || "$p" == "$PPID" ]] && continue
        is_strata_pid "$p" && echo "$p"
    done
    return 0
}
port_pids() {
    ss -ltnpH "sport = :$REMOTE_PORT" 2>/dev/null | grep -o 'pid=[0-9]*' | cut -d= -f2 | sort -u
}
kill_and_wait() {
    local p alive i
    kill "$@" 2>/dev/null || true
    for i in $(seq 1 10); do
        alive=""
        for p in "$@"; do kill -0 "$p" 2>/dev/null && alive+="$p "; done
        [[ -z "$alive" ]] && return 0
        sleep 1
    done
    # shellcheck disable=SC2086
    kill -9 $alive 2>/dev/null || true
    sleep 1
}

tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
mapfile -t old < <(strata_pids)
if (( ${#old[@]} > 0 )); then
    rmsg r_stop_old "${old[*]}"
    kill_and_wait "${old[@]}"
fi

mapfile -t holders < <(port_pids)
if (( ${#holders[@]} > 0 )); then
    others=""
    for p in "${holders[@]}"; do
        if is_strata_pid "$p"; then
            kill_and_wait "$p"
        else
            others+="  pid $p: $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-120)"$'\n'
        fi
    done
    if [[ -n "$others" ]]; then
        rmsg r_port_other "$REMOTE_PORT"
        printf '%s' "$others"
        rmsg r_port_other_hint
        exit 3
    fi
fi

# ---- Strata の取得 ----
if [[ ! -d "$REMOTE_DIR/.git" ]]; then
    rmsg r_cloning "$STRATA_REPO"
    git clone --depth 1 "$STRATA_REPO" "$REMOTE_DIR"
    tl clone-done
fi
# どのコミットの Strata で動いたかを、時刻の記録と一緒に残す
tl strata-commit commit "$(git -C "$REMOTE_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"

# ---- Python ----
# Strata の setup.sh は PATH 上の python3 で venv を作る。venv が作れる Python を探して PATH の先頭に置く。
ok_py() { "$1" -c 'import sys, venv, ensurepip; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; }
find_py() {
    local c
    for c in $(type -ap python3 python3.12 python3.11 python3.10) \
             /usr/bin/python3 /usr/bin/python3.12 /usr/bin/python3.11 /usr/bin/python3.10; do
        if [[ -x "$c" ]] && ok_py "$c"; then
            echo "$c"
            return 0
        fi
    done
    return 1
}
# Colab's Python has venv but no ensurepip. With strata_fast.py (and no custom model, whose check runs setup.sh itself), the
# venv is made with --without-pip and the system pip installs pip into it (pip --python, pip >= 22.3): apt-get update and
# install took 15-46 s per start (live runs 3 and 5).  Otherwise python3-venv is installed as before.
nopip_py() {
    local c
    for c in $(type -ap python3 python3.12 python3.11 python3.10) /usr/bin/python3 /usr/bin/python3.12; do
        if [[ -x "$c" ]] && "$c" -c 'import sys, venv; sys.exit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null &&
           "$c" -m pip --help 2>/dev/null | grep -- '--python ' >/dev/null; then
            echo "$c"
            return 0
        fi
    done
    return 1
}
STRATA_VENV_NOPIP=0
if ! PY="$(find_py)"; then
    if [[ "$FAST_SETUP" == 1 && -n "$FAST_PY_B64" && -z "$MODEL_REPO" ]] && PY="$(nopip_py)"; then
        STRATA_VENV_NOPIP=1
    else
        rmsg r_py_install
        apt-get -qq update >/dev/null
        apt-get -qq install -y python3 python3-venv python3-pip >/dev/null
        PY="$(find_py)" || { rmsg r_py_missing; exit 1; }
    fi
fi
PY_SHIM_DIR="$(dirname "$REMOTE_DIR")/.strata-python"
mkdir -p "$PY_SHIM_DIR"
ln -sf "$PY" "$PY_SHIM_DIR/python3"
ln -sf "$PY" "$PY_SHIM_DIR/python"
rmsg r_py "$PY" "$("$PY" --version 2>&1)"
tl python-ready nopip "$STRATA_VENV_NOPIP"

# ---- 保存済み設定のポート ----
# Strata は保存済みの設定 strata-<model>.json のポートで起動するので、REMOTE_PORT に合わせる。
for f in "$REMOTE_DIR"/strata-*.json; do
    [[ -f "$f" ]] || continue
    old_ports="$("$PY" - "$f" "$REMOTE_PORT" <<'PYEOF'
import json, sys
path, port = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)
if not isinstance(cfg, dict):
    sys.exit(0)
changed = []
if "port" in cfg and str(cfg["port"]) != str(port):
    changed.append(str(cfg["port"]))
    cfg["port"] = port
args = cfg.get("args")
if isinstance(args, list):
    for i, a in enumerate(args[:-1]):
        if a == "--port" and str(args[i + 1]) != str(port):
            changed.append(str(args[i + 1]))
            args[i + 1] = str(port)
if changed:
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2, ensure_ascii=False)
    print(", ".join(sorted(set(changed))))
PYEOF
)"
    [[ -z "$old_ports" ]] || rmsg r_port_fixed "$f" "$old_ports" "$REMOTE_PORT"
done

# ---- 公式以外のモデル ----
# MODEL_REPO を指定したときだけ、Hugging Face から GGUF を落として --gguf-dir で Strata に渡す。
# ダウンロードは起動と同じ tmux の中で行う。ここでは動かせるファイルかどうかと、ディスクの空きだけを先に確かめる。
GGUF_DIR=""
FETCH_CMD=""
if [[ -n "$MODEL_REPO" ]]; then
    WORK_DIR="$(dirname "$REMOTE_DIR")/.strata-colab"
    HF_VENV="$WORK_DIR/hf-venv"
    HF_TOKEN_FILE="$WORK_DIR/hf_token"
    CUSTOM_DIR="$DATA_DIR/custom/${MODEL_REPO//\//__}"
    PATTERN="${MODEL_FILES:-*${MODEL}*.gguf}"
    mkdir -p "$WORK_DIR" "$CUSTOM_DIR"

    # トークンはコマンドラインに出さず、権限 600 のファイルで渡す
    if [[ -n "${HF_TOKEN:-}" ]]; then
        (umask 077 && printf '%s' "$HF_TOKEN" > "$HF_TOKEN_FILE")
    else
        rm -f "$HF_TOKEN_FILE"
    fi
    hf_env=()
    [[ -f "$HF_TOKEN_FILE" ]] && hf_env=(HF_TOKEN_PATH="$HF_TOKEN_FILE")

    if [[ ! -x "$HF_VENV/bin/hf" ]]; then
        rmsg r_hf_install
        "$PY" -m venv "$HF_VENV"
        "$HF_VENV/bin/python" -m pip install -q --disable-pip-version-check "huggingface_hub[hf_xet]"
    fi

    # 1. Strata 自身に、ヘッダーだけを読んで動かせるファイルかを確かめさせる
    rmsg r_custom_inspect "$MODEL_REPO" "$MODEL"
    set +e
    (export PATH="$PY_SHIM_DIR:$PATH" HF_TOKEN="${HF_TOKEN:-}"; cd "$REMOTE_DIR" && ./setup.sh --inspect "hf:$MODEL_REPO" "$MODEL")
    rc=$?
    set -e
    if (( rc == 2 )); then
        rmsg r_custom_unsupported "$MODEL_REPO" "$MODEL"
        exit 4
    elif (( rc != 0 )); then
        rmsg r_custom_inspect_unknown "$rc"
    fi

    # 2. 落とすファイルの一覧と大きさを調べ、ディスクの空きと比べる
    set +e
    plan="$(env "${hf_env[@]}" "$HF_VENV/bin/python" - "$MODEL_REPO" "$MODEL_REVISION" "$PATTERN" "$CUSTOM_DIR" <<'PYEOF'
import fnmatch, os, posixpath, shutil, sys
from huggingface_hub import HfApi
repo, rev, pattern, dest = sys.argv[1], sys.argv[2] or None, sys.argv[3], sys.argv[4]
try:
    info = HfApi().model_info(repo, revision=rev, files_metadata=True)
except Exception as e:
    print(f"error={type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(10)
files = [s for s in info.siblings if fnmatch.fnmatch(s.rfilename, pattern)]
if not files:
    sys.exit(3)
dirs = {posixpath.dirname(s.rfilename) for s in files}
if len(dirs) != 1:
    sys.exit(4)
need = 0
for s in files:
    local = os.path.join(dest, s.rfilename)
    have = os.path.getsize(local) if os.path.exists(local) else 0
    if have != (s.size or 0):
        need += (s.size or 0) - have
free = shutil.disk_usage(dest).free
print(f"files={len(files)}")
print(f"subdir={dirs.pop()}")
print(f"need_bytes={need}")
print(f"need_gb={need / 1e9:.1f}")
print(f"free_gb={free / 1e9:.1f}")
sys.exit(5 if need > free * 0.98 else 0)
PYEOF
)"
    rc=$?
    set -e
    plan_get() { sed -n "s/^$1=//p" <<<"$plan"; }
    case "$rc" in
        0) ;;
        3) rmsg r_custom_nofiles "$MODEL_REPO" "$PATTERN"; exit 4 ;;
        4) rmsg r_custom_multidir "$PATTERN"; exit 4 ;;
        5) rmsg r_custom_disk "$(plan_get need_gb)" "$(plan_get free_gb)"; exit 4 ;;
        *) rmsg r_custom_lookup_failed "$MODEL_REPO"; exit 4 ;;
    esac
    GGUF_DIR="$CUSTOM_DIR"
    subdir="$(plan_get subdir)"
    [[ -n "$subdir" ]] && GGUF_DIR="$CUSTOM_DIR/$subdir"
    if [[ "$(plan_get need_bytes)" == "0" ]]; then
        rmsg r_custom_ready "$MODEL_REPO"
    else
        rmsg r_custom_plan "$MODEL_REPO" "$(plan_get files)" "$CUSTOM_DIR" "$(plan_get need_gb)" "$(plan_get free_gb)"
    fi

    # 3. tmux の中で実行するダウンロードのコマンド。済んだファイルは飛ばされ、途中からは再開される
    dl=("$HF_VENV/bin/hf" download "$MODEL_REPO" --include "$PATTERN" --local-dir "$CUSTOM_DIR")
    [[ -n "$MODEL_REVISION" ]] && dl+=(--revision "$MODEL_REVISION")
    FETCH_CMD="env $(printf '%q ' "${hf_env[@]}" "${dl[@]}") && "
fi

# ---- 起動 ----
args=(--model "$MODEL" --context "$CONTEXT" --port "$REMOTE_PORT"
      --data-dir "$DATA_DIR" --no-browser --yes)
[[ -n "$MODEL_FAMILY" ]] && args+=(--family "$MODEL_FAMILY")
[[ -n "$GGUF_DIR" ]] && args+=(--gguf-dir "$GGUF_DIR")
[[ -n "$API_KEY" ]] && args+=(--api-key "$API_KEY")
# STRATA_EXTRA_ARGS は空白で区切って渡す
# shellcheck disable=SC2206
[[ -n "$STRATA_EXTRA_ARGS" ]] && args+=($STRATA_EXTRA_ARGS)

# 前回のログは .prev に残す
[[ -f "$REMOTE_LOG" ]] && mv -f "$REMOTE_LOG" "$REMOTE_LOG.prev"

# ---- setup.sh か、先行取得つきの strata_fast.py か ----
SETUP_CMD=./setup.sh
if [[ "$FAST_SETUP" == 1 && -n "$FAST_PY_B64" ]]; then
    mkdir -p "$WORK_DIR"
    if printf '%s' "$FAST_PY_B64" | base64 -d > "$WORK_DIR/strata_fast.py.tmp"; then
        mv -f "$WORK_DIR/strata_fast.py.tmp" "$WORK_DIR/strata_fast.py"
        # setup.sh と同じ手順で .venv を用意してから、setup.py を strata_fast.py 経由で実行する。
        # .venv を作れなければ setup.sh に任せる
        cat > "$WORK_DIR/fast-setup.sh" <<'SHEOF'
#!/bin/sh
here="$(cd "$(dirname "$0")" && pwd)"
# STRATA_VENV_NOPIP=1: this Python has no ensurepip (remote-setup.sh skipped apt): the venv gets pip from the system pip
mkvenv() {
  if [ "${STRATA_VENV_NOPIP:-0}" = 1 ]; then
    python3 -m venv --without-pip "$1" &&
      python3 -m pip --python "$1/bin/python" install -q --disable-pip-version-check pip
  else
    python3 -m venv "$1"
  fi
}
to_setup_sh() {
  if [ "${STRATA_VENV_NOPIP:-0}" = 1 ]; then         # setup.sh makes its venv with ensurepip
    apt-get -qq update >/dev/null 2>&1; apt-get -qq install -y python3-venv >/dev/null 2>&1
  fi
  exec ./setup.sh "$@"
}
# .venv, engine, engine-feed (not in the repository) on the VM's memory: while the shards fill the disk, ordinary writes wait
# (pip's unpacking took 103 s). Only when the memory folder has 8 GB free; a link left from an earlier run gets its folder again.
# venv will not create into a link, so .venv is created in memory and linked after; any failure leaves it on the disk.
# Colab's /dev/shm is noexec (live run 5: "strata is not executable"), so a tmpfs of our own is mounted (root, CAP_SYS_ADMIN).
shm=
mem=/mnt/strata-mem
if [ "${STRATA_FAST_SHM:-1}" = 1 ] &&
   { mountpoint -q "$mem" 2>/dev/null || { mkdir -p "$mem" 2>/dev/null && mount -t tmpfs -o size=16g,mode=755 tmpfs "$mem" 2>/dev/null; }; } &&
   [ "$(df -Pk "$mem" 2>/dev/null | awk 'NR==2{print $4}')" -ge 8388608 ] 2>/dev/null; then
  shm="$mem/strata-root"
  mkdir -p "$shm" || shm=
fi
export STRATA_FAST_SHM_DIR="$shm"
if [ -n "$shm" ]; then
  for d in engine engine-feed; do
    if [ -L "$d" ]; then
      [ -e "$d" ] || mkdir -p "$(readlink "$d")"
    elif [ ! -e "$d" ]; then
      mkdir -p "$shm/$d" && ln -s "$shm/$d" "$d"
    fi
  done
fi
if [ -x .venv/bin/python ] && ! .venv/bin/python -m pip --version >/dev/null 2>&1; then
  rm -rf .venv
fi
if [ ! -x .venv/bin/python ]; then
  if [ -n "$shm" ] && [ ! -e .venv ]; then
    rm -f .venv; rm -rf "$shm/.venv"
    if mkvenv "$shm/.venv" && ln -s "$shm/.venv" .venv; then
      echo "[fast] .venv, engine, engine-feed are in $shm (memory)"
    else
      rm -f .venv; rm -rf "$shm/.venv"
    fi
  fi
  if [ ! -x .venv/bin/python ]; then
    mkvenv .venv || { rm -rf .venv; echo "[fast] could not create .venv; running setup.sh"; to_setup_sh "$@"; }
  fi
fi
exec .venv/bin/python "$here/strata_fast.py" "$@"
SHEOF
        chmod +x "$WORK_DIR/fast-setup.sh"
        SETUP_CMD="$(printf '%q' "$WORK_DIR/fast-setup.sh")"
        rmsg r_fast_on
    else
        rm -f "$WORK_DIR/strata_fast.py.tmp"
        rmsg r_fast_broken
    fi
fi
fast_env="STRATA_TIMELINE_LOG=$(printf '%q' "$TIMELINE_LOG") STRATA_PREFETCH_LOG_DIR=$(printf '%q' "$PREFETCH_LOG_DIR") STRATA_FAST_T0=$REMOTE_T0 STRATA_FAST_DOWNLOAD=$(printf '%q' "${FAST_DOWNLOAD:-1}") STRATA_FAST_SHM=$(printf '%q' "${FAST_SHM:-1}") STRATA_VENV_NOPIP=$STRATA_VENV_NOPIP"
# Colab のディスクは PLE 表（28.8 GB）のランダム読み出しが 10〜43 MB/s しか出ず、--ple-io direct では長いプロンプトの
# layer 1 で60秒の監視に掛かってエンジンが止まる（exit -6）。遅いと測ったら OS のキャッシュ経由（mmap）に切り替えさせる
fast_env+=" STRATA_PLE_AUTO_MMAP=1"
# キャッシュが冷えていると mmap でも layer 1 が60秒を超える。遅いだけで止まっていないので、監視を600秒に延ばす
fast_env+=" STRATA_WATCHDOG_S=${STRATA_WATCHDOG_S:-600}"

# ---- PLE 表の先読み ----
# エンジンが準備できるたび（起動時、使われずに外れた後の再読み込み、異常終了からの再起動）に、PLE 表を大きな連続読み出しで
# OS のキャッシュに載せる。エキスパートの読み込みがキャッシュを押し出すので、読み込みのたびにやり直す。
# 小さなランダム読み出し（約5000回/秒）では数分かかる量が、連続読み出しなら1〜2分で済む
mkdir -p "$WORK_DIR"
PLE_WARM="$WORK_DIR/ple-warm.sh"
cat > "$PLE_WARM" <<'WARMEOF'
#!/bin/bash
# 引数: ポート、時刻の記録先（JSON Lines）
port=$1; tlog=$2; warmed=""
note() { printf '{"t": "%s", "event": "%s"%s}\n' "$(date +%Y-%m-%dT%H:%M:%S.%3N)" "$1" "${2:+, $2}" >> "$tlog" 2>/dev/null; }
while sleep 5; do
  pid=$(pgrep -f "engine/strata --serve" | head -1)
  [[ -n "$pid" && "$pid" != "$warmed" ]] || continue
  curl -s -m 5 "http://127.0.0.1:$port/health" | grep -q '"loaded": true' || continue
  ple=$(tr '\0' '\n' < /proc/$pid/cmdline | grep -A1 -x -- --ple-gguf | tail -1)
  [[ -f "$ple" ]] || { warmed=$pid; continue; }
  # エキスパートのファイル（読み込み済みで、エンジンは RAM の写しを使う）をキャッシュから外し、表の入る場所を空ける。
  # 表（26.8 GiB）はエキスパートを置いた後の空き（約21 GB）に全部は入らないが、外さないとほとんど残らなかった
  native=$(tr '\0' '\n' < /proc/$pid/cmdline | grep -A1 -x -- --native | tail -1)
  [[ -f "$native" ]] && python3 -c 'import os,sys; fd=os.open(sys.argv[1],os.O_RDONLY); os.posix_fadvise(fd,0,0,os.POSIX_FADV_DONTNEED); os.close(fd)' "$native" 2>/dev/null
  t0=$(date +%s.%N); size=$(stat -c %s "$ple"); part=$(( (size + 4*1048576*4 - 1) / (4*1048576*4) * 1048576*4 ))
  for i in 0 1 2 3; do
    dd if="$ple" of=/dev/null bs=4M skip=$(( i * part / 4194304 )) count=$(( part / 4194304 )) status=none &
  done
  wait
  warmed=$pid
  note ple-warm "\"secs\": $(awk -v a="$(date +%s.%N)" -v b="$t0" 'BEGIN{printf "%.1f", a-b}'), \"gib\": $(awk -v s="$size" 'BEGIN{printf "%.1f", s/1073741824}'), \"engine\": $pid"
done
WARMEOF
chmod +x "$PLE_WARM"
pkill -f "$PLE_WARM" 2>/dev/null || true
nohup setsid "$PLE_WARM" "$REMOTE_PORT" "$TIMELINE_LOG" > /dev/null 2>&1 < /dev/null &
CACHE_TOKEN="${MTP_CACHE_TOKEN:-${HF_TOKEN:-}}"
if [[ -n "${MTP_CACHE_REPO:-}" && -n "$CACHE_TOKEN" ]]; then
    # 変換済み MTP を Hugging Face の非公開リポジトリから復元し、無ければ変換後に保存する。
    # トークンはコマンドラインにも環境変数にも出さず、権限 600 のファイルで strata_fast.py に渡す
    mkdir -p "$WORK_DIR"
    (umask 077 && printf '%s' "$CACHE_TOKEN" > "$WORK_DIR/mtp_cache_token")
    fast_env+=" STRATA_HF_CACHE_REPO=$(printf '%q' "$MTP_CACHE_REPO") STRATA_HF_TOKEN_FILE=$(printf '%q' "$WORK_DIR/mtp_cache_token") STRATA_HF_LIB=$(printf '%q' "$WORK_DIR/hf-lib")"
elif [[ "${DRIVE_CACHE:-0}" == 1 && -n "${DRIVE_TOKEN:-}" ]]; then
    # 手元が並行して Drive をマウントし、結果を DRIVE_STATUS に書く。strata_fast.py はそれを見て MTP のキャッシュを使う
    fast_env+=" STRATA_DRIVE_CACHE_DIR=$(printf '%q' "$DRIVE_CACHE_DIR") STRATA_DRIVE_STATUS=$(printf '%q' "$DRIVE_STATUS") STRATA_DRIVE_TOKEN=$(printf '%q' "$DRIVE_TOKEN")"
fi
tl tmux-launch

cmd="export PATH=$(printf '%q' "$PY_SHIM_DIR"):\$PATH $fast_env; cd $(printf '%q' "$REMOTE_DIR") && { ${FETCH_CMD}${SETUP_CMD} $(printf '%q ' "${args[@]}"); } 2>&1 | tee -a $(printf '%q' "$REMOTE_LOG")"
cmd+="; echo $(printf '%q' "$EXIT_MARK") | tee -a $(printf '%q' "$REMOTE_LOG"); sleep infinity"

# tmux の中で動かすので、SSH が切れてもサーバーは止まらない
tmux new-session -d -s "$TMUX_SESSION" bash -c "$cmd"
rmsg r_started "$MODEL" "$CONTEXT" "$REMOTE_PORT"
