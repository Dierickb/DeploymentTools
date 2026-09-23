# Public/Invoke-CopyInstall.ps1
#
# Reemplaza execute\copy_install.ps1: copia un instalador y luego lo
# ejecuta remotamente.
#
# Corregido (ver CHANGES.md):
#  - El original, tras copiar, llamaba a "$copyRemote.WriteLogSafe(...)"
#    -- una variable que NO existía en ese script (se llamaba
#    $copyInstallRemote); eso rompía con un error de referencia nula en
#    cada corrida, silenciosamente atrapado por el catch genérico.
#  - El chequeo de ping era "if (-not $resultPingRemote)", que evalúa el
#    objeto devuelto (siempre "truthy", incluso cuando el ping falla) en
#    vez de "$resultPingRemote.Success" — el ping fallido nunca se
#    detectaba y el script seguía igual.
function Invoke-CopyInstall {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        [Parameter(Mandatory)]
        [string]$SourcePath,

        [Parameter(Mandatory)]
        [string]$ItemName,

        [string]$RemoteSubPath = 'temp',

        [Parameter(Mandatory)]
        [string]$InstallCommand,

        [int]$ElapsedTime,

        [int]$ThrottleLimit,

        [string]$LogPath,

        [string]$LogMutexName = 'Global\copy_install',

        [switch]$ShowProgress,

        # Pass-through hacia Invoke-ThrottledDeployment: cola de progreso en
        # vivo y flag de cancelación. Los usa la GUI (Deploy-Gui.ps1); desde
        # consola o tarea programada simplemente no se pasan.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    $config = Get-DeploymentConfig
    if (-not $ThrottleLimit) { $ThrottleLimit = 1 }  # copiar+instalar suele ser pesado; 1 por defecto, como el original
    # DefaultElapsedTime de config.psd1 se aplica solo si no se paso
    # -ElapsedTime explicito (0 = sin timeout).
    if (-not $PSBoundParameters.ContainsKey('ElapsedTime')) { $ElapsedTime = $config.DefaultElapsedTime }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath 'copy_install.log' }

    $classPaths = @(Join-Path $PSScriptRoot '..\Classes\BaseDeploy.ps1')

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $SourcePath, $ItemName, $RemoteSubPath, $InstallCommand, $ElapsedTime)

        $deploy = [BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)
        try {
            $ping = $deploy.TestPingEquipo()
            if (-not $ping.Success) {
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $ping.msg }
            }

            $deploy.WriteLogSafe("Copiando --> $ItemName")
            $copyResult = $deploy.CopyRemote($SourcePath, $ItemName, $RemoteSubPath, $false)
            if (-not $copyResult.Success) {
                $deploy.WriteLogSafe("ERROR FINAL: $($copyResult.msg)")
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $copyResult.msg }
            }
            $deploy.WriteLogSafe("OK: $($copyResult.msg)")

            $installResult = $deploy.InvokePsExec($InstallCommand, $true, $true, $ElapsedTime)
            if (-not $installResult.Success) {
                $deploy.WriteLogSafe("ERROR FINAL: $($installResult.ErrorMessage)")
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = $installResult.ExitCode; Message = $installResult.ErrorMessage }
            }

            $deploy.WriteLogSafe("Invoke Psexec: $($installResult.ExitCode)")
            $deploy.WriteLogSafe("Invoke Stdout: $($installResult.StdOut)")
            $deploy.WriteLogSafe("Completed")
            return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = $installResult.ExitCode; Message = $installResult.StdOut }
        }
        catch {
            $msg = "ERROR JOB: $($_.Exception.Message)"
            $deploy.WriteLogSafe($msg)
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
        }
    }

    $actionArgs = [ordered]@{
        SourcePath     = $SourcePath
        ItemName       = $ItemName
        RemoteSubPath  = $RemoteSubPath
        InstallCommand = $InstallCommand
        ElapsedTime    = $ElapsedTime
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
