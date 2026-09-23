<#
.SYNOPSIS
    Despliega una app de forma no interactiva. Reemplaza execute\deploy_app.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputersFile,
    [Parameter(Mandatory)][string]$Command,
    [Parameter(Mandatory)][string]$ItemName,
    [int]$ThrottleLimit,
    [int[]]$SuccessCodes,
    [int]$ElapsedTimeMinutes = 0,
    [switch]$UpdateTenableAfter
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = Read-ComputerList -Path $computersPath

$summary = Invoke-DeployApp -ComputerList $computers -Commands @($Command) -ItemNames @($ItemName) `
    -SuccessCodes $SuccessCodes -ElapsedTime ($ElapsedTimeMinutes * 60) -ThrottleLimit $ThrottleLimit `
    -UpdateTenableAfter:$UpdateTenableAfter

exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
