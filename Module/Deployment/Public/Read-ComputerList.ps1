# Private/Read-ComputerList.ps1
#
# Lee un archivo de hostnames y lo limpia: recorta espacios/CRLF sueltos,
# descarta lineas vacias y comentarios, y quita duplicados
# (case-insensitive, ya que "citstlpf3ap5zw" y "CITSTLPF3AP5ZW" son el
# mismo equipo). Antes cada script hacia `Get-Content $ruta` a secas - un
# archivo vacio (como copy_install._computers.txt o
# execute_query_computers.txt en el proyecto original) simplemente hacia
# que el foreach no iterara nada, SIN ningun aviso de que la lista estaba
# vacia por error (por ejemplo una ruta de archivo mal tipeada).
#
# Formatos que acepta (todos mezclables en el mismo archivo):
#
#     EQUIPO-01                 un hostname por linea, lo habitual
#     EQUIPO-02, EQUIPO-03      varios en una linea, separados por coma
#     EQUIPO-04; EQUIPO-05      o por punto y coma
#     EQUIPO-06  EQUIPO-07      o por espacios/tabs (pegado desde un Excel)
#     "EQUIPO-08"               con comillas alrededor
#     # esto es un comentario   lineas que empiezan con # o //
#
# Partir por espacios es seguro porque un hostname de Windows nunca puede
# tener espacios. Se agrego porque pegar la lista desde un mail o una
# planilla deja todo en una sola linea, y antes eso se leia como UN equipo
# con un nombre larguisimo, que despues fallaba el ping sin explicacion.
function Read-ComputerList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "No existe el archivo de equipos: $Path"
    }

    $raw = Get-Content -Path $Path -ErrorAction Stop

    $clean = foreach ($line in $raw) {
        if ($null -eq $line) { continue }

        # Saca el BOM que queda pegado al primer equipo del archivo. Hay
        # dos formas en que aparece:
        #   1. Como caracter U+FEFF, cuando el .txt se guardo como UTF-8 y
        #      alguien lo leyo sin que se descartara el BOM.
        #   2. Como los tres caracteres 0xEF 0xBB 0xBF sueltos, que es lo
        #      que se ve cuando un archivo UTF-8 con BOM se lee como ANSI
        #      (el default de Get-Content en PowerShell 5.1).
        # Sin esto, el primer equipo arrastra basura invisible adelante y
        # falla el ping sin que se entienda por que.
        $l = $line.TrimStart([char]0xFEFF)
        if ($l.Length -ge 3 -and
            [int]$l[0] -eq 0xEF -and [int]$l[1] -eq 0xBB -and [int]$l[2] -eq 0xBF) {
            $l = $l.Substring(3)
        }
        $l = $l.Trim()

        if ($l -eq '' -or $l.StartsWith('#') -or $l.StartsWith('//')) { continue }

        foreach ($token in ($l -split '[,;\s]+')) {
            $t = $token.Trim().Trim('"').Trim("'").Trim()
            if ($t -ne '') { $t }
        }
    }

    $clean = @($clean | Select-Object -Unique)

    if ($clean.Count -eq 0) {
        Write-Warning "El archivo de equipos '$Path' esta vacio (o solo tiene lineas en blanco/comentarios)."
    }

    return @($clean)
}
