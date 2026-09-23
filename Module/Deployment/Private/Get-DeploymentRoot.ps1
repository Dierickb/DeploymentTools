# Private/Get-DeploymentRoot.ps1
#
# Resuelve la raíz del proyecto (la carpeta que contiene config/, imports/,
# logs/, scripts/) a partir de dónde vive el propio módulo, sin ninguna
# ruta absoluta hardcodeada.
#
# ANTES: cada script tenía sembrado literalmente "C:\Intel\Deployment\..."
# en media docena de lugares (el `$init` de cada Start-Job, las rutas de
# imports/logs, el dot-source de las clases...). Mover o renombrar la
# carpeta del proyecto rompía todo. Ahora basta con mover la carpeta
# completa: todas las rutas se calculan en relación al módulo.
function Get-DeploymentRoot {
    [CmdletBinding()]
    param()

    # Este archivo vive en <root>\Module\Deployment\Private\
    # -> subir 3 niveles para llegar a <root>
    $moduleRoot = Split-Path -Parent $PSScriptRoot          # <root>\Module\Deployment
    $moduleDir  = Split-Path -Parent $moduleRoot             # <root>\Module
    $root       = Split-Path -Parent $moduleDir              # <root>

    return $root
}
