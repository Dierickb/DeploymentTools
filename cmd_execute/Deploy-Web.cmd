@echo off
REM Interfaz web local del Deployment Toolkit (se abre en el navegador).
REM A diferencia de Deploy-Gui.cmd, esta no necesita WPF ni -STA.
setlocal
set "ROOT=%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\Deploy-Web.ps1" %*
if errorlevel 1 (
    echo.
    echo La interfaz web termino con error. Revisa el mensaje de arriba.
    pause
)
endlocal
