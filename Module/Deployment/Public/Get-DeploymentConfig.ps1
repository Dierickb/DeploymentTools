# Public/Get-DeploymentConfig.ps1
#
# Config centralizada. Devuelve UN objeto con todo lo que el toolkit
# necesita saber, armado en dos capas:
#
#   1. Deployment.Constants.psd1 (junto al modulo, versionado): todos los
#      valores del toolkit, cada uno definido una sola vez. Ver ese archivo
#      para la lista completa y que significa cada valor.
#   2. config\config.psd1 (del operador, NO versionado): encima de lo
#      anterior, pero SOLO puede sobrescribir la seccion Tunable (datos del
#      entorno, timeouts, throttle, success codes, rutas de herramientas).
#      Una clave que no sea ajustable se ignora con un aviso, en vez de
#      cambiar en silencio algo que el resto del toolkit da por fijo.
#
# NINGUN dato del entorno esta hardcodeado: RepositoryRoot, UpdatesPath,
# NessusPath y NessusScanUUID vienen vacios de las constantes. Si falta uno,
# la tarea que lo necesita falla con un mensaje que dice exactamente que
# completar y donde, en vez de apuntar en silencio a un servidor que no es.
#
# Forma del objeto devuelto:
#   .<clave de Tunable>   ya combinada (p. ej. .DefaultThrottleLimit, .PsExecPath)
#   .ImportsPath/.LogsPath  resueltas a rutas absolutas
#   .Tasks.<id>           identidad de la tarea (LogFile, MutexName, ImportFile...)
#                         + ThrottleLimit y ElapsedTime (segundos) ya resueltos
#   .Log, .Remote, .Validation, .Office, .Simulation, .Runner, .Ui, .Paths
#                         las secciones fijas, tal cual
#   .Root                 raiz del proyecto
#
# Es publica porque los puntos de entrada (Deploy-Gui.ps1, Deploy-Web.ps1,
# Deploy-Menu.ps1, scripts\run_*.ps1) la necesitan antes de poder llamar a
# cualquier tarea.
function Get-DeploymentConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    $root = Get-DeploymentRoot
    $constants = Get-DeploymentConstants
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path (Join-Path $root $constants.Paths.ConfigFolder) $constants.Paths.ConfigFile
    }

    # --- 1. Lo ajustable, con los defaults de las constantes ---
    $values = @{}
    foreach ($key in $constants.Tunable.Keys) {
        $values[$key] = $constants.Tunable[$key]
    }
    $taskDefaults = @{}
    foreach ($id in $constants.Tunable.TaskDefaults.Keys) {
        $taskDefaults[$id] = @{} + $constants.Tunable.TaskDefaults[$id]
    }
    # Lo unico que se puede ajustar por tarea. Son nombres de campo (el
    # esquema de TaskDefaults), no valores.
    $taskTunableFields = @('ThrottleLimit', 'ElapsedTime')

    # --- 2. config.psd1 encima, solo sobre lo ajustable ---
    if (Test-Path $ConfigPath) {
        $userConfig = @{}
        try {
            $userConfig = Import-PowerShellDataFile -Path $ConfigPath
        }
        catch {
            Write-Warning "No se pudo leer $ConfigPath ($($_.Exception.Message)); se usan los valores por defecto."
        }

        foreach ($key in $userConfig.Keys) {
            if (-not $constants.Tunable.ContainsKey($key)) {
                Write-Warning "$ConfigPath : '$key' no es un valor ajustable (ver la seccion Tunable de Deployment.Constants.psd1); se ignora."
                continue
            }
            if ($key -ne 'TaskDefaults') {
                $values[$key] = $userConfig[$key]
                continue
            }

            if ($userConfig.TaskDefaults -isnot [hashtable]) {
                Write-Warning "$ConfigPath : TaskDefaults tiene que ser un hashtable @{ <tarea> = @{ ... } }; se ignora."
                continue
            }
            foreach ($id in $userConfig.TaskDefaults.Keys) {
                if (-not $constants.Tasks.ContainsKey($id)) {
                    Write-Warning "$ConfigPath : TaskDefaults.$id no es una tarea conocida ($(($constants.Tasks.Keys | Sort-Object) -join ', ')); se ignora."
                    continue
                }
                if (-not $taskDefaults.ContainsKey($id)) { $taskDefaults[$id] = @{} }
                foreach ($field in $userConfig.TaskDefaults[$id].Keys) {
                    if ($field -notin $taskTunableFields) {
                        Write-Warning "$ConfigPath : TaskDefaults.$id.$field no es ajustable (solo $($taskTunableFields -join ', ')); se ignora."
                        continue
                    }
                    $taskDefaults[$id][$field] = $userConfig.TaskDefaults[$id][$field]
                }
            }
        }
    }
    else {
        Write-Warning "No existe $ConfigPath. Copia config\config.example.psd1 a config\config.psd1 y completa los valores de tu entorno."
    }

    if (-not $values.ImportsPath) { $values.ImportsPath = Join-Path $root $constants.Paths.ImportsFolder }
    if (-not $values.LogsPath)    { $values.LogsPath    = Join-Path $root $constants.Paths.LogsFolder }
    # TaskDefaults ya se aplica en .Tasks: no se expone aparte para que haya
    # un solo lugar donde leer el valor efectivo de cada tarea.
    $values.Remove('TaskDefaults')

    # --- 3. Tareas, con sus defaults ya resueltos ---
    $tasks = [ordered]@{}
    foreach ($id in ($constants.Tasks.Keys | Sort-Object)) {
        $task = [ordered]@{ Id = $id }
        foreach ($k in $constants.Tasks[$id].Keys) { $task[$k] = $constants.Tasks[$id][$k] }
        $task.ThrottleLimit = $values.DefaultThrottleLimit
        $task.ElapsedTime   = $values.DefaultElapsedTime
        if ($taskDefaults.ContainsKey($id)) {
            foreach ($k in $taskDefaults[$id].Keys) { $task[$k] = $taskDefaults[$id][$k] }
        }
        $tasks[$id] = [pscustomobject]$task
    }
    $values.Tasks = [pscustomobject]$tasks

    # --- 4. Secciones fijas, tal cual ---
    foreach ($section in $constants.Keys) {
        if ($section -in @('Tunable', 'Tasks')) { continue }
        $values[$section] = [pscustomobject]$constants[$section]
    }

    $values.Root = $root
    return [pscustomobject]$values
}
