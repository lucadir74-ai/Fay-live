@echo off
rem Parte interna: la lancia "Fay Live.bat" dopo il controllo degli aggiornamenti. Non aprirla a mano.
cd /d "%~dp0"
set "PATH=%~dp0node;%PATH%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione scelta
if errorlevel 20 goto postazione
if errorlevel 10 goto centrale
exit /b

:centrale
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione avvio
if errorlevel 1 exit /b
start "" /min powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione apricentrale
set FAY_NO_APRI=1
call "%~dp0_motore.bat"
exit /b

:postazione
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione apri
exit /b
