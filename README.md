# Colab Strata キット（Colab Manager と委譲の仕組み）

Google Colab の GPU（A100）で Strata を動かし、Qwen3.8 を手元の PC から使うための一式です。
ノート PC でも、Colab につながれば強い GPU の推論を使えます。

| フォルダ | 中身 |
|---|---|
| `colab-manager\` | Colab Manager（Colab のランタイムの起動・監視・停止をする画面のアプリ） |
| `strata-colab-cli\` | Colab に Strata を立ち上げ、手元の `http://127.0.0.1:8080` に転送するスクリプト（WSL で動く） |
| `delegation\` | 委譲の仕組み（監督の LLM が Qwen3.8 に仕事を渡す）。入口は `delegation\HANDOFF.md`。使わなければ無視してよい |

## 初めて使う方へ

準備は **Windows 側**で行います。まず必要なソフトを入れ、キットをダウンロードして `install.cmd` を実行します。チャット画面は付属の Strata WebUI を使えるので、DeepSeek Harness や委譲の設定は後回しでかまいません。

以下のコマンドは、特に「Ubuntu で実行」と書いたもの以外は **Windows の PowerShell** に貼り付けて実行してください。PowerShell はスタートメニューで検索して開けます。

## 1. 必要なものを用意する

- Windows 10 / 11 とインターネット接続。
- Google Colab で A100 を利用できるアカウントと、コンピューティング ユニット（CU）。必要な GPU を割り当てられるかは、その時点の空き状況にもよります。稼働中はモデルの準備時間も含めて CU を消費します。約 6.7 CU/時は過去の参考値です。
- WSL 2 の Ubuntu。まだ入っていなければ、PowerShell を右クリックして「管理者として実行」で開き、次を実行します。

  ```powershell
  wsl --install -d Ubuntu
  ```

  再起動を求められたら再起動し、スタートメニューから Ubuntu を開いて、Linux 用のユーザー名とパスワードを設定します。このパスワードは後で `sudo` に使います。Windows の PIN とは別です。既に Ubuntu を使っている場合は、入れ直す必要はありません。`wsl -l -v` で名前と VERSION が `2` であることを確認できます。

- PowerShell 7。まだ入っていなければ、Windows の PowerShell で次を実行します。

  ```powershell
  winget install --id Microsoft.PowerShell --source winget
  ```

  以降、PowerShell 7 を開くときはスタートメニューで「PowerShell 7」を選びます。

Git for Windows は、下の Git によるダウンロード、または委譲の仕組みを使う場合に必要です。ZIP から入れて Strata WebUI を使うだけなら不要です。DeepSeek Harness も任意です。

## 2. キットをダウンロードして置く

### 置き場所

この手順では、**Windows のユーザーフォルダの直下**に `colab-strata-kit` を置きます。たとえば Windows のユーザー名が `yamada` なら、完成後の場所は `C:\Users\yamada\colab-strata-kit` です。

エクスプローラーのアドレス欄に `%USERPROFILE%` と入力して Enter を押すと、自分のユーザーフォルダを開けます。下の PowerShell コマンドの `$env:USERPROFILE` も同じ場所を指すため、ユーザー名を書き換えずに使えます。

別の場所を選ぶ場合は、`C:\Tools\colab-strata-kit` や `D:\Tools\colab-strata-kit` など、**この PC のローカルドライブ上にあり、自分が書き込めるフォルダ**にしてください。Windows 側のファイルを WSL から読み込んで使うため、次の場所は使わないでください。

- `\\server\share` などの共有フォルダや、共有フォルダを割り当てたネットワークドライブ（`Z:` など）。ドライブ文字があってもネットワーク上なら対象外です。
- `\\wsl.localhost\Ubuntu` など、Ubuntu 側のファイルをエクスプローラーで表示した場所。

ダウンロード方法は、次の **A・B のどちらか一方**を選びます。

### A. ZIP でダウンロードする（Git の操作が不要）

1. ブラウザで [このリポジトリ](https://github.com/t32504m/colab-strata-kit) を開きます。非公開の間は、アクセス権のある GitHub アカウントでログインしてください。招待されている場合は、先に招待を承認します。ページが見られない場合は、管理者にアクセス権を確認してください。
2. **Code → Download ZIP** を選びます。
3. ダウンロードした ZIP を右クリックして **すべて展開**します。ZIP を開いただけの状態では、`install.cmd` を実行しないでください。
4. 展開してできた `colab-strata-kit-main` フォルダを `colab-strata-kit` に名前変更し、上で開いたユーザーフォルダへ移動します。配布された ZIP の場合は、`install.cmd` が入っているフォルダを同じ場所に置いてください。

### B. Git でダウンロードする（Git for Windows が必要）

[Git for Windows](https://gitforwindows.org/) を入れ、PowerShell を開き直してから、次を実行します。

```powershell
git clone https://github.com/t32504m/colab-strata-kit.git "$env:USERPROFILE\colab-strata-kit"
```

このコマンドは、リポジトリをダウンロードして `colab-strata-kit` フォルダを作ります。先に同名のフォルダを作る必要はありません。既にその場所にキットがある場合は、下の「新しい版に入れ替えるとき」を参照してください。

非公開の間は、Git の認証でもアクセス権のある GitHub アカウントを使います。認証を求められたら案内に従ってください。`Repository not found` になる場合は、アクセス権と認証に使ったアカウントを確認します。トークンを URL に書き込む必要はありません。

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

Hugging Face のトークンは任意です。最初は空のまま進められます。設定する場合は、下の「設定」を参照してください。

## 4. 起動して使い、停止する

1. デスクトップ、またはキットのフォルダにある **「Colab Manager」** をダブルクリックします。ランタイムが無ければ前回の設定で自動起動し、CU の消費が始まります。既にランタイムがある場合は、その状態を確認・監視します。
2. モデルの取得・準備が終わるまで待ちます。初回は数十 GB のダウンロードがあり、数十分かかることがあります。画面の進捗を確認してください。
3. **「準備完了」** と表示されたら使えます。DeepSeek Harness を入れていない場合は、「起動後に開く」を **Strata WebUI** にして「選択した画面を開く」を押します。次回から自動で開くかは「準備できたら自動で開く」で選べます。
4. 使い終わったら **「Colabを停止」** を押し、**「停止完了」** と表示されるまで待ちます。WebUI や Harness を閉じるだけでは Colab は停止しません。

Manager の「×」でも停止を要求します。停止確認のメッセージが出るまで待ち、OK を押して終了してください。既定では約30分使われない場合も停止しますが、これは PC 側の監視です。PC のスリープ・電源断・ネットワーク障害などでは停止を完了できないことがあります。復帰後に状態を確認してください。

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
| `HF_TOKEN` | 空 | Hugging Face のトークン。書くとモデルの取得が速く・安定する。[Hugging Face の設定画面](https://huggingface.co/settings/tokens)で作る（モデルの取得は読み取り権限で足りる）。**秘密の値なので人に見せない** |
| `MTP_CACHE_REPO` | `auto` | 変換済みのデータ（約 0.8 GB）を Hugging Face に非公開で保存し、2回目以降の起動を速くする。`auto` なら `<トークンのユーザー名>/strata-colab-cache`。使わないなら空にする |
| `MTP_CACHE_TOKEN` | 空 | 上の保存に使う、書き込み権限のあるトークン。空なら `HF_TOKEN` を使う（そのときは `HF_TOKEN` に書き込み権限が要る） |
| `HIGH_MEM` | `0` | `1` で High-memory のランタイム（Colab Pro / Pro+ が必要） |
| `ON_GPU_MISMATCH` | `stop` | A100 以外が割り当てられたら止める（CU の無駄を防ぐ） |
| `CONTEXT` / `MODEL` / `STRATA_EXTRA_ARGS` | | Manager の画面が書き換える。手で変えなくてよい |

トークンを書いたら、Manager で起動し直すと使われる。トークンを書かなくても動く（取得が遅いことがあるだけ）。

### DeepSeek Harness を使う場合（任意）

DeepSeek Harness を先に入れてから `install.cmd` を実行すると、「Colab の Strata」をモデルとして選べるように設定を足す。後から入れたときは、`install.cmd` をもう一度実行する。ほかのアプリから使うときは、API の URL（「4. 起動して使い、停止する」）を設定する。キーの入力が必須の場合は、ダミー値（例: `local-ssh`）を指定する。

## 注意

- 費用は、ランタイムが動いている時間で決まる。止まったことは、画面の表示か、WSL で `colab status -s strata` が「not found」になることで確かめる。
- 同じ Google アカウントで、2台の PC から同時に Manager を使わない（ランタイムは1つを取り合う）。
- `config.local.env`（トークン）と `colab-manager\local.settings.json`（この PC の WSL の名前）は、この PC だけのもの。ほかの人に渡さない。
- 接続が一時的に切れても、十数秒で自動で張り直す。それより長く「Connection error」が続くときは、Manager の画面でランタイムが動いているかを見る。

## 新しい版に入れ替えるとき

最初に Manager で Colab を停止し、「停止完了」を確認してから Manager を閉じます。

Git で入れた場合は、Windows の PowerShell で次を実行します。別の場所に置いた場合は、`Set-Location` の行を実際の場所に変更してください。

```powershell
Set-Location "$env:USERPROFILE\colab-strata-kit"
git pull --ff-only
.\install.cmd
```

自分で変更したファイルがあるなどの理由で `git pull` が失敗したら、表示を確認してください。設定ファイルを消したり、強制的に上書きしたりする必要はありません。

ZIP で入れた場合は、新しい ZIP を別の場所に展開し、`install.cmd` と3つのフォルダがある階層の中身を、既存のキットのフォルダへ上書きコピーします。キットのフォルダ全体を先に削除しないでください。GitHub の Download ZIP には、この PC で作った `strata-colab-cli\config.local.env`、`colab-manager\local.settings.json`、`colab-manager\state\`、ショートカットは含まれないため、そのまま残せます。コピー後は `install.cmd` をもう一度実行します。

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
