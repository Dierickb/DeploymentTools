@echo off
pushd "%~dp0\.."

set /p COMPUTERS_FILE="Archivo de equipos (en imports\): "
set /p TARGET_VERSION="Version minima esperada de Office (ej. 16.0.19929.20220): "

Powershell.exe -ExecutionPolicy Bypass -File "%~dp0..\scripts\run_office_update.ps1" -ComputersFile "%COMPUTERS_FILE%" -TargetVersion "%TARGET_VERSION%"
pause
