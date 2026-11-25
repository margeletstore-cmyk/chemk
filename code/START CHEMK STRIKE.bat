@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0serve-local.ps1"
if errorlevel 1 (
    echo.
    echo The local server stopped because of an error.
    pause
)
