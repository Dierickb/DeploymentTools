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
    # Sin pasar: el timeout de la tarea 'deployapp' en la config.
    [int]$ElapsedTimeMinutes,
    [switch]$UpdateTenableAfter
)

$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

$config = Get-DeploymentConfig
$computersPath = if (Test-Path $ComputersFile) { $ComputersFile } else { Join-Path $config.ImportsPath $ComputersFile }
$computers = @(Read-ComputerList -Path $computersPath)

$params = @{
    ComputerList       = $computers
    Commands           = @($Command)
    ItemNames          = @($ItemName)
    SuccessCodes       = $SuccessCodes
    ThrottleLimit      = $ThrottleLimit
    UpdateTenableAfter = $UpdateTenableAfter
}
if ($PSBoundParameters.ContainsKey('ElapsedTimeMinutes')) { $params.ElapsedTime = $ElapsedTimeMinutes * 60 }

$summary = Invoke-DeployApp @params

exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
