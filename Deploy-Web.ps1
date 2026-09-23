#Requires -Version 5.1
<#
.SYNOPSIS
    Interfaz web local del Deployment Toolkit. Corre en Windows, macOS y Linux.

.DESCRIPTION
    Misma funcionalidad que Deploy-Gui.ps1, pero servida al navegador en vez
    de dibujada con WPF. Existe por una razon concreta: WPF es exclusivo de
    Windows, asi que la interfaz grafica no se puede ni abrir en una Mac. Esta
    si, porque HttpListener y el resto son .NET multiplataforma.

    Las dos interfaces conviven y NO duplican nada:

      - Las 7 tareas salen del mismo catalogo del modulo
        (Get-DeploymentTaskCatalog), asi que no pueden desincronizarse.
      - El despliegue lo hacen las mismas funciones publicas
        (Invoke-DeployApp, Invoke-KbDeployment, etc.).
      - El progreso en vivo usa el mismo mecanismo: un runspace aparte que
        le pasa una cola thread-safe (-ProgressQueue) a
        Invoke-ThrottledDeployment, mas el tail incremental del .log. Lo que
        en WPF era un DispatcherTimer cada 250 ms, aca es el navegador
        pidiendo /api/progress cada 500 ms.

    QUE SE PUEDE PROBAR EN UNA MAC
    Toda la interfaz: catalogo de tareas, lectura de imports\\, validaciones,
    armado de parametros, y el ciclo completo de ejecucion contra equipos
    ficticios usando -Simular. Lo que NO se puede es el despliegue real:
    psexec.exe no existe para macOS y las rutas \\\\equipo\\C$ son recursos
    administrativos de Windows. Para eso, esta misma interfaz en Windows.

    SEGURIDAD
    Escucha solo en loopback (127.0.0.1) y exige un token aleatorio, distinto
    en cada arranque, que viaja en la URL. Sin eso, cualquier pagina web
    abierta en el navegador podria hacerle pedidos a este puerto y disparar
    un despliegue contra cientos de equipos.

.PARAMETER Port
    Puerto local. Por defecto 8787.

.PARAMETER NoBrowser
    No abre el navegador solo; imprime la URL y espera.

.PARAMETER Simular
    No ejecuta nada real: reemplaza la tarea por un scriptblock de prueba que
    inventa resultados. Sirve para recorrer la interfaz completa en una Mac,
    o para mostrarla sin tocar un equipo.

.EXAMPLE
    pwsh ./Deploy-Web.ps1 -Simular
    # en una Mac: recorre toda la interfaz sin tocar ningun equipo

.EXAMPLE
    .\Deploy-Web.ps1
    # en Windows: despliegue real, igual que Deploy-Gui.ps1
#>
[CmdletBinding()]
param(
    [int]$Port = 8787,
    [switch]$NoBrowser,
    [switch]$Simular
)

$ErrorActionPreference = 'Stop'

$script:Root       = $PSScriptRoot
$script:ModulePath = Join-Path $script:Root (Join-Path 'Module' (Join-Path 'Deployment' 'Deployment.psd1'))
Import-Module $script:ModulePath -Force

$script:Config  = Get-DeploymentConfig -WarningAction SilentlyContinue
$script:Tasks   = Get-DeploymentTaskCatalog
$script:Token   = [guid]::NewGuid().ToString('N')
$script:EsWindows = ($null -eq $PSVersionTable.Platform) -or ($PSVersionTable.Platform -eq 'Win32NT')

# Estado de la corrida en curso (una sola a la vez, igual que la GUI)
$script:Run = $null

# ---------------------------------------------------------------------
# 1. Helpers de lista de equipos
#    Misma semantica que Deploy-Gui.ps1: se devuelve SIEMPRE ruta y motivo,
#    nunca una lista vacia en silencio.
# ---------------------------------------------------------------------
function Get-ImportFiles {
    $folder = $script:Config.ImportsPath
    if (-not $folder -or -not (Test-Path $folder)) { return @() }
    return @(Get-ChildItem -Path $folder -Filter '*.txt' -ErrorAction SilentlyContinue |
             Sort-Object Name | ForEach-Object { $_.Name })
}

function Resolve-Computers {
    param([string]$File, [string]$Pegados)

    if ($Pegados) {
        $lista = @($Pegados -split "[`r`n,;\s]+" |
                   ForEach-Object { $_.Trim().Trim('"').Trim("'") } |
                   Where-Object { $_ -ne '' -and -not $_.StartsWith('#') } |
                   Select-Object -Unique)
        return [pscustomobject]@{ List = $lista; Path = '(hostnames pegados a mano)'; Error = $null }
    }

    $folder = $script:Config.ImportsPath
    if (-not $folder -or -not (Test-Path $folder)) {
        return [pscustomobject]@{ List = @(); Path = $folder; Error = "No existe la carpeta de imports: $folder" }
    }
    if (-not $File) {
        return [pscustomobject]@{ List = @(); Path = $folder; Error = "No hay ningun archivo .txt seleccionado." }
    }

    $path = Join-Path $folder $File
    try {
        $lista = @(Read-ComputerList -Path $path -WarningAction SilentlyContinue)
        return [pscustomobject]@{ List = $lista; Path = $path; Error = $null }
    }
    catch {
        return [pscustomobject]@{ List = @(); Path = $path; Error = $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------
# 2. Traduccion formulario -> parametros reales del modulo
#    Es la misma tabla de tipos que usa la GUI (ver el catalogo).
# ---------------------------------------------------------------------
function ConvertTo-Splat {
    param($Task, $Valores)

    $splat = @{}
    foreach ($field in $Task.Fields) {
        $raw = $null
        if ($Valores.PSObject.Properties.Name -contains $field.Name) {
            $raw = $Valores.$($field.Name)
        }

        switch ($field.Type) {
            'Switch'  { if ([bool]$raw) { $splat[$field.Name] = $true } }
            'Bool'    { $splat[$field.Name] = [bool]$raw }
            'BoolArr' { $splat[$field.Name] = [bool[]]@([bool]$raw) }
            'List'    { $splat[$field.Name] = @("$raw" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
            'Codes'   { $splat[$field.Name] = [int[]]@("$raw" -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ }) }
            'TextArr' { $splat[$field.Name] = @("$raw".Trim()) }
            'Int'     { if ("$raw".Trim()) { $splat[$field.Name] = [int]"$raw".Trim() } }
            'Minutes' {
                # La interfaz pide minutos; el modulo espera SEGUNDOS.
                $m = 0
                if ("$raw".Trim()) { $m = [int]"$raw".Trim() }
                $splat[$field.Name] = $m * 60
            }
            default   { if ("$raw".Trim()) { $splat[$field.Name] = "$raw".Trim() } }
        }
    }
    return $splat
}

function Test-Valores {
    param($Task, $Valores, $Computers, [int]$Throttle)

    $errores = @()
    if ($Computers.Count -eq 0) { $errores += 'No hay equipos seleccionados.' }
    if ($Throttle -lt 1) { $errores += 'El throttle limit tiene que ser 1 o mas.' }

    foreach ($field in $Task.Fields) {
        if ($field.Type -in @('Switch', 'Bool', 'BoolArr')) { continue }
        $valor = ''
        if ($Valores.PSObject.Properties.Name -contains $field.Name) { $valor = "$($Valores.$($field.Name))".Trim() }

        if ($field.Required -and -not $valor) {
            $errores += "Falta completar: $($field.Label)."
            continue
        }
        if ($valor -and $field.Pattern -and ($valor -notmatch $field.Pattern)) {
            $errores += "$($field.Label): $($field.PatternMsg)"
        }
    }

    # Reglas propias de dos tareas, iguales a las de la GUI.
    if ($Task.Id -eq 'remotecmd') {
        $cmp = [bool]$Valores.CompareVersion
        $min = "$($Valores.MinVersion)".Trim()
        if ($cmp -and -not $min) { $errores += 'Comparar version requiere la version minima.' }
    }
    if ($Task.Id -eq 'office') {
        $forzar = [bool]$Valores.ForceUpdate
        $target = "$($Valores.TargetVersion)".Trim()
        if (-not $forzar -and -not $target) {
            $errores += 'Indica la version minima esperada, o tilda "Forzar actualizacion".'
        }
    }

    return $errores
}

# ---------------------------------------------------------------------
# 3. Arranque de una corrida
#    Identico en planteo a la GUI: runspace aparte + cola de progreso +
#    flag de cancelacion + tail del log. Aca el que "hace tick" es el
#    navegador pidiendo /api/progress.
# ---------------------------------------------------------------------
function Start-Corrida {
    param($Task, $Splat, $Computers, [int]$Throttle, [string]$LogPath)

    $sync = [hashtable]::Synchronized(@{})
    $sync.Queue   = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $sync.Cancel  = [hashtable]::Synchronized(@{ Cancel = $false })
    $sync.Summary = $null
    $sync.Error   = $null

    $splatFinal = $Splat.Clone()
    $splatFinal['ComputerList']  = $Computers
    $splatFinal['ThrottleLimit'] = $Throttle
    $splatFinal['LogPath']       = $LogPath

    $worker = {
        param($ModulePath, $FunctionName, $Splat, $Sync, $Simular)
        try {
            Import-Module $ModulePath -Force -ErrorAction Stop
            $Splat['ProgressQueue'] = $Sync.Queue
            $Splat['CancelFlag']    = $Sync.Cancel

            if ($Simular) {
                # Modo simulacion: una funcion publica del modulo que corre el
                # MISMO runner con un scriptblock de prueba. Asi se ejercita el
                # camino real (cola de progreso, cancelacion, log, resumen) sin
                # tocar ningun equipo, y sin que esta interfaz tenga que llamar
                # a nada de Private\.
                $Sync.Summary = Invoke-SimulatedDeployment `
                    -ComputerList $Splat['ComputerList'] `
                    -ThrottleLimit $Splat['ThrottleLimit'] `
                    -LogPath $Splat['LogPath'] `
                    -ProgressQueue $Sync.Queue -CancelFlag $Sync.Cancel
            }
            else {
                $Sync.Summary = & $FunctionName @Splat
            }
        }
        catch {
            $Sync.Error = $_.Exception.Message
            $Sync.Queue.Enqueue([pscustomobject]@{ Type = 'Error'; Message = $_.Exception.Message })
        }
        finally {
            $Sync.Queue.Enqueue([pscustomobject]@{ Type = 'WorkerDone' })
        }
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'MTA'
    $rs.ThreadOptions  = 'ReuseThread'
    $rs.Open()

    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($worker).
        AddArgument($script:ModulePath).
        AddArgument($Task.Function).
        AddArgument($splatFinal).
        AddArgument($sync).
        AddArgument([bool]$Simular)

    # Se arranca a leer el log desde el final actual: solo las lineas de
    # ESTA corrida, no el historico.
    $offset = 0
    if (Test-Path $LogPath) { $offset = (Get-Item $LogPath).Length }

    $script:Run = [pscustomobject]@{
        Sync      = $sync
        Ps        = $ps
        Handle    = $ps.BeginInvoke()
        LogPath   = $LogPath
        LogOffset = $offset
        LogCarry  = ''
        Total     = $Computers.Count
        Ok        = 0
        Fail      = 0
        Done      = 0
        # Detalle por equipo para los paneles de OK / Fallidos. Se llenan en
        # vivo con cada JobDone y, al terminar, se reemplazan por el resumen
        # final del modulo (que para un job caido trae el error real, no el
        # generico "sin resultado" que ve el peek en vivo).
        OkList    = New-Object 'System.Collections.Generic.List[string]'
        FailList  = New-Object 'System.Collections.Generic.List[object]'
        Terminado = $false
        Cerrado   = $false
        Tarea     = $Task.Label
    }
}

# Lee solo lo nuevo del log. FileShare.ReadWrite porque los jobs lo estan
# escribiendo al mismo tiempo.
function Read-NuevasLineas {
    if (-not $script:Run) { return @() }
    $path = $script:Run.LogPath
    if (-not $path -or -not (Test-Path $path)) { return @() }

    $lineas = @()
    try {
        $fs = New-Object System.IO.FileStream($path,
            [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        try {
            if ($fs.Length -lt $script:Run.LogOffset) {
                $script:Run.LogOffset = 0
                $script:Run.LogCarry = ''
            }
            [void]$fs.Seek($script:Run.LogOffset, [System.IO.SeekOrigin]::Begin)
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
            $chunk = $sr.ReadToEnd()
            $script:Run.LogOffset = $fs.Position

            if ($chunk) {
                $chunk = $script:Run.LogCarry + $chunk
                $script:Run.LogCarry = ''
                if (-not $chunk.EndsWith("`n")) {
                    $idx = $chunk.LastIndexOf("`n")
                    if ($idx -ge 0) {
                        $script:Run.LogCarry = $chunk.Substring($idx + 1)
                        $chunk = $chunk.Substring(0, $idx + 1)
                    }
                    else { $script:Run.LogCarry = $chunk; $chunk = '' }
                }
                if ($chunk) { $lineas = @($chunk -split "`r?`n" | Where-Object { $_ -ne '' }) }
            }
        }
        finally { $fs.Dispose() }
    }
    catch { }
    return $lineas
}

function Get-EstadoCorrida {
    if (-not $script:Run) {
        return [pscustomobject]@{ activo = $false; lineas = @(); total = 0; ok = 0; fail = 0; done = 0; terminado = $true; resumen = $null }
    }

    $eventos = @()
    $item = $null
    while ($script:Run.Sync.Queue.TryDequeue([ref]$item)) {
        switch ($item.Type) {
            'JobDone' {
                $script:Run.Done = $item.Done
                if ($item.Success) {
                    $script:Run.Ok++
                    $script:Run.OkList.Add([string]$item.Equipo)
                }
                else {
                    $script:Run.Fail++
                    $script:Run.FailList.Add([pscustomobject]@{ equipo = [string]$item.Equipo; mensaje = [string]$item.Message })
                }
            }
            'BatchEnd'   { if ($item.Cancelled) { $eventos += '*** Cancelado por el usuario ***' } }
            'Error'      { $eventos += "ERROR: $($item.Message)" }
            'WorkerDone' { $script:Run.Terminado = $true }
        }
    }

    $lineas = @(Read-NuevasLineas) + $eventos

    $resumen = $null
    if ($script:Run.Terminado -and -not $script:Run.Cerrado) {
        # Una vuelta mas ya se hizo arriba; se cierra el runspace y se arma
        # el resumen final.
        try { [void]$script:Run.Ps.EndInvoke($script:Run.Handle) } catch { }
        try {
            if ($script:Run.Ps.Runspace) { $script:Run.Ps.Runspace.Dispose() }
            $script:Run.Ps.Dispose()
        } catch { }
        $script:Run.Cerrado = $true

        $s = $script:Run.Sync.Summary
        if ($s) {
            # El resumen final es la fuente de verdad del detalle: se
            # reemplaza lo acumulado en vivo.
            $script:Run.OkList.Clear()
            foreach ($r in @($s.Succeeded)) { if ($r) { $script:Run.OkList.Add([string]$r.Equipo) } }
            $script:Run.FailList.Clear()
            foreach ($r in @($s.Errors)) {
                if ($r) { $script:Run.FailList.Add([pscustomobject]@{ equipo = [string]$r.Equipo; mensaje = [string]$r.Message }) }
            }
            $script:Run.Ok   = $script:Run.OkList.Count
            $script:Run.Fail = $script:Run.FailList.Count

            $resumen = [pscustomobject]@{
                total = $s.Total; ok = $s.Ok; fail = $s.Failed
                errores = @($s.Errors | Where-Object { $_ } | ForEach-Object {
                    [pscustomobject]@{ equipo = $_.Equipo; mensaje = "$($_.Message)" }
                })
            }
        }
        elseif ($script:Run.Sync.Error) {
            $resumen = [pscustomobject]@{ total = $script:Run.Total; ok = 0; fail = 0; errores = @(
                [pscustomobject]@{ equipo = '-'; mensaje = $script:Run.Sync.Error }) }
        }
    }

    return [pscustomobject]@{
        activo    = (-not $script:Run.Cerrado)
        lineas    = $lineas
        total     = $script:Run.Total
        ok        = $script:Run.Ok
        fail      = $script:Run.Fail
        done      = $script:Run.Done
        terminado = $script:Run.Cerrado
        resumen   = $resumen
    }
}

# Detalle de la corrida (en curso o la ultima terminada) para los paneles
# que se abren al hacer click en OK o Fallidos. Va aparte de /api/progress
# a proposito: con cientos de equipos no tiene sentido mandar la lista
# entera cada 500 ms, solo cuando el panel esta abierto y el contador cambio.
function Get-ResultadosCorrida {
    param([string]$Tipo)

    if (-not $script:Run) {
        return [pscustomobject]@{ tipo = $Tipo; hayCorrida = $false; items = @() }
    }
    # .ToArray() y asignacion dentro de cada rama, a proposito:
    #  - @($lista) sobre un List[object] leido como propiedad truena en
    #    PowerShell 7.4 con "Argument types do not match".
    #  - "$x = if (...) { @(...) }" desenrolla el array: con UN solo equipo
    #    el JSON saldria como un string suelto en vez de una lista.
    if ($Tipo -eq 'fail') { $items = $script:Run.FailList.ToArray() }
    else                  { $items = $script:Run.OkList.ToArray() }
    return [pscustomobject]@{
        tipo       = $Tipo
        hayCorrida = $true
        tarea      = $script:Run.Tarea
        terminado  = $script:Run.Cerrado
        items      = $items
    }
}

# ---------------------------------------------------------------------
# 4. La pagina
#    Mismo lenguaje visual que Deploy-Gui.ps1 (rail oscuro, acento rojo,
#    verde OK / purpura fallido, consola oscura) y un solo scroll general,
#    como quedo la version WPF.
# ---------------------------------------------------------------------
$script:Html = @'
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Deployment Toolkit</title>
<style>
  *{box-sizing:border-box;}
  body{margin:0;background:#f5f6f8;color:#1b1f24;
       font-family:"Segoe UI",-apple-system,BlinkMacSystemFont,"Helvetica Neue",Arial,sans-serif;font-size:13px;}
  .top{background:#1c1e22;color:#dfe1e6;padding:10px 16px;display:flex;align-items:center;gap:10px;flex-wrap:wrap;}
  .top b{font-weight:600;} .top .sep{color:#4c505a;} .top .sub{color:#8b8f99;}
  .top .modo{margin-left:auto;font-family:ui-monospace,Consolas,monospace;font-size:11px;color:#5c616b;}
  .top .sim{background:#5b2a86;color:#fff;padding:2px 8px;border-radius:10px;font-size:11px;font-weight:600;}
  .wrap{display:flex;min-height:calc(100vh - 42px);align-items:stretch;}
  .rail{background:#1c1e22;width:190px;flex:0 0 190px;padding:12px 10px;}
  .rail button{display:block;width:100%;text-align:left;background:transparent;border:0;color:#b6bac3;
       padding:8px 10px;border-radius:6px;font-size:12.5px;cursor:pointer;margin-bottom:2px;font-family:inherit;}
  .rail button:hover{background:#25272c;color:#e7e9ee;}
  .rail button.on{background:#33131a;color:#fff;}
  .main{flex:1;min-width:0;padding:16px;overflow-y:auto;max-height:calc(100vh - 42px);}
  h2{margin:0 0 3px;font-size:16px;font-weight:600;} .desc{color:#6b7280;font-size:12px;margin:0 0 12px;}
  .card{background:#fff;border:1px solid #e2e4e9;border-radius:8px;padding:14px;margin-bottom:10px;}
  .card h3{margin:0 0 10px;font-size:11px;font-weight:700;color:#8a8f99;letter-spacing:.06em;}
  label{display:block;font-size:11.5px;font-weight:600;color:#454b57;margin-bottom:4px;}
  .hint{font-weight:400;color:#9aa1ad;}
  input[type=text],select,textarea{width:100%;max-width:440px;border:1px solid #d7d9de;border-radius:6px;
       padding:6px 8px;font-family:ui-monospace,Consolas,monospace;font-size:12.5px;background:#fff;color:#1b1f24;}
  textarea{max-width:none;height:70px;}
  .field{margin-bottom:10px;}
  .chk{display:flex;align-items:center;gap:8px;font-size:12.5px;color:#374151;}
  .chk input{width:auto;}
  .row{display:flex;gap:10px;flex-wrap:wrap;align-items:center;}
  button.act{background:#a11530;color:#fff;border:0;border-radius:6px;padding:8px 18px;
       font-weight:600;font-size:13px;cursor:pointer;font-family:inherit;}
  button.act:hover{background:#8d1129;} button.act:disabled{background:#c9ccd2;cursor:default;}
  button.ghost{background:#eef0f3;color:#374151;border:1px solid #d7d9de;border-radius:6px;
       padding:7px 14px;cursor:pointer;font-family:inherit;font-size:12.5px;}
  .path{font-family:ui-monospace,Consolas,monospace;font-size:11px;color:#9aa1ad;margin-top:6px;word-break:break-all;}
  .prev{font-family:ui-monospace,Consolas,monospace;font-size:11.5px;color:#6b7280;margin-top:4px;word-break:break-all;}
  .prev.bad{color:#5b2a86;}
  .err{color:#5b2a86;font-size:12px;margin-top:8px;}
  .tiles{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0;}
  .tile{background:#f5f6f8;border:1px solid #e6e8ec;border-radius:7px;padding:8px 12px;min-width:92px;}
  .tile .n{font-size:18px;font-weight:700;} .tile .l{font-size:10.5px;font-weight:600;color:#8a8f99;}
  .tile.ok .n{color:#2e7d32;} .tile.fail .n{color:#5b2a86;}
  /* OK y Fallidos son botones: abren el detalle por equipo */
  button.tile{font-family:inherit;text-align:left;cursor:pointer;color:inherit;}
  button.tile:hover{background:#eceef1;border-color:#d7d9de;}
  button.tile:focus-visible{outline:2px solid #a11530;outline-offset:2px;}
  button.tile.ok.on{background:#fff;border-color:#2e7d32;box-shadow:inset 0 0 0 1px #2e7d32;}
  button.tile.fail.on{background:#fff;border-color:#5b2a86;box-shadow:inset 0 0 0 1px #5b2a86;}
  .car{display:inline-block;width:5px;height:5px;border-right:1.5px solid currentColor;border-bottom:1.5px solid currentColor;
       transform:rotate(45deg);margin-left:6px;position:relative;top:-2px;transition:transform .15s;}
  button.tile.on .car{transform:rotate(-135deg);top:1px;}
  .det{border:1px solid #e2e4e9;border-radius:7px;background:#fafbfc;margin:0 0 10px;}
  .det[hidden]{display:none;}
  .det-h{display:flex;align-items:center;gap:8px;padding:8px 10px;border-bottom:1px solid #e6e8ec;flex-wrap:wrap;}
  .det-t{font-size:11px;font-weight:700;letter-spacing:.06em;} .det-t.ok{color:#2e7d32;} .det-t.fail{color:#5b2a86;}
  .det-n{font-size:11px;font-weight:600;color:#6b7280;background:#eef0f3;border-radius:10px;padding:1px 8px;}
  .det-acc{display:flex;gap:6px;margin-left:auto;}
  .det-h button.ghost{padding:4px 10px;font-size:11.5px;} .det-h button.ghost:disabled{color:#a8adb6;cursor:default;}
  .det-b{max-height:260px;overflow:auto;padding:6px 10px 8px;}
  .det-vacio{color:#6b7280;font-size:12.5px;padding:6px 0;}
  .hosts{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:0 14px;
         font-family:ui-monospace,Consolas,monospace;font-size:12px;}
  .hosts div{padding:3px 0;border-bottom:1px solid #eef0f3;overflow-wrap:anywhere;}
  table.fails{width:100%;border-collapse:collapse;font-size:12px;}
  table.fails th{position:sticky;top:-6px;background:#fafbfc;text-align:left;font-size:10.5px;font-weight:700;
         color:#8a8f99;letter-spacing:.05em;padding:4px 10px 4px 0;border-bottom:1px solid #e2e4e9;}
  table.fails td{padding:5px 10px 5px 0;border-bottom:1px solid #eef0f3;vertical-align:top;}
  table.fails td:first-child{font-family:ui-monospace,Consolas,monospace;font-weight:600;white-space:nowrap;width:1%;}
  table.fails td:last-child{color:#4a3566;overflow-wrap:anywhere;}
  .bar{height:7px;background:#e6e8ec;border-radius:20px;overflow:hidden;flex:1;min-width:120px;}
  .bar>div{height:100%;width:0;background:#a11530;transition:width .3s;}
  .con{background:#12141a;color:#c9cdd6;border-radius:7px;padding:10px 12px;height:300px;overflow:auto;
       font-family:ui-monospace,Consolas,monospace;font-size:11.5px;line-height:1.6;white-space:pre-wrap;}
  .con .ok{color:#56d364;} .con .bad{color:#b28cf0;} .con .warn{color:#ffcf6b;}
  .con .mut{color:#7d8590;} .con .sum{color:#e7e9ee;font-weight:600;}
  @media (max-width:760px){ .wrap{flex-direction:column;} .rail{width:auto;flex:none;display:flex;gap:4px;overflow-x:auto;}
       .rail button{white-space:nowrap;width:auto;} .main{max-height:none;} }
</style>
</head>
<body>
<div class="top">
  <b>Deployment Toolkit</b><span class="sep">-</span><span class="sub" id="tTarea"></span>
  <span id="tSim"></span>
  <span class="modo" id="tRoot"></span>
</div>
<div class="wrap">
  <nav class="rail" id="rail"></nav>
  <main class="main">
    <h2 id="tTitulo"></h2>
    <p class="desc" id="tDesc"></p>

    <div class="card">
      <h3>LISTA DE EQUIPOS</h3>
      <div class="row">
        <label class="chk"><input type="radio" name="src" value="file" checked> Archivo de imports\</label>
        <select id="selFile" style="max-width:280px"></select>
        <label class="chk"><input type="radio" name="src" value="paste"> Pegar hostnames</label>
        <button class="ghost" id="btnRecargar">Recargar</button>
      </div>
      <textarea id="pegados" style="display:none;margin-top:8px" placeholder="un hostname por linea, o separados por coma"></textarea>
      <div id="cuenta" style="margin-top:8px;font-size:12.5px"></div>
      <div class="path" id="ruta"></div>
      <div class="prev" id="prev"></div>
    </div>

    <div class="card"><h3>PARAMETROS</h3><div id="campos"></div></div>

    <div class="card">
      <h3>EJECUCION</h3>
      <div class="row">
        <label style="margin:0">Throttle limit</label>
        <input type="text" id="throttle" style="width:60px">
        <button class="act" id="btnRun">Ejecutar</button>
        <button class="ghost" id="btnStop" disabled>Detener</button>
        <span class="path" id="logHint"></span>
      </div>
      <div class="err" id="errores" style="display:none"></div>
    </div>

    <div class="card">
      <h3>PROGRESO Y CONSOLA EN VIVO</h3>
      <div class="row"><span id="prog" style="min-width:110px;font-size:11.5px;color:#6b7280"></span>
        <div class="bar"><div id="barra"></div></div></div>
      <div class="tiles">
        <div class="tile"><div class="n" id="nTotal">0</div><div class="l">TOTAL</div></div>
        <button type="button" class="tile ok" id="tOk" aria-expanded="false" aria-controls="det"
                title="Ver los equipos que terminaron OK"><div class="n" id="nOk">0</div><div class="l">OK<span class="car"></span></div></button>
        <button type="button" class="tile fail" id="tFail" aria-expanded="false" aria-controls="det"
                title="Ver los equipos que fallaron y su error"><div class="n" id="nFail">0</div><div class="l">FALLIDOS<span class="car"></span></div></button>
        <button class="ghost" id="btnLimpiar" style="align-self:center">Limpiar consola</button>
      </div>
      <div class="det" id="det" hidden>
        <div class="det-h">
          <span class="det-t" id="detTitulo"></span><span class="det-n" id="detN">0</span>
          <span class="det-acc">
            <button type="button" class="ghost" id="btnCopiar" title="Copia solo los hostnames, uno por linea">Copiar hostnames</button>
            <button type="button" class="ghost" id="btnCerrarDet" aria-label="Cerrar detalle">Cerrar</button>
          </span>
        </div>
        <div class="det-b" id="detCuerpo"></div>
      </div>
      <div class="con" id="con"></div>
    </div>
  </main>
</div>
<script>
const TOKEN = new URLSearchParams(location.search).get('t') || '';
let TAREAS = [], actual = null, poll = null;

const $ = id => document.getElementById(id);
const api = (ruta, opt) => fetch(ruta + (ruta.includes('?') ? '&' : '?') + 't=' + TOKEN, opt).then(r => r.json());

function tipoLinea(l){
  if (/RESUMEN|INIT \||FIN \|/.test(l)) return 'sum';
  if (/ERROR|FAIL|No Instalado|no actualizado|CANCELADO/.test(l)) return 'bad';
  if (/OK:|Ping OK|Completed|correctamente/.test(l)) return 'ok';
  if (/INSTALANDO|Ejecutando:|Copiando|Consultando|simulacion/.test(l)) return 'warn';
  return 'mut';
}
function log(linea, clase){
  const d = document.createElement('div');
  d.className = clase || tipoLinea(linea);
  d.textContent = linea;
  $('con').appendChild(d);
  while ($('con').childElementCount > 900) $('con').removeChild($('con').firstChild);
  $('con').scrollTop = $('con').scrollHeight;
}

function pintarRail(){
  $('rail').innerHTML = '';
  TAREAS.forEach(t => {
    const b = document.createElement('button');
    b.textContent = t.Label;
    b.onclick = () => elegir(t.Id);
    b.dataset.id = t.Id;
    $('rail').appendChild(b);
  });
}

function elegir(id){
  actual = TAREAS.find(t => t.Id === id);
  [...$('rail').children].forEach(b => b.classList.toggle('on', b.dataset.id === id));
  $('tTarea').textContent = actual.Label;
  $('tTitulo').textContent = actual.Label;
  $('tDesc').textContent = actual.Desc;
  $('throttle').value = actual.Throttle;
  $('logHint').textContent = 'logs\\' + actual.LogFile;
  pintarCampos();
  cargarArchivos();
}

function pintarCampos(){
  const c = $('campos'); c.innerHTML = '';
  if (!actual.Fields || !actual.Fields.length){
    c.innerHTML = '<div style="color:#6b7280;font-size:12.5px">Esta tarea no tiene parametros propios.</div>';
    return;
  }
  actual.Fields.forEach(f => {
    const d = document.createElement('div'); d.className = 'field';
    if (['Switch','Bool','BoolArr'].includes(f.Type)){
      d.innerHTML = '<label class="chk"><input type="checkbox" id="f_' + f.Name + '"' +
                    (f.Default ? ' checked' : '') + '> ' + f.Label + '</label>';
    } else {
      d.innerHTML = '<label>' + f.Label + (f.Hint ? ' <span class="hint">(' + f.Hint + ')</span>' : '') +
                    '</label><input type="text" id="f_' + f.Name + '" value="' + (f.Default || '') + '">';
    }
    c.appendChild(d);
  });
}

function valores(){
  const v = {};
  (actual.Fields || []).forEach(f => {
    const el = $('f_' + f.Name);
    v[f.Name] = ['Switch','Bool','BoolArr'].includes(f.Type) ? el.checked : el.value;
  });
  return v;
}

function cargarArchivos(){
  api('/api/imports').then(r => {
    $('selFile').innerHTML = '';
    r.archivos.forEach(a => {
      const o = document.createElement('option'); o.value = a; o.textContent = a;
      if (a === actual.ImportFile) o.selected = true;
      $('selFile').appendChild(o);
    });
    refrescarEquipos();
  });
}

function refrescarEquipos(){
  const pegar = document.querySelector('input[name=src]:checked').value === 'paste';
  const q = pegar ? '/api/computers?paste=1' : '/api/computers?file=' + encodeURIComponent($('selFile').value);
  const opt = pegar ? { method:'POST', headers:{'Content-Type':'application/json'},
                        body: JSON.stringify({ pegados: $('pegados').value }) } : undefined;
  api(q, opt).then(r => {
    $('cuenta').textContent = r.total + ' equipos seleccionados';
    $('ruta').textContent = 'Leyendo: ' + r.ruta;
    if (r.error){ $('prev').className = 'prev bad'; $('prev').textContent = 'PROBLEMA: ' + r.error; }
    else if (!r.total){ $('prev').className = 'prev bad'; $('prev').textContent = 'El archivo existe pero no tiene hostnames.'; }
    else { $('prev').className = 'prev'; $('prev').textContent = r.muestra.join('   ') + (r.total > 6 ? '   ... +' + (r.total-6) + ' mas' : ''); }
  });
}

function ejecutar(){
  $('errores').style.display = 'none';
  const pegar = document.querySelector('input[name=src]:checked').value === 'paste';
  const cuerpo = {
    tarea: actual.Id, valores: valores(), throttle: $('throttle').value,
    archivo: pegar ? '' : $('selFile').value, pegados: pegar ? $('pegados').value : ''
  };
  api('/api/run', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify(cuerpo) })
    .then(r => {
      if (r.errores && r.errores.length){
        $('errores').style.display = 'block';
        $('errores').textContent = r.errores.join('   |   ');
        return;
      }
      $('con').innerHTML = '';
      log('=== ' + actual.Label + ' - ' + r.total + ' equipos - throttle ' + r.throttle + ' ===', 'sum');
      log('Llamando a ' + actual.Function + (r.simulado ? '  [SIMULACION]' : ''), 'mut');
      $('nTotal').textContent = r.total; $('nOk').textContent = '0'; $('nFail').textContent = '0';
      $('btnRun').disabled = true; $('btnStop').disabled = false;
      if (detalle) cargarDetalle();   // corrida nueva: el panel abierto arranca vacio
      poll = setInterval(progreso, 500);
    });
}

// ---- Detalle por equipo (click en OK / Fallidos) ----
// El panel pide la lista al servidor solo cuando esta abierto y el contador
// cambio: con cientos de equipos no vale la pena traerla en cada tick.
let detalle = null, detalleN = -1, detalleItems = [], pidiendo = false, repetir = false;

function abrirDetalle(tipo){
  detalle = (detalle === tipo) ? null : tipo;
  ['ok','fail'].forEach(t => {
    const b = $(t === 'ok' ? 'tOk' : 'tFail');
    b.classList.toggle('on', detalle === t);
    b.setAttribute('aria-expanded', detalle === t ? 'true' : 'false');
  });
  $('det').hidden = !detalle;
  detalleN = -1;
  if (detalle) cargarDetalle();
}

function cargarDetalle(){
  const tipo = detalle;
  if (!tipo) return;
  // Un pedido a la vez; si llega otro mientras tanto (p.ej. el del final de
  // la corrida), se repite al volver para no quedarse con datos viejos.
  if (pidiendo){ repetir = true; return; }
  pidiendo = true;
  api('/api/resultados?tipo=' + tipo)
    .then(r => { if (detalle === tipo) pintarDetalle(r); })
    .finally(() => { pidiendo = false; if (repetir){ repetir = false; cargarDetalle(); } });
}

function pintarDetalle(r){
  const ok = r.tipo === 'ok';
  const items = r.items || [];
  detalleItems = items; detalleN = items.length;
  $('detTitulo').textContent = ok ? 'EQUIPOS OK' : 'EQUIPOS FALLIDOS';
  $('detTitulo').className = 'det-t ' + (ok ? 'ok' : 'fail');
  $('detN').textContent = items.length;
  $('btnCopiar').disabled = !items.length;
  $('btnCopiar').textContent = 'Copiar hostnames';

  const cuerpo = $('detCuerpo'); cuerpo.innerHTML = '';
  if (!items.length){
    const d = document.createElement('div'); d.className = 'det-vacio';
    d.textContent = !r.hayCorrida ? 'Todavia no se ejecuto ninguna tarea.'
                  : ok ? (r.terminado ? 'Ningun equipo termino OK.' : 'Todavia ningun equipo termino OK.')
                       : (r.terminado ? 'Ningun equipo fallo.' : 'Por ahora ningun equipo fallo.');
    cuerpo.appendChild(d);
    return;
  }
  // Todo con textContent: hostnames y mensajes vienen de archivos y de los
  // equipos, nunca se interpretan como HTML.
  if (ok){
    const g = document.createElement('div'); g.className = 'hosts';
    items.forEach(h => { const d = document.createElement('div'); d.textContent = h; g.appendChild(d); });
    cuerpo.appendChild(g);
  } else {
    const t = document.createElement('table'); t.className = 'fails';
    t.innerHTML = '<thead><tr><th>HOSTNAME</th><th>ERROR</th></tr></thead>';
    const tb = document.createElement('tbody');
    items.forEach(e => {
      const tr = document.createElement('tr');
      const h = document.createElement('td'); h.textContent = e.equipo;
      const m = document.createElement('td'); m.textContent = e.mensaje || '(sin detalle)';
      tr.append(h, m); tb.appendChild(tr);
    });
    t.appendChild(tb); cuerpo.appendChild(t);
  }
}

function copiarHostnames(){
  const texto = detalleItems.map(i => typeof i === 'string' ? i : i.equipo).join('\n');
  const listo = () => { $('btnCopiar').textContent = 'Copiado'; setTimeout(() => $('btnCopiar').textContent = 'Copiar hostnames', 1500); };
  if (navigator.clipboard && window.isSecureContext){
    navigator.clipboard.writeText(texto).then(listo, () => copiarViejo(texto, listo));
  } else { copiarViejo(texto, listo); }
}
function copiarViejo(texto, listo){
  const ta = document.createElement('textarea');
  ta.value = texto; ta.style.position = 'fixed'; ta.style.opacity = '0';
  document.body.appendChild(ta); ta.select();
  try { document.execCommand('copy'); listo(); } catch (e) { }
  document.body.removeChild(ta);
}

function progreso(){
  api('/api/progress').then(r => {
    (r.lineas || []).forEach(l => log(l));
    $('nOk').textContent = r.ok; $('nFail').textContent = r.fail;
    $('prog').textContent = r.done + ' / ' + r.total + ' equipos';
    $('barra').style.width = r.total ? Math.round(r.done / r.total * 100) + '%' : '0';
    if (detalle){
      // Al terminar se recarga igual: el resumen final puede traer un error
      // mas preciso que el que se vio en vivo, aunque el contador no cambie.
      const n = detalle === 'ok' ? r.ok : r.fail;
      if (n !== detalleN || r.terminado) cargarDetalle();
    }
    if (r.terminado){
      clearInterval(poll); poll = null;
      $('btnRun').disabled = false; $('btnStop').disabled = true;
      if (r.resumen){
        log('RESUMEN | Total=' + r.resumen.total + ' OK=' + r.resumen.ok + ' Fallidos=' + r.resumen.fail, 'sum');
        (r.resumen.errores || []).forEach(e => log('  - ' + e.equipo + '  ' + e.mensaje, 'bad'));
      }
    }
  });
}

$('btnRun').onclick = ejecutar;
$('btnStop').onclick = () => { api('/api/stop', {method:'POST'}); $('btnStop').disabled = true; };
$('btnRecargar').onclick = cargarArchivos;
$('btnLimpiar').onclick = () => $('con').innerHTML = '';
$('tOk').onclick = () => abrirDetalle('ok');
$('tFail').onclick = () => abrirDetalle('fail');
$('btnCerrarDet').onclick = () => { if (detalle) abrirDetalle(detalle); };
$('btnCopiar').onclick = copiarHostnames;
$('selFile').onchange = refrescarEquipos;
$('pegados').oninput = () => { if (document.querySelector('input[name=src]:checked').value === 'paste') refrescarEquipos(); };
document.querySelectorAll('input[name=src]').forEach(r => r.onchange = () => {
  const pegar = document.querySelector('input[name=src]:checked').value === 'paste';
  $('pegados').style.display = pegar ? 'block' : 'none';
  $('selFile').disabled = pegar;
  refrescarEquipos();
});

api('/api/init').then(r => {
  TAREAS = r.tareas; 
  $('tRoot').textContent = r.root;
  if (r.simulado) $('tSim').innerHTML = '<span class="sim">SIMULACION</span>';
  pintarRail();
  elegir(TAREAS[0].Id);
});
</script>
</body>
</html>
'@

# ---------------------------------------------------------------------
# 5. Router HTTP
# ---------------------------------------------------------------------
function Write-Respuesta {
    param($Context, $Cuerpo, [string]$Tipo = 'application/json; charset=utf-8', [int]$Codigo = 200)

    $texto = if ($Tipo -like 'application/json*') { $Cuerpo | ConvertTo-Json -Depth 8 -Compress } else { [string]$Cuerpo }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($texto)
    $Context.Response.StatusCode  = $Codigo
    $Context.Response.ContentType = $Tipo
    $Context.Response.ContentLength64 = $bytes.Length
    # Nada de esto debe quedar cacheado: son datos vivos.
    $Context.Response.Headers.Add('Cache-Control', 'no-store')
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.OutputStream.Close()
}

function Read-CuerpoJson {
    param($Context)
    if ($Context.Request.ContentLength64 -le 0) { return [pscustomobject]@{} }
    $sr = New-Object System.IO.StreamReader($Context.Request.InputStream, [System.Text.Encoding]::UTF8)
    $texto = $sr.ReadToEnd()
    $sr.Close()
    if (-not $texto) { return [pscustomobject]@{} }
    try { return ($texto | ConvertFrom-Json) } catch { return [pscustomobject]@{} }
}

function Invoke-Ruta {
    param($Context)

    $ruta = $Context.Request.Url.AbsolutePath
    $q    = $Context.Request.QueryString

    # Token obligatorio en todo lo que no sea la pagina inicial. Impide que
    # otra pestania del navegador dispare un despliegue contra el puerto.
    if ($ruta -ne '/' -and $q['t'] -ne $script:Token) {
        Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{ error = 'token invalido' }) -Codigo 403
        return
    }

    switch -Regex ($ruta) {

        '^/$' {
            if ($q['t'] -ne $script:Token) {
                Write-Respuesta -Context $Context -Cuerpo 'Token invalido. Abri la URL que imprimio el script.' -Tipo 'text/plain; charset=utf-8' -Codigo 403
                return
            }
            Write-Respuesta -Context $Context -Cuerpo $script:Html -Tipo 'text/html; charset=utf-8'
            return
        }

        '^/api/init$' {
            Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{
                tareas   = $script:Tasks
                root     = $script:Root
                simulado = [bool]$Simular
            })
            return
        }

        '^/api/imports$' {
            Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{ archivos = @(Get-ImportFiles) })
            return
        }

        '^/api/computers$' {
            $pegados = ''
            if ($Context.Request.HttpMethod -eq 'POST') {
                $cuerpo = Read-CuerpoJson -Context $Context
                $pegados = "$($cuerpo.pegados)"
            }
            $r = Resolve-Computers -File $q['file'] -Pegados $pegados
            Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{
                total   = $r.List.Count
                muestra = @($r.List | Select-Object -First 6)
                ruta    = "$($r.Path)"
                error   = $r.Error
            })
            return
        }

        '^/api/run$' {
            if ($script:Run -and -not $script:Run.Cerrado) {
                Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{ errores = @('Ya hay un despliegue en curso.') })
                return
            }

            $cuerpo = Read-CuerpoJson -Context $Context
            $task = $script:Tasks | Where-Object { $_.Id -eq $cuerpo.tarea } | Select-Object -First 1
            if (-not $task) {
                Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{ errores = @('Tarea desconocida.') })
                return
            }

            $throttle = 0
            [void][int]::TryParse("$($cuerpo.throttle)".Trim(), [ref]$throttle)
            $r = Resolve-Computers -File "$($cuerpo.archivo)" -Pegados "$($cuerpo.pegados)"
            $errores = @(Test-Valores -Task $task -Valores $cuerpo.valores -Computers $r.List -Throttle $throttle)
            if ($r.Error) { $errores = @($r.Error) + $errores }

            if ($errores.Count -gt 0) {
                Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{ errores = $errores })
                return
            }

            $splat = ConvertTo-Splat -Task $task -Valores $cuerpo.valores
            $logPath = Join-Path $script:Config.LogsPath $task.LogFile
            Start-Corrida -Task $task -Splat $splat -Computers $r.List -Throttle $throttle -LogPath $logPath

            Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{
                errores = @(); total = $r.List.Count; throttle = $throttle; simulado = [bool]$Simular
            })
            return
        }

        '^/api/progress$' {
            Write-Respuesta -Context $Context -Cuerpo (Get-EstadoCorrida)
            return
        }

        '^/api/resultados$' {
            $tipo = if ($q['tipo'] -eq 'fail') { 'fail' } else { 'ok' }
            Write-Respuesta -Context $Context -Cuerpo (Get-ResultadosCorrida -Tipo $tipo)
            return
        }

        '^/api/stop$' {
            if ($script:Run -and -not $script:Run.Cerrado) {
                $script:Run.Sync.Cancel['Cancel'] = $true
            }
            Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{ ok = $true })
            return
        }

        default {
            Write-Respuesta -Context $Context -Cuerpo ([pscustomobject]@{ error = 'no encontrado' }) -Codigo 404
            return
        }
    }
}

# ---------------------------------------------------------------------
# 6. Arranque del servidor
# ---------------------------------------------------------------------
$listener = [System.Net.HttpListener]::new()
$prefijo = "http://127.0.0.1:$Port/"
$listener.Prefixes.Add($prefijo)

try {
    $listener.Start()
}
catch {
    Write-Host ""
    Write-Host "No se pudo escuchar en $prefijo" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor DarkRed
    Write-Host ""
    Write-Host "Si el puerto esta ocupado, proba otro:  -Port 8899" -ForegroundColor Yellow
    if ($script:EsWindows) {
        Write-Host "Si dice 'Acceso denegado', Windows pide reservar la URL una sola vez," -ForegroundColor Yellow
        Write-Host "desde una consola como administrador:" -ForegroundColor Yellow
        Write-Host "   netsh http add urlacl url=$prefijo user=$env:USERDOMAIN\$env:USERNAME" -ForegroundColor Cyan
        Write-Host "(o corre esta ventana de PowerShell como administrador)" -ForegroundColor Yellow
    }
    return
}

$url = "$prefijo" + "?t=$script:Token"

Write-Host ""
Write-Host "Deployment Toolkit - interfaz web" -ForegroundColor Cyan
Write-Host "  URL     : $url"
Write-Host "  Carpeta : $script:Root"
if ($Simular) {
    Write-Host "  Modo    : SIMULACION (no toca ningun equipo)" -ForegroundColor Magenta
}
elseif (-not $script:EsWindows) {
    Write-Host "  Aviso   : no estas en Windows. La interfaz anda, pero el despliegue real" -ForegroundColor Yellow
    Write-Host "            necesita psexec.exe y rutas \\equipo\C$. Usa -Simular para recorrerla." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Ctrl+C para detener el servidor." -ForegroundColor DarkGray
Write-Host ""

if (-not $NoBrowser) {
    try {
        if ($script:EsWindows) { Start-Process $url }
        elseif ($IsMacOS)      { Start-Process 'open' -ArgumentList $url }
        else                   { Start-Process 'xdg-open' -ArgumentList $url }
    }
    catch {
        Write-Host "  (no se pudo abrir el navegador solo; copia la URL de arriba)" -ForegroundColor DarkGray
    }
}

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try { Invoke-Ruta -Context $ctx }
        catch {
            try {
                Write-Respuesta -Context $ctx -Cuerpo ([pscustomobject]@{ error = $_.Exception.Message }) -Codigo 500
            } catch { }
        }
    }
}
finally {
    # Si queda un despliegue corriendo, se le pide cancelar antes de cerrar.
    if ($script:Run -and -not $script:Run.Cerrado) {
        $script:Run.Sync.Cancel['Cancel'] = $true
    }
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-Host "Servidor detenido." -ForegroundColor DarkGray
}
