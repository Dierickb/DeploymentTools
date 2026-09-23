<#
.SYNOPSIS
    Corre un comando arbitrario de forma no interactiva. Reemplaza execute\invokePsexec.ps1
    (ahora genérico de verdad: no asume que la salida es una version ni actualiza Tenable
    salvo que se pida explícitamente).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputersFile,
    [Parameter(Mandatory)][string]$Command,
    [int]$ElapsedTimeMinutes = 0,
    [int]$ThrottleLimit,
    [switch]$CompareVersion,
    [version]$MinVersion,
    [switch]$UpdateTenableAfter
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = Read-ComputerList -Path $computersPath

$summary = Invoke-RemoteCommand -ComputerList $computers -Command $Command -RunAsSystem -Elevated `
    -ElapsedTime ($ElapsedTimeMinutes * 60) -ThrottleLimit $ThrottleLimit `
    -CompareVersion:$CompareVersion -MinVersion $MinVersion -UpdateTenableAfter:$UpdateTenableAfter

exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
