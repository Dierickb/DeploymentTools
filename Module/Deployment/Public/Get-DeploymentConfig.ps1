# Public/Get-DeploymentConfig.ps1
#
# Config centralizada. Antes, valores como la ruta del repositorio, los
# codigos de exito de instalacion o los limites de concurrencia estaban
# repetidos (y a veces ligeramente distintos) entre los 7 scripts de
# execute\. Ahora viven en UN solo archivo editable: config\config.psd1.
#
# NINGUN dato del entorno esta hardcodeado en el codigo. Las rutas del
# repositorio, la ruta del agente de Nessus y el UUID del scan vienen
# SIEMPRE de config\config.psd1 y aca quedan vacios a proposito: si falta
# uno, la tarea que lo necesita falla con un mensaje que dice exactamente
# que completar y donde, en vez de apuntar en silencio a un servidor que no
# es. Ver config\config.example.psd1 para el formato de cada valor.
#
# Es publica porque los puntos de entrada (Deploy-Gui.ps1, Deploy-Menu.ps1,
# scripts\run_*.ps1) la necesitan antes de poder llamar a cualquier tarea.
function Get-DeploymentConfig {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    $root = Get-DeploymentRoot
    if (-not $ConfigPath) {
        $ConfigPath = Join-Path $root 'config\config.psd1'
    }

    $defaults = @{
        # --- Valores propios del entorno: se completan en config.psd1 ---

        # Raiz del repositorio de instaladores.
        #   Formato: '\\<servidor-o-ip>\<recurso>'
        RepositoryRoot       = ''

        # Subcarpeta con las actualizaciones/KB. Adentro se espera
        # <UpdatesPath>\<carpeta-YYYY-MM>\install.cmd
        #   Formato: '\\<servidor-o-ip>\<recurso>\InstallApps\Updates'
        UpdatesPath          = ''

        # Ruta LOCAL del agente de Nessus/Tenable en los equipos remotos.
        #   Formato: 'C:\Program Files\Tenable\Nessus Agent\nessuscli.exe'
        NessusPath           = ''

        # UUID del scan de Tenable a disparar.
        #   Formato: el GUID que entrega la consola de Tenable.
        NessusScanUUID       = ''

        # --- Valores estructurales: sirven igual sin tocarlos ---

        DefaultThrottleLimit = 5
        DefaultSuccessCodes  = @(0, 3010, 1641, 1707, 2359302)
        DefaultElapsedTime   = 0
        ImportsPath          = Join-Path $root 'imports'
        LogsPath             = Join-Path $root 'logs'
    }

    if (Test-Path $ConfigPath) {
        try {
            $userConfig = Import-PowerShellDataFile -Path $ConfigPath
            foreach ($key in $userConfig.Keys) {
                $defaults[$key] = $userConfig[$key]
            }
        }
        catch {
            Write-Warning "No se pudo leer $ConfigPath ($($_.Exception.Message)); se usan los valores por defecto."
        }
    }
    else {
        Write-Warning "No existe $ConfigPath. Copia config\config.example.psd1 a config\config.psd1 y completa los valores de tu entorno."
    }

    $defaults['Root'] = $root
    return [pscustomobject]$defaults
}
