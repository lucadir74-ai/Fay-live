@echo off
rem Scrive sul desktop un file con lo stato del cavo di rete. Non cambia nessuna impostazione.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rete.ps1" -Azione diagnosi
