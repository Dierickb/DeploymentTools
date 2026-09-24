<#
.SYNOPSIS
    Dispara el scan de Nessus/Tenable de forma no interactiva.
    Reemplaza execute\nessus_scan.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputersFile,
    [int]$ThrottleLimit
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = @(Read-ComputerList -Path $computersPath)

$summary = Invoke-NessusScan -ComputerList $computers -ThrottleLimit $ThrottleLimit
exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
