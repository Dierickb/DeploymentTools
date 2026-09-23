# Public/Invoke-CopyFiles.ps1
#
# Reemplaza execute\copy_files.ps1: copia uno o más archivos/carpetas a
# una ruta remota (bajo \\<equipo>\C$\...) en cada equipo de la lista.
function Invoke-CopyFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        [Parameter(Mandatory)]
        [string[]]$SourcePaths,

        [Parameter(Mandatory)]
        [string[]]$ItemNames,

        [Parameter(Mandatory)]
        [string[]]$RemoteSubPaths,

        [bool[]]$Recurse,

        [int]$ThrottleLimit,

        [string]$LogPath,

        [string]$LogMutexName = 'Global\copy_files',

        [switch]$ShowProgress,

        # Pass-through hacia Invoke-ThrottledDeployment: cola de progreso en
        # vivo y flag de cancelación. Los usa la GUI (Deploy-Gui.ps1); desde
        # consola o tarea programada simplemente no se pasan.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    if (
        $SourcePaths.Count -ne $ItemNames.Count -or
        $SourcePaths.Count -ne $RemoteSubPaths.Count
    ) {
        throw "SourcePaths, ItemNames y RemoteSubPaths deben tener la misma longitud."
    }
    if (-not $Recurse) {
        $Recurse = @($SourcePaths | ForEach-Object { $false })
    }
    elseif ($Recurse.Count -ne $SourcePaths.Count) {
        throw "Recurse debe tener la misma longitud que SourcePaths (o quedar vacío para 'ninguno recursivo')."
    }

    $config = Get-DeploymentConfig
    if (-not $ThrottleLimit) { $ThrottleLimit = $config.DefaultThrottleLimit }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath 'copy_files.log' }

    $classPaths = @(Join-Path $PSScriptRoot '..\Classes\BaseDeploy.ps1')

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $SourcePaths, $ItemNames, $RemoteSubPaths, $Recurse)

        $deploy = [BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)
        try {
            $ping = $deploy.TestPingEquipo()
            if (-not $ping.Success) {
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $ping.msg }
            }

            $results = for ($i = 0; $i -lt $SourcePaths.Count; $i++) {
                $deploy.WriteLogSafe("[$i] $($ItemNames[$i]): $($SourcePaths[$i]) --> $($RemoteSubPaths[$i])")
                $r = $deploy.CopyRemote($SourcePaths[$i], $ItemNames[$i], $RemoteSubPaths[$i], [bool]$Recurse[$i])
                [pscustomobject]@{ Item = $ItemNames[$i]; Result = $r }
            }

            $failed = @($results | Where-Object { -not $_.Result.Success })
            if ($failed.Count -gt 0) {
                $msgError = ($failed | ForEach-Object { "$($_.Item): $($_.Result.msg)" }) -join '; '
                $deploy.WriteLogSafe("ERROR FINAL: $msgError")
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msgError }
            }

            $msgOK = ($results | ForEach-Object { "$($_.Item): $($_.Result.msg)" }) -join '; '
            $deploy.WriteLogSafe("OK: $msgOK")
            return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = 0; Message = $msgOK }
        }
        catch {
            $msg = "ERROR JOB: $($_.Exception.Message)"
            $deploy.WriteLogSafe($msg)
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
        }
    }

    $actionArgs = [ordered]@{
        SourcePaths    = $SourcePaths
        ItemNames      = $ItemNames
        RemoteSubPaths = $RemoteSubPaths
        Recurse        = $Recurse
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
