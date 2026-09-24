# CHANGES.md — Correcciones, integración y optimización

Aviso honesto primero: no tuve PowerShell disponible en el entorno donde
hice este trabajo (sin red para instalarlo), así que todo lo de acá salió
de revisión manual cuidadosa del código y de los logs reales que venían
en `Deployment/logs/` (que sí me sirvieron como evidencia en más de un
caso). No pude correr nada en vivo. Antes de confiar en esto para un
despliegue real, corré primero contra 2-3 equipos de prueba.

## 1. Bugs reales corregidos

### 1.1 `office_update.ps1`: `InvokePsExec` llamado con 3 argumentos en vez de 4 — probablemente el bug más serio
```powershell
$resultVersionGetted = $office.InvokePsExec($getOfficeVersion, $true, $true)
```
El método `InvokePsExec` de `BaseDeploy` tenía una sola firma, con 4
parámetros obligatorios (`$command, $runAsSystem, $elevated,
$elapsedTime`). **Las clases de PowerShell no admiten valores por
defecto en los parámetros de sus métodos** (a diferencia de las
funciones normales): llamar con menos argumentos que los declarados
rompe la resolución del método. Encontré evidencia de esto en
`logs/office_updates.log`: 390 líneas de `ERROR JOB`, muchas del tipo
`Cannot convert value "" to type "System.Version"` — consistente con
que en algún momento el script sí tenía el 4º argumento y se perdió en
una edición posterior.
**Fix:** agregué un *overload* de 3 argumentos a `InvokePsExec` en
`BaseDeploy.ps1` (sin timeout, equivalente a pasar 0) para que este tipo
de llamada funcione sin reventar, Y además corregí las llamadas en
`Invoke-OfficeUpdate` para pasar siempre el elapsedTime explícito.

### 1.2 `copy_install.ps1`: variable inexistente
```powershell
$copyRemote.WriteLogSafe("OK: { $msgOK }")
```
La variable en ese script se llamaba `$copyInstallRemote`, no
`$copyRemote` (copiado y pegado de `copy_files.ps1`, donde sí se llama
así). Esto rompía con un error de referencia nula en cada corrida,
atrapado silenciosamente por el catch genérico.
**Fix:** en `Invoke-CopyInstall`, la variable se usa consistentemente.

### 1.3 Chequeo de ping que nunca detecta un ping fallido — en `copy_install.ps1` y `office_update.ps1`
```powershell
$resultPingRemote = $copyInstallRemote.TestPingEquipo()
if(-not $resultPingRemote) { throw "$Equipo no en red" }
```
`TestPingEquipo()` siempre devuelve un objeto (`pscustomobject`), tanto
si el ping fue exitoso como si falló — nunca `$null`. `-not
$resultPingRemote` evalúa la "verdad" del objeto en sí (siempre
verdadero, sea cual sea su contenido), no la propiedad `.Success`. Un
equipo apagado o inalcanzable pasaba este chequeo igual y el script
seguía adelante intentando copiar/ejecutar en él. El patrón correcto
(`-not $resultPingRemote.Success`) sí estaba en `copy_files.ps1` y
`deploy_app.ps1` — la inconsistencia era justo entre scripts.
**Fix:** todas las funciones nuevas (`Invoke-*`) chequean `.Success`.

### 1.4 `kb_execute.ps1`: valor corrupto en la carpeta de instalación
```powershell
$kbFolderDeploy = "2026-08+++´\\\\\\\\"
```
Un valor claramente corrupto (parece un pegado accidental) que hacía
apuntar la instalación a una ruta que no existe. Comparé contra
`logs/resultado_kb.log`, donde corridas anteriores sí usaban carpetas
válidas (`2026-07`), así que esto es un error reciente, no cómo era
siempre.
**Fix:** `Invoke-KbDeployment`/`Deploy-Menu.ps1` exigen `-KbFolder`
como parámetro obligatorio, validado contra un patrón `YYYY-MM[-DD][sufijo]`
(rechaza valores como el de arriba) — nunca hay un default silencioso.

### 1.5 `deploy_app.ps1`: bloque de código muerto
```powershell
'
$resultNessusUpdate = $deployApp.UpdateTenable()
...
'
```
Ese bloque completo (comparar/actualizar Tenable tras el deploy) estaba
escrito como un string sin usar — una forma improvisada de "comentar"
código que nunca se ejecuta, dejando además `$Command_2`/`$Command_3`
sin usar, referenciando variables (`$installPath_2`, `$installPath_3`)
que ni siquiera estaban definidas en ese momento (comentadas más arriba).
**Fix:** en `Invoke-DeployApp`, actualizar Tenable después del deploy es
un switch explícito (`-UpdateTenableAfter`), no código fantasma.

### 1.6 `invokePsexec.ps1`: el bug de diseño más importante de todo el paquete
Este script se usaba como ejecutor **genérico** de comandos puntuales —
el archivo tenía decenas de comandos distintos comentados y
descomentados según la tarea del día (netsh, DNS, msiexec, limpiar
perfiles VPN, consultar versión de Chrome, wmic...). Pero el CUERPO del
script asumía siempre que la salida era un número de versión de Chrome,
y siempre intentaba actualizar Tenable al final:
```powershell
if ([version]$result.StdOut.Trim() -le [version]'152.0.7977.82') {...}
$resultNessusUpdate = $invokePsexec.UpdateTenable()
```
Con cualquier otro comando (el que estaba activo al revisar esto era
`netsh interface set interface Wi-Fi admin=disable`), esa línea intenta
convertir una salida vacía o no numérica a `[version]` y revienta.
**Fix:** `Invoke-RemoteCommand` es genérico de verdad por defecto (corre
el comando, registra el resultado, listo). El chequeo de versión y la
actualización de Tenable quedan como opt-in explícito
(`-CompareVersion -MinVersion ...`, `-UpdateTenableAfter`).

### 1.7 `InvokePsExec`: el timeout nunca se aplicaba de verdad
```powershell
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
if ($elapsedTime -ne 0) {
    if (-not $proc.WaitForExit($elapsedTime)) { ... }
}
```
`ReadToEnd()` es **bloqueante**: no retorna hasta que el proceso cierra
sus streams (es decir, hasta que termina). Para cuando el código llegaba
a `WaitForExit($elapsedTime)`, el proceso ya había terminado (caso
normal) — o, si estaba colgado, el hilo ya llevaba colgado en
`ReadToEnd()` un tiempo indefinido, y `WaitForExit()` nunca se alcanzaba.
Si `psexec` se quedaba esperando (un diálogo de UAC, una instalación
tildada, la red intermitente), el job se quedaba colgado **para
siempre**, sin ningún timeout posible — justo lo que `$elapsedTime`
debería evitar, y justo el tipo de cosa que puede trabar un despliegue
masivo a cientos de equipos (el throttle limit se llena de jobs
colgados y nada más avanza).
**Fix:** lectura asíncrona con `ReadToEndAsync()`, de forma que
`WaitForExit($ms)` se aplica de verdad y el proceso se mata (`Kill()`)
si se pasa del tiempo.

### 1.8 `InvokePsExec`: segundos pasados directo a un método que espera milisegundos
```powershell
$minutes = 10
$elapsedTime = $minutes * 60      # 600 (segundos)
...
$proc.WaitForExit($elapsedTime)   # WaitForExit espera MILISEGUNDOS
```
Un "timeout de 10 minutos" terminaba siendo, en la práctica, un timeout
real de 600 **milisegundos** (0.6 segundos). Este bug estaba enmascarado
por el bug 1.7 (como el timeout nunca se aplicaba de verdad, tampoco
importaba que la cifra estuviera mal). Al corregir 1.7 había que
corregir también esto, o el timeout real habría quedado en 0.6s.
**Fix:** `$proc.WaitForExit($elapsedTime * 1000)`.

### 1.9 `DeployApp`: lógica de códigos de éxito confusa, con un caso borde real
```powershell
$validSuccessCodes = $true
if ($SuccessCodes -and $SuccessCodes.Count -gt 0) {
    $validSuccessCodes = $SuccessCodes -notcontains $result.ExitCode
}
if ($validSuccessCodes -and $result.ExitCode -ne 0) { throw ... }
```
El doble negativo (`$validSuccessCodes` en realidad significaba "NO está
en la lista de éxito") es confuso, y tiene un caso borde real: si
`$SuccessCodes` no incluye 0 mismo, pero el ExitCode real ES 0, el `-and
$result.ExitCode -ne 0` de la segunda condición hace que NO se lance el
error de todas formas — un "0" siempre se trata como éxito aunque no
esté en la lista explícita. En la práctica casi nunca se manifestaba
porque todas las listas de códigos incluían 0, pero es una regla
implícita que no debería depender de eso.
**Fix:** lógica simplificada y directa: `$SuccessCodes -contains
$result.ExitCode`. Un ExitCode que no está en la lista SIEMPRE falla,
sea cual sea.

## 2. Integración ("que sean un proyecto único")

- **Portabilidad**: `C:\Intel\Deployment\...` estaba hardcodeado en
  cada script (el `$init` de cada `Start-Job`, las rutas de
  `imports\`/`logs\`). Ahora se resuelve solo, en base a dónde vive el
  propio módulo (`Get-DeploymentRoot`) — mover o renombrar la carpeta
  completa del proyecto ya no rompe nada.
- **Config centralizada**: la ruta del repositorio, los códigos de
  éxito por defecto, los límites de concurrencia — todo repetido (y a
  veces ligeramente distinto) entre los 7 scripts — ahora vive en un
  solo `config/config.psd1` (`config.example.psd1` como plantilla).
- **Un solo módulo** (`Module/Deployment/`) con las clases corregidas
  (`BaseDeploy`, `KbWindows`) y 7 funciones públicas
  (`Invoke-DeployApp`, `Invoke-CopyFiles`, `Invoke-CopyInstall`,
  `Invoke-RemoteCommand`, `Invoke-KbDeployment`, `Invoke-OfficeUpdate`,
  `Invoke-NessusScan`), usadas tanto por el menú interactivo como por
  los scripts de tarea programada — nada duplicado entre las dos formas
  de usarlo.
- **El bloque de orquestación de jobs**, copiado casi idéntico en los 7
  scripts originales (`$jobs = @(); foreach...Start-Job...Wait-Job`,
  con pequeñas variaciones — incluida la inconsistencia
  `$throttleLimit` vs `$throttletLimit` — typo presente en 3 de los 7
  scripts), es ahora una sola función (`Invoke-ThrottledDeployment`).

## 3. Optimización / mejoras nuevas (no existían antes)

- **Resumen final real**: ningún script original reportaba éxito/fallo
  agregado. Cada scriptblock terminaba con `exit 0` / `exit -1`, pero
  ese exit code de un `Start-Job` **no se lee en ningún lado de forma
  simple** — tras `Wait-Job`/`Remove-Job`, cada script solo imprimía
  "Procesamiento paralelo finalizado", sin importar cuántos equipos
  fallaron. Había que abrir el log a mano y buscar "ERROR"/"Failed"
  entre miles de líneas. Ahora cada scriptblock *devuelve* (no
  `exit`) un objeto de resultado, y `Write-DeploymentSummary` imprime
  un resumen real al final (total / OK / fallidos, con el detalle de
  cada equipo que falló).
- **Progreso visible**: `Invoke-ThrottledDeployment` con
  `-ShowProgress` muestra `Write-Progress` mientras encola y espera los
  jobs — antes no había ninguna señal de avance durante la corrida.
- **Listas de equipos más robustas**: `Read-ComputerList` recorta
  espacios/CRLF sueltos, quita líneas vacías y duplicados, y avisa si
  el archivo queda vacío — antes un archivo vacío (como
  `copy_install._computers.txt` o `execute_query_computers.txt` en el
  proyecto original) simplemente no hacía nada, sin ningún aviso.
- **Interfaz interactiva** (`Deploy-Menu.ps1`): antes, cualquier tarea
  puntual significaba abrir un `.ps1` en un editor, cambiar variables a
  mano, guardar, y hacer doble click en el `.cmd`. El menú hace lo
  mismo desde la consola, sin tocar código: elegís la tarea, de dónde
  sale la lista de equipos (un archivo de `imports\`, una ruta escrita
  a mano, o pegar hostnames directamente), y los parámetros — con
  confirmación antes de ejecutar.

## 4. Qué NO se tocó / limitaciones de esta pasada

- **No pude ejecutar nada en PowerShell real** en el entorno donde hice
  este trabajo (sin red para instalarlo, ni siquiera a los espejos base
  de Ubuntu — lo comprobé). La validación fue lectura cuidadosa +
  balance de llaves/paréntesis/comillas por script. Para cerrar esa
  brecha agregué `tests\Test-DeploymentToolkit.ps1`, que SÍ corre en tu
  máquina y valida sin `psexec`/red corporativa: sintaxis de los 23
  archivos, import del módulo, resolución de rutas, config, limpieza de
  listas de equipos, un ping real a loopback, logging, comparación de
  KBs, el patrón de `-KbFolder`, y el runner de jobs completo
  (`Invoke-ThrottledDeployment`) con un scriptblock de prueba. Correlo
  primero. Lo que sigue sin poder probarse sin infraestructura real es
  la copia/ejecución/Tenable vía `psexec.exe` — para eso, 2-3 equipos de
  prueba antes de un despliegue masivo.
- Las listas de `imports/*.txt` se copiaron tal cual (incluye algunos
  hostnames que parecen typos del propio archivo original, p. ej.
  `C0CRLPF3AN3LH` con un cero en vez de una O, o
  `CBNLPF3W3WER3X` — no los "corregí" porque no tengo forma de saber
  cuál era el hostname real correcto; quedan ahí y van a fallar el
  ping, como ya fallaban antes).
- `functions.ps1` (`getDate()`, una función de una línea) no se migró:
  quedó redundante frente a `Get-Date -Format 'yyyy-MM-dd'` usado
  directo donde hacía falta.
- No armé tareas programadas (Scheduled Tasks) de Windows en sí — los
  `scripts/run_*.ps1` están pensados para que las configures vos con
  los parámetros de cada tarea recurrente (KB mensual, Office, Nessus).

## 5. Pruebas ejecutadas (esta pasada) — ya sí con PowerShell real

A diferencia de la pasada anterior, esta vez sí corrí `tests\Test-DeploymentToolkit.ps1`
contra un PowerShell 7.4.6 real (instalado para esta sesión). Primera corrida:
27 OK / 10 fallidos. De esos 10, 8 eran un artefacto del entorno de pruebas
(usa `$env:TEMP`, que no viene definido por defecto en PowerShell sobre Linux
— en Windows, donde corre este toolkit de verdad, `$env:TEMP` siempre existe,
así que no aplica ahí). Con `$env:TEMP` fijado, quedaron 3 fallos reales, dos
de los cuales eran bugs genuinos del código (no del entorno):

### 5.1 `Invoke-ThrottledDeployment`/las 7 funciones públicas rechazaban una lista de equipos vacía con un error de binding, en vez del aviso-y-sigue que el propio código intentaba dar
```powershell
[Parameter(Mandatory)]
[string[]]$ComputerList,
```
En PowerShell, un parámetro **Mandatory** de tipo array rechaza un array
vacío (`@()`) directo en el *binding*, antes de que el cuerpo de la función
llegue a ejecutarse — con el error "Cannot bind argument to parameter
'ComputerList' because it is an empty array." Esto hacía que el chequeo
`if ($ComputerList.Count -eq 0) { Write-Warning ...; return @() }` dentro de
`Invoke-ThrottledDeployment` fuera código inalcanzable: nunca se llegaba a
correr, porque el binding fallaba antes. Y como las 7 funciones públicas
(`Invoke-CopyFiles`, `Invoke-CopyInstall`, etc.) reciben `-ComputerList` con
la misma firma y se lo pasan tal cual a `Invoke-ThrottledDeployment`, el
mismo problema aplicaba en cascada a los 7 `scripts\run_*.ps1`: si un archivo
de `imports\` quedaba vacío (el escenario real que motivó `Read-ComputerList`
en el punto 3), el script de todas formas explotaba con un error de binding,
en vez de avisar y salir en 0 como se buscaba.
**Fix:** agregado `[AllowEmptyCollection()]` a `$ComputerList` en las 7
funciones públicas y en `Invoke-ThrottledDeployment`, y a `$ClassPaths`
en `Invoke-ThrottledDeployment` (parámetro que también es Mandatory y
también puede llegar vacío cuando el `$Action` no necesita clases propias).

### 5.2 `Invoke-ThrottledDeployment`: `return @()` colapsaba a `$null` en quien lo llama, y `Write-DeploymentSummary` (Mandatory) reventaba con eso
Una vez arreglado 5.1, la lista vacía sí llegaba al cuerpo de la función —
pero `return @()` en PowerShell, al no tener la coma unaria, "desenrolla" el
array vacío en el stream de salida: quien hace `$results = Invoke-ThrottledDeployment ...`
termina con `$results = $null`, no con un array de 0 elementos. Cada una de
las 7 funciones públicas pasa ese `$results` directo a `Write-DeploymentSummary`,
que es `Mandatory` (no acepta `$null`, solo array vacío) — así que con lista
vacía el flujo real terminaba en "Cannot bind argument to parameter 'Results'
because it is null." Esto **no lo detectaba** la prueba original de "lista
vacía no explota" porque esa prueba llama a `Invoke-ThrottledDeployment` de
forma aislada y solo revisa `$results.Count`, sin encadenarlo hasta
`Write-DeploymentSummary` como sí hace el código real.
**Fix:** `return @()` → `return ,@()` (coma unaria) en los dos `return` de
`Invoke-ThrottledDeployment` que pueden devolver una colección vacía.
Agregada además una prueba de integración real
("Invoke-CopyFiles con lista de equipos vacia no explota (encadenado hasta
el resumen)") que llama a una función pública de punta a punta con lista
vacía, para que este tipo de bug de "se ve bien en el test unitario pero
truena en el camino real" no vuelva a colarse.

### 5.3 Falso positivo del propio test (no del toolkit): `Classes\KbWindows.ps1` "no parseaba"
El loop de sintaxis del test original parsea cada `.ps1` de forma aislada
con `Parser::ParseFile`. `KbWindows.ps1` declara `class KbWindows : BaseDeploy`,
y el parser necesita el tipo `[BaseDeploy]` ya resuelto en la sesión para
validar la herencia — parseado solo, siempre da "Unable to find type
[BaseDeploy]" (se reproduce igual en Windows; no es un problema de este
entorno). En el uso real esto nunca pasa: `BaseDeploy.ps1` siempre se
dot-sourcea antes que `KbWindows.ps1` (ver `Invoke-KbDeployment.ps1` y el
propio import del módulo). **Fix (solo en el test):** `Classes\` se excluye
del loop genérico y se agrega un caso dedicado que parsea `BaseDeploy.ps1` +
`KbWindows.ps1` concatenados, con la herencia ya resuelta.

### Resultado final
**37 OK / 0 fallidos.** Sigue sin poder probarse sin infraestructura real
—copia/ejecución/Tenable vía `psexec.exe`— lo mismo que ya decía la sección
4: antes de un despliegue masivo, corré cualquiera de las tareas contra 2-3
equipos de prueba.

## 6. Interfaz gráfica e integración con el módulo

Se agregó `Deploy-Gui.ps1` (WPF) como tercera forma de usar el mismo
módulo, sin duplicar nada: cada tarea de la ventana arma un splat y llama a
la misma función pública que ya usaban el menú de consola y los
`scripts\run_*.ps1`. Ver `ARQUITECTURA.md` sección 7 para el detalle de
diseño. Lo que hizo falta agregarle al framework para que eso fuera posible:

### 6.1 `-ProgressQueue`: progreso en vivo, equipo por equipo
`Invoke-ThrottledDeployment` no devolvía **nada** hasta que terminaba el
último equipo. Servía para consola (donde el log se puede mirar aparte),
pero una ventana necesita saber qué está pasando *mientras* pasa. Se agregó
un parámetro opcional `-ProgressQueue` (un `ConcurrentQueue[object]`,
thread-safe porque lo escribe el runspace de trabajo y lo lee el hilo de
interfaz) donde se encola un evento `JobStart` por equipo encolado y un
`JobDone` apenas termina, con su `Success` ya resuelto, más un `BatchEnd`
al cerrar el lote.

Detalle importante de implementación: el peek del resultado usa
`Receive-Job -Keep`, que mira la salida del job **sin consumirla**. Sin
`-Keep`, el reporte de progreso le robaría el resultado a la recolección
final y el resumen quedaría vacío. Hay una prueba que verifica justamente
eso (que los 3 equipos sigan llegando al resumen después de haber sido
reportados por la cola).

Con la cola conectada el polling interno pasa de 1 s a 250 ms, que es lo
que hace que la consola se sienta en vivo en vez de avanzar a los saltos.
Sin cola, todo queda exactamente como antes.

### 6.2 `-CancelFlag`: poder cancelar un lote a medias
No había forma de detener un despliegue una vez lanzado. Se agregó
`-CancelFlag` (un hashtable sincronizado con una clave `Cancel`) que los
dos loops de `Invoke-ThrottledDeployment` chequean: deja de encolar equipos
nuevos, hace `Stop-Job` de los que sigan corriendo, deja constancia en el
log y devuelve los resultados parciales. Tiene que frenarse desde adentro
del runspace porque `Start-Job` registra los jobs por runspace — desde el
hilo de UI, `Get-Job` no los ve.

Ambos parámetros son opcionales y pass-through en las 7 funciones públicas;
desde consola o tarea programada simplemente no se pasan y el
comportamiento es idéntico al anterior (hay una prueba para eso también).

### 6.3 Bug real encontrado en el camino: archivos sin BOM
Ningún `.ps1`/`.psd1` del proyecto tenía BOM, pero casi todos tienen
acentos. **Windows PowerShell 5.1 —el que corre esto en producción— lee un
archivo sin BOM como ANSI, no como UTF-8.** O sea: en la máquina donde esto
realmente se usa, cada tilde y cada ñ se estaba corrompiendo. No es solo
cosmético en los comentarios: afecta los `Write-Warning`, los textos del
menú interactivo (`Deploy-Menu.ps1` está lleno de "¿Qué querés hacer?",
"Elegí una opción", "Desplegar aplicación") y —peor— las líneas que
`WriteLogSafe` escribe al archivo de log ("No se encontró el item en
destino", "Salida vacía al consultar versión de KB").

**Fix:** BOM UTF-8 agregado a los 22 archivos con caracteres no-ASCII, más
una prueba que falla si alguno vuelve a guardarse sin BOM.

### 6.4 Qué se probó de esto y qué no
La suite pasó a **44 OK / 0 fallidos**, con pruebas nuevas para la cola de
progreso, la cancelación, el pass-through en las 7 funciones, el BOM, y una
que compara los campos del formulario de la GUI contra los parámetros
reales de cada función (si alguien agrega un campo con el nombre mal
escrito, falla ahí y no con el despliegue lanzado).

Lo que **no** se pudo ejecutar: la ventana en sí. WPF necesita Windows, y
el entorno donde se armó esto es Linux. Lo que sí se validó de
`Deploy-Gui.ps1` sin poder abrirlo: que el archivo parsea sin errores de
sintaxis, que el XAML es XML bien formado, que los 27 controles que el
script busca por nombre existen realmente en el XAML, que los `x:Key` de
estilos que usa están definidos, y que cada campo del formulario
corresponde a un parámetro real del módulo. Queda pendiente abrirla una vez
en una máquina Windows antes de usarla contra equipos.

## 7. Datos del entorno fuera del código, y límite Public/Private

### 7.1 La GUI moría al arrancar: helpers no exportados
`Deployment.psm1` exportaba solo las 7 tareas. Pero los tres puntos de
entrada (`Deploy-Gui.ps1`, `Deploy-Menu.ps1`, los 7 `scripts\run_*.ps1`)
corren **fuera** del módulo y necesitan `Get-DeploymentConfig` y
`Read-ComputerList` antes de poder invocar una tarea. Al no estar
exportadas, esas llamadas fallaban con *"The term 'Get-DeploymentConfig'
is not recognized"*: la GUI no abría y el menú moría al elegir tarea.

La suite no lo detectaba porque dot-sourcea `Private\*.ps1` a mano para
probar los internos: en las pruebas existían, en el uso real no.

**Fix:** las dos funciones se movieron a `Public\`, que es donde
correspondía — son API, no internos. Así `Private\` vuelve a significar
"nadie de afuera lo toca". Se agregó una prueba que parsea los puntos de
entrada, busca qué funciones del módulo llaman, y verifica contra
`ExportedFunctions` (no contra `Get-Command`, que vería lo dot-sourceado).

### 7.2 Sin datos del entorno en el código
Se sacaron del código **todos** los datos de infraestructura, que estaban
repartidos en 6 archivos: la IP del repositorio (`Get-DeploymentConfig`,
`KbWindows`, `Deploy-Menu`, `README`, `config.example`) y el UUID del scan
de Tenable (`BaseDeploy`, `Get-DeploymentConfig`, `config.example`).
También se quitó el GUID del manifiesto, que ahora queda comentado para
que cada quien genere el suyo con `New-Guid`.

Ahora todos viven **solo** en `config\config.psd1`, que no se versiona.
En el código quedan vacíos con un comentario que indica el formato
esperado. `BaseDeploy.UpdateTenable()` pasó a recibir ruta y UUID como
parámetros (via propiedades que setean las funciones públicas desde la
config) y avisa con un mensaje claro si falta alguno.

Hay una prueba que falla si vuelve a entrar una IP o un UUID a cualquier
`.ps1`/`.psd1`/`.psm1`.

### 7.3 Bugs encontrados de paso
- **Defaults muertos en métodos de clase.** `KbWindows.DeployKB` y
  `RunKbWindows` declaraban valores por defecto en sus parámetros. Las
  clases de PowerShell **aceptan la sintaxis pero ignoran los defaults**
  (`HasDefaultValue` queda en `False`), así que era código muerto que
  encima dejaba la ruta del repositorio escrita. Es el mismo problema que
  el punto 1.1, que había quedado sin corregir en `KbWindows`.
- **Riesgo de desalineación en `$actionArgs`.** Se pasan posicionalmente
  a `Start-Job`, así que el orden del hashtable tiene que coincidir con el
  `param()` del scriptblock. Al agregar los datos de Tenable casi se
  introduce ese bug. Hay una prueba nueva que compara ambos órdenes en las
  7 tareas por AST.
- **`DefaultElapsedTime` era una clave muerta**: la config la definía y
  ninguna función la leía. Ahora las 4 tareas con `-ElapsedTime` caen a
  ese valor si no se les pasa uno explícito.

**Resultado: 55 OK / 0 fallidos.**

## 8. Detalle por equipo en OK / Fallidos (web y GUI)

En "Progreso y consola en vivo", los contadores **OK** y **Fallidos** ahora
son clickeables: OK abre la lista de hostnames que salieron bien, Fallidos
abre cada hostname con su error. Se actualiza en vivo, y "Copiar
hostnames" deja los nombres uno por línea para armar un `.txt` de
reintento. Mismo comportamiento en `Deploy-Web.ps1` y `Deploy-Gui.ps1`.

- **Módulo**: `Write-DeploymentSummary` devuelve además `Succeeded` (los
  resultados OK). `Errors` no cambió, así que nada de lo que ya lo usaba
  se rompe.
- **Web**: ruta nueva `/api/resultados?tipo=ok|fail`.
- **Bug de PowerShell 7.4 encontrado en el camino**: `@($lista)` sobre un
  `List[object]` que contiene `pscustomobject` truena con *"Argument types
  do not match"*. Las dos interfaces usan `foreach` o `.ToArray()` para
  esas listas. Y `$x = if (...) { @(...) }` desenrolla el array: con un
  solo equipo, el JSON salía como un string suelto en vez de una lista.
  Las dos cosas salieron probando la interfaz web en modo `-Simular`.
- **Prueba nueva**: el resumen de `Invoke-SimulatedDeployment` trae los
  hostnames OK en `Succeeded` y el fallido con su mensaje en `Errors`.

**Resultado: 59 OK / 0 fallidos.** La lógica nueva de la GUI WPF se probó
aparte, con los tipos de WPF reemplazados por stubs (WPF no existe fuera de
Windows): 25 chequeos OK. El render real de la ventana hay que verlo en
Windows.

## 9. Varias tareas a la vez (web y GUI)

Antes las dos interfaces corrían una sola tarea por vez: la web contestaba
"Ya hay un despliegue en curso" y la GUI bloqueaba el menú mientras algo
corría. Era un límite de las interfaces, no del módulo. Ahora se pueden
correr varias tareas **distintas** en paralelo (por ejemplo, desplegar una
aplicación mientras se copian archivos), hasta `-MaxTareas` (2 por
defecto, hasta 7) en `Deploy-Web.ps1` y en `Deploy-Gui.ps1`.

- **Fichas de ejecuciones** en "Progreso y consola en vivo": una por tarea,
  con su avance y sus OK/Fallidos. Click en una ficha y la barra, la
  consola y el detalle OK/Fallidos pasan a mostrar esa tarea.
- **"Detener" se movió** de la tarjeta de ejecución a "Progreso y consola
  en vivo", y frena solo la tarea que se está viendo. "Ejecutar" sigue
  actuando sobre la tarea elegida en el menú.
- **Bloqueos**: la misma tarea no corre dos veces a la vez (compartiría el
  log) y no se pasa del máximo. "Ejecutar" se deshabilita y se muestra el
  motivo.
- **El módulo no se tocó.** Cada tarea ya escribía en su propio log con su
  propio mutex.
- **Web**: `/api/progress` devuelve todas las corridas en un pedido;
  `/api/resultados` y `/api/stop` reciben `tarea=<id>`; `/api/init` informa
  `maxTareas`. Si se recarga la página, las fichas se recuperan (la consola
  de lo ya leído no).
- **GUI**: el estado que era único (`$script:Sync`, `$script:PsWorker`,
  `$script:LogOffset`, contadores...) pasó a un objeto por corrida
  (`New-RunState`), y un solo timer atiende a todas. El relanzamiento en
  STA pasa `-MaxTareas`.
- **Prueba nueva**: dos despliegues simulados en runspaces separados, al
  mismo tiempo, sin cruzar equipos, líneas de log ni eventos de progreso.

**Resultado: 60 OK / 0 fallidos.** La web se probó en `-Simular` de punta a
punta: dos tareas en paralelo, rechazo de la misma tarea y de una tercera,
consola separada por tarea, detener una sin tocar la otra, recarga de la
página y vista en celular. La lógica de la GUI se probó con los tipos de WPF
reemplazados por stubs (38 chequeos OK). La ventana WPF real hay que verla
en Windows.

## 10. Sin magic strings: `Deployment.Constants.psd1`

Los valores con significado propio estaban escritos a mano y repetidos
entre archivos: el nombre de log y de mutex de cada tarea (módulo +
catálogo), la ruta `temp\RemoteInstall` (clase, módulo, catálogo, menú,
script), el formato de fecha del log (6 lugares), los timeouts por tarea
(hasta 4 lugares), el patrón de `-KbFolder` (3), los success codes (3),
además de números sueltos en `BaseDeploy` (ping, mutex, reintentos de
copia, 420 s de Tenable) y en las interfaces (puerto, intervalos, máximo de
tareas). Ahora cada uno está definido una sola vez en
`Module/Deployment/Deployment.Constants.psd1` y todos lo leen de
`Get-DeploymentConfig`. Ver `ARQUITECTURA.md` 3.6.

- **`config.psd1` solo sobrescribe lo ajustable** (sección `Tunable`:
  datos del entorno, timeouts, throttle, success codes, rutas de
  herramientas, y `TaskDefaults` por tarea). Una clave fija se ignora con
  un aviso. Antes aceptaba cualquier clave.
- **Inconsistencia corregida**: el timeout por defecto de "Copiar e
  instalar" era 15 min en la GUI y la web, pero 0 (sin límite) en el menú,
  `scripts\run_copy_install.ps1` y el módulo. Ahora es **15 min en todos
  lados** (`TaskDefaults.copyinstall.ElapsedTime = 900`).
- **Clases**: leen sus valores de `[BaseDeploy]::Settings`, que
  `Invoke-ThrottledDeployment` carga en cada job. Se quitó el default
  `"temp\RemoteInstall"` del parámetro de `CopyRemote`: era código muerto
  (los métodos de clase ignoran los defaults) y todos los llamadores ya
  pasan el valor.
- **`scripts\`**: `-ElapsedTimeMinutes`, `-RemoteSubPath` y `-ThrottleLimit`
  ya no tienen default propio; sin pasarlos, se usa el de la tarea.
- **`-KbFolder`, `-MaxTareas` y `-Port`** se validan/resuelven en el
  cuerpo: un atributo `[ValidatePattern()]`/`[ValidateRange()]` solo acepta
  literales. El máximo de `-MaxTareas` pasó a ser la cantidad de tareas del
  catálogo (hoy 7, igual que antes).
- **Pruebas nuevas** (5): identidad única por tarea en las constantes; qué
  sobrescribe y qué no `config.psd1`; mismos defaults en catálogo y módulo;
  `-KbFolder` inválido con mensaje claro; y ningún valor de texto de las
  constantes escrito como literal en un `.ps1` (contra `main` esa prueba da
  48 hallazgos).

**Resultado: 66 OK / 0 fallidos** (PowerShell 7 en macOS). Además: un job
real (`Invoke-NessusScan` contra `127.0.0.1`) confirmó que la config llega
a las clases dentro del `Start-Job`, y la web en `-Simular` se probó por su
API (catálogo, `/api/init`, una corrida de "Copiar e instalar").

## 11. `scripts\run_*.ps1` con un archivo de equipos vacío

**Bug que ya estaba antes de la sección 10.** Con un archivo de `imports\`
vacío (o solo con comentarios), los 7 wrappers de `scripts\` fallaban con
*"Cannot bind argument to parameter 'ComputerList' because it is null"*,
en vez del aviso-y-sigue que describe el README.

Causa: la misma trampa de la sección 5.2. `Read-ComputerList` termina con
`return @($clean)`, y un array vacío puesto en la salida se desenrolla a
nada, así que `$computers = Read-ComputerList ...` quedaba en `$null`. La
GUI y la web no tenían el problema porque ya llamaban con
`@(Read-ComputerList ...)`, y el menú corta antes por `.Count -eq 0`. La
prueba de la sección 5.1 no lo veía porque le pasa `@()` directo a
`Invoke-CopyFiles`, sin pasar por `Read-ComputerList`.

- **Arreglo**: los 7 wrappers ahora asignan
  `$computers = @(Read-ComputerList -Path $computersPath)`, igual que la GUI
  y la web. `Read-ComputerList` no se tocó: devolver con coma unaria
  (`return ,@(...)`) habría roto a esos otros llamadores, que con `@(...)`
  recibirían un array de un solo elemento con la lista entera adentro.
- **Pruebas nuevas** (2): lista vacía de `Read-ComputerList` pasada a una
  tarea real; y una que recorre los puntos de entrada y falla si alguno
  asigna `Read-ComputerList` sin `@()` (contra `main` marca los 7 scripts).

**Resultado: 68 OK / 0 fallidos.** Además, `run_copy_install`,
`run_copy_files`, `run_kb_deployment` y `run_nessus_scan` se corrieron de
verdad con un archivo vacío (sobre una copia del proyecto, para no escribir
en `logs\`): salen con código 0 y dejan el resumen con 0 equipos.
