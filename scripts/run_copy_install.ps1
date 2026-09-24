<#
.SYNOPSIS
    Copia e instala de forma no interactiva. Reemplaza execute\copy_install.ps1.

    RemoteSubPath, ElapsedTimeMinutes y ThrottleLimit son opcionales: sin
    pasarlos, se usan los de la tarea 'copyinstall' en la config
    (Deployment.Constants.psd1, ajustables en config\config.psd1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputersFile,
    [Parameter(Mandatory)][string]$SourcePath,
    [Parameter(Mandatory)][string]$ItemName,
    [string]$RemoteSubPath,
    [Parameter(Mandatory)][string]$InstallCommand,
    [int]$ElapsedTimeMinutes,
    [int]$ThrottleLimit
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = @(Read-ComputerList -Path $computersPath)

$params = @{
    ComputerList   = $computers
    SourcePath     = $SourcePath
    ItemName       = $ItemName
    InstallCommand = $InstallCommand
    ThrottleLimit  = $ThrottleLimit
}
if ($RemoteSubPath) { $params.RemoteSubPath = $RemoteSubPath }
if ($PSBoundParameters.ContainsKey('ElapsedTimeMinutes')) { $params.ElapsedTime = $ElapsedTimeMinutes * 60 }

$summary = Invoke-CopyInstall @params

exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
