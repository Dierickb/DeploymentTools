# Public/Invoke-OfficeUpdate.ps1
#
# Reemplaza execute\office_update.ps1.
#
# Corregido (ver CHANGES.md):
#  - "if (-not $resultPingRemote)" evaluaba el objeto (siempre truthy)
#    en vez de "$resultPingRemote.Success"; un ping fallido nunca se
#    detectaba.
#  - InvokePsExec se llamaba con 3 argumentos en dos lugares, pero el
#    metodo (en su momento) solo tenia UNA firma de 4 argumentos
#    obligatorios - las clases de PowerShell no soportan valores por
#    defecto en los parametros de un metodo, asi que esa llamada no podia
#    resolverse. Ahora hay un overload de 3 argumentos en BaseDeploy (sin
#    timeout) Y ademas aca se pasa siempre el elapsedTime explicito.
#
# TRES MODOS DE USO (antes habia uno solo y era obligatorio):
#
#  1. Por version minima (lo de siempre):
#       -TargetVersion 16.0.19929.20220
#     Consulta la version instalada en cada equipo y actualiza SOLO los que
#     estan por debajo. Los que ya cumplen se saltean sin tocar nada.
#
#  2. Forzado, sin comparar:
#       -ForceUpdate
#     Dispara la actualizacion en todos los equipos de la lista, sin
#     consultar que version tienen. Util cuando ya sabes que hay que
#     actualizar y no queres que una lectura de registro fallida te deje
#     equipos sin tocar. De paso ahorra una llamada a psexec por equipo.
#
#  3. A una version exacta:
#       -UpdateToVersion 16.0.19029.20244
#     Agrega updatetoversion= al comando de OfficeC2RClient, que es la
#     forma de fijar (o volver a) una version puntual en vez de ir a la
#     ultima del canal. Se combina con cualquiera de los dos modos de
#     arriba.
#
# -TargetVersion y -ForceUpdate son excluyentes en intencion pero no en
# sintaxis: si se pasan los dos, gana -ForceUpdate (se actualiza igual).
# Lo que NO se acepta es no pasar ninguno de los dos, porque entonces no
# habria criterio para decidir que hacer.
function Invoke-OfficeUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        # Version minima esperada. Los equipos que ya esten en esta version
        # o superior NO se tocan. Opcional: si se usa -ForceUpdate, no hace
        # falta (y se ignora).
        [version]$TargetVersion,

        # Actualiza sin consultar ni comparar la version instalada.
        [switch]$ForceUpdate,

        # Opcional: version exacta a la que llevar Office (updatetoversion
        # de OfficeC2RClient). Vacio = la ultima disponible del canal.
        [version]$UpdateToVersion,

        [bool]$ForceAppShutdown = $true,

        # Sin pasar: OfficeC2RClientPath de la config (ajustable en config.psd1).
        [string]$OfficePath,

        [int]$ElapsedTime,

        [switch]$UpdateTenableAfter,

        [int]$ThrottleLimit,

        [string]$LogPath,

        [string]$LogMutexName,

        [switch]$ShowProgress,

        # Pass-through hacia Invoke-ThrottledDeployment: cola de progreso en
        # vivo y flag de cancelacion. Los usa la GUI (Deploy-Gui.ps1); desde
        # consola o tarea programada simplemente no se pasan.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        [hashtable]$CancelFlag
    )

    # Primero de todo, antes de tocar config o levantar un solo job: sin
    # criterio no se ejecuta nada.
    if (-not $ForceUpdate -and -not $TargetVersion) {
        throw "Falta decidir el criterio: usa -TargetVersion <version> para actualizar solo los equipos por debajo de esa version, o -ForceUpdate para actualizar todos sin comparar."
    }

    $config = Get-DeploymentConfig
    $task = $config.Tasks.office
    if (-not $ThrottleLimit) { $ThrottleLimit = $task.ThrottleLimit }
    # El default de la tarea se aplica solo si no se paso -ElapsedTime
    # explicito (0 = sin timeout).
    if (-not $PSBoundParameters.ContainsKey('ElapsedTime')) { $ElapsedTime = $task.ElapsedTime }
    if (-not $OfficePath) { $OfficePath = $config.OfficeC2RClientPath }
    if (-not $LogPath) { $LogPath = Join-Path $config.LogsPath $task.LogFile }
    if (-not $LogMutexName) { $LogMutexName = $task.MutexName }

    $getVersionCommand = "powershell -command `"(Get-ItemProperty '$($config.Office.VersionRegistryKey)' -ErrorAction SilentlyContinue).$($config.Office.VersionValueName)`""

    $updateCommand = "`"$OfficePath`" /update user displaylevel=true forceappshutdown=$ForceAppShutdown"
    if ($UpdateToVersion) {
        $updateCommand += " updatetoversion=$UpdateToVersion"
    }

    $classPaths = @(Join-Path $PSScriptRoot '..\Classes\BaseDeploy.ps1')

    $action = {
        param($Equipo, $LogPath, $LogMutexName, $GetVersionCommand, $UpdateCommand, $TargetVersionString, $ElapsedTime, $UpdateTenableAfter, $ForceUpdate, $NessusPath, $NessusScanUuid)

        $office = [BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)
        $office.NessusPath     = $NessusPath
        $office.NessusScanUuid = $NessusScanUuid
        try {
            $ping = $office.TestPingEquipo()
            if (-not $ping.Success) {
                return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $ping.msg }
            }

            $alreadyUpdated = $false
            $resumen = 'Office actualizado (forzado, sin comparar version)'

            if ($ForceUpdate) {
                $office.WriteLogSafe("Modo forzado: se actualiza sin consultar la version instalada")
            }
            else {
                $targetVersion = [version]$TargetVersionString
                $versionResult = $office.InvokePsExec($GetVersionCommand, $true, $true, $ElapsedTime)

                if ($versionResult.Success -and $versionResult.StdOut) {
                    $cleanVersion = $versionResult.StdOut -replace 'STDOUT:\s*', ''
                    try {
                        $obtainedVersion = [version]$cleanVersion.Trim()
                        $alreadyUpdated = $obtainedVersion -ge $targetVersion
                        $office.WriteLogSafe("Version instalada: $obtainedVersion (esperada >= $targetVersion)")
                    }
                    catch {
                        $office.WriteLogSafe("No se pudo interpretar version obtenida ('$cleanVersion'), se procede a actualizar igual")
                    }
                }
                $resumen = if ($alreadyUpdated) {
                    "Sin cambios: ya estaba en version >= $targetVersion"
                } else {
                    "Office actualizado (estaba por debajo de $targetVersion)"
                }
            }

            if (-not $alreadyUpdated) {
                $updateResult = $office.InvokePsExec($UpdateCommand, $true, $true, $ElapsedTime)
                if (-not $updateResult.Success) {
                    $msg = "Error actualizando Office: $($updateResult.ErrorMessage)"
                    $office.WriteLogSafe($msg)
                    return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = $updateResult.ExitCode; Message = $msg }
                }
            }

            $office.WriteLogSafe("OK: $resumen")

            if ($UpdateTenableAfter) {
                $tenable = $office.UpdateTenable()
                if ($tenable.Success) {
                    $office.WriteLogSafe("Tenable actualizado correctamente")
                }
                else {
                    $office.WriteLogSafe("Office OK, Tenable no actualizado: $($tenable.ErrorMessage)")
                }
            }

            $office.WriteLogSafe("Completed")
            return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = 0; Message = $resumen }
        }
        catch {
            $msg = "ERROR JOB: $($_.Exception.Message)"
            $office.WriteLogSafe($msg)
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
        }
    }

    $actionArgs = [ordered]@{
        GetVersionCommand   = $getVersionCommand
        UpdateCommand       = $updateCommand
        TargetVersionString = if ($TargetVersion) { $TargetVersion.ToString() } else { '' }
        ElapsedTime         = $ElapsedTime
        UpdateTenableAfter  = [bool]$UpdateTenableAfter
        ForceUpdate         = [bool]$ForceUpdate
        NessusPath         = $config.NessusPath
        NessusScanUuid     = $config.NessusScanUUID
    }

    $results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
        -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
        -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress `
        -ProgressQueue $ProgressQueue -CancelFlag $CancelFlag -Settings $config

    return Write-DeploymentSummary -Results $results -LogPath $LogPath
}
