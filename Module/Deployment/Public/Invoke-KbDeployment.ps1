# Public/Invoke-KbDeployment.ps1
#
# Reemplaza execute\kb_execute.ps1.
#
# Corregido: el original tenía
#     $kbFolderDeploy = "2026-08+++´\\\\\\\\"
# un valor claramente corrupto (probablemente un pegado accidental) que
# hacía apuntar la instalación a una carpeta que no existe
# (\\...\Updates\2026-08+++´\\\\\\\\\install.cmd). Acá -KbFolder es
# obligatorio y se valida contra el patrón "YYYY-MM" antes de usarlo, en
# vez de aceptar cualquier string silenciosamente.
#
# La validación está en el cuerpo y no en un [ValidatePattern()]: un
# atributo solo acepta literales, y el patrón vive en
# Deployment.Constants.psd1 (Validation.KbFolderPattern), el mismo que usan
# las interfaces para validar el formulario.
function Invoke-KbDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        [Parameter(Mandatory)]
        [string[]]$KbPatch,

        [Parameter(Mandatory)]
        [string]$KbFolder,

        [int[]]$SuccessCodes,

        [string]$InstallPath,

        # En segundos. Sin pasar: el ElapsedTime de la tarea 'kb' en la config.
        [int]$ElapsedTime,

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
    if ($KbFolder -notmatch $config.Validation.KbFolderPattern) {
        throw "-KbFolder '$KbFolder' no tiene un formato valido. Debe ser YYYY-MM (ej. 2026-09), opcionalmente con dia y sufijo (2026-08-24h2)."
    }

    $task = $config.Tasks.kb
    if (-not $SuccessCodes) { $SuccessCodes = $config.DefaultSuccessCodes }
    if (-not $InstallPath) { $InstallPath = $config.UpdatesPath }
    if (-not $ThrottleLimit) { $ThrottleLimit = $task.ThrottleLimit }
    if (-not $PSBoundParameters.ContainsKey('ElapsedTime')) { $ElapsedTime = $task.ElapsedTime }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath $task.LogFile }
    if (-not $LogMutexName) { $LogMutexName = $task.MutexName }

    $classPaths = @(
        Join-Path $PSScriptRoot '..\Classes\BaseDeploy.ps1'
        Join-Path $PSScriptRoot '..\Classes\KbWindows.ps1'
    )

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $KbPatch, $KbFolder, $SuccessCodes, $InstallPath, $ElapsedTime, $NessusPath, $NessusScanUuid)

        $kb = [KbWindows]::new($Equipo, $LogPath, $LogMutexName)
        $kb.NessusPath     = $NessusPath
        $kb.NessusScanUuid = $NessusScanUuid
        try {
            $result = $kb.RunKbWindows($KbPatch, $KbFolder, $SuccessCodes, $InstallPath, $ElapsedTime)
            if (-not $result.Success) {
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = $result.ExitCode; Message = $result.ErrorMessage }
            }
            $kb.WriteLogSafe("OK: $($result.StdOut)")
            $kb.WriteLogSafe("Completed")
            return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = $result.ExitCode; Message = $result.StdOut }
        }
        catch {
            $msg = "ERROR JOB: $($_.Exception.Message)"
            $kb.WriteLogSafe($msg)
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
        }
    }

    $actionArgs = [ordered]@{
        KbPatch      = $KbPatch
        KbFolder     = $KbFolder
        SuccessCodes = $SuccessCodes
        InstallPath  = $InstallPath
        ElapsedTime  = $ElapsedTime
        NessusPath         = $config.NessusPath
        NessusScanUuid     = $config.NessusScanUUID
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag -Settings $config

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
