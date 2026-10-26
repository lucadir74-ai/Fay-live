@echo off
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)
cd /d "%~dp0"
:menu
cls
echo.
echo   FAY LIVE - CONFIGURAZIONE DEL PORTATILE
echo   ---------------------------------------
echo.
echo   1 = questo portatile fa da PC CENTRALE
echo   2 = questo portatile e' una POSTAZIONE
echo.
set "scelta="
set /p "scelta=  Scrivi 1 oppure 2 e premi Invio: "
if "%scelta%"=="1" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione centrale
  exit /b
)
if "%scelta%"=="2" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione postazione
  exit /b
)
goto menu
