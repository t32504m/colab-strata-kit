@echo off
rem Colab Manager の準備（最初に1回）。PowerShell 7 があればそれで、無ければ Windows PowerShell で install.ps1 を実行する。
where pwsh >nul 2>nul
if %errorlevel%==0 (
  pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
)
echo.
pause
