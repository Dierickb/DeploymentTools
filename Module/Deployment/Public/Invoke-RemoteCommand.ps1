# Public/Invoke-RemoteCommand.ps1
#
# Reemplaza execute\invokePsexec.ps1.
#
# BUG corregido (el más importante de todo el paquete, ver CHANGES.md):
# el script original se usaba como ejecutor GENÉRICO de comandos puntuales
# (decenas de comandos distintos comentados en el archivo: netsh, DNS,
# msiexec, limpiar perfiles VPN, consultar versión de Chrome...), pero el
# CUERPO del script asumía SIEMPRE que la salida del comando era un número
# de versión de Chrome, y SIEMPRE intentaba actualizar Tenable al final:
#
#     if ([version]$result.StdOut.Trim() -le [version]'152.0.7977.82') {...}
#     $resultNessusUpdate = $invokePsexec.UpdateTenable()
#
# Con cualquier otro comando (p. ej. el que estaba activo al momento de
# revisar esto, 'netsh interface set interface Wi-Fi admin=disable'), esa
# línea intenta convertir una salida vacía o no-numérica a [version] y
# revienta. Ahora el comportamiento por defecto es genérico de verdad:
# ejecuta el comando, registra el resultado, listo. El chequeo de versión
# y la actualización de Tenable quedan como opt-in explícito
# (-CompareVersion/-MinVersion, -UpdateTenableAfter) para cuando sí se
# quiera ese flujo puntual.
function Invoke-RemoteCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        [Parameter(Mandatory)]
        [string]$Command,

        [switch]$RunAsSystem,

        [switch]$Elevated,

        [int]$ElapsedTime,

        # Opcional: si se da, compara la salida del comando (StdOut, como
        # [version]) contra -MinVersion, y solo actualiza Tenable si la
        # salida es >= MinVersion. Pensado para el caso puntual de "revisar
        # si Chrome/algo quedó en tal versión o más", NO es el
        # comportamiento por defecto.
        [switch]$CompareVersion,
        [version]$MinVersion,

        [switch]$UpdateTenableAfter,

        [int]$ThrottleLimit,

        [string]$LogPath,

        [string]$LogMutexName,

        [switch]$ShowProgress,

        # Pass-through hacia Invoke-ThrottledDeployment: cola de progreso en
        # vivo y flag de cancelación. Los usa la GUI (Deploy-Gui.ps1); desde
        # consola o tarea programada simplemente no se pasan.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    if ($CompareVersion -and -not $MinVersion) {
        throw "-CompareVersion requiere también -MinVersion."
    }

    $config = Get-DeploymentConfig
    $task = $config.Tasks.remotecmd
    if (-not $ThrottleLimit) { $ThrottleLimit = $task.ThrottleLimit }
    # El default de la tarea se aplica solo si no se paso -ElapsedTime
    # explicito (0 = sin timeout).
    if (-not $PSBoundParameters.ContainsKey('ElapsedTime')) { $ElapsedTime = $task.ElapsedTime }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath $task.LogFile }
    if (-not $LogMutexName) { $LogMutexName = $task.MutexName }

    $classPaths = @(Join-Path $PSScriptRoot '..\Classes\BaseDeploy.ps1')

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $Command, $RunAsSystem, $Elevated, $ElapsedTime, $CompareVersion, $MinVersionString, $UpdateTenableAfter, $NessusPath, $NessusScanUuid)

        $deploy = [BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)
        $deploy.NessusPath     = $NessusPath
        $deploy.NessusScanUuid = $NessusScanUuid
        try {
            $ping = $deploy.TestPingEquipo()
            if (-not $ping.Success) {
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $ping.msg }
            }

            $result = $deploy.InvokePsExec($Command, [bool]$RunAsSystem, [bool]$Elevated, $ElapsedTime)
            if (-not $result.Success) {
                $deploy.WriteLogSafe("ERROR FINAL: $($result.ErrorMessage)")
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = $result.ExitCode; Message = $result.ErrorMessage }
            }

            $deploy.WriteLogSafe("ExitCode: $($result.ExitCode)")
            $deploy.WriteLogSafe("StdOut: $($result.StdOut)")

            if ($CompareVersion) {
                $minVersion = [version]$MinVersionString
                try {
                    $obtained = [version]$result.StdOut.Trim()
                }
                catch {
                    $msg = "No se pudo interpretar '$($result.StdOut)' como version: $($_.Exception.Message)"
                    $deploy.WriteLogSafe($msg)
                    return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = $result.ExitCode; Message = $msg }
                }

                if ($obtained -lt $minVersion) {
                    $msg = "Version obtenida ($obtained) es menor a la esperada ($minVersion)"
                    $deploy.WriteLogSafe($msg)
                    return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = $result.ExitCode; Message = $msg }
                }
                $deploy.WriteLogSafe("Version cumple: $obtained >= $minVersion")
            }

            if ($UpdateTenableAfter) {
                $tenable = $deploy.UpdateTenable()
                if ($tenable.Success) {
                    $deploy.WriteLogSafe("Tenable actualizado correctamente")
                }
                else {
                    $deploy.WriteLogSafe("Comando OK, Tenable no actualizado: $($tenable.ErrorMessage)")
                }
            }

            $deploy.WriteLogSafe("Completed")
            return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = $result.ExitCode; Message = $result.StdOut }
        }
        catch {
            $msg = "ERROR JOB: $($_.Exception.Message)"
            $deploy.WriteLogSafe($msg)
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
        }
    }

    $actionArgs = [ordered]@{
        Command            = $Command
        RunAsSystem        = [bool]$RunAsSystem
        Elevated           = [bool]$Elevated
        ElapsedTime        = $ElapsedTime
        CompareVersion     = [bool]$CompareVersion
        MinVersionString   = if ($MinVersion) { $MinVersion.ToString() } else { "" }
        UpdateTenableAfter = [bool]$UpdateTenableAfter
        NessusPath         = $config.NessusPath
        NessusScanUuid     = $config.NessusScanUUID
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag -Settings $config

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
