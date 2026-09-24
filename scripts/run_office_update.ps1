<#
.SYNOPSIS
    Corre la actualización de Office de forma no interactiva.
    Reemplaza execute\office_update.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputersFile,
    [Parameter(Mandatory)][version]$TargetVersion,
    [int]$ThrottleLimit,
    [switch]$UpdateTenableAfter
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = @(Read-ComputerList -Path $computersPath)

$summary = Invoke-OfficeUpdate -ComputerList $computers -TargetVersion $TargetVersion `
    -ThrottleLimit $ThrottleLimit -UpdateTenableAfter:$UpdateTenableAfter

exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
