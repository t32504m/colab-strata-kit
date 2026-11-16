Set-StrictMode -Version Latest
$script:AppRoot = $PSScriptRoot
$script:StateRoot = Join-Path $PSScriptRoot 'state'
New-Item -ItemType Directory -Force $script:StateRoot | Out-Null
function Save-JsonAtomic($Path, $Value) {
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($Value | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tmp, $Path, $true)
}
function Read-JsonSafe($Path) {
    try { return Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json } catch { return $null }
}
# ---- 置き場（パッケージのフォルダからの相対）と PC ごとの設定 ----
# colab-manager と strata-colab-cli は同じフォルダ（$KitRoot）の下に並べて置く。
# PC ごとの値は colab-manager\local.settings.json（git の管理外。install.ps1 が書く）:
#   { "WslDistro": "Ubuntu" }
$script:KitRoot = Split-Path $PSScriptRoot -Parent
$script:CliRoot = Join-Path $script:KitRoot 'strata-colab-cli'
$script:CliConfig = Join-Path $script:CliRoot 'config.local.env'
$script:LocalSettings = Read-JsonSafe (Join-Path $PSScriptRoot 'local.settings.json')
$script:WslDistro = 'Ubuntu'
if($script:LocalSettings -and $script:LocalSettings.PSObject.Properties['WslDistro'] -and $script:LocalSettings.WslDistro) {$script:WslDistro=[string]$script:LocalSettings.WslDistro}
function ConvertTo-WslPath([string]$Path) {
    # C:\a\b → /mnt/c/a/b（WSL の既定の自動マウント）。ネットワークのパスは WSL から同じ形では見えないので断る
    $full=[IO.Path]::GetFullPath($Path)
    if($full -notmatch '^([A-Za-z]):\\(.*)$') {throw "WSL から見えない場所です（ドライブ文字のある場所に置いてください）: $full"}
    return '/mnt/' + $Matches[1].ToLowerInvariant() + '/' + ($Matches[2] -replace '\\','/')
}
function ConvertTo-Utc($Value) {
    # ConvertFrom-Json may return a DateTime for ISO strings. Parsing it again
    # drops its Kind during implicit string conversion and applies the TZ twice.
    if($Value -is [DateTime]) {return $Value.ToUniversalTime()}
    if($Value -is [DateTimeOffset]) {return $Value.UtcDateTime}
    return [DateTimeOffset]::Parse([string]$Value,[Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}
function Start-Bridge([string]$Action, [string]$Tag) {
    if ($Action -notin @('status','start','stop','restart','reconnect')) { throw 'Invalid bridge action' }
    $out = Join-Path $script:StateRoot "$Tag.out.log"
    $err = Join-Path $script:StateRoot "$Tag.err.log"
    $bridge = ConvertTo-WslPath (Join-Path $script:AppRoot 'bridge.sh')
    if ($bridge.Contains('"') -or $script:WslDistro -notmatch '^[A-Za-z0-9._-]+$') { throw "使えない文字を含む置き場かディストリ名です: $bridge / $script:WslDistro" }
    # -e: シェルを通さずに実行する（-- だと wsl.exe が引数をシェルで解釈し直し、空白や括弧のあるパスで崩れる）。
    # Start-Process は配列の要素を引用符で囲まないので、1つの文字列にしてパスを自分で囲む。
    $argLine = "-d $script:WslDistro -e bash `"$bridge`" $Action"
    Add-Content (Join-Path $script:StateRoot 'commands.log') ("$([DateTimeOffset]::Now.ToString('o')) [Windows] wsl.exe $argLine")
    $proc = Start-Process -FilePath "$env:SystemRoot\System32\wsl.exe" -ArgumentList $argLine -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    return @{Process=$proc; Out=$out; Err=$err; Started=[DateTime]::UtcNow; Action=$Action}
}
function Get-JobText($Job) {
    $text = ''
    foreach ($p in @($Job.Out,$Job.Err)) {
        if(Test-Path -LiteralPath $p) { try { $text += [IO.File]::ReadAllText($p) + "`r`n" } catch {} }
    }
    return [regex]::Replace($text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
}
function Parse-Status([string]$Text) {
    $runtime='unknown'; $balance=$null; $rate=$null; $assignments=$null
    if($Text -match 'MANAGER_STATE=(present|absent|unknown)') {$runtime=$Matches[1]}
    if($Text -match 'Current balance:\s*([\d.]+)') {$balance=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)}
    if($Text -match 'Usage rate:\s*([\d.]+)') {$rate=[double]::Parse($Matches[1],[Globalization.CultureInfo]::InvariantCulture)}
    if($Text -match 'Active assignments:\s*(\d+)') {$assignments=[int]$Matches[1]}
    $idle=$null; if($Text -match 'STRATA_IDLE_SECONDS=(\d+)') {$idle=[int]$Matches[1]}
    $gpu = ($Text -split '\r?\n' | Where-Object {$_ -match '^NVIDIA.*MiB'} | Select-Object -First 1)
    return @{Runtime=$runtime; Balance=$balance; Rate=$rate; Assignments=$assignments; GPU=$gpu; IdleSeconds=$idle}
}
function Read-LaunchSettings {
    # 新しい PC で config.local.env がまだ無いときは、既定の値で画面を出す（起動すると Write-LaunchSettings が作る）
    $text=if(Test-Path -LiteralPath $script:CliConfig){Get-Content -LiteralPath $script:CliConfig -Raw}else{''}
    $cfg=@{Context=262144; Model='IQ3_S'; HighMemory=$false; MTP=$true; Vision=$true; IdleMinutes=30; Harness='DeepSeek Harness'; AutoOpen=$true; Budget=0.0}
    if($text -match '(?m)^CONTEXT=(\d+)') {$cfg.Context=[int]$Matches[1]}
    if($text -match '(?m)^MODEL=([A-Z0-9_]+)') {$cfg.Model=$Matches[1]}
    if($text -match '(?m)^HIGH_MEM=([01])') {$cfg.HighMemory=$Matches[1] -eq '1'}
    if($text -match '--mtp off') {$cfg.MTP=$false}
    if($text -match '--vision (no|none)') {$cfg.Vision=$false}
    $saved=Read-JsonSafe (Join-Path $script:StateRoot 'preferences.json')
    if($saved) {foreach($key in @('IdleMinutes','Harness','AutoOpen','Budget')) {if($saved.PSObject.Properties[$key]) {$cfg[$key]=$saved.$key}}}
    return $cfg
}
function Write-LaunchSettings($Cfg) {
    if($Cfg.Context -notin @(16384,32768,65536,131072,262144) -or $Cfg.Model -notin @('IQ3_S','IQ3_XXS','IQ2_XS','Q2_0')) {throw 'Unsupported selection'}
    $p=$script:CliConfig
    if(!(Test-Path -LiteralPath $p)) {throw "設定ファイルがありません: $p（install.ps1 を実行してください）"}
    $text=Get-Content -LiteralPath $p -Raw
    Copy-Item -LiteralPath $p "$p.manager-backup" -Force
    $map=[ordered]@{CONTEXT=[string]$Cfg.Context;MODEL=$Cfg.Model;HIGH_MEM=$(if($Cfg.HighMemory){'1'}else{'0'});OPEN_BROWSER='0';STRATA_EXTRA_ARGS="'--mtp $(if($Cfg.MTP){'on'}else{'off'}) --vision $(if($Cfg.Vision){'yes'}else{'no'})'"}
    foreach($key in $map.Keys) {
        if($text -match "(?m)^$key=") {$text=[regex]::Replace($text,"(?m)^$key=[^\r\n]*",[string]$map[$key].Insert(0,"$key="))}
        else {$text += "`n$key=$($map[$key])`n"}
    }
    [IO.File]::WriteAllText($p,$text.Replace("`r`n","`n"),[Text.UTF8Encoding]::new($false))
    Save-JsonAtomic (Join-Path $script:StateRoot 'preferences.json') $Cfg
}
function Test-Owner($Lease) {
    try { $p=Get-Process -Id $Lease.ownerPid -ErrorAction Stop; return $p.StartTime.ToUniversalTime().Ticks -eq [long]$Lease.ownerStartTicks } catch {return $false}
}
function Get-Field($Obj, [string]$Name) {
    if($Obj -is [Collections.IDictionary]) {return $Obj[$Name]}
    $p=$Obj.PSObject.Properties[$Name]; if($p) {return $p.Value}; return $null
}
function Get-StopReason($Lease, [bool]$OwnerAlive, [DateTime]$Now, $Telemetry) {
    if(!$Lease.armed) {return ''}
    if(!$OwnerAlive) {return '管理アプリの終了・異常終了'}
    if($Lease.requestStop) {return '停止操作'}
    if($Lease.deadlineUtc -and $Now -ge (ConvertTo-Utc $Lease.deadlineUtc)) {return '利用時間の上限'}
    # 無操作: 最後に使われた時刻（Colab側のGPU使用率で判定。起動処理中と測れない間は Manager が進めない）から idleMinutes 分。
    $idleMin=Get-Field $Lease 'idleMinutes'; $lastActive=Get-Field $Lease 'lastActiveUtc'   # 以前の lease.json には無い
    if($idleMin -gt 0 -and $lastActive -and ($Now-(ConvertTo-Utc $lastActive)).TotalMinutes -ge [double]$idleMin) {return ('{0}分間使われなかった' -f $idleMin)}
    if($Lease.cuBudget -gt 0 -and $null -ne $Lease.balanceAtStart -and $Telemetry -and $null -ne $Telemetry.balance) {
        if(([double]$Lease.balanceAtStart-[double]$Telemetry.balance) -ge [double]$Lease.cuBudget) {return 'CU減少量の上限（アカウント全体）'}
    }
    return ''
}

# ---- クライアント（dsh・Pi）の設定を、動いている Strata のモデル名と文脈の長さに合わせる ----
# 以前は sync-clients.cjs（Node と pi の yaml 部品が要る）だった。新しい PC でも動くよう、ここで正規表現で書き換える。
# 書き換えるのは colab-strata の部分だけ: モデル名 qwen3.8-flash-next-* のすべて、表示名、colab-strata の最初の contextWindow。
function Get-ClientConfigPaths {
    @(
        (Join-Path $env:USERPROFILE '.dsh\profiles\desktop\cordis.patch.yml'),   # DeepSeek Harness（デスクトップ）
        (Join-Path $script:KitRoot 'deepseek-harness\strata.patch.yml'),          # headless（この PC の以前の置き場）
        (Join-Path $script:AppRoot 'harness\strata.patch.yml'),                    # headless（パッケージの置き場）
        (Join-Path $script:KitRoot 'pi-config\models.json')                        # Pi
    ) | Where-Object { Test-Path -LiteralPath $_ }
}
function Update-ClientConfigText([string]$Text, [string]$Model, [int]$Context, [string]$Kind) {
    if($Kind -eq 'json') {
        $d=$Text.TrimStart([char]0xFEFF) | ConvertFrom-Json
        $m=$d.providers.'colab-strata'.models[0]; $m.id=$Model; $m.name="$Model (Colab)"; $m.contextWindow=$Context
        return ($d | ConvertTo-Json -Depth 32) + "`n"
    }
    $i=$Text.IndexOf('colab-strata:')
    if($i -lt 0) {return $Text}   # Colab Strata の設定が無いファイルは触らない
    # id・model・name（"<モデル名> (Colab)"）のどれも、モデル名の部分だけを置き換えればよい
    $t=[regex]::Replace($Text,'qwen3\.8-flash-next-[a-z0-9_]+',$Model)
    $i=$t.IndexOf('colab-strata:')
    $cw=[regex]::new('contextWindow:\s*\d+').Match($t,$i)
    if($cw.Success) {$t=$t.Substring(0,$cw.Index)+"contextWindow: $Context"+$t.Substring($cw.Index+$cw.Length)}
    return $t
}
function Sync-ClientConfigs([string]$Model, [int]$Context) {
    if($Model -notmatch '^qwen3\.8-flash-next-[a-z0-9_]+$' -or $Context -notin @(16384,32768,65536,131072,262144)) {throw 'Invalid live model metadata'}
    $done=@()
    foreach($p in Get-ClientConfigPaths) {
        $text=[IO.File]::ReadAllText($p)
        $new=Update-ClientConfigText $text $Model $Context $(if($p -like '*.json'){'json'}else{'yaml'})
        if($new -ne $text) {Copy-Item -LiteralPath $p "$p.manager-backup" -Force; [IO.File]::WriteAllText($p,$new,[Text.UTF8Encoding]::new($false)); $done+=$p}
    }
    return $done
}
