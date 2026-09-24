#Requires -Version 5.1
<#
.SYNOPSIS
    Interfaz interactiva de consola para el toolkit de despliegue.

.DESCRIPTION
    Antes, cada tarea (desplegar una app, copiar un archivo, correr un
    comando puntual...) significaba abrir un .ps1 en un editor, cambiar
    variables a mano, guardar, y hacer doble click en el .cmd
    correspondiente. Este menú hace lo mismo de forma interactiva, sin
    tocar ningún archivo de código: elegís la tarea, la lista de equipos
    y los parámetros desde la consola.

.EXAMPLE
    .\Deploy-Menu.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
Import-Module (Join-Path $root 'Module\Deployment\Deployment.psd1') -Force

# ---------------------------------------------------------------------
# Helpers de UI (viven acá, no en el módulo: son específicos de consola)
# ---------------------------------------------------------------------

function Write-Title($text) {
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host ("=" * 60) -ForegroundColor DarkCyan
}

function Read-MenuChoice($options, $prompt = "Elegí una opción") {
    for ($i = 0; $i -lt $options.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $options[$i])
    }
    Write-Host ""
    while ($true) {
        $raw = Read-Host $prompt
        if ($raw -match '^\d+$' -and [int]$raw -ge 1 -and [int]$raw -le $options.Count) {
            return [int]$raw
        }
        Write-Host "Opción inválida." -ForegroundColor Yellow
    }
}

function Read-YesNo($prompt, $default = $true) {
    $suffix = if ($default) { "[S/n]" } else { "[s/N]" }
    $raw = Read-Host "$prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
    return $raw.Trim().ToLower() -in @('s', 'si', 'sí', 'y', 'yes')
}

# El timeout de cada tarea esta en SEGUNDOS en la config; el menu lo pide
# en minutos.
function Get-TaskMinutes($task) {
    return [math]::Floor($task.ElapsedTime / 60)
}

function Read-ValueOrDefault($prompt, $default) {
    $raw = Read-Host "$prompt (default: $default)"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $default }
    return $raw
}

# Devuelve un [string[]] de hostnames, eligiendo entre un archivo de
# imports\, una ruta escrita a mano, o pegados directamente en consola.
function Get-ComputerListInteractive {
    param([string]$ImportsPath)

    $files = @(Get-ChildItem -Path $ImportsPath -Filter '*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)

    $options = @()
    $options += "Elegir un archivo de imports\"
    $options += "Escribir la ruta de un archivo"
    $options += "Pegar hostnames directamente (uno por línea, línea vacía para terminar)"

    $choice = Read-MenuChoice -options $options -prompt "¿De dónde sale la lista de equipos?"

    switch ($choice) {
        1 {
            if ($files.Count -eq 0) {
                Write-Host "No hay archivos .txt en $ImportsPath" -ForegroundColor Yellow
                return Get-ComputerListInteractive -ImportsPath $ImportsPath
            }
            $fileNames = $files | ForEach-Object { $_.Name }
            $idx = Read-MenuChoice -options $fileNames -prompt "Archivo"
            return Read-ComputerList -Path $files[$idx - 1].FullName
        }
        2 {
            $path = Read-Host "Ruta del archivo"
            return Read-ComputerList -Path $path
        }
        3 {
            Write-Host "Pegá los hostnames (Enter en una línea vacía para terminar):"
            $lines = @()
            while ($true) {
                $line = Read-Host
                if ([string]::IsNullOrWhiteSpace($line)) { break }
                $lines += $line.Trim()
            }
            return @($lines | Select-Object -Unique)
        }
    }
    return @()
}

function Show-Preview($computerList) {
    Write-Host ""
    Write-Host "Equipos seleccionados: $($computerList.Count)" -ForegroundColor Cyan
    $preview = $computerList | Select-Object -First 5
    $preview | ForEach-Object { Write-Host "  - $_" }
    if ($computerList.Count -gt 5) {
        Write-Host "  ... y $($computerList.Count - 5) más"
    }
}

# ---------------------------------------------------------------------
# Acciones del menú (una por tarea)
# ---------------------------------------------------------------------

function Invoke-MenuDeployApp {
    Write-Title "Desplegar aplicación"
    $config = Get-DeploymentConfig
    $task = $config.Tasks.deployapp
    $computers = Get-ComputerListInteractive -ImportsPath $config.ImportsPath
    if ($computers.Count -eq 0) { Write-Host "Lista vacía, cancelado." -ForegroundColor Yellow; return }
    Show-Preview $computers

    $itemName = Read-Host "Nombre del ítem (solo para el log, ej. 'GoogleChrome')"
    $command = Read-Host "Comando completo a ejecutar (ej. `"\\...\Deploy-Application.exe`")"
    $throttle = [int](Read-ValueOrDefault "Throttle limit" $task.ThrottleLimit)
    $updateTenable = Read-YesNo "¿Actualizar Tenable después del deploy?" $false

    if (-not (Read-YesNo "¿Confirmar ejecución en $($computers.Count) equipos?")) { return }

    Invoke-DeployApp -ComputerList $computers -Commands @($command) -ItemNames @($itemName) `
        -ThrottleLimit $throttle -UpdateTenableAfter:$updateTenable -ShowProgress | Out-Null
}

function Invoke-MenuCopyFiles {
    Write-Title "Copiar archivos"
    $config = Get-DeploymentConfig
    $task = $config.Tasks.copyfiles
    $computers = Get-ComputerListInteractive -ImportsPath $config.ImportsPath
    if ($computers.Count -eq 0) { Write-Host "Lista vacía, cancelado." -ForegroundColor Yellow; return }
    Show-Preview $computers

    $source = Read-Host "Carpeta origen (ruta UNC del repositorio)"
    $itemName = Read-Host "Nombre del archivo/carpeta a copiar"
    $remoteSub = Read-ValueOrDefault "Ruta relativa destino (bajo C$ del equipo remoto)" $task.RemoteSubPath
    $recurse = Read-YesNo "¿Copiar recursivamente (carpeta completa)?" $false
    $throttle = [int](Read-ValueOrDefault "Throttle limit" $task.ThrottleLimit)

    if (-not (Read-YesNo "¿Confirmar ejecución en $($computers.Count) equipos?")) { return }

    Invoke-CopyFiles -ComputerList $computers -SourcePaths @($source) -ItemNames @($itemName) `
        -RemoteSubPaths @($remoteSub) -Recurse @($recurse) -ThrottleLimit $throttle -ShowProgress | Out-Null
}

function Invoke-MenuCopyInstall {
    Write-Title "Copiar e instalar"
    $config = Get-DeploymentConfig
    $task = $config.Tasks.copyinstall
    $computers = Get-ComputerListInteractive -ImportsPath $config.ImportsPath
    if ($computers.Count -eq 0) { Write-Host "Lista vacía, cancelado." -ForegroundColor Yellow; return }
    Show-Preview $computers

    $source = Read-Host "Carpeta origen del instalador"
    $itemName = Read-Host "Nombre del instalador/carpeta"
    $remoteSub = Read-ValueOrDefault "Ruta relativa destino" $task.RemoteSubPath
    $installCommand = Read-Host "Comando de instalación a ejecutar tras copiar"
    $minutes = [int](Read-ValueOrDefault "Timeout en minutos (0 = sin timeout)" (Get-TaskMinutes $task))
    $throttle = [int](Read-ValueOrDefault "Throttle limit" $task.ThrottleLimit)

    if (-not (Read-YesNo "¿Confirmar ejecución en $($computers.Count) equipos?")) { return }

    Invoke-CopyInstall -ComputerList $computers -SourcePath $source -ItemName $itemName `
        -RemoteSubPath $remoteSub -InstallCommand $installCommand -ElapsedTime ($minutes * 60) `
        -ThrottleLimit $throttle -ShowProgress | Out-Null
}

function Invoke-MenuRemoteCommand {
    Write-Title "Ejecutar comando remoto"
    $config = Get-DeploymentConfig
    $task = $config.Tasks.remotecmd
    $computers = Get-ComputerListInteractive -ImportsPath $config.ImportsPath
    if ($computers.Count -eq 0) { Write-Host "Lista vacía, cancelado." -ForegroundColor Yellow; return }
    Show-Preview $computers

    $command = Read-Host "Comando a ejecutar en cada equipo"
    $minutes = [int](Read-ValueOrDefault "Timeout en minutos (0 = sin timeout)" (Get-TaskMinutes $task))
    $throttle = [int](Read-ValueOrDefault "Throttle limit" $task.ThrottleLimit)
    $updateTenable = Read-YesNo "¿Actualizar Tenable después de correr el comando?" $false

    if (-not (Read-YesNo "¿Confirmar ejecución en $($computers.Count) equipos?")) { return }

    Invoke-RemoteCommand -ComputerList $computers -Command $command -RunAsSystem -Elevated `
        -ElapsedTime ($minutes * 60) -ThrottleLimit $throttle -UpdateTenableAfter:$updateTenable -ShowProgress | Out-Null
}

function Invoke-MenuKbDeployment {
    Write-Title "Instalar KB de Windows"
    $config = Get-DeploymentConfig
    $task = $config.Tasks.kb
    $computers = Get-ComputerListInteractive -ImportsPath $config.ImportsPath
    if ($computers.Count -eq 0) { Write-Host "Lista vacía, cancelado." -ForegroundColor Yellow; return }
    Show-Preview $computers

    $kbPatchRaw = Read-Host "Número(s) de KB esperado(s), separados por coma (ej. KB5099414)"
    $kbPatch = @($kbPatchRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $kbFolder = Read-Host "Carpeta de instalación bajo Updates\ (formato YYYY-MM, ej. 2026-09)"
    $minutes = [int](Read-ValueOrDefault "Timeout en minutos" (Get-TaskMinutes $task))
    $throttle = [int](Read-ValueOrDefault "Throttle limit" $task.ThrottleLimit)

    if (-not (Read-YesNo "¿Confirmar instalación de $($kbPatch -join ', ') en $($computers.Count) equipos?")) { return }

    Invoke-KbDeployment -ComputerList $computers -KbPatch $kbPatch -KbFolder $kbFolder `
        -ElapsedTime ($minutes * 60) -ThrottleLimit $throttle -ShowProgress | Out-Null
}

function Invoke-MenuOfficeUpdate {
    Write-Title "Actualizar Office"
    $config = Get-DeploymentConfig
    $task = $config.Tasks.office
    $computers = Get-ComputerListInteractive -ImportsPath $config.ImportsPath
    if ($computers.Count -eq 0) { Write-Host "Lista vacía, cancelado." -ForegroundColor Yellow; return }
    Show-Preview $computers

    $targetVersion = Read-Host "Versión mínima esperada de Office (ej. 16.0.19929.20220)"
    $minutes = [int](Read-ValueOrDefault "Timeout en minutos (0 = sin timeout)" (Get-TaskMinutes $task))
    $throttle = [int](Read-ValueOrDefault "Throttle limit" $task.ThrottleLimit)
    $updateTenable = Read-YesNo "¿Actualizar Tenable después?" $false

    if (-not (Read-YesNo "¿Confirmar ejecución en $($computers.Count) equipos?")) { return }

    Invoke-OfficeUpdate -ComputerList $computers -TargetVersion $targetVersion `
        -ElapsedTime ($minutes * 60) -ThrottleLimit $throttle -UpdateTenableAfter:$updateTenable -ShowProgress | Out-Null
}

function Invoke-MenuNessusScan {
    Write-Title "Disparar scan de Nessus/Tenable"
    $config = Get-DeploymentConfig
    $task = $config.Tasks.nessus
    $computers = Get-ComputerListInteractive -ImportsPath $config.ImportsPath
    if ($computers.Count -eq 0) { Write-Host "Lista vacía, cancelado." -ForegroundColor Yellow; return }
    Show-Preview $computers
    $throttle = [int](Read-ValueOrDefault "Throttle limit" $task.ThrottleLimit)

    if (-not (Read-YesNo "¿Confirmar ejecución en $($computers.Count) equipos?")) { return }

    Invoke-NessusScan -ComputerList $computers -ThrottleLimit $throttle -ShowProgress | Out-Null
}

function Show-RecentLogs {
    Write-Title "Logs recientes"
    $config = Get-DeploymentConfig
    $logs = @(Get-ChildItem -Path $config.LogsPath -Filter '*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($logs.Count -eq 0) { Write-Host "No hay logs todavía."; return }

    $names = $logs | ForEach-Object { "$($_.Name)  ($($_.LastWriteTime))" }
    $idx = Read-MenuChoice -options $names -prompt "¿Qué log querés ver (últimas 40 líneas)?"
    Get-Content -Path $logs[$idx - 1].FullName -Tail 40
}

# ---------------------------------------------------------------------
# Loop principal
# ---------------------------------------------------------------------

$menuOptions = @(
    "Desplegar aplicación"
    "Copiar archivos"
    "Copiar e instalar"
    "Ejecutar comando remoto"
    "Instalar KB de Windows"
    "Actualizar Office"
    "Disparar scan de Nessus/Tenable"
    "Ver logs recientes"
    "Salir"
)

while ($true) {
    Write-Title "Deployment Toolkit"
    $choice = Read-MenuChoice -options $menuOptions -prompt "¿Qué querés hacer?"

    try {
        switch ($choice) {
            1 { Invoke-MenuDeployApp }
            2 { Invoke-MenuCopyFiles }
            3 { Invoke-MenuCopyInstall }
            4 { Invoke-MenuRemoteCommand }
            5 { Invoke-MenuKbDeployment }
            6 { Invoke-MenuOfficeUpdate }
            7 { Invoke-MenuNessusScan }
            8 { Show-RecentLogs }
            9 { Write-Host "Chau."; return }
        }
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host ""
    Read-Host "Enter para volver al menú"
}
