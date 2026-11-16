#!/usr/bin/env bash
# watch_strata / relink_now の模擬テスト（Colab にはつながない）。実行: bash tests/test_watch.sh
# 時計・ssh・curl をすべて偽物に差し替え、接続が切れたときの動きだけを確かめる。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/lib/messages.sh"
eval "$(sed -n '/^LINK_CHECK_SEC=/,/^}/p' "$ROOT/lib/common.sh")"      # LINK_CHECK_SEC と relink_now
eval "$(sed -n '/^watch_strata() {/,/^}/p' "$ROOT/lib/common.sh")"
COLAB_SESSION=test-$$; HOME="$(mktemp -d)"; mkdir -p "$HOME/.ssh"; SOCK="$HOME/.ssh/colab-cm-$COLAB_SESSION"
WATCH_SEC=30; LOG=""
log(){ LOG+="[t=$T] $*"$'\n'; }; warn(){ LOG+="[t=$T] $*"$'\n'; }
pass=0; fail=0
check(){ if eval "$2"; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1"; echo "     -> ${out:-$watch_strata_out}" | head -c 600; echo; fi; }

# 偽物: MASTER=共有接続が生きているか、SSH_OK=新しい接続が作れるか、STRATA=Colab 側の Strata が応答するか
# END に達したら、数えた値を出してサブシェルごと終える（watch_strata は $(...) の中で動かす）
sleep(){ T=$((T + $1)); on_tick; (( T < END )) || { echo "relinks=$RELINKS starts=$STARTS t=$T"; exit 0; }; }
ctl(){ [[ "$1" == check ]] && (( MASTER )); }
local_port_in_use(){ (( MASTER )); }
local_healthy(){ (( MASTER && STRATA )); }
session_exists(){ true; }
close_link(){ :; }
ensure_master(){ [[ -e "$SOCK" ]] && ! (( MASTER )) && return 1; (( SSH_OK )) && { MASTER=1; touch "$SOCK"; }; (( MASTER )); }
open_link(){ ensure_master && RELINKS=$((RELINKS+1)); }
remote_healthy(){ (( MASTER && STRATA )); }
remote_start(){ STARTS=$((STARTS+1)); (( START_OK )); }
wait_healthy(){ (( STRATA )); }

# 1) 共有接続が切れても SSH は通る: 次の確認（5 秒以内）で張り直す
reset(){ MASTER=1; SSH_OK=1; STRATA=1; START_OK=1; touch "$SOCK"; }
reset; END=60; on_tick(){ (( T == 15 )) && MASTER=0 || true; }
watch_strata_out=$(T=0; RELINKS=0; STARTS=0; set +e; watch_strata)
check "切れて 5 秒以内に張り直す" '[[ "$watch_strata_out" == *"relinks=1 starts=0"* ]]'

# 2) 突然切れてソケットのファイルが残る: 古いソケットを消して張り直す
reset; END=60; on_tick(){ (( T == 15 )) && MASTER=0 || true; }   # MASTER=0 でも $SOCK は残っている
out=$(T=0; RELINKS=0; STARTS=0; set +e; watch_strata)
check "残ったソケットを消して張り直す" '[[ "$out" == *"relinks=1"* ]]'

# 3) SSH がしばらく通らない: Strata の再セットアップに進まず、トンネルも終わらず、通るようになったら張り直す
reset; END=200; on_tick(){ (( T == 15 )) && { MASTER=0; SSH_OK=0; }; (( T == 150 )) && SSH_OK=1; true; }
out=$(T=0; RELINKS=0; STARTS=0; set +e; watch_strata)
check "SSH が通らない間はセットアップしない・終わらない" '[[ "$out" == *"starts=0"* && "$out" == *"t=200"* && "$out" == *"relinks=1"* ]]'

# 4) Strata が本当に落ちて、1 回目の復旧が失敗: トンネルは終わらず、次の確認でもう一度復旧する
reset; END=300; on_tick(){ (( T == 15 )) && { STRATA=0; START_OK=0; }; (( T == 130 )) && START_OK=1; (( START_OK && STARTS >= 1 )) && STRATA=1; true; }
out=$(T=0; RELINKS=0; STARTS=0; set +e; watch_strata)
check "復旧の失敗でトンネルが終わらない" '[[ "$out" == *"t=300"* ]] && [[ "$(grep -o "starts=[0-9]*" <<<"$out" | cut -d= -f2)" -ge 2 ]]'

rm -rf "$HOME"
echo "pass=$pass fail=$fail"; (( fail == 0 ))
