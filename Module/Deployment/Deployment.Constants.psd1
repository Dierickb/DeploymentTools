# Deployment.Constants.psd1
#
# Unico lugar del proyecto donde viven los valores fijos del toolkit (los
# "magic strings"): nombres de log y de mutex de cada tarea, formatos,
# rutas estandar de Windows, timeouts internos, intervalos de las
# interfaces. Cada valor esta definido UNA sola vez; el modulo, el menu,
# scripts\, la GUI y la interfaz web lo leen de aca via Get-DeploymentConfig.
#
# Dos clases de valor:
#
#   Tunable   Defaults que config\config.psd1 PUEDE sobrescribir: datos del
#             entorno, timeouts, throttle, success codes y rutas de
#             herramientas. Get-DeploymentConfig ignora (con un aviso)
#             cualquier clave de config.psd1 que no este en esta seccion.
#
#   El resto  Fijo. NO se sobrescribe desde config.psd1. Ejemplo de por que:
#             si un config cambiara el nombre de mutex de una tarea mientras
#             otra corrida de esa tarea sigue abierta, las dos escribirian al
#             mismo log sin sincronizarse.
#
# Este archivo es codigo, no configuracion del entorno: se versiona. Los
# datos del entorno (servidores, UUID del scan) van en config\config.psd1.
@{
    Tunable = @{
        # --- Datos del entorno: vacios a proposito, se completan en config.psd1 ---
        RepositoryRoot            = ''
        UpdatesPath               = ''
        NessusPath                = ''
        NessusScanUUID            = ''

        # --- Carpetas del proyecto. Vacio = <raiz>\imports y <raiz>\logs ---
        ImportsPath               = ''
        LogsPath                  = ''

        # --- Defaults generales de las tareas ---
        DefaultThrottleLimit      = 5
        # 0=OK, 3010/1641/1707=reinicio pendiente, 2359302=ya instalado.
        DefaultSuccessCodes       = @(0, 3010, 1641, 1707, 2359302)
        # En SEGUNDOS. 0 = sin timeout.
        DefaultElapsedTime        = 0

        # --- Defaults por tarea: pisan a los generales de arriba ---
        # Solo se admiten ThrottleLimit y ElapsedTime (en SEGUNDOS). Una
        # tarea que no aparece usa DefaultThrottleLimit/DefaultElapsedTime.
        TaskDefaults              = @{
            # Copiar+instalar suele ser pesado: de a un equipo y 15 minutos.
            copyinstall = @{ ThrottleLimit = 1; ElapsedTime = 900 }
            kb          = @{ ElapsedTime = 600 }
        }

        # --- Herramientas ---
        PsExecPath                = 'psexec.exe'
        OfficeC2RClientPath       = 'C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeC2RClient.exe'

        # --- Tiempos internos de BaseDeploy ---
        PingTimeoutMs             = 2000
        # Espera maxima por el mutex del log; si se vence, la linea se descarta.
        LogMutexWaitMs            = 5000
        # Tras copiar: espera inicial y luego hasta N reintentos de Test-Path.
        CopyVerifySettleSeconds   = 2
        CopyVerifyRetries         = 30
        CopyVerifyIntervalSeconds = 1
        # Resguardo para leer stdout/stderr de psexec una vez que termino.
        PsExecStreamWaitMs        = 5000
        TenableTimeoutSeconds     = 420
    }

    # Identidad de cada tarea. Las claves son los Id del catalogo
    # (Get-DeploymentTaskCatalog). Cada tarea escribe en su propio .log con
    # su propio mutex: es lo que permite correr varias tareas a la vez.
    Tasks = @{
        deployapp   = @{ LogFile = 'deploy_app.log';     MutexName = 'Global\deploy_app';       ImportFile = 'deploy_app_computers.txt' }
        copyfiles   = @{ LogFile = 'copy_files.log';     MutexName = 'Global\copy_files';       ImportFile = 'copy_files_computers.txt';    RemoteSubPath = 'temp\RemoteInstall' }
        copyinstall = @{ LogFile = 'copy_install.log';   MutexName = 'Global\copy_install';     ImportFile = 'copy_install_computers.txt';  RemoteSubPath = 'temp' }
        remotecmd   = @{ LogFile = 'invoke_command.log'; MutexName = 'Global\invoke_command';   ImportFile = 'invokePsexec_computer.txt' }
        kb          = @{ LogFile = 'kb_deploy.log';      MutexName = 'Global\kb_deploy';        ImportFile = 'computers.txt' }
        office      = @{ LogFile = 'office_update.log';  MutexName = 'Global\office_update';    ImportFile = 'office_update_computers.txt' }
        nessus      = @{ LogFile = 'nessus_scan.log';    MutexName = 'Global\nessus_scan';      ImportFile = 'nessus_scan_computers.txt' }
        # No es una tarea del catalogo: la usa Invoke-SimulatedDeployment.
        simulation  = @{ LogFile = 'simulacion.log';     MutexName = 'Global\simulated_deploy'; ImportFile = '' }
    }

    Paths = @{
        ConfigFolder  = 'config'
        ConfigFile    = 'config.psd1'
        ImportsFolder = 'imports'
        LogsFolder    = 'logs'
    }

    Log = @{
        # Formato de la fecha al inicio de cada linea de log:
        #   <fecha> | <equipo> | <mensaje>
        DateFormat = 'yyyy-MM-dd HH:mm:ss'
    }

    Remote = @{
        # Recurso administrativo por el que se copia a \\<equipo>\<AdminShare>\...
        AdminShare      = 'C$'
        # Script que se ejecuta dentro de <UpdatesPath>\<KbFolder>\
        KbInstallScript = 'install.cmd'
    }

    Validation = @{
        # -KbFolder: YYYY-MM, opcionalmente con dia y sufijo (2026-08-24h2).
        KbFolderPattern       = '^\d{4}-\d{2}(-\d{2})?[a-z0-9]*$'
        # Formato de Get-Date con el que los formularios sugieren -KbFolder
        # (el mes en curso). Tiene que cumplir KbFolderPattern.
        KbFolderDefaultFormat = 'yyyy-MM'
        # Numero de version de 2 a 4 partes (16.0.19929.20220).
        VersionPattern  = '^\d+(\.\d+){1,3}$'
    }

    Office = @{
        VersionRegistryKey = 'HKLM:\Software\Microsoft\Office\ClickToRun\Configuration'
        VersionValueName   = 'VersionToReport'
    }

    Simulation = @{
        # Demora por equipo = DelayMs + un aleatorio de 0 a JitterMs.
        DelayMs     = 300
        JitterMs    = 700
        # Un equipo cuyo nombre matchee se reporta como fallido.
        FailPattern = '(?i)fail'
    }

    Runner = @{
        # Intervalo de sondeo de Invoke-ThrottledDeployment: normal, y con
        # una cola de progreso conectada (las interfaces, que muestran en vivo).
        PollMs     = 1000
        LivePollMs = 250
    }

    Ui = @{
        # Tareas distintas a la vez en la GUI y en la web (-MaxTareas).
        DefaultMaxTasks = 2
        WebPort         = 8787
        GuiPollMs       = 250
        WebPollMs       = 500
        # Cuanto dura el "Copiado" del boton "Copiar hostnames".
        CopyFeedbackMs  = 1500
    }
}
