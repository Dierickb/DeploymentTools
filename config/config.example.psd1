@{
    # -----------------------------------------------------------------
    # Copiar este archivo a config\config.psd1 y completar los valores.
    #
    # config.psd1 NO deberia versionarse ni salir del equipo: es el unico
    # lugar del proyecto donde viven los datos del entorno (servidores,
    # UUID del scan). El codigo no tiene ninguno hardcodeado.
    #
    # Solo se pueden poner aca los valores AJUSTABLES: los de la seccion
    # Tunable de Module\Deployment\Deployment.Constants.psd1, que es donde
    # esta el default de cada uno. Cualquier otra clave se ignora con un
    # aviso.
    # -----------------------------------------------------------------

    # Raiz del repositorio de instaladores.
    #   Formato: '\\<servidor-o-ip>\<recurso>'
    RepositoryRoot       = ''

    # Subcarpeta donde viven las actualizaciones/KB. El toolkit arma
    # <UpdatesPath>\<carpeta>\install.cmd, donde <carpeta> es lo que se pasa
    # como -KbFolder (formato YYYY-MM).
    #   Formato: '\\SERVIDOR\Repository\InstallApps\Updates'
    UpdatesPath          = ''

    # Ruta LOCAL del agente de Nessus/Tenable EN LOS EQUIPOS REMOTOS.
    #   Formato: 'C:\Program Files\Tenable\Nessus Agent\nessuscli.exe'
    NessusPath           = 'C:\Program Files\Tenable\Nessus Agent\nessuscli.exe'

    # UUID del scan de Tenable que se dispara al terminar una tarea. Se saca
    # de la consola de Tenable.
    #   Formato: '00000000-0000-0000-0000-000000000000'
    NessusScanUUID       = ''

    # -----------------------------------------------------------------
    # De aca para abajo, todo es opcional: sin tocarlo, se usan los
    # defaults de Deployment.Constants.psd1. Descomentar solo lo que haga
    # falta cambiar. Los tiempos van en SEGUNDOS salvo que el nombre diga Ms.
    # -----------------------------------------------------------------

    # DefaultThrottleLimit = <equipos en paralelo por tarea>
    # DefaultSuccessCodes  = @(<codigos de salida que cuentan como exito>)
    # DefaultElapsedTime   = <timeout de psexec en segundos, 0 = sin timeout>

    # Por tarea (deployapp, copyfiles, copyinstall, remotecmd, kb, office,
    # nessus). Solo ThrottleLimit y ElapsedTime:
    # TaskDefaults = @{
    #     kb          = @{ ElapsedTime = <segundos> }
    #     copyinstall = @{ ThrottleLimit = <n>; ElapsedTime = <segundos> }
    # }

    # PsExecPath          = '<ruta a psexec.exe, si no esta en el PATH>'
    # OfficeC2RClientPath = '<ruta a OfficeC2RClient.exe en los equipos>'

    # PingTimeoutMs, LogMutexWaitMs, CopyVerifySettleSeconds,
    # CopyVerifyRetries, CopyVerifyIntervalSeconds, PsExecStreamWaitMs,
    # TenableTimeoutSeconds: tiempos internos, ver Deployment.Constants.psd1.
}
