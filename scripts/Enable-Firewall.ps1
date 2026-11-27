<#
  Crea UNA regla de entrada de Windows Firewall, acotada a: este node.exe, el puerto del servidor y SOLO redes privadas.
  No desactiva ninguna protección. Requiere administrador (el instalador la lanza con elevación UAC).
  Uso:  Enable-Firewall.ps1 [-Remove]
#>
param([switch]$Remove, [string]$Config)
$Root = Split-Path $PSScriptRoot -Parent
$name = 'Cloud Phone Server'
$id = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $id.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Remove) { $argList += '-Remove' }
    if ($Config) { $argList += '-Config'; $argList += """$Config""" }
    Start-Process powershell -Verb RunAs -ArgumentList $argList -Wait
    exit
}
Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
if ($Remove) { Write-Host 'Regla eliminada.'; exit }
$port = 8443
$cfgPath = if ($Config) { $Config } else { Join-Path $Root 'cloudphone-config.json' }
if (Test-Path $cfgPath) { try { $port = [int]((Get-Content $cfgPath -Raw | ConvertFrom-Json).server.port) } catch { } }
$node = Join-Path $Root 'node\node.exe'
if (-not (Test-Path $node)) { $node = (Get-Command node).Source }
New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -Profile Private -Program $node -Description 'Permite que tu iPhone se conecte al servidor Cloud Phone (solo redes privadas).' | Out-Null
Write-Host "Regla creada: TCP $port, perfil Privado, solo $node"
