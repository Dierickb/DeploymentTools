# Private/Invoke-ThrottledDeployment.ps1
#
# Reemplaza el bloque
#     $jobs = @()
#     foreach ($Equipo in $Equipos) {
#         while (...) { Start-Sleep -Seconds 1 }
#         $jobs += Start-Job ...
#     }
#     Wait-Job $jobs | Out-Null
#     $jobs | Remove-Job -Force
# que estaba copiado casi idéntico en los 7 scripts de execute\ (cada uno
# con pequeñas variaciones: algunos con throttleLimit mal escrito como
# "throttletLimit", otros sin manejo de progreso). Ahora es una sola
# función.
#
# CAMBIO DE DISEÑO importante respecto al original: antes cada scriptblock
# terminaba con `exit 0` / `exit -1`. Un `exit` dentro de un Start-Job SÍ
# termina el proceso hijo, pero PowerShell NO expone ese código de salida
# en ninguna propiedad simple de $job — así que en la práctica, en los 7
# scripts originales, ese exit code nunca se leía en ningún lado. Tras
# `Wait-Job`/`Remove-Job` el script solo imprimía "Procesamiento paralelo
# finalizado", sin importar cuántos equipos fallaron. Acá el scriptblock de
# cada tarea debe *devolver* (Write-Output, no `exit`) un objeto con al
# menos `Equipo` y `Success`, y esta función arma con eso un resumen real al
# final (ver Write-DeploymentSummary).
function Invoke-ThrottledDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ComputerList,

        # Scriptblock que recibe, en este orden: $Equipo, $LogPath, $LogMutexName,
        # y luego los valores de $ActionArgs (en el orden en que se agregaron).
        # Debe devolver un [pscustomobject] con al menos Equipo/Success/Message.
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [string]$LogPath,

        [Parameter(Mandatory)]
        [string]$LogMutexName,

        [int]$ThrottleLimit = 5,

        # OrderedDictionary a propósito: el orden de .Values debe coincidir
        # con el orden de los parámetros extra del scriptblock $Action.
        [System.Collections.Specialized.OrderedDictionary]$ActionArgs = [ordered]@{},

        # Rutas de los .ps1 de clases a cargar dentro de cada job (BaseDeploy.ps1, KbWindows.ps1...).
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ClassPaths,

        [switch]$ShowProgress,

        # Cola opcional para reportar progreso EN VIVO, equipo por equipo,
        # sin esperar a que termine el lote completo. Se encola un evento
        # 'JobStart' cuando cada equipo entra a la cola de ejecución y un
        # 'JobDone' apenas su job termina, con el Success ya resuelto.
        #
        # Para qué existe: la GUI (Deploy-Gui.ps1) corre esta función en un
        # runspace aparte del hilo de interfaz y drena esta cola cada 250 ms
        # para pintar el avance. Sin esto, la única señal de progreso posible
        # era mirar el archivo de log a mano, porque esta función no devuelve
        # NADA hasta que el último equipo terminó.
        #
        # Es un ConcurrentQueue a propósito: lo escribe este runspace y lo lee
        # el hilo de UI, así que tiene que ser thread-safe de verdad.
        [System.Collections.Concurrent.ConcurrentQueue[object]]$ProgressQueue,

        # Hashtable (idealmente [hashtable]::Synchronized(@{})) con una clave
        # 'Cancel'. Si en cualquier momento pasa a $true, se deja de encolar
        # equipos nuevos, se detienen los jobs que sigan corriendo, y la
        # función devuelve los resultados PARCIALES en vez de quedarse
        # esperando. Es lo que hace posible el botón "Detener" de la GUI:
        # los jobs se frenan desde acá, que es el único scope donde Get-Job
        # los ve (Start-Job los registra por runspace).
        [hashtable]$CancelFlag
    )

    if ($ComputerList.Count -eq 0) {
        Write-Warning "La lista de equipos está vacía. Nada que hacer."
        # OJO: "return @()" (sin la coma unaria) colapsa a $null en quien
        # lo llama -- PowerShell "desenrolla" un array vacío puesto en el
        # stream de salida, así que "$results = Invoke-ThrottledDeployment ..."
        # termina con $results = $null en vez de un array de 0 elementos.
        # Las 7 funciones públicas (Invoke-CopyFiles, etc.) hacen justo eso
        # y después pasan $results a Write-DeploymentSummary, que es
        # Mandatory y truena con "Cannot bind argument ... because it is
        # null." La coma unaria fuerza que el array (vacío) llegue intacto.
        return ,@()
    }

    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }
    if (-not (Test-Path $LogPath)) {
        New-Item -Path $LogPath -ItemType File -Force | Out-Null
    }
    Add-Content -Path $LogPath -Encoding UTF8 -Value (
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | INIT | Inicio ejecucion " +
        "($($ComputerList.Count) equipos, throttle=$ThrottleLimit)"
    )

    $missingClasses = $ClassPaths | Where-Object { -not (Test-Path $_) }
    if ($missingClasses) {
        throw "No se encuentran estos archivos de clase: $($missingClasses -join ', ')"
    }
    $dotSourceLines = $ClassPaths | ForEach-Object { ". '$_'" }
    $initScript = [scriptblock]::Create($dotSourceLines -join "`n")

    $total = $ComputerList.Count
    $started = 0
    $jobs = @()
    $cancelled = $false

    # Con una cola de progreso conectada se hace polling más fino (250 ms en
    # vez de 1 s): es lo que hace que la consola de la GUI se sienta "en vivo"
    # en vez de avanzar a los saltos. Sin cola, se mantiene el intervalo de
    # siempre para no cambiar el comportamiento de consola/tareas programadas.
    $pollMs = if ($ProgressQueue) { 250 } else { 1000 }

    # Marca los jobs que ya terminaron y todavía no fueron reportados a la
    # cola. Clave por Id (no por Name): Name es el hostname y, aunque
    # Read-ComputerList deduplica, el Id siempre es único.
    $reportedJobs = @{}
    $reportFinished = {
        param($jobList)
        if (-not $ProgressQueue) { return }
        foreach ($j in $jobList) {
            if ($j.State -eq 'Running' -or $reportedJobs.ContainsKey($j.Id)) { continue }
            $reportedJobs[$j.Id] = $true

            $peek = $null
            try {
                # -Keep es la clave: mira la salida del job SIN consumirla,
                # para que la recolección final (más abajo) siga encontrando
                # el objeto de resultado intacto. Sin -Keep, este peek le
                # robaría el resultado al resumen final.
                $peek = Receive-Job -Job $j -Keep -ErrorAction SilentlyContinue | Select-Object -Last 1
            }
            catch { }

            $ProgressQueue.Enqueue([pscustomobject]@{
                Type    = 'JobDone'
                Equipo  = $j.Name
                Success = [bool]($peek -and $peek.Success)
                Message = if ($peek -and $peek.Message) { [string]$peek.Message } else { "Job en estado '$($j.State)' sin resultado" }
                Done    = $reportedJobs.Count
                Total   = $total
            })
        }
    }

    $isCancelled = { return ($CancelFlag -and $CancelFlag['Cancel']) }

    foreach ($equipo in $ComputerList) {
        if (& $isCancelled) { $cancelled = $true; break }

        while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -ge $ThrottleLimit) {
            if (& $isCancelled) { break }
            & $reportFinished $jobs
            Start-Sleep -Milliseconds $pollMs
        }
        if (& $isCancelled) { $cancelled = $true; break }

        $argList = @($equipo, $LogPath, $LogMutexName) + @($ActionArgs.Values)
        $jobs += Start-Job -Name $equipo -InitializationScript $initScript -ScriptBlock $Action -ArgumentList $argList
        $started++

        if ($ProgressQueue) {
            $ProgressQueue.Enqueue([pscustomobject]@{
                Type    = 'JobStart'
                Equipo  = $equipo
                Started = $started
                Total   = $total
            })
        }

        if ($ShowProgress) {
            Write-Progress -Activity "Encolando equipos" -Status "$started / $total" -PercentComplete (($started / $total) * 100)
        }
    }

    $completed = 0
    while (($jobs | Where-Object { $_.State -eq 'Running' }).Count -gt 0) {
        if (& $isCancelled) {
            $cancelled = $true
            $running = @($jobs | Where-Object { $_.State -eq 'Running' })
            if ($running.Count -gt 0) {
                $running | Stop-Job -ErrorAction SilentlyContinue
            }
            break
        }

        Start-Sleep -Milliseconds $pollMs
        & $reportFinished $jobs

        if ($ShowProgress) {
            $doneNow = ($jobs | Where-Object { $_.State -ne 'Running' }).Count
            if ($doneNow -ne $completed) {
                $completed = $doneNow
                Write-Progress -Activity "Ejecutando en los equipos" -Status "$completed / $total completados" -PercentComplete (($completed / $total) * 100)
            }
        }
    }
    if ($ShowProgress) { Write-Progress -Activity "Ejecutando en los equipos" -Completed }

    # Último barrido: los equipos que terminaron entre la penúltima vuelta del
    # loop y la salida (o los que fueron detenidos por cancelación) también
    # tienen que llegar a la cola, o la GUI quedaría mostrando un contador
    # que nunca cierra.
    & $reportFinished $jobs

    $results = foreach ($job in $jobs) {
        $jobErrors = $job.ChildJobs[0].Error
        $output = Receive-Job -Job $job -ErrorAction SilentlyContinue

        # El scriptblock debería devolver exactamente UN objeto de resultado.
        # Si no devolvió nada (excepción no controlada dentro del job antes
        # del primer Write-Output) o el job terminó en estado Failed, se
        # arma un resultado sintético para que igual aparezca en el resumen
        # en vez de desaparecer silenciosamente.
        $resultObj = $output | Select-Object -Last 1

        if (-not $resultObj -or $job.State -eq 'Failed') {
            $errText = if ($jobErrors -and $jobErrors.Count -gt 0) { ($jobErrors | ForEach-Object { $_.ToString() }) -join '; ' } else { "Job en estado '$($job.State)' sin resultado" }
            [pscustomobject]@{
                Equipo   = $job.Name
                Success  = $false
                ExitCode = -1
                Message  = $errText
            }
        }
        else {
            $resultObj
        }
    }

    $jobs | Remove-Job -Force

    $finLine = if ($cancelled) {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | FIN | Procesamiento CANCELADO por el usuario ($($jobs.Count) de $total equipos encolados)"
    }
    else {
        "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | FIN | Procesamiento finalizado"
    }
    Add-Content -Path $LogPath -Encoding UTF8 -Value $finLine

    if ($ProgressQueue) {
        $ProgressQueue.Enqueue([pscustomobject]@{
            Type      = 'BatchEnd'
            Cancelled = $cancelled
            Total     = $total
        })
    }

    # Misma razón que el "return ,@()" de arriba: forzar array-ness para
    # que un resultado vacío no colapse a $null en el caller.
    return ,@($results)
}
