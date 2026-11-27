# Etapa 2 — Android virtual (verificado en este PC, 2026-11-26)

Entorno: D:\CloudPhone  (jdk\, sdk\, avd\). Emulator 37.3.10, platform-tools 37.0.3, imagen android-33 google_apis x86_64 (r17).
Aceleración: WHPX (Windows 10 19045), `emulator -accel-check` -> "WHPX is installed and usable".

| Prueba | Resultado |
|---|---|
| Android arranca (sin ventana, -gpu host) | OK. Primer arranque 130 s; siguientes 40 s |
| Pantalla/densidad reales | OK: `wm size` 720x1280, 320 dpi |
| Root real | OK: `adb root` -> `uid=0(root)` contexto `u:r:su:s0`; escribe en /data como root; build userdebug |
| Instalar APK | OK con `adb install` (probado con un APK del propio sistema; **pendiente probar un APK de terceros**) |
| Persistencia tras apagar/arrancar | OK (archivo en /data y app instalada sobreviven) |

## Hallazgos
- `avdmanager` dejó `disk.dataPartition.path=<temp>` en config.ini: **los datos se perdían en cada arranque**. El servidor debe eliminar esa línea al crear el AVD.
- Tras cada reinicio hay que repetir `adb root` (adbd vuelve a modo shell).
- `su` es el de AOSP (`su 0 comando`), no Magisk: root disponible por adb, no para apps.
- sdkmanager está deprecado: no existe `--licenses`; las rutas con `;` se rompen al pasar por .bat desde PowerShell (usar `cmd /c` o formato con `/`).
- Imagen descomprimida: 8,2 GB; SDK total ~10 GB.
