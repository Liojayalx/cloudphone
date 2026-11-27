# Cloud Phone privado

Tu PC con Windows ejecuta un **Android real** (emulador oficial de Google, con **root real**) y tu iPhone lo ve y lo controla en tiempo real con una app nativa SwiftUI. Concepto inspirado en los "cloud phones"; implementación original, sin código, marcas ni recursos de terceros.

```
iPhone (app SwiftUI) ──Wi‑Fi/VPN──► Servidor Node.js (Windows) ──adb/scrcpy──► Android (emulador oficial, WHPX)
   VideoToolbox ◄── WebSocket: H.264 + control táctil/teclado ──┘
```

## Qué incluye

| Carpeta | Contenido |
|---|---|
| `server/` | Servidor Node.js: gestión del Android, API REST, autenticación, streaming H.264, control táctil/teclado, panel de administración web local |
| `scripts/` | Iniciar/detener/reiniciar servidor, preparar Android (descargas verificadas), regla de firewall acotada |
| `installer/` | `CloudPhone.iss` (Inno Setup) y `build.ps1` (genera instalador y versión portable) |
| `ios/` | App SwiftUI + `project.yml` (XcodeGen) |
| `.github/workflows/build-ios.yml` | Compila el **IPA sin firmar** en un runner macOS (para firmar con ESign) |
| `docs/` | Documentación (empieza por `04-INSTALACION.md`) |

## Inicio rápido

1. **PC (Windows 10/11 x64):** instala con `CloudPhone-Setup.exe` (o descomprime `CloudPhone-Portable.zip`) → ejecuta **Preparar Android** → abre **Cloud Phone** y pulsa **Iniciar**. Ver [04-INSTALACION.md](docs/04-INSTALACION.md).
2. **IPA:** compílalo con GitHub Actions o en un Mac → fírmalo e instálalo con ESign. Ver [05-IOS-IPA-ESIGN.md](docs/05-IOS-IPA-ESIGN.md).
3. **iPhone:** Ajustes → IP del PC, puerto, código de emparejamiento (panel → Dispositivos) → **Abrir dispositivo**.

## Estado y límites (resumen honesto)

Verificado en un PC real: Android 13 con root real, instalación de APK, persistencia, API, autenticación, streaming H.264 decodificado en navegador, toque/texto/rotación/calidad con latencia toque→imagen ≈ 50‑55 ms (medida en el servidor), reinicio/parada del servidor. El instalador (`Setup.exe`) se compiló e instaló/desinstaló en silencio con éxito, y la app iOS **compila en macOS (GitHub Actions) y genera un IPA sin firmar real**. **No verificado:** la app no se ha ejecutado en un iPhone, ESign no se ha probado, y el asistente interactivo del instalador y la descarga completa de «Preparar Android» desde cero tampoco. Detalle en [06-ESTADO-Y-PRUEBAS.md](docs/06-ESTADO-Y-PRUEBAS.md).

La conexión iPhone↔PC **no está cifrada** (HTTP/WebSocket): úsala en tu Wi‑Fi de confianza o por VPN (Tailscale/WireGuard). Nunca expongas el puerto a Internet.
