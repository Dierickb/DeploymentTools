@echo off
pushd "%~dp0\.."
Powershell.exe -NoExit -ExecutionPolicy Bypass -File "%~dp0..\Deploy-Menu.ps1"
