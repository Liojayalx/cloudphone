<#
  Cloud Phone — Administrador nativo de Windows (ventana de Windows Forms, sin navegador).
  Controla el servidor y el Android: iniciar/detener, estado, root, captura de pantalla, APK, emparejamiento, dispositivos, logs.
  Uso:  powershell -STA -WindowStyle Hidden -File CloudPhone-Manager.ps1 [-Config ruta\cloudphone-config.json]
#>
param([string]$Config, [string]$SelfTestPng, [switch]$StartAll)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Una sola ventana: si ya hay un administrador abierto (en la bandeja), no abrir otro
if (-not $SelfTestPng) {
    $script:Mutex = New-Object Threading.Mutex($false, 'Local\CloudPhoneManager')
    if (-not $script:Mutex.WaitOne(0)) { [Windows.Forms.MessageBox]::Show('El administrador de Cloud Phone ya está abierto: búscalo en la bandeja del sistema (junto al reloj).', 'Cloud Phone') | Out-Null; exit }
}
[System.Windows.Forms.Application]::EnableVisualStyles()

$Root = Split-Path $PSScriptRoot -Parent
if (-not $Config) { $Config = Join-Path $Root 'cloudphone-config.json' }
$cfg = $null
if (Test-Path $Config) { try { $cfg = [IO.File]::ReadAllText($Config).TrimStart([char]0xFEFF) | ConvertFrom-Json } catch { } }
$adminPort = 8444; $dataDir = Join-Path $Root 'data'; $sdk = Join-Path $Root 'runtime\sdk'; $userHome = Join-Path $Root 'runtime\android-user'; $instance = 'phone1'
if ($cfg) {
    if ($cfg.server.adminPort) { $adminPort = [int]$cfg.server.adminPort }
    if ($cfg.paths.data) { $dataDir = $cfg.paths.data }
    if ($cfg.paths.androidSdk) { $sdk = $cfg.paths.androidSdk }
    if ($cfg.paths.androidUserHome) { $userHome = $cfg.paths.androidUserHome }
    if ($cfg.instances -and $cfg.instances[0].id) { $instance = $cfg.instances[0].id }
}
$script:Base = "http://127.0.0.1:$adminPort"
$script:TokenFile = Join-Path $dataDir 'admin.token'
$script:Busy = $false

function Get-Token { if (Test-Path $script:TokenFile) { return ([IO.File]::ReadAllText($script:TokenFile)).Trim() } return '' }
function ApiGet($path, $t = 2) { Invoke-RestMethod "$script:Base$path" -Headers @{ 'X-Admin-Token' = (Get-Token) } -TimeoutSec $t }
function ApiPost($path, $body = @{}, $t = 8) { Invoke-RestMethod "$script:Base$path" -Method Post -Headers @{ 'X-Admin-Token' = (Get-Token) } -Body ($body | ConvertTo-Json -Compress) -ContentType 'application/json' -TimeoutSec $t }

# ---------------- trabajo en segundo plano (la ventana nunca se congela) ----------------
$script:Jobs = New-Object System.Collections.ArrayList
function Run-Bg([scriptblock]$Work, [object[]]$ArgList, [scriptblock]$Done) {
    $ps = [powershell]::Create(); [void]$ps.AddScript($Work); foreach ($a in $ArgList) { [void]$ps.AddArgument($a) }
    [void]$script:Jobs.Add(@{ ps = $ps; h = $ps.BeginInvoke(); done = $Done })
}
function Poll-Jobs {
    foreach ($j in @($script:Jobs)) {
        if ($j.h.IsCompleted) {
            [void]$script:Jobs.Remove($j)
            $res = $null; $err = $null
            try { $res = $j.ps.EndInvoke($j.h) } catch { $err = $_.Exception.Message }
            if ($j.ps.Streams.Error.Count) { $err = $j.ps.Streams.Error[0].ToString() }
            $j.ps.Dispose()
            if ($j.done) { & $j.done $res $err }
        }
    }
}

# ---------------- colores / controles ----------------
$bg = [Drawing.Color]::FromArgb(14, 17, 22); $card = [Drawing.Color]::FromArgb(23, 27, 34); $fg = [Drawing.Color]::FromArgb(230, 233, 239)
$muted = [Drawing.Color]::FromArgb(139, 148, 163); $acc = [Drawing.Color]::FromArgb(79, 140, 255); $ok = [Drawing.Color]::FromArgb(63, 178, 127); $bad = [Drawing.Color]::FromArgb(229, 83, 75); $warn = [Drawing.Color]::FromArgb(210, 153, 34)
$fontUi = New-Object Drawing.Font('Segoe UI', 9.5); $fontBig = New-Object Drawing.Font('Segoe UI Semibold', 15); $fontMono = New-Object Drawing.Font('Consolas', 9.5)

function New-Btn($text, $x, $y, $w, $primary) {
    $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 32)
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(48, 56, 70); $b.Font = $fontUi
    if ($primary) { $b.BackColor = $acc; $b.ForeColor = [Drawing.Color]::White; $b.FlatAppearance.BorderColor = $acc } else { $b.BackColor = [Drawing.Color]::FromArgb(34, 41, 54); $b.ForeColor = $fg }
    $b.Cursor = 'Hand'; return $b
}
function New-Lbl($text, $x, $y, $w, $h, $font, $color) {
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, $h)
    $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [Drawing.Color]::Transparent; return $l
}

$form = New-Object Windows.Forms.Form
$form.Text = 'Cloud Phone — Administrador'; $form.Size = New-Object Drawing.Size(980, 680); $form.MinimumSize = New-Object Drawing.Size(900, 640)
$form.StartPosition = 'CenterScreen'; $form.BackColor = $bg; $form.ForeColor = $fg; $form.Font = $fontUi
$icoPath = @((Join-Path $Root 'assets\cloudphone.ico'), (Join-Path $Root 'dist\stage\assets\cloudphone.ico')) | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($icoPath) { $form.Icon = New-Object Drawing.Icon($icoPath) }

# --- tarjeta de estado ---
$pnl = New-Object Windows.Forms.Panel; $pnl.Location = New-Object Drawing.Point(16, 14); $pnl.Size = New-Object Drawing.Size(930, 132); $pnl.BackColor = $card; $pnl.Anchor = 'Top,Left,Right'
$form.Controls.Add($pnl)
$lblName = New-Lbl 'Cloud Phone' 16 10 420 30 $fontBig $fg
$lblServer = New-Lbl 'Servidor: …' 16 46 300 22 $fontUi $muted
$lblAndroid = New-Lbl 'Android: …' 16 70 300 22 $fontUi $muted
$lblRoot = New-Lbl 'Root: …' 16 94 300 22 $fontUi $muted
$lblListen = New-Lbl '' 330 46 300 22 $fontUi $muted
$lblClients = New-Lbl '' 330 70 300 22 $fontUi $muted
$lblUp = New-Lbl '' 330 94 300 22 $fontUi $muted
foreach ($c in $lblName, $lblServer, $lblAndroid, $lblRoot, $lblListen, $lblClients, $lblUp) { $pnl.Controls.Add($c) }
$btnSrvStart = New-Btn 'Iniciar servidor' 660 12 130 32 $false
$btnSrvStop = New-Btn 'Detener servidor' 796 12 128 32 $false
$btnAnStart = New-Btn 'Encender Android' 660 50 130 32 $true
$btnAnStop = New-Btn 'Apagar Android' 796 50 128 32 $false
$btnAnRestart = New-Btn 'Reiniciar Android' 660 88 130 32 $false
$btnAll = New-Btn 'Iniciar todo' 796 88 128 32 $true
foreach ($c in $btnSrvStart, $btnSrvStop, $btnAnStart, $btnAnStop, $btnAnRestart, $btnAll) { $c.Anchor = 'Top,Right'; $pnl.Controls.Add($c) }
$lblMsg = New-Lbl '' 16 152 930 22 $fontUi $muted; $lblMsg.Anchor = 'Top,Left,Right'; $form.Controls.Add($lblMsg)

# --- pestañas ---
$tabs = New-Object Windows.Forms.TabControl; $tabs.Location = New-Object Drawing.Point(16, 180); $tabs.Size = New-Object Drawing.Size(930, 450); $tabs.Anchor = 'Top,Bottom,Left,Right'; $tabs.Font = $fontUi
$form.Controls.Add($tabs)
function New-Tab($title) { $t = New-Object Windows.Forms.TabPage; $t.Text = $title; $t.BackColor = $card; $t.ForeColor = $fg; $tabs.TabPages.Add($t); return $t }
$tabInfo = New-Tab 'Pantalla e información'; $tabPair = New-Tab 'Emparejar iPhone'; $tabApk = New-Tab 'APK y apps'; $tabLogs = New-Tab 'Registro'

# Pantalla e información
$pic = New-Object Windows.Forms.PictureBox; $pic.Location = New-Object Drawing.Point(12, 12); $pic.Size = New-Object Drawing.Size(220, 390); $pic.SizeMode = 'Zoom'; $pic.BackColor = [Drawing.Color]::Black; $pic.Anchor = 'Top,Left,Bottom'
$btnShot = New-Btn 'Capturar pantalla' 244 12 160 32 $false
$chkAuto = New-Object Windows.Forms.CheckBox; $chkAuto.Text = 'Actualizar cada 2 s'; $chkAuto.Location = New-Object Drawing.Point(414, 18); $chkAuto.Size = New-Object Drawing.Size(180, 22); $chkAuto.ForeColor = $fg
$txtInfo = New-Object Windows.Forms.TextBox; $txtInfo.Multiline = $true; $txtInfo.ReadOnly = $true; $txtInfo.Location = New-Object Drawing.Point(244, 54); $txtInfo.Size = New-Object Drawing.Size(660, 348)
$txtInfo.BackColor = $bg; $txtInfo.ForeColor = $fg; $txtInfo.Font = $fontMono; $txtInfo.BorderStyle = 'None'; $txtInfo.Anchor = 'Top,Bottom,Left,Right'
$tabInfo.Controls.AddRange(@($pic, $btnShot, $chkAuto, $txtInfo))

# Emparejar
$lblCodeT = New-Lbl 'Código de emparejamiento (un solo uso)' 16 16 500 22 $fontUi $muted
$lblCode = New-Lbl '—' 16 40 360 48 (New-Object Drawing.Font('Consolas', 28, [Drawing.FontStyle]::Bold)) $acc
$btnNewCode = New-Btn 'Generar nuevo código' 400 46 180 32 $false
$lblHow = New-Lbl 'En la app: Ajustes → IP del PC + puerto + este código → Emparejar.' 16 96 880 22 $fontUi $muted
$lstDev = New-Object Windows.Forms.ListView; $lstDev.View = 'Details'; $lstDev.FullRowSelect = $true; $lstDev.Location = New-Object Drawing.Point(16, 132); $lstDev.Size = New-Object Drawing.Size(880, 220); $lstDev.BackColor = $bg; $lstDev.ForeColor = $fg; $lstDev.Anchor = 'Top,Left,Right,Bottom'
[void]$lstDev.Columns.Add('Dispositivo', 260); [void]$lstDev.Columns.Add('IP', 140); [void]$lstDev.Columns.Add('Último uso', 200); [void]$lstDev.Columns.Add('Emparejado', 200)
$btnRevoke = New-Btn 'Revocar seleccionado' 16 362 190 32 $false; $btnRevoke.Anchor = 'Bottom,Left'
$tabPair.Controls.AddRange(@($lblCodeT, $lblCode, $btnNewCode, $lblHow, $lstDev, $btnRevoke))

# APK
$btnPick = New-Btn 'Instalar APK…' 16 16 150 32 $true
$lblApk = New-Lbl '' 180 22 700 22 $fontUi $muted
$btnApps = New-Btn 'Actualizar lista' 16 60 150 32 $false
$lstApps = New-Object Windows.Forms.ListBox; $lstApps.Location = New-Object Drawing.Point(16, 100); $lstApps.Size = New-Object Drawing.Size(600, 300); $lstApps.BackColor = $bg; $lstApps.ForeColor = $fg; $lstApps.Font = $fontMono; $lstApps.Anchor = 'Top,Left,Bottom'
$btnLaunch = New-Btn 'Abrir' 632 100 130 32 $false; $btnUninstall = New-Btn 'Desinstalar' 632 140 130 32 $false
$tabApk.Controls.AddRange(@($btnPick, $lblApk, $btnApps, $lstApps, $btnLaunch, $btnUninstall))

# Logs
$txtLog = New-Object Windows.Forms.TextBox; $txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'; $txtLog.Dock = 'Fill'
$txtLog.BackColor = $bg; $txtLog.ForeColor = $fg; $txtLog.Font = $fontMono; $tabLogs.Controls.Add($txtLog)

# --- icono de bandeja ---
$tray = New-Object Windows.Forms.NotifyIcon; $tray.Text = 'Cloud Phone'; $tray.Visible = $true
if ($icoPath) { $tray.Icon = New-Object Drawing.Icon($icoPath) } else { $tray.Icon = [Drawing.SystemIcons]::Application }
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Mostrar ventana', $null, { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
[void]$menu.Items.Add('Iniciar todo', $null, { Do-StartAll })
[void]$menu.Items.Add('Detener todo', $null, { Do-StopAll })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Salir del administrador', $null, { $script:Exiting = $true; $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ $form.Show(); $form.WindowState = 'Normal'; $form.Activate() })
$form.add_FormClosing({ if (-not $script:Exiting -and $_.CloseReason -eq 'UserClosing') { $_.Cancel = $true; $form.Hide(); $tray.ShowBalloonTip(2500, 'Cloud Phone', 'Sigue funcionando en segundo plano. Doble clic en el icono para abrir.', 'Info') } else { $tray.Visible = $false } })

# ---------------- acciones ----------------
$scripts = $PSScriptRoot
function Say($text, $color) { $lblMsg.Text = $text; $lblMsg.ForeColor = $color }
function Do-StartServer($then) {
    $script:ThenAction = $then
    Say 'Iniciando servidor…' $warn
    Run-Bg { param($s, $c) & (Join-Path $s 'Start-Server.ps1') -Config $c } @($scripts, $Config) { param($r, $e) if ($e) { Say "No se pudo iniciar el servidor: $e" $bad } else { Say 'Servidor iniciado.' $ok; if ($script:ThenAction) { $a = $script:ThenAction; $script:ThenAction = $null; & $a } } }
}
function Do-AndroidAction($name, $label) {
    Say "$label… (puede tardar hasta 2 minutos)" $warn
    Run-Bg { param($b, $tk, $path) Invoke-RestMethod "$b$path" -Method Post -Headers @{ 'X-Admin-Token' = $tk } -Body '{}' -ContentType 'application/json' -TimeoutSec 400 | Out-Null } @($script:Base, (Get-Token), "/api/instances/$instance/$name") { param($r, $e) if ($e) { Say "Error: $e" $bad } else { Say 'Listo.' $ok } }
}
function Do-StartAll {
    Do-StartServer {
        # Si la configuración ya enciende el Android con el servidor, no pedirlo dos veces
        try { $st = (ApiGet '/admin/status' 5).instances[0]; if ($st.state -eq 'stopped') { Do-AndroidAction 'start' 'Encendiendo Android' } else { Say 'Servidor listo. El Android ya se está encendiendo…' $ok } }
        catch { Do-AndroidAction 'start' 'Encendiendo Android' }
    }
}
function Do-StopAll {
    Say 'Deteniendo todo (apaga el Android y el servidor)…' $warn
    Run-Bg { param($s, $c) & (Join-Path $s 'Stop-Server.ps1') -Config $c } @($scripts, $Config) { param($r, $e) Say 'Todo detenido.' $ok }
}
$btnSrvStart.Add_Click({ Do-StartServer $null })
$btnSrvStop.Add_Click({ Do-StopAll })
$btnAnStart.Add_Click({ Do-AndroidAction 'start' 'Encendiendo Android' })
$btnAnStop.Add_Click({ if ([Windows.Forms.MessageBox]::Show('¿Apagar el Android?', 'Cloud Phone', 'YesNo', 'Question') -eq 'Yes') { Do-AndroidAction 'stop' 'Apagando Android' } })
$btnAnRestart.Add_Click({ Do-AndroidAction 'restart' 'Reiniciando Android' })
$btnAll.Add_Click({ Do-StartAll })

function Do-Shot {
    $script:ShotBusy = $true
    $adb = Join-Path $sdk 'platform-tools\adb.exe'
    Run-Bg { param($adb, $uh, $out) $env:ANDROID_USER_HOME = $uh; Start-Process $adb -ArgumentList '-s', 'emulator-5554', 'exec-out', 'screencap', '-p' -RedirectStandardOutput $out -Wait -NoNewWindow; ,([IO.File]::ReadAllBytes($out)) } @($adb, $userHome, (Join-Path $env:TEMP 'cloudphone-shot.png')) {
        param($r, $e)
        $script:ShotBusy = $false
        if ($e) { return }
        try { $bytes = [byte[]]$r[0]; $ms = New-Object IO.MemoryStream(, $bytes); $old = $pic.Image; $pic.Image = [Drawing.Image]::FromStream($ms); if ($old) { $old.Dispose() } } catch { }
    }
}
$btnShot.Add_Click({ Do-Shot })

$btnNewCode.Add_Click({ try { $lblCode.Text = (ApiPost '/admin/pairing').code } catch { Say "No se pudo: $($_.Exception.Message)" $bad } })
$btnRevoke.Add_Click({ if ($lstDev.SelectedItems.Count) { $id = $lstDev.SelectedItems[0].Tag; try { Invoke-RestMethod "$script:Base/admin/devices/$id" -Method Delete -Headers @{ 'X-Admin-Token' = (Get-Token) } -TimeoutSec 4 | Out-Null; Refresh-Pair } catch { Say "No se pudo revocar: $($_.Exception.Message)" $bad } } })

function Refresh-Apps {
    try { $a = (ApiGet "/api/instances/$instance/apps" 6).apps; $lstApps.Items.Clear(); foreach ($x in $a) { [void]$lstApps.Items.Add($x) } } catch { $lstApps.Items.Clear(); [void]$lstApps.Items.Add("(" + $_.Exception.Message + ")") }
}
$btnApps.Add_Click({ Refresh-Apps })
$btnLaunch.Add_Click({ if ($lstApps.SelectedItem) { try { ApiPost "/api/instances/$instance/launch" @{ package = [string]$lstApps.SelectedItem } | Out-Null } catch { Say $_.Exception.Message $bad } } })
$btnUninstall.Add_Click({ if ($lstApps.SelectedItem -and [Windows.Forms.MessageBox]::Show("¿Desinstalar $($lstApps.SelectedItem)?", 'Cloud Phone', 'YesNo', 'Question') -eq 'Yes') { try { Invoke-RestMethod "$script:Base/api/instances/$instance/apps/$([uri]::EscapeDataString([string]$lstApps.SelectedItem))" -Method Delete -Headers @{ 'X-Admin-Token' = (Get-Token) } -TimeoutSec 30 | Out-Null; Refresh-Apps } catch { Say $_.Exception.Message $bad } } })
$btnPick.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog; $dlg.Filter = 'Aplicaciones Android (*.apk)|*.apk'; $dlg.Title = 'Elige un APK'
    if ($dlg.ShowDialog() -ne 'OK') { return }
    $lblApk.Text = "Instalando $([IO.Path]::GetFileName($dlg.FileName))…"; $lblApk.ForeColor = $warn
    Run-Bg {
        param($base, $tk, $inst, $file)
        $req = [Net.HttpWebRequest]::Create("$base/api/instances/$inst/apk?name=$([uri]::EscapeDataString([IO.Path]::GetFileName($file)))")
        $req.Method = 'POST'; $req.ContentType = 'application/octet-stream'; $req.Headers.Add('X-Admin-Token', $tk); $req.Timeout = 600000; $req.ReadWriteTimeout = 600000
        $fs = [IO.File]::OpenRead($file); $req.ContentLength = $fs.Length; $rs = $req.GetRequestStream(); $fs.CopyTo($rs); $rs.Close(); $fs.Close()
        try { $resp = $req.GetResponse(); $resp.Close(); 'OK' } catch [Net.WebException] { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); 'ERROR: ' + $sr.ReadToEnd() }
    } @($script:Base, (Get-Token), $instance, $dlg.FileName) {
        param($r, $e)
        $msg = if ($e) { "ERROR: $e" } else { [string]($r | Select-Object -First 1) }
        if ($msg -eq 'OK') { $lblApk.Text = 'APK instalado.'; $lblApk.ForeColor = $ok; Refresh-Apps } else { $lblApk.Text = $msg; $lblApk.ForeColor = $bad }
    }
})

# ---------------- refresco periódico ----------------
function Refresh-Pair {
    try {
        $lblCode.Text = (ApiGet '/admin/pairing').code
        $lstDev.Items.Clear()
        foreach ($d in (ApiGet '/admin/devices')) { $i = New-Object Windows.Forms.ListViewItem($d.name); [void]$i.SubItems.Add([string]$d.lastIp); [void]$i.SubItems.Add($(if ($d.lastSeen) { ([datetime]$d.lastSeen).ToString('g') } else { 'nunca' })); [void]$i.SubItems.Add(([datetime]$d.createdAt).ToString('g')); $i.Tag = $d.id; [void]$lstDev.Items.Add($i) }
    } catch { }
}
$script:ServerUp = $false
function Refresh-Status {
    try {
        $s = ApiGet '/admin/status' 2
        $script:ServerUp = $true
        $i = $s.instances[0]
        $lblName.Text = $i.name
        $lblServer.Text = 'Servidor: ● en marcha'; $lblServer.ForeColor = $ok
        $lblListen.Text = "Dirección: $($s.listen)"; $lblClients.Text = "iPhones emparejados: $(@($s.devices).Count)"
        $txt = @{ running = 'En marcha'; stopped = 'Apagado'; starting = 'Iniciando…'; stopping = 'Apagando…'; error = 'Error' }[$i.state]
        $lblAndroid.Text = "Android: ● $txt"; $lblAndroid.ForeColor = $(if ($i.state -eq 'running') { $ok } elseif ($i.state -in 'starting', 'stopping') { $warn } elseif ($i.state -eq 'error') { $bad } else { $muted })
        if ($i.state -eq 'running') { $lblRoot.Text = $(if ($i.root.active) { 'Root: ● activo (real)' } else { 'Root: ● no disponible' }); $lblRoot.ForeColor = $(if ($i.root.active) { $ok } else { $warn }) } else { $lblRoot.Text = 'Root: —'; $lblRoot.ForeColor = $muted }
        $lblUp.Text = $(if ($i.uptimeSeconds -ne $null) { "Android activo: $([math]::Floor($i.uptimeSeconds / 60)) min" } else { '' })
        $running = $i.state -eq 'running'; $idle = -not $i.busy
        $btnAnStart.Enabled = (-not $running) -and $idle -and $i.state -eq 'stopped'; $btnAnStop.Enabled = ($i.state -ne 'stopped') -and $idle; $btnAnRestart.Enabled = $running -and $idle
        $btnSrvStart.Enabled = $false; $btnSrvStop.Enabled = $true; $btnShot.Enabled = $running
        if ($i.error) { Say "Error del Android: $($i.error)" $bad }
        try { $c = @(ApiGet '/admin/connections'); $lblClients.Text += "   ·   streaming activo: $($c.Count)" } catch { }
        if ($tabs.SelectedTab -eq $tabInfo) {
            if ($running) { try { $n = ApiGet "/api/instances/$instance/info" 6; $txtInfo.Text = ("Android      {0} (API {1})`r`nModelo       {2}`r`nCompilación  {3} · {4}`r`nRoot         {5}`r`nPantalla     {6} @ {7} dpi`r`nMemoria      {8} MB`r`nAlmacenam.   {9} / {10} MB usados`r`nCPU emulador {11} núcleos asignados" -f $n.androidVersion, $n.sdk, $n.model, $n.buildType, $n.abi, $(if ($n.root.active) { "sí — $($n.root.id)" } else { 'no' }), $n.display.size, $n.display.density, $n.memoryTotalMB, $n.storage.usedMB, $n.storage.totalMB, $i.configured.cpuCores) } catch { } } else { $txtInfo.Text = 'El Android no está en marcha.' }
            if ($running -and $chkAuto.Checked -and -not $script:ShotBusy) { Do-Shot }
        }
        if ($tabs.SelectedTab -eq $tabPair) { Refresh-Pair }
        if ($tabs.SelectedTab -eq $tabLogs) { $l = ApiGet '/admin/logs?n=250' 3; $txtLog.Text = (($l | ForEach-Object { '{0} {1,-5} [{2}] {3}' -f $_.t.Substring(11, 8), $_.level.ToUpper(), $_.module, $_.msg }) -join "`r`n"); $txtLog.SelectionStart = $txtLog.Text.Length; $txtLog.ScrollToCaret() }
    } catch {
        $script:ServerUp = $false
        $lblServer.Text = 'Servidor: ● apagado'; $lblServer.ForeColor = $bad; $lblAndroid.Text = 'Android: —'; $lblAndroid.ForeColor = $muted; $lblRoot.Text = 'Root: —'; $lblRoot.ForeColor = $muted
        $lblListen.Text = ''; $lblClients.Text = ''; $lblUp.Text = ''
        $btnSrvStart.Enabled = $true; $btnSrvStop.Enabled = $false; $btnAnStart.Enabled = $false; $btnAnStop.Enabled = $false; $btnAnRestart.Enabled = $false; $btnShot.Enabled = $false
    }
}
$tabs.Add_SelectedIndexChanged({ Refresh-Status; if ($tabs.SelectedTab -eq $tabApk) { Refresh-Apps } })
$timer = New-Object Windows.Forms.Timer; $timer.Interval = 2000
$timer.Add_Tick({ Poll-Jobs; if (-not $script:Ticking) { $script:Ticking = $true; try { Refresh-Status } finally { $script:Ticking = $false } } })
$jobTimer = New-Object Windows.Forms.Timer; $jobTimer.Interval = 300; $jobTimer.Add_Tick({ Poll-Jobs }); $jobTimer.Start()

if ($SelfTestPng) {   # modo de verificación: construye, refresca una vez, guarda una imagen de la ventana y sale
    $form.Show(); Refresh-Status; $form.Refresh()
    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height); $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height))); $bmp.Save($SelfTestPng, [Drawing.Imaging.ImageFormat]::Png)
    $tray.Visible = $false; $form.Dispose(); 'SELFTEST OK'; exit 0
}
$timer.Start(); Refresh-Status
if ($StartAll) {
    if (-not $script:ServerUp) { Do-StartAll }
    else { try { if ((ApiGet '/admin/status' 5).instances[0].state -eq 'stopped') { Do-AndroidAction 'start' 'Encendiendo Android' } } catch { } }
}
[void][Windows.Forms.Application]::Run($form)
