# Classes/KbWindows.ps1
#
# Extiende BaseDeploy con el flujo de instalación de parches KB de Windows:
# consultar versión instalada, comparar contra la esperada, desplegar si
# falta, y (opcionalmente) disparar un scan de Tenable al finalizar.

class KbWindows : BaseDeploy {

    KbWindows([string]$Equipo, [string]$LogPath, [string]$LogMutexName) : base($Equipo, $LogPath, $LogMutexName) {
        $this.WriteLogSafe("INICIANDO KB Windows")
    }
    
    [pscustomobject] GetKBVersion(
            [int]$elapsedTime
        ) {
        $this.WriteLogSafe("Consultando KB Version ...")
        $result = $null
        try {
            $cmd = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-HotFix | ForEach-Object { $_.HotFixID }"'
            $result = $this.InvokePsExec($cmd, $true, $true, $elapsedTime)
            if (-not $result -or $result.ExitCode -ne 0) {
                throw "Error en ejecucion: ExitCode $($result.ExitCode)"
            }
            if (-not $result.StdOut) {
                throw "Salida vacía al consultar versión de KB"
            }

            $result.StdOut = @(
                $result.StdOut -split '[,\r\n]+' |
                ForEach-Object { $_.Trim().ToUpper() } |
                Where-Object { $_ -ne '' }
            )

            if (-not $result.StdOut -or $result.StdOut.Count -eq 0) {
                throw "$($this.Equipo) No se pudo parsear la salida: $result.StdOut"
            }            

            $this.WriteLogSafe("RESULTADO: $(($result.StdOut -join ",") -split '\s*,\s*')")
            return [pscustomobject]@{
                Success  = $true
                ExitCode = $result.ExitCode
                StdOut   = $result.StdOut
                StdErr   = $result.StdErr
            }
        }
        catch {
            $msg = "ERROR obteniendo version: $($_.Exception.Message)"
            $this.WriteLogSafe($msg)

            return [pscustomobject]@{
                Success      = $false
                ExitCode     = if ($result) { $result.ExitCode } else { -1 }
                StdOut       = if ($result) { $result.StdOut } else { "" }
                StdErr       = if ($result) { $result.StdErr } else { "" }
                ErrorMessage = $msg
            }
        }
    }

    [pscustomobject] CompareKb(
        [string[]]$kbGetted,
        [string[]]$kbPatch
    ) {
        $this.WriteLogSafe("Comparando KB Version ...")
        $kbGetted = $kbGetted |
            ForEach-Object { $_.ToString().Trim().ToUpper() }
        $kbPatch = $kbPatch |
            ForEach-Object { $_.ToString().Trim().ToUpper() }

        $this.WriteLogSafe("CompareKB:")

        if(-not ($kbGetted -and $kbPatch)) {
            return [pscustomobject]@{
                Success      = $false
                ExitCode     = -1
                StdOut       = [pscustomobject]@{ kbGetted = $kbGetted; kbPatch = $kbPatch }
                StdErr       = "Error Objetos vacios: {kbGetted: $kbGetted, kbPatch: $kbPatch}"
                ErrorMessage = "Objetos vacios {kbGetted: $kbGetted, kbPatch: $kbPatch} " 
            } 
        }        
                
        $missing = $kbPatch | Where-Object {
            $_ -notin $kbGetted
        }

        if($missing.Count -gt 0) {
            return [pscustomobject]@{
                Success      = $false
                ExitCode     = -1
                StdOut       = [pscustomobject]@{ kbGetted = $kbGetted; kbPatch = $kbPatch }
                StdErr       = "KB No Instalado: {kbGetted: $kbGetted, kbPatch: $kbPatch}"
                ErrorMessage = "KB No Instalado {kbGetted: $kbGetted, kbPatch: $kbPatch} " 
            }  
        }
        return [pscustomobject]@{
            Success      = $true
            ExitCode     = 0
            StdOut       = [pscustomobject]@{ kbGetted = $kbGetted; kbPatch = $kbPatch }
            StdErr       = ""
            ErrorMessage = ""
        }
    }
    
    # OJO: los parametros de un metodo de clase NO admiten valor por defecto.
    # PowerShell acepta la sintaxis pero los ignora (HasDefaultValue queda en
    # False), asi que un "= ..." aca es codigo muerto que ademas engania al
    # que lee: hay que pasar SIEMPRE los 4 argumentos. Antes habia defaults
    # escritos con la ruta del repositorio adentro; ahora installPath llega
    # desde config\config.psd1 via Invoke-KbDeployment.
    [pscustomobject] DeployKB(
        [string]$kbFolder,
        [int[]]$SuccessCodes,
        [string]$installPath,
        [int]$elapsedTime
    ) {
        $this.WriteLogSafe("Inicio Deploy KB Version ...")
        $result = $null
        try {
            if ([string]::IsNullOrWhiteSpace($installPath)) {
                throw "Falta UpdatesPath en config\config.psd1 (carpeta de actualizaciones del repositorio)."
            }
            $this.WriteLogSafe("INSTALANDO KB $kbFolder")
            $fullPath = "$installPath\$kbFolder\install.cmd"
            $this.WriteLogSafe("Ruta install: $fullPath")
            
            $result = $this.DeployApp($fullPath, $SuccessCodes,$elapsedTime)

            if (-not $result.Success) {
                throw "Fallo en DeployApp: ExitCode $($result.ExitCode)"
            }
            return [pscustomobject]@{
                Success  = $true
                ExitCode = $result.ExitCode
                StdOut   = $result.StdOut
                StdErr   = $result.StdErr
            }
        }
        catch {
            $msg = "ERROR DeployKB: $($_.Exception.Message)"
            $this.WriteLogSafe($msg)
            return [pscustomobject]@{
                Success      = $false
                ExitCode     = if ($result) { $result.ExitCode } else { -1 }
                StdOut       = if ($result) { $result.StdOut } else { "" }
                StdErr       = if ($result) { $result.StdErr } else { "" }
                ErrorMessage = $msg
            }
        }
    }

    # Mismo caso que DeployKB: sin defaults, los 5 argumentos son obligatorios.
    [pscustomobject] RunKbWindows(
        [string[]]$kbPatch,
        [string]$kbFolderDeploy,
        [int[]]$SuccessCodesDeploy,
        [string]$installPathDeploy,
        [int]$elapsedTime
    ){
        $this.WriteLogSafe("Iniciando Proceso KB Version ...")
        $result = $null
        try {            
            $resultPingRemote = $this.TestPingEquipo()
            if (-not $resultPingRemote.Success) {
                throw $($resultPingRemote.msg)
            }
            
            $resultGetKb = $this.GetKBVersion($elapsedTime)
            $result = $resultGetKb
            if(-not $resultGetKb.Success){
                throw "GetKBVersion Fallo: $($resultGetKb.StdErr)"
            }

            $resultCompareKB = $this.CompareKb($resultGetKb.StdOut, $kbPatch)
            $result = $resultCompareKB
            if(-not $resultCompareKB.Success){
                $resultKbWindows = $this.DeployKB($kbFolderDeploy, $SuccessCodesDeploy, $installPathDeploy, $elapsedTime)
                $result = $resultKbWindows
                if(-not $resultKbWindows.Success){
                    throw "DeployKB fallo: $($resultKbWindows.StdErr)"
                }
            }             
            
            $this.WriteLogSafe("KB instalado: kbGetted: $($resultCompareKB.StdOut.kbGetted), kbPatch: $($resultCompareKB.StdOut.kbPatch)")
            $resultTenable = $this.UpdateTenable()

            if(-not $resultTenable.Success ) {
                return [pscustomobject]@{
                    Success  = $true
                    ExitCode = 0
                    StdOut   = "Proceso Deploy KB Completado; Tenable no Actualizado"
                    StdErr   = "Tenable no Actualizado"
                }
            }
            return [pscustomobject]@{
                Success  = $true
                ExitCode = 0
                StdOut   = "Proceso Deploy KB Completado Correctamente"
                StdErr   = ""
            }            
        }
        catch {
            $msg = "ERROR KbWindows: $($_.Exception.Message)"
            $this.WriteLogSafe($msg)
            return [pscustomobject]@{
                Success      = $false
                ExitCode     = if ($result) { $result.ExitCode } else { -1 }
                StdOut       = if ($result) { $result.StdOut } else { "" }
                StdErr       = if ($result) { $result.StdErr } else { "" }
                ErrorMessage = $msg
            }
        }
    }
}
