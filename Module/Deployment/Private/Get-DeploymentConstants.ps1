# Private/Get-DeploymentConstants.ps1
#
# Lee Deployment.Constants.psd1 tal cual, sin mezclar con config\config.psd1.
# Es la unica funcion que conoce el nombre de ese archivo.
#
# Desde afuera del modulo se usa Get-DeploymentConfig, que devuelve estas
# constantes YA combinadas con lo ajustable de config.psd1. Esta funcion es
# para lo interno que solo necesita un valor fijo (por ejemplo el formato de
# fecha del log en Write-DeploymentSummary) y no tiene por que releer
# config.psd1 ni repetir sus avisos.
function Get-DeploymentConstants {
    [CmdletBinding()]
    param()

    $moduleRoot = Split-Path -Parent $PSScriptRoot
    return Import-PowerShellDataFile -Path (Join-Path $moduleRoot 'Deployment.Constants.psd1')
}
