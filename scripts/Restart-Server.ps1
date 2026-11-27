# Reinicia el servidor Cloud Phone (detención limpia + inicio + abrir panel)
$here = $PSScriptRoot
& (Join-Path $here 'Stop-Server.ps1')
& (Join-Path $here 'Start-Server.ps1') -OpenPanel
