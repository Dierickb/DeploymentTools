# Public/Invoke-DeployApp.ps1
#
# Reemplaza execute\deploy_app.ps1.
#
# Corregido: el original tenía un bloque completo (comparar con Tenable al
# final) escrito como un string sin usar de comentario improvisado — nunca
# se ejecutaba, y no había forma de saber si era código muerto a propósito
# o un olvido. Acá "actualizar Tenable después del deploy" es un switch
# explícito (-UpdateTenableAfter), no código fantasma.
function Invoke-DeployApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        # Uno o más comandos a ejecutar (típicamente "<ruta>\Deploy-Application.exe").
        # Debe tener la misma cantidad de elementos que -ItemNames.
        [Parameter(Mandatory)]
        [string[]]$Commands,

        [Parameter(Mandatory)]
        [string[]]$ItemNames,

        [int[]]$SuccessCodes,

        [int]$ElapsedTime,

        [int]$ThrottleLimit,

        [switch]$UpdateTenableAfter,

        [string]$LogPath,

        [string]$LogMutexName = 'Global\deploy_app',

        [switch]$ShowProgress,

        # Pass-through hacia Invoke-ThrottledDeployment: cola de progreso en
        # vivo y flag de cancelación. Los usa la GUI (Deploy-Gui.ps1); desde
        # consola o tarea programada simplemente no se pasan.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    if ($Commands.Count -ne $ItemNames.Count) {
        throw "Commands ($($Commands.Count)) y ItemNames ($($ItemNames.Count)) deben tener la misma longitud."
    }

    $config = Get-DeploymentConfig
    if (-not $SuccessCodes) { $SuccessCodes = $config.DefaultSuccessCodes }
    if (-not $ThrottleLimit) { $ThrottleLimit = $config.DefaultThrottleLimit }
    # DefaultElapsedTime de config.psd1 se aplica solo si no se paso
    # -ElapsedTime explicito (0 = sin timeout).
    if (-not $PSBoundParameters.ContainsKey('ElapsedTime')) { $ElapsedTime = $config.DefaultElapsedTime }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath 'deploy_app.log' }

    $classPaths = @(
        Join-Path $PSScriptRoot '..\Classes\BaseDeploy.ps1'
    )

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $Commands, $ItemNames, $SuccessCodes, $ElapsedTime, $UpdateTenableAfter, $NessusPath, $NessusScanUuid)

        $deploy = [BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)
        $deploy.NessusPath     = $NessusPath
        $deploy.NessusScanUuid = $NessusScanUuid
        try {
            $ping = $deploy.TestPingEquipo()
            if (-not $ping.Success) {
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $ping.msg }
            }

            $results = for ($i = 0; $i -lt $Commands.Count; $i++) {
                $deploy.WriteLogSafe("[$i] Instalando --> $($ItemNames[$i])")
                $r = $deploy.DeployApp($Commands[$i], $SuccessCodes, $ElapsedTime)
                [pscustomobject]@{ Item = $ItemNames[$i]; Result = $r }
            }

            $failed = @($results | Where-Object { -not $_.Result.Success })
            if ($failed.Count -gt 0) {
                $msgError = ($failed | ForEach-Object { "$($_.Item): $($_.Result.ErrorMessage)" }) -join '; '
                $deploy.WriteLogSafe("ERROR FINAL: $msgError")
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msgError }
            }

            $msgOK = ($results | ForEach-Object { "$($_.Item): $($_.Result.msg)" }) -join '; '
            $deploy.WriteLogSafe("OK: $msgOK")

            if ($UpdateTenableAfter) {
                $tenable = $deploy.UpdateTenable()
                if ($tenable.Success) {
                    $deploy.WriteLogSafe("Tenable actualizado correctamente")
                }
                else {
                    $deploy.WriteLogSafe("Deploy OK, Tenable no actualizado: $($tenable.ErrorMessage)")
                }
            }

            $deploy.WriteLogSafe("Completed")
            return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = 0; Message = $msgOK }
        }
        catch {
            $msg = "ERROR JOB: $($_.Exception.Message)"
            $deploy.WriteLogSafe($msg)
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
        }
    }

    $actionArgs = [ordered]@{
        Commands           = $Commands
        ItemNames          = $ItemNames
        SuccessCodes       = $SuccessCodes
        ElapsedTime        = $ElapsedTime
        UpdateTenableAfter = [bool]$UpdateTenableAfter
        NessusPath         = $config.NessusPath
        NessusScanUuid     = $config.NessusScanUUID
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
