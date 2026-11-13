@echo off
rem Motore interno: avvia solo il server. Non aprirlo a mano, usa "Fay Live.bat".
title Fay Live - PC centrale
cd /d "%~dp0"
node\node.exe --disable-warning=ExperimentalWarning server.mjs
echo.
echo Il PC centrale si e' fermato.
if exist "%~dp0riserva\versione.json" echo Se si e' fermato da solo dopo un aggiornamento: doppio clic su "Torna alla versione di prima.bat".
echo Premi un tasto per chiudere.
pause >nul