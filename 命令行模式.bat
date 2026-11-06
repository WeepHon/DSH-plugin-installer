@echo off
setlocal
cd /d "%~dp0"

if /i "%~1"=="list" goto run

echo ============================================================
echo  DSH Plugin Installer - Command Line Mode
echo ============================================================
echo  show plugins    : call this file with  list
echo  check status    : ... status -PluginPath "C:\path\to\plugin"
echo  install         : ... install -PluginPath "C:\path\to\plugin" -Profiles desktop
echo  install both    : ... install -PluginPath "C:\path\to\plugin" -Profiles desktop,web
echo  switch on plugin: add  -EnableConfig
echo  manual mode     : add  -ManualMode
echo  uninstall       : ... uninstall -PluginName dsh-unrestricted -Profiles desktop
echo ------------------------------------------------------------

:run
where powershell.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] Windows PowerShell not found.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0cli-mode.ps1" %*
echo.
pause
