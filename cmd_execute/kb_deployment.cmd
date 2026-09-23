@echo off
pushd "%~dp0\.."

set /p COMPUTERS_FILE="Archivo de equipos (en imports\, ej. computers.txt): "
set /p KB_PATCH="Numero(s) de KB esperados, separados por coma (ej. KB5099414): "
set /p KB_FOLDER="Carpeta de instalacion (formato YYYY-MM, ej. 2026-09): "

Powershell.exe -ExecutionPolicy Bypass -File "%~dp0..\scripts\run_kb_deployment.ps1" -ComputersFile "%COMPUTERS_FILE%" -KbPatch "%KB_PATCH%" -KbFolder "%KB_FOLDER%"
pause
