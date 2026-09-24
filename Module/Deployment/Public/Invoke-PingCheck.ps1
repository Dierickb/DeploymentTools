# Public/Invoke-PingCheck.ps1
#
# Verifica conectividad: hace SOLO el ping de BaseDeploy.TestPingEquipo() a
# cada equipo de la lista, sin copiar ni ejecutar nada. Sirve para saber que
# equipos estan en red antes de lanzar un despliegue.
#
# En el resumen, OK = en red y Fallidos = sin respuesta, cada uno con el
# motivo que dio el ping (TimedOut, host que no resuelve, etc.). Desde las
# interfaces, "Copiar hostnames" sobre cualquiera de las dos listas deja un
# .txt listo para imports\.
#
# Usa el mismo runner que las otras tareas (un job por equipo), asi tiene
# progreso en vivo, cancelacion y log sin codigo propio. El timeout del ping
# es PingTimeoutMs de la config, igual que el ping con el que arranca
# cualquier otra tarea.
function Invoke-PingCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        [int]$ThrottleLimit,

        [string]$LogPath,

        [string]$LogMutexName,

        [switch]$ShowProgress,

        # Pass-through hacia Invoke-ThrottledDeployment: cola de progreso en
        # vivo y flag de cancelacion. Los usan las interfaces; desde consola o
        # tarea programada simplemente no se pasan.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    $config = Get-DeploymentConfig
    $task = $config.Tasks.ping
    if (-not $ThrottleLimit) { $ThrottleLimit = $task.ThrottleLimit }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath $task.LogFile }
    if (-not $LogMutexName) { $LogMutexName = $task.MutexName }

    $classPaths = @(Join-Path $PSScriptRoot '..\Classes\BaseDeploy.ps1')

    $action = {
        param($Equipo, $LogPath, $LogMutexName)

        $deploy = [BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)
        try {
            $ping = $deploy.TestPingEquipo()
            if (-not $ping.Success) {
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $ping.msg }
            }

            $deploy.WriteLogSafe("Completed")
            return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = 0; Message = "En red: $($ping.msg)" }
        }
        catch {
            $msg = "ERROR JOB: $($_.Exception.Message)"
            $deploy.WriteLogSafe($msg)
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
        }
    }

    # Sin argumentos propios: el ping solo necesita el equipo, el log y el
    # mutex, que el runner ya pasa siempre.
    $actionArgs = [ordered]@{}

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag -Settings $config

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
