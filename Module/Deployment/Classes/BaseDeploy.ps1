# Classes/BaseDeploy.ps1
#
# Clase base para despliegues remotos (ping, copia de archivos, PsExec).
# Ver CHANGES.md para el detalle de qué se corrigió respecto a la versión anterior.

class BaseDeploy {

    [string] $Equipo
    [string] $LogPath
    [string] $LogMutexName
    [System.Threading.Mutex] $Mutex

    # Datos del entorno para Tenable. Se setean desde afuera (las funciones
    # publicas los toman de config\config.psd1 y los pasan al job). NO tienen
    # valor por defecto a proposito: antes la ruta y el UUID estaban escritos
    # dentro del metodo UpdateTenable, con lo cual el dato del entorno vivia
    # en el codigo y no habia forma de cambiarlo sin editar la clase.
    [string] $NessusPath = ''
    [string] $NessusScanUuid = ''

    BaseDeploy([string]$equipo, [string]$logPath, [string]$logMutexName) {
        $this.Equipo = $equipo.Trim()
        $this.LogPath = $logPath
        $this.LogMutexName = $logMutexName
        $this.Mutex = [System.Threading.Mutex]::new($false, $logMutexName)
    }

    [void] WriteLogSafe([string]$message) {
        $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | $($this.Equipo) | $message"

        try {
            if (-not $this.Mutex.WaitOne(5000)) { return }
            Add-Content -Path $this.LogPath -Value $line -Encoding UTF8
        }
        finally {
            try { $this.Mutex.ReleaseMutex() | Out-Null } catch {}
        }
    }

    [pscustomobject] TestPingEquipo() {
        $this.WriteLogSafe("Ping test")
        try {
            $ping = New-Object System.Net.NetworkInformation.Ping
            $reply = $ping.Send($this.Equipo, 2000)

            if ($reply.Status -eq 'Success') {
                $this.WriteLogSafe("Ping OK a $($this.Equipo)")
                return [pscustomobject]@{
                    Success  = $true
                    ExitCode = 0
                    StdOut   = "Ping OK a $($this.Equipo)"
                    StdErr   = ""
                    msg      = "Ping OK a $($this.Equipo)"
                }
            }
            throw "Ping FAIL a $($this.Equipo): $($reply.Status)"
        }
        catch {
            $msg = "ERROR Ping: $($_.Exception.Message)"
            $this.WriteLogSafe($msg)
            return [pscustomobject]@{
                Success  = $false
                ExitCode = -1
                StdOut   = ""
                StdErr   = $msg
                msg      = $msg
            }
        }
    }

    [pscustomobject] CopyRemote(
        [string]$SourcePath,
        [string]$ItemName,
        [string]$remoteSubPath = "temp\RemoteInstall",
        [switch]$Recurse
    ) {
        try {
            $remoteRoot = "\\$($this.Equipo)\C$"
            $remoteUNC  = Join-Path $remoteRoot $remoteSubPath

            if (Test-Path $remoteUNC) {
                $item = Get-Item $remoteUNC -ErrorAction SilentlyContinue
                if ($item -and -not $item.PSIsContainer) {
                    $this.WriteLogSafe("$remoteUNC existe como archivo, eliminando...")
                    Remove-Item $remoteUNC -Force
                }
            }

            $this.WriteLogSafe("Copiando $ItemName desde $SourcePath hacia $remoteUNC")
            New-Item -ItemType Directory -Path $remoteUNC -Force | Out-Null
            $sourceFull = Join-Path $SourcePath $ItemName
            $destFull   = Join-Path $remoteUNC $ItemName

            if ($Recurse) {
                Copy-Item -Path $sourceFull -Destination $remoteUNC -Recurse -Force -ErrorAction Stop
            } else {
                Copy-Item -Path $sourceFull -Destination $remoteUNC -Force -ErrorAction Stop
            }

            Start-Sleep -Seconds 2

            for ($i = 0; $i -lt 30; $i++) {
                if (Test-Path $destFull) {
                    $this.WriteLogSafe("$destFull validado en destino")
                    return [pscustomobject]@{
                        Success  = $true
                        ExitCode = 0
                        StdOut   = "Copiado correctamente: $sourceFull --> $destFull"
                        StdErr   = ""
                        msg      = "Copiado correctamente: $sourceFull --> $destFull"
                    }
                }
                Start-Sleep -Seconds 1
            }

            throw "ERROR CopyRemote: No se encontró el item en destino tras la copia: $destFull"
        }
        catch {
            $type = $_.Exception.GetType().Name
            $msg  = $_.Exception.Message

            $this.WriteLogSafe("ERROR CopyRemote [$type]: $msg")
            return [pscustomobject]@{
                Success  = $false
                ExitCode = -1
                StdOut   = ""
                StdErr   = $msg
                msg      = $msg
            }
        }
    }

    # Overload de conveniencia: sin elapsedTime, corre sin timeout (equivalente a pasar 0).
    #
    # BUG corregido (ver CHANGES.md): los métodos de una clase de PowerShell
    # NO admiten valores por defecto para sus parámetros — llamar a
    # InvokePsExec() con menos de 4 argumentos rompe la resolución del
    # método. `office_update.ps1` llamaba a InvokePsExec() con solo 3
    # argumentos, lo que fallaba. Este overload explícito hace que ese tipo
    # de llamada (con 3 argumentos) funcione correctamente sin timeout, en
    # vez de fallar.
    [pscustomobject] InvokePsExec([string]$command, [switch]$runAsSystem, [switch]$elevated) {
        return $this.InvokePsExec($command, $runAsSystem, $elevated, 0)
    }

    [pscustomobject] InvokePsExec(
        [string]$command,
        [switch]$runAsSystem,
        [switch]$elevated,
        [int]$elapsedTime
    ) {
        $flags = @('-accepteula', '-nobanner')
        if ($runAsSystem) { $flags += '-s' }
        if ($elevated) { $flags += '-h' }
        $arguments = "\\$($this.Equipo) $($flags -join ' ') $command"
        $this.WriteLogSafe("Ejecutando: psexec $arguments")

        $result = $null
        $proc = $null

        try {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = 'psexec.exe'
            $psi.Arguments = $arguments
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true
            $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
            $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

            $proc = [System.Diagnostics.Process]::Start($psi)

            # BUG corregido: antes se leia con ReadToEnd() (bloqueante) ANTES
            # de llamar a WaitForExit($elapsedTime). ReadToEnd() no retorna
            # hasta que el proceso cierra sus streams (es decir, hasta que
            # termina), asi que para cuando el codigo llegaba a
            # WaitForExit() el proceso ya habia terminado (o el hilo ya
            # llevaba colgado un buen rato bloqueado en ReadToEnd()) — el
            # timeout nunca se aplicaba de verdad. Si psexec se quedaba
            # colgado (UAC, red inestable, instalador esperando un
            # dialogo), el job se quedaba colgado PARA SIEMPRE, sin ningun
            # timeout posible: justo lo que $elapsedTime deberia evitar en
            # un despliegue masivo a cientos de equipos.
            #
            # Se corrige con lectura ASINCRONA (ReadToEndAsync, no bloquea)
            # para poder llamar a WaitForExit($ms) de verdad y matar el
            # proceso si se excede el tiempo, sin depender de que los
            # streams ya se hayan cerrado.
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            $timedOut = $false
            if ($elapsedTime -ne 0) {
                # $elapsedTime esta en SEGUNDOS; WaitForExit espera
                # MILISEGUNDOS. (otro bug corregido: antes se pasaba
                # $elapsedTime tal cual, o sea "10 minutos" terminaba
                # siendo un timeout real de 600 milisegundos, no 600
                # segundos).
                if (-not $proc.WaitForExit($elapsedTime * 1000)) {
                    $timedOut = $true
                    try {
                        if (-not $proc.HasExited) { $proc.Kill() }
                    }
                    catch {
                        throw "Error proceso de InvokePsExec"
                    }
                }
            }
            else {
                $proc.WaitForExit()
            }

            # Una vez que el proceso terminó (normal o por Kill()), sus
            # streams se cierran y los Task ya deberían completar solos;
            # el timeout de 5s acá es solo un resguardo, no el mecanismo
            # principal de control de tiempo (ese es el WaitForExit de arriba).
            [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000) | Out-Null
            $stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.Result } else { "" }
            $stderr = if ($stderrTask.IsCompleted) { $stderrTask.Result } else { "" }

            if ($timedOut) {
                throw "Timeout esperando finalizacion de PsExec (${elapsedTime}s)"
            }

            $result = [pscustomobject]@{
                Success  = $true
                ExitCode = $proc.ExitCode
                StdOut   = ($stdout -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join ', '
                StdErr   = ($stderr -replace '\r\n|\r|\n', ' ' -replace '\s{2,}', ' ').Trim()
                msg      = "INVOKE PSEXEC: PSexec ejecutado correctamente"
            }
            if ($proc.ExitCode -ne 0 -and $stderr) {
                throw "ExitCode invalido: $($result.ExitCode)"
            }
            return $result
        }
        catch {
            $msg = "ERROR InvokePsExec: $($_.Exception.Message)"
            $this.WriteLogSafe($msg)
            return [pscustomobject]@{
                Success      = $false
                ExitCode     = if ($result) { $result.ExitCode } else { -1 }
                StdOut       = if ($result) { $result.StdOut } else { "" }
                StdErr       = if ($result) { $result.StdErr } else { "" }
                msg          = $msg
                ErrorMessage = $msg
            }
        }
        finally {
            if ($proc) { try { $proc.Dispose() } catch {} }
        }
    }

    [pscustomobject] DeployApp(
        [string]$Command,
        [int[]]$SuccessCodes = @(0),
        [int]$elapsedTime
    ) {
        $this.WriteLogSafe("Deploy App Iniciando")
        $result = $null
        try {
            $result = $this.InvokePsExec($Command, $true, $true, $elapsedTime)

            if (-not $result.Success) {
                throw "DEPLOY APP: InvokePsExec fallo: $($result.ErrorMessage)"
            }

            $isSuccessCode = $true
            if ($SuccessCodes -and $SuccessCodes.Count -gt 0) {
                $isSuccessCode = $SuccessCodes -contains $result.ExitCode
            }

            if (-not $isSuccessCode) {
                throw "DEPLOY APP: ExitCode invalido $($result.ExitCode)"
            }
            return [pscustomobject]@{
                Success  = $true
                ExitCode = $result.ExitCode
                StdOut   = $result.StdOut
                StdErr   = $result.StdErr
                msg      = "DEPLOY APP: Deploy ejecutado correctamente"
            }
        }
        catch {
            $msg = "$($_.Exception.Message)"
            $this.WriteLogSafe("ERROR DeployApp: $msg")
            return [pscustomobject]@{
                Success      = $false
                ExitCode     = if ($result) { $result.ExitCode } else { -1 }
                StdOut       = if ($result) { $result.StdOut } else { "" }
                StdErr       = if ($result) { $result.StdErr } else { "" }
                msg          = $msg
                ErrorMessage = $msg
            }
        }
    }

    # Overload de conveniencia: usa lo que tenga seteado la instancia.
    [pscustomobject] UpdateTenable() {
        return $this.UpdateTenable($this.NessusPath, $this.NessusScanUuid)
    }

    [pscustomobject] UpdateTenable(
        [string]$nessusPath,
        [string]$scanUuid
    ) {
        $this.WriteLogSafe("Inicio Update Tenable")

        $result = $null

        try {
            # Si falta configuracion, se dice exactamente que falta y donde,
            # en vez de fallar mas adelante con un error de ruta.
            if ([string]::IsNullOrWhiteSpace($nessusPath)) {
                throw "Falta NessusPath en config\config.psd1 (ruta local de nessuscli.exe en los equipos)."
            }
            if ([string]::IsNullOrWhiteSpace($scanUuid)) {
                throw "Falta NessusScanUUID en config\config.psd1 (UUID del scan de Tenable)."
            }

            if (-not (Test-Path $nessusPath)) {
                throw "nessuscli.exe no encontrado en ruta: $nessusPath"
            }

            $argumentsFile = "scan-triggers --start --uuid=`"$scanUuid`""
            $cmd = "`"$nessusPath`" $argumentsFile"
            $result = $this.InvokePsExec($cmd, $false, $true, 420)

            if (-not $result -or -not $result.Success) {
                $errorMsg = if ($result) { $result.ErrorMessage } else { "Resultado NULL desde InvokePsExec" }
                throw $errorMsg
            }
            return [pscustomobject]@{
                Success  = $true
                ExitCode = $result.ExitCode
                StdOut   = $result.StdOut
                StdErr   = ""
                msg      = "UPDATE TENABLE: Update Tenable ejecutado correctamente"
            }
        }
        catch {
            $msg = "ERROR UPDATE TENABLE: $($_.Exception.Message)"
            $this.WriteLogSafe($msg)
            return [pscustomobject]@{
                Success      = $false
                ExitCode     = if ($result -and $null -ne $result.ExitCode) { $result.ExitCode } else { -1 }
                StdOut       = if ($result) { $result.StdOut } else { "" }
                StdErr       = if ($result) { $result.StdErr } else { "" }
                msg          = $msg
                ErrorMessage = $msg
            }
        }
    }
}
