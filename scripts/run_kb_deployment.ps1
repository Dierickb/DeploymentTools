<#
.SYNOPSIS
    Corre el despliegue de KB de forma no interactiva (para Scheduled Tasks).
    Reemplaza execute\kb_execute.ps1.

.EXAMPLE
    .\run_kb_deployment.ps1 -ComputersFile computers.txt -KbPatch KB5099414 -KbFolder 2026-09
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputersFile,
    [Parameter(Mandatory)][string]$KbPatch,     # uno o más, separados por coma (ej. "KB5099414,KB5087420")
    [Parameter(Mandatory)][string]$KbFolder,
    [int]$ThrottleLimit,
    [int]$ElapsedTimeMinutes = 10
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = Read-ComputerList -Path $computersPath
$kbPatchList = @($KbPatch -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })

$summary = Invoke-KbDeployment -ComputerList $computers -KbPatch $kbPatchList -KbFolder $KbFolder `
    -ElapsedTime ($ElapsedTimeMinutes * 60) -ThrottleLimit $ThrottleLimit

exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
