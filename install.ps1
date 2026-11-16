<#
Colab Manager（と委譲の仕組み）を、この PC で使えるようにする。最初に1回だけ実行する（何度実行しても壊れない）。
Windows PowerShell 5.1 でも PowerShell 7 でも動く。install.cmd から呼ぶと楽。

やること（それぞれ、済んでいれば飛ばす）:
  1. PowerShell 7 があるか確かめる（Manager に必要。無ければ入れ方を示して止まる）
  2. WSL の Ubuntu があるか確かめ、使うディストリを colab-manager\local.settings.json に書く
  3. WSL に必要なもの（ssh、uv、colab CLI、SSH の鍵）を入れる（strata-colab-cli\setup-wsl.sh。sudo のパスワードを聞かれる）
  4. strata-colab-cli\config.local.env を雛形から作る（秘密の値は自分で書く）
  5. Colab CLI に Google アカウントでログインする（ブラウザが開く）
  6. DeepSeek Harness が入っていれば、Colab の Strata につなぐ設定を足す
  7. 「Colab Manager」のショートカットを、このフォルダとデスクトップに作る

-Check を付けると、何も変えずに状態だけを表示する。
#>
param([switch]$Check, [string]$Distro, [switch]$SkipWsl, [switch]$SkipLogin, [switch]$NoDesktopShortcut, [switch]$ReplaceShortcuts)
$ErrorActionPreference = 'Stop'
$Kit = $PSScriptRoot
$Mgr = Join-Path $Kit 'colab-manager'
$Cli = Join-Path $Kit 'strata-colab-cli'
$problems = New-Object System.Collections.Generic.List[string]
function Step($n, $m) { Write-Host ''; Write-Host "[$n] $m" -ForegroundColor Cyan }
function Ok($m) { Write-Host "  済: $m" -ForegroundColor Green }
function Todo($m) { Write-Host "  要: $m" -ForegroundColor Yellow; $problems.Add($m) | Out-Null }
function Info($m) { Write-Host "  $m" }
function ConvertTo-WslPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "WSL から見えない場所です（ドライブ文字のある場所に置いてください）: $full" }
    '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '\\', '/')
}
function Invoke-Wsl([string]$D, [string]$Cmd, [switch]$Capture) {
    # 外部のコマンドに渡す文字列に " が含まれると、PowerShell（特に 5.1）では引用符が崩れて bash に正しく届かない。
    # 命令は UTF-8 の base64 にして、引用符も日本語も含まない形で渡し、WSL の中で一時ファイルに戻して実行する。
    # 端末はそのまま使えるので、sudo のパスワードやブラウザでの許可を待つ命令も動く。
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Cmd + "`n"))
    $wrapper = 'f=$(mktemp); echo ' + $b64 + ' | base64 -d > $f; bash -l $f; rc=$?; rm -f $f; exit $rc'
    # -e: シェルを通さずに bash を実行する（-- だと wsl.exe が引数をシェルで解釈し直し、命令が崩れる）
    # 5.1 は、Stop のまま外部コマンドの stderr を受け取ると例外にするので、ここだけ Continue にする
    $ErrorActionPreference = 'Continue'
    if ($Capture) {
        $out = & wsl.exe -d $D -e bash -c $wrapper 2>&1 | ForEach-Object { "$_" } | Out-String
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
    }
    & wsl.exe -d $D -e bash -c $wrapper | Out-Host
    return $LASTEXITCODE
}

function Read-WslProbeOutput([byte[]]$Bytes) {
    # wsl.exe の Windows 側メッセージは、WSL_UTF8 が設定されていても UTF-16LE の場合がある。
    $encoding = [Text.Encoding]::UTF8
    if ($Bytes -contains 0 -or ($Bytes.Length -ge 2 -and $Bytes[0] -eq 255 -and $Bytes[1] -eq 254)) {
        $encoding = [Text.Encoding]::Unicode
    }
    $encoding.GetString($Bytes).TrimStart([char]0xFEFF).Trim()
}
function Invoke-WslProbe([string]$Arguments) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($start)
    $stdout = New-Object IO.MemoryStream
    $stderr = New-Object IO.MemoryStream
    try {
        $readOut = $process.StandardOutput.BaseStream.CopyToAsync($stdout)
        $readErr = $process.StandardError.BaseStream.CopyToAsync($stderr)
        $null = $readOut.GetAwaiter().GetResult()
        $null = $readErr.GetAwaiter().GetResult()
        $process.WaitForExit()
        [pscustomobject]@{
            Code = $process.ExitCode
            Out = Read-WslProbeOutput ($stdout.ToArray())
            Err = Read-WslProbeOutput ($stderr.ToArray())
        }
    } finally {
        $stdout.Dispose()
        $stderr.Dispose()
        $process.Dispose()
    }
}

if (-not (Test-Path (Join-Path $Mgr 'Manager.ps1')) -or -not (Test-Path (Join-Path $Cli 'lib\common.sh'))) {
    throw "colab-manager と strata-colab-cli が、このファイルと同じフォルダにありません: $Kit"
}
$null = ConvertTo-WslPath $Kit   # ネットワークのドライブなどは先に断る
if ($Check) { Write-Host '（-Check: 何も変えずに状態だけを表示します）' -ForegroundColor DarkGray }
# WSL で命令を流す前に、実際に動くとき（lib/common.sh）と同じく、キットの設定（PATH など）を読む
$prelude = "cd '" + (ConvertTo-WslPath $Cli) + "' || exit 90; set -a; . ./config.env; [ -f config.local.env ] && . ./config.local.env; set +a; export PATH=`"`$HOME/.local/bin:`$PATH`"; "


# ---- 1. PowerShell 7 ----
Step 1 'PowerShell 7'
$pwsh = $null
$cmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($cmd) { $pwsh = $cmd.Source }
if (-not $pwsh) {
    $cands = @((Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
               (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe'))
    $pwsh = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if ($pwsh) { Ok $pwsh } else { Todo 'PowerShell 7 を入れてから、もう一度実行する: winget install --id Microsoft.PowerShell' }

# ---- 2. WSL ----
Step 2 'WSL の Ubuntu'
$env:WSL_UTF8 = '1'
$wslReady = $false
$distros = @()
$list = Invoke-WslProbe '-l -q'
if ($list.Code -eq 0) {
    $distros = @($list.Out -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if (-not $Distro) {
    $saved = Join-Path $Mgr 'local.settings.json'
    if (Test-Path $saved) { try { $Distro = (Get-Content $saved -Raw | ConvertFrom-Json).WslDistro } catch { } }
}
if (-not $Distro) { $Distro = $distros | Where-Object { $_ -match '^Ubuntu' } | Select-Object -First 1 }
if ($list.Code -ne 0 -and ($list.Out + $list.Err) -notmatch 'WSL_E_(DEFAULT_)?DISTRO_NOT_FOUND') {
    @($list.Out, $list.Err) | Where-Object { $_ } | ForEach-Object { Info $_ }
    Todo 'WSL のディストリ一覧を取得できません。表示された WSL のエラーを確認してください'
    $Distro = $null
} elseif (-not $Distro) {
    Todo 'WSL の Ubuntu を入れる（管理者の PowerShell で: wsl --install -d Ubuntu。再起動とユーザー名の設定のあと、もう一度実行する）'
} elseif ($distros -notcontains $Distro) {
    Todo "WSL のディストリ '$Distro' がありません（ある: $($distros -join ', ')）。-Distro で指定する"
    $Distro = $null
} else {
    Ok "使うディストリ: $Distro"
    if (-not ($SkipWsl -and $SkipLogin)) {
        $distroArg = $Distro
        if ($Distro -match '\s') { $distroArg = '"' + $Distro + '"' }
        $probe = Invoke-WslProbe ('-d ' + $distroArg + ' -e /bin/true')
        $wslReady = $probe.Code -eq 0
        if (-not $wslReady) {
            @($probe.Out, $probe.Err) | Where-Object { $_ } | ForEach-Object { Info $_ }
            Todo "WSL の '$Distro' を起動できません（終了コード $($probe.Code)）。起動できるようになってから、もう一度実行してください"
        }
    }
    if (-not $Check) {
        $json = '{ "WslDistro": "' + $Distro + '" }'
        [IO.File]::WriteAllText((Join-Path $Mgr 'local.settings.json'), $json + "`n", (New-Object Text.UTF8Encoding($false)))
    }
}

# ---- 3. WSL の中の準備 ----
Step 3 'WSL に必要なもの（ssh、uv、colab CLI、SSH の鍵）'
if ($wslReady -and -not $SkipWsl) {
    $have = Invoke-Wsl $Distro ($prelude + 'command -v colab >/dev/null && command -v ssh >/dev/null && command -v curl >/dev/null && command -v ss >/dev/null && test -f ~/.ssh/id_ed25519') -Capture
    if ($have.Code -eq 0) {
        Ok 'colab CLI・ssh・鍵がそろっている'
        # colab CLI 0.8 以降はトークンを OS のキーリングに置く。WSL ではキーリングの作成・解除を毎回聞かれるので、ファイルに置く設定にする
        $kr = Invoke-Wsl $Distro ($prelude + 'grep -qs "^default-keyring *= *keyrings.alt.file.PlaintextKeyring" "${XDG_CONFIG_HOME:-$HOME/.config}/python_keyring/keyringrc.cfg" && "$(uv tool dir)/google-colab-cli/bin/python" -c "import keyrings.alt"') -Capture
        if ($kr.Code -eq 0) { Ok 'ログインのトークンはファイルに置く設定（キーリングは聞かれない）' }
        elseif ($Check) { Todo 'トークンの置き場所をファイルにする（install.ps1 を -Check なしで実行する。sudo は不要）' }
        else {
            $rc = Invoke-Wsl $Distro ("cd '" + (ConvertTo-WslPath $Cli) + "' && bash ./setup-keyring.sh")
            if ($rc -eq 0) { Ok 'トークンの置き場所をファイルにした（キーリングに保存済みのログインは使われなくなるので、手順5で一度ログインし直す）' }
            else { Todo "setup-keyring.sh が失敗した（終了コード $rc）。表示を見て直し、もう一度実行する" }
        }
    }
    elseif ($Check) { Todo 'WSL の準備（install.ps1 を -Check なしで実行する）' }
    else {
        Info 'setup-wsl.sh を実行します（sudo のパスワードを聞かれます）'
        $rc = Invoke-Wsl $Distro ("cd '" + (ConvertTo-WslPath $Cli) + "' && bash ./setup-wsl.sh")
        if ($rc -eq 0) { Ok 'WSL の準備が済んだ' } else { Todo "setup-wsl.sh が失敗した（終了コード $rc）。表示を見て直し、もう一度実行する" }
    }
} elseif ($SkipWsl) { Info '飛ばした（-SkipWsl）' }
elseif ($Distro) { Info 'Ubuntu の起動後に実行できます' }

# ---- 4. config.local.env ----
Step 4 'この PC の設定（strata-colab-cli\config.local.env）'
$conf = Join-Path $Cli 'config.local.env'
if (Test-Path $conf) { Ok '既にある（触らない）' }
elseif ($Check) { Todo 'config.local.env を作る（install.ps1 を -Check なしで実行する）' }
else {
    $text = (Get-Content (Join-Path $Cli 'config.local.example.env') -Raw) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($conf, $text, (New-Object Text.UTF8Encoding($false)))
    Ok '雛形から作った'
}
if (Test-Path $conf) {
    $hf = (Select-String -Path $conf -Pattern '^HF_TOKEN=\S' -Quiet)
    if ($hf) { Ok 'HF_TOKEN が書いてある（値は表示しない）' }
    else { Info '任意: HF_TOKEN を書くと、モデルの取得が速く・安定し、2回目以降の起動も速くなる（メモ帳で開いて書く）' }
}

# ---- 5. Colab CLI のログイン ----
Step 5 'Colab CLI のログイン（Google アカウント）'
if ($wslReady -and -not $SkipLogin) {
    # colab status はランタイムを作らない（Manager もこれで状態を見ている）。ログインしていなければブラウザでの許可を求める
    # ログインできたかは、別のプロセスの colab status で確かめる（トークンが保存されていなければ、次のコマンドでまた聞かれるため）
    $statusCmd = $prelude + 'timeout -k 5 60 colab status -s strata </dev/null 2>&1'
    $loggedIn = { param($o) $o -match "Session 'strata' not found|\[strata\].*Status:" -and $o -notmatch 'Could not (read|save) the OAuth token' }
    $out = (Invoke-Wsl $Distro $statusCmd -Capture).Out
    if (& $loggedIn $out) { Ok 'ログイン済み' }
    elseif ($Check) { Todo 'Colab CLI にログインする（install.ps1 を -Check なしで実行する）' }
    else {
        Info 'ブラウザで Google アカウントの許可を求められます。許可したら、この画面に戻ってください。'
        $null = Invoke-Wsl $Distro ($prelude + 'colab status -s strata')
        $out = (Invoke-Wsl $Distro $statusCmd -Capture).Out
        if (& $loggedIn $out) { Ok 'ログインした（次のコマンドでも聞かれないことを確かめた）' }
        elseif ($out -match 'keyring|OAuth token') {
            ($out -split '\r?\n' | Where-Object { $_ -match 'keyring|OAuth token' } | Select-Object -First 3) | ForEach-Object { Info $_ }
            Todo 'ログインのトークンを保存できない。install.cmd をもう一度実行して手順3でトークンの置き場所をファイルにしてから、ログインし直す'
        }
        else { Todo 'Colab CLI のログインが済んでいない（WSL で colab status -s strata を実行して許可する）' }
    }
} elseif ($SkipLogin) { Info '飛ばした（-SkipLogin）' }
elseif ($Distro) { Info 'Ubuntu の起動後に実行できます' }

# ---- 6. DeepSeek Harness（任意） ----
Step 6 'DeepSeek Harness（任意）'
$dshExe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
$dshProfile = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\cordis.patch.yml'
if (-not (Test-Path $dshExe)) { Info '入っていない（使うなら公式の配布元から入れて、もう一度実行する。Strata WebUI だけなら不要）' }
elseif ((Test-Path $dshProfile) -and (Select-String -Path $dshProfile -Pattern 'colab-strata:' -Quiet)) { Ok 'Colab の Strata につなぐ設定がある' }
elseif ((Test-Path $dshProfile) -and (Select-String -Path $dshProfile -Pattern '^\s*-\s*id:\s*llm-pi-ai\s*$' -Quiet)) {
    Todo "dsh の設定に別の llm-pi-ai がある。colab-manager\harness\dsh-desktop.patch.yml の colab-strata の部分を、手で $dshProfile に足す"
} elseif ($Check) { Todo 'dsh に Colab の Strata につなぐ設定を足す（install.ps1 を -Check なしで実行する）' }
else {
    $patch = (Get-Content (Join-Path $Mgr 'harness\dsh-desktop.patch.yml') -Raw) -replace "`r`n", "`n"
    New-Item -ItemType Directory -Force (Split-Path $dshProfile) | Out-Null
    if (Test-Path $dshProfile) {
        Copy-Item $dshProfile "$dshProfile.before-colab-kit" -Force
        $old = (Get-Content $dshProfile -Raw) -replace "`r`n", "`n"
        if ($old -and -not $old.EndsWith("`n")) { $old += "`n" }
        $patch = $old + $patch
    }
    [IO.File]::WriteAllText($dshProfile, $patch, (New-Object Text.UTF8Encoding($false)))
    Ok "設定を足した: $dshProfile（前の内容は .before-colab-kit）。dsh を開き直すと効く"
}

# ---- 7. ショートカット ----
Step 7 'ショートカット「Colab Manager」'
$targets = @(Join-Path $Kit 'Colab Manager.lnk')
if (-not $NoDesktopShortcut) { $targets += Join-Path ([Environment]::GetFolderPath('Desktop')) 'Colab Manager.lnk' }
if (-not $pwsh) { Info 'PowerShell 7 が入ってから作る' }
elseif ($Check) {
    $sh = New-Object -ComObject WScript.Shell
    foreach ($t in $targets) {
        if (-not (Test-Path $t)) { Todo "ショートカットを作る: $t" }
        elseif ($sh.CreateShortcut($t).Arguments -like "*$(Join-Path $Mgr 'Manager.ps1')*") { Ok $t }
        elseif ($t -eq $targets[0]) { Todo "古い置き場を指しているので作り直す: $t" }
        else { Info "別の場所の Manager を指すショートカットがある（触らない。このキットに向け直すなら install.cmd -ReplaceShortcuts）: $t" }
    }
}
else {
    $sh = New-Object -ComObject WScript.Shell
    $mine = Join-Path $Mgr 'Manager.ps1'
    foreach ($t in $targets) {
        $s = $sh.CreateShortcut($t)
        # キットのフォルダの中のものは、いつもこのキットに向ける（フォルダを移したり写したりすると古い置き場を指したままになるため）。
        # デスクトップのものが別の場所のキットを指していれば、-ReplaceShortcuts のときだけ向け直す
        if ($t -ne $targets[0] -and -not $ReplaceShortcuts -and (Test-Path $t) -and $s.Arguments -and ($s.Arguments -notlike "*$mine*")) { Info "別の場所の Manager を指すショートカットがあるので触らない: $t（$($s.Arguments)）。このキットに向け直すなら install.cmd -ReplaceShortcuts"; continue }
        $s.TargetPath = $pwsh
        $s.Arguments = '-NoProfile -WindowStyle Hidden -File "' + (Join-Path $Mgr 'Manager.ps1') + '"'
        $s.WorkingDirectory = $Mgr
        $s.WindowStyle = 1
        $s.Save()
        Ok $t
    }
}

Write-Host ''
if ($problems.Count) {
    Write-Host "残っていること（$($problems.Count) 件）:" -ForegroundColor Yellow
    $problems | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host '準備ができました。「Colab Manager」のショートカットから開きます（開くと Colab の GPU を借りて起動し、CU がかかります）。' -ForegroundColor Green
exit 0
