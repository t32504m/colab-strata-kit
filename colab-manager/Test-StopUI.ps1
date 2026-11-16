$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot ('test-guardian-ui-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $root | Out-Null
Copy-Item "$PSScriptRoot\Guardian.ps1" $root
Copy-Item "$PSScriptRoot\Progress.ps1" $root
$core=Get-Content "$PSScriptRoot\Core.ps1" -Raw
$core+=@'

function Start-Bridge([string]$Action,[string]$Tag) {
    if($Action -notin @('status','stop')){throw 'Test refuses runtime start'}
    $out=Join-Path $StateRoot "$Tag.out.log";$err=Join-Path $StateRoot "$Tag.err.log"
    $p=Start-Process (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',"`"$PSScriptRoot\fake.ps1`"",$Action) -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError $err -PassThru
    return @{Process=$p;Out=$out;Err=$err}
}
'@
Set-Content "$root\Core.ps1" $core -Encoding utf8
@'
param($action)
if($action -eq 'status'){'MANAGER_STATE=absent';'Usage rate: 0.00';exit}
'CLI_STOP_PROGRESS'
Start-Sleep 8
'[manager] stopped'
'@ | Set-Content "$root\fake.ps1" -Encoding utf8
$src=Get-Content "$PSScriptRoot\Manager.ps1" -Raw
$src=$src.Replace('Local\ColabStrataManager','Local\ColabStrataManagerUITest')
# Replace only the completion dialog in the fixture; record that it was reached.
$src=[regex]::Replace($src,'(?m)^\s*\[Windows.Forms.MessageBox\]::Show\(\$form,.*\|Out-Null$',"      Record-Event 'TEST: completion dialog reached'")
$inject=@'
$script:testStarted=[DateTime]::UtcNow
$script:testClicked=$false;$script:sawProgress=$false;$script:checkedStopped=$false
$testTimer=[Windows.Forms.Timer]::new();$testTimer.Interval=200
$testTimer.Add_Tick({
 try {
  if(([DateTime]::UtcNow-$script:testStarted).TotalSeconds -gt 35){throw 'UI test timed out'}
  if(!$script:testClicked -and ([DateTime]::UtcNow-$script:testStarted).TotalSeconds -gt 2){
    $script:testClicked=$true;$stop.PerformClick();Ask-Stop
    if($stop.Enabled){throw 'Stop button stayed enabled'}
  }
  if($log.Text -match 'CLI_STOP_PROGRESS'){$script:sawProgress=$true}
  if($script:stopNotified -and !$script:checkedStopped){
    if(!$form.Visible -or $script:closing){throw 'Stop button closed the window'}
    if(!$script:sawProgress -or $log.Text -notmatch '\[manager\] stopped'){throw 'Stop logs missing'}
    if($script:lastState -ne 'absent' -or $script:ready){throw 'Final state incorrect'}
    $script:checkedStopped=$true;$form.Close()
  }
 } catch {Set-Content (Join-Path $StateRoot 'test-error.txt') $_;$testTimer.Stop();$script:allowClose=$true;$form.Close()}
})
$testTimer.Start()
'@
$src=$src.Replace('$timer.Start()',('$timer.Start()'+"`n"+$inject))
Set-Content "$root\Manager.ps1" $src -Encoding utf8
$pwsh=(Get-Process -Id $PID).Path
$p=Start-Process $pwsh -ArgumentList @('-NoProfile','-File',"`"$root\Manager.ps1`"",'-NoAutoStart') -WindowStyle Hidden -PassThru
if(!$p.WaitForExit(45000)){$p.Kill();throw 'UI did not exit'}
if(Test-Path "$root\state\test-error.txt"){throw (Get-Content "$root\state\test-error.txt" -Raw)}
$state=Get-Content "$root\state\ui-status.json" -Raw|ConvertFrom-Json
$events=Get-Content "$root\state\events.log" -Raw
if(!$state.stopConfirmed -or $state.runtime -ne 'absent' -or $events -notmatch 'completion dialog reached'){throw 'Final confirmation not recorded'}
if(([regex]::Matches($events,'停止要求')).Count -ne 1){throw 'Repeated stop was not idempotent'}
'PASS: live stop logs, repeated stop, window stays open, close confirmation, final stopped snapshot (fake backend)'
