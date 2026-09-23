# Private/Write-DeploymentSummary.ps1
#
# Ninguno de los 7 scripts originales imprimía un resumen real al
# terminar — solo "Procesamiento paralelo finalizado", sin importar
# cuántos equipos fallaron. Esta función sí lo hace, a partir de los
# resultados que devuelve Invoke-ThrottledDeployment.
function Write-DeploymentSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Results,

        [string]$LogPath
    )

    $total = $Results.Count
    $ok = @($Results | Where-Object { $_.Success })
    $failed = @($Results | Where-Object { -not $_.Success })

    Write-Host ""
    Write-Host "==================== RESUMEN ====================" -ForegroundColor Cyan
    Write-Host "Total equipos procesados : $total"
    Write-Host "OK                       : $($ok.Count)" -ForegroundColor Green
    Write-Host "Fallidos                 : $($failed.Count)" -ForegroundColor $(if ($failed.Count -gt 0) { 'Red' } else { 'Green' })

    if ($failed.Count -gt 0) {
        Write-Host ""
        Write-Host "Equipos con error:" -ForegroundColor Yellow
        $failed | ForEach-Object {
            Write-Host ("  - {0,-20} {1}" -f $_.Equipo, $_.Message) -ForegroundColor Red
        }
    }
    Write-Host "===================================================" -ForegroundColor Cyan

    if ($LogPath) {
        $summaryLine = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | RESUMEN | Total=$total OK=$($ok.Count) Fallidos=$($failed.Count)" +
            $(if ($failed.Count -gt 0) { " | Equipos con error: " + (($failed | ForEach-Object { $_.Equipo }) -join ', ') } else { "" })
        Add-Content -Path $LogPath -Value $summaryLine -Encoding UTF8
    }

    # Succeeded (los resultados OK) se agrega para que las interfaces puedan
    # listar QUE equipos salieron bien, no solo cuantos. Errors se mantiene
    # con el mismo nombre y contenido de siempre para no romper a nadie.
    return [pscustomobject]@{
        Total     = $total
        Ok        = $ok.Count
        Failed    = $failed.Count
        Succeeded = $ok
        Errors    = $failed
    }
}
