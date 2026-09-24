# Public/Invoke-NessusScan.ps1
#
# Reemplaza execute\nessus_scan.ps1: dispara un scan de Tenable/Nessus en
# cada equipo de la lista.
function Invoke-NessusScan {
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
        # vivo y flag de cancelación. Los usa la GUI (Deploy-Gui.ps1); desde
        # consola o tarea programada simplemente no se pasan.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    $config = Get-DeploymentConfig
    $task = $config.Tasks.nessus
    if (-not $ThrottleLimit) { $ThrottleLimit = $task.ThrottleLimit }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath $task.LogFile }
    if (-not $LogMutexName) { $LogMutexName = $task.MutexName }

    $classPaths = @(Join-Path $PSScriptRoot '..\Classes\BaseDeploy.ps1')

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $NessusPath, $NessusScanUuid)

        $deploy = [BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)
        $deploy.NessusPath     = $NessusPath
        $deploy.NessusScanUuid = $NessusScanUuid
        try {
            $ping = $deploy.TestPingEquipo()
            if (-not $ping.Success) {
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $ping.msg }
            }

            $tenable = $deploy.UpdateTenable()
            if (-not $tenable.Success) {
                $deploy.WriteLogSafe("Tenable no actualizado: $($tenable.ErrorMessage)")
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = $tenable.ExitCode; Message = $tenable.ErrorMessage }
            }

            $deploy.WriteLogSafe("OK: $($tenable.StdOut)")
            $deploy.WriteLogSafe("Completed")
            return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = $tenable.ExitCode; Message = $tenable.StdOut }
        }
        catch {
            $msg = "ERROR JOB: $($_.Exception.Message)"
            $deploy.WriteLogSafe($msg)
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
        }
    }

    $actionArgs = [ordered]@{
        NessusPath     = $config.NessusPath
        NessusScanUuid = $config.NessusScanUUID
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag -Settings $config

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
