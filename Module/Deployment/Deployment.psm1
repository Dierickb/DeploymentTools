#Requires -Version 5.1
# Deployment.psm1
#
# Modulo unico que reemplaza los 7 scripts de execute\ + Bases\.
#
# La regla de la carpeta es simple y no tiene excepciones:
#
#   Public\   Todo lo que se llama desde AFUERA del modulo (Deploy-Gui.ps1,
#             Deploy-Menu.ps1, scripts\run_*.ps1). Se exporta completo.
#   Private\  Interno del modulo. NO se exporta, y nada de afuera lo llama.
#
# Antes Get-DeploymentConfig y Read-ComputerList vivian en Private\ pero los
# tres puntos de entrada las llamaban igual, porque las necesitan antes de
# poder invocar una tarea: primero resuelven la config, despues leen la lista
# de equipos, recien ahi llaman a Invoke-*. Al no estar exportadas, esas
# llamadas fallaban con "The term 'Get-DeploymentConfig' is not recognized".
# La solucion no fue exportar cosas de Private\ (eso rompia la regla), sino
# reconocer que esas dos SON API publica y moverlas a Public\, donde estaban
# describiendo mal su rol. Ahora "Private = nadie de afuera lo toca" vuelve a
# ser cierto, y hay una prueba que lo verifica parseando los puntos de
# entrada.
#
# Las clases (BaseDeploy, KbWindows) NO se cargan aca: se dot-sourcean
# frescas dentro de cada Start-Job (ver Invoke-ThrottledDeployment), que es
# el unico lugar donde realmente se instancian. Esto evita las limitaciones
# de PowerShell para exportar clases desde un modulo.

$privateFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue
$publicFiles  = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue

foreach ($file in @($privateFiles) + @($publicFiles)) {
    try {
        . $file.FullName
    }
    catch {
        throw "Error cargando $($file.FullName): $($_.Exception.Message)"
    }
}

Export-ModuleMember -Function $publicFiles.BaseName
