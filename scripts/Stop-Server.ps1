<#
  Detiene el servidor Cloud Phone de forma limpia (apaga el Android y cierra conexiones).
  Si no responde en 90 s, termina el proceso.
#>
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$cfgPath = Join-Path $Root 'cloudphone-config.json'
$adminPort = 8444; $dataDir = Join-Path $Root 'data'
if (Test-Path $cfgPath) {
    try { $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
          if ($c.server.adminPort) { $adminPort = [int]$c.server.adminPort }
          if ($c.paths.data) { $dataDir = $c.paths.data } } catch { }
}
$pidFile = Join-Path $dataDir 'server.pid'
$tokenFile = Join-Path $dataDir 'admin.token'
$srvPid = $null; if (Test-Path $pidFile) { $srvPid = [int](Get-Content $pidFile -Raw).Trim() }

$graceful = $false
if (Test-Path $tokenFile) {
    try {
        $h = @{ 'X-Admin-Token' = (Get-Content $tokenFile -Raw).Trim() }
        Invoke-RestMethod "http://127.0.0.1:$adminPort/admin/shutdown" -Method Post -Headers $h -Body '{}' -ContentType 'application/json' -TimeoutSec 5 | Out-Null
        $graceful = $true
    } catch { }
}
if ($srvPid) {
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Process -Id $srvPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    $p = Get-Process -Id $srvPid -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match 'node') { Stop-Process -Id $srvPid -Force; Write-Host 'Servidor terminado a la fuerza.' }
    else { Write-Host 'Servidor detenido.' }
} elseif (-not $graceful) { Write-Host 'El servidor no estaba en marcha.' } else { Write-Host 'Servidor detenido.' }
