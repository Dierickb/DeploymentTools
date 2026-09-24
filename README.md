# Deployment Toolkit

Toolkit de despliegue remoto (copiar archivos, instalar apps, parches
KB, actualizar Office, disparar scans de Nessus/Tenable, correr comandos
puntuales) a través de PsExec, para equipos GBS. Ver `CHANGES.md` para
el detalle completo de qué se corrigió respecto a la versión anterior.

## Instalación

1. Copiá toda esta carpeta (`Deployment\`) a donde quieras — ya no
   depende de estar en `C:\Intel\Deployment`, se ubica sola.
2. Copiá `config\config.example.psd1` a `config\config.psd1` y **completá
   los valores de tu entorno**: ruta del repositorio, carpeta de updates,
   ruta del agente de Nessus y UUID del scan. El código no trae ninguno
   hardcodeado — si falta uno, la tarea que lo necesita avisa exactamente
   qué completar. `config.psd1` no debería versionarse ni salir del equipo.
3. Verificá que `psexec.exe` esté en el PATH (o en la misma carpeta
   desde donde corrés los scripts).

## Uso — interfaz web (única que corre también en macOS/Linux)

```
cmd_execute\Deploy-Web.cmd          (Windows)
pwsh ./Deploy-Web.ps1                (macOS / Linux)
```

Levanta un servidor local y abre el navegador. Mismas 7 tareas, mismo
módulo, mismo progreso en vivo. Escucha solo en `127.0.0.1` y exige un
token aleatorio que cambia en cada arranque, así ninguna otra pestaña del
navegador puede dispararle un despliegue. Opciones: `-Port 8899` si el
puerto está ocupado, `-NoBrowser` para no abrirlo solo, `-MaxTareas 3`
para permitir más tareas a la vez (por defecto 2, ver "Varias tareas a la
vez" más abajo), y `-Simular` para recorrer toda la interfaz **sin tocar
ningún equipo** (la forma de probarla en una Mac, donde `psexec.exe` no
existe).

## Uso — interfaz gráfica WPF (solo Windows)

```
cmd_execute\Deploy-Gui.cmd
```
o directamente:
```powershell
powershell.exe -STA -File .\Deploy-Gui.ps1
powershell.exe -STA -File .\Deploy-Gui.ps1 -MaxTareas 3   # mas tareas a la vez
```

Ventana con las mismas 7 tareas: elegís la tarea a la izquierda, de
dónde sale la lista de equipos, completás los parámetros, y "Ejecutar".
Valida los parámetros antes de arrancar (campos obligatorios, formato
`YYYY-MM` de la carpeta de KB, etc.) en vez de fallar a mitad de camino.
Mientras corre, la consola de abajo muestra el log **en vivo** línea por
línea, con la barra de progreso y los contadores OK/fallidos
actualizándose equipo por equipo — la ventana no se congela, y el botón
"Detener" (en "Progreso y consola en vivo") cancela la tarea que estás
viendo.

**Varias tareas a la vez** (igual en la interfaz web): mientras una tarea
corre, podés elegir otra en el menú de la izquierda y ejecutarla — por
ejemplo, desplegar una aplicación mientras se copian archivos. En
"Progreso y consola en vivo" aparece una ficha por tarea con su avance y
sus OK/Fallidos; hacé click en una ficha para ver su barra, su consola y
su detalle. "Detener" frena solo la tarea que estás viendo. Por defecto
se permiten **2 tareas a la vez** (`-MaxTareas` para cambiarlo, hasta 7).
La misma tarea no puede correr dos veces a la vez, porque las dos
escribirían en el mismo log. Ojo con la carga: la concurrencia real es la
suma de los throttle (5 + 5 = 10 equipos atendidos al mismo tiempo desde
tu máquina).

**Detalle por equipo** (igual en la interfaz web): hacé click en el
contador **OK** para ver la lista de hostnames que salieron bien, o en
**Fallidos** para ver cada hostname con su error. El panel se va llenando
en vivo mientras corre la tarea, y al terminar se actualiza con el error
definitivo del resumen. "Copiar hostnames" copia solo los nombres, uno por
línea — listo para pegar en un `.txt` de `imports\` y reintentar los
fallidos. Otro click en el mismo contador (o "Cerrar") lo cierra.

El `-STA` no es opcional: WPF no arranca en apartment MTA. El `.cmd` ya
lo pasa, y si se corre desde `pwsh` 7 el script se relanza solo. WPF es
exclusivo de Windows: en macOS o Linux este script avisa y no arranca —
ahí va la interfaz web.

## Uso — interfaz interactiva de consola

```
Deploy-Menu.cmd
```
o directamente:
```powershell
.\Deploy-Menu.ps1
```

Te pregunta la tarea, de dónde sacar la lista de equipos (un archivo de
`imports\`, una ruta escrita a mano, o pegar hostnames directamente en
consola), y los parámetros de esa tarea. Al final muestra un resumen
real (cuántos OK, cuántos fallaron, y cuáles).

## Uso — scripts para tareas programadas / automatización

Para lo que sí corre en un horario fijo (KB mensual, Office, Nessus),
usá los scripts de `scripts\`, con los parámetros por línea de comandos
(no hay nada para editar a mano):

```powershell
# KB mensual
.\scripts\run_kb_deployment.ps1 -ComputersFile computers.txt -KbPatch "KB5099414" -KbFolder "2026-09"

# Varios KB a la vez
.\scripts\run_kb_deployment.ps1 -ComputersFile computers.txt -KbPatch "KB5099414,KB5087420" -KbFolder "2026-09"

# Office
.\scripts\run_office_update.ps1 -ComputersFile office_update_computers.txt -TargetVersion 16.0.19929.20220

# Nessus / Tenable
.\scripts\run_nessus_scan.ps1 -ComputersFile nessus_scan_computers.txt

# Deploy de una app puntual
.\scripts\run_deploy_app.ps1 -ComputersFile deploy_app_computers.txt `
    -Command '"\\SERVIDOR\Repository\...\Deploy-Application.exe"' -ItemName "GoogleChrome"

# Copiar archivos
.\scripts\run_copy_files.ps1 -ComputersFile copy_files_computers.txt `
    -SourcePath '\\SERVIDOR\Repository\...' -ItemName "archivo.xml" `
    -RemoteSubPath 'ProgramData\...'

# Copiar + instalar
.\scripts\run_copy_install.ps1 -ComputersFile copy_install_computers.txt `
    -SourcePath '\\SERVIDOR\Repository\Otros' -ItemName "Cisco_SecureClientBundle_..." `
    -InstallCommand 'c:\temp\Cisco_SecureClientBundle_...\Deploy\install-SkipReboot.cmd'

# Comando arbitrario (reemplaza invokePsexec.ps1 — ya NO asume que la
# salida es una versión ni actualiza Tenable, salvo que se lo pidas)
.\scripts\run_remote_command.ps1 -ComputersFile invokePsexec_computer.txt `
    -Command 'netsh interface set interface Wi-Fi admin=disable'

# Ídem, con el flujo de "chequear versión y actualizar Tenable si corresponde"
.\scripts\run_remote_command.ps1 -ComputersFile invokePsexec_computer.txt `
    -Command 'powershell -Command "(Get-Item ''C:\Program Files\Google\Chrome\Application\chrome.exe'').VersionInfo.ProductVersion"' `
    -CompareVersion -MinVersion 152.0.7977.82 -UpdateTenableAfter
```

`ComputersFile` puede ser una ruta completa o solo el nombre de un
archivo dentro de `imports\`.

`cmd_execute\` tiene lanzadores `.cmd` para doble-click: `Deploy-Menu.cmd`
(el menú), y `kb_deployment.cmd` / `office_update.cmd` / `nessus_scan.cmd`
(piden los datos clave por consola, para las tareas más repetitivas).

## Estructura

```
Deployment/
  Module/Deployment/
    Deployment.psd1 / .psm1     Manifiesto y módulo raíz
    Classes/
      BaseDeploy.ps1             Ping, copia remota, PsExec, deploy de apps, Tenable
      KbWindows.ps1               Extiende BaseDeploy: flujo de parches KB
    Private/                      Interno del módulo, NO exportado
      Get-DeploymentRoot.ps1      Resuelve la raíz del proyecto (sin rutas hardcodeadas)
      Invoke-ThrottledDeployment.ps1  El runner de jobs (reemplaza el bloque duplicado)
      Write-DeploymentSummary.ps1     Resumen final OK/fallidos (no existía antes)
    Public/                       La API: lo que se llama desde afuera
      Get-DeploymentConfig.ps1    Carga config\config.psd1
      Read-ComputerList.ps1       Lee y limpia un archivo de hostnames
      Invoke-DeployApp.ps1        Reemplaza execute\deploy_app.ps1
      Invoke-CopyFiles.ps1        Reemplaza execute\copy_files.ps1
      Invoke-CopyInstall.ps1      Reemplaza execute\copy_install.ps1
      Invoke-RemoteCommand.ps1    Reemplaza execute\invokePsexec.ps1 (ahora genérico de verdad)
      Invoke-KbDeployment.ps1     Reemplaza execute\kb_execute.ps1
      Invoke-OfficeUpdate.ps1     Reemplaza execute\office_update.ps1
      Invoke-NessusScan.ps1       Reemplaza execute\nessus_scan.ps1
  scripts\        Wrappers no interactivos (para Scheduled Tasks) sobre el módulo
  cmd_execute\    Lanzadores .cmd (Deploy-Gui.cmd y Deploy-Menu.cmd son los principales)
  tests\          Test-DeploymentToolkit.ps1 — auto-diagnóstico sin psexec/red
  config\         config.example.psd1 (copiar a config.psd1)
  imports\        Listas de equipos (.txt, uno por línea) — sin cambios
  logs\           Se crean solos al correr cualquier tarea
  Deploy-Gui.ps1  La interfaz gráfica WPF (solo Windows)
  Deploy-Web.ps1  La interfaz web (Windows, macOS y Linux)
  Deploy-Menu.ps1 La interfaz interactiva de consola
  ARQUITECTURA.md Cómo está armado todo (para alguien nuevo en el proyecto)
  CHANGES.md      Detalle de bugs corregidos
```

## Diseño

- **Un solo módulo, cuatro formas de usarlo**: la interfaz web, la
  interfaz gráfica WPF, el menú de consola y los scripts de `scripts\` llaman exactamente a las
  mismas 7 funciones del módulo — nunca hay dos copias de la misma
  lógica. La GUI además corre esas funciones en un runspace aparte del
  hilo de ventana, así la interfaz no se congela durante el despliegue
  (ver `ARQUITECTURA.md`, sección 7).
- **Las clases se cargan frescas dentro de cada job** (no desde el
  módulo importado en la sesión principal): `Invoke-ThrottledDeployment`
  le pasa las rutas de `Classes\*.ps1` a `Start-Job -InitializationScript`,
  así que cada equipo se procesa en su propio proceso aislado, en
  paralelo, con el límite de concurrencia (`-ThrottleLimit`) que
  corresponda a esa tarea.
- **Nunca `exit N` dentro de un job**: cada tarea *retorna* un objeto
  `{Equipo, Success, ExitCode, Message}`, que es lo único que permite
  armar el resumen final — un `exit N` dentro de un `Start-Job` no se
  puede leer de forma simple después.
- **Los pasos "opcionales pegados"** (chequear versión antes de seguir,
  actualizar Tenable al final) son siempre switches explícitos
  (`-CompareVersion`, `-UpdateTenableAfter`), nunca comportamiento fijo
  — fue justamente la falta de esto (en `invokePsexec.ps1`) lo que
  rompía cualquier comando que no fuera "consultar la versión de
  Chrome".

## Pruebas

`tests\Test-DeploymentToolkit.ps1` ya se corrió con PowerShell 7 real
(no solo revisión manual): **60/60 pruebas OK**. Valida sintaxis de
todos los `.ps1`, que el módulo importa, resolución de rutas, carga de
config, limpieza de listas de equipos, un ping real a loopback, el
logging, la comparación de KBs, el patrón de `-KbFolder`, el runner de
jobs completo (`Invoke-ThrottledDeployment`) con un scriptblock de
prueba, y el camino de integración real de una función pública con
lista de equipos vacía. En esa corrida salieron 2 bugs reales (no del
entorno) que ya están corregidos — ver `CHANGES.md`, sección 5, para el
detalle: una lista de equipos vacía rompía con un error de *binding* en
vez de avisar y seguir, en las 7 funciones públicas y en
`Invoke-ThrottledDeployment`.

```powershell
.\tests\Test-DeploymentToolkit.ps1
```

Corré esto igual en tu máquina antes de confiar en el toolkit — nunca
está de más repetirlo tras mover o clonar la carpeta. Lo que ese script
NO prueba (necesita `psexec.exe` + equipos Windows reales) es la
copia/ejecución/Tenable de verdad — para eso, **antes de un despliegue
masivo, corré cualquiera de las tareas contra 2-3 equipos de prueba**
(armá un `imports\prueba.txt` con esos 2-3 hostnames y usalo desde el
menú).
