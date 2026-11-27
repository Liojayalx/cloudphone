; Cloud Phone Server — instalador para Windows (Inno Setup 6.3 o superior)
; Compilar con installer\build.ps1 (prepara dist\stage y llama a ISCC).

#define AppName "Cloud Phone Server"
#define AppVersion "1.0.0"
#define Stage "..\dist\stage"

[Setup]
AppId={{B6A4F7D2-5C1E-4C57-9A41-7C0F5D2E9A11}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Cloud Phone (proyecto privado)
DefaultDirName={code:DefaultInstallDir}
DefaultGroupName=Cloud Phone
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\dist
OutputBaseFilename=CloudPhone-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\assets\cloudphone.ico
SetupIconFile={#Stage}\assets\cloudphone.ico
InfoAfterFile={#Stage}\docs\LEEME-INSTALACION.txt
CloseApplications=no
UsePreviousAppDir=yes

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "Crear un acceso directo en el escritorio"; GroupDescription: "Accesos directos:"
Name: "autostart"; Description: "Iniciar el servidor automáticamente al iniciar sesión en Windows"; GroupDescription: "Inicio:"; Flags: unchecked
Name: "autostartandroid"; Description: "Encender el Android automáticamente cuando arranque el servidor"; GroupDescription: "Inicio:"; Flags: unchecked
Name: "firewall"; Description: "Permitir que el iPhone se conecte (regla de firewall solo para redes privadas; pide permiso de administrador)"; GroupDescription: "Red:"

[Files]
Source: "{#Stage}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autodesktop}\Cloud Phone"; Filename: "powershell.exe"; Parameters: "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\CloudPhone-Manager.ps1"" -StartAll"; IconFilename: "{app}\assets\cloudphone.ico"; Comment: "Abre el administrador, inicia el servidor y enciende el Android"; Tasks: desktopicon
Name: "{group}\Cloud Phone (administrador, inicia todo)"; Filename: "powershell.exe"; Parameters: "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\CloudPhone-Manager.ps1"" -StartAll"; IconFilename: "{app}\assets\cloudphone.ico"
Name: "{group}\Panel web (avanzado)"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\Start-Server.ps1"" -OpenPanel"; IconFilename: "{app}\assets\cloudphone.ico"
Name: "{group}\Detener servidor"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\Stop-Server.ps1"""; IconFilename: "{app}\assets\cloudphone.ico"
Name: "{group}\Reiniciar servidor"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\Restart-Server.ps1"""; IconFilename: "{app}\assets\cloudphone.ico"
Name: "{group}\Preparar Android (descarga componentes)"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Setup-Android.ps1"""; IconFilename: "{app}\assets\cloudphone.ico"
Name: "{group}\Editar configuración"; Filename: "notepad.exe"; Parameters: """{app}\cloudphone-config.json"""
Name: "{group}\Carpeta de logs"; Filename: "{app}\logs"
Name: "{group}\Desinstalar Cloud Phone"; Filename: "{uninstallexe}"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "CloudPhoneServer"; ValueData: "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\Start-Server.ps1"""; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Enable-Firewall.ps1"""; StatusMsg: "Configurando la regla de firewall (red privada)..."; Tasks: firewall; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Setup-Android.ps1"""; Description: "Preparar ahora el Android virtual (descarga componentes oficiales de Google y Adoptium, ~3-9 GB)"; Flags: postinstall skipifsilent
Filename: "powershell.exe"; Parameters: "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\scripts\CloudPhone-Manager.ps1"" -StartAll"; Description: "Abrir el administrador e iniciar el servidor"; Flags: postinstall skipifsilent nowait

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\scripts\Stop-Server.ps1"""; RunOnceId: "StopServer"; Flags: runhidden waituntilterminated

[Code]
var
  AndroidPage: TInputQueryWizardPage;

function GetDriveTypeW(lpRootPathName: String): Cardinal; external 'GetDriveTypeW@kernel32.dll stdcall';

// Carpeta por defecto: la primera unidad fija distinta de C: (p. ej. un disco HDD de datos); si no hay, Archivos de programa del usuario.
function DefaultInstallDir(Param: String): String;
var
  i: Integer;
  root: String;
begin
  Result := ExpandConstant('{autopf}\CloudPhone');
  for i := Ord('D') to Ord('Z') do
  begin
    root := Chr(i) + ':\';
    if GetDriveTypeW(root) = 3 then
    begin
      Result := root + 'CloudPhone';
      Exit;
    end;
  end;
end;

procedure InitializeWizard;
begin
  AndroidPage := CreateInputQueryPage(wpSelectDir, 'Dispositivo Android',
    'Configura tu Cloud Phone',
    'Estos valores se guardan en cloudphone-config.json. Puedes cambiarlos después desde el panel de administración.');
  AndroidPage.Add('Nombre del dispositivo (letras, números y espacios):', False);
  AndroidPage.Add('Resolución - ancho (px):', False);
  AndroidPage.Add('Resolución - alto (px):', False);
  AndroidPage.Add('Densidad (DPI):', False);
  AndroidPage.Add('Memoria RAM (MB):', False);
  AndroidPage.Add('Almacenamiento (GB):', False);
  AndroidPage.Add('Puerto del servidor:', False);
  AndroidPage.Values[0] := 'Mi Cloud Phone';
  AndroidPage.Values[1] := '720';
  AndroidPage.Values[2] := '1280';
  AndroidPage.Values[3] := '320';
  AndroidPage.Values[4] := '3072';
  AndroidPage.Values[5] := '8';
  AndroidPage.Values[6] := '8443';
end;

function InRange(const S: String; Lo, Hi: Integer): Boolean;
var
  v: Integer;
begin
  v := StrToIntDef(S, -1);
  Result := (v >= Lo) and (v <= Hi);
end;

function SafeName(const S: String): String;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or ((c >= '0') and (c <= '9')) or (c = ' ') or (c = '-') or (c = '_') then
      Result := Result + c;
  end;
  Result := Trim(Result);
  if Result = '' then Result := 'Mi Cloud Phone';
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  msg: String;
begin
  Result := True;
  if CurPageID = AndroidPage.ID then
  begin
    msg := '';
    if not InRange(AndroidPage.Values[1], 320, 2160) then msg := 'El ancho debe estar entre 320 y 2160.'
    else if not InRange(AndroidPage.Values[2], 480, 3840) then msg := 'El alto debe estar entre 480 y 3840.'
    else if not InRange(AndroidPage.Values[3], 120, 640) then msg := 'El DPI debe estar entre 120 y 640.'
    else if not InRange(AndroidPage.Values[4], 1024, 16384) then msg := 'La RAM debe estar entre 1024 y 16384 MB.'
    else if not InRange(AndroidPage.Values[5], 2, 128) then msg := 'El almacenamiento debe estar entre 2 y 128 GB.'
    else if not InRange(AndroidPage.Values[6], 1024, 65535) then msg := 'El puerto debe estar entre 1024 y 65535.';
    if msg <> '' then
    begin
      MsgBox(msg, mbError, MB_OK);
      Result := False;
    end;
  end;
end;

function BoolStr(b: Boolean): String;
begin
  if b then Result := 'true' else Result := 'false';
end;

procedure WriteConfig;
var
  f, s: String;
  adminPort: Integer;
begin
  f := ExpandConstant('{app}\cloudphone-config.json');
  if FileExists(f) then Exit; // reinstalación/actualización: se conserva la configuración del usuario
  adminPort := StrToInt(AndroidPage.Values[6]) + 1;
  s := '{' + #13#10 +
    '  "server": { "port": ' + AndroidPage.Values[6] + ', "adminPort": ' + IntToStr(adminPort) + ', "autoStartAndroid": ' + BoolStr(WizardIsTaskSelected('autostartandroid')) + ' },' + #13#10 +
    '  "instances": [' + #13#10 +
    '    { "id": "phone1", "name": "' + SafeName(AndroidPage.Values[0]) + '",' + #13#10 +
    '      "android": { "resolution": { "width": ' + AndroidPage.Values[1] + ', "height": ' + AndroidPage.Values[2] + ' }, "dpi": ' + AndroidPage.Values[3] +
    ', "ramMB": ' + AndroidPage.Values[4] + ', "storageGB": ' + AndroidPage.Values[5] + ' } }' + #13#10 +
    '  ]' + #13#10 + '}' + #13#10;
  SaveStringToFile(f, s, False);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  rc: Integer;
  stopScript: String;
begin
  if CurStep = ssInstall then
  begin
    // Actualización: detener el servidor antiguo para poder reemplazar archivos
    stopScript := ExpandConstant('{app}\scripts\Stop-Server.ps1');
    if FileExists(stopScript) then
      Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + stopScript + '"', '', SW_HIDE, ewWaitUntilTerminated, rc);
  end;
  if CurStep = ssPostInstall then
  begin
    ForceDirectories(ExpandConstant('{app}\logs'));
    ForceDirectories(ExpandConstant('{app}\data'));
    WriteConfig;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  rc: Integer;
  app: String;
begin
  if CurUninstallStep = usUninstall then
  begin
    // Quitar la regla de firewall solo si existe
    app := ExpandConstant('{app}');
    if Exec('powershell.exe', '-NoProfile -Command "if (Get-NetFirewallRule -DisplayName ''Cloud Phone Server'' -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }"', '', SW_HIDE, ewWaitUntilTerminated, rc) and (rc = 0) then
      Exec('powershell.exe', '-NoProfile -ExecutionPolicy Bypass -File "' + app + '\scripts\Enable-Firewall.ps1" -Remove', '', SW_HIDE, ewWaitUntilTerminated, rc);
  end;
  if CurUninstallStep = usPostUninstall then
  begin
    app := ExpandConstant('{app}');
    if MsgBox('¿Eliminar también el Android virtual, sus datos, los dispositivos emparejados, la configuración y los componentes descargados (SDK/JDK)?' + #13#10#13#10 +
              'Si eliges «No», se conservan en: ' + app, mbConfirmation, MB_YESNO or MB_DEFBUTTON2) = IDYES then
    begin
      DelTree(app + '\runtime', True, True, True);
      DelTree(app + '\data', True, True, True);
      DelTree(app + '\apk', True, True, True);
      DelTree(app + '\logs', True, True, True);
      DeleteFile(app + '\cloudphone-config.json');
      RemoveDir(app);
    end;
  end;
end;
