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
# Un equipo cuyo nombre matchee Simulation.FailPattern (por defecto, que
# contenga "fail") se reporta como fallido, para que el resumen y los
# colores de la consola se puedan ver con ambos casos.
function Invoke-SimulatedDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        # Demora simulada por equipo, en milisegundos. Se le suma una
        # variacion aleatoria (Simulation.JitterMs) para que el avance no se
        # vea artificialmente parejo. Sin pasar: Simulation.DelayMs.
        [int]$DelayMs,

        [int]$ThrottleLimit,

        [string]$LogPath,

        [string]$LogMutexName,

        [switch]$ShowProgress,

        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    $config = Get-DeploymentConfig
    $task = $config.Tasks.simulation
    if (-not $PSBoundParameters.ContainsKey('DelayMs')) { $DelayMs = $config.Simulation.DelayMs }
    if (-not $ThrottleLimit) { $ThrottleLimit = $task.ThrottleLimit }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath $task.LogFile }
    if (-not $LogMutexName) { $LogMutexName = $task.MutexName }

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $DelayMs, $JitterMs, $FailPattern, $DateFormat)

        Start-Sleep -Milliseconds ($DelayMs + (Get-Random -Maximum $JitterMs))

        $ok = $Equipo -notmatch $FailPattern
        $msg = if ($ok) { 'OK: simulacion completada' } else { 'ERROR: fallo simulado' }

        # Se escribe al log igual que una tarea real, para que el tail en
        # vivo de la interfaz tenga algo que mostrar.
        $linea = "$(Get-Date -Format $DateFormat) | $Equipo | $msg"
        Add-Content -Path $LogPath -Value $linea -Encoding UTF8 -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            Equipo   = $Equipo
            Success  = $ok
            ExitCode = $(if ($ok) { 0 } else { -1 })
            Message  = $(if ($ok) { 'simulacion completada' } else { 'fallo simulado' })
        }
    }

    $actionArgs = [ordered]@{
        DelayMs     = $DelayMs
        JitterMs    = $config.Simulation.JitterMs
        FailPattern = $config.Simulation.FailPattern
        DateFormat  = $config.Log.DateFormat
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths @() -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag -Settings $config

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
