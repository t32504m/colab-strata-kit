#!/usr/bin/env bash
# colab CLI（0.8 以降）がログインのトークンを置く場所を、WSL のホームのファイルにする。sudo は要らない。
#
# 0.8 からトークンは OS のキーリングに置かれる。WSL に GNOME keyring があると、保存のたびに
# 「キーリングを作る」「ロックを解除する」の画面が出る（WSL はログイン時にキーリングを開かないため）。
# keyrings.alt のファイル保存（~/.local/share/python_keyring/、本人だけが読める）を使えば、聞かれない。
# 0.8 より前の ~/.config/colab-cli/token.json と同じく、暗号化はしない。
set -euo pipefail

# shellcheck source=lib/messages.sh
source "$(dirname "$0")/lib/messages.sh"
export PATH="$HOME/.local/bin:$PATH"

backend='keyrings.alt.file.PlaintextKeyring'
cfg="${XDG_CONFIG_HOME:-$HOME/.config}/python_keyring/keyringrc.cfg"
py="$(uv tool dir)/google-colab-cli/bin/python"

msg sk_title; echo
if [[ ! -x "$py" ]]; then
    msg sk_no_colab; echo
    exit 1
fi

if ! "$py" -c 'import keyrings.alt' 2>/dev/null; then
    # --with は uv が覚えるので、この後の uv tool upgrade でも残る
    uv tool install --force google-colab-cli --with keyrings.alt
fi

if [[ -f "$cfg" ]] && ! grep -q "^default-keyring *= *$backend" "$cfg"; then
    # 本人が別のキーリングを選んでいるので触らない
    msg sk_other_cfg "$cfg"; echo
else
    mkdir -p "$(dirname "$cfg")"
    printf '[backend]\ndefault-keyring=%s\n' "$backend" > "$cfg"
fi

got="$("$py" -c 'import keyring; k = keyring.get_keyring(); print(type(k).__module__ + "." + type(k).__name__)')"
if [[ "$got" == "$backend" ]]; then
    msg sk_ok; echo
else
    msg sk_ng "$got"; echo
    exit 1
fi
