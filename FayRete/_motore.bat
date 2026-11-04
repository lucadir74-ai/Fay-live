@echo off
rem Motore interno: avvia solo il server. Non aprirlo a mano, usa "Avvia Fay Live.bat".
title Fay Live - PC centrale
cd /d "%~dp0"
node\node.exe --disable-warning=ExperimentalWarning server.mjs
echo.
echo Il PC centrale si e' fermato. Premi un tasto per chiudere.
pause >nul
