# Cloud Phone privado — Etapa 1: Análisis y arquitectura

Estado: **análisis y diseño. Todavía no hay nada instalado ni probado en las etapas 2–8.**

## 1. Tu PC (medido, no supuesto)

| Dato | Valor | Consecuencia |
|---|---|---|
| CPU | i5-6600K, 4 núcleos / 4 hilos, VT-x + SLAT activos en BIOS | Virtualización por hardware posible |
| RAM | 15,9 GB | Android con 3–4 GB, 2–3 vCPU. Una sola instancia cómoda |
| Disco C: libre | 25,7 GB | Justo. SDK+imagen ≈ 4 GB, datos Android 4–8 GB. Se puede elegir otra unidad |
| GPU | Radeon RX 480 | Render del emulador con GPU del host (`-gpu host`) |
| Windows | 10 Pro 22H2 (19045) | Soporta Windows Hypervisor Platform (WHPX) |
| Hipervisor activo | **No** | Hay que habilitar la característica *Windows Hypervisor Platform* (admin + reinicio) |
| Instalado | Node, .NET, Git, WSL, BlueStacks | **Faltan**: Java, adb, scrcpy, Inno Setup, Android SDK |

## 2. Android en Windows — opciones evaluadas

| Opción | Android real | Root real | Automatizable | Redistribuible | Veredicto |
|---|---|---|---|---|---|
| **Android SDK Emulator (AOSP, QEMU) + WHPX** | Sí | Sí (`adb root` en imágenes `google_apis`, build *userdebug*) | Sí, CLI completa (`avdmanager`, `emulator`, `adb`) | Se descarga de Google en la instalación | **Elegida** |
| BlueStacks / LDPlayer / Nox | Sí | Sí, pero root propio de cada producto | No hay API estable | No | Descartada (cerrada, sin control programático, anuncios) |
| WSA (Subsistema Android de Windows) | Sí | Solo con parches no oficiales | — | — | **Descontinuado por Microsoft (mar. 2025)** |
| Waydroid / Cuttlefish | Sí | Sí | — | — | Solo Linux; en Windows exigiría una VM Linux con virtualización anidada (frágil) |
| Android-x86 en VirtualBox/Hyper-V | Sí | Sí | Mal | — | Versiones antiguas, sin mantenimiento |

**Decisión:** emulador oficial del Android SDK con imagen `google_apis` x86_64 (Android 13/API 33 como punto de partida), hipervisor WHPX.

**Root real:** en imágenes `google_apis` (sin Play Store) `adb root` reinicia `adbd` como uid 0 y `su`/shell root funcionan de verdad; se comprueba con `adb shell id`. Opción posterior: Magisk (rootAVD) si hiciera falta `su` para apps. *Limitación:* con root las apps con Play Integrity/detección de root (bancos, algunos juegos) pueden negarse a funcionar; sin Play Store no hay Google Play (se instalan APK).

**Limitaciones honestas:**
- Rendimiento de WHPX con 4 núcleos: usable para apps normales, no equiparable a un teléfono. Juegos 3D pesados: esperar poco.
- Apps solo-ARM: las imágenes x86_64 recientes traducen ARM, pero no al 100 %.
- Sin sensores/cámara reales (la cámara virtual existe, es sintética).
- WHPX y VirtualBox/otros hipervisores de terceros pueden convivir mal; BlueStacks (ya instalado) puede entrar en conflicto de arranque.
- Se pierde la imagen si se borra el AVD; la persistencia es la del disco `userdata` del AVD (se hará copia de seguridad opcional).

## 3. Streaming y control

**Elegido: scrcpy-server** (Apache-2.0, Genymobile) lanzado en el Android vía adb. Codifica la pantalla en H.264 *dentro* del Android (MediaCodec) y expone un protocolo de control (táctil multitouch, teclas, texto, portapapeles).

```
Android (emulador) ──adb forward──► Servidor Windows (Node.js) ──WebSocket(H.264 + control)──► iPhone (VideoToolbox)
```

**¿Por qué no WebRTC?** WebRTC aporta NAT traversal, congestión adaptativa y cifrado, pero en iOS exige un framework binario de terceros (el oficial de Google no se publica para SwiftPM), señalización, STUN y reencapsular H.264 a RTP. En Wi-Fi/LAN (nuestro caso prioritario) un WebSocket binario con H.264 en Annex-B da latencia comparable (≈50–120 ms), menos piezas móviles y se decodifica con VideoToolbox + `AVSampleBufferDisplayLayer`. WebRTC queda como mejora futura si se quiere acceso por Internet sin VPN.

**Acceso remoto:** recomendado **Tailscale/WireGuard** en vez de abrir puertos al Internet.

Parámetros ajustables: resolución máxima, bitrate, FPS (hasta 60; recomendado 30 en tu CPU), calidad.

## 4. Servidor Windows

Node.js (ya lo tienes) + TypeScript; dependencias mínimas (`ws`, `fastify`/`http` nativo). Módulos:

```
server/src/
  config/        carga + validación + defaults de cloudphone-config.json
  android/       InstanceManager (multi-instancia desde el diseño), AVD, emulador, adb, root, APK, apps
  stream/        relé scrcpy → WebSocket, ajustes de calidad
  input/         touch, teclado, navegación (Back/Home/Recientes), portapapeles
  auth/          token de emparejamiento, sesiones, lista de dispositivos autorizados
  api/           REST + WebSocket (/api/..., /stream/:id)
  admin/         panel web local (solo 127.0.0.1) + endpoints de administración
  log/           logs rotativos + stream a panel
  net/           conexiones activas, reconexión
```

Panel de administración PC: web local (`http://127.0.0.1:PUERTO/admin`, solo loopback) servida por el propio servidor y abierta por un acceso directo; arrancar/parar/reiniciar Android, root, logs, conexiones, APK, edición de configuración con validación. *(Decisión de pragmatismo: una app web local es lo más mantenible; si prefieres bandeja del sistema nativa .NET, se añade después como envoltorio.)*

## 5. Seguridad

- Sin credenciales por defecto: el instalador genera un **código de emparejamiento aleatorio** y un token de 256 bits.
- Escucha en la IP LAN elegida, nunca `0.0.0.0` salvo que lo configures; admin solo loopback.
- Dispositivos iOS autorizados por token; revocables desde el panel.
- TLS con certificado autofirmado y *pinning* en la app (fase de endurecimiento; en LAN inicial puede ser `ws://` con aviso explícito).
- Descargas solo de fuentes oficiales con verificación SHA-256: dl.google.com (SDK/emulador/imágenes), Adoptium (JDK), GitHub oficial de Genymobile (scrcpy-server). No se desactiva Defender ni el firewall: se crea una regla de firewall específica y acotada a red privada (pidiendo permiso en la instalación).

## 6. Instalador Windows

**Inno Setup 6** (gratuito, asistente clásico, desinstalador, accesos directos, páginas personalizadas para carpeta/resolución/RAM/almacenamiento, detección de instalación previa). Incluye: servidor (Node portable + código), platform-tools, scrcpy-server, scripts. Tras instalar, un paso *post-install* ejecuta: habilitar WHPX (pide admin/reinicio, explicado), descargar emulador + imagen (aceptando tú la licencia de Google), crear AVD, generar credenciales. Versión **portable**: mismo contenido en .zip con `Setup-Android.cmd`.

## 7. App iOS (SwiftUI) e IPA

- SwiftUI nativo, iOS 16+, `URLSessionWebSocketTask`, VideoToolbox, gestos táctiles → coordenadas de Android, teclado, rotación, pantalla completa, latencia (ping), reconexión con backoff, Bonjour opcional.
- Proyecto definido con **XcodeGen** (`project.yml`) para poder escribirlo sin Xcode.
- **La compilación requiere macOS + Xcode. Desde Windows no se puede compilar iOS.** Camino realista: un *workflow* de GitHub Actions con runner macOS que ejecuta `xcodebuild` sin firmar y empaqueta `Payload/App.app → .ipa` (IPA **sin firmar**, que es lo que ESign necesita) o compilarlo en un Mac. El IPA solo existirá cuando ese workflow/Mac se ejecute de verdad; no lo afirmaré antes.
- ESign firma con **tu** certificado/perfil (.p12 + .mobileprovision); no se incluye nada de eso.

## 8. Plan de etapas y riesgos

| Etapa | Qué se verifica en tu PC | Necesita de ti |
|---|---|---|
| 2 Android | WHPX, AVD arranca, `adb shell id` = root, instalar APK, persistencia tras reinicio | Admin + reinicio; ~3–5 GB de descargas oficiales; aceptar licencia Android SDK |
| 3 Servidor | API, auth, start/stop, estado | — |
| 4 Instalador | Compilar Setup.exe y probar instalar/desinstalar | Permiso para instalar Inno Setup y JDK |
| 5 Streaming | Capturar H.264 real, latencia medida con cliente de prueba en PC | — |
| 6–7 iOS/IPA | **No verificable en Windows** salvo revisión estática; compilación en GitHub Actions/Mac | Mac o repo GitHub; tu iPhone para probar |
| 8 Pruebas | Informe honesto de qué funciona | Tu prueba real en el iPhone |

**Riesgo principal:** que WHPX en tu CPU Skylake rinda poco o choque con BlueStacks. Se mide en la Etapa 2 antes de construir encima.
