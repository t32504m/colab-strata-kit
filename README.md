# Colab Strata キット（Colab Manager と委譲の仕組み）

Google Colab の GPU（A100）で Strata を動かし、Qwen3.8 を手元の PC から使うための一式です。
ノート PC でも、Colab につながれば強い GPU の推論を使えます。

| フォルダ | 中身 |
|---|---|
| `colab-manager\` | Colab Manager（Colab のランタイムの起動・監視・停止をする画面のアプリ） |
| `strata-colab-cli\` | Colab に Strata を立ち上げ、手元の `http://127.0.0.1:8080` に転送するスクリプト（WSL で動く） |
| `delegation\` | 委譲の仕組み（監督の LLM が Qwen3.8 に仕事を渡す）。入口は `delegation\HANDOFF.md`。使わなければ無視してよい |

## 必要なもの
- Windows 10 / 11
- Google Colab で A100 を使えるアカウントと、コンピューティング ユニット（CU）。動いている間、約 6.7 CU/時かかる
- WSL の Ubuntu（無ければ、管理者の PowerShell で `wsl --install -d Ubuntu` を実行し、再起動してユーザー名を決める）
- PowerShell 7（無ければ `winget install --id Microsoft.PowerShell`）
- 任意: DeepSeek Harness（Qwen3.8 とチャットやコード生成をする画面。公式の配布元から入れる）、Git for Windows（委譲を使うとき）

## 準備（最初に1回）
1. キットを手元に置く。どちらでもよい。**ドライブ文字のある場所**に置く（ネットワークのフォルダは不可）。中のフォルダの並びは変えない。
   - リポジトリから（招待を受けている場合。Git for Windows が要る）:
     ```
     git clone <リポジトリの URL> C:\Tools\colab-strata-kit
     ```
   - zip から: 展開して、`colab-strata-kit` フォルダを好きな場所に置く（例: `C:\Tools\colab-strata-kit`）。
2. `install.cmd` をダブルクリックする。次のことを順に行い、済んでいるものは飛ばす。
   - PowerShell 7 と WSL の Ubuntu があるか確かめる
   - WSL に ssh・uv・colab CLI・SSH の鍵を入れる（**sudo のパスワードを聞かれる**）
   - `strata-colab-cli\config.local.env` を雛形から作る
   - Colab CLI に Google アカウントでログインする（**ブラウザが開くので許可する**）
   - DeepSeek Harness が入っていれば、Colab の Strata につなぐ設定を足す
   - 「Colab Manager」のショートカットを、このフォルダとデスクトップに作る
3. 任意: `strata-colab-cli\config.local.env` をメモ帳で開き、`HF_TOKEN=` に Hugging Face のトークンを書く（モデルの取得が速く・安定し、2回目以降の起動も速くなる）。トークンは https://huggingface.co/settings/tokens で作る。
4. 最後に「準備ができました」と出れば完了。「残っていること」が出たら、その指示どおりにしてから `install.cmd` をもう一度実行する。

状態だけを見たいときは、PowerShell で `.\install.ps1 -Check`（何も変えない）。

`install.cmd` の選択肢（PowerShell で `.\install.cmd -SkipLogin` のように付ける）:

| 選択肢 | 意味 |
|---|---|
| `-Check` | 何も変えず、済んでいること・残っていることを表示する |
| `-Distro <名前>` | Ubuntu 以外の名前の WSL ディストリを使う |
| `-SkipWsl` / `-SkipLogin` | WSL の準備 / Colab のログインを飛ばす |
| `-NoDesktopShortcut` | デスクトップにショートカットを作らない |
| `-ReplaceShortcuts` | 別の置き場のキットを指すデスクトップのショートカットを、このキットに向け直す |

## 設定（how to set up）
設定は2か所。どちらも、この PC だけのもので、git にも zip にも入らない。

### 1. Manager の画面で選ぶもの
Manager の画面で、モデル（量子化）、コンテキスト長、起動後に開くもの（DeepSeek Harness / Strata WebUI など）、使われないときに自動で止めるまでの時間を選ぶ。選んだものは `strata-colab-cli\config.local.env` と `colab-manager\state\preferences.json` に保存され、次からはそのまま使われる。

### 2. `strata-colab-cli\config.local.env`（メモ帳で開いて書く）
`install.cmd` が雛形（`config.local.example.env`）から作る。ここに書いた値が `config.env`（全員共通の既定値。書き換えない）より優先される。

| 項目 | 既定 | 意味 |
|---|---|---|
| `HF_TOKEN` | 空 | Hugging Face のトークン。書くとモデルの取得が速く・安定する。https://huggingface.co/settings/tokens で作る（読み取りで足りる）。**秘密の値なので人に見せない** |
| `MTP_CACHE_REPO` | `auto` | 変換済みのデータ（約 0.8 GB）を Hugging Face に非公開で保存し、2回目以降の起動を速くする。`auto` なら `<トークンのユーザー名>/strata-colab-cache`。使わないなら空にする |
| `MTP_CACHE_TOKEN` | 空 | 上の保存に使う、書き込み権限のあるトークン。空なら `HF_TOKEN` を使う（そのときは `HF_TOKEN` に書き込み権限が要る） |
| `HIGH_MEM` | `0` | `1` で High-memory のランタイム（Colab Pro / Pro+ が必要） |
| `ON_GPU_MISMATCH` | `stop` | A100 以外が割り当てられたら止める（CU の無駄を防ぐ） |
| `CONTEXT` / `MODEL` / `STRATA_EXTRA_ARGS` | | Manager の画面が書き換える。手で変えなくてよい |

トークンを書いたら、Manager で起動し直すと使われる。トークンを書かなくても動く（取得が遅いことがあるだけ）。

### 3. DeepSeek Harness を使う場合（任意）
DeepSeek Harness を先に入れてから `install.cmd` を実行すると、「Colab の Strata」をモデルとして選べるように設定を足す。後から入れたときは、`install.cmd` をもう一度実行する。ほかのアプリから使うときは、API の URL（下の「使い方」）を設定する。キーは何でもよい。

## 使い方
1. 「Colab Manager」のショートカットで開く。**開くと、そのまま Colab の GPU を借りて起動する**（CU がかかる）。起動させずに開くなら、`colab-manager\Manager.ps1 -NoAutoStart`。
2. 準備完了まで、GPU が割り当てられてから約7分（モデルの取得と読み込み）。初回は変換があるので約12分かかる。2回目以降は、`HF_TOKEN`（書き込み権限つき）を書いておくと変換済みのデータを使って速くなる。A100 が空いていないときは、空くまで待つ（その間は CU がかからない）。状態は画面に出る。
3. 準備ができると、選んだもの（DeepSeek Harness / Strata WebUI など）が開く。API は `http://127.0.0.1:8080/v1`（OpenAI 互換）と `http://127.0.0.1:8080/v1/messages`（Anthropic 互換）。キーは不要。
4. 使い終わったら「停止」を押す。押し忘れても、既定では30分使われないと自動で止まる（画面で変えられる）。**Manager を閉じても止まる**（閉じるときに確認が出る）。

## 注意
- 費用は、ランタイムが動いている時間で決まる。止まったことは、画面の表示か、WSL で `colab status -s strata` が「not found」になることで確かめる。
- 同じ Google アカウントで、2台の PC から同時に Manager を使わない（ランタイムは1つを取り合う）。
- `config.local.env`（トークン）と `colab-manager\local.settings.json`（この PC の WSL の名前）は、この PC だけのもの。ほかの人に渡さない。
- 接続が一時的に切れても、十数秒で自動で張り直す。それより長く「Connection error」が続くときは、Manager の画面でランタイムが動いているかを見る。

## 新しい版に入れ替えるとき
- リポジトリから入れた場合: キットのフォルダで `git pull` を実行し、`install.cmd` をもう一度実行する。
- zip の場合: 新しい zip を展開して、古いフォルダに上書きする。次のものは zip に入っていないので、そのまま残る: `strata-colab-cli\config.local.env`、`colab-manager\local.settings.json`、`colab-manager\state\`、ショートカット。上書きの後に `install.cmd` をもう一度実行すると、足りないものだけを直す。

## 困ったとき
- `install.cmd` が「WSL の Ubuntu を入れる」と言う: 管理者の PowerShell で `wsl --install -d Ubuntu` を実行し、再起動して Ubuntu を一度開き、ユーザー名とパスワードを決める。名前が違うディストリを使うなら `.\install.ps1 -Distro <名前>`。
- Colab のログインをやり直したい: WSL で `colab status -s strata` を実行する。
- 「キーリングを作る」「キーリングのロックを解除する」と毎回聞かれる、または毎回ログインを求められる: Colab CLI 0.8 以降はログインのトークンを OS のキーリングに置くが、WSL ではキーリングが開かれたままにならない。`install.cmd` をもう一度実行すると、トークンを WSL のホームのファイル（`~/.local/share/python_keyring/`、本人だけが読める）に置く設定にする（sudo 不要）。キーリングに入っていたログインは使われなくなるので、手順5で一度だけログインし直す。入れた `gnome-keyring` は残しても害はない。
- ショートカットが前の置き場のキットを開く: `install.cmd -ReplaceShortcuts` を実行すると、デスクトップのショートカットもこのキットに向け直す（キットのフォルダの中のものは、いつも向け直す）。
- Manager の画面に「Colab CLI の認証が必要です」と出る: `install.cmd` をもう一度実行する。
- 起動が失敗する: Manager の画面の「Strata詳細ログ」「CLI実行ログ」と、`colab-manager\state\` の `operation-*.err.log` を見る。A100 が割り当てられないとき（ログに `assign ... Service Unavailable`）は Colab 側の空き不足なので、数分〜数十分置いてもう一度「起動」を押す（このときランタイムは作られず、CU はかからない）。
- 版: `VERSION.txt` に、元にしたコミットが書いてある。

## ライセンス
`colab-manager\` と `delegation\`、キットの直下のファイルは MIT（`LICENSE`）。`strata-colab-cli\` は [NeviumX/strata-colab-cli](https://github.com/NeviumX/strata-colab-cli) に手を加えたもので、元にライセンスが無いため MIT の対象外。このキットは知人の間で使うためのもので、再配布はしない。Colab の上で動かす Strata（[Niko1221/Strata](https://github.com/Niko1221/Strata)）は MIT。
