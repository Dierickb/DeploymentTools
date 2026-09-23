# Public/Invoke-SimulatedDeployment.ps1
#
# Octava "tarea", pero que no toca ningun equipo: corre el MISMO runner
# (Invoke-ThrottledDeployment) con un scriptblock de prueba que inventa
# resultados. Sirve para:
#
#   - Recorrer una interfaz completa en una maquina que no es Windows,
#     donde psexec.exe no existe (ver Deploy-Web.ps1 -Simular).
#   - Mostrar el toolkit sin riesgo de disparar nada real.
#   - Ejercitar de punta a punta el camino de verdad: cola de progreso en
#     vivo, cancelacion, escritura al log y resumen final.
#
# Por que vive aca y no dentro del script de la interfaz: porque lo que
# necesita es Invoke-ThrottledDeployment y Write-DeploymentSummary, que son
# Private\. La regla del modulo es que nada de afuera llama a Private\, asi
# que el que tiene que estar del lado de adentro es esto. De paso, queda
# disponible para las dos interfaces y para pruebas.
#
# Un equipo cuyo nombre contenga "fail" se reporta como fallido, para que
# el resumen y los colores de la consola se puedan ver con ambos casos.
function Invoke-SimulatedDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        # Demora simulada por equipo, en milisegundos. Se le suma una
        # variacion aleatoria para que el avance no se vea artificialmente
        # parejo.
        [int]$DelayMs = 300,

        [int]$ThrottleLimit,

        [string]$LogPath,

        [string]$LogMutexName = 'Global\simulated_deploy',

        [switch]$ShowProgress,

        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    $config = Get-DeploymentConfig
    if (-not $ThrottleLimit) { $ThrottleLimit = $config.DefaultThrottleLimit }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath 'simulacion.log' }

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $DelayMs)

        Start-Sleep -Milliseconds ($DelayMs + (Get-Random -Maximum 700))

        $ok = $Equipo -notmatch '(?i)fail'
        $msg = if ($ok) { 'OK: simulacion completada' } else { 'ERROR: fallo simulado' }

        # Se escribe al log igual que una tarea real, para que el tail en
        # vivo de la interfaz tenga algo que mostrar.
        $linea = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $Equipo | $msg"
        Add-Content -Path $LogPath -Value $linea -Encoding UTF8 -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            Equipo   = $Equipo
            Success  = $ok
            ExitCode = $(if ($ok) { 0 } else { -1 })
            Message  = $(if ($ok) { 'simulacion completada' } else { 'fallo simulado' })
        }
    }

    $actionArgs = [ordered]@{
        DelayMs = $DelayMs
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths @() -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
