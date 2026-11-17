# Colab Strata キット（Colab Manager と委譲の仕組み）

Google Colab の GPU（A100）で Strata を動かし、Qwen3.8 を手元の PC から使うための一式です。
ノート PC でも、Colab につながれば強い GPU の推論を使えます。

| フォルダ | 中身 |
|---|---|
| `colab-manager\` | Colab Manager（Colab のランタイムの起動・監視・停止をする画面のアプリ） |
| `strata-colab-cli\` | Colab に Strata を立ち上げ、手元の `http://127.0.0.1:8080` に転送するスクリプト（WSL で動く） |
| `delegation\` | 委譲の仕組み（監督の LLM が Qwen3.8 に仕事を渡す）。入口は `delegation\HANDOFF.md`。使わなければ無視してよい |

## 初めて使う方へ

準備は **Windows 側**で行います。まず必要なソフトを入れ、キットをダウンロードして `install.cmd` を実行します。HFトークンを用意する場合は、Manager を初めて開く前に設定しておくことをおすすめします。チャット画面は DeepSeek Harness または付属の Strata WebUI を使えます。

以下のコマンドは、特に「Ubuntu で実行」と書いたもの以外は **Windows の PowerShell** に貼り付けて実行してください。PowerShell はスタートメニューで検索して開けます。

## 1. 必要なものを用意する

### まず、インストール状況とバージョンを確認する

次の確認コマンドは **Windows の PowerShell** で実行します。確認できたものを入れ直す必要はありません。

| 確認するもの | このキットでの条件・導入の目安 |
|---|---|
| Windows | Windows 10 / 11。以下の `wsl --install` を使う場合は Windows 10 バージョン2004（ビルド19041）以降、または Windows 11 が前提。これは WSL の導入条件で、キットの全バージョンでの動作検証を意味しません |
| WSL・Ubuntu | **WSL 2** 上の Ubuntu。この手順で新しく入れる場合は **Ubuntu 24.04 LTS** を指定します。既存の Ubuntu の最小対応バージョンは未確認です |
| PowerShell | Manager は **PowerShell 7 系**で使います。導入は7系の最新安定版を推奨。Windows 標準の Windows PowerShell 5.1 とは別です。委譲スクリプトは `#requires -Version 7` を指定しています |
| Colab アカウント | A100 を利用でき、CU が残っていること。GPU の割り当ては空き状況にもよります。PC 内のコマンドでは権限や残量を確認できないので、Colab のアカウントで確認してください |

Windows の種類・ビルド・CPUアーキテクチャ：

```powershell
Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, BuildNumber, OSArchitecture
```

WSL の導入状態と Ubuntu の一覧：

```powershell
wsl --version
wsl --status
wsl -l -v
```

`wsl --version` は WSL 本体の版です。古い WSL でこのオプションが使えない場合は、`--status` と `-l -v` の出力を確認してください。

`wsl -l -v` の一覧に使う Ubuntu があり、**VERSION が `2`** なら WSL 2 です。VERSION は Ubuntu の版ではありません。Ubuntu 自体の版は、一覧の名前に合わせて次で確認します（例は `Ubuntu`）。

```powershell
wsl -d Ubuntu -e cat /etc/os-release
```

出力の `PRETTY_NAME` または `VERSION_ID` を確認します。名前が `Ubuntu-24.04` なら、コマンド中の `Ubuntu` を `Ubuntu-24.04` に置き換えてください。

PowerShell 7 の導入状況と版：

```powershell
Get-Command pwsh -ErrorAction SilentlyContinue
pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
```

`7.x.x` と表示されることを確認します。現在開いている画面の版だけを調べる `$PSVersionTable` では、Windows PowerShell 5.1 と表示されることがあります。`pwsh` が見つからなければ、次の手順で PowerShell 7 を入れてください。

### 不足しているものを入れる

WSL・Ubuntu が無い場合は、PowerShell を右クリックして「管理者として実行」で開き、次を実行します。

```powershell
wsl --install -d Ubuntu-24.04
```

再起動を求められたら再起動し、スタートメニューから Ubuntu 24.04 を開いて、Linux 用のユーザー名とパスワードを設定します。このパスワードは後で `sudo` に使います。Windows の PIN とは別です。既に Ubuntu を使っている場合は入れ直さず、上のコマンドで状態を確認してください。

PowerShell 7 が無い場合は、Windows の PowerShell で次を実行します。

```powershell
winget --version
winget install --id Microsoft.PowerShell --source winget
```

`winget` 自体が見つからない場合は、Microsoft Store の「アプリ インストーラー」をインストール・更新するか、[PowerShell の公式インストール手順](https://learn.microsoft.com/ja-jp/powershell/scripting/install/installing-powershell-on-windows)を参照してください。インストール後は PowerShell を開き直し、上の `pwsh` の確認コマンドを実行します。

ssh・uv・Colab CLI は手順3の `install.cmd` が **Ubuntu 側**に用意します。Windows 側に個別に入れる必要はありません。Colab CLI のトークン保存処理は0.8以降を想定しています。セットアップは最新版を導入・更新し、版は固定していません。WSL 本体の最小パッケージ版、uv の最小版、Ubuntu の最小対応版については未検証です。

導入後に uv と Colab CLI の実際の版を確認したい場合は、Windows の PowerShell で次を実行します。`Ubuntu-24.04` は自分の WSL の名前に合わせて変更してください。`uv tool list` に `google-colab-cli v...` が表示されます。以下は uv の通常のインストール先（`~/.local/bin/uv`）を使う例です。別の場所に導入済みの場合は実際のパスに合わせてください。

```powershell
wsl -d Ubuntu-24.04 -e bash -lc '~/.local/bin/uv --version'
wsl -d Ubuntu-24.04 -e bash -lc '~/.local/bin/uv tool list'
```

ランタイムの稼働中はモデルの準備時間も含めて CU を消費します。約 6.7 CU/時は過去の参考値です。

### 任意：Hugging Face のトークン（起動前の設定を推奨）

トークンなしでも動きますが、**初回起動前に、キャッシュの保存までできるトークンを用意することをおすすめします**。このキットは変換済みMTPデータ（約0.8 GB）を Hugging Face に保存し、次回の起動で再利用できます。

| 権限・状態 | できること |
|---|---|
| Read（読み取り） | モデルの取得と、アクセス権がある保存済みキャッシュの読み込み。新しいキャッシュは保存できない |
| Write（書き込み） | 上記に加えて、キャッシュ用の非公開リポジトリを作り、変換済みデータを保存できる |
| 保存済みキャッシュがある次回起動 | 対応するデータを復元し、MTP用の取得・変換を省ける。読み込みだけなら Read でも使える |

**Write に変えるだけで、初回のダウンロードが速くなるわけではありません。** 最初は変換して保存し、保存に成功した後の起動で再利用します。モデル本体すべてをキャッシュする仕組みではありません。起動時間はキャッシュ・モデル・回線などで変わり、Read と Write の条件をそろえた実測は未確認です。

1. [Hugging Face](https://huggingface.co/) のアカウントを作成、またはログインします。
2. [Access Tokens の設定画面](https://huggingface.co/settings/tokens)で **Create new token** を選びます。
3. この手順の既定設定でキャッシュの作成・保存まで使う場合は、**Write（書き込み）** 権限のトークンを作成します。モデル取得と既存キャッシュの読み込みだけなら Read で足ります。
4. 発行されたトークンを安全に保管します。手順3で `install.cmd` を実行した後、作成された `strata-colab-cli\config.local.env` の `HF_TOKEN=` に設定します。書き込むまでは Colab Manager を開かないでください。

トークンはパスワードと同様に扱い、チャット・スクリーンショット・共有するファイルに載せないでください。

### 任意：DeepSeek Harness（チャット・コード生成の画面）

使う場合は、公式の配布元から Windows 版を入れておきます。対応する最小バージョンは、このリポジトリでは指定・検証していません。先に入れてから `install.cmd` を実行すると、Colab の Strata につなぐ設定が追加されます。後から入れた場合は、`install.cmd` をもう一度実行してください。

DeepSeek Harness を入れない場合は、付属の Strata WebUI を使えます。委譲の仕組みも使う場合は、[Git for Windows](https://gitforwindows.org/) を別途用意してください。キットのダウンロード自体には Git は不要です。

通常のインストール先にあるかと、実行ファイルのバージョン情報を Windows の PowerShell で確認できます。

```powershell
$harnessExe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
Test-Path -LiteralPath $harnessExe
if (Test-Path -LiteralPath $harnessExe) { (Get-Item -LiteralPath $harnessExe).VersionInfo | Select-Object ProductVersion, FileVersion }
```

`True` なら、このキットが探す場所に実行ファイルがあります。バージョン欄が空の場合は、Harness の設定・バージョン情報画面も確認してください。`False` なら、その場所にはありません。別の場所にインストールしている場合、このキットの自動検出の対象外です。

委譲も使う場合の Git は、`git --version` で導入状況と版を確認できます。Git の最小対応版は未指定です。

## 2. キットをダウンロードして置く

### 置き場所

キットは、**この PC のローカルドライブ上にあり、自分が書き込めるフォルダ**に置いてください。ドライブ直下でも、その下のフォルダでも使えます。

| 配置例 | 使えるか |
|---|---|
| `C:\colab-strata-kit` | 使える（Cドライブ直下） |
| `C:\Tools\colab-strata-kit` | 使える（フォルダの中） |
| `D:\Tools\colab-strata-kit` | 使える（別のローカルドライブ） |
| `C:\Users\yamada\colab-strata-kit` | 使える（ユーザーフォルダの中） |

以下では例として **Windows のユーザーフォルダの中**に置きます。エクスプローラーのアドレス欄に `%USERPROFILE%` と入力して Enter を押すと、自分のユーザーフォルダを開けます。後述の PowerShell コマンドの `$env:USERPROFILE` も同じ場所を指します。別の場所に置いた場合は、コマンドの移動先を実際の場所に変更してください。

Windows 側のファイルを WSL から読み込んで使うため、次の場所は使わないでください。

- `\\server\share` などの共有フォルダや、共有フォルダを割り当てたネットワークドライブ（`Z:` など）。ドライブ文字があってもネットワーク上なら対象外です。
- `\\wsl.localhost\Ubuntu` など、Ubuntu 側のファイルをエクスプローラーで表示した場所。

### ZIP でダウンロードする

1. ブラウザで [このリポジトリ](https://github.com/t32504m/colab-strata-kit) を開きます。非公開の間は、アクセス権のある GitHub アカウントでログインしてください。招待されている場合は、先に招待を承認します。ページが見られない場合は、管理者にアクセス権を確認してください。
2. **Code → Download ZIP** を選びます。
3. ダウンロードした ZIP を右クリックして **すべて展開**します。ZIP を開いただけの状態では、`install.cmd` を実行しないでください。
4. 展開してできた `colab-strata-kit-main` フォルダを `colab-strata-kit` に名前変更し、上で開いたユーザーフォルダへ移動します。配布された ZIP の場合は、`install.cmd` が入っているフォルダを同じ場所に置いてください。

### 配置できたか確認する

エクスプローラーで `colab-strata-kit` を開き、次のファイルとフォルダが **同じ階層**にあることを確認します。ほかのファイルも入っています。

```text
colab-strata-kit
├─ install.cmd
├─ install.ps1
├─ README.md
├─ colab-manager
├─ strata-colab-cli
└─ delegation
```

`install.cmd` だけを別の場所にコピーしたり、`colab-manager` などを個別に移動したりせず、このフォルダ全体を一緒に置いてください。以降、この `install.cmd` があるフォルダを「キットのフォルダ」と呼びます。

## 3. 初期設定を実行する

1. エクスプローラーでキットのフォルダを開き、`install.cmd` をダブルクリックします。通常は「管理者として実行」にする必要はありません。
2. 開いた画面の案内に従います。済んでいる処理は飛ばします。

   | 処理 | 自分で行う操作 |
   |---|---|
   | PowerShell 7・WSL の確認 | 不足を指摘されたら、手順1で用意する |
   | Ubuntu に ssh・uv・Colab CLI・SSH 鍵を用意 | `sudo` に聞かれたら Ubuntu のパスワードを入力する。入力中は文字が表示されないが、そのまま Enter を押す |
   | この PC 用の `strata-colab-cli\config.local.env` を作成 | 自動で作成する。既にある場合は上書きしない |
   | Colab CLI にログイン | ブラウザの案内を確認し、Colab を使う Google アカウントで許可する。終わったらインストール画面に戻る |
   | DeepSeek Harness の設定（インストール済みの場合） | 表示された結果を確認する。Strata WebUI だけなら Harness は不要 |
   | ショートカットを作成 | キットのフォルダとデスクトップに「Colab Manager」ができたことを確認する |

3. 最後に **「準備ができました」** と表示されれば完了です。「残っていること」が表示されたら、その内容に対応して `install.cmd` をもう一度実行します。

初期設定では GPU を起動しません。**次の手順で Colab Manager を開くと、ランタイムが無い場合は自動で GPU を起動します。**

### Manager を開く前に HFトークンを設定する（推奨）

手順1で用意したトークンを、キットのフォルダにある `strata-colab-cli\config.local.env` に書き込みます。

1. `config.local.env` を右クリックし、メモ帳などのテキストエディターで開きます。
2. `HF_TOKEN=` の行を探し、= の直後に発行されたトークンを貼り付けて保存します。変更するのは `config.local.env` で、雛形の `config.local.example.env` ではありません。
3. 保存してから、次の手順で Colab Manager を開きます。

既定は `MTP_CACHE_REPO=auto` です。`MTP_CACHE_TOKEN` が空なら `HF_TOKEN` をキャッシュにも使うため、`HF_TOKEN` に Write のトークンを設定すれば保存まで使えます。モデル取得用と分ける場合は、`HF_TOKEN` に Read、`MTP_CACHE_TOKEN` にキャッシュ保存先へ書き込めるトークンを設定します。保存先は通常 `<トークンのユーザー名>/strata-colab-cache` の非公開リポジトリです。

## 4. 起動して使い、停止する

1. デスクトップ、またはキットのフォルダにある **「Colab Manager」** をダブルクリックします。**開くだけで Colab ランタイムへの接続と Strata の起動が自動で進みます。** ランタイムが無ければ新しく起動し、既に稼働していればその状態を確認・監視します。通常は、追加で「起動」を押す必要はありません。ランタイムの稼働中は CU を消費します。
2. モデルの取得・準備が終わるまで待ちます。保存済みMTPキャッシュを再利用できる場合は、取得・変換の一部を省けます。初回やキャッシュがない場合は数十分かかることがあります。画面の進捗を確認してください。
3. **「準備完了」** と表示されたら使えます。DeepSeek Harness を入れていない場合は、「起動後に開く」を **Strata WebUI** にして「選択した画面を開く」を押します。次回から自動で開くかは「準備できたら自動で開く」で選べます。
4. 使い終わったら **Colab Manager のウィンドウを「×」で閉じます**。Manager はランタイムの停止・切断を行い、停止を確認してから終了します。停止確認のメッセージが出たら OK を押してください。WebUI や Harness を閉じるだけでは Colab は停止しません。

画面を残してランタイムだけを止めたい場合は **「Colabを停止」** を押し、**「停止完了」** と表示されるまで待ちます。既定では約30分使われない場合も停止しますが、これは PC 側の監視です。PC のスリープ・電源断・ネットワーク障害などでは停止を完了できないことがあります。復帰後に状態を確認してください。

設定を選んでから GPU を起動したい場合は、PowerShell 7 で次を実行します。この手順どおりの場所に置いた場合のコマンドです。

```powershell
Set-Location "$env:USERPROFILE\colab-strata-kit"
pwsh -NoProfile -ExecutionPolicy Bypass -File .\colab-manager\Manager.ps1 -NoAutoStart
```

モデルやコンテキスト長を選んでから「起動」を押します。詳しい操作と停止の仕組みは [Colab Manager の手順書](colab-manager/README.md) を参照してください。

ほかのアプリから接続するときの URL は、OpenAI 互換 API が `http://127.0.0.1:8080/v1`、Anthropic 互換 API が `http://127.0.0.1:8080/v1/messages` です。既定では認証キーは不要です。接続先アプリがキーの入力を必須にしている場合は、ダミー値（例: `local-ssh`）を指定します。

## 設定

普段使う設定は、Manager の画面と `config.local.env` で変更します。保存されるファイルはこの PC 用です。Git の管理対象には含まれませんが、フォルダを手動で ZIP にすると含まれることがあるため、そのまま人に渡さないでください。

### 1. Manager の画面で選ぶもの

Manager の画面で、モデル（量子化）、コンテキスト長、起動後に開くもの（DeepSeek Harness / Strata WebUI など）、使われないときに自動で止めるまでの時間を選ぶ。選んだものは `strata-colab-cli\config.local.env` と `colab-manager\state\preferences.json` に保存され、次からはそのまま使われる。

### 2. `strata-colab-cli\config.local.env`（メモ帳で開いて書く）

`install.cmd` が雛形（`config.local.example.env`）から作る。ここに書いた値が `config.env`（全員共通の既定値。書き換えない）より優先される。

| 項目 | 既定 | 意味 |
|---|---|---|
| `HF_TOKEN` | 空 | Hugging Face のトークン。書くとモデルの取得が速く・安定する。[Hugging Face の設定画面](https://huggingface.co/settings/tokens)で作る（取得は Read、キャッシュの新規保存も使う場合は Write）。**秘密の値なので人に見せない** |
| `MTP_CACHE_REPO` | `auto` | 変換済みのデータ（約 0.8 GB）を Hugging Face に非公開で保存し、2回目以降の起動を速くする。`auto` なら `<トークンのユーザー名>/strata-colab-cache`。使わないなら空にする |
| `MTP_CACHE_TOKEN` | 空 | 上の保存に使う、書き込み権限のあるトークン。空なら `HF_TOKEN` を使う（そのときは `HF_TOKEN` に書き込み権限が要る） |
| `HIGH_MEM` | `0` | `1` で High-memory のランタイム（Colab Pro / Pro+ が必要） |
| `ON_GPU_MISMATCH` | `stop` | A100 以外が割り当てられたら止める（CU の無駄を防ぐ） |
| `CONTEXT` / `MODEL` / `STRATA_EXTRA_ARGS` | | Manager の画面が書き換える。手で変えなくてよい |

トークンを書いたら、Manager で起動し直すと使われる。キャッシュの保存には書き込み権限が必要で、保存成功後の起動で再利用できます。

### DeepSeek Harness を使う場合（任意）

DeepSeek Harness を先に入れてから `install.cmd` を実行すると、「Colab の Strata」をモデルとして選べるように設定を足す。後から入れたときは、`install.cmd` をもう一度実行する。ほかのアプリから使うときは、API の URL（「4. 起動して使い、停止する」）を設定する。キーの入力が必須の場合は、ダミー値（例: `local-ssh`）を指定する。

## 注意

- 費用は、ランタイムが動いている時間で決まる。止まったことは、画面の表示か、WSL で `colab status -s strata` が「not found」になることで確かめる。
- 同じ Google アカウントで、2台の PC から同時に Manager を使わない（ランタイムは1つを取り合う）。
- `config.local.env`（トークン）と `colab-manager\local.settings.json`（この PC の WSL の名前）は、この PC だけのもの。ほかの人に渡さない。
- 接続が一時的に切れても、十数秒で自動で張り直す。それより長く「Connection error」が続くときは、Manager の画面でランタイムが動いているかを見る。

## 新しい版に入れ替えるとき

最初に Manager で Colab を停止し、「停止完了」を確認してから Manager を閉じます。

新しい ZIP を別の場所に展開し、`install.cmd` と3つのフォルダがある階層の中身を、既存のキットのフォルダへ上書きコピーします。キットのフォルダ全体を先に削除しないでください。GitHub の Download ZIP には、この PC で作った `strata-colab-cli\config.local.env`、`colab-manager\local.settings.json`、`colab-manager\state\`、ショートカットは含まれないため、そのまま残せます。コピー後は `install.cmd` をもう一度実行します。

## 初期設定の確認・追加オプション

以下は、キットのフォルダを開いた状態の Windows の PowerShell で実行します。この手順どおりの場所に置いた場合は、最初に次を実行してください。

```powershell
Set-Location "$env:USERPROFILE\colab-strata-kit"
.\install.cmd -Check
```

`-Check` は初期設定の状態を表示します。インストールや設定ファイルへの書き込みは行いません。WSL の起動や、Colab への状態照会は行います。

| オプション | 意味 |
|---|---|
| `-Check` | 済んでいること・残っていることを表示する |
| `-Distro <名前>` | 使用する WSL の名前を指定する。例: `.\install.cmd -Distro Ubuntu-24.04`。名前は `wsl -l -v` で確認する |
| `-SkipWsl` / `-SkipLogin` | WSL 内の準備 / Colab のログイン処理を飛ばす |
| `-NoDesktopShortcut` | デスクトップにショートカットを作らない |
| `-ReplaceShortcuts` | 別の置き場のキットを指すデスクトップのショートカットを、このキットに向け直す |

## 困ったとき

- `install.cmd` が「WSL の Ubuntu を入れる」と言う: 管理者の PowerShell で `wsl --install -d Ubuntu` を実行し、再起動して Ubuntu を一度開き、ユーザー名とパスワードを決める。名前が違う場合は、キットのフォルダを開いた PowerShell で `.\install.cmd -Distro Ubuntu-24.04` のように実際の名前を指定する。
- Colab のログインをやり直したい: WSL で `colab status -s strata` を実行する。
- 「キーリングを作る」「キーリングのロックを解除する」と毎回聞かれる、または毎回ログインを求められる: Colab CLI 0.8 以降はログインのトークンを OS のキーリングに置くが、WSL ではキーリングが開かれたままにならない。`install.cmd` をもう一度実行すると、トークンを WSL のホームのファイル（`~/.local/share/python_keyring/`、本人だけが読める）に置く設定にする（sudo 不要）。キーリングに入っていたログインは使われなくなるので、続く Colab CLI のログイン処理で一度だけログインし直す。入れた `gnome-keyring` は残しても害はない。
- ショートカットが前の置き場のキットを開く: キットのフォルダを開いた PowerShell で `.\install.cmd -ReplaceShortcuts` を実行すると、デスクトップのショートカットもこのキットに向け直す（キットのフォルダの中のものは、いつも向け直す）。
- Manager の画面に「Colab CLI の認証が必要です」と出る: `install.cmd` をもう一度実行する。
- 起動が失敗する: Manager の画面の「Strata詳細ログ」「CLI実行ログ」と、`colab-manager\state\` の `operation-*.err.log` を見る。A100 が割り当てられないとき（ログに `assign ... Service Unavailable`）は Colab 側の空き不足なので、数分〜数十分置いてもう一度「起動」を押す（このときランタイムは作られず、CU はかからない）。
- 版: `VERSION.txt` に、元にしたコミットが書いてある。

## ライセンス

`colab-manager\` と `delegation\`、キットの直下のファイルは MIT（`LICENSE`）。`strata-colab-cli\` は [NeviumX/strata-colab-cli](https://github.com/NeviumX/strata-colab-cli) に手を加えたもので、元にライセンスが無いため MIT の対象外。このキットは知人の間で使うためのもので、再配布はしない。Colab の上で動かす Strata（[Niko1221/Strata](https://github.com/Niko1221/Strata)）は MIT。
