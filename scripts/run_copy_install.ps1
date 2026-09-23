<#
.SYNOPSIS
    Copia e instala de forma no interactiva. Reemplaza execute\copy_install.ps1.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputersFile,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ItemName,
    [string]$RemoteSubPath = 'temp',
    [Parameter(Mandatory)][string]$InstallCommand,
    [int]$ElapsedTimeMinutes = 0,
    [int]$ThrottleLimit = 1
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = Read-ComputerList -Path $computersPath

$summary = Invoke-CopyInstall -ComputerList $computers -SourcePath $SourcePath -ItemName $ItemName `
    -RemoteSubPath $RemoteSubPath -InstallCommand $InstallCommand -ElapsedTime ($ElapsedTimeMinutes * 60) `
    -ThrottleLimit $ThrottleLimit

exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
