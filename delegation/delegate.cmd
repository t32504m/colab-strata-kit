@echo off
rem delegate.ps1 を PowerShell 7 で呼ぶ。例: delegate status / delegate run -Card cards\T-001.md -Async
set "PW=%USERPROFILE%\.cache\codex-runtimes\codex-primary-runtime\dependencies\native\powershell\pwsh.exe"
if not exist "%PW%" set "PW=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not exist "%PW%" set "PW=pwsh"
"%PW%" -NoProfile -File "%~dp0delegate.ps1" %*
