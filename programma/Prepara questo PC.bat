@echo off
rem Prepara questo portatile per Fay Live: si fa UNA volta, Windows chiede il permesso (Si').
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0rete.ps1\" -Azione prepara'"
