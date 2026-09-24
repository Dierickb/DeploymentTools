<#
.SYNOPSIS
    Verifica conectividad (solo ping) de forma no interactiva.

    Sale con exit 0 si todos los equipos responden y con exit 1 si alguno
    no responde, asi una tarea programada puede alertar. La lista de los que
    no respondieron, con el motivo, queda en el resumen y en el log de la
    tarea 'ping'.

.EXAMPLE
    .\run_ping_check.ps1 -ComputersFile computers.txt
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

$summary = Invoke-PingCheck -ComputerList $computers -ThrottleLimit $ThrottleLimit
exit ($(if ($summary.Failed -gt 0) { 1 } else { 0 }))
