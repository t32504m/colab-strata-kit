param([Parameter(Mandatory)][string]$LeasePath)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Core.ps1"
$job=$null; $lastRun=''; $stopped=$false; $nextAttempt=[DateTime]::MinValue
$resultPath=Join-Path $StateRoot 'guardian.json'
while($true) {
    try {
        $lease=Read-JsonSafe $LeasePath
        if(!$lease) {Start-Sleep 2; continue}
        if($lease.runId -ne $lastRun) {$lastRun=$lease.runId;$stopped=$false;$nextAttempt=[DateTime]::MinValue}
        $alive=Test-Owner $lease
        $telemetry=Read-JsonSafe (Join-Path $StateRoot 'telemetry.json')
        $reason=Get-StopReason $lease $alive ([DateTime]::UtcNow) $telemetry
        if($reason -and !$stopped) {
            if(!$job -and [DateTime]::UtcNow -ge $nextAttempt) {
                Save-JsonAtomic $resultPath @{runId=$lastRun;state='stopping';reason=$reason;at=[DateTime]::UtcNow.ToString('o')}
                $job=Start-Bridge stop ('guardian-stop-'+[DateTime]::UtcNow.Ticks)
            }
            if($job -and $job.Process.HasExited) {
                $text=Get-JobText $job
                # Only an authoritative absence confirmed by bridge.sh counts as stopped.
                if($job.Process.ExitCode -eq 0 -and $text -match '\[manager\] stopped') {
                    $stopped=$true
                    Save-JsonAtomic $resultPath @{runId=$lastRun;state='stopped';reason=$reason;detail=$text;at=[DateTime]::UtcNow.ToString('o')}
                } else {
                    Save-JsonAtomic $resultPath @{runId=$lastRun;state='retrying';reason=$reason;detail=$text;at=[DateTime]::UtcNow.ToString('o')}
                    $nextAttempt=[DateTime]::UtcNow.AddSeconds(20)
                }
                $job=$null
            }
            if($job) {
                Save-JsonAtomic $resultPath @{runId=$lastRun;state='stopping';reason=$reason;detail=(Get-JobText $job);at=[DateTime]::UtcNow.ToString('o')}
            }
        }
        if(!$alive -and ($stopped -or !$lease.armed)) {break}
    } catch {
        Add-Content (Join-Path $StateRoot 'guardian-errors.log') ("$([DateTime]::UtcNow.ToString('o')) $_")
    }
    Start-Sleep -Seconds 2
}
