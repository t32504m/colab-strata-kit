param([switch]$Preview,[switch]$RenderPreview,[switch]$CaptureStatus,[switch]$StartOnOpen,[switch]$NoAutoStart)
$ErrorActionPreference='Stop'
. "$PSScriptRoot\Core.ps1"
. "$PSScriptRoot\Progress.ps1"
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$mutex=[Threading.Mutex]::new($false,'Local\ColabStrataManager')
if(!$Preview -and !$mutex.WaitOne(0)) {[Windows.Forms.MessageBox]::Show('管理アプリは既に起動しています。','Colab Manager') | Out-Null;exit}
$script:closing=$false; $script:allowClose=$false; $script:operation=$null; $script:statusJob=$null
$script:lastState='unknown'; $script:balance=$null; $script:rate=$null; $script:baseline=$null
$script:nextPoll=[DateTime]::MinValue; $script:autoPending=$false; $script:ready=$false;$script:everReady=$false; $script:healthTask=$null
$script:captured=$false
$script:stopNotified=$false
$script:lastHealthError='';$script:lastHealthRecord='';$script:uiError=''
$script:statusMessage=''
# 開いたらそのまま起動する（-NoAutoStart で無効、-Preview では起動しない）。稼働中のランタイムがあれば監視だけにする。
$script:requestedStart=($StartOnOpen -or !$NoAutoStart) -and !$Preview
$script:leasePath=Join-Path $StateRoot 'lease.json'; $script:guard=$null; $script:lastHealth=$null
$cfg=Read-LaunchSettings
$script:lease=@{ownerPid=$PID;ownerStartTicks=(Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks;runId=[guid]::NewGuid().ToString();armed=$true;requestStop=$false;deadlineUtc=$null;idleMinutes=[int]$cfg.IdleMinutes;lastActiveUtc=[DateTime]::UtcNow.ToString('o');cuBudget=[double]$cfg.Budget;balanceAtStart=$null}
$form=[Windows.Forms.Form]::new(); $form.Text='Colab Manager — Strata'; $form.Size=[Drawing.Size]::new(1050,810);$form.MinimumSize=[Drawing.Size]::new(960,760);$form.StartPosition='CenterScreen'
$form.BackColor=[Drawing.ColorTranslator]::FromHtml('#111827'); $form.ForeColor=[Drawing.Color]::WhiteSmoke; $form.Font=[Drawing.Font]::new('Yu Gothic UI',10)
function LabelAt($text,$x,$y,$w,$h,$size=10) {$c=[Windows.Forms.Label]::new();$c.Text=$text;$c.SetBounds($x,$y,$w,$h);$c.Font=[Drawing.Font]::new('Yu Gothic UI',$size);$form.Controls.Add($c);return $c}
function ButtonAt($text,$x,$y,$w,$color='#334155') {$c=[Windows.Forms.Button]::new();$c.Text=$text;$c.SetBounds($x,$y,$w,38);$c.FlatStyle='Flat';$c.FlatAppearance.BorderSize=0;$c.BackColor=[Drawing.ColorTranslator]::FromHtml($color);$c.ForeColor=[Drawing.Color]::White;$form.Controls.Add($c);return $c}
function ComboAt($values,$value,$x,$y,$w) {$c=[Windows.Forms.ComboBox]::new();$c.DropDownStyle='DropDownList';$c.SetBounds($x,$y,$w,32);$c.Items.AddRange([object[]]$values);$c.SelectedItem=[string]$value;$form.Controls.Add($c);return $c}
function CheckAt($text,$value,$x,$y,$w) {$c=[Windows.Forms.CheckBox]::new();$c.Text=$text;$c.Checked=$value;$c.SetBounds($x,$y,$w,30);$form.Controls.Add($c);return $c}
function NumberAt($value,$min,$max,$x,$y,$w) {$c=[Windows.Forms.NumericUpDown]::new();$c.Minimum=$min;$c.Maximum=$max;$c.Value=[decimal]$value;$c.SetBounds($x,$y,$w,30);$form.Controls.Add($c);return $c}
$null=LabelAt 'COLAB / STRATA' 24 17 650 38 23
$null=LabelAt '開くだけではGPUは起動しません。「起動」で開始します。既存ランタイムは監視します。' 26 61 980 25 11
$statusLabel=LabelAt '状態を確認しています…' 26 101 960 33 16
$statusLabel.ForeColor=[Drawing.ColorTranslator]::FromHtml('#67e8f9')
$cuLabel=LabelAt 'CU残量 —    使用レート —    今回の減少 —' 26 145 970 28 12
$detailLabel=LabelAt 'GPU / API の実測情報を取得します' 26 179 970 25
$timeLabel=LabelAt '終了時は停止確認まで待ちます。状態不明は「停止済み」と扱いません。' 26 211 970 25
$start=ButtonAt '起動' 26 251 118 '#0369a1';$reconnect=ButtonAt '再接続' 154 251 118;$restart=ButtonAt '推論を再起動' 282 251 145
$stop=ButtonAt 'Colabを停止' 437 251 150 '#9f1239';$refresh=ButtonAt '状態を更新' 597 251 130;$folder=ButtonAt 'ログ / 手順' 737 251 135
$null=LabelAt '起動設定' 26 310 140 26 13
$null=LabelAt 'モデル' 26 348 90 25;$model=ComboAt @('IQ3_S','IQ3_XXS','IQ2_XS','Q2_0') $cfg.Model 115 344 160
$null=LabelAt 'コンテキスト' 302 348 110 25;$context=ComboAt @('16384','32768','65536','131072','262144') $cfg.Context 418 344 125
$high=CheckAt 'High-memory を要求' $cfg.HighMemory 572 344 230
$null=LabelAt 'VRAM容量は起動後に実測表示。稼働中は起動設定を変更できません。' 26 384 960 24
$mtp=CheckAt 'MTPを使う（通常はこちら）' $cfg.MTP 26 414 300
$vision=CheckAt '画像入力を使う' $cfg.Vision 340 414 200
$showCommands=CheckAt '実行コマンドを表示' $false 680 414 290
$null=LabelAt 'MTPを外すと初回の追加取得・変換を省けますが、生成速度が下がる場合があります。' 26 448 960 24
$null=LabelAt '起動後に開く' 26 489 110 25;$harness=ComboAt @('DeepSeek Harness','DeepSeek Harness + WebUI','Pi','Strata WebUI') $cfg.Harness 147 484 200
$auto=CheckAt '準備できたら自動で開く' $cfg.AutoOpen 369 484 265;$open=ButtonAt '選択した画面を開く' 672 480 200
$null=LabelAt '無操作で停止（分）' 26 532 165 25;$minutes=NumberAt $cfg.IdleMinutes 5 720 197 528 85
$null=LabelAt 'CU減少上限（0＝無効）' 314 532 205 25;$budget=NumberAt $cfg.Budget 0 1000 528 528 85;$budget.DecimalPlaces=1;$budget.Increment=0.5
$limits=ButtonAt 'この値を反映' 672 522 200
$activityLabel=LabelAt 'CLI実行ログ（表示専用・コマンド入力不可）／状態の更新を待っています' 26 568 970 24
$log=[Windows.Forms.TextBox]::new();$log.Multiline=$true;$log.ReadOnly=$true;$log.ScrollBars='Vertical';$log.BackColor=[Drawing.ColorTranslator]::FromHtml('#020617');$log.ForeColor=[Drawing.ColorTranslator]::FromHtml('#cbd5e1');$log.Font=[Drawing.Font]::new('Consolas',9);$log.SetBounds(26,609,972,120);$log.Anchor='Top,Bottom,Left,Right';$form.Controls.Add($log)
$footer=LabelAt '×で閉じるとColabも停止します。停止確認に失敗した場合は再試行します。' 26 740 970 24;$footer.Anchor='Bottom,Left,Right'
$handler=[Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false
$http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[TimeSpan]::FromSeconds(3)
function Current-Settings {return @{Context=[int]$context.SelectedItem;Model=[string]$model.SelectedItem;HighMemory=$high.Checked;MTP=$mtp.Checked;Vision=$vision.Checked;Harness=[string]$harness.SelectedItem;AutoOpen=$auto.Checked;IdleMinutes=[int]$minutes.Value;Budget=[double]$budget.Value}}
function Persist-Lease {if(!$Preview){Save-JsonAtomic $leasePath $lease}}
function Record-Event([string]$Text) {
    if(!$Preview){Add-Content (Join-Path $StateRoot 'events.log') ("$([DateTimeOffset]::Now.ToString('o')) PID=$PID $Text")}
}
function New-Limits {
    $script:lease.deadlineUtc=$null;$script:lease.idleMinutes=[int]$minutes.Value;$script:lease.lastActiveUtc=[DateTime]::UtcNow.ToString('o');$script:lease.cuBudget=[double]$budget.Value;$script:lease.balanceAtStart=$script:balance
    Persist-Lease
    if(!$Preview){Save-JsonAtomic (Join-Path $StateRoot 'preferences.json') (Current-Settings)}
}
function Ask-Stop {
    if($Preview){$script:allowClose=$true;if($script:closing){$form.Close()};return}
    if($script:lease.requestStop){return}
    Record-Event '停止要求'
    $script:lease.requestStop=$true;Persist-Lease;$statusLabel.Text='停止を要求しました。Colabの停止確認までお待ちください…'
    $log.Text="停止コマンドの実行を待っています。通常は数十秒かかります。`r`n"
    $start.Enabled=$false;$reconnect.Enabled=$false;$restart.Enabled=$false;$stop.Enabled=$false
}
function Begin-Operation($action) {
    if($Preview){$log.Text='プレビューでは操作を実行しません。';return}
    if(!$script:guard -or $script:guard.HasExited){throw '停止監視プロセスが動いていません。アプリを開き直してください。'}
    if($script:operation -and !$script:operation.Process.HasExited -and !$script:ready){throw '起動処理が実行中です。'}
    if($script:lastState -eq 'unknown'){throw 'Colabの状態を確認できるまで起動できません。状態を更新してください。'}
    if($action -eq 'start' -and $script:lastState -eq 'absent'){
        $selected=Current-Settings
        if($selected.Harness -like 'DeepSeek Harness*' -and $selected.Context -lt 32768){throw 'DeepSeek Harnessでは32K以上を選んでください。16Kは初期指示と出力枠で不足することを確認しています。'}
        Write-LaunchSettings $selected
    }
    if($action -ne 'reconnect' -or $script:lease.requestStop){
        $script:lease.runId=[guid]::NewGuid().ToString();$script:lease.requestStop=$false;$script:lease.armed=$true;New-Limits
    }
    $stopFile=Join-Path $StateRoot 'stop.request';if(Test-Path $stopFile){Remove-Item -LiteralPath $stopFile}
    $script:stopNotified=$false
    Record-Event "操作開始: $action"
    $script:operation=Start-Bridge $action ('operation-'+[DateTime]::UtcNow.Ticks)
    $script:autoPending=$auto.Checked;$script:ready=$false;$script:everReady=$false;$script:nextPoll=[DateTime]::MinValue
    $statusLabel.Text='起動処理中 — 初回のモデル準備には時間がかかります'
}
function Open-Harness {
    if($Preview){return}
    # A loaded=false API is fine: Strata loads the model again on the next request (after an idle unload or an engine restart).
    if(!$script:lastHealth -or (!$script:lastHealth.loaded -and $script:operation -and !$script:everReady)){throw 'APIの準備がまだ完了していません。'}
    if([string]$harness.SelectedItem -like 'DeepSeek Harness*' -and $script:lastHealth.max_context -lt 32768){throw 'このAPIは16Kです。DeepSeek Harnessには32K以上で起動してください。'}
    # Use live metadata, not the launch dropdown, when attaching an existing runtime.
    try {$null=Sync-ClientConfigs ([string]$script:lastHealth.model) ([int]$script:lastHealth.max_context)} catch {throw "クライアント設定の同期に失敗: $($_.Exception.Message)"}
    $startHarness=Join-Path $PSScriptRoot 'harness\Start-Harness.ps1'
    switch([string]$harness.SelectedItem) {
      'DeepSeek Harness' {
        # Electron's second-instance launch restores its existing window.
        # Background renderer processes alone do not mean a window is open.
        & $startHarness
        Record-Event 'DeepSeek Harnessへ起動・表示を要求'
      }
      'Pi' {
        $pi=Join-Path $script:KitRoot 'pi-colab.cmd'
        if(!(Test-Path -LiteralPath $pi)){throw "Pi はこの PC に入っていません: $pi"}
        Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-NoExit','-Command',"& '$pi'") -WorkingDirectory $script:KitRoot
      }
      'DeepSeek Harness + WebUI' {
        & $startHarness
        Start-Process 'http://127.0.0.1:8080'
        Record-Event 'DeepSeek HarnessとStrata WebUIの起動・表示を要求'
      }
      'Strata WebUI' {Start-Process 'http://127.0.0.1:8080';Record-Event 'Strata WebUIの表示を要求'}
    }
}
function Safe-Action([scriptblock]$Action) {try{& $Action}catch{Record-Event ("操作エラー: "+$_.Exception.Message);[Windows.Forms.MessageBox]::Show($_.Exception.Message,'操作を完了できません')|Out-Null}}
$start.Add_Click({Safe-Action {Begin-Operation 'start'}})
$reconnect.Add_Click({Safe-Action {Begin-Operation 'reconnect'}})
$restart.Add_Click({Safe-Action {Begin-Operation 'restart'}})
$stop.Add_Click({Ask-Stop})
$refresh.Add_Click({$script:nextPoll=[DateTime]::MinValue})
$open.Add_Click({Safe-Action {Open-Harness}})
$limits.Add_Click({Safe-Action {New-Limits}})
$folder.Add_Click({Start-Process explorer.exe -ArgumentList $PSScriptRoot})
$form.Add_FormClosing({param($sender,$e)
    if(!$script:allowClose -and !$Preview){Record-Event "ウィンドウ終了要求: $($e.CloseReason)";$e.Cancel=$true;$script:closing=$true;Ask-Stop}
})
if(!$Preview) {
    Persist-Lease
    Record-Event 'Manager 起動'
    $pwsh=(Get-Process -Id $PID).Path
    $script:guard=Start-Process $pwsh -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-File',"`"$PSScriptRoot\Guardian.ps1`"",'-LeasePath',"`"$leasePath`"") -WindowStyle Hidden -PassThru
} else {
    $form.Text+=' [プレビュー / 操作なし]';$statusLabel.Text='準備完了 — プレビュー';$cuLabel.Text='CU残量 240.82    使用レート 6.73 CU/時    今回の減少 0.00 CU'
    $detailLabel.Text='A100 40GB  /  Qwen3.8 Flash Next IQ3_S  /  32K';$log.Text='プレビューです。Colab・設定・監視には変更を加えません。'
}
$timer=[Windows.Forms.Timer]::new();$timer.Interval=1000
$timer.Add_Tick({
 try {
  if($Preview){return}
  $now=[DateTime]::UtcNow
  $guardResult=Read-JsonSafe (Join-Path $StateRoot 'guardian.json')
  $guardState=''
  if($guardResult -and $guardResult.runId -eq $lease.runId){$guardState=$guardResult.state}
  $stopping=$lease.requestStop -or $guardState -in @('stopping','retrying','stopped')
  # 外部からの停止指示（Claude Code など）: state/stop-now.request を置くと、停止ボタンと同じ扱いで止める。
  $stopNow=Join-Path $StateRoot 'stop-now.request'
  if(Test-Path -LiteralPath $stopNow){Remove-Item -LiteralPath $stopNow -ErrorAction SilentlyContinue;if(!$stopping){Record-Event '外部からの停止指示';Ask-Stop}}
  # 外部からの起動指示（delegate.ps1 など）: state/start-now.request。ランタイムが無く、起動処理も動いていないときだけ起動する。
  $startNow=Join-Path $StateRoot 'start-now.request'
  if((Test-Path -LiteralPath $startNow) -and $script:lastState -ne 'unknown'){
    Remove-Item -LiteralPath $startNow -ErrorAction SilentlyContinue
    $running=$script:operation -and !$script:operation.Process.HasExited
    if($script:lastState -eq 'absent' -and !$running -and $guardState -notin @('stopping','retrying')){Record-Event '外部からの起動指示';Safe-Action {Begin-Operation 'start'};$stopping=$false}
    else{Record-Event ('外部からの起動指示: 起動しない（ランタイム '+$script:lastState+$(if($running){'、起動処理中'}else{''})+'）')}
  }
  # 起動処理中（モデル準備中）は使われていなくても数えない。ただし90分を超えて準備が終わらない場合は数え始める。
  if($script:operation -and !$script:everReady -and !$stopping -and ($now-$script:operation.Started).TotalMinutes -lt 90 -and ($now-(ConvertTo-Utc $lease.lastActiveUtc)).TotalSeconds -ge 30){$lease.lastActiveUtc=$now.ToString('o');Persist-Lease}
  if($guardState -eq 'stopped') {
    $statusLabel.Text='停止完了 — Colabランタイムが存在しないことを確認済み';$script:lastState='absent';$script:ready=$false
    if($guardResult.PSObject.Properties['detail']){$log.Text=$guardResult.detail}
    $detailLabel.Text='session: strata は停止済み。再利用する場合は「起動」を押してください。'
    if(!$script:stopNotified){Record-Event 'Colab停止確認完了';$script:stopNotified=$true}
    if($script:closing){
      Save-JsonAtomic (Join-Path $StateRoot 'ui-status.json') @{at=$now.ToString('o');label=$statusLabel.Text;runtime='absent';ready=$false;closing=$true;stopConfirmed=$true}
      $timer.Stop()
      [Windows.Forms.MessageBox]::Show($form,'Colabの停止を確認しました。ランタイムは残っていません。管理アプリを終了します。','停止完了',[Windows.Forms.MessageBoxButtons]::OK,[Windows.Forms.MessageBoxIcon]::Information)|Out-Null
      $script:allowClose=$true;$form.Close();return
    }
  } elseif($guardState -in @('stopping','retrying')) {
    $statusLabel.Text=$(if($guardState -eq 'retrying'){'停止を確認できません。ネット接続を確認してください。再試行中…'}else{'Colabを停止しています…'})
    if($guardResult.PSObject.Properties['detail']){$log.Text=$guardResult.detail}
  }
  if($script:guard.HasExited -and $guardState -ne 'stopped'){
    $log.AppendText("`r`n停止監視を再起動します。`r`n")
    $script:guard=Start-Process (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-WindowStyle','Hidden','-File',"`"$PSScriptRoot\Guardian.ps1`"",'-LeasePath',"`"$leasePath`"") -WindowStyle Hidden -PassThru
  }
  if(!$statusJob -and $now -ge $script:nextPoll -and !$stopping){
    $script:statusJob=Start-Bridge status ('status-'+$now.Ticks)
    $script:nextPoll=$now.AddSeconds(60)
    if(!$script:statusMessage){Record-Event 'Colab の状態確認を開始'}
  }
  if($script:statusJob -and $script:statusJob.Process.HasExited) {
    $statusText=Get-JobText $script:statusJob
    $s=Parse-Status $statusText
    if(!$stopping){$script:lastState=$s.Runtime}
    $message=if($statusText -match 'MANAGER_AUTH_REQUIRED'){'Colab CLI の認証が必要です。キットのフォルダの install.cmd を実行してください（済んでいる手順は飛ばされます）。'}
      elseif($statusText -match 'MANAGER_STATUS_TIMEOUT'){'Colab の状態確認がタイムアウトしました。'}
      elseif($s.Runtime -eq 'unknown'){"Colab の状態を確認できませんでした。詳細ログ $($script:statusJob.Err)"}
      elseif($s.Runtime -eq 'present'){'Colab のランタイムは稼働中です。'}
      else{'Colab のランタイムは停止中です。'}
    if($script:statusMessage -ne $message){Record-Event $message;$script:statusMessage=$message}
    if($null -ne $s.Balance){$script:balance=$s.Balance;if($null -eq $script:baseline){$script:baseline=$s.Balance};if($null -eq $lease.balanceAtStart){$lease.balanceAtStart=$s.Balance;Persist-Lease}}
    if($null -ne $s.Rate){$script:rate=$s.Rate}
    if($null -ne $s.IdleSeconds -and !$stopping){
      # 測れた値を優先する（開き直したときも、Colab側で最後に使われた時刻から数える）。準備中だけは上の「数えない」を優先。
      $script:lastIdle=$s.IdleSeconds;$seen=$now.AddSeconds(-$s.IdleSeconds)
      if(!($script:operation -and !$script:everReady) -and $seen -ne (ConvertTo-Utc $lease.lastActiveUtc)){$lease.lastActiveUtc=$seen.ToString('o');Persist-Lease}
    }
    Save-JsonAtomic (Join-Path $StateRoot 'telemetry.json') @{balance=$s.Balance;rate=$s.Rate;runtime=$s.Runtime;at=$now.ToString('o')}
    if($s.GPU -and !$stopping){$detailLabel.Text=$s.GPU+'  / '+$(if($script:ready){[string]$script:lastHealth.max_context+' ctx'}else{'APIはモデル準備完了後に起動します'})}
    $script:statusJob=$null
  }
  if(!$script:healthTask -and !$stopping){$script:healthTask=$http.GetStringAsync('http://127.0.0.1:8080/health')}
  if($script:healthTask -and $script:healthTask.IsCompleted){
    $script:ready=$false
    if(!$stopping){
      try {
        $raw=$script:healthTask.GetAwaiter().GetResult()
        $script:lastHealth=$raw|ConvertFrom-Json;$script:ready=[bool]$script:lastHealth.loaded;if($script:ready){$script:everReady=$true}
        $script:lastHealthError=if($script:ready){''}else{'APIは応答しましたがモデル未ロードです。'}
        Save-JsonAtomic (Join-Path $StateRoot 'health.json') @{at=$now.ToString('o');ready=$script:ready;response=$script:lastHealth}
      } catch {
        $script:lastHealthError=$_.Exception.GetBaseException().Message
        Save-JsonAtomic (Join-Path $StateRoot 'health.json') @{at=$now.ToString('o');ready=$false;error=$script:lastHealthError}
      }
      if($script:lastHealthError -ne $script:lastHealthRecord){Record-Event ('Windows API: '+$(if($script:lastHealthError){$script:lastHealthError}else{'接続成功'}));$script:lastHealthRecord=$script:lastHealthError}
    }
    $script:healthTask=$null
  }
  if(!$stopping){
    $statusLabel.Text=if($script:ready){'準備完了 — '+$script:lastHealth.model+' / '+$script:lastHealth.max_context+' ctx'}elseif($script:lastState -eq 'absent'){'Colabは停止中'}elseif($script:lastState -eq 'present'){'Colabは稼働中 — モデル準備中、またはトンネル未接続'}else{'状態を確認できません — 停止済みとは限りません'}
    if(!$script:ready -and $script:operation -and !$script:operation.Process.HasExited){
      $phase=try{(Get-Content (Join-Path $StateRoot 'phase') -Raw -ErrorAction Stop).Trim()}catch{'checking'}
      $phaseNames=@{checking='既存ランタイムを確認中';allocating='A100を割り当て中';ssh='SSH接続を準備中';preparing='モデルを準備中';ready='Colab準備完了 — Windows側APIへの接続待ち';cancelling='起動の取り消し中'}
      $phaseText=if($phaseNames.ContainsKey($phase)){$phaseNames[$phase]}else{$phase}
      if($phase -eq 'preparing'){$phaseText=Get-StartupProgress (Get-JobText $script:operation)}
      $statusLabel.Text='起動処理中 — '+$phaseText
      $elapsed=([DateTime]::UtcNow-$script:operation.Started).TotalMinutes
      $detailLabel.Text=('開始から {0:N0}分 / 初回起動は前回約23分。速度により変動し、残り時間は未確定です。' -f $elapsed)
      if($phase -eq 'ready'){$detailLabel.Text='127.0.0.1:8080 / '+$script:lastHealthError}
    }
  }
  $b=if($null -ne $script:balance){'{0:N2}' -f $script:balance}else{'—'}
  $r=if($null -ne $script:rate){'{0:N2} CU/時' -f $script:rate}else{'—'}
  $used=if($null -ne $script:balance -and $null -ne $script:baseline){'{0:N2} CU' -f ($script:baseline-$script:balance)}else{'—'}
  $cuLabel.Text="CU残量 $b    使用レート $r    アプリ起動後の減少 $used"
  $quiet=($now-(ConvertTo-Utc $lease.lastActiveUtc)).TotalMinutes
  $remaining=[Math]::Max(0,[double]$lease.idleMinutes-$quiet)
  $why=if($script:operation -and !$script:everReady){'準備中は数えません'}else{'最後に使われてから {0:N0}分' -f $quiet}
  $timeLabel.Text='使われないまま 約{0:N0}分で停止（{1}）  /  ×で閉じると停止確認して終了  /  session: strata' -f $remaining,$why
  if($guardState -eq 'stopped'){$timeLabel.Text='停止確認済み。画面はそのまま残します。「×」で終了できます。'}
  $activityLabel.Text='CLI実行ログ（表示専用）／画面更新 '+[DateTime]::Now.ToString('HH:mm:ss')+' ／ '+$(if($stopping){'停止結果を確認'}elseif($script:ready){'API応答あり・SSH転送中'}else{'状態を監視中'})
  if($script:operation -and !$stopping){
    $t=Get-JobText $script:operation
    $detailPath=Join-Path $StateRoot 'strata-detail.log'
    if((Test-Path $detailPath) -and (Get-Item $detailPath).LastWriteTimeUtc -ge $script:operation.Started){
      $t+="`r`n--- Strata詳細ログ（全体は state/strata-detail.log に保存）---`r`n"+[IO.File]::ReadAllText($detailPath)
      if(!$script:ready -and (Get-Content (Join-Path $StateRoot 'phase') -Raw).Trim() -eq 'preparing'){
        $statusLabel.Text='起動処理中 — '+(Get-StartupProgress ([IO.File]::ReadAllText($detailPath)))
        $age=([DateTime]::UtcNow-(Get-Item $detailPath).LastWriteTimeUtc).TotalSeconds
        $activityLabel.Text=('Strata詳細ログ / 新しい出力から {0:N0}秒（変換中は出力が途切れる場合があります）' -f $age)
      }
    }
    if($t.Length -gt 40000){$t=$t.Substring($t.Length-40000)}
    if($log.Text -ne $t){$log.Text=$t;$log.SelectionStart=$log.TextLength;$log.ScrollToCaret()}
  }
  if(!$script:operation -and !$stopping -and !$showCommands.Checked){
    $message=$script:statusMessage
    if(!$message -and $script:statusJob){$message='Colab の状態を確認しています。'}
    if($log.Text -ne $message){$log.Text=$message}
  }
  $busy=$script:operation -and !$script:operation.Process.HasExited -and !$script:ready
  if($showCommands.Checked){
    $commandFile=Join-Path $StateRoot 'commands.log'
    $log.Text=if(Test-Path $commandFile){(Get-Content $commandFile -Tail 160) -join "`r`n"}else{'この版で実行したコマンドはまだありません。'}
    $activityLabel.Text='実行コマンド履歴 / function: は記載したソース内の関数呼び出しです。'
  }
  $canStart=(!$stopping -or $guardState -eq 'stopped') -and !$busy -and !$script:guard.HasExited
  $start.Enabled=$canStart -and !$script:ready -and $script:lastState -ne 'unknown'
  $reconnect.Enabled=$canStart -and !$script:ready -and $script:lastState -eq 'present'
  $restart.Enabled=$canStart -and $script:ready
  $stop.Enabled=!$stopping -and !$script:guard.HasExited
  $open.Enabled=$script:ready -and !$stopping
  foreach($c in @($model,$context,$high,$mtp,$vision)){$c.Enabled=$script:lastState -eq 'absent' -and !$busy -and (!$stopping -or $guardState -eq 'stopped')}
  if($script:autoPending -and $script:ready -and !$stopping){$script:autoPending=$false;Safe-Action {Open-Harness}}
  if($script:requestedStart -and $script:lastState -ne 'unknown' -and !$stopping){$script:requestedStart=$false;if($script:lastState -eq 'absent'){Record-Event '開いたので自動起動';Safe-Action {Begin-Operation 'start'}}else{Record-Event ('自動起動しない: ランタイムの状態 '+$script:lastState)}}
  Save-JsonAtomic (Join-Path $StateRoot 'ui-status.json') @{at=$now.ToString('o');label=$statusLabel.Text;runtime=$script:lastState;ready=$script:ready;guardianPid=$script:guard.Id;guardianAlive=(!$script:guard.HasExited);closing=$script:closing}
  if($CaptureStatus -and !$script:captured -and $null -ne $script:balance){
    $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
    $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save((Join-Path $StateRoot 'live.png'),[Drawing.Imaging.ImageFormat]::Png);$bitmap.Dispose();$script:captured=$true
  }
 } catch {$log.AppendText("`r`n[manager] $($_.Exception.Message)`r`n");if($script:uiError -ne $_.Exception.Message){$script:uiError=$_.Exception.Message;Record-Event ('UIエラー: '+$script:uiError)}}
})
$timer.Start()
if($Preview -and $RenderPreview){
    $form.Add_Shown({
        $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
        $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height))
        $bitmap.Save((Join-Path $StateRoot 'preview.png'),[Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose();$form.Close()
    })
}
try{[void]$form.ShowDialog()}finally{$timer.Stop();$http.Dispose();if(!$Preview){$mutex.ReleaseMutex()};$mutex.Dispose()}
