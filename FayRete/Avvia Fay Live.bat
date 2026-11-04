@echo off
cd /d "%~dp0"
set "PATH=%~dp0node;%PATH%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione avvio
if errorlevel 1 exit /b
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione apricentrale
set FAY_NO_APRI=1
call "%~dp0_motore.bat"
