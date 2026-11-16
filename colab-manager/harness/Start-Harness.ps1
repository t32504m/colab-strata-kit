# DeepSeek Harness（デスクトップ版）を開く。既に開いていれば、その窓が前に出る。
# Strata はキーなしで動かしている（SSH の転送で手元だけに出ている）。dsh は apiKeyEnv の変数があることだけを求めるので、仮の値を入れる。
$env:STRATA_API_KEY = 'local-ssh'
$exe = Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\DeepSeek Harness.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "DeepSeek Harness が入っていません: $exe" }
Start-Process -FilePath $exe
