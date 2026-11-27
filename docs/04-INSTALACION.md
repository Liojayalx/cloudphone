# Instalación y uso del servidor (Windows)

## Requisitos del PC

| Requisito | Detalle |
|---|---|
| Windows | 10 (2004+) o 11, **64 bits** |
| CPU | Con virtualización (Intel VT‑x / AMD‑V) **activada en BIOS/UEFI** y SLAT |
| RAM | 8 GB mínimo; 16 GB recomendado (el Android usa 3 GB por defecto) |
| Disco | 12 GB libres como mínimo (SDK+imagen ≈ 10 GB, datos Android hasta el tamaño configurado). Se recomienda instalar en un disco de datos (HDD) para no llenar el SSD |
| Windows Features | **Plataforma del hipervisor de Windows** (WHPX). El asistente la activa con tu permiso (admin + reinicio) |
| Red | PC y iPhone en la misma Wi‑Fi (o VPN) |

Probado en: Windows 10 22H2, i5‑6600K (4 núcleos), 16 GB RAM, GPU AMD RX 480.

## Instalar

**Opción A — Instalador (`CloudPhone-Setup.exe`)**: asistente en español: carpeta (por defecto la primera unidad fija distinta de C:), nombre/resolución/DPI/RAM/almacenamiento del Android, puerto, accesos directos, inicio automático opcional, regla de firewall opcional. No requiere administrador salvo para el firewall y para activar WHPX (UAC).
> El `.exe` **no está firmado digitalmente**: SmartScreen mostrará «Windows protegió su PC» → *Más información* → *Ejecutar de todas formas*.
> Para generarlo hace falta Inno Setup 6: `installer\build.ps1` (o `-InstallInno` para que lo descargue de jrsoftware.org verificando su firma). Sin Inno Setup, `build.ps1` genera solo la versión portable.

**Opción B — Portable (`CloudPhone-Portable.zip`)**: descomprime en cualquier carpeta; ejecuta `Instalar-Android.cmd` una vez; luego `Iniciar-CloudPhone.cmd`.

### «Preparar Android» (primera vez)
Descarga **solo de fuentes oficiales y verifica sumas de comprobación**:
JDK 17 Temurin (Adoptium, SHA‑256) · Android command‑line tools (dl.google.com, SHA‑1 del manifiesto de Google) · platform‑tools, emulator e imagen Android 13 `google_apis` x86_64 (via sdkmanager). Pide que escribas `ACEPTO` para la licencia del Android SDK. Es idempotente: si algo ya está instalado, lo detecta y no lo repite.

## Uso diario

1. Acceso directo **Cloud Phone** del escritorio → arranca el servidor (sin ventanas) y abre el panel local.
2. Panel → **Iniciar** (≈ 1 min la primera vez). Estados: Apagado / Iniciando / En marcha, root, uptime.
3. Cabecera del panel: **Reiniciar servidor** / **Apagar servidor**. Menú Inicio → *Detener servidor* / *Reiniciar servidor*.

### Panel de administración (`http://127.0.0.1:8444`, solo este PC)
Iniciar/apagar/reiniciar Android · estado y root real · información (versión, modelo, RAM, almacenamiento) · resolución/DPI/orientación en caliente · **pantalla en vivo con control** (ratón = dedo, clic derecho = Atrás, teclado) · instalar/abrir/desinstalar APK · editor de configuración con validación · emparejar iPhone (código de un solo uso) · dispositivos autorizados (revocar) · conexiones activas · logs.
El acceso directo abre el panel con el token en el fragmento de la URL (`#t=…`, no se envía al servidor); el navegador lo guarda localmente.

## Configuración (`cloudphone-config.json`)

Se crea con valores por defecto si no existe; se valida al arrancar (si es inválido, el servidor no arranca y dice por qué). Solo hace falta poner lo que cambie; el resto usa los valores por defecto. Ejemplo completo: `cloudphone-config.example.json`.

| Clave | Por defecto | Notas |
|---|---|---|
| `server.listenAddress` | `"auto"` | `auto` = primera IPv4 privada. `0.0.0.0` está **prohibido** |
| `server.port` / `adminPort` | 8443 / 8444 | `adminPort` solo escucha en 127.0.0.1 |
| `server.autoStartAndroid` | `false` | Enciende el Android al arrancar el servidor |
| `server.stopAndroidOnExit` | `true` | Apaga el Android al parar el servidor |
| `auth.maxAuthorizedDevices` | 3 | |
| `instances[].android.resolution/dpi/ramMB/cpuCores/storageGB` | 720×1280 / 320 / 3072 / 3 / 8 | Se aplican en el **siguiente arranque** del Android |
| `instances[].android.gpu` | `host` | `host`, `swiftshader_indirect`, `angle_indirect`, `auto` |
| `instances[].android.root` | `true` | Ejecuta `adb root` en cada arranque |
| `streaming.fps / bitrateKbps / maxWidth / quality` | 30 / 4000 / 720 / balanced | `quality`: low/balanced/high (factor de bitrate e intervalo de fotogramas clave) |
| `paths.*` | bajo la carpeta de instalación | `androidSdk, jdk, avdHome, androidUserHome, tmp, data, logs, apkLibrary, scrcpyServer` |

El diseño admite **varias instancias** (`instances[]` con puertos de emulador independientes), pero solo se ha probado una.

## Conectar el iPhone
Panel → *Dispositivos* → código (8 caracteres, un solo uso). En la app: Ajustes → IP del PC (`ipconfig`) + puerto + código → *Emparejar*. Si no conecta: ¿misma Wi‑Fi? ¿regla de firewall creada? ¿perfil de red «Privada»? ¿permiso «Red local» concedido a la app?

## Solución de problemas

| Síntoma | Causa / solución |
|---|---|
| «Falta activar WHPX» / emulador se cierra al iniciar | Activa *Plataforma del hipervisor de Windows* y reinicia. Si usas VirtualBox/VMware antiguos o BlueStacks, pueden entrar en conflicto con el hipervisor |
| `HypervisorPresent` sigue en False tras activarlo | Reinicia de verdad (`shutdown /r /t 0`; el «inicio rápido» no basta) y revisa que VT‑x esté en BIOS |
| Android tarda mucho / va lento | HDD: el arranque y el I/O son más lentos. Baja resolución/FPS; mueve la instalación a SSD si puedes; no pongas más RAM de la que te sobre |
| El iPhone no conecta | Comprueba `listenAddress` (no `127.0.0.1`), firewall, misma red; en la app «Probar conexión» |
| «Código incorrecto» / 429 | El código es de un solo uso (se regenera tras emparejar); 5 fallos = bloqueo de 1 min por IP |
| `403 Máximo de dispositivos` | Revoca alguno en el panel o sube `auth.maxAuthorizedDevices` |
| Pantalla negra en el panel | Pulsa *Conectar*; si persiste, mira `logs\server.log` y `logs\emulator-phone1.log` |
| La config no se aplica | Resolución/RAM/etc. se aplican al reiniciar el Android; puertos al reiniciar el servidor |
| Datos del Android se pierden | El servidor elimina `disk.dataPartition.path=<temp>` del AVD; no lo añadas a mano |
| Apps con detección de root no abren | Limitación del root real; algunas apps bancarias/juegos lo bloquean |

## Desinstalar
Menú Inicio → Cloud Phone → Desinstalar. Pregunta si borrar también el Android virtual, sus datos, los emparejamientos y los componentes descargados. Quita la regla de firewall y el inicio automático.

## Limitaciones técnicas de la virtualización
- Rendimiento limitado por CPU/WHPX; juegos 3D pesados no son viables. Sin sensores/cámara reales.
- Imagen `google_apis` x86_64: sin Google Play Store (se instalan APK); apps solo‑ARM pueden fallar.
- Root es el de `userdebug` (`adb root`, `su` de AOSP): válido para el sistema y `adb`, no equivale a Magisk para apps.
- Tras cada arranque de Android se reaplica `adb root` automáticamente.
