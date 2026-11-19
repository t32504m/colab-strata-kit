#!/usr/bin/env bash
# 各スクリプト共通の設定読み込みと関数。source して使う。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT/.state"
TUNNEL_PID_FILE="$STATE_DIR/tunnel.pid"
mkdir -p "$STATE_DIR"

# Windows のエディターで保存すると改行が CRLF になり、値の末尾に \r が付いてしまうので、取り除いてから読む
# shellcheck disable=SC1090
load_config() { source <(tr -d '\r' < "$1"); }
load_config "$ROOT/config.env"
if [[ -f "$ROOT/config.local.env" ]]; then
    load_config "$ROOT/config.local.env"
fi
# shellcheck source=messages.sh
source "$ROOT/lib/messages.sh"

# 古い config.env に無い値の既定
HF_TOKEN="${HF_TOKEN:-}"
MTP_CACHE_TOKEN="${MTP_CACHE_TOKEN:-}"
MODEL_FAMILY="${MODEL_FAMILY:-}"
MODEL_REPO="${MODEL_REPO:-}"
MODEL_FILES="${MODEL_FILES:-}"
MODEL_REVISION="${MODEL_REVISION:-}"
FAST_SETUP="${FAST_SETUP:-1}"
TIMELINE_LOG="${TIMELINE_LOG:-/content/strata-timeline.log}"
FAST_DOWNLOAD="${FAST_DOWNLOAD:-1}"
FAST_SHM="${FAST_SHM:-1}"
MTP_CACHE_REPO="${MTP_CACHE_REPO:-}"
DRIVE_CACHE="${DRIVE_CACHE:-0}"
DRIVE_MOUNT="${DRIVE_MOUNT:-/content/drive}"
DRIVE_CACHE_DIR="${DRIVE_CACHE_DIR:-$DRIVE_MOUNT/MyDrive/strata-colab-cache}"
DRIVE_STATUS=/content/.strata-colab/drive-status
# この起動の目印。Drive のマウント結果をこれと一緒に書き、VM 側の strata_fast.py が前回の結果と取り違えないようにする
DRIVE_TOKEN="${DRIVE_TOKEN:-$(date +%s%N)}"

# ssh_config が $COLAB_SESSION を参照する
export COLAB_SESSION
command -v colab >/dev/null 2>&1 || export PATH="$HOME/.local/bin:$PATH"

SSH_HOST="${SSH_HOST:-colab-strata}"
SSH_OPTS=(-F "$ROOT/ssh_config")
# 共有 SSH 接続のソケットの置き場所
mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"

log()  { printf '\033[36m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[33m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '\033[31m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

require_cmds() {
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || die "$(msg cmd_missing "$c")"
    done
}

# ランタイムがあるかを colab status の出力で判定する
session_exists() {
    local out
    out="$(colab status -s "$COLAB_SESSION" 2>&1)" || return 1
    ! grep -qi "not found" <<<"$out"
}

# ssh_config の ControlMaster で作った共有 SSH 接続への操作。新しい接続は作らない
ctl() { ssh "${SSH_OPTS[@]}" -O "$1" "${@:2}" "$SSH_HOST"; }

# 共有 SSH 接続を用意する。Colab のランタイムには同時に 1 本しか SSH をつなげないため、
# すべての ssh はこの 1 本に相乗りする。
ensure_master() {
    ctl check >/dev/null 2>&1 && return 0
    (
        flock 9
        ctl check >/dev/null 2>&1 && exit 0
        setsid -w ssh "${SSH_OPTS[@]}" -o ControlMaster=yes -N -f "$SSH_HOST"
    ) 9>"$HOME/.ssh/colab-cm-$COLAB_SESSION.lock"
}

# Colab VM 上でコマンドを実行する。
# colab ssh はランタイムが無いと新しく作るので、先に存在を確かめる。
rssh() {
    if ! session_exists; then
        warn "$(msg no_runtime_skip_ssh "$COLAB_SESSION")"
        return 255
    fi
    ensure_master || return 255
    ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"
}

# 指定した変数を「NAME=値 ...」の形にして、リモートのコマンドの前に付けられるようにする
remote_env() {
    local v out=""
    for v in "$@"; do out+="$v=$(printf '%q' "${!v}") "; done
    printf '%s' "$out"
}

remote_healthy() {
    rssh "curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/health >/dev/null" 2>/dev/null
}

# remote-setup.sh と同じ値にしておくこと
EXIT_MARK='[strata-colab-cli] setup.sh exited'
PORT_ERR_RE='already in use|address in use|eaddrinuse'

# Colab VM で Strata を起動する。起動済み・起動中なら何もしない。引数 1 なら止めてからやり直す。
remote_start() {
    local FORCE_RESTART="${1:-0}"
    # 表示する文章も一緒に送り、言語は手元で決めたものを使わせる。
    # 秘密の値はコマンドラインに載せず、流し込む本体の先頭に代入文として付ける
    # strata_fast.py は base64 にして同じ流し込みの先頭に付ける
    {
        printf 'API_KEY=%q\nHF_TOKEN=%q\nMTP_CACHE_TOKEN=%q\n' "$API_KEY" "$HF_TOKEN" "$MTP_CACHE_TOKEN"
        if [[ "$FAST_SETUP" == 1 ]]; then
            printf 'FAST_PY_B64=%q\n' "$(base64 -w0 < "$ROOT/lib/strata_fast.py")"
        fi
        cat "$ROOT/lib/messages.sh" "$ROOT/lib/remote-setup.sh"
    } | rssh "$(remote_env STRATA_REPO STRATA_REF REMOTE_DIR DATA_DIR MODEL CONTEXT REMOTE_PORT STRATA_EXTRA_ARGS REMOTE_LOG \
                MODEL_FAMILY MODEL_REPO MODEL_FILES MODEL_REVISION FORCE_RESTART MSG_LANG FAST_SETUP TIMELINE_LOG \
                FAST_DOWNLOAD FAST_SHM MTP_CACHE_REPO DRIVE_CACHE DRIVE_CACHE_DIR DRIVE_STATUS DRIVE_TOKEN) bash -s"
}

# Google Drive を VM にマウントし、結果を「目印 状態」の形で DRIVE_STATUS に書く。状態は mounted / needs-auth / failed。
# 変換済みの MTP の置き場所に使う。remote_start と並行して呼んでよい。VM 側はこの結果を最大 4 分待ち、
# 来なければキャッシュなしで進む。初回の許可が済んでいなければ、対話なしでは許可できないので needs-auth になる。
drive_mount() {
    [[ "$DRIVE_CACHE" == 1 && "$FAST_SETUP" == 1 ]] || return 0
    local st=failed out q_mnt
    q_mnt="$(printf '%q' "$DRIVE_MOUNT")"
    if rssh "test -d $q_mnt/MyDrive" 2>/dev/null; then
        st=mounted
    else
        # 許可が要るときの colab drivemount は URL を出して Enter を待ち続けるので、URL が出たら打ち切る
        local tmp pid i
        tmp="$(mktemp)"
        timeout 180 colab drivemount -s "$COLAB_SESSION" "$DRIVE_MOUNT" </dev/null >"$tmp" 2>&1 &
        pid=$!
        for i in $(seq 1 90); do
            kill -0 "$pid" 2>/dev/null || break
            if grep -qi 'authorization needed\|press enter' "$tmp"; then kill "$pid" 2>/dev/null; break; fi
            sleep 2
        done
        wait "$pid" 2>/dev/null || true
        out="$(cat "$tmp")"
        rm -f "$tmp"
        if rssh "test -d $q_mnt/MyDrive" 2>/dev/null; then
            st=mounted
        elif grep -qi 'authorization needed\|unauthorized\|visit' <<<"$out"; then
            st=needs-auth
        fi
        [[ "$st" == mounted ]] || printf '%s\n' "$out" | tail -n 5 | sed 's/^/    [drive] /' >&2
    fi
    rssh "mkdir -p $(dirname "$DRIVE_STATUS") && echo $(printf '%q' "$DRIVE_TOKEN $st") > $(printf '%q' "$DRIVE_STATUS")" \
        2>/dev/null || true
    case "$st" in
        mounted) log "$(msg drive_mounted "$DRIVE_CACHE_DIR")" ;;
        needs-auth) warn "$(msg drive_needs_auth "$COLAB_SESSION")" ;;
        *) warn "$(msg drive_failed)" ;;
    esac
}

# Colab 側の状態を 1 回の SSH で調べる: HEALTHY / PORT_IN_USE / EXITED / ログの最終行
remote_poll() {
    local q_log
    q_log="$(printf '%q' "$REMOTE_LOG")"
    rssh "if curl -sf -m 5 http://127.0.0.1:$REMOTE_PORT/health >/dev/null 2>&1; then echo HEALTHY;
          elif tail -n 40 $q_log 2>/dev/null | grep -qiE '$PORT_ERR_RE'; then echo PORT_IN_USE;
          elif tail -n 5 $q_log 2>/dev/null | grep -qF '$EXIT_MARK'; then echo EXITED;
          elif ! tmux has-session -t strata 2>/dev/null; then echo NOT_RUNNING;
          else tail -c 400 $q_log 2>/dev/null | tr '\r' '\n' | grep -v '^[[:space:]]*\$' | tail -n 1; fi" \
        2>/dev/null || msg ssh_no_response
}

# 起動完了を待つ。ポート使用中などで setup.sh が落ちたら SETUP_RETRIES 回までやり直す。
wait_healthy() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT_MIN * 60)) status why retries=0
    while true; do
        status="$(remote_poll)"
        case "$status" in
            HEALTHY) return 0 ;;
            PORT_IN_USE|EXITED|NOT_RUNNING)
                case "$status" in
                    PORT_IN_USE) why="$(msg why_port_in_use "$REMOTE_PORT")" ;;
                    EXITED)      why="$(msg why_setup_exited)" ;;
                    *)           why="$(msg why_not_running)" ;;
                esac
                (( retries < SETUP_RETRIES )) ||
                    die "$(msg retry_exhausted "$why" "$SETUP_RETRIES")"
                retries=$((retries + 1))
                warn "$(msg retry_setup "$why" "$retries" "$SETUP_RETRIES")"
                remote_start 1
                deadline=$((SECONDS + HEALTH_TIMEOUT_MIN * 60))
                ;;
            *) if [[ -n "${status//[[:space:]]/}" ]]; then printf '    %s\n' "${status:0:160}"; fi ;;
        esac
        (( SECONDS < deadline )) || die "$(msg start_timeout "$HEALTH_TIMEOUT_MIN")"
        sleep "$POLL_SEC"
    done
}

local_healthy() { curl -sf -m 5 "http://127.0.0.1:$LOCAL_PORT/health" >/dev/null 2>&1; }

local_port_in_use() { ss -ltnH "sport = :$LOCAL_PORT" 2>/dev/null | grep -q .; }

# SSH が通るまで待つ。VM の起動直後は少し時間がかかる
wait_ssh() {
    local i err
    for i in 1 2 3 4 5 6; do
        err="$(rssh true 2>&1 >/dev/null)" && return 0
        if grep -q "429" <<<"$err"; then
            warn "$(msg ssh_busy_429 "$i")"
        else
            warn "$(msg ssh_waiting "$i")"
        fi
        sleep 10
    done
    die "$(msg ssh_failed)"
}

# ---- 共有 SSH 接続のトンネル ----
stop_master() { ctl exit >/dev/null 2>&1 || true; }

FWD_SPEC="127.0.0.1:$LOCAL_PORT:127.0.0.1:$REMOTE_PORT"
KEEPALIVE_PID=""

# 共有 SSH 接続にポート転送を足す。
# ウィンドウを開いている間は、接続を保つための何もしないセッションを 1 本つないでおく。
open_link() {
    rssh true || return 1
    if [[ -z "$KEEPALIVE_PID" ]] || ! kill -0 "$KEEPALIVE_PID" 2>/dev/null; then
        # shellcheck disable=SC2016
        ssh "${SSH_OPTS[@]}" "$SSH_HOST" 'while kill -0 $PPID 2>/dev/null; do sleep 30; done' \
            </dev/null >/dev/null 2>&1 &
        KEEPALIVE_PID=$!
    fi
    ctl forward -L "$FWD_SPEC" >/dev/null 2>&1
}

close_link() {
    if [[ -n "$KEEPALIVE_PID" ]]; then
        kill "$KEEPALIVE_PID" 2>/dev/null || true
        KEEPALIVE_PID=""
    fi
    ctl cancel -L "$FWD_SPEC" >/dev/null 2>&1 || true
}

open_browser() {
    local url="http://localhost:$LOCAL_PORT"
    if command -v cmd.exe >/dev/null 2>&1; then
        (cd /mnt/c 2>/dev/null || true; cmd.exe /c start "" "$url" >/dev/null 2>&1) || true
    elif command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || true
    fi
}

print_endpoints() {
    local base="http://localhost:$LOCAL_PORT"
    echo
    echo "  $(msg ep_webui "$base")"
    echo "  $(msg ep_openai "$base/v1")"
    echo "  $(msg ep_anthropic "$base/v1/messages")"
    echo "  $(msg ep_apikey "${API_KEY:-$(msg ep_apikey_unset)}")"
    echo
}

# 別のウィンドウでトンネルを保っている up.sh / tunnel.sh を止める。トンネルはその終了処理が閉じる
stop_tunnel() {
    local pid
    pid="$(cat "$TUNNEL_PID_FILE" 2>/dev/null)" || return 0
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        local i
        for i in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    fi
    rm -f "$TUNNEL_PID_FILE"
}

# トンネルをこのプロセスで保持する。ウィンドウを閉じるか Ctrl+C でトンネルだけ切れる。
run_tunnel_foreground() {
    local other
    other="$(cat "$TUNNEL_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$other" && "$other" != "$$" ]] && kill -0 "$other" 2>/dev/null && local_healthy; then
        log "$(msg tunnel_already)"
        [[ "$OPEN_BROWSER" == 1 ]] && open_browser
        print_endpoints
        return 0
    fi
    # 前回のウィンドウが残した転送があれば外してから、ポートが空いているか確かめる
    close_link
    if local_port_in_use; then
        die "$(msg local_port_busy "$LOCAL_PORT")"
    fi

    echo "$$" > "$TUNNEL_PID_FILE"
    trap 'close_link; rm -f "$TUNNEL_PID_FILE"; echo; warn "$(msg tunnel_closed)"' EXIT
    trap 'exit 130' INT TERM

    open_link || die "$(msg tunnel_failed)"
    local i
    for i in $(seq 1 30); do
        local_healthy && break
        sleep 2
    done
    local_healthy || die "$(msg tunnel_unreachable)"

    log "$(msg ready)"
    [[ "$OPEN_BROWSER" == 1 ]] && open_browser
    print_endpoints
    log "$(msg tunnel_hold)"
    watch_strata
}

LINK_CHECK_SEC="${LINK_CHECK_SEC:-5}"

# 共有接続か転送が消えたときに、すぐ張り直す。ランタイムが無ければ何もしない（下の見張りが扱う）。
relink_now() {
    local t0=$SECONDS
    warn "$(msg link_lost)"
    close_link
    # 共有接続のプロセスが突然終わると、ソケットのファイルが残る。残っていると新しい共有接続を作れず
    # （"ControlSocket ... already exists, disabling multiplexing"）、張り直しが失敗し続ける。応答しないソケットだけ消す。
    if ! ctl check >/dev/null 2>&1; then
        rm -f "$HOME/.ssh/colab-cm-$COLAB_SESSION"
    fi
    if open_link; then
        log "$(msg link_restored "$((SECONDS - t0))")"
    else
        warn "$(msg relink_retry_later)"
    fi
}

# トンネルを保っている間、Strata が応答するか見張る。
# Colab 側で落ちていたらセットアップをやり直し、トンネルだけが切れていたら張り直す。
watch_strata() {
    local fails=0 waited
    while true; do
        # 共有 SSH 接続（転送もこの上にある）が切れたら、応答の確認を待たずにすぐ張り直す。
        # Colab の中継で接続が切れると転送ごと消えるので、30 秒ごとの応答確認 2 回（60〜90 秒）を待つと、
        # クライアント（dsh の再試行は約 16 秒）が先に諦めてしまう。ctl check と ss は手元だけで済み、軽い。
        waited=0
        while (( waited < WATCH_SEC )); do
            sleep "$LINK_CHECK_SEC"
            waited=$((waited + LINK_CHECK_SEC))
            if ! ctl check >/dev/null 2>&1 || ! local_port_in_use; then
                relink_now
            fi
        done
        if local_healthy; then
            fails=0
            continue
        fi
        fails=$((fails + 1))
        (( fails >= 2 )) || continue    # 一度だけの失敗は様子を見る
        fails=0

        session_exists || { warn "$(msg runtime_stopped "$COLAB_SESSION")"; break; }
        # SSH 自体が通らないときは、Strata が落ちたのではなく接続の問題。セットアップには進まず、張り直しを続ける
        # （以前は remote_healthy の失敗を「Strata が落ちた」と取り違え、復旧に失敗してトンネルごと終わっていた）。
        if ! ensure_master >/dev/null 2>&1; then
            warn "$(msg relink_retry_later)"
            continue
        fi
        if remote_healthy; then
            warn "$(msg tunnel_stuck)"
            open_link || warn "$(msg relink_retry_later)"
            continue
        fi
        warn "$(msg strata_down_recovering)"
        # set -e のもとで 1 回の失敗でトンネルごと終わらないように、失敗したら次の確認でやり直す
        if ! remote_start 0 || ! wait_healthy; then
            warn "$(msg relink_retry_later)"
            continue
        fi
        open_link || warn "$(msg relink_retry_later)"
        log "$(msg recovered)"
    done
}
