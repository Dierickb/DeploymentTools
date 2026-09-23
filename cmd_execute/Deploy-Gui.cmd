@echo off
REM Lanzador de la interfaz grafica del Deployment Toolkit.
REM -STA es obligatorio: WPF no arranca en apartment MTA.
setlocal
set "ROOT=%~dp0.."
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\Deploy-Gui.ps1"
if errorlevel 1 (
    echo.
    echo La interfaz termino con error. Revisa el mensaje de arriba.
    pause
)
endlocal
