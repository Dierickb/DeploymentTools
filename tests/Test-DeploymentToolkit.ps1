#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-diagnóstico del toolkit, SIN psexec.exe ni equipos remotos.

.DESCRIPTION
    Esto es lo que Claude no pudo correr (no tenía PowerShell disponible
    en el entorno donde se armó el toolkit). Corré esto PRIMERO, en tu
    propia máquina, antes de probar contra equipos reales — valida en
    segundos toda la lógica que no depende de la red corporativa:

      - Que los 15 archivos .ps1 del módulo parsean sin errores de sintaxis.
      - Que el módulo importa correctamente (Deployment.psd1/.psm1).
      - Que Get-DeploymentRoot resuelve la carpeta del proyecto sin
        rutas hardcodeadas.
      - Que Get-DeploymentConfig lee config.psd1 (o cae a los defaults
        si no existe).
      - Que Read-ComputerList limpia espacios/duplicados/blancos y avisa
        si un archivo queda vacío.
      - Que BaseDeploy.TestPingEquipo() funciona de verdad (contra
        127.0.0.1 — no hace falta red corporativa para esto).
      - Que BaseDeploy.WriteLogSafe() efectivamente escribe en el log.
      - Que KbWindows.CompareKb() detecta correctamente KBs faltantes.
      - Que el patrón de validación de -KbFolder acepta/rechaza lo que
        debería (incluye el caso real que estaba corrupto: "2026-08+++´\\\\\\\\").
      - Que Invoke-ThrottledDeployment (el runner de jobs, el corazón del
        toolkit) efectivamente encola, ejecuta, respeta el throttle limit,
        y arma bien el resumen final — usando un scriptblock de prueba en
        vez de psexec real, así que corre en cualquier máquina.

    Lo que esto NO prueba (necesita psexec.exe + equipos Windows reales
    en tu red): CopyRemote copiando de verdad, InvokePsExec ejecutando
    un comando real via psexec, UpdateTenable contra un agente Nessus
    real. Para eso, corré una tarea desde Deploy-Menu.ps1 contra 2-3
    equipos de prueba.

.EXAMPLE
    .\tests\Test-DeploymentToolkit.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
# $tmpDir solo existe en Windows. GetTempPath() resuelve en los tres SO,
# asi que la suite corre igual en Windows, macOS y Linux.
$tmpDir = [System.IO.Path]::GetTempPath()
$moduleDir = Join-Path $root 'Module\Deployment'

$script:testsPassed = 0
$script:testsFailed = 0
$script:failures = @()

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Write-Host "[OK]   $Name" -ForegroundColor Green
        $script:testsPassed++
    }
    catch {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:testsFailed++
        $script:failures += $Name
    }
}

function Assert-True($condition, $message) {
    if (-not $condition) { throw "Assert-True fallo: $message" }
}
function Assert-Equal($expected, $actual, $message) {
    if ("$expected" -ne "$actual") { throw "Assert-Equal fallo: $message (esperado '$expected', obtenido '$actual')" }
}
function Assert-Throws {
    param([scriptblock]$Body, [string]$Message)
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw "Assert-Throws fallo: $Message (no lanzo excepcion, y debia)" }
}
function Assert-DoesNotThrow {
    param([scriptblock]$Body, [string]$Message)
    try { & $Body } catch { throw "Assert-DoesNotThrow fallo: $Message ($($_.Exception.Message))" }
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Auto-diagnostico del Deployment Toolkit" -ForegroundColor Cyan
Write-Host " (sin psexec.exe, sin equipos remotos)" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# -----------------------------------------------------------------
# 1. Sintaxis: cada .ps1 del módulo parsea sin errores
#
# Classes\KbWindows.ps1 se excluye del loop genérico: declara
# "class KbWindows : BaseDeploy", y el parser necesita el tipo
# [BaseDeploy] ya resuelto en la sesión para validar la herencia —
# ParseFile() sobre el archivo aislado falla con "Unable to find type
# [BaseDeploy]" SIEMPRE (no es un problema de este entorno ni del
# orden del loop; se reproduce igual en Windows). En uso real esto
# nunca pasa porque BaseDeploy.ps1 siempre se dot-sourcea antes que
# KbWindows.ps1 (ver Invoke-KbDeployment.ps1 y el propio Test-Case de
# import más abajo). Para validar la sintaxis real de ambas clases
# juntas, con la herencia resuelta, se parsean concatenadas.
# -----------------------------------------------------------------
$classesDir = Join-Path $moduleDir 'Classes'
$allFiles = @(Get-ChildItem -Path $root -Filter '*.ps1' -Recurse | Where-Object {
    $_.FullName -ne $PSCommandPath -and $_.DirectoryName -ne $classesDir
})
foreach ($f in $allFiles) {
    Test-Case "Sintaxis OK: $($f.FullName.Substring($root.Length + 1))" {
        $errors = $null
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if ($errors.Count -gt 0) {
            throw ($errors | ForEach-Object { $_.Message }) -join '; '
        }
    }
}

Test-Case "Sintaxis OK: Classes\BaseDeploy.ps1 + Classes\KbWindows.ps1 (cargadas juntas, herencia resuelta)" {
    $combined = @(
        Get-Content (Join-Path $classesDir 'BaseDeploy.ps1') -Raw
        Get-Content (Join-Path $classesDir 'KbWindows.ps1') -Raw
    ) -join "`n"
    $errors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseInput($combined, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw ($errors | ForEach-Object { $_.Message }) -join '; '
    }
}

# -----------------------------------------------------------------
# 2. El módulo importa correctamente
# -----------------------------------------------------------------
Test-Case "El modulo Deployment.psd1 importa sin errores" {
    Import-Module (Join-Path $moduleDir 'Deployment.psd1') -Force
    $cmds = Get-Command -Module Deployment
    # 7 tareas + Get-DeploymentConfig + Read-ComputerList + el catalogo
    # (ver Deployment.psm1: los puntos de entrada las necesitan exportadas).
    Assert-True ($cmds.Count -eq 11) "se esperaban 11 funciones exportadas, hay $($cmds.Count): $(($cmds.Name | Sort-Object) -join ', ')"
}

# Para probar los helpers Private/ (no exportados por el modulo) y las
# clases, se dot-sourcean directo — patron normal para testear internos.
. (Join-Path $moduleDir 'Classes\BaseDeploy.ps1')
. (Join-Path $moduleDir 'Classes\KbWindows.ps1')
Get-ChildItem (Join-Path $moduleDir 'Private') -Filter '*.ps1' | ForEach-Object { . $_.FullName }

# Config de referencia para las pruebas: solo las constantes, sin el
# config.psd1 de quien corre la suite (que puede tener sus propios ajustes).
$script:testConfig = Get-DeploymentConfig -ConfigPath (Join-Path $tmpDir "no_existe_$(Get-Random).psd1") -WarningAction SilentlyContinue

# Dentro de un job, Invoke-ThrottledDeployment le carga la config a las
# clases. Aca se usan directo, asi que hay que hacerlo a mano.
[BaseDeploy]::Settings = $script:testConfig

# -----------------------------------------------------------------
# 3. Get-DeploymentRoot
# -----------------------------------------------------------------
Test-Case "Get-DeploymentRoot resuelve la raiz del proyecto" {
    $resolved = (Get-DeploymentRoot).TrimEnd('\')
    $expected = $root.TrimEnd('\')
    Assert-Equal $expected $resolved "Get-DeploymentRoot"
}

# -----------------------------------------------------------------
# 4. Get-DeploymentConfig
# -----------------------------------------------------------------
Test-Case "Get-DeploymentConfig cae a los defaults si config.psd1 no existe" {
    $cfg = Get-DeploymentConfig -ConfigPath (Join-Path $tmpDir "no_existe_$(Get-Random).psd1") -WarningAction SilentlyContinue
    Assert-True ($cfg.DefaultThrottleLimit -gt 0) "DefaultThrottleLimit deberia tener un default"
    # Los valores del entorno NO tienen default: quedan vacios para que la
    # tarea que los necesite avise que falta completarlos.
    Assert-Equal '' $cfg.RepositoryRoot "RepositoryRoot no deberia tener un valor hardcodeado"
    Assert-True ($cfg.ImportsPath -like '*imports*') "ImportsPath si deberia resolverse solo"
}

Test-Case "Get-DeploymentConfig lee config.example.psd1 correctamente" {
    $examplePath = Join-Path $root 'config\config.example.psd1'
    $cfg = Get-DeploymentConfig -ConfigPath $examplePath
    # El ejemplo viene con los valores del entorno VACIOS a proposito: son
    # los que cada quien completa en su config.psd1.
    Assert-Equal '' $cfg.RepositoryRoot "RepositoryRoot deberia venir vacio en el ejemplo"
    Assert-Equal '' $cfg.NessusScanUUID "NessusScanUUID deberia venir vacio en el ejemplo"
    Assert-Equal 5 $cfg.DefaultThrottleLimit "DefaultThrottleLimit"
}

# -----------------------------------------------------------------
# 5. Read-ComputerList
# -----------------------------------------------------------------
Test-Case "Read-ComputerList limpia espacios, duplicados y comentarios" {
    $tmp = Join-Path $tmpDir "test_computers_$(Get-Random).txt"
    @("  host1  ", "host2", "", "host1", "# comentario", "   ", "host3") | Set-Content -Path $tmp -Encoding UTF8
    $list = Read-ComputerList -Path $tmp
    Assert-Equal 3 $list.Count "cantidad de hosts unicos"
    Assert-True ($list -contains 'host1') "deberia contener host1"
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

Test-Case "Read-ComputerList con archivo vacio no explota (solo warning)" {
    $tmp = Join-Path $tmpDir "test_empty_$(Get-Random).txt"
    "" | Set-Content -Path $tmp -Encoding UTF8
    $list = Read-ComputerList -Path $tmp -WarningAction SilentlyContinue
    Assert-Equal 0 $list.Count "lista deberia quedar vacia"
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

Test-Case "Read-ComputerList con archivo inexistente lanza error claro" {
    Assert-Throws { Read-ComputerList -Path (Join-Path $tmpDir "no_existe_$(Get-Random).txt") } "archivo inexistente"
}

# -----------------------------------------------------------------
# 6. BaseDeploy — pruebas reales, sin psexec (ping a loopback, logging)
# -----------------------------------------------------------------
Test-Case "BaseDeploy.TestPingEquipo() funciona contra 127.0.0.1" {
    $tmpLog = Join-Path $tmpDir "test_ping_$(Get-Random).log"
    $deploy = [BaseDeploy]::new('127.0.0.1', $tmpLog, "Global\test_ping_$(Get-Random)")
    $result = $deploy.TestPingEquipo()
    Assert-True $result.Success "ping a 127.0.0.1 deberia funcionar sin red externa"
    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

Test-Case "BaseDeploy.WriteLogSafe() escribe en el log de verdad" {
    $tmpLog = Join-Path $tmpDir "test_log_$(Get-Random).log"
    $deploy = [BaseDeploy]::new('equipo-prueba', $tmpLog, "Global\test_log_$(Get-Random)")
    $deploy.WriteLogSafe("mensaje de prueba 12345")
    Assert-True (Test-Path $tmpLog) "el archivo de log deberia existir"
    $content = Get-Content $tmpLog -Raw
    Assert-True ($content -like '*mensaje de prueba 12345*') "el log deberia contener el mensaje"
    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# 7. KbWindows.CompareKb — lógica pura, sin red
# -----------------------------------------------------------------
Test-Case "KbWindows.CompareKb detecta un KB instalado" {
    $tmpLog = Join-Path $tmpDir "test_kb_$(Get-Random).log"
    $kb = [KbWindows]::new('equipo-prueba', $tmpLog, "Global\test_kb_$(Get-Random)")
    $result = $kb.CompareKb(@("KB1111111", "KB2222222"), @("KB1111111"))
    Assert-True $result.Success "KB1111111 esta en la lista, deberia dar Success=true"
    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

Test-Case "KbWindows.CompareKb detecta un KB faltante" {
    $tmpLog = Join-Path $tmpDir "test_kb2_$(Get-Random).log"
    $kb = [KbWindows]::new('equipo-prueba', $tmpLog, "Global\test_kb2_$(Get-Random)")
    $result = $kb.CompareKb(@("KB1111111"), @("KB9999999"))
    Assert-True (-not $result.Success) "KB9999999 no esta en la lista, deberia dar Success=false"
    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# 8. Patrón de validación de -KbFolder (el bug del valor corrupto)
# -----------------------------------------------------------------
$kbFolderPattern = $script:testConfig.Validation.KbFolderPattern

Test-Case "Patron -KbFolder acepta formatos validos" {
    foreach ($v in @('2026-09', '2026-05', '2026-08h2', '2026-08-24h2')) {
        Assert-True ($v -match $kbFolderPattern) "deberia aceptar '$v'"
    }
}

Test-Case "Patron -KbFolder rechaza el valor corrupto real que tenia kb_execute.ps1" {
    $badValue = "2026-08+++$([char]0x00B4)\\\\\\\\"
    Assert-True (-not ($badValue -match $kbFolderPattern)) "deberia rechazar el valor corrupto"
}

# -----------------------------------------------------------------
# 9. Invoke-ThrottledDeployment — el runner de jobs, sin psexec
# -----------------------------------------------------------------
Test-Case "Invoke-ThrottledDeployment ejecuta, respeta throttle y arma resultados" {
    $tmpLog = Join-Path $tmpDir "test_throttled_$(Get-Random).log"

    # Scriptblock de prueba: no usa BaseDeploy ni psexec, solo simula
    # exito/fallo segun el nombre del "equipo" para poder verificar el
    # resumen.
    $fakeAction = {
        param($Equipo, $LogPath, $LogMutexName)
        Start-Sleep -Milliseconds 100
        return [pscustomobject]@{
            Equipo   = $Equipo
            Success  = ($Equipo -ne 'equipo-que-falla')
            ExitCode = 0
            Message  = "resultado de prueba"
        }
    }

    $results = Invoke-ThrottledDeployment -ComputerList @('host1', 'host2', 'equipo-que-falla') `
        -Action $fakeAction -LogPath $tmpLog -LogMutexName "Global\test_throttled_$(Get-Random)" `
        -ThrottleLimit 2 -ClassPaths @()

    Assert-Equal 3 $results.Count "cantidad de resultados"

    $summary = Write-DeploymentSummary -Results $results -LogPath $tmpLog
    Assert-Equal 2 $summary.Ok "cantidad de OK"
    Assert-Equal 1 $summary.Failed "cantidad de fallidos"
    Assert-True (Test-Path $tmpLog) "el log deberia haberse creado"

    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

Test-Case "El resumen dice QUE equipos salieron OK y cuales fallaron (detalle de las interfaces)" {
    # Es lo que usan los paneles que se abren al hacer click en OK /
    # Fallidos: Succeeded con los OK, Errors con hostname + mensaje. Se
    # prueba por el camino publico que usa la interfaz web con -Simular.
    $tmpLog = Join-Path $tmpDir "test_detalle_$(Get-Random).log"
    $summary = Invoke-SimulatedDeployment -ComputerList @('pc-a', 'pc-fail-b', 'pc-c') -DelayMs 50 `
        -ThrottleLimit 3 -LogPath $tmpLog -LogMutexName "Global\test_detalle_$(Get-Random)"

    $okNames = @($summary.Succeeded | ForEach-Object { $_.Equipo } | Sort-Object)
    Assert-Equal 'pc-a,pc-c' ($okNames -join ',') "Succeeded deberia traer los hostnames OK"
    Assert-Equal 1 @($summary.Errors).Count "deberia haber un fallido"
    Assert-Equal 'pc-fail-b' @($summary.Errors)[0].Equipo "hostname del fallido"
    Assert-True ([bool]@($summary.Errors)[0].Message) "el fallido deberia traer su mensaje de error"
    Assert-Equal $summary.Ok @($summary.Succeeded).Count "Ok y Succeeded tienen que coincidir"
    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

Test-Case "Dos tareas a la vez en runspaces separados no se mezclan (base de la multitarea)" {
    # Es exactamente lo que hacen las interfaces con -MaxTareas: cada tarea
    # en su propio runspace, con su cola, su log y su resumen. Si el modulo
    # compartiera algo entre corridas, aca se verian equipos cruzados.
    $manifest = Join-Path $moduleDir 'Deployment.psd1'
    $corridas = @(
        @{ Hosts = @('ta-01', 'ta-02', 'ta-fail-03'); Log = (Join-Path $tmpDir "test_multiA_$(Get-Random).log") },
        @{ Hosts = @('tb-01', 'tb-02');               Log = (Join-Path $tmpDir "test_multiB_$(Get-Random).log") }
    )
    $worker = {
        param($Manifest, $Hosts, $Log, $Queue)
        Import-Module $Manifest -Force
        Invoke-SimulatedDeployment -ComputerList $Hosts -DelayMs 50 -ThrottleLimit 3 -LogPath $Log `
            -LogMutexName "Global\test_multi_$(Get-Random)" -ProgressQueue $Queue
    }
    foreach ($c in $corridas) {
        $c.Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $c.Ps = [powershell]::Create()
        [void]$c.Ps.AddScript($worker).AddArgument($manifest).AddArgument($c.Hosts).AddArgument($c.Log).AddArgument($c.Queue)
        $c.Handle = $c.Ps.BeginInvoke()      # las dos arrancan antes de esperar a ninguna
    }
    foreach ($c in $corridas) {
        $c.Summary = @($c.Ps.EndInvoke($c.Handle)) | Select-Object -Last 1
        $c.Ps.Dispose()
    }

    $a = $corridas[0]; $b = $corridas[1]
    Assert-Equal 'ta-01,ta-02' ((@($a.Summary.Succeeded | ForEach-Object { $_.Equipo } | Sort-Object)) -join ',') "OK de la corrida A"
    Assert-Equal 'ta-fail-03' (@($a.Summary.Errors)[0].Equipo) "fallido de la corrida A"
    Assert-Equal 'tb-01,tb-02' ((@($b.Summary.Succeeded | ForEach-Object { $_.Equipo } | Sort-Object)) -join ',') "OK de la corrida B"
    Assert-Equal 0 @($b.Summary.Errors).Count "la corrida B no tiene fallidos"

    $logA = Get-Content $a.Log -Raw
    $logB = Get-Content $b.Log -Raw
    Assert-True (($logA -match 'ta-01') -and ($logA -notmatch 'tb-')) "el log de A solo tiene equipos de A"
    Assert-True (($logB -match 'tb-01') -and ($logB -notmatch 'ta-')) "el log de B solo tiene equipos de B"

    $item = $null; $dA = @(); while ($a.Queue.TryDequeue([ref]$item)) { if ($item.Type -eq 'JobDone') { $dA += $item.Equipo } }
    $item = $null; $dB = @(); while ($b.Queue.TryDequeue([ref]$item)) { if ($item.Type -eq 'JobDone') { $dB += $item.Equipo } }
    Assert-Equal 3 $dA.Count "la cola de A reporto sus 3 equipos"
    Assert-Equal 2 $dB.Count "la cola de B reporto sus 2 equipos"
    Assert-True (-not (@($dA) | Where-Object { $_ -like 'tb-*' })) "la cola de A no trae equipos de B"

    Remove-Item $a.Log, $b.Log -ErrorAction SilentlyContinue
}

Test-Case "Invoke-ThrottledDeployment con lista vacia no explota" {
    $tmpLog = Join-Path $tmpDir "test_empty2_$(Get-Random).log"
    $results = Invoke-ThrottledDeployment -ComputerList @() -Action { param($e,$l,$m) } `
        -LogPath $tmpLog -LogMutexName "Global\test_empty2" -ClassPaths @() -WarningAction SilentlyContinue
    Assert-True ($null -ne $results) "el resultado no deberia ser `$null (return @() sin coma unaria colapsa a `$null)"
    Assert-Equal 0 $results.Count "no deberia haber resultados"
}

# -----------------------------------------------------------------
# 10. Integración real: una función pública (Invoke-CopyFiles) con
#     lista de equipos vacía, encadenada hasta Write-DeploymentSummary
#     — el camino real que sigue cualquier scripts\run_*.ps1 cuando el
#     archivo de imports\ queda vacío. Esto es lo que la prueba #9 NO
#     cubría: ahí se llama Invoke-ThrottledDeployment aislado y solo se
#     revisa $results.Count, sin pasar ese valor a Write-DeploymentSummary
#     como sí hacen las 7 funciones públicas reales.
# -----------------------------------------------------------------
Test-Case "Invoke-CopyFiles con lista de equipos vacia no explota (encadenado hasta el resumen)" {
    $tmpLog = Join-Path $tmpDir "test_copyfiles_empty_$(Get-Random).log"
    $summary = $null
    $warn = $null
    $summary = Invoke-CopyFiles -ComputerList @() -SourcePaths @('C:\x') -ItemNames @('archivo.txt') `
        -RemoteSubPaths @('temp') -LogPath $tmpLog -WarningAction SilentlyContinue -WarningVariable warn
    Assert-True ($null -ne $summary) "el resumen no deberia ser `$null"
    Assert-Equal 0 $summary.Total "Total deberia ser 0"
    Assert-Equal 0 $summary.Ok "Ok deberia ser 0"
    Assert-Equal 0 $summary.Failed "Failed deberia ser 0 (vacio no es fallo)"
    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# 11. -ProgressQueue: el reporte de avance en vivo que consume la GUI.
#     Lo importante acá no es solo que encole eventos, sino que el peek
#     con Receive-Job -Keep NO le robe el resultado al resumen final.
# -----------------------------------------------------------------
Test-Case "Invoke-ThrottledDeployment reporta JobStart/JobDone en la ProgressQueue" {
    $tmpLog = Join-Path $tmpDir "test_queue_$(Get-Random).log"
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'

    $fakeAction = {
        param($Equipo, $LogPath, $LogMutexName)
        Start-Sleep -Milliseconds 80
        return [pscustomobject]@{
            Equipo   = $Equipo
            Success  = ($Equipo -ne 'equipo-que-falla')
            ExitCode = 0
            Message  = "resultado de prueba"
        }
    }

    $results = Invoke-ThrottledDeployment -ComputerList @('host1', 'host2', 'equipo-que-falla') `
        -Action $fakeAction -LogPath $tmpLog -LogMutexName "Global\test_queue_$(Get-Random)" `
        -ThrottleLimit 2 -ClassPaths @() -ProgressQueue $queue

    $events = @()
    $item = $null
    while ($queue.TryDequeue([ref]$item)) { $events += $item }

    $starts = @($events | Where-Object { $_.Type -eq 'JobStart' })
    $dones  = @($events | Where-Object { $_.Type -eq 'JobDone' })
    $ends   = @($events | Where-Object { $_.Type -eq 'BatchEnd' })

    Assert-Equal 3 $starts.Count "deberia haber un JobStart por equipo"
    Assert-Equal 3 $dones.Count "deberia haber un JobDone por equipo"
    Assert-Equal 1 $ends.Count "deberia haber un unico BatchEnd"

    $failEvent = @($dones | Where-Object { $_.Equipo -eq 'equipo-que-falla' })
    Assert-Equal 1 $failEvent.Count "deberia reportarse el equipo que falla"
    Assert-True (-not $failEvent[0].Success) "el JobDone del equipo que falla deberia traer Success=false"

    $okEvents = @($dones | Where-Object { $_.Success })
    Assert-Equal 2 $okEvents.Count "deberian reportarse 2 equipos OK"

    # El peek usa -Keep justamente para esto: el resumen final tiene que
    # seguir viendo los 3 resultados intactos.
    Assert-Equal 3 $results.Count "el resultado final no deberia perder equipos por el peek"
    $summary = Write-DeploymentSummary -Results $results -LogPath $tmpLog
    Assert-Equal 2 $summary.Ok "OK en el resumen final"
    Assert-Equal 1 $summary.Failed "fallidos en el resumen final"

    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# 12. -CancelFlag: cancelación cooperativa (el botón "Detener" de la GUI)
# -----------------------------------------------------------------
Test-Case "Invoke-ThrottledDeployment con CancelFlag ya activo no encola ningun equipo" {
    $tmpLog = Join-Path $tmpDir "test_cancel_$(Get-Random).log"
    $cancel = [hashtable]::Synchronized(@{ Cancel = $true })

    $results = Invoke-ThrottledDeployment -ComputerList @('host1', 'host2', 'host3') `
        -Action { param($e, $l, $m) return [pscustomobject]@{ Equipo = $e; Success = $true } } `
        -LogPath $tmpLog -LogMutexName "Global\test_cancel_$(Get-Random)" `
        -ClassPaths @() -CancelFlag $cancel

    Assert-True ($null -ne $results) "el resultado no deberia ser `$null"
    Assert-Equal 0 $results.Count "cancelado de entrada, no deberia haber resultados"

    $logContent = Get-Content $tmpLog -Raw
    Assert-True ($logContent -like '*CANCELADO*') "el log deberia dejar constancia de la cancelacion"

    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

Test-Case "Sin CancelFlag el comportamiento no cambia (no se cancela solo)" {
    $tmpLog = Join-Path $tmpDir "test_nocancel_$(Get-Random).log"
    $results = Invoke-ThrottledDeployment -ComputerList @('host1', 'host2') `
        -Action { param($e, $l, $m) return [pscustomobject]@{ Equipo = $e; Success = $true } } `
        -LogPath $tmpLog -LogMutexName "Global\test_nocancel_$(Get-Random)" -ClassPaths @()

    Assert-Equal 2 $results.Count "deberian procesarse los 2 equipos"
    Remove-Item $tmpLog -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# 13. La GUI llama a las funciones públicas con -ProgressQueue/-CancelFlag.
#     Si alguien agrega una tarea nueva y se olvida del pass-through, la
#     GUI queda muda (sin progreso) o sin poder cancelar.
# -----------------------------------------------------------------
Test-Case "Las 7 funciones publicas exponen -ProgressQueue y -CancelFlag" {
    $publicFunctions = @(
        'Invoke-DeployApp', 'Invoke-CopyFiles', 'Invoke-CopyInstall', 'Invoke-RemoteCommand',
        'Invoke-KbDeployment', 'Invoke-OfficeUpdate', 'Invoke-NessusScan'
    )
    foreach ($fn in $publicFunctions) {
        $cmd = Get-Command $fn -ErrorAction Stop
        Assert-True $cmd.Parameters.ContainsKey('ProgressQueue') "$fn deberia exponer -ProgressQueue"
        Assert-True $cmd.Parameters.ContainsKey('CancelFlag') "$fn deberia exponer -CancelFlag"
    }
}

# -----------------------------------------------------------------
# 14. Encoding: PowerShell 5.1 (el de Windows, el que corre esto en
#     producción) lee un .ps1 SIN BOM como ANSI, no como UTF-8. Un
#     archivo con acentos y sin BOM le corrompe todos los textos: los
#     mensajes del menú, los Write-Warning y las líneas que se escriben
#     al log quedan con mojibake ("está" -> "estÃ¡").
# -----------------------------------------------------------------
Test-Case "Todo .ps1/.psd1 con caracteres no-ASCII tiene BOM UTF-8" {
    $sinBom = @()
    $archivos = @(Get-ChildItem -Path $root -Include '*.ps1', '*.psd1' -Recurse -File)
    foreach ($f in $archivos) {
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        if (@($bytes -gt 127).Count -eq 0) { continue }   # puro ASCII: no importa el BOM
        $tieneBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if (-not $tieneBom) { $sinBom += $f.FullName.Substring($root.Length + 1) }
    }
    Assert-Equal 0 $sinBom.Count "archivos con acentos y sin BOM (PS 5.1 los leeria como ANSI): $($sinBom -join ', ')"
}

# -----------------------------------------------------------------
# 15. El catalogo contra el modulo: cada campo del formulario tiene que
#     corresponder a un parametro REAL de la funcion que esa tarea invoca.
#     Es el pegamento entre las interfaces y el modulo; sin esta prueba, un
#     nombre mal escrito (-SourcePath vs -SourcePaths) recien se descubre
#     con el despliegue lanzado y la ventana abierta.
# -----------------------------------------------------------------
Test-Case "Los campos del catalogo mapean a parametros reales del modulo" {
    $problemas = @()
    foreach ($t in (Get-DeploymentTaskCatalog)) {
        $cmd = Get-Command $t.Function -ErrorAction SilentlyContinue
        if (-not $cmd) {
            $problemas += "$($t.Id): la funcion $($t.Function) no existe en el modulo"
            continue
        }
        foreach ($f in $t.Fields) {
            if (-not $cmd.Parameters.ContainsKey($f.Name)) {
                $problemas += "$($t.Id): -$($f.Name) no es parametro de $($t.Function)"
            }
        }
        # Los que las interfaces agregan siempre al splat, para toda tarea.
        foreach ($p in @('ComputerList', 'ThrottleLimit', 'LogPath', 'ProgressQueue', 'CancelFlag')) {
            if (-not $cmd.Parameters.ContainsKey($p)) {
                $problemas += "$($t.Id): $($t.Function) no acepta -$p"
            }
        }
    }
    Assert-Equal 0 $problemas.Count "campos del catalogo que no matchean: $($problemas -join '; ')"
}

Test-Case "El catalogo trae las 7 tareas con lo minimo que una interfaz necesita" {
    $cat = @(Get-DeploymentTaskCatalog)
    Assert-Equal 7 $cat.Count "deberian ser 7 tareas"
    foreach ($t in $cat) {
        foreach ($clave in @('Id', 'Label', 'Function', 'ImportFile', 'LogFile', 'Throttle', 'Desc', 'Fields')) {
            Assert-True ($t.Contains($clave)) "la tarea $($t.Id) deberia tener $clave"
        }
    }
}

# -----------------------------------------------------------------
# 16. Invoke-OfficeUpdate: modos de actualizacion.
#     Antes -TargetVersion era obligatorio y la unica forma de decidir.
#     Ahora se puede forzar sin comparar, y fijar una version exacta.
# -----------------------------------------------------------------
Test-Case "Invoke-OfficeUpdate ya no exige -TargetVersion como obligatorio" {
    $cmd = Get-Command Invoke-OfficeUpdate
    $attr = @($cmd.Parameters['TargetVersion'].Attributes |
              Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })
    $esObligatorio = @($attr | Where-Object { $_.Mandatory }).Count -gt 0
    Assert-True (-not $esObligatorio) "-TargetVersion no deberia ser obligatorio (se puede usar -ForceUpdate)"
}

Test-Case "Invoke-OfficeUpdate expone -ForceUpdate y -UpdateToVersion" {
    $cmd = Get-Command Invoke-OfficeUpdate
    Assert-True $cmd.Parameters.ContainsKey('ForceUpdate') "deberia exponer -ForceUpdate"
    Assert-True $cmd.Parameters.ContainsKey('UpdateToVersion') "deberia exponer -UpdateToVersion"
}

Test-Case "Invoke-OfficeUpdate sin TargetVersion ni ForceUpdate falla con mensaje claro" {
    $mensaje = ''
    try {
        Invoke-OfficeUpdate -ComputerList @('equipo-inexistente') -WarningAction SilentlyContinue | Out-Null
    }
    catch { $mensaje = $_.Exception.Message }
    Assert-True ($mensaje -like '*-TargetVersion*' -and $mensaje -like '*-ForceUpdate*') `
        "el error deberia nombrar las dos opciones, y decia: '$mensaje'"
}

# -----------------------------------------------------------------
# 17. Read-ComputerList: formatos reales con los que llega una lista de
#     equipos (pegada de un mail, de un Excel, con comillas, con BOM).
# -----------------------------------------------------------------
Test-Case "Read-ComputerList acepta varios equipos en una misma linea" {
    $tmp = Join-Path $tmpDir "test_inline_$(Get-Random).txt"
    @("EQ-01, EQ-02", "EQ-03; EQ-04", "EQ-05`tEQ-06", "EQ-07  EQ-08") | Set-Content -Path $tmp -Encoding UTF8
    $list = Read-ComputerList -Path $tmp
    Assert-Equal 8 $list.Count "deberia separar por coma, punto y coma, tab y espacios"
    Assert-True ($list -contains 'EQ-06') "deberia contener EQ-06"
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

Test-Case "Read-ComputerList saca comillas y comentarios //" {
    $tmp = Join-Path $tmpDir "test_quotes_$(Get-Random).txt"
    @('"EQ-01"', "'EQ-02'", "// comentario", "# otro comentario", "EQ-03") | Set-Content -Path $tmp -Encoding UTF8
    $list = Read-ComputerList -Path $tmp
    Assert-Equal 3 $list.Count "deberia quedar con 3 equipos"
    Assert-True ($list -contains 'EQ-01') "las comillas dobles deberian salir"
    Assert-True ($list -contains 'EQ-02') "las comillas simples deberian salir"
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

Test-Case "Read-ComputerList lee bien un .txt guardado como UTF-8 con BOM" {
    $tmp = Join-Path $tmpDir "test_bom_$(Get-Random).txt"
    [System.IO.File]::WriteAllText($tmp, "EQ-01`r`nEQ-02`r`n", [System.Text.UTF8Encoding]::new($true))
    $list = Read-ComputerList -Path $tmp
    Assert-Equal 2 $list.Count "deberia leer los 2 equipos"
    Assert-True ($list -contains 'EQ-01') "el primer equipo no deberia arrastrar el BOM"
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

Test-Case "Read-ComputerList tolera el BOM llegado como basura ANSI" {
    $tmp = Join-Path $tmpDir "test_bomansi_$(Get-Random).txt"
    $basura = [string]([char]0xEF) + [char]0xBB + [char]0xBF
    [System.IO.File]::WriteAllText($tmp, "$basura`EQ-01`r`nEQ-02`r`n", [System.Text.Encoding]::Unicode)
    $list = Read-ComputerList -Path $tmp
    Assert-Equal 2 $list.Count "deberia leer los 2 equipos"
    Assert-True ($list -contains 'EQ-01') "el primer equipo deberia quedar limpio, y quedo: '$($list[0])'"
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

# -----------------------------------------------------------------
# 18. La prueba que faltaba: que TODO lo que los puntos de entrada llaman
#     del modulo este realmente exportado.
#
#     Esta suite dot-sourcea Private\ a proposito (para probar los helpers
#     por dentro), y eso escondio un bug real: Get-DeploymentConfig y
#     Read-ComputerList no estaban exportadas, pero las interfaces las
#     llamaban. En las pruebas existian y en el uso real no. Por eso esta
#     prueba NO usa Get-Command: mira ExportedFunctions, que es lo unico
#     que ve alguien de afuera.
# -----------------------------------------------------------------
Test-Case "Todo lo que los puntos de entrada llaman del modulo esta exportado" {
    $mod = Get-Module Deployment
    Assert-True ($null -ne $mod) "el modulo deberia estar importado"
    $exportadas = @($mod.ExportedFunctions.Keys)

    $definidas = @(
        @(Get-ChildItem (Join-Path $moduleDir 'Public')  -Filter '*.ps1' -ErrorAction SilentlyContinue) +
        @(Get-ChildItem (Join-Path $moduleDir 'Private') -Filter '*.ps1' -ErrorAction SilentlyContinue)
    ) | ForEach-Object { $_.BaseName }

    $entryPoints = @()
    $entryPoints += @(Get-ChildItem -Path $root -Filter '*.ps1' -File -ErrorAction SilentlyContinue)
    $entryPoints += @(Get-ChildItem -Path (Join-Path $root 'scripts') -Filter '*.ps1' -File -ErrorAction SilentlyContinue)

    $faltantes = @()
    foreach ($ep in $entryPoints) {
        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ep.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { continue }

        $llamadas = @($ast.FindAll({
            param($nodo) $nodo -is [System.Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object { $_.GetCommandName() } |
            Where-Object { $_ } | Select-Object -Unique)

        foreach ($llamada in $llamadas) {
            if (($definidas -contains $llamada) -and ($exportadas -notcontains $llamada)) {
                $faltantes += "$($ep.Name) llama a '$llamada', que el modulo NO exporta"
            }
        }
    }
    Assert-Equal 0 $faltantes.Count ($faltantes -join ' | ')
}

# -----------------------------------------------------------------
# 19. El orden de $actionArgs tiene que coincidir con el param() del
#     scriptblock de la tarea.
#
#     Invoke-ThrottledDeployment pasa @($ActionArgs.Values) POSICIONALMENTE
#     a Start-Job. Si alguien agrega una clave al medio del hashtable y el
#     param del scriptblock no acompana, los argumentos se corren en
#     silencio: el equipo recibe el timeout donde iba el comando y nadie se
#     entera hasta que falla en produccion.
# -----------------------------------------------------------------
Test-Case "El orden de actionArgs coincide con el param() de cada tarea" {
    $desalineados = @()

    foreach ($f in @(Get-ChildItem (Join-Path $moduleDir 'Public') -Filter 'Invoke-*.ps1')) {
        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { continue }

        # El scriptblock de la tarea: el unico con param() dentro del archivo.
        $sb = @($ast.FindAll({
            param($nodo) $nodo -is [System.Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true) | Where-Object { $_.ScriptBlock.ParamBlock }) | Select-Object -First 1
        if (-not $sb) { continue }

        # Los 3 primeros ($Equipo, $LogPath, $LogMutexName) los pone el runner.
        $extras = @(@($sb.ScriptBlock.ParamBlock.Parameters |
                      ForEach-Object { $_.Name.VariablePath.UserPath }) | Select-Object -Skip 3)

        # El hashtable asignado a $actionArgs.
        $asig = @($ast.FindAll({
            param($nodo)
            $nodo -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $nodo.Left.Extent.Text -eq '$actionArgs'
        }, $true)) | Select-Object -First 1

        $claves = @()
        if ($asig) {
            $hash = @($asig.Right.FindAll({
                param($nodo) $nodo -is [System.Management.Automation.Language.HashtableAst]
            }, $true)) | Select-Object -First 1
            if ($hash) {
                $claves = @($hash.KeyValuePairs | ForEach-Object { $_.Item1.Extent.Text })
            }
        }

        if (($extras -join ',') -ne ($claves -join ',')) {
            $desalineados += "$($f.Name): param=[$($extras -join ', ')] vs actionArgs=[$($claves -join ', ')]"
        }
    }

    Assert-Equal 0 $desalineados.Count ($desalineados -join ' | ')
}

# -----------------------------------------------------------------
# 20. Que no vuelva a entrar un dato del entorno al codigo.
#     Todo lo que sea servidor, UUID de scan o similar va en
#     config\config.psd1, que no se versiona.
# -----------------------------------------------------------------
Test-Case "No hay IPs ni UUIDs hardcodeados en el codigo" {
    $hallazgos = @()
    $archivos = @(Get-ChildItem -Path $root -Include '*.ps1', '*.psd1', '*.psm1' -Recurse -File |
                  Where-Object { $_.FullName -ne $PSCommandPath })

    # Se permite 127.0.0.1 (loopback, lo usa la prueba de ping) y los
    # numeros de version tipo 16.0.19929.20220, que no son direcciones.
    $patronIp   = '\b(?!127\.0\.0\.1)(?!0\.)(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\b'
    $patronUuid = '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b'

    foreach ($f in $archivos) {
        $contenido = Get-Content $f.FullName -Raw
        $relativo = $f.FullName.Substring($root.Length + 1)

        foreach ($m in ([regex]$patronIp).Matches($contenido)) {
            # Descarta versiones: los 4 octetos de una IP son <= 255.
            $octetos = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $m.Groups[4].Value)
            $esIp = -not (@($octetos | Where-Object { [int]$_ -gt 255 }).Count -gt 0)
            if ($esIp) { $hallazgos += "$relativo : IP $($m.Value)" }
        }
        foreach ($m in ([regex]$patronUuid).Matches($contenido)) {
            # El GUID de ejemplo todo en ceros es un placeholder, no un dato.
            if ($m.Value -ne '00000000-0000-0000-0000-000000000000') {
                $hallazgos += "$relativo : UUID $($m.Value)"
            }
        }
    }

    Assert-Equal 0 $hallazgos.Count "datos del entorno que quedaron en el codigo: $($hallazgos -join ' | ')"
}

# -----------------------------------------------------------------
# 20b. Read-ComputerList con un archivo vacio devuelve $null a quien lo
#      asigna directo ("return @()" se desenrolla a nada), y pasarle $null
#      a -ComputerList revienta con "Cannot bind argument ... because it is
#      null". Los scripts\run_*.ps1 lo asignaban asi y fallaban justo en el
#      caso que el README dice que es un aviso, no un error. La prueba 10 no
#      lo veia porque le pasa @() directo a Invoke-CopyFiles.
#
#      Se prueba sobre el codigo y no corriendo un wrapper porque los
#      scripts no aceptan -LogPath: el resumen caeria en logs\ del repo.
# -----------------------------------------------------------------
Test-Case "Read-ComputerList con archivo vacio + @() da una lista vacia que -ComputerList acepta" {
    $tmp = Join-Path $tmpDir "test_empty3_$(Get-Random).txt"
    $tmpLog = Join-Path $tmpDir "test_empty3_$(Get-Random).log"
    "" | Set-Content -Path $tmp -Encoding UTF8
    $computers = @(Read-ComputerList -Path $tmp -WarningAction SilentlyContinue)
    $summary = Invoke-CopyFiles -ComputerList $computers -SourcePaths @('x') -ItemNames @('y') `
        -RemoteSubPaths @('z') -LogPath $tmpLog -WarningAction SilentlyContinue
    Assert-Equal 0 $summary.Total "lista vacia: 0 equipos, sin error de binding"
    Remove-Item $tmp, $tmpLog -ErrorAction SilentlyContinue
}

Test-Case "Ningun punto de entrada asigna Read-ComputerList sin envolverlo en @()" {
    $malos = @()
    $entryPoints = @(Get-ChildItem -Path $root -Filter '*.ps1' -File) +
                   @(Get-ChildItem -Path (Join-Path $root 'scripts') -Filter '*.ps1' -File)
    foreach ($ep in $entryPoints) {
        $errors = $null
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($ep.FullName, [ref]$tokens, [ref]$errors)
        $asignaciones = @($ast.FindAll({
            param($nodo)
            $nodo -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $nodo.Right -is [System.Management.Automation.Language.PipelineAst] -and
            $nodo.Right.PipelineElements[0] -is [System.Management.Automation.Language.CommandAst] -and
            $nodo.Right.PipelineElements[0].GetCommandName() -eq 'Read-ComputerList'
        }, $true))
        foreach ($a in $asignaciones) { $malos += "$($ep.Name):$($a.Extent.StartLineNumber)" }
    }
    Assert-Equal 0 $malos.Count "asignar sin @() deja `$null con un archivo vacio: $($malos -join ', ')"
}

# -----------------------------------------------------------------
# 21. Deployment.Constants.psd1: la fuente unica de los valores fijos.
#     Cada tarea del catalogo tiene su identidad ahi, y dos tareas nunca
#     comparten log ni mutex (se pisarian corriendo a la vez).
# -----------------------------------------------------------------
Test-Case "Cada tarea del catalogo tiene log, mutex e imports propios en las constantes" {
    $problemas = @()
    foreach ($t in (Get-DeploymentTaskCatalog -Config $script:testConfig)) {
        $task = $script:testConfig.Tasks.($t.Id)
        if (-not $task) { $problemas += "$($t.Id): no esta en Tasks de Deployment.Constants.psd1"; continue }
        foreach ($clave in @('LogFile', 'MutexName', 'ImportFile', 'ThrottleLimit')) {
            if (-not $task.$clave) { $problemas += "$($t.Id): falta $clave" }
        }
    }
    $todas = @($script:testConfig.Tasks.PSObject.Properties.Value)
    foreach ($clave in @('LogFile', 'MutexName')) {
        $repetidos = @($todas | Group-Object -Property $clave | Where-Object { $_.Count -gt 1 })
        foreach ($r in $repetidos) { $problemas += "$clave '$($r.Name)' compartido por: $(($r.Group.Id) -join ', ')" }
    }
    Assert-Equal 0 $problemas.Count ($problemas -join ' | ')
}

# -----------------------------------------------------------------
# 22. config.psd1 solo puede sobrescribir lo ajustable (seccion Tunable).
#     Lo fijo, como el nombre de mutex de una tarea, se ignora con aviso.
# -----------------------------------------------------------------
Test-Case "config.psd1 sobrescribe lo ajustable e ignora lo fijo" {
    $tmp = Join-Path $tmpDir "test_config_$(Get-Random).psd1"
    @'
@{
    DefaultThrottleLimit = 9
    TaskDefaults = @{
        kb        = @{ ElapsedTime = 1200 }
        copyfiles = @{ LogFile = 'otro.log' }
    }
    Tasks = @{ kb = @{ MutexName = 'Global\otro' } }
    Log   = @{ DateFormat = 'dd/MM' }
}
'@ | Set-Content -Path $tmp -Encoding UTF8

    $warn = $null
    $cfg = Get-DeploymentConfig -ConfigPath $tmp -WarningAction SilentlyContinue -WarningVariable warn
    Remove-Item $tmp -ErrorAction SilentlyContinue

    Assert-Equal 9 $cfg.DefaultThrottleLimit "DefaultThrottleLimit es ajustable"
    Assert-Equal 9 $cfg.Tasks.deployapp.ThrottleLimit "una tarea sin TaskDefaults hereda DefaultThrottleLimit"
    Assert-Equal 1200 $cfg.Tasks.kb.ElapsedTime "TaskDefaults.kb.ElapsedTime es ajustable"
    Assert-Equal $script:testConfig.Tasks.copyinstall.ThrottleLimit $cfg.Tasks.copyinstall.ThrottleLimit "el TaskDefaults de las constantes gana sobre DefaultThrottleLimit"
    Assert-Equal $script:testConfig.Tasks.copyfiles.LogFile $cfg.Tasks.copyfiles.LogFile "LogFile NO es ajustable por TaskDefaults"
    Assert-Equal $script:testConfig.Tasks.kb.MutexName $cfg.Tasks.kb.MutexName "Tasks NO es ajustable"
    Assert-Equal $script:testConfig.Log.DateFormat $cfg.Log.DateFormat "Log NO es ajustable"
    Assert-Equal 3 @($warn).Count "deberia avisar por cada clave ignorada (TaskDefaults.copyfiles.LogFile, Tasks, Log)"
}

# -----------------------------------------------------------------
# 23. Un default por tarea, el mismo en todas las interfaces. Antes el
#     timeout de "Copiar e instalar" era 15 min en la GUI/web y 0 en el
#     menu, scripts\ y el modulo.
# -----------------------------------------------------------------
Test-Case "El catalogo muestra los mismos defaults por tarea que usa el modulo" {
    $problemas = @()
    foreach ($t in (Get-DeploymentTaskCatalog -Config $script:testConfig)) {
        $task = $script:testConfig.Tasks.($t.Id)
        if ($t.Throttle -ne $task.ThrottleLimit) { $problemas += "$($t.Id): throttle $($t.Throttle) vs $($task.ThrottleLimit)" }
        if ($t.ImportFile -ne $task.ImportFile) { $problemas += "$($t.Id): ImportFile" }
        if ($t.LogFile -ne $task.LogFile) { $problemas += "$($t.Id): LogFile" }
        $campoTimeout = @($t.Fields | Where-Object { $_.Type -eq 'Minutes' }) | Select-Object -First 1
        if ($campoTimeout -and ([int]$campoTimeout.Default * 60) -ne $task.ElapsedTime) {
            $problemas += "$($t.Id): timeout $($campoTimeout.Default) min vs $($task.ElapsedTime) s"
        }
    }
    Assert-Equal 0 $problemas.Count ($problemas -join ' | ')
    Assert-Equal 900 $script:testConfig.Tasks.copyinstall.ElapsedTime "Copiar e instalar: 15 minutos por defecto"
}

# -----------------------------------------------------------------
# 24. -KbFolder se valida en el cuerpo (el patron vive en las constantes),
#     antes de levantar un solo job.
# -----------------------------------------------------------------
Test-Case "Invoke-KbDeployment rechaza un -KbFolder invalido con mensaje claro" {
    $mensaje = ''
    try {
        Invoke-KbDeployment -ComputerList @() -KbPatch 'KB1' -KbFolder "2026-08+++$([char]0x00B4)" -WarningAction SilentlyContinue | Out-Null
    }
    catch { $mensaje = $_.Exception.Message }
    Assert-True ($mensaje -like '*-KbFolder*YYYY-MM*') "deberia explicar el formato, y decia: '$mensaje'"
}

# -----------------------------------------------------------------
# 25. Que no vuelvan los magic strings: ningun valor de texto de
#     Deployment.Constants.psd1 puede aparecer escrito como literal en el
#     codigo. Se miran los tokens de string (no los comentarios ni los
#     mensajes que lo mencionan dentro de un texto mas largo).
# -----------------------------------------------------------------
Test-Case "Ningun valor de Deployment.Constants.psd1 esta repetido como literal en el codigo" {
    $constPath = Join-Path $moduleDir 'Deployment.Constants.psd1'
    $const = Import-PowerShellDataFile -Path $constPath

    $valores = @()
    foreach ($task in $const.Tasks.Values) { $valores += @($task.Values | Where-Object { $_ -is [string] }) }
    foreach ($seccion in $const.Keys | Where-Object { $_ -notin @('Tunable', 'Tasks') }) {
        $valores += @($const[$seccion].Values | Where-Object { $_ -is [string] })
    }
    $valores += @($const.Tunable.Values | Where-Object { $_ -is [string] })
    $valores = @($valores | Where-Object { $_ } | Select-Object -Unique)

    $hallazgos = @()
    $archivos = @(Get-ChildItem -Path $root -Include '*.ps1', '*.psm1' -Recurse -File |
                  Where-Object { $_.FullName -ne $PSCommandPath })
    foreach ($f in $archivos) {
        $errors = $null
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        $strings = @($tokens | Where-Object { $_ -is [System.Management.Automation.Language.StringToken] } |
                     ForEach-Object { $_.Value })
        foreach ($v in $valores) {
            # Comparacion exacta, con mayusculas: un titulo de ventana como
            # 'Imports' es texto de interfaz, no el nombre de la carpeta.
            if ($strings -ccontains $v) { $hallazgos += "$($f.FullName.Substring($root.Length + 1)) : '$v'" }
        }
    }
    Assert-Equal 0 $hallazgos.Count "valores de las constantes escritos a mano en el codigo: $($hallazgos -join ' | ')"
}

# -----------------------------------------------------------------
# Resumen
# -----------------------------------------------------------------
Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host " Resultado: $($script:testsPassed) OK / $($script:testsFailed) fallidos" -ForegroundColor $(if ($script:testsFailed -gt 0) { 'Red' } else { 'Green' })
if ($script:testsFailed -gt 0) {
    Write-Host " Fallaron:" -ForegroundColor Red
    $script:failures | ForEach-Object { Write-Host "   - $_" -ForegroundColor Red }
}
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Recordá: esto NO prueba psexec/copia/instalación reales — para eso," -ForegroundColor Yellow
Write-Host "corré una tarea desde Deploy-Menu.ps1 contra 2-3 equipos de prueba." -ForegroundColor Yellow

exit ($(if ($script:testsFailed -gt 0) { 1 } else { 0 }))
