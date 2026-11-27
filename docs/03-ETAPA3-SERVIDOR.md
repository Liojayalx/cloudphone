# Etapa 3 — Servidor (verificado en este PC, 2026-11-27)

Código: `server/` (Node.js >= 20, **sin dependencias npm**). Arranque: `node src/index.js`. Config: `cloudphone-config.json` (se crea con valores por defecto si falta; se valida al iniciar y falla con mensajes claros).

## Módulos
config · log (archivo rotativo + buffer) · auth · android (proc, adb, instance, manager) · api (REST + admin). Streaming/entrada táctil/teclado: **Etapa 5, aún no existen**.

## Seguridad implementada
- Sin credenciales por defecto: código de emparejamiento aleatorio de 8 caracteres, **un solo uso**, canjeado por un token de 256 bits (solo se guarda su hash SHA-256).
- 5 intentos fallidos por IP -> bloqueo de 1 minuto. Límite de dispositivos (3 por defecto). Revocación desde admin.
- Puerto de dispositivos: IP LAN privada ("auto") o la indicada; `0.0.0.0` rechazado. Puerto de administración: solo 127.0.0.1 + `X-Admin-Token` leído de `data/admin.token`.
- **Limitación:** el tráfico va en HTTP sin cifrar (TLS aún no implementado). Úsalo solo en tu LAN de confianza o por VPN (Tailscale/WireGuard).

## API (dispositivos, `Authorization: Bearer <token>`)
`GET /api/ping` · `POST /api/pair` · `GET /api/status` · `GET /api/instances[/:id]` · `GET .../info` · `POST .../start|stop|restart|orientation|resolution|launch|apk?name=` · `GET .../apps` · `DELETE .../apps/:pkg`
Admin (puerto admin): `/admin/status|pairing|devices|logs|config` (+ las rutas de instancias).

## Pruebas realizadas contra el Android real
| Prueba | Resultado |
|---|---|
| 5 tests unitarios de config (`npm test`) | 5/5 OK |
| 401 sin token / token falso / token de dispositivo en admin; 404 admin en puerto de dispositivos | OK |
| Emparejamiento: código malo, código reutilizado, límite de dispositivos (403), revocación | OK |
| Start / stop / restart por API (arranque 41-71 s, stop 4 s), root real activo tras cada arranque | OK |
| Adopción de un emulador ya en marcha tras reiniciar el servidor (con estado de root) | OK (tras corregir un fallo) |
| Info real (versión, root `uid=0`, pantalla, RAM, almacenamiento) | OK |
| Subir e instalar APK (5,2 MB) vía API; rechazo de archivo falso (400); nombre con `..\` no escapa | OK |
| Cambiar resolución/DPI en caliente y reset; orientación; lanzar app (Ajustes) | OK |
| Config inválida -> 422; config válida se guarda; RAM 4096 aplicada al reiniciar (MemTotal ~4 GB) | OK |
| Apps y datos persisten tras restart | OK |

## Fallos hallados y corregidos
`root.active` vacío tras adoptar emulador · lista de apps omitía actualizaciones de apps de sistema · `busy` visible en respuesta de start.

## No probado / pendiente
Reconexión de clientes, autostart al iniciar Windows, TLS, varias instancias simultáneas (diseño preparado, solo probada 1), `listenAddress: auto` en LAN real (pruebas hechas en 127.0.0.1 para evitar el aviso del firewall), subida de APK con `Invoke-RestMethod -InFile` (falló en el cliente de PowerShell 5.1; con curl funciona).
