# Estado del proyecto y resultados de pruebas

Fecha de las pruebas: 2026‑11‑26/27. Equipo: Windows 10 Pro 22H2, i5‑6600K 4C/4T, 16 GB, RX 480, instalación en HDD (D:).

## Qué funciona (probado en este PC)

| Componente | Prueba | Resultado |
|---|---|---|
| Android virtual | Arranque headless con WHPX (primer arranque 130 s; siguientes 40–70 s) | ✅ |
| Root real | `adb root` → `uid=0(root)` con contexto `u:r:su:s0`; escritura en `/data` como root; build `userdebug`; el servidor lo reaplica en cada arranque | ✅ |
| APK | Instalación por API (5,2 MB), rechazo de archivo falso (400), nombre con `..\` no escapa de la biblioteca; abrir/desinstalar | ✅ (probado con un APK del propio sistema; **no** con APK de terceros) |
| Persistencia | Archivo y app sobreviven a apagar/arrancar (tras corregir `disk.dataPartition.path=<temp>`); también tras reinicios del servidor | ✅ |
| Config | Valores por defecto, validación (5 tests unitarios), 422 con errores claros, guardado desde panel, RAM 4096 aplicada tras reiniciar | ✅ |
| Seguridad | 401 sin/with token falso; admin solo loopback; token de dispositivo no sirve como admin; código de un solo uso; bloqueo tras 5 fallos; límite de dispositivos; revocación; panel sin path traversal | ✅ |
| Streaming | H.264 real (720×1280), SPS/PPS + IDR + P‑frames; decodificado en vivo en el navegador (WebCodecs) mostrando la pantalla Android real | ✅ |
| Control | Toque (Chrome se abrió), deslizamiento, Inicio/Atrás, **texto Unicode (`ñ`, `ú`) escrito en un campo real**, rotación (720×1280 ↔ 1280×720, con coordenadas correctas), cambio de calidad en caliente | ✅ |
| Latencia | Toque→primer fotograma con cambio medida **en el servidor**: mediana ≈ 53–55 ms (no incluye red ni decodificación en el cliente) | ✅ medida |
| Multi‑cliente / reconexión | 2 clientes simultáneos y reconexión: imagen en 2–3 ms (GOP en caché) | ✅ |
| Servidor | Reinicio desde el panel (nuevo PID en 4 s), parada limpia con script (apaga Android, borra PID, libera puertos), adopción de un emulador ya en marcha | ✅ |
| Paquete | `CloudPhone-Portable.zip` extraído en carpeta limpia: scripts de inicio/parada, panel, API, streaming y Android funcionan | ✅ |
| Instalador | `CloudPhone-Setup.exe` compilado con Inno Setup 6.7.4; instalación silenciosa en D: → archivos, `cloudphone-config.json` generado con valores del asistente, accesos directos, entrada de desinstalación; servidor arranca desde lo instalado; desinstalación silenciosa deja la máquina limpia | ✅ |
| **Compilación iOS** | GitHub Actions `macos-15` (Xcode 16.4, SDK iOS 18.5): proyecto generado con XcodeGen, compilación Release `iphoneos` **sin errores y sin avisos de Swift**, empaquetado en IPA | ✅ |
| **IPA** | `dist\ipa\CloudPhone.ipa` (0,38 MB): binario **arm64**, Bundle ID `com.cloudphone.client`, `MinimumOSVersion` 16.0, permisos de Red local en `Info.plist`, **sin `_CodeSignature`** (sin firmar, listo para ESign). SHA‑256 `C1EE054F708335F5728A61DB47534DC7AA9A3D772C21C8BE549A960852473F8F` | ✅ generado; ❌ no probado en iPhone |

## Qué NO está verificado / no funciona todavía

| Elemento | Estado |
|---|---|
| **App iOS en un iPhone** | **Compila** (ver abajo) pero **no se ha ejecutado en ningún iPhone**. Sin probar: decodificación VideoToolbox, multitáctil real, teclado, reconexión, permiso de Red local, subida de APK desde Archivos. Pueden aparecer errores de ejecución |
| **ESign** | Documentado, no probado (requiere tu certificado) |
| Asistente del instalador (interactivo) | Se probó la instalación/desinstalación **silenciosa** (valores por defecto). Las páginas del asistente, el inicio automático, la tarea de firewall (UAC) y la pregunta final del desinstalador no se ejecutaron de forma interactiva |
| `Setup-Android.ps1` descarga completa | Probada la **detección** de componentes ya instalados (sin descargar). La ruta de descarga desde cero (JDK/cmdline-tools/SDK, ~10 GB) sigue sin ejecutarse de principio a fin |
| Regla de firewall | Script escrito, no ejecutado |
| Pruebas en la LAN real | Todo se probó en `127.0.0.1`; el iPhone aún no se ha conectado |
| Cifrado | **No hay TLS**: tráfico en claro (HTTP/WS). Mitigar con VPN/LAN de confianza |
| Varias instancias | Diseño preparado; solo se probó una |
| Audio, cámara, sensores | No implementados |
| Portapapeles Android→iPhone | Implementado en servidor y app; no probado |

## Requisitos
- **Windows:** ver `04-INSTALACION.md`.
- **Android:** el que descarga `Setup-Android.ps1` (Android 13 API 33 google_apis x86_64, ≈ 10 GB).
- **iPhone:** iOS 16 o superior, iPhone.
- **Compilar iOS:** macOS + Xcode 15+ (o GitHub Actions `macos-15`).
- **Firmar:** certificado/perfil tuyos (Apple Developer) y ESign.

## Decisiones técnicas
Ver `01-ARQUITECTURA.md` (emulador oficial de Android + WHPX; scrcpy‑server 5.0.1 para vídeo/control en lugar de WebRTC porque en iOS WebRTC exige un framework binario de terceros y en LAN no aporta ventajas; servidor Node.js sin dependencias salvo `ws`; instalador Inno Setup; panel web local).
