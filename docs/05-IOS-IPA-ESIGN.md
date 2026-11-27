# App iOS: compilar el IPA y firmarlo con ESign

> **Estado honesto:** el código de la app (SwiftUI, ~1300 líneas) está escrito y revisado, pero **no se ha podido compilar ni ejecutar en Windows**. No existe un IPA hasta que se ejecute la compilación de abajo. El primer build en macOS puede revelar errores de compilación que habrá que corregir (el workflow sube el log para diagnosticarlos).

## Qué hace la app
SwiftUI nativo (iOS 16+, iPhone): panel con tarjeta del dispositivo (estado, root, conexión, info Android, iniciar/apagar/reiniciar, instalar APK desde Archivos) · pantalla Android en tiempo real (VideoToolbox/`AVSampleBufferDisplayLayer`) con multitáctil, Atrás/Inicio/Recientes, teclado, rotar, pantalla completa, latencia/FPS, calidad, pegar texto · Ajustes (IP, puerto, emparejamiento, calidad, reconexión automática con backoff) · token en el Llavero.

## Requisitos de compilación
iOS **no se puede compilar desde Windows**. Necesitas **macOS + Xcode 15 o superior**, ya sea:
- **A. GitHub Actions (recomendado, sin Mac):** el workflow `.github/workflows/build-ios.yml` usa un runner macOS gratuito/de pago de GitHub. Sube el proyecto a un repositorio **privado** y ejecuta *Actions → Build iOS IPA → Run workflow*. Al terminar, descarga el artefacto `CloudPhone-unsigned-ipa` (contiene `CloudPhone.ipa`). Los minutos de runners macOS consumen cuota (en repos privados cuentan ×10).
- **B. Mac propio / Mac en la nube:**
  ```bash
  brew install xcodegen
  cd ios && xcodegen generate
  xcodebuild -project CloudPhone.xcodeproj -scheme CloudPhone -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
  mkdir Payload && cp -R build/Build/Products/Release-iphoneos/CloudPhone.app Payload/
  zip -qry CloudPhone.ipa Payload
  ```
  (También puedes abrir `CloudPhone.xcodeproj` en Xcode y archivar con tu equipo de desarrollo.)

El IPA resultante está **sin firmar** a propósito: lo firma ESign con **tu** certificado. El repositorio **no contiene certificados, perfiles ni claves** (`.gitignore` los excluye).

## Firmar e instalar con ESign
ESign es una app de terceros; su interfaz cambia entre versiones, así que estos pasos son orientativos:
1. **Obtén el IPA** en el iPhone (descarga desde GitHub en Safari → *Guardar en Archivos*, o AirDrop/iCloud).
2. **Importa tu certificado en ESign:** archivo `.p12` + `.mobileprovision` + contraseña del `.p12`. Debe ser un certificado **tuyo** (cuenta Apple Developer de pago, o un Apple ID gratuito → perfiles de 7 días). El perfil debe incluir el UDID de tu iPhone (salvo certificados de distribución empresarial).
3. **Importa el IPA** en ESign (Importar / abrir con ESign desde Archivos).
4. Selecciona el IPA → **Firmar**, elige tu certificado. Puedes dejar el Bundle ID (`com.cloudphone.client`) o cambiarlo si ya hay un conflicto.
5. **Instala** la app firmada. Si iOS dice «Desarrollador no confiable»: *Ajustes → General → VPN y gestión de dispositivos* → confiar en tu perfil.
6. Abre la app → permite **Red local** cuando lo pida.

### Errores comunes
| Error | Causa / solución |
|---|---|
| «No se puede instalar» / «Integridad no verificada» | Certificado revocado/caducado, perfil sin tu UDID, o Bundle ID no coincide con el perfil. Vuelve a firmar con un perfil válido |
| «Desarrollador no confiable» | Confía en el perfil en Ajustes → General → VPN y gestión de dispositivos |
| La app se cierra al abrir | iOS < 16 no soportado; reinstala el IPA; revisa que el IPA venga del workflow (arm64) |
| «No se puede conectar» en la app | Permiso *Red local* denegado (Ajustes → Cloud Phone → Red local), IP errónea, firewall, distinta Wi‑Fi |
| Sin vídeo pero conecta | Android apagado: pulsa *Iniciar* en la tarjeta; mira el panel del PC → Logs |
| El workflow falla compilando | Descarga el artefacto `build-log` y corrige el error de Swift indicado |

## Verificaciones del workflow
Tras compilar, el workflow muestra el contenido del IPA, la arquitectura (`lipo -info` → arm64), el Bundle ID, `MinimumOSVersion` y comprueba que **no** hay `_CodeSignature` (IPA sin firmar, listo para ESign).
