<#
  Inicia el servidor Cloud Phone en segundo plano (sin ventana) y, opcionalmente, abre el panel de administración.
  Uso:  Start-Server.ps1 [-OpenPanel]
#>
param([switch]$OpenPanel, [string]$Config)
$ErrorActionPreference = 'Stop'

$Root = Split-Path $PSScriptRoot -Parent
$env:CLOUDPHONE_CONFIG = if ($Config) { $Config } else { Join-Path $Root 'cloudphone-config.json' }
$serverDir = Join-Path $Root 'server'
$node = Join-Path $Root 'node\node.exe'
if (-not (Test-Path $node)) { $c = Get-Command node -ErrorAction SilentlyContinue; if ($c) { $node = $c.Source } else { throw 'No se encuentra Node.js (node\node.exe).' } }

function Get-Cfg {
    $p = $env:CLOUDPHONE_CONFIG
    if (Test-Path $p) { try { return Get-Content $p -Raw | ConvertFrom-Json } catch { } }
    return $null
}
$cfg = Get-Cfg
$adminPort = 8444; if ($cfg -and $cfg.server -and $cfg.server.adminPort) { $adminPort = [int]$cfg.server.adminPort }
$dataDir = Join-Path $Root 'data'; if ($cfg -and $cfg.paths -and $cfg.paths.data) { $dataDir = $cfg.paths.data }
$logDir = Join-Path $Root 'logs'; if ($cfg -and $cfg.paths -and $cfg.paths.logs) { $logDir = $cfg.paths.logs }
New-Item -ItemType Directory -Force $dataDir, $logDir | Out-Null
$pidFile = Join-Path $dataDir 'server.pid'

function Test-Up { try { $c = New-Object Net.Sockets.TcpClient; $c.Connect('127.0.0.1', $adminPort); $c.Close(); return $true } catch { return $false } }

if (Test-Up) {
    Write-Host 'El servidor ya está en marcha.'
} else {
    $p = Start-Process -FilePath $node -ArgumentList 'src\index.js' -WorkingDirectory $serverDir -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $logDir 'console.log') -RedirectStandardError (Join-Path $logDir 'console-error.log')
    $deadline = (Get-Date).AddSeconds(20)
    while (-not (Test-Up)) {
        if ($p.HasExited) {
            $err = ''; $ef = Join-Path $logDir 'console-error.log'; $of = Join-Path $logDir 'console.log'
            if (Test-Path $ef) { $err = (Get-Content $ef -Tail 8) -join "`n" }
            if (-not $err -and (Test-Path $of)) { $err = (Get-Content $of -Tail 8) -join "`n" }
            throw "El servidor se cerró al iniciar:`n$err"
        }
        if ((Get-Date) -gt $deadline) { throw 'El servidor no respondió en 20 s. Revisa la carpeta logs.' }
        Start-Sleep -Milliseconds 400
    }
    Write-Host 'Servidor iniciado.'
}

if ($OpenPanel) {
    $tokenFile = Join-Path $dataDir 'admin.token'
    $frag = ''
    if (Test-Path $tokenFile) { $frag = '#t=' + (Get-Content $tokenFile -Raw).Trim() }
    Start-Process "http://127.0.0.1:$adminPort/$frag"
}
