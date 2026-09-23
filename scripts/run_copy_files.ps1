<#
.SYNOPSIS
    Copia archivos de forma no interactiva. Reemplaza execute\copy_files.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputersFile,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ItemName,
    [string]$RemoteSubPath = 'temp\RemoteInstall',
    [switch]$Recurse,
    [int]$ThrottleLimit
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = Read-ComputerList -Path $computersPath

$summary = Invoke-CopyFiles -ComputerList $computers -SourcePaths @($SourcePath) -ItemNames @($ItemName) `
    -RemoteSubPaths @($RemoteSubPath) -Recurse @([bool]$Recurse) -ThrottleLimit $ThrottleLimit

exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
