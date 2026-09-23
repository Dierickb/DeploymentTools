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
function Invoke-KbDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        [Parameter(Mandatory)]
        [string[]]$KbPatch,

        [Parameter(Mandatory)]
        [ValidatePattern('^\d{4}-\d{2}(-\d{2})?[a-z0-9]*$')]
        [string]$KbFolder,

        [int[]]$SuccessCodes,

        [string]$InstallPath,

        [int]$ElapsedTime = 600,

        [int]$ThrottleLimit,

        [string]$LogPath,

        [string]$LogMutexName = 'Global\kb_deploy',

        [switch]$ShowProgress,

        # Pass-through hacia Invoke-ThrottledDeployment: cola de progreso en
        # vivo y flag de cancelación. Los usa la GUI (Deploy-Gui.ps1); desde
        # consola o tarea programada simplemente no se pasan.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    $config = Get-DeploymentConfig
    if (-not $SuccessCodes) { $SuccessCodes = $config.DefaultSuccessCodes }
    if (-not $InstallPath) { $InstallPath = $config.UpdatesPath }
    if (-not $ThrottleLimit) { $ThrottleLimit = $config.DefaultThrottleLimit }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath 'kb_deploy.log' }

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
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
