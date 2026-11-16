#requires -Version 7
<#
.SYNOPSIS
  監督（Opus など）が書いたタスクカードを、ワーカー（Colab の Strata / Qwen3.8、dsh headless）に渡して結果を確かめる。

.DESCRIPTION
  サブコマンド:
    run      -Card <カード> [-Repo <リポジトリ>] [-Base <起点>] [-Async]
             1件をワーカーに渡す。-Async なら裏で動かしてすぐ戻る（実行フォルダを表示）。
    followup -Run <実行フォルダか ID> -Note <指示のファイルか文字列> [-Async]
             前回の結果に差し戻す。前回のカード・要確認・検証の失敗を引き継ぎ、Note を「前回からの指示」として足す。
             前回のブランチが残っていればその上で、採用済みならリポジトリの現在の HEAD の上で作業させる。
    adopt    -Run <実行フォルダか ID> [-Message <コミットの件名>]
             採用: squash merge してコミットし、worktree とブランチを消して台帳に書く。
    discard  -Run <実行フォルダか ID>
             破棄: worktree とブランチを消して台帳に書く。
    status   [-Last <件数>]
             最近の実行の状態の一覧。
    queue    [-Parallel <同時数>]
             queue\ に置いたカードをまとめて流す（同時に Parallel 本まで）。流したカードは queue\started\ へ移す。

  run の流れ:
    1. カードを読み、必須の項目がそろっているか確かめる（そろっていなければ渡さない）。
    2. Strata の API（127.0.0.1:8080）が応答するまで待つ。止まっていれば Colab Manager に起動させる。
    3. 対象リポジトリに git worktree（ブランチ delegate/<ID>-<時刻>）を作り、その中だけで作業させる。
    4. dsh headless を workspace-write（書き込みは worktree の中だけ）で動かす。
    5. 終わったら、このスクリプト自身が確かめる（ワーカーの自己申告は使わない）:
       - 変更されたファイルが「変更してよいファイル」の範囲内か
       - 「検証コマンド」の結果（ワーカーにも見えている）
       - 「受け入れテスト」の結果（監督が書いたテスト。ワーカーには見せず、終わった後にだけ置いて実行し、消す）
    6. 変更をブランチにコミットし、runs\<ID>-<時刻>\ に短い report.md、ワーカーの報告の全文 worker-report.md、
       diff.patch、report.json を置き、台帳に1行足す。

.EXAMPLE
  pwsh -File G:\local\delegation\delegate.ps1 run -Card G:\local\delegation\cards\T-001.md -Async
  pwsh -File G:\local\delegation\delegate.ps1 followup -Run T-001-20261109-101500 -Note "要確認1は案Aで。2は不要。"
  pwsh -File G:\local\delegation\delegate.ps1 adopt -Run T-001-20261109-101500
#>
param(
    [Parameter(Position = 0)][ValidateSet('run', 'followup', 'adopt', 'discard', 'status', 'queue', 'wait', 'precheck')][string]$Command = 'run',
    [string]$Card,
    [string]$Repo,
    [string]$Base,
    [string]$Run,
    [string]$Note,
    [string]$Message,
    [switch]$Async,
    [int]$Parallel = 2,
    [int]$Last = 15,
    [int]$TimeoutMinutes = 40,
    [int]$WaitReadyMinutes = 20,
    [string]$Stamp            # 内部用: -Async で子に渡す実行の時刻
)
$ErrorActionPreference = 'Stop'
# パイプやログに渡すとき、日本語が既定のコードページ（cp932）で化けないようにする
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$Root = $PSScriptRoot
$Runs = Join-Path $Root 'runs'
$QueueDir = Join-Path $Root 'queue'
$AcceptRoot = Join-Path $Root 'accept'
$HarnessExe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
$CliJs = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\app.asar\dsh\node_modules\@deepseek-ai\dsh-desktop-host\lib\cli.js'
# colab-manager などと同じフォルダ（$KitRoot）の下に並べて置く。headless の dsh 設定は、この PC の以前の置き場があればそれを使う
$KitRoot = Split-Path $Root -Parent
$StrataPatch = @((Join-Path $KitRoot 'deepseek-harness\strata.patch.yml'), (Join-Path $KitRoot 'colab-manager\harness\strata.patch.yml')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$WorkerPatch = Join-Path $Root 'worker.patch.yml'
$ManagerLink = Join-Path $KitRoot 'Colab Manager.lnk'
$Ledger = Join-Path $Root 'ledger.md'
$Pwsh = (Get-Process -Id $PID).Path
# git は Git for Windows を使う。PATH の先頭に msys2 の git（devkitPro）があり、それだと worktree の .git に /g/... 形式の
# パスが書かれて、後で worktree remove などが失敗する。
$Git = @('C:\Program Files\Git\cmd\git.exe', 'C:\Program Files\Git\mingw64\bin\git.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $Git) { $Git = 'git' }
$Required = @('タスクID', '目的', '変更してよいファイル', 'やること', '完了条件', '検証コマンド')
$Hidden = @('受け入れテスト', '受け入れコマンド')          # ワーカーに渡すカードからは外す
$Known = $Required + $Hidden + @('対象リポジトリ', '入力', '出力', 'やってはいけないこと', '不明点が出たら', '依存関係', '並列可否', '前回からの指示')

function Say($m) { Write-Host "[delegate] $m" }
function Write-Utf8([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false)) }

# ---- カード ----
# 見出しは「キー:」のほか「キー（補足）:」も読む（AGENT.md の書式どおり）。続く行は次の見出しまでその値。
function Read-CardText([string]$Text) {
    $fields = [ordered]@{}; $key = $null
    foreach ($line in ($Text -split '\r?\n')) {
        $hit = $null
        foreach ($k in $Known) { if ($line -match "^\s*$([regex]::Escape($k))\s*(?:[（(][^）)]*[）)])?\s*[:：]\s*(.*)$") { $hit = $k; $rest = $Matches[1]; break } }
        if ($hit) { $key = $hit; $fields[$key] = $rest.Trim(); continue }
        if ($key) { $fields[$key] = ($fields[$key] + "`n" + $line).Trim() }
    }
    return $fields
}
function Read-Card([string]$Path) {
    $text = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $fields = Read-CardText $text
    $missing = @($Required | Where-Object { -not $fields.Contains($_) -or -not $fields[$_] })
    if ($missing) { throw "カードに必須の項目がありません: $($missing -join ', ')" }
    if ($fields['タスクID'] -notmatch '^[A-Za-z0-9._-]+$') { throw "タスクIDは英数字と . _ - だけにしてください: $($fields['タスクID'])" }
    if ($fields.Contains('受け入れテスト') -xor $fields.Contains('受け入れコマンド')) { throw '受け入れテストと受け入れコマンドは両方書いてください。' }
    return @{ Text = $text; Fields = $fields }
}
# ワーカーに見せるカード: 受け入れテストの項目（場所と実行方法）を外す
function Get-WorkerCardText([string]$Text) {
    $out = New-Object System.Collections.Generic.List[string]; $skip = $false
    foreach ($line in ($Text -split '\r?\n')) {
        $isHead = $false; $isHidden = $false
        foreach ($k in $Known) { if ($line -match "^\s*$([regex]::Escape($k))\s*(?:[（(][^）)]*[）)])?\s*[:：]") { $isHead = $true; $isHidden = $k -in $Hidden; break } }
        if ($isHead) { $skip = $isHidden }
        if (-not $skip) { $out.Add($line) }
    }
    return ($out -join "`n").TrimEnd()
}
function Split-List([string]$v) { @($v -split '[\r\n,、]+' | ForEach-Object { ($_ -replace '^\s*[-*]\s*', '').Trim().Trim('`') } | Where-Object { $_ }) }
function Split-Commands([string]$v) { @($v -split '\r?\n' | ForEach-Object { ($_ -replace '^\s*[-*]\s*', '').Trim().Trim('`') } | Where-Object { $_ -and $_ -notmatch '^```' }) }

function Resolve-RunDir([string]$R) {
    if (-not $R) { throw '-Run を指定してください（実行フォルダか、その名前）。' }
    if (Test-Path -LiteralPath $R) { return (Resolve-Path -LiteralPath $R).Path }
    $d = Join-Path $Runs $R; if (Test-Path -LiteralPath $d) { return $d }
    $hits = @(Get-ChildItem $Runs -Directory -Filter "$R*" | Sort-Object Name -Descending)
    if ($hits.Count -ge 1) { return $hits[0].FullName }
    throw "実行が見つかりません: $R"
}
function Read-Report([string]$Dir) {
    $p = Join-Path $Dir 'report.json'
    if (-not (Test-Path $p)) { throw "まだ終わっていないか、失敗した実行です（report.json がありません）: $Dir" }
    return Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json
}
function Add-Ledger([string]$Id, [string]$Who, [string]$Why, [string]$Result) {
    if (-not (Test-Path $Ledger)) { "| 日時 | タスクID | 担当 | 理由 | 結果 |`n|---|---|---|---|---|" | Set-Content -LiteralPath $Ledger -Encoding utf8 }
    Add-Content -LiteralPath $Ledger -Encoding utf8 -Value "| $(Get-Date -Format 'yyyy-MM-dd HH:mm') | $Id | $Who | $Why | $Result |"
}
# ワーカーの報告から「要確認」の節を取り出す（無ければ空）
function Get-OpenQuestions([string]$Final) {
    if (-not $Final) { return '' }
    $lines = $Final -split '\r?\n'
    $start = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^\s*(#+\s*|\*\*)?\s*要確認') { $start = $i; break } }
    if ($start -lt 0) { return '' }
    $body = ($lines[$start..($lines.Count - 1)] -join "`n").Trim()
    if ($body.Length -gt 2500) { $body = $body.Substring(0, 2500) + "`n…（全文は worker-report.md）" }
    return $body
}

# ---- Strata の準備 ----
function Get-Health { try { Invoke-RestMethod -Uri 'http://127.0.0.1:8080/health' -TimeoutSec 4 -NoProxy } catch { $null } }
function Wait-Strata {
    $h = Get-Health
    if (-not $h) {
        $mgr = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like '*colab-manager\Manager.ps1*' }
        if (-not $mgr) { Say 'Strata が応答しません。Colab Manager を開いて起動します（約9分）。'; Start-Process $ManagerLink }
        else {
            # 開いている Manager に起動を頼む（ランタイムが無いときだけ起動する。起動中・稼働中なら何もしない）
            Say 'Strata が応答しません。開いている Colab Manager に起動を頼みます（約9分）。'
            New-Item -ItemType File -Force (Join-Path $KitRoot 'colab-manager\state\start-now.request') | Out-Null
        }
        $deadline = (Get-Date).AddMinutes($WaitReadyMinutes)
        do { Start-Sleep 10; $h = Get-Health } until ($h -or (Get-Date) -gt $deadline)
        if (-not $h) { throw "Strata が $WaitReadyMinutes 分以内に応答しませんでした。Colab Manager の画面を確認してください。" }
    }
    if (-not $h.loaded) { Say 'モデルが外れています。最初のリクエストで読み込み直します（約3分）。' }
}

function Invoke-Commands([string[]]$Commands, [string]$Dir) {
    $results = @()
    foreach ($cmd in $Commands) {
        $out = & $Pwsh -NoProfile -Command "[Console]::OutputEncoding=[Text.UTF8Encoding]::new(`$false); Set-Location -LiteralPath '$Dir'; $cmd" 2>&1 | Out-String
        $results += [pscustomobject]@{ command = $cmd; exit = $LASTEXITCODE; tail = (($out -split '\r?\n') | Where-Object { $_ } | Select-Object -Last 25) -join "`n" }
    }
    return , $results
}

# ---- run ----
function Start-Delegation([string]$CardPath, [string]$RepoArg, [string]$BaseArg) {
    $cardInfo = Read-Card (Resolve-Path -LiteralPath $CardPath).Path
    $f = $cardInfo.Fields
    $id = $f['タスクID']
    if (-not $RepoArg) { $RepoArg = $f['対象リポジトリ'] }
    if (-not $RepoArg) { throw '対象のリポジトリがありません。-Repo を渡すか、カードに「対象リポジトリ:」を書いてください。' }
    $repoPath = (Resolve-Path -LiteralPath $RepoArg.Trim().Trim('`')).Path
    & $Git -C $repoPath rev-parse --is-inside-work-tree *> $null; if ($LASTEXITCODE) { throw "git リポジトリではありません: $repoPath" }
    if (-not $BaseArg) { $BaseArg = 'HEAD' }
    $allowed = Split-List $f['変更してよいファイル']
    $verify = Split-Commands $f['検証コマンド']
    $acceptDir = $null; $acceptCmds = @()
    if ($f.Contains('受け入れテスト')) {
        $a = $f['受け入れテスト'].Trim().Trim('`')
        $acceptDir = if ([IO.Path]::IsPathRooted($a)) { $a } else { Join-Path $AcceptRoot $a }
        if (-not (Test-Path -LiteralPath $acceptDir -PathType Container)) { throw "受け入れテストのフォルダがありません: $acceptDir" }
        $acceptCmds = Split-Commands $f['受け入れコマンド']
    }

    $st = if ($Stamp) { $Stamp } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    $run = Join-Path $Runs "$id-$st"
    if ($Async) {
        # 自分を裏で動かし、すぐ戻る。終わると run\report.json と done.txt ができる
        New-Item -ItemType Directory -Force $run | Out-Null
        $childArgs = @('-NoProfile', '-File', "`"$PSCommandPath`"", 'run', '-Card', "`"$((Resolve-Path -LiteralPath $CardPath).Path)`"", '-Repo', "`"$repoPath`"", '-Base', $BaseArg, '-Stamp', $st, '-TimeoutMinutes', $TimeoutMinutes)
        Start-Process -FilePath $Pwsh -ArgumentList ($childArgs -join ' ') -WindowStyle Hidden -RedirectStandardOutput (Join-Path $run 'delegate.log') -RedirectStandardError (Join-Path $run 'delegate.err.log') | Out-Null
        Say "裏で開始しました: $run"
        Say "終わると $(Join-Path $run 'done.txt') ができます。状態: delegate.ps1 status"
        return
    }

    Wait-Strata
    # worktree の置き場（既定 G:\delegate-runs。DELEGATE_WT_ROOT で変更）。
    # dsh の Windows サンドボックスは作業フォルダに自分用のアクセス権を書き込むので、
    # 実行するアカウントにそのフォルダのフル コントロール（アクセス権の変更を含む）が要る。
    # G: や D: の既定は Authenticated Users の「変更」だけなので、そのままでは失敗する（SetNamedSecurityInfoW failed (Win32 5)）。
    # → 置き場を初めて作るときに、自分のアカウントへフル コントロールを付ける（2026-11-09 に G: で確認）。
    # %LOCALAPPDATA% の下は、サンドボックスのシェルが親フォルダを通れず使えない（Access denied）。
    # 注意: 置き場はこの PC のほかのアカウントからも読める（ドライブの既定のアクセス権を継ぐ）。秘密を含むリポジトリには使わない。
    # 既定は、このフォルダと同じドライブの直下（この PC では G:\delegate-runs）
    $WtRoot = if ($env:DELEGATE_WT_ROOT) { $env:DELEGATE_WT_ROOT } else { Join-Path ([IO.Path]::GetPathRoot($Root)) 'delegate-runs' }
    if (-not (Test-Path -LiteralPath $WtRoot)) {
        New-Item -ItemType Directory -Force $WtRoot | Out-Null
        icacls $WtRoot /grant "$($env:USERNAME):(OI)(CI)F" *> $null
        if ($LASTEXITCODE) { throw "作業フォルダに自分のフル コントロールを付けられません: $WtRoot" }
    }
    $wt = Join-Path $WtRoot "$id-$st\wt"
    $branch = "delegate/$id-$st"
    New-Item -ItemType Directory -Force $run | Out-Null
    Copy-Item -LiteralPath (Resolve-Path -LiteralPath $CardPath).Path (Join-Path $run 'card.md')
    & $Git -C $repoPath worktree add -q -b $branch $wt $BaseArg; if ($LASTEXITCODE) { throw 'git worktree add に失敗しました' }
    $baseSha = (& $Git -C $wt rev-parse HEAD).Trim()
    Say "worktree: $wt（ブランチ $branch、元 $($baseSha.Substring(0, 7))）"

    $prompt = @"
次のタスクカードの作業を、このフォルダ（git の作業ツリー）の中で行ってください。
変更してよいファイル以外は変更しないこと。最後に、カードの検証コマンドを実行して結果を報告すること。

----- タスクカード -----
$(Get-WorkerCardText $cardInfo.Text)
----- ここまで -----
"@
    $promptPath = Join-Path $run 'prompt.txt'
    Write-Utf8 $promptPath $prompt
    $events = Join-Path $run 'events.jsonl'; $errLog = Join-Path $run 'dsh-stderr.log'
    $env:ELECTRON_RUN_AS_NODE = '1'
    $env:STRATA_API_KEY = 'local-ssh'          # Strata は鍵なし。dsh の設定が鍵の変数を要求するためのダミー値
    $dshArgs = @('--expose-internals', $CliJs, '--profile', 'headless', '--patch', $StrataPatch, '--patch', $WorkerPatch,
        '--json', '--permission-mode', 'workspace-write', '--approval-policy', 'never', '-') | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
    $t0 = Get-Date
    Say "ワーカーに渡しました（上限 $TimeoutMinutes 分）。"
    $p = Start-Process -FilePath $HarnessExe -ArgumentList ($dshArgs -join ' ') -WorkingDirectory $wt -NoNewWindow -PassThru `
        -RedirectStandardInput $promptPath -RedirectStandardOutput $events -RedirectStandardError $errLog
    $timedOut = -not $p.WaitForExit($TimeoutMinutes * 60 * 1000)
    if ($timedOut) { try { Stop-Process -Id $p.Id -Force } catch {} ; Get-CimInstance Win32_Process -Filter "ParentProcessId=$($p.Id)" | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    $workerSecs = [int]((Get-Date) - $t0).TotalSeconds

    $final = ''; $reason = ''; $inTok = 0; $outTok = 0; $tools = 0
    if (Test-Path $events) {
        foreach ($line in [IO.File]::ReadAllLines($events)) {
            try { $e = $line | ConvertFrom-Json } catch { continue }
            switch ($e.type) {
                'final' { $final = [string]$e.text; $reason = [string]$e.reason.kind }
                'tool_call' { $tools++ }
                'status' { if ($e.phase -eq 'step_end' -and $e.usage) { $inTok += [int]$e.usage.inputTokens + [int]$e.usage.cacheReadTokens; $outTok += [int]$e.usage.outputTokens } }
            }
        }
    }
    Write-Utf8 (Join-Path $run 'worker-report.md') $final

    # 範囲と検証（このスクリプトが確かめる）
    & $Git -C $wt add -A
    $changed = @(& $Git -C $wt diff --cached --name-only | Where-Object { $_ })
    $outside = @($changed | Where-Object { $c = $_; -not ($allowed | Where-Object { $c -like $_ -or $c -like ($_.TrimEnd('/') + '/*') }) })
    $verifyResults = Invoke-Commands $verify $wt
    $verifyOk = ($verifyResults.Count -gt 0) -and -not ($verifyResults | Where-Object { $_.exit -ne 0 })

    # 受け入れテスト: ワーカーが終わった後にだけ置いて実行し、消す（コミットには入らない）
    $acceptResults = @(); $acceptOk = $true; $placed = @()
    if ($acceptDir) {
        try {
            foreach ($src in Get-ChildItem -LiteralPath $acceptDir -Recurse -File) {
                $rel = [IO.Path]::GetRelativePath($acceptDir, $src.FullName)
                $dst = Join-Path $wt $rel
                if (Test-Path -LiteralPath $dst) { throw "受け入れテストのファイルが作業ツリーの既存のファイルと重なります: $rel" }
                New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
                Copy-Item -LiteralPath $src.FullName $dst; $placed += $dst
            }
            $acceptResults = Invoke-Commands $acceptCmds $wt
            $acceptOk = ($acceptResults.Count -gt 0) -and -not ($acceptResults | Where-Object { $_.exit -ne 0 })
        }
        catch { $acceptOk = $false; $acceptResults = @([pscustomobject]@{ command = '(受け入れテストの準備)'; exit = -1; tail = $_.Exception.Message }) }
        finally {
            foreach ($d in $placed) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
            Get-ChildItem -LiteralPath $wt -Recurse -Directory -Filter '__pycache__' -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # 記録
    & $Git -C $wt diff --cached | Set-Content -LiteralPath (Join-Path $run 'diff.patch') -Encoding utf8
    $diffStat = (& $Git -C $wt diff --cached --shortstat) -join ''
    if ($changed) { & $Git -C $wt -c user.name='delegate-worker' -c user.email='worker@localhost' commit -q -m "worker: $id" --no-verify }
    $status = if ($timedOut) { 'timeout' } elseif ($reason -ne 'completed') { 'worker_error' } elseif (-not $changed) { 'no_change' } elseif ($outside) { 'out_of_scope' } elseif (-not $verifyOk) { 'verify_failed' } elseif (-not $acceptOk) { 'accept_failed' } else { 'ready_for_review' }
    $questions = Get-OpenQuestions $final
    $report = [ordered]@{
        id = $id; status = $status; branch = $branch; base = $baseSha; worktree = $wt; repo = $repoPath; card = (Join-Path $run 'card.md')
        worker = @{ reason = $reason; seconds = $workerSecs; tool_calls = $tools; input_tokens = $inTok; output_tokens = $outTok }
        changed = $changed; diffstat = $diffStat; outside_allowed = $outside; allowed = $allowed
        verify = $verifyResults; accept = $acceptResults; open_questions = $questions
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $run 'report.json') -Encoding utf8

    # 監督が読む短い報告（全文は worker-report.md）
    $bt = [char]96
    $md = @("# ${id}: $status", '',
        "- 変更: $(if ($changed) { ($changed | ForEach-Object { $bt + $_ + $bt }) -join ', ' } else { 'なし' })（$diffStat）",
        "- 範囲外: $(if ($outside) { ($outside | ForEach-Object { $bt + $_ + $bt }) -join ', ' } else { 'なし' })",
        "- ワーカー: $reason / $workerSecs 秒 / ツール $tools 回")
    foreach ($r in $verifyResults) { $md += "- 検証 $bt$($r.command)$bt → exit $($r.exit)" }
    foreach ($r in $acceptResults) { $md += "- 受け入れ $bt$($r.command)$bt → exit $($r.exit)" }
    foreach ($r in @($verifyResults) + @($acceptResults) | Where-Object { $_.exit -ne 0 }) { $md += @('', "失敗した出力（$($r.command)）:", '```', $r.tail, '```') }
    $md += @('', '## 要確認（ワーカーの報告から）', $(if ($questions) { $questions } else { '（節が見当たりません。全文は worker-report.md）' }), '',
        '## 次の操作',
        "- 差分: $bt$(Join-Path $run 'diff.patch')$bt",
        "- 採用: ${bt}delegate.ps1 adopt -Run $id-$st$bt",
        "- 差し戻し: ${bt}delegate.ps1 followup -Run $id-$st -Note <指示>$bt",
        "- 破棄: ${bt}delegate.ps1 discard -Run $id-$st$bt")
    Write-Utf8 (Join-Path $run 'report.md') ($md -join "`n")
    Add-Ledger $id 'worker' '(delegate.ps1)' "$status / $workerSecs 秒 / runs\$id-$st"
    Write-Utf8 (Join-Path $run 'done.txt') $status
    Say "結果: $status  → $(Join-Path $run 'report.md')"
    if ($status -ne 'ready_for_review') { exit 1 }
}

# ---- followup ----
function Start-Followup {
    $dir = Resolve-RunDir $Run
    $rep = Read-Report $dir
    if (-not $Note) { throw '-Note に指示（ファイルのパスか文字列）を渡してください。' }
    $noteText = if (Test-Path -LiteralPath $Note -PathType Leaf) { Get-Content -LiteralPath $Note -Raw -Encoding utf8 } else { $Note }
    $prevText = Get-Content -LiteralPath (Join-Path $dir 'card.md') -Raw -Encoding utf8
    $prev = Read-CardText $prevText
    $prevId = $prev['タスクID']
    $newId = if ($prevId -match '^(.*)-r(\d+)$') { "$($Matches[1])-r$([int]$Matches[2] + 1)" } else { "$prevId-r2" }
    # 前回の結果のうち、ワーカーに伝えるもの: 検証の失敗と、前回の要確認
    $failed = @(@($rep.verify) | Where-Object { $_ -and $_.exit -ne 0 } | ForEach-Object { "- $($_.command) → exit $($_.exit)`n$($_.tail)" })
    $acceptFailed = @(@($rep.accept) | Where-Object { $_ -and $_.exit -ne 0 })
    $carry = @("監督からの指示:", $noteText.Trim())
    if ($failed) { $carry += @('', '前回の検証コマンドの失敗:', ($failed -join "`n")) }
    if ($acceptFailed) { $carry += @('', '前回の作業は、監督の受け入れテストに通りませんでした（テストの中身は示しません。上の指示を手がかりに直してください）。') }
    if ($rep.open_questions) { $carry += @('', '前回あなたが挙げた要確認（回答は上の指示にあります。指示に無いものは前回の判断のままでよい）:', [string]$rep.open_questions) }
    # 前回の「前回からの指示」は引き継がず、新しいものに置き換える
    $body = ($prevText -split '\r?\n' | Where-Object { $true }) -join "`n"
    $body = [regex]::Replace($body, '(?ms)^\s*前回からの指示\s*(?:[（(][^）)]*[）)])?\s*[:：].*?(?=^\s*(?:' + (($Known | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s*(?:[（(][^）)]*[）)])?\s*[:：]|\z)', '')
    $body = [regex]::Replace($body, '(?m)^(\s*タスクID\s*(?:[（(][^）)]*[）)])?\s*[:：]\s*).*$', "`${1}$newId")
    $body = $body.TrimEnd() + "`n前回からの指示:`n" + ($carry -join "`n") + "`n"
    New-Item -ItemType Directory -Force (Join-Path $Root 'cards') | Out-Null
    $newCard = Join-Path $Root "cards\$newId.md"
    Write-Utf8 $newCard $body
    # 前回のブランチが残っていればその上で（未採用の作業の続き）、無ければ現在の HEAD の上で
    & $Git -C $rep.repo rev-parse --verify --quiet "refs/heads/$($rep.branch)" *> $null
    $baseRef = if ($LASTEXITCODE -eq 0) { $rep.branch } else { 'HEAD' }
    Say "差し戻しのカード: $newCard（起点 $baseRef）"
    Start-Delegation $newCard $rep.repo $baseRef
}

# ---- adopt / discard ----
function Remove-RunTree($rep) {
    if (Test-Path -LiteralPath $rep.worktree) { & $Git -C $rep.repo worktree remove --force $rep.worktree 2>$null }
    & $Git -C $rep.repo worktree prune 2>$null
    & $Git -C $rep.repo rev-parse --verify --quiet "refs/heads/$($rep.branch)" *> $null
    if ($LASTEXITCODE -eq 0) { & $Git -C $rep.repo branch -q -D $rep.branch }
    # worktree の親（<置き場>\<実行>）が空なら消す
    $parentDir = Split-Path $rep.worktree
    if ((Test-Path -LiteralPath $parentDir) -and -not (Get-ChildItem -LiteralPath $parentDir -Force)) { Remove-Item -LiteralPath $parentDir -Force }
}
# 差し戻しの元の実行: この実行の起点（base）が、その実行のブランチの先端と同じもの。差し戻しを重ねていれば、さかのぼって全部
function Get-ParentRuns($rep) {
    $found = @(); $base = $rep.base; $seen = @{}
    while ($base -and -not $seen[$base]) {
        $seen[$base] = $true; $hit = $null
        foreach ($d in Get-ChildItem $Runs -Directory) {
            $p = Join-Path $d.FullName 'report.json'
            if (-not (Test-Path $p)) { continue }
            $r = Get-Content -LiteralPath $p -Raw -Encoding utf8 | ConvertFrom-Json
            if ($r.repo -ne $rep.repo -or $r.branch -eq $rep.branch) { continue }
            $tip = & $Git -C $r.repo rev-parse --verify --quiet "refs/heads/$($r.branch)" 2>$null
            # ワーカーのコミットがある（先端が起点と違う）実行だけ。変更の無かった実行の先端は起点と同じで、無関係の実行と重なりうる
            if ($LASTEXITCODE -eq 0 -and $tip -and $tip.Trim() -eq $base -and $tip.Trim() -ne $r.base) { $hit = @{ Dir = $d.FullName; Report = $r }; break }
        }
        if (-not $hit) { break }
        $found += $hit; $base = $hit.Report.base
    }
    return , $found
}
function Invoke-Adopt {
    $dir = Resolve-RunDir $Run
    $rep = Read-Report $dir
    if ($rep.status -ne 'ready_for_review') { Say "注意: この実行の状態は $($rep.status) です。" }
    $dirty = & $Git -C $rep.repo status --porcelain --untracked-files=no
    if ($dirty) { throw "対象リポジトリに未コミットの変更があります。先にコミットか退避をしてください: $($rep.repo)" }
    $mergeOut = & $Git -C $rep.repo merge -q --squash $rep.branch 2>&1; if ($LASTEXITCODE) { Write-Host ($mergeOut -join "`n"); & $Git -C $rep.repo merge --abort 2>$null; & $Git -C $rep.repo reset -q --merge 2>$null; throw 'squash merge に失敗しました（衝突など）。差分を見て手で取り込んでください。' }
    $card = Read-CardText (Get-Content -LiteralPath (Join-Path $dir 'card.md') -Raw -Encoding utf8)
    $subject = if ($Message) { $Message } else { "$($rep.id): $((($card['目的'] -split '\r?\n')[0]).Trim())" }
    $msg = "$subject`n`nDelegated to the Qwen3.8 worker (Colab Strata, dsh headless) and reviewed by the supervisor.`nRun: runs\$(Split-Path $dir -Leaf)"
    # 採用のコミットは監督が作るもの。DELEGATE_COAUTHOR（例: "Claude Opus 5.5 <noreply@anthropic.com>"）があれば共著者の行を付ける
    $coauthor = if ($null -ne $env:DELEGATE_COAUTHOR) { $env:DELEGATE_COAUTHOR } else { 'Claude Opus 5.5 <noreply@anthropic.com>' }
    if ($coauthor) { $msg += "`n`nCo-Authored-By: $coauthor" }
    & $Git -C $rep.repo commit -q -m $msg; if ($LASTEXITCODE) { throw 'コミットに失敗しました。' }
    $sha = (& $Git -C $rep.repo rev-parse --short HEAD).Trim()
    # 差し戻しの元（採用されずに残っているブランチと worktree）も片付ける。中身はこのコミットに含まれている
    foreach ($par in Get-ParentRuns $rep) {
        Remove-RunTree $par.Report
        Write-Utf8 (Join-Path $par.Dir 'superseded.txt') "$(Split-Path $dir -Leaf) を採用（$sha）"
        Say "差し戻しの元も片付けました: $(Split-Path $par.Dir -Leaf)"
    }
    Remove-RunTree $rep
    Add-Ledger $rep.id 'worker' '採用' "$sha"
    Write-Utf8 (Join-Path $dir 'adopted.txt') $sha
    Say "採用しました: $sha（$subject）"
}
function Invoke-Discard {
    $dir = Resolve-RunDir $Run
    $rep = Read-Report $dir
    Remove-RunTree $rep
    Add-Ledger $rep.id 'worker' '破棄' "runs\$(Split-Path $dir -Leaf)"
    Write-Utf8 (Join-Path $dir 'discarded.txt') (Get-Date -Format o)
    Say "破棄しました: $($rep.branch)"
}

# ---- status ----
function Show-Status {
    if (-not (Test-Path $Runs)) { Say '実行はまだありません。'; return }
    $rows = foreach ($d in Get-ChildItem $Runs -Directory | Sort-Object CreationTime -Descending | Select-Object -First $Last) {
        $state = if (Test-Path (Join-Path $d.FullName 'superseded.txt')) { '差し戻し先を採用' }
        elseif (Test-Path (Join-Path $d.FullName 'adopted.txt')) { "採用 $((Get-Content (Join-Path $d.FullName 'adopted.txt') -Raw).Trim())" }
        elseif (Test-Path (Join-Path $d.FullName 'discarded.txt')) { '破棄' }
        elseif (Test-Path (Join-Path $d.FullName 'done.txt')) { (Get-Content (Join-Path $d.FullName 'done.txt') -Raw).Trim() }
        elseif (Test-Path (Join-Path $d.FullName 'report.json')) { (Get-Content (Join-Path $d.FullName 'report.json') -Raw | ConvertFrom-Json).status }
        elseif (Test-Path (Join-Path $d.FullName 'events.jsonl')) { "実行中（イベント $(@(Get-Content (Join-Path $d.FullName 'events.jsonl')).Count) 行）" }
        else { '準備中' }
        [pscustomobject]@{ 実行 = $d.Name; 状態 = $state }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
}

# ---- wait ----
# 裏で動かした実行が終わるまで待ち、短い報告を表示する（Claude Code では Bash の run_in_background で呼ぶと、終わったときに知らせが来る）
function Wait-Run {
    $dir = Resolve-RunDir $Run
    $stampOf = (Split-Path $dir -Leaf) -replace '^.*-(\d{8}-\d{6})$', '$1'
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes + $WaitReadyMinutes)
    while (-not (Test-Path (Join-Path $dir 'done.txt'))) {
        $alive = Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -like "*-Stamp $stampOf*" -and $_.ProcessId -ne $PID }
        if (-not $alive) { Start-Sleep 3; if (Test-Path (Join-Path $dir 'done.txt')) { break }; Say "実行が終わらずに止まりました: $dir（delegate.err.log を確認）"; exit 2 }
        if ((Get-Date) -gt $deadline) { Say "待ちきれませんでした: $dir"; exit 2 }
        Start-Sleep 5
    }
    $rm = Join-Path $dir 'report.md'
    if (Test-Path $rm) { Get-Content -LiteralPath $rm -Raw -Encoding utf8 | Write-Host }
    else { Say "report.md がありません: $((Get-Content -LiteralPath (Join-Path $dir 'done.txt') -Raw).Trim())" }
    if ((Get-Content -LiteralPath (Join-Path $dir 'done.txt') -Raw).Trim() -ne 'ready_for_review') { exit 1 }
}

# ---- queue ----
function Invoke-Precheck {
    # 渡す前に、起点のコードで受け入れテストを一度だけ流す。
    # まだ作っていない機能のテストは落ちてよい。見るのは「落ち方」: 前提の操作の失敗・import の誤り・テスト自体の誤りで落ちていないか。
    if (-not $Card) { throw '-Card を指定してください。' }
    $f = (Read-Card (Resolve-Path -LiteralPath $Card).Path).Fields
    if (-not $f.Contains('受け入れテスト')) { Say 'このカードに受け入れテストはありません。'; return }
    $repoArg = if ($Repo) { $Repo } else { $f['対象リポジトリ'] }
    $repoPath = (Resolve-Path -LiteralPath $repoArg.Trim().Trim('`')).Path
    $a = $f['受け入れテスト'].Trim().Trim('`')
    $acceptDir = if ([IO.Path]::IsPathRooted($a)) { $a } else { Join-Path $AcceptRoot $a }
    $base = if ($Base) { $Base } else { 'HEAD' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("delegate-precheck-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    & $Git -C $repoPath worktree add -q --detach $tmp $base *> $null; if ($LASTEXITCODE) { throw "worktree を作れません（起点 $base）" }
    try {
        foreach ($src in Get-ChildItem -LiteralPath $acceptDir -Recurse -File) {
            $dst = Join-Path $tmp ([IO.Path]::GetRelativePath($acceptDir, $src.FullName))
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null; Copy-Item -LiteralPath $src.FullName $dst
        }
        foreach ($r in Invoke-Commands (Split-Commands $f['受け入れコマンド']) $tmp) {
            Say "起点 $base で: $($r.command) → exit $($r.exit)"
            # 結果の行と、失敗の理由の行だけ（全文は読まない）
            ($r.tail -split "`n") | Where-Object { $_ -match '\.\.\. (ok|FAIL|ERROR|skipped)|^(FAIL|ERROR):|Error:|error:|^Ran |^(OK|FAILED)' } | ForEach-Object { "  $_" } | Write-Host
        }
    }
    finally { & $Git -C $repoPath worktree remove --force $tmp *> $null }
}

function Invoke-Queue {
    New-Item -ItemType Directory -Force (Join-Path $QueueDir 'started') | Out-Null
    $cards = @(Get-ChildItem $QueueDir -File -Filter '*.md' | Sort-Object Name)
    if (-not $cards) { Say "queue\ にカードがありません: $QueueDir"; return }
    Wait-Strata
    $procs = @(); $started = @()
    foreach ($c in $cards) {
        while (@($procs | Where-Object { -not $_.HasExited }).Count -ge $Parallel) { Start-Sleep 5 }
        $moved = Join-Path $QueueDir "started\$($c.Name)"
        Move-Item -LiteralPath $c.FullName $moved -Force
        $st = Get-Date -Format 'yyyyMMdd-HHmmss'
        $id = (Read-Card $moved).Fields['タスクID']
        $log = Join-Path $Runs "queue-$id-$st.log"
        New-Item -ItemType Directory -Force $Runs | Out-Null
        $procs += Start-Process -FilePath $Pwsh -ArgumentList "-NoProfile -File `"$PSCommandPath`" run -Card `"$moved`" -Stamp $st -TimeoutMinutes $TimeoutMinutes" -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError "$log.err"
        $started += "$id-$st"
        Say "開始: $id-$st"
        Start-Sleep 2      # 時刻（実行フォルダの名前）が重ならないように
    }
    foreach ($p in $procs) { $p.WaitForExit() }
    foreach ($s in $started) {
        $done = Join-Path $Runs "$s\done.txt"
        Say "$s : $(if (Test-Path $done) { (Get-Content $done -Raw).Trim() } else { '失敗（report が無い。queue-*.log を確認）' })"
    }
}

switch ($Command) {
    'run' {
        if (-not $Card) { throw '-Card を指定してください。' }
        try { Start-Delegation $Card $Repo $Base }
        catch {
            # 裏で動かした実行（-Stamp あり）が途中で失敗したら、done.txt に理由を残す（status と wait が止まったままにならないように）
            if ($Stamp) {
                $id = try { (Read-Card $Card).Fields['タスクID'] } catch { $null }
                if ($id) { $d = Join-Path $Runs "$id-$Stamp"; New-Item -ItemType Directory -Force $d | Out-Null; Write-Utf8 (Join-Path $d 'done.txt') "error: $($_.Exception.Message)" }
            }
            throw
        }
    }
    'followup' { Start-Followup }
    'adopt' { Invoke-Adopt }
    'discard' { Invoke-Discard }
    'status' { Show-Status }
    'queue' { Invoke-Queue }
    'wait' { Wait-Run }
    'precheck' { Invoke-Precheck }
}
