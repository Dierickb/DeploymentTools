# Public/Get-DeploymentTaskCatalog.ps1
#
# Catalogo declarativo de las tareas: que funcion del modulo invoca cada
# una, con que archivo de imports\ y que .log se corresponde, y que campos
# tiene su formulario.
#
# Existe para que las DOS interfaces (Deploy-Gui.ps1 en WPF y Deploy-Web.ps1
# en el navegador) lean exactamente la misma definicion. Antes el catalogo
# vivia dentro del .ps1 de la GUI; al sumar la segunda interfaz eso se
# habria duplicado, y dos copias de lo mismo es justo el problema que este
# proyecto vino a resolver (eran 7 scripts casi identicos). Agregar una
# tarea nueva se hace aca una sola vez y aparece en ambas.
#
# Type de cada field:
#   Text    -> [string]
#   List    -> [string[]]  (se separa por coma)
#   Codes   -> [int[]]     (se separa por coma)
#   Int     -> [int]
#   Minutes -> [int]       (se ingresa en minutos, se pasa en SEGUNDOS, que
#                           es la unidad que espera -ElapsedTime)
#   Switch  -> [switch]    (solo se manda si esta tildado)
#   Bool    -> [bool]      (se manda siempre, tildado o no)
#   TextArr -> [string[]] de un solo elemento (para -SourcePaths etc.)
#   BoolArr -> [bool[]] de un solo elemento (para -Recurse)
#
# Hay una prueba que verifica que cada Name de cada field sea un parametro
# real de la funcion que la tarea invoca.
#
# Lo que NO se escribe aca: archivo de imports\, .log, throttle, timeouts,
# rutas por defecto, success codes y patrones de validacion. Todo eso sale
# de la config (Deployment.Constants.psd1 + config.psd1), asi que la GUI, la
# web, el menu, scripts\ y el modulo usan el mismo valor. Aca solo queda lo
# propio del formulario: etiquetas, textos de ayuda y tipo de cada campo.
function Get-DeploymentTaskCatalog {
    [CmdletBinding()]
    param(
        # La config ya resuelta. Las interfaces pasan la que ya leyeron; si no
        # viene, se lee aca.
        [object]$Config
    )

    if (-not $Config) { $Config = Get-DeploymentConfig -WarningAction SilentlyContinue }
    $t = $Config.Tasks
    # Los campos 'Minutes' se muestran en minutos; ElapsedTime esta en segundos.
    $enMinutos = { param($task) [string][math]::Floor($task.ElapsedTime / 60) }

    return @(
        [ordered]@{
            Id = 'deployapp'; Label = 'Desplegar aplicacion'; Function = 'Invoke-DeployApp'
            ImportFile = $t.deployapp.ImportFile; LogFile = $t.deployapp.LogFile; Throttle = $t.deployapp.ThrottleLimit
            Desc = 'Ejecuta el instalador de una aplicacion en cada equipo y valida el codigo de salida contra la lista de codigos de exito.'
            Fields = @(
                [ordered]@{ Name = 'ItemNames'; Label = 'Nombre del item'; Type = 'TextArr'; Default = 'GoogleChrome'; Hint = 'solo para el log'; Required = $true }
                [ordered]@{ Name = 'Commands'; Label = 'Comando'; Type = 'TextArr'; Default = ''; Hint = 'ruta completa al Deploy-Application.exe'; Required = $true; Wide = $true }
                [ordered]@{ Name = 'SuccessCodes'; Label = 'Success codes'; Type = 'Codes'; Default = ($Config.DefaultSuccessCodes -join ', ') }
                [ordered]@{ Name = 'ElapsedTime'; Label = 'Timeout'; Type = 'Minutes'; Default = (& $enMinutos $t.deployapp); Hint = 'minutos, 0 = sin limite' }
                [ordered]@{ Name = 'UpdateTenableAfter'; Label = 'Actualizar Tenable al terminar'; Type = 'Switch'; Default = $false }
            )
        }
        [ordered]@{
            Id = 'copyfiles'; Label = 'Copiar archivos'; Function = 'Invoke-CopyFiles'
            ImportFile = $t.copyfiles.ImportFile; LogFile = $t.copyfiles.LogFile; Throttle = $t.copyfiles.ThrottleLimit
            Desc = 'Copia un archivo o carpeta a una ruta remota bajo C$ de cada equipo, y verifica que haya llegado a destino.'
            Fields = @(
                [ordered]@{ Name = 'SourcePaths'; Label = 'Carpeta origen'; Type = 'TextArr'; Default = ''; Required = $true; Wide = $true }
                [ordered]@{ Name = 'ItemNames'; Label = 'Nombre del archivo o carpeta'; Type = 'TextArr'; Default = ''; Required = $true }
                [ordered]@{ Name = 'RemoteSubPaths'; Label = 'Ruta destino (bajo C$)'; Type = 'TextArr'; Default = $t.copyfiles.RemoteSubPath; Required = $true }
                [ordered]@{ Name = 'Recurse'; Label = 'Copiar recursivamente'; Type = 'BoolArr'; Default = $false }
            )
        }
        [ordered]@{
            Id = 'copyinstall'; Label = 'Copiar e instalar'; Function = 'Invoke-CopyInstall'
            ImportFile = $t.copyinstall.ImportFile; LogFile = $t.copyinstall.LogFile; Throttle = $t.copyinstall.ThrottleLimit
            Desc = "Copia un instalador y lo ejecuta remotamente en un solo paso. Throttle $($t.copyinstall.ThrottleLimit) por defecto: suele ser una tarea pesada."
            Fields = @(
                [ordered]@{ Name = 'SourcePath'; Label = 'Carpeta origen del instalador'; Type = 'Text'; Default = ''; Required = $true; Wide = $true }
                [ordered]@{ Name = 'ItemName'; Label = 'Nombre del instalador'; Type = 'Text'; Default = ''; Required = $true }
                [ordered]@{ Name = 'RemoteSubPath'; Label = 'Ruta destino (bajo C$)'; Type = 'Text'; Default = $t.copyinstall.RemoteSubPath }
                [ordered]@{ Name = 'InstallCommand'; Label = 'Comando de instalacion'; Type = 'Text'; Default = ''; Required = $true; Wide = $true }
                [ordered]@{ Name = 'ElapsedTime'; Label = 'Timeout'; Type = 'Minutes'; Default = (& $enMinutos $t.copyinstall); Hint = 'minutos, 0 = sin limite' }
            )
        }
        [ordered]@{
            Id = 'remotecmd'; Label = 'Comando remoto'; Function = 'Invoke-RemoteCommand'
            ImportFile = $t.remotecmd.ImportFile; LogFile = $t.remotecmd.LogFile; Throttle = $t.remotecmd.ThrottleLimit
            Desc = 'Ejecuta un comando arbitrario via PsExec. Comparar version y actualizar Tenable son opcionales explicitos, no comportamiento fijo.'
            Fields = @(
                [ordered]@{ Name = 'Command'; Label = 'Comando'; Type = 'Text'; Default = ''; Required = $true; Wide = $true }
                [ordered]@{ Name = 'RunAsSystem'; Label = 'Ejecutar como SYSTEM'; Type = 'Switch'; Default = $true }
                [ordered]@{ Name = 'Elevated'; Label = 'Elevado'; Type = 'Switch'; Default = $true }
                [ordered]@{ Name = 'ElapsedTime'; Label = 'Timeout'; Type = 'Minutes'; Default = (& $enMinutos $t.remotecmd); Hint = 'minutos, 0 = sin limite' }
                [ordered]@{ Name = 'CompareVersion'; Label = 'Comparar version de la salida'; Type = 'Switch'; Default = $false }
                [ordered]@{ Name = 'MinVersion'; Label = 'Version minima'; Type = 'Text'; Default = ''; Hint = 'requerido si comparas version' }
                [ordered]@{ Name = 'UpdateTenableAfter'; Label = 'Actualizar Tenable al terminar'; Type = 'Switch'; Default = $false }
            )
        }
        [ordered]@{
            Id = 'kb'; Label = 'KB de Windows'; Function = 'Invoke-KbDeployment'
            ImportFile = $t.kb.ImportFile; LogFile = $t.kb.LogFile; Throttle = $t.kb.ThrottleLimit
            Desc = 'Consulta los KB instalados, compara contra el esperado, y despliega el parche solo si falta.'
            Fields = @(
                [ordered]@{ Name = 'KbPatch'; Label = 'KB esperado(s)'; Type = 'List'; Default = ''; Hint = 'separados por coma'; Required = $true }
                [ordered]@{ Name = 'KbFolder'; Label = 'Carpeta de instalacion'; Type = 'Text'; Default = (Get-Date -Format $Config.Validation.KbFolderDefaultFormat); Hint = 'formato YYYY-MM'; Required = $true
                            Pattern = $Config.Validation.KbFolderPattern
                            PatternMsg = "Formato invalido. Debe ser YYYY-MM (ej. 2026-09), opcionalmente con dia y sufijo (2026-08-24h2)." }
                [ordered]@{ Name = 'ElapsedTime'; Label = 'Timeout'; Type = 'Minutes'; Default = (& $enMinutos $t.kb); Hint = 'minutos' }
            )
        }
        [ordered]@{
            Id = 'office'; Label = 'Actualizar Office'; Function = 'Invoke-OfficeUpdate'
            ImportFile = $t.office.ImportFile; LogFile = $t.office.LogFile; Throttle = $t.office.ThrottleLimit
            Desc = 'Dos modos: por version minima (actualiza solo los equipos por debajo de la version que indiques) o forzado (actualiza todos sin consultar que tienen instalado). Opcionalmente podes fijar la version exacta a la que llevarlos.'
            Fields = @(
                # Ya NO es obligatoria: si se tilda "Forzar actualizacion", el
                # criterio pasa a ser "actualizar todos" y esta version no se usa.
                # La regla esta en Test-Parameters, y la funcion del modulo la
                # valida tambien por su cuenta.
                [ordered]@{ Name = 'TargetVersion'; Label = 'Version minima esperada'; Type = 'Text'; Default = ''
                            Hint = 'solo actualiza los equipos por debajo de esta version'
                            Pattern = $Config.Validation.VersionPattern
                            PatternMsg = "Tiene que ser una version valida, ej. 16.0.19929.20220" }
                [ordered]@{ Name = 'ForceUpdate'; Label = 'Forzar actualizacion (no comparar la version instalada)'; Type = 'Switch'; Default = $false }
                [ordered]@{ Name = 'UpdateToVersion'; Label = 'Actualizar exactamente a esta version'; Type = 'Text'; Default = ''
                            Hint = 'opcional, vacio = la ultima del canal'
                            Pattern = $Config.Validation.VersionPattern
                            PatternMsg = "Tiene que ser una version valida, ej. 16.0.19029.20244" }
                # Bool, no Switch: -ForceAppShutdown es [bool] en Invoke-OfficeUpdate
                # y su default es $true. Con un Switch, destildarlo simplemente no
                # mandaria el parametro y volveria a ganar el default, o sea, no
                # se podria desactivar nunca.
                [ordered]@{ Name = 'ForceAppShutdown'; Label = 'Forzar cierre de apps de Office'; Type = 'Bool'; Default = $true }
                [ordered]@{ Name = 'ElapsedTime'; Label = 'Timeout'; Type = 'Minutes'; Default = (& $enMinutos $t.office); Hint = 'minutos, 0 = sin limite' }
                [ordered]@{ Name = 'UpdateTenableAfter'; Label = 'Actualizar Tenable al terminar'; Type = 'Switch'; Default = $false }
            )
        }
        [ordered]@{
            Id = 'nessus'; Label = 'Scan Nessus/Tenable'; Function = 'Invoke-NessusScan'
            ImportFile = $t.nessus.ImportFile; LogFile = $t.nessus.LogFile; Throttle = $t.nessus.ThrottleLimit
            Desc = 'Dispara un scan del agente de Tenable/Nessus en cada equipo. No tiene parametros propios mas alla del throttle.'
            Fields = @()
        }
        [ordered]@{
            Id = 'ping'; Label = 'Verificar conectividad (ping)'; Function = 'Invoke-PingCheck'
            ImportFile = $t.ping.ImportFile; LogFile = $t.ping.LogFile; Throttle = $t.ping.ThrottleLimit
            Desc = 'Solo hace ping a cada equipo, sin copiar ni ejecutar nada. OK = en red; Fallidos = sin respuesta, con el motivo. Click en cada contador para ver la lista y copiar los hostnames.'
            Fields = @()
        }
    )
}
