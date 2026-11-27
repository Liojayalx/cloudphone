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

## Qué NO está verificado / no funciona todavía

| Elemento | Estado |
|---|---|
| **App iOS** | Escrita pero **sin compilar ni probar** (requiere macOS/Xcode). Puede haber errores de compilación o de ejecución. No se ha probado el decodificador VideoToolbox, el multitáctil real, el teclado ni la reconexión en un iPhone |
| **IPA** | **No existe aún.** Se genera ejecutando el workflow de GitHub Actions o compilando en un Mac |
| **ESign** | Documentado, no probado |
| **Instalador `Setup.exe`** | `CloudPhone.iss` escrito pero **no compilado ni probado**: no se instaló Inno Setup (requiere tu permiso; ver `build.ps1 -InstallInno`). El paquete portable sí está probado. El asistente (páginas, tareas, desinstalador, firewall) está sin ejecutar |
| `Setup-Android.ps1` completo | Sintaxis validada y lógica de descarga/verificación basada en lo hecho a mano; **no se ejecutó de principio a fin** en una carpeta vacía (son 10 GB de descarga) |
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
