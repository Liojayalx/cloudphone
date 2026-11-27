<#
  Prepara el entorno Android del Cloud Phone. Es idempotente: detecta lo que ya está instalado y no lo vuelve a descargar.
  Descarga SOLO de fuentes oficiales y verifica sumas de comprobación:
    - JDK 17 (Eclipse Temurin)       api.adoptium.net / github.com/adoptium     (SHA-256 publicado)
    - Android command-line tools     dl.google.com                              (SHA-1 del manifiesto oficial de Google)
    - platform-tools, emulator e imagen del sistema (Android 13 google_apis x86_64)   dl.google.com via sdkmanager
  Uso:  Setup-Android.ps1 [-ApiLevel 33] [-AcceptLicense]
#>
param([int]$ApiLevel = 33, [switch]$AcceptLicense, [switch]$NoPause)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path $PSScriptRoot -Parent
$cfgPath = Join-Path $Root 'cloudphone-config.json'
$runtime = Join-Path $Root 'runtime'
$sdk = Join-Path $runtime 'sdk'; $jdkDir = Join-Path $runtime 'jdk'; $dl = Join-Path $runtime 'downloads'
if (Test-Path $cfgPath) { try { $c = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if ($c.paths.androidSdk) { $sdk = $c.paths.androidSdk }; if ($c.paths.jdk) { $jdkDir = $c.paths.jdk } } catch { } }
New-Item -ItemType Directory -Force $runtime, $dl, $sdk, $jdkDir | Out-Null

function Step($t) { Write-Host "`n== $t" -ForegroundColor Cyan }
function Ok($t) { Write-Host "   [OK] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "   [!]  $t" -ForegroundColor Yellow }
function Pause-Close { if (-not $NoPause) { Read-Host 'Pulsa Enter para cerrar' | Out-Null } }
function Fail($t) { Write-Host "`n[ERROR] $t" -ForegroundColor Red; Pause-Close; exit 1 }

Write-Host 'Cloud Phone — preparación del Android virtual' -ForegroundColor White
Write-Host "Carpeta de componentes: $runtime"

# ---------------- 1. Virtualización ----------------
Step '1/5 Comprobando virtualización'
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if (-not $cpu.VirtualizationFirmwareEnabled -and -not (Get-CimInstance Win32_ComputerSystem).HypervisorPresent) {
    Fail 'La virtualización (Intel VT-x / AMD-V) está desactivada en la BIOS/UEFI. Actívala y vuelve a ejecutar este asistente.'
}
$hv = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
if ($hv) { Ok 'Hipervisor de Windows activo (WHPX disponible).' }
else {
    Warn 'Falta activar la característica de Windows «Plataforma del hipervisor de Windows» (WHPX).'
    Write-Host '   Es necesaria para que Android se ejecute con aceleración. Requiere permisos de administrador y reiniciar el PC.'
    $a = Read-Host '   ¿Activarla ahora? (s/N)'
    if ($a -match '^[sSyY]') {
        Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile', '-Command', 'Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform -NoRestart; Read-Host "Hecho. Pulsa Enter"'
        Fail 'Reinicia el PC y vuelve a ejecutar «Preparar Android» desde el menú Inicio.'
    }
    Fail 'Sin WHPX el emulador no puede arrancar. Actívala (Panel de control > Características de Windows > Plataforma del hipervisor de Windows) y reinicia.'
}

# ---------------- 2. Licencia ----------------
Step '2/5 Licencia del Android SDK'
$needGoogle = -not (Test-Path (Join-Path $sdk "system-images\android-$ApiLevel\google_apis\x86_64\system.img")) -or -not (Test-Path (Join-Path $sdk 'emulator\emulator.exe'))
if ($needGoogle -and -not $AcceptLicense) {
    Write-Host '   Se descargarán paquetes de Google (emulador e imagen de Android, ~3-9 GB). Su uso está sujeto a la licencia del Android SDK:'
    Write-Host '   https://developer.android.com/studio/terms' -ForegroundColor Cyan
    $a = Read-Host '   Escribe ACEPTO para aceptar la licencia y continuar'
    if ($a.Trim().ToUpper() -ne 'ACEPTO') { Fail 'Licencia no aceptada. No se descargó nada de Google.' }
}
if ($needGoogle) { Ok 'Licencia aceptada por el usuario.' } else { Ok 'Componentes de Google ya instalados.' }

# ---------------- 3. JDK ----------------
Step '3/5 JDK 17 (Eclipse Temurin)'
$javaExe = Get-ChildItem $jdkDir -Recurse -Filter java.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if ($javaExe) { Ok "Ya instalado: $($javaExe.Directory.Parent.FullName)" }
else {
    $a = Invoke-RestMethod 'https://api.adoptium.net/v3/assets/latest/17/hotspot?architecture=x64&image_type=jdk&os=windows'
    $pkg = $a[0].binary.package
    if ($pkg.link -notmatch '^https://github\.com/adoptium/') { Fail "Origen inesperado para el JDK: $($pkg.link)" }
    $zip = Join-Path $dl 'jdk17.zip'
    Write-Host "   Descargando $($pkg.name) ($([math]::Round($pkg.size/1MB)) MB)…"
    Invoke-WebRequest -UseBasicParsing $pkg.link -OutFile $zip
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -ne $pkg.checksum.ToLower()) { Remove-Item $zip -Force; Fail 'La suma SHA-256 del JDK no coincide. Descarga descartada.' }
    Ok 'SHA-256 verificado.'
    $tmp = Join-Path $dl 'jdk-tmp'; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive $zip $tmp -Force
    Get-ChildItem $tmp | ForEach-Object { Move-Item $_.FullName $jdkDir -Force }
    Remove-Item $tmp -Recurse -Force; Remove-Item $zip -Force
    Ok 'JDK instalado.'
}
$javaHome = (Get-ChildItem $jdkDir -Recurse -Filter java.exe | Select-Object -First 1).Directory.Parent.FullName
$env:JAVA_HOME = $javaHome

# ---------------- 4. Android command-line tools ----------------
Step '4/5 Android command-line tools'
$sdkmanager = Join-Path $sdk 'cmdline-tools\latest\bin\sdkmanager.bat'
if (Test-Path $sdkmanager) { Ok 'Ya instaladas.' }
else {
    $xml = (Invoke-WebRequest -UseBasicParsing 'https://dl.google.com/android/repository/repository2-3.xml').Content
    $pkgXml = [regex]::Match($xml, '<remotePackage path="cmdline-tools;latest">.*?</remotePackage>', 'Singleline').Value
    $m = [regex]::Match($pkgXml, '<archive>.*?<checksum type="sha1">(?<sha>[0-9a-f]+)</checksum>\s*<url>(?<url>commandlinetools-win-[^<]+)</url>', 'Singleline')
    if (-not $m.Success) { Fail 'No se pudo leer el manifiesto de Google.' }
    $zip = Join-Path $dl 'cmdline-tools.zip'
    Write-Host "   Descargando $($m.Groups['url'].Value)…"
    Invoke-WebRequest -UseBasicParsing "https://dl.google.com/android/repository/$($m.Groups['url'].Value)" -OutFile $zip
    if ((Get-FileHash $zip -Algorithm SHA1).Hash.ToLower() -ne $m.Groups['sha'].Value) { Remove-Item $zip -Force; Fail 'La suma SHA-1 de las command-line tools no coincide. Descarga descartada.' }
    Ok 'SHA-1 verificado.'
    $tmp = Join-Path $dl 'ct-tmp'; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
    Expand-Archive $zip $tmp -Force
    New-Item -ItemType Directory -Force (Join-Path $sdk 'cmdline-tools\latest') | Out-Null
    Copy-Item (Join-Path $tmp 'cmdline-tools\*') (Join-Path $sdk 'cmdline-tools\latest') -Recurse -Force
    Remove-Item $tmp -Recurse -Force; Remove-Item $zip -Force
    Ok 'Command-line tools instaladas.'
}

# ---------------- 5. Paquetes del SDK ----------------
Step "5/5 platform-tools, emulator e imagen Android $ApiLevel (google_apis x86_64)"
$want = @()
if (-not (Test-Path (Join-Path $sdk 'platform-tools\adb.exe'))) { $want += 'platform-tools' }
if (-not (Test-Path (Join-Path $sdk 'emulator\emulator.exe'))) { $want += 'emulator' }
if (-not (Test-Path (Join-Path $sdk "system-images\android-$ApiLevel\google_apis\x86_64\system.img"))) { $want += "system-images/android-$ApiLevel/google_apis/x86_64" }
if ($want.Count -eq 0) { Ok 'Todo ya instalado.' }
else {
    Write-Host "   Instalando: $($want -join ', ')  (puede tardar varios minutos)"
    & $sdkmanager "--sdk_root=$sdk" @want
    if ($LASTEXITCODE -ne 0) { Fail "sdkmanager terminó con error $LASTEXITCODE." }
    Ok 'Paquetes instalados.'
}

# ---------------- Verificación ----------------
Step 'Verificando aceleración del emulador'
$acc = & (Join-Path $sdk 'emulator\emulator.exe') -accel-check 2>&1 | Out-String
if ($acc -match 'WHPX.*usable|is installed and usable') { Ok 'WHPX operativo.' } else { Warn "El emulador no confirmó la aceleración:`n$acc" }

Write-Host "`nListo. Abre «Cloud Phone» desde el escritorio y pulsa «Iniciar» en el panel." -ForegroundColor Green
Pause-Close
