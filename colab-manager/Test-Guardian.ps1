# Real process-level test; the bridge alone is a local fake, never Colab.
$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot ('test-guardian-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $root | Out-Null
Copy-Item "$PSScriptRoot\Guardian.ps1" $root
$core=Get-Content "$PSScriptRoot\Core.ps1" -Raw
$core += @'

function Start-Bridge([string]$Action,[string]$Tag) {
    if($Action -ne 'stop'){throw 'Unexpected action in guardian test'}
    $out=Join-Path $StateRoot "$Tag.out.log";$err=Join-Path $StateRoot "$Tag.err.log"
    $p=Start-Process (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',"`"$PSScriptRoot\fake-stop.ps1`"") -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    return @{Process=$p;Out=$out;Err=$err}
}
'@
Set-Content (Join-Path $root 'Core.ps1') $core -Encoding utf8
@'
$p=Join-Path $PSScriptRoot 'attempts.txt'
$n=if(Test-Path $p){[int](Get-Content $p)}else{0}
$n++;Set-Content $p $n
if($n -eq 1){'Simulated network failure';exit 1}
'[manager] stopped'
'@ | Set-Content (Join-Path $root 'fake-stop.ps1') -Encoding utf8
Set-Content (Join-Path $root 'fake-owner.ps1') 'Start-Sleep -Seconds 120' -Encoding utf8
$pwsh=(Get-Process -Id $PID).Path
$owner=Start-Process $pwsh -ArgumentList @('-NoProfile','-File',"`"$root\fake-owner.ps1`"") -WindowStyle Hidden -PassThru
. "$root\Core.ps1"
$leasePath=Join-Path $root 'lease.json'
Save-JsonAtomic $leasePath @{ownerPid=$owner.Id;ownerStartTicks=$owner.StartTime.ToUniversalTime().Ticks;runId='test-run';armed=$true;requestStop=$false;deadlineUtc=[DateTime]::UtcNow.AddMinutes(3).ToString('o');cuBudget=0;balanceAtStart=$null}
$guardian=Start-Process $pwsh -ArgumentList @('-NoProfile','-File',"`"$root\Guardian.ps1`"",'-LeasePath',"`"$leasePath`"") -WindowStyle Hidden -PassThru
try {
    Start-Sleep 5
    $before=Read-JsonSafe (Join-Path $root 'state\guardian.json')
    if($before){throw "Guardian attempted stop while owner was alive and deadline in the future: $($before|ConvertTo-Json -Compress)"}
    $owner.Kill() # Only the dummy process created by this test.
    $deadline=[DateTime]::UtcNow.AddSeconds(55);$sawRetry=$false
    do {
        Start-Sleep 1
        $r=Read-JsonSafe (Join-Path $root 'state\guardian.json')
        if($r -and $r.state -eq 'retrying'){$sawRetry=$true}
        if($r -and $r.state -eq 'stopped'){break}
    } while([DateTime]::UtcNow -lt $deadline)
    if(!$r -or $r.state -ne 'stopped' -or !$sawRetry){throw "Guardian did not recover from failure: $($r|ConvertTo-Json -Compress)"}
    if($r.reason -notmatch '異常終了'){throw 'Wrong stop trigger'}
    if(!(Test-Path (Join-Path $root 'attempts.txt')) -or [int](Get-Content (Join-Path $root 'attempts.txt')) -lt 2){throw 'No retry attempt'}
    'PASS: owner crash -> failed stop -> retry -> verified stopped (fake backend only)'
} finally {
    if(!$owner.HasExited){$owner.Kill()}
    if(!$guardian.HasExited){$guardian.Kill()}
}
