<#
  Construye dist\CloudPhone-Setup.exe (instalador Inno Setup) y dist\CloudPhone-Portable.zip.
  Requisitos en ESTE equipo de compilación: Node.js (se incluye su node.exe) y la carpeta D:\CloudPhone\scrcpy con scrcpy-server.jar
  (o pásala con -ScrcpyJar). Si Inno Setup no está, se descarga del sitio oficial y se verifica su firma Authenticode.
#>
param(
    [switch]$InstallInno,   # solo si se indica: descarga e instala Inno Setup (oficial, firma verificada). Sin esto, se usa el que ya exista.
    [string]$ScrcpyJar = 'D:\CloudPhone\scrcpy\scrcpy-server.jar',
    [string]$InnoDir = $(if (Test-Path 'D:\') { 'D:\Tools\InnoSetup' } else { Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6' })
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Proj = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $Proj 'dist'; $stage = Join-Path $dist 'stage'
$SCRCPY_SHA256 = '764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536'   # scrcpy-server v5.0.1 (Genymobile)

function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }

# ---------- 1. Inno Setup ----------
Step 'Inno Setup'
$iscc = @("$InnoDir\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc -and -not $InstallInno) {
    Write-Host 'Inno Setup no está instalado: se construirá SOLO la versión portable.' -ForegroundColor Yellow
    Write-Host 'Para generar también CloudPhone-Setup.exe: instala Inno Setup 6 desde https://jrsoftware.org/isdl.php o ejecuta build.ps1 -InstallInno.' -ForegroundColor Yellow
}
if (-not $iscc -and $InstallInno) {
    $tmp = Join-Path $env:TEMP ('inno-' + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory $tmp | Out-Null
    $exe = Join-Path $tmp 'is.exe'
    Write-Host 'Descargando Inno Setup 6.7.4 (repositorio oficial jrsoftware/issrc)…'
    Invoke-WebRequest -UseBasicParsing 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe' -OutFile $exe
    $sig = Get-AuthenticodeSignature $exe
    if ($sig.Status -ne 'Valid') { throw "La firma del instalador de Inno Setup NO es válida ($($sig.Status)). Abortado." }
    Write-Host "Firma válida: $($sig.SignerCertificate.Subject)"
    & $exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER "/DIR=$InnoDir" | Out-Null
    Remove-Item $tmp -Recurse -Force
    $iscc = Join-Path $InnoDir 'ISCC.exe'
    if (-not (Test-Path $iscc)) { throw 'No se pudo instalar Inno Setup.' }
}
if ($iscc) { Write-Host "ISCC: $iscc" }

# ---------- 2. Preparar dist\stage ----------
Step 'Preparando archivos'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force "$stage\server", "$stage\scripts", "$stage\docs", "$stage\assets", "$stage\node", "$stage\runtime\scrcpy" | Out-Null

# node.exe
$nodeExe = (Get-Command node).Source
Copy-Item $nodeExe "$stage\node\node.exe"
Write-Host ("Node.js: " + (& $nodeExe --version))

# servidor (solo producción)
Copy-Item "$Proj\server\src" "$stage\server\src" -Recurse
Copy-Item "$Proj\server\panel" "$stage\server\panel" -Recurse
Copy-Item "$Proj\server\package.json", "$Proj\server\package-lock.json" "$stage\server\"
Push-Location "$stage\server"; npm ci --omit=dev --no-fund --no-audit 2>&1 | Select-Object -Last 2; Pop-Location
if (-not (Test-Path "$stage\server\node_modules\ws")) { throw 'Falta node_modules\ws en el paquete.' }

# scrcpy-server (verificado)
if (-not (Test-Path $ScrcpyJar)) { throw "No existe $ScrcpyJar" }
if ((Get-FileHash $ScrcpyJar -Algorithm SHA256).Hash.ToLower() -ne $SCRCPY_SHA256) { throw 'scrcpy-server.jar no coincide con el SHA-256 oficial de v5.0.1' }
Copy-Item $ScrcpyJar "$stage\runtime\scrcpy\scrcpy-server.jar"

# scripts, docs, config de ejemplo, avisos
Copy-Item "$Proj\scripts\*" "$stage\scripts\"
Copy-Item "$Proj\docs\LEEME-INSTALACION.txt", "$Proj\docs\THIRD-PARTY-NOTICES.txt" "$stage\docs\"
Copy-Item "$Proj\server\cloudphone-config.example.json" "$stage\cloudphone-config.example.json"
Get-ChildItem "$Proj\docs\*.md" | Copy-Item -Destination "$stage\docs\"

# lanzadores para la versión portable (.cmd)
$cmds = @{
  'Instalar-Android.cmd'  = '@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Setup-Android.ps1"'
  'Iniciar-CloudPhone.cmd' = '@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0scripts\Start-Server.ps1" -OpenPanel'
  'Detener-CloudPhone.cmd' = '@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Stop-Server.ps1"'
}
foreach ($k in $cmds.Keys) { Set-Content (Join-Path $stage $k) ($ExecutionContext.InvokeCommand.ExpandString($cmds[$k])) -Encoding ASCII }

# icono .ico (PNG 256 embebido) a partir del PNG del app iOS
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile("$Proj\ios\CloudPhone\Assets.xcassets\AppIcon.appiconset\icon-1024.png")
$bmp = New-Object System.Drawing.Bitmap 256, 256; $g = [System.Drawing.Graphics]::FromImage($bmp)
$g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($src, 0, 0, 256, 256); $g.Dispose(); $src.Dispose()
$ms = New-Object IO.MemoryStream; $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
$png = $ms.ToArray(); $ms.Dispose()
$fs = [IO.File]::Create("$stage\assets\cloudphone.ico"); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
$bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([UInt16]1); $bw.Write([UInt16]32); $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]22)
$bw.Write($png); $bw.Close()

# ---------- 3. Compilar instalador ----------
if ($iscc) {
    Step 'Compilando instalador'
    & $iscc "$PSScriptRoot\CloudPhone.iss" | Select-Object -Last 12
    if ($LASTEXITCODE -ne 0) { throw "ISCC falló ($LASTEXITCODE)" }
} else { Step 'Instalador omitido (sin Inno Setup)' }

# ---------- 4. Versión portable ----------
Step 'Creando versión portable'
$zip = Join-Path $dist 'CloudPhone-Portable.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$stage\*" -DestinationPath $zip -CompressionLevel Optimal

Step 'Resultado'
Get-ChildItem $dist -File | ForEach-Object { "{0,-28} {1,8:N1} MB   SHA-256 {2}" -f $_.Name, ($_.Length / 1MB), (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
