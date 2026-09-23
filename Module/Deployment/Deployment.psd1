@{
    RootModule         = 'Deployment.psm1'
    ModuleVersion      = '2.2.0'

    # GUID del modulo: es solo un identificador de identidad del modulo, no
    # un dato del entorno, pero se deja para que cada quien genere el suyo y
    # no queden copias distintas compartiendo identidad. Generarlo con:
    #     New-Guid
    # y pegarlo aca descomentando la linea.
    # GUID             = '00000000-0000-0000-0000-000000000000'

    Author             = 'Dierick Brochero'
    Description        = 'Toolkit de despliegue remoto (PsExec/copia/KB/Office/Nessus) para equipos GBS. Reemplaza los scripts sueltos de execute\ por un modulo unico.'
    PowerShellVersion  = '5.1'

    # Tiene que coincidir con los archivos de Public\: el manifiesto filtra
    # ademas de lo que exporte el .psm1, asi que una funcion que falte aca no
    # se exporta aunque este en Public\. Hay una prueba que compara las dos
    # listas.
    FunctionsToExport  = @(
        # Las 7 tareas
        'Invoke-DeployApp'
        'Invoke-CopyFiles'
        'Invoke-CopyInstall'
        'Invoke-RemoteCommand'
        'Invoke-KbDeployment'
        'Invoke-OfficeUpdate'
        'Invoke-NessusScan'

        # Lo que los puntos de entrada necesitan antes de llamar a una tarea
        'Get-DeploymentConfig'
        'Read-ComputerList'

        # Catalogo declarativo de las tareas, compartido por las dos
        # interfaces (Deploy-Gui.ps1 en WPF y Deploy-Web.ps1 en navegador)
        'Get-DeploymentTaskCatalog'

        # Despliegue simulado: no toca ningun equipo. Lo usan las interfaces
        # para poder recorrerse en una maquina que no es Windows.
        'Invoke-SimulatedDeployment'
    )
    CmdletsToExport    = @()
    VariablesToExport  = @()
    AliasesToExport    = @()
}
