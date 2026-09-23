@{
    # -----------------------------------------------------------------
    # Copiar este archivo a config\config.psd1 y completar los valores.
    #
    # config.psd1 NO deberia versionarse ni salir del equipo: es el unico
    # lugar del proyecto donde viven los datos del entorno (servidores,
    # UUID del scan). El codigo no tiene ninguno hardcodeado.
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
    # De aca para abajo son valores estructurales: funcionan tal cual.
    # -----------------------------------------------------------------

    # Concurrencia por defecto si un comando no especifica -ThrottleLimit.
    DefaultThrottleLimit = 5

    # Codigos de salida que MSI/instaladores tratan como exito
    # (0=OK, 3010/1641/1707=reinicio pendiente, 2359302=ya instalado).
    DefaultSuccessCodes  = @(0, 3010, 1641, 1707, 2359302)

    # 0 = sin timeout. En SEGUNDOS (no milisegundos).
    DefaultElapsedTime   = 0
}
