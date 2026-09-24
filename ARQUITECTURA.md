# Arquitectura del Deployment Toolkit

Este documento es para alguien que recibe el proyecto por primera vez y
necesita entender cómo está armado antes de tocar código. No repite lo
que ya está en `README.md` (instalación, uso día a día) ni en
`CHANGES.md` (bugs corregidos respecto a la versión anterior) — para
eso, léase ese par de archivos primero. Acá el foco es: qué hace cada
pieza, cómo se llaman entre sí, y por qué está diseñado así.

## 1. Qué problema resuelve

Es un toolkit para ejecutar tareas de IT contra listas de equipos
Windows remotos vía `psexec.exe`: copiar archivos, instalar apps,
parchear KBs de Windows, actualizar Office, disparar un scan de
Nessus/Tenable, o correr un comando arbitrario puntual. Reemplaza 7
scripts sueltos (`execute\*.ps1`) que tenían lógica casi idéntica
copiada y pegada entre sí, con inconsistencias y bugs reales (ver
`CHANGES.md`).

## 2. Los tres niveles del proyecto

Todo se apoya en **un solo módulo de PowerShell**
(`Module/Deployment/`). Sobre ese módulo hay cuatro formas de usarlo, que
nunca duplican lógica entre sí:

1. **`Deploy-Web.ps1`** — interfaz web local (HttpListener + navegador).
   Es la única que corre fuera de Windows, y la que permite probar la
   interfaz desde una Mac con `-Simular`. Ver sección 9.
2. **`Deploy-Gui.ps1`** — interfaz gráfica (WPF, solo Windows). Es la vía recomendada
   para tareas puntuales: mismas 7 tareas del menú, con formulario,
   validación previa, consola en vivo y botón de cancelar. Ver la
   sección 7, que explica cómo no se traba la ventana.
3. **`Deploy-Menu.ps1`** — interfaz interactiva de consola, para
   tareas puntuales. Pregunta la tarea, de dónde sale la lista de
   equipos, y los parámetros; llama a las mismas funciones del módulo
   que las otras vías.
4. **`scripts\run_*.ps1`** — wrappers no interactivos, pensados para
   Scheduled Tasks de Windows (parámetros por línea de comandos, sin
   nada que editar a mano). Cada uno de los 7 (`run_copy_files`,
   `run_copy_install`, `run_deploy_app`, `run_kb_deployment`,
   `run_nessus_scan`, `run_office_update`, `run_remote_command`)
   simplemente: importa el módulo, resuelve la lista de equipos con
   `Read-ComputerList`, y llama a **una** función pública del módulo.

`cmd_execute\*.cmd` son lanzadores de doble-click sobre lo anterior
(para gente que no quiere abrir una consola de PowerShell a mano).

## 3. El módulo: `Module/Deployment/`

```
Deployment.psd1 / .psm1     Manifiesto y módulo raíz (carga todo, exporta 7 funciones)
Deployment.Constants.psd1   Todos los valores fijos y los defaults ajustables (ver 3.6)
Classes/
  BaseDeploy.ps1             Ping, copia remota, PsExec, deploy de apps, Tenable
  KbWindows.ps1               Extiende BaseDeploy: flujo de parches KB
Private/                      Interno del módulo, NO exportado
  Get-DeploymentConstants.ps1
  Get-DeploymentRoot.ps1
  Invoke-ThrottledDeployment.ps1
  Write-DeploymentSummary.ps1
Public/                       La API del módulo: lo que se llama desde afuera
  Get-DeploymentConfig.ps1
  Read-ComputerList.ps1
  Invoke-DeployApp.ps1
  Invoke-CopyFiles.ps1
  Invoke-CopyInstall.ps1
  Invoke-RemoteCommand.ps1
  Invoke-KbDeployment.ps1
  Invoke-OfficeUpdate.ps1
  Invoke-NessusScan.ps1
```

### 3.1 Cómo carga el módulo (`Deployment.psm1`)

Dot-sourcea todo lo que hay en `Private\` y `Public\` (en ese orden) y
exporta como funciones públicas los nombres de archivo de `Public\`
(`Export-ModuleMember -Function $publicFiles.BaseName`).

**La regla de carpeta no tiene excepciones**: `Public\` es todo lo que se
llama desde afuera del módulo y se exporta completo; `Private\` es interno
y nadie de afuera lo toca. `Get-DeploymentConfig` y `Read-ComputerList`
están en `Public\` porque los tres puntos de entrada las necesitan antes
de poder invocar una tarea (primero config, después lista de equipos,
recién ahí `Invoke-*`). Estuvieron un tiempo en `Private\` y eso era un
bug: al no exportarse, la GUI moría al arrancar con *"The term
'Get-DeploymentConfig' is not recognized"*. Hay una prueba que parsea los
puntos de entrada y verifica que todo lo que llaman del módulo esté
exportado. Importante:
**las clases (`Classes\`) NO se cargan acá**. Se dot-sourcean
frescas dentro de cada `Start-Job` (ver 3.3) — es la forma de evitar
las limitaciones de PowerShell para exportar clases desde un módulo, y
además hace que cada job tenga su propia copia aislada de la clase, sin
compartir estado entre equipos.

### 3.2 Las clases: dónde vive la lógica de "hacer algo en un equipo"

**`BaseDeploy`** (`Classes/BaseDeploy.ps1`) es la clase base. Se
instancia una por equipo, dentro del job de ese equipo:
`[BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)`. Sus métodos:

- `WriteLogSafe($message)` — escribe una línea al log compartido,
  protegida por un `Mutex` con nombre (`Global\...`) para que jobs en
  paralelo no se pisen escribiendo al mismo archivo. Espera hasta
  `LogMutexWaitMs` por el mutex; si no lo consigue, descarta la línea en
  silencio (no hace throw, no retry).
- `TestPingEquipo()` — ping ICMP simple. Devuelve un `[pscustomobject]`
  con `.Success`/`.msg`/etc. — **nunca** `$true`/`$false` ni `$null` a
  secas. Esto importa: en el código viejo, chequear el resultado con
  `if (-not $resultado)` siempre daba `$false` (un objeto no-null
  siempre es "truthy"), así que un ping fallido nunca se detectaba.
  Todo el código nuevo chequea `.Success` explícitamente.
- `CopyRemote(...)` — copia un archivo/carpeta a `\\<equipo>\C$\...`,
  y confirma que llegó (reintenta `Test-Path` hasta `CopyVerifyRetries`
  veces) antes de darlo por bueno.
- `InvokePsExec($command, $runAsSystem, $elevated, $elapsedTime)` —
  el corazón de todo: lanza `psexec.exe` como proceso hijo, lee su
  salida de forma **asíncrona** (`ReadToEndAsync`) para poder aplicar
  un timeout real vía `WaitForExit($elapsedTime * 1000)` y matar el
  proceso (`Kill()`) si se cuelga. Hay un overload de 3 argumentos
  (sin timeout) para llamadas que no necesitan uno. Devuelve
  `.Success/.ExitCode/.StdOut/.StdErr/.msg`.
- `DeployApp(...)` — llama a `InvokePsExec` y valida el `ExitCode`
  contra una lista de códigos de éxito (0, o los de reinicio pendiente
  de MSI: 3010/1641/1707/2359302).
- `UpdateTenable()` — dispara un scan de Nessus/Tenable local en el
  equipo remoto vía `nessuscli.exe scan-triggers`, con un timeout de
  `TenableTimeoutSeconds`.

Todos esos valores (timeouts, reintentos, ruta de `psexec.exe`, formato
del log) salen de **`[BaseDeploy]::Settings`**, una propiedad estática con
la config ya resuelta. La clase no puede leerla sola porque corre dentro
de un job sin el módulo importado: la carga `Invoke-ThrottledDeployment`
(ver 3.3). Si falta, el constructor falla con un mensaje claro. Ojo al
editar la clase: un método no puede tener una variable local que se llame
igual que una propiedad (`$settings` vs `Settings`) — PowerShell lo
rechaza al parsear; por eso las locales se llaman `$cfg`.

**`KbWindows`** (`Classes/KbWindows.ps1`) **extiende** `BaseDeploy`
(`class KbWindows : BaseDeploy`) y agrega el flujo específico de
parches de Windows:

- `GetKBVersion($elapsedTime)` — corre `Get-HotFix` remoto y devuelve
  la lista de KBs instalados.
- `CompareKb($kbGetted, $kbPatch)` — lógica pura (sin red): compara dos
  listas de KBs y dice si el/los esperado(s) ya están instalados.
- `DeployKB(...)` — instala el patch (vía `DeployApp` con la ruta
  `<InstallPath>\<kbFolder>\install.cmd`).
- `RunKbWindows(...)` — orquesta las tres de arriba: ping → obtener
  KBs instalados → comparar → si falta, desplegar → opcionalmente
  actualizar Tenable. Es el único método que llaman las funciones
  públicas; los demás son piezas internas que también se prueban por
  separado en `tests\`.

**Por qué `KbWindows` no se puede parsear sola:** al declarar
`class KbWindows : BaseDeploy`, el parser de PowerShell necesita que
`[BaseDeploy]` ya esté cargado en la sesión para resolver la herencia.
Si algún día se agrega una tercera clase, debe seguir el mismo patrón:
extender `BaseDeploy`, y cargarse siempre **después** de
`BaseDeploy.ps1` en cualquier `-ClassPaths` que se arme (ver 3.3).

### 3.3 El runner de jobs: `Invoke-ThrottledDeployment` (Private)

Esta es la pieza que reemplaza el bloque
`$jobs = @(); foreach (...) { Start-Job ... }; Wait-Job; Remove-Job`
que estaba copiado (con pequeñas variaciones y typos) en los 7 scripts
originales. La usan **todas** las funciones públicas, siempre de la
misma forma:

```powershell
$results = Invoke-ThrottledDeployment -ComputerList $ComputerList -Action $action `
    -LogPath $LogPath -LogMutexName $LogMutexName -ThrottleLimit $ThrottleLimit `
    -ActionArgs $actionArgs -ClassPaths $classPaths -ShowProgress:$ShowProgress
```

Qué hace, paso a paso:

1. Si `$ComputerList` está vacía, avisa con `Write-Warning` y devuelve
   una colección vacía sin hacer nada más (no es un error: un archivo
   de `imports\` vacío es un caso esperado).
2. Por cada equipo, espera a que haya un cupo libre según
   `-ThrottleLimit` (cuántos equipos en paralelo como máximo), y lanza
   un `Start-Job` con:
   - `-InitializationScript`: un scriptblock armado en caliente que
     dot-sourcea cada ruta de `-ClassPaths` — así el job, que corre en
     un proceso completamente aparte, tiene las clases disponibles sin
     depender del módulo importado en la sesión principal. Si hay clases,
     además deja la config (`-Settings`, o `Get-DeploymentConfig` si no
     vino) en `[BaseDeploy]::Settings`, serializada como JSON dentro del
     propio script.
   - `-ScriptBlock`: el `-Action` que le pasó la función pública (ver
     3.4).
   - `-ArgumentList`: `$Equipo, $LogPath, $LogMutexName` + los valores
     de `-ActionArgs` (un `OrderedDictionary`; el orden importa y debe
     coincidir con los parámetros que declara el `$Action`).
3. Con `-ShowProgress`, muestra una barra (`Write-Progress`) mientras
   encola y mientras espera a que terminen.
4. Al terminar todos, arma `$results`: por cada job, toma el **último**
   objeto que devolvió (`Receive-Job | Select -Last 1`). Si un job no
   devolvió nada o quedó en estado `Failed` (crasheó sin control), arma
   un resultado sintético con `Success=$false` y el error real, para
   que ese equipo igual aparezca en el resumen — nunca desaparece en
   silencio.
5. Limpia los jobs (`Remove-Job -Force`) y escribe una línea de INICIO/FIN al log.

**Diseño clave: nunca `exit N` dentro de un job.** Cada `$Action` debe
*devolver* (`return`/`Write-Output`, nunca `exit`) un objeto con al
menos `Equipo`/`Success`/`ExitCode`/`Message`. Un `exit` dentro de un
`Start-Job` sí mata ese proceso hijo, pero PowerShell no expone ese
código de salida en ninguna propiedad simple del `$job` — en los 7
scripts originales esto significaba que, pasara lo que pasara, solo se
imprimía "Procesamiento finalizado" sin saber cuántos fallaron.

**Gotcha de PowerShell a tener en cuenta si se toca este archivo:**
`return @()` (sin coma unaria) colapsa a `$null` en quien lo llama —
un array vacío puesto en el stream de salida se "desenrolla" a cero
objetos, y `$x = MiFuncion` con cero objetos de salida da `$x = $null`,
no un array vacío. Por eso los dos `return` que pueden devolver una
colección vacía usan `return ,@(...)` (coma unaria) y no `return @(...)`
a secas — si se edita esta función, mantené esa coma. `Write-DeploymentSummary`
es `Mandatory`, así que un `$null` ahí revienta.

### 3.4 El patrón `$Action`: cómo agregar una tarea nueva

Cada función pública arma su propio `$Action` (scriptblock) con esta forma:

```powershell
$action = {
    param($Equipo, $LogPath, $LogMutexName, <...parámetros propios de la tarea...>)

    $deploy = [BaseDeploy]::new($Equipo, $LogPath, $LogMutexName)   # o [KbWindows]::new(...)
    try {
        $ping = $deploy.TestPingEquipo()
        if (-not $ping.Success) {
            return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $ping.msg }
        }
        # ... lógica específica de la tarea, usando métodos de $deploy ...
        return [pscustomobject]@{ Equipo = $Equipo; Success = $true; ExitCode = 0; Message = "..." }
    }
    catch {
        $msg = "ERROR JOB: $($_.Exception.Message)"
        $deploy.WriteLogSafe($msg)
        return [pscustomobject]@{ Equipo = $Equipo; Success = $false; ExitCode = -1; Message = $msg }
    }
}
```

Para agregar una octava tarea (ejemplo: "reiniciar el equipo"):

1. Agregar su identidad a `Tasks` en `Deployment.Constants.psd1`
   (`LogFile`, `MutexName` y `ImportFile` propios; si necesita throttle o
   timeout distintos de los generales, una entrada en
   `Tunable.TaskDefaults`).
2. Crear `Public/Invoke-RebootEquipo.ps1` siguiendo ese patrón —
   parámetros propios + `$Action` con el `try/catch` de arriba — y
   resolver los defaults desde `$config.Tasks.<id>` (ThrottleLimit,
   ElapsedTime, LogFile, MutexName), como las otras 7. Ningún valor
   escrito a mano: hay una prueba que lo verifica (ver 3.6).
3. Armar `$actionArgs` (`[ordered]@{...}`) en el mismo orden que los
   parámetros del `$Action` (después de `$Equipo, $LogPath, $LogMutexName`).
4. Llamar a `Invoke-ThrottledDeployment` y devolver
   `Write-DeploymentSummary -Results $results -LogPath $LogPath` — igual que las otras 7.
5. Agregar el nombre a `FunctionsToExport` en `Deployment.psd1`.
6. Opcional: agregar una opción al menú en `Deploy-Menu.ps1`, y/o un
   wrapper en `scripts\run_reboot_equipo.ps1` si va a correr en
   Scheduled Task.
7. Agregar un caso al `Test-Case` de sintaxis (se detecta solo, es un
   `Get-ChildItem -Recurse`) y, si tiene lógica propia no trivial, una
   prueba dedicada en `tests\Test-DeploymentToolkit.ps1`.

### 3.5 Otros helpers `Private\`

- **`Get-DeploymentRoot`** — sube 3 niveles desde su propia ubicación
  (`<root>\Module\Deployment\Private\`) para encontrar `<root>`. Es la
  base de la portabilidad: mover/renombrar la carpeta del proyecto
  entero no rompe nada, porque nada usa una ruta absoluta hardcodeada.
- **`Get-DeploymentConfig`** — combina `Deployment.Constants.psd1` con
  `config\config.psd1` (ver 3.6) y devuelve un solo objeto: los valores
  ajustables ya resueltos, `.Tasks.<id>` con la identidad y los defaults
  de cada tarea, y las secciones fijas (`.Log`, `.Remote`, `.Validation`,
  `.Office`, `.Simulation`, `.Runner`, `.Ui`, `.Paths`). Los valores **del
  entorno** (repositorio, carpeta de updates, ruta del agente de Nessus,
  UUID del scan) quedan **vacíos a propósito** — no hay ni un dato de
  infraestructura escrito en el código. Si falta uno, la tarea que lo
  necesita falla con un mensaje que dice qué completar y dónde, en vez de
  apuntar en silencio a un servidor que no es.
- **`Get-DeploymentConstants`** — lee `Deployment.Constants.psd1` tal
  cual, sin `config.psd1`. Es el único lugar que conoce el nombre de ese
  archivo; lo usan `Get-DeploymentConfig` y lo interno que solo necesita
  un valor fijo (el formato de fecha en `Write-DeploymentSummary`).
- **`Read-ComputerList`** — lee un `.txt` de hostnames, recorta
  espacios, descarta líneas vacías/comentarios (`#`), y quita
  duplicados. Si el archivo queda vacío, avisa (no truena) — el
  archivo *no* existiendo sí es un error real (`throw`).
- **`Write-DeploymentSummary`** — toma el array de resultados de
  `Invoke-ThrottledDeployment`, imprime un resumen (total/OK/fallidos +
  detalle de los que fallaron), lo agrega al log si `-LogPath` viene
  dado, y devuelve un `[pscustomobject]` con `Total/Ok/Failed/Errors`
  — es lo que cada función pública devuelve al final, y lo que
  `scripts\run_*.ps1` usa para decidir su `exit 0`/`exit 1`.

### 3.6 Constantes y config: `Deployment.Constants.psd1`

Todo valor con significado propio (nombre de log o de mutex de una tarea,
archivo de `imports\` por defecto, timeouts, throttle, success codes,
formato de fecha del log, patrón de `-KbFolder`, ruta de `psexec.exe` y de
`OfficeC2RClient.exe`, clave de registro de Office, puerto e intervalos de
las interfaces) está definido **una sola vez**, en
`Module/Deployment/Deployment.Constants.psd1`. El módulo, el menú,
`scripts\`, la GUI y la web lo leen de `Get-DeploymentConfig`; nadie lo
escribe a mano.

El archivo tiene dos clases de valor:

- **`Tunable`** — defaults que `config\config.psd1` puede sobrescribir:
  datos del entorno, `DefaultThrottleLimit`, `DefaultSuccessCodes`,
  `DefaultElapsedTime`, `TaskDefaults` (throttle y timeout por tarea),
  rutas de herramientas y tiempos internos de `BaseDeploy`.
- **El resto** — fijo. Si `config.psd1` trae una clave que no está en
  `Tunable` (o un campo de `TaskDefaults` que no sea `ThrottleLimit` o
  `ElapsedTime`), se ignora con un aviso. Por ejemplo, cambiar el mutex de
  una tarea mientras otra corrida de esa tarea sigue abierta haría que las
  dos escriban al mismo log sin sincronizarse.

Los timeouts de la config están en **segundos**; el menú, la GUI, la web
y los `scripts\` los muestran y piden en minutos.

Lo que **sí** queda escrito en el código, a propósito: la ruta
`Module\Deployment\Deployment.psd1` en cada punto de entrada (hace falta
para importar el módulo, antes de poder leer ninguna constante), la
sintaxis de los comandos (flags de `psexec`, el comando de `Get-HotFix`,
el de `OfficeC2RClient`), los textos para el usuario, y los formatos de
presentación (anchos de columna, cuántas líneas de preview).

Dos pruebas lo cuidan: una verifica que ningún valor de texto de las
constantes aparezca como literal en un `.ps1` (mira los tokens de string,
no los comentarios), y otra que el catálogo muestre los mismos defaults
por tarea que usa el módulo.

**Por qué `-KbFolder` y `-MaxTareas` no usan `[ValidatePattern()]` /
`[ValidateRange()]`**: un atributo solo acepta literales, y el patrón y el
rango viven en las constantes. Se validan al principio del cuerpo, antes
de lanzar ningún job.

## 4. Flujo completo de punta a punta (ejemplo: KB mensual)

```
scripts\run_kb_deployment.ps1  (o la opción 5 del Deploy-Menu.ps1)
  │
  ├─ Import-Module Deployment.psd1
  ├─ Read-ComputerList  →  lista de hostnames limpia
  │
  └─ Invoke-KbDeployment -ComputerList ... -KbPatch ... -KbFolder ...
        │
        ├─ Get-DeploymentConfig            (defaults: throttle, success codes, updates path)
        ├─ arma $classPaths = [BaseDeploy.ps1, KbWindows.ps1]   (orden importa)
        ├─ arma $action { ... $kb.RunKbWindows(...) ... }
        │
        └─ Invoke-ThrottledDeployment -ComputerList -Action $action -ClassPaths $classPaths ...
              │
              │  por cada equipo (respetando -ThrottleLimit):
              └─ Start-Job -InitializationScript {dot-source BaseDeploy+KbWindows} -ScriptBlock $action
                    │
                    └─ [KbWindows]::new(...)
                          .RunKbWindows()
                            ├─ TestPingEquipo()
                            ├─ GetKBVersion()      → InvokePsExec(Get-HotFix)
                            ├─ CompareKb()
                            ├─ (si falta) DeployKB() → DeployApp() → InvokePsExec(install.cmd)
                            └─ UpdateTenable()      → InvokePsExec(nessuscli.exe)
                    │
                    └─ return [pscustomobject]@{Equipo; Success; ExitCode; Message}
              │
              └─ junta todos los resultados (con sintético si algún job crasheó)
        │
        └─ Write-DeploymentSummary  →  imprime resumen + lo devuelve
```

Cada `InvokePsExec` de arriba escribe además al log compartido vía
`WriteLogSafe` (protegido por el `MutexName` de la tarea `kb`), así que el
archivo de log de la tarea termina con las líneas de **todos** los
equipos intercaladas, en el orden en que realmente ocurrieron.

## 5. Configuración y datos

- **`config\config.psd1`** (no versionado; copiar desde
  `config.example.psd1`) — ruta del repositorio, ruta de updates,
  ruta/UUID de Nessus, y opcionalmente cualquier otro valor de la sección
  `Tunable` de `Deployment.Constants.psd1` (ver 3.6). Si no existe, el
  toolkit sigue funcionando con los defaults de las constantes.
- **`imports\*.txt`** — listas de hostnames, una por archivo/tarea. Se
  copiaron tal cual del proyecto original; algunos nombres tienen
  typos evidentes de fábrica (ver `CHANGES.md`, punto 4) que no se
  "corrigieron" a ciegas.
- **`logs\*.log`** — un archivo por tarea (el `LogFile` de cada una en
  las constantes), se crean solos. Formato de línea:
  `<fecha en Log.DateFormat> | <equipo> | <mensaje>`.

## 6. Pruebas: `tests\Test-DeploymentToolkit.ps1`

Auto-diagnóstico que corre en cualquier máquina con PowerShell, sin
`psexec.exe` ni red corporativa: sintaxis de todos los `.ps1`
(`Classes\` se valida aparte, concatenada, por la herencia — ver 3.2),
import del módulo, `Get-DeploymentRoot`/`Get-DeploymentConfig`,
`Read-ComputerList`, `TestPingEquipo` contra loopback, `WriteLogSafe`,
`KbWindows.CompareKb`, el patrón de `-KbFolder`, y
`Invoke-ThrottledDeployment` completo (con un scriptblock de prueba en
vez de `psexec` real) — incluyendo el camino de integración real
encadenado hasta `Write-DeploymentSummary` con lista de equipos vacía.
Ya se corrió con PowerShell 7 real: **60/60 OK** (detalle de los 2
bugs reales que salieron de esa corrida y ya están corregidos, en
`CHANGES.md` sección 5). Correrlo primero, siempre, antes de confiar en
un cambio. Lo único que NO prueba (necesita `psexec.exe` + equipos
Windows reales) es la copia/ejecución/Tenable de verdad — para eso,
antes de un despliegue masivo, correr cualquier tarea contra 2-3
equipos de prueba (`imports\prueba.txt`).

## 7. La capa GUI (`Deploy-Gui.ps1`)

La interfaz gráfica no reimplementa nada: arma un splat de parámetros y
llama a la **misma** función pública que el menú de consola. Lo que sí
tiene es la plomería para que una ventana no se congele mientras corre
un despliegue de horas.

### 7.1 El problema: las funciones del módulo son bloqueantes

`Invoke-KbDeployment` (y las otras 6) no devuelven nada hasta que el
último equipo terminó. Llamarla directo desde el handler del botón
congelaría la ventana entera —Windows la marcaría "No responde"— y no
habría forma de ver avance ni de cancelar. Es la versión GUI, y peor,
del problema de "los logs se traban y no veo nada en tiempo real".

### 7.2 La solución: runspace + cola + DispatcherTimer

```
   Hilo de UI (STA)                    Runspace worker (MTA)
   ────────────────                    ─────────────────────
   BtnRun click
     └─ arma $splat  ──────────────►  Import-Module Deployment
        crea $sync                     Invoke-KbDeployment @splat
        BeginInvoke  ─────────────►      └─ Invoke-ThrottledDeployment
        arranca DispatcherTimer              ├─ Start-Job por equipo
                                             │    (procesos hijos)
   cada 250 ms:                              └─ encola eventos ──┐
     ├─ drena $sync.Queue  ◄─────────────────────────────────────┘
     │    JobStart / JobDone / BatchEnd  →  progreso, contadores
     ├─ lee líneas NUEVAS del .log       →  consola coloreada
     └─ si WorkerDone: 4 vueltas más y cierra
```

Tres piezas:

- **Runspace aparte**: el despliegue corre en su propio hilo. La ventana
  sigue repintando, se puede mover, y el botón "Detener" responde.
- **`-ProgressQueue`** (parámetro nuevo de `Invoke-ThrottledDeployment`,
  pass-through en las 7 funciones públicas): un
  `ConcurrentQueue[object]` —thread-safe a propósito, lo escribe el
  worker y lo lee la UI— donde se encola un evento `JobStart` por
  equipo encolado y un `JobDone` apenas termina, con su `Success` ya
  resuelto. El peek usa `Receive-Job -Keep`: mira el resultado **sin
  consumirlo**, para que la recolección final del resumen lo siga
  encontrando intacto (sin `-Keep`, el progreso le robaría los
  resultados al resumen).
- **Tail incremental del log**: el `DispatcherTimer` lee solo los bytes
  agregados al `.log` desde la vuelta anterior, guardando el offset. Se
  abre con `FileShare.ReadWrite` porque los jobs lo están escribiendo al
  mismo tiempo — abrirlo en modo exclusivo desde la UI rompería sus
  `Add-Content`. Si el chunk leído no termina en salto de línea (un job
  escribiendo justo en ese instante), la línea parcial se guarda y se
  completa en la vuelta siguiente en vez de pintarse cortada.
- **Detalle por equipo (click en OK / Fallidos)**: cada `JobDone` ya trae
  `Equipo`, `Success` y `Message`, así que la GUI arma dos listas en vivo
  (`$script:OkList`, `$script:FailList`) sin pedirle nada nuevo al
  runner. Al terminar se **reemplazan** por el resumen final
  (`Write-DeploymentSummary` devuelve `Succeeded` y `Errors`), porque para
  un job caído el peek en vivo solo ve "sin resultado" y el resumen trae el
  error real. Con el panel abierto, cada `JobDone` agrega una fila; el
  panel entero se redibuja solo al abrirlo, al cambiar de OK a Fallidos, al
  arrancar y al terminar.

### 7.3 Cancelar

`-CancelFlag` es un hashtable sincronizado con una clave `Cancel`.
`Invoke-ThrottledDeployment` lo chequea en sus dos loops: deja de
encolar equipos nuevos y hace `Stop-Job` de los que sigan corriendo,
devolviendo los resultados parciales. Tiene que frenarse **desde
adentro** del runspace worker porque `Start-Job` registra los jobs por
runspace: `Get-Job`/`Stop-Job` desde el hilo de UI no los vería.

Con multitarea (7.3.1), cada corrida tiene su propio `CancelFlag`, así que
"Detener" frena solo la tarea que se está viendo.

### 7.3.1 Multitarea: varias tareas a la vez

Todo lo de 7.2 es **por corrida**: cada tarea lanzada tiene su runspace,
su cola, su `CancelFlag`, su offset del log, sus contadores, sus listas
OK/Fallidos y las líneas de su consola, en un objeto que arma
`New-RunState`. Se guardan en `$script:Runs`, uno por tarea (el que está en
curso o el último que terminó; relanzar la tarea reemplaza el suyo). Un
solo `DispatcherTimer` recorre las corridas activas en cada tick.

- **El módulo no cambió para esto**: cada tarea escribe en su propio
  `.log` con su propio mutex (`Global\deploy_app`, `Global\copy_files`,
  ...), así que dos tareas distintas no se pisan. Hay una prueba que corre
  dos despliegues simulados en runspaces separados y verifica que no se
  crucen equipos ni líneas de log.
- **Lo que se bloquea**: la misma tarea dos veces a la vez (compartirían
  el log y se mezclarían las consolas) y más de `-MaxTareas` tareas en
  paralelo (2 por defecto, hasta 7). El botón "Ejecutar" se deshabilita y
  la tarjeta de ejecución dice por qué.
- **Vista vs. menú**: la corrida que se ve en "Progreso y consola"
  (`$script:ViewTask`) es independiente de la tarea elegida en el menú. Así
  se puede preparar la segunda tarea sin perder de vista la primera. Las
  fichas cambian la vista; "Ejecutar" pasa a mostrar lo recién lanzado.
- **Consola por corrida**: las líneas se guardan en la corrida
  (`Add-RunLine`) y solo se pintan si es la que se ve; al cambiar de ficha
  se repinta la consola con las de esa corrida. `$script:OkList` y
  `$script:FailList` apuntan a las listas de la corrida vista, así que el
  detalle OK/Fallidos no necesitó cambios.
- **Carga**: la concurrencia real es la suma de los throttle de las tareas
  en curso. Por eso el máximo por defecto es 2.

### 7.4 El formulario es declarativo

`$script:Tasks` describe cada tarea: qué función invoca, qué archivo de
`imports\` y qué `.log` le corresponden, y la lista de campos con su
tipo. De ahí salen **tanto** los controles (`Build-ParameterPanel`)
**como** los parámetros con los que se llama a la función
(`Read-ParameterValues`). Agregar una tarea a la GUI es agregar una
entrada a ese array — nada de XAML nuevo.

Tipos de campo y a qué se traducen: `Text`→`[string]`,
`TextArr`→`[string[]]` de un elemento, `List`/`Codes`→ arrays separados
por coma, `Int`→`[int]`, `Minutes`→ se ingresa en minutos y se pasa en
**segundos** (que es lo que espera `-ElapsedTime`; la confusión de
unidades fue un bug real, ver `CHANGES.md` 1.8), `Switch`→ solo se
manda si está tildado, `Bool`→ se manda siempre (para parámetros que son
`[bool]` con default `$true`, como `-ForceAppShutdown`: con un switch
nunca se podrían desactivar), `BoolArr`→`[bool[]]` de un elemento.

La validación (campos obligatorios, el patrón `YYYY-MM` de `-KbFolder`,
que `-CompareVersion` venga con `-MinVersion`) corre **antes** de
arrancar, así el error aparece en la ventana en vez de reventar con el
despliegue ya lanzado.

### 7.5 Arranque

WPF exige apartment **STA**. `powershell.exe` (5.1) ya arranca así;
`pwsh` 7 arranca en MTA, por eso el script se relanza solo con `-STA` si
detecta que no lo está. `cmd_execute\Deploy-Gui.cmd` es el lanzador de
doble-click y ya pasa el flag.

## 8. Puntos a tener presente para quien siga manteniendo esto

- **Nunca** un `default` en un parámetro de método de clase — PowerShell
  no lo soporta; de ahí los overloads explícitos en `InvokePsExec`.
- **Siempre** chequear `.Success`, nunca la "verdad" del objeto
  devuelto a secas (`TestPingEquipo`/`InvokePsExec`/etc. siempre
  devuelven un objeto no-null).
- **Siempre** `[AllowEmptyCollection()]` en cualquier parámetro
  `Mandatory` de tipo array que legítimamente pueda recibir una
  colección vacía (ComputerList, ClassPaths) — si no, PowerShell
  rechaza el *binding* antes de que el código llegue a correr.
- **Siempre** `return ,@(...)` (coma unaria) en vez de `return @(...)`
  cuando la función puede devolver una colección vacía y quien la llama
  necesita distinguir "vacío" de "`$null`". Excepción:
  `Read-ComputerList` devuelve `@(...)` a secas, así que quien la llama
  **siempre** la envuelve: `$x = @(Read-ComputerList ...)` (hay una prueba).
  Ver `CHANGES.md` sección 11.
- Un método nuevo que agregue una clase que herede de otra debe
  cargarse siempre después de su base en cualquier `-ClassPaths`.
- **Ningún valor con significado escrito a mano.** Si hace falta uno
  nuevo, va en `Deployment.Constants.psd1` (en `Tunable` si el operador
  debería poder cambiarlo) y se lee de `Get-DeploymentConfig`. La prueba
  de literales falla si un valor de las constantes se copia en un `.ps1`.
- El `Mutex` de `WriteLogSafe` da hasta `LogMutexWaitMs` y después descarta la línea
  en silencio — no es un log 100% garantizado bajo contención extrema;
  ver la conversación sobre "logs que se traban" para el detalle de
  cuándo esto puede notarse y qué endurecerlo si hace falta.
- **Guardar todo `.ps1`/`.psd1` con acentos como UTF-8 CON BOM.**
  Windows PowerShell 5.1 —el que corre esto en producción— lee un
  archivo sin BOM como ANSI, no como UTF-8: todos los textos con tilde
  o ñ quedan corruptos, incluidos los que se escriben al log y los del
  menú. Hay una prueba que lo verifica; si un editor guarda sin BOM,
  esa prueba falla.
- En la GUI, cualquier trabajo largo va **en el runspace worker**, nunca
  en el hilo de UI. Y cualquier toque a controles va **en el hilo de
  UI** (el `DispatcherTimer`), nunca desde el worker: WPF tira una
  excepción de cross-thread si un hilo ajeno toca un control.
- Si se agrega un parámetro nuevo a una función pública y la GUI lo va a
  usar, el campo se declara en `$script:Tasks` con el mismo nombre que
  el parámetro — hay una prueba que compara ambos lados y falla si no
  coinciden.
- El peek de progreso usa `Receive-Job -Keep`. Sacar el `-Keep` haría
  que el progreso consuma la salida del job y el resumen final quede
  vacío.


## 9. La interfaz web (`Deploy-Web.ps1`)

Existe porque WPF es exclusivo de Windows: `Deploy-Gui.ps1` no se puede
ni abrir en una Mac. Esta sí, porque `HttpListener` y el resto son .NET
multiplataforma.

**Las dos interfaces conviven sin duplicar nada.** Las 7 tareas salen del
mismo catálogo del módulo (`Get-DeploymentTaskCatalog`), así que no pueden
desincronizarse: agregar una tarea se hace una sola vez y aparece en las
dos. El despliegue lo hacen las mismas funciones públicas. El progreso en
vivo usa el mismo mecanismo (runspace aparte + `-ProgressQueue` + tail
incremental del log); lo que en WPF era un `DispatcherTimer` cada 250 ms,
acá es el navegador pidiendo `/api/progress` cada 500 ms.

La API es chica: `/api/init` (catálogo), `/api/imports`, `/api/computers`,
`/api/run`, `/api/progress`, `/api/resultados` y `/api/stop`.

`/api/resultados?tipo=ok|fail&tarea=<id>` es el detalle que se abre al
hacer click en OK o Fallidos (mismo criterio que la GUI, sección 7.2:
listas en vivo que al final se reemplazan por el resumen). Va aparte de
`/api/progress` a propósito: con cientos de equipos no tiene sentido mandar
la lista entera cada 500 ms, así que el navegador la pide solo con el panel
abierto y cuando el contador cambió. Hostnames y mensajes se insertan
siempre con `textContent`, nunca como HTML.

**Multitarea** (mismo diseño que la GUI, sección 7.3.1): el servidor guarda
una corrida por tarea en `$script:Runs` y acepta hasta `-MaxTareas`
distintas a la vez; `/api/run` rechaza la misma tarea dos veces y el
exceso sobre el máximo. `/api/progress` devuelve **todas** las corridas en
un solo pedido (`corridas: [...]`) porque las líneas nuevas del log se
consumen al leerlas: si el navegador preguntara solo por la que está
mirando, la consola de la otra quedaría con huecos. Cada corrida lleva un
`seq` creciente para descartar una respuesta vieja que llegue después de
relanzar esa tarea. `/api/stop?tarea=<id>` detiene solo esa corrida.

**Seguridad.** Escucha solo en `127.0.0.1` y exige un token aleatorio,
distinto en cada arranque, que viaja en la URL. Sin eso, cualquier página
abierta en el navegador podría hacerle pedidos al puerto y disparar un
despliegue contra cientos de equipos.

**`-Simular`.** Llama a `Invoke-SimulatedDeployment`, una función pública
del módulo que corre el **mismo runner** con un scriptblock de prueba: se
ejercita el camino real —cola de progreso, cancelación, escritura al log,
resumen— sin tocar ningún equipo. Vive dentro del módulo, y no en el
script de la interfaz, porque necesita `Invoke-ThrottledDeployment` y
`Write-DeploymentSummary`, que son `Private\`. Un equipo cuyo nombre
contenga "fail" se reporta como fallido, para poder ver ambos casos.

**En Windows**, si `HttpListener` responde "Acceso denegado", Windows pide
reservar la URL una sola vez desde una consola como administrador; el
script imprime el comando `netsh http add urlacl` exacto.
