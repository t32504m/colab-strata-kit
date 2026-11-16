$ErrorActionPreference='Stop'
. "$PSScriptRoot\Core.ps1"
function Assert($condition,$message){if(!$condition){throw "FAIL: $message"}}
$sample="MANAGER_STATE=present`nCurrent balance: 240.82 compute units`nUsage rate: 6.73/hr`nActive assignments: 1`nNVIDIA A100-SXM4-40GB, 37916 MiB, 40960 MiB"
$s=Parse-Status $sample
Assert ($s.Runtime -eq 'present' -and $s.Balance -eq 240.82 -and $s.Rate -eq 6.73) 'usage parsing'
Assert ((Parse-Status 'authentication failed').Runtime -eq 'unknown') 'errors must not imply stopped'
Assert ((Parse-Status 'MANAGER_STATE=absent').Runtime -eq 'absent') 'explicit absence'
$now=[DateTime]::UtcNow
$lease=[pscustomobject]@{armed=$true;requestStop=$false;deadlineUtc=$now.AddMinutes(5).ToString('o');cuBudget=2.0;balanceAtStart=100.0}
Assert ((Get-StopReason $lease $true $now ([pscustomobject]@{balance=99.0})) -eq '') 'no premature stop'
Assert ((Get-StopReason $lease $false $now $null) -match '異常終了') 'owner crash'
Assert ((Get-StopReason $lease $true $now.AddMinutes(6) $null) -match '時間') 'time budget'
Assert ((Get-StopReason $lease $true $now ([pscustomobject]@{balance=97.9})) -match 'CU') 'CU budget'
Assert ((Get-StopReason $lease $true $now $null) -eq '') 'unknown CU must not invent usage'
$lease.requestStop=$true
Assert ((Get-StopReason $lease $true $now $null) -eq '停止操作') 'explicit stop'
$lease.armed=$false
Assert ((Get-StopReason $lease $false $now $null) -eq '') 'disarmed guard'
$lease.armed=$true;$lease.requestStop=$false
$lease.deadlineUtc=$now.AddHours(2).ToString('o')
$roundtrip=$lease | ConvertTo-Json | ConvertFrom-Json
Assert ((Get-StopReason $roundtrip $true $now $null) -eq '') 'ISO deadline survives JSON roundtrip without double timezone conversion'
Assert ((Get-StopReason $roundtrip $true $now.AddHours(3) $null) -match '時間') 'roundtrip deadline expires at intended time'
Assert ([Math]::Abs(((ConvertTo-Utc $roundtrip.deadlineUtc)-$now).TotalMinutes-120) -lt 0.1) 'countdown is 120 minutes in host timezone'
Assert ((Parse-Status "MANAGER_STATE=present`nSTRATA_IDLE_SECONDS=125").IdleSeconds -eq 125) 'idle seconds parsing'
Assert ($null -eq (Parse-Status 'MANAGER_STATE=present').IdleSeconds) 'missing idle seconds stays unknown'
$idle=[pscustomobject]@{armed=$true;requestStop=$false;deadlineUtc=$null;idleMinutes=30;lastActiveUtc=$now.ToString('o');cuBudget=0;balanceAtStart=$null}
Assert ((Get-StopReason $idle $true $now.AddMinutes(29) $null) -eq '') 'no idle stop before 30 minutes'
Assert ((Get-StopReason $idle $true $now.AddMinutes(30) $null) -match '30分間使われなかった') 'idle stop at 30 minutes'
$idleRt=$idle | ConvertTo-Json | ConvertFrom-Json
Assert ((Get-StopReason $idleRt $true $now.AddMinutes(29) $null) -eq '') 'idle time survives JSON roundtrip (no early stop)'
Assert ((Get-StopReason $idleRt $true $now.AddMinutes(31) $null) -match '使われなかった') 'idle time survives JSON roundtrip (stops)'
$idle.idleMinutes=0
Assert ((Get-StopReason $idle $true $now.AddDays(1) $null) -eq '') 'idle limit 0 disables idle stop'
foreach($p in Get-ChildItem $PSScriptRoot -Filter '*.ps1') {
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($p.FullName,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "PowerShell syntax: $($p.Name): $errors"
}
'PASS: status parser, stop conditions, PowerShell syntax'
. "$PSScriptRoot\Progress.ps1"
Assert ((Get-StartupProgress '[manager] checking model-00001-of-00002.gguf: 5 / 55 GB (9%)') -match '整合性検証 / ファイル 1/2 / この工程 9%') 'verification progress'
Assert ((Get-StartupProgress '[manager] model-00002-of-00002.gguf: 10 / 29 GB (34%)') -match 'ダウンロード / ファイル 2/2') 'download progress'
Assert ((Get-StartupProgress 'mtp.layers.0.mlp: q2_0 235 MB') -match '変換') 'MTP conversion'
Assert ((Get-StartupProgress '[strata] still starting (93 s)') -match '読み込み') 'loading progress'

# Write the real settings code against a disposable path, not the user's config.
$fixture=Join-Path $PSScriptRoot ('test-config-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $fixture | Out-Null
$configFile=Join-Path $fixture 'config.local.env'
[IO.File]::WriteAllText($configFile,"CONTEXT=32768`nMODEL=IQ3_S`nHIGH_MEM=0`nCUSTOM_KEEP=unchanged`n")
# Core.ps1 は置き場をパッケージのフォルダから決める。テストでは設定ファイルと state（preferences.json）を一時フォルダに向ける
$realState=$script:StateRoot
$script:CliConfig=$configFile; $script:StateRoot=$fixture
try {
    Write-LaunchSettings @{Context=262144;Model='IQ2_XS';HighMemory=$true;MTP=$false;Vision=$false;Minutes=60;Harness='Pi';AutoOpen=$true;Budget=5.0}
    $text=Get-Content $configFile -Raw
    Assert ($text -match 'CONTEXT=262144' -and $text -match 'MODEL=IQ2_XS' -and $text -match 'HIGH_MEM=1') 'launch settings applied'
    Assert ($text -match 'CUSTOM_KEEP=unchanged') 'unrelated settings preserved'
    Assert ($text -match "STRATA_EXTRA_ARGS='--mtp off --vision no'") 'fast-start options'
    Assert (Test-Path "$configFile.manager-backup") 'config backup'
    Assert (Test-Path (Join-Path $fixture 'preferences.json')) 'preferences go to the test state folder'
    # 新しい PC で config.local.env がまだ無い: 画面は既定の値で出し、保存は理由を示して断る
    Remove-Item $configFile
    Assert ((Read-LaunchSettings).Context -eq 262144) 'defaults without a config file'
    $threw=$false; try {Write-LaunchSettings @{Context=32768;Model='IQ3_S';HighMemory=$false;MTP=$true;Vision=$true}} catch {$threw=$_.Exception.Message -match 'install.ps1'}
    Assert $threw 'missing config is explained'
} finally { $script:StateRoot=$realState; Remove-Item -Recurse -Force $fixture }
'PASS: launch settings save, backup, unrelated settings preservation'

# ---- 置き場の変換（他の PC で別の場所に置いても動くように） ----
Assert ((ConvertTo-WslPath 'C:\Users\a b\kit\colab-manager\bridge.sh') -eq '/mnt/c/Users/a b/kit/colab-manager/bridge.sh') 'wsl path with spaces'
Assert ((ConvertTo-WslPath 'D:\x') -eq '/mnt/d/x') 'wsl path drive letter'
$threw=$false; try {ConvertTo-WslPath '\\server\share\x' | Out-Null} catch {$threw=$true}
Assert $threw 'network paths are refused'
Assert ($script:CliRoot -eq (Join-Path (Split-Path $PSScriptRoot -Parent) 'strata-colab-cli')) 'cli root is the sibling folder'
# ---- クライアント設定の書き換え（colab-strata の部分だけ） ----
$yaml="- id: other`n  config:`n    contextWindow: 999`n- id: llm-pi-ai`n  config:`n    providers:`n      colab-strata:`n        models:`n          - id: qwen3.8-flash-next-iq3_s`n            name: qwen3.8-flash-next-iq3_s (Colab)`n            contextWindow: 262144`n      other-provider:`n        models:`n          - contextWindow: 8192`n- id: agent-default-model`n  config:`n    model: qwen3.8-flash-next-iq3_s`n"
$y=Update-ClientConfigText $yaml 'qwen3.8-flash-next-iq2_xs' 131072 'yaml'
Assert ($y -notmatch 'iq3_s' -and $y -match 'name: qwen3\.8-flash-next-iq2_xs \(Colab\)' -and $y -match 'model: qwen3\.8-flash-next-iq2_xs') 'model names replaced'
Assert ($y -match 'contextWindow: 131072' -and $y -match 'contextWindow: 999' -and $y -match 'contextWindow: 8192') 'only the colab-strata context changes'
Assert ((Update-ClientConfigText "- id: x`n  contextWindow: 5`n" 'qwen3.8-flash-next-iq2_xs' 131072 'yaml') -eq "- id: x`n  contextWindow: 5`n") 'files without colab-strata are untouched'
$j=Update-ClientConfigText ([string][char]0xFEFF+'{"providers":{"colab-strata":{"models":[{"id":"qwen3.8-flash-next-iq3_s","name":"x","contextWindow":262144}]}}}') 'qwen3.8-flash-next-iq2_xs' 65536 'json' | ConvertFrom-Json
Assert ($j.providers.'colab-strata'.models[0].id -eq 'qwen3.8-flash-next-iq2_xs' -and $j.providers.'colab-strata'.models[0].contextWindow -eq 65536) 'pi models.json'
$threw=$false; try {Sync-ClientConfigs 'evil; rm' 262144 | Out-Null} catch {$threw=$true}
Assert $threw 'invalid model names are refused'
'PASS: paths relative to the kit, client config rewrite'
