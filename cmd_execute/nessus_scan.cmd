@echo off
pushd "%~dp0\.."

set /p COMPUTERS_FILE="Archivo de equipos (en imports\): "

Powershell.exe -ExecutionPolicy Bypass -File "%~dp0..\scripts\run_nessus_scan.ps1" -ComputersFile "%COMPUTERS_FILE%"
pause
