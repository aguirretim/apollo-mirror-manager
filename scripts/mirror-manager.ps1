# mirror-manager.ps1 â€” Apollo Mirror Manager
# Desktop GUI that (1) health-checks & repairs the game-mirror system and
# (2) adds/removes Apollo (Moonlight) game tiles without hand-editing anything.
# Launch via mirror-manager.vbs or the "Apollo Mirror Manager" desktop shortcut.
# Repo: https://github.com/aguirretim/apollo-mirror-manager
param([switch]$SelfTest, [switch]$TestGui, [string]$Screenshot = '')

$ErrorActionPreference = 'Stop'
$Root      = $PSScriptRoot
$AppsJson  = 'C:\Program Files\Apollo\config\apps.json'
$SteamRoot = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
if (-not $SteamRoot) { $SteamRoot = 'C:\Program Files (x86)\Steam' }
$SteamRoot = $SteamRoot -replace '/', '\'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Apollo Mirror Watcher.lnk'
$WatchdogTask = 'ApolloMirrorWatchdog'

# --- self-elevate (apps.json lives in Program Files; service restart needs admin) ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $SelfTest -and -not $TestGui -and -not $Screenshot) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    exit
}

# ============================== core functions ==============================

function Get-WatcherProcess {
    $w = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*-File*mirror-watcher.ps1*' -and $_.CommandLine -notlike '*-Command*' }
    if ($w) { return ($w | Select-Object -First 1) }
    # PID-file fallback: an elevated/non-elevated mismatch hides the command line
    $pf = Join-Path $Root 'mirror-watcher.pid'
    if (Test-Path $pf) {
        $watcherPid = (Get-Content $pf -ErrorAction SilentlyContinue | Select-Object -First 1) -as [int]
        if ($watcherPid) {
            $p = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -eq 'powershell' -and
                $p.StartTime -le (Get-Item $pf).LastWriteTime.AddSeconds(5)) {
                return [pscustomobject]@{ ProcessId = $p.Id }
            }
        }
    }
    return $null
}

function Test-ApolloRunning {
    $s = Get-Service ApolloService -ErrorAction SilentlyContinue
    return ($null -ne $s -and $s.Status -eq 'Running')
}

function Test-WatchdogTask {
    return ($null -ne (Get-ScheduledTask -TaskName $WatchdogTask -ErrorAction SilentlyContinue))
}

function Start-Watcher {
    Start-Process wscript.exe -ArgumentList "`"$Root\start-mirror-watcher.vbs`""
}

function Repair-StartupShortcut {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($StartupLnk)
    $lnk.TargetPath = 'C:\Windows\System32\wscript.exe'
    $lnk.Arguments = "`"$Root\start-mirror-watcher.vbs`""
    $lnk.WorkingDirectory = $Root
    $lnk.Description = 'Starts the Apollo/Moonlight game mirror watcher'
    $lnk.Save()
}

function Repair-WatchdogTask {
    $action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$Root\watchdog-mirror.vbs`""
    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
            -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650))
    )
    Register-ScheduledTask -TaskName $WatchdogTask -Action $action -Trigger $triggers -Force | Out-Null
}

function Get-ApolloTiles {
    if (-not (Test-Path $AppsJson)) { return @() }
    $j = Get-Content $AppsJson -Raw | ConvertFrom-Json
    return @($j.apps)
}

function Get-SteamLibraries {
    $paths = @()
    $vdf = Join-Path $SteamRoot 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        $raw = Get-Content $vdf -Raw
        foreach ($m in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
            $paths += ($m.Groups[1].Value -replace '\\\\', '\')
        }
    }
    if (-not $paths) { $paths = @($SteamRoot) }
    $paths | ForEach-Object { Join-Path $_ 'steamapps' } | Where-Object { Test-Path $_ } | Select-Object -Unique
}

function Get-InstalledSteamGames {
    # excluded: Steamworks redist, SteamVR, OVR Advanced Settings
    $exclIds = @('228980', '250820', '1009850')
    $games = foreach ($lib in Get-SteamLibraries) {
        foreach ($acf in Get-ChildItem $lib -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $raw = Get-Content $acf.FullName -Raw
            $appid = [regex]::Match($raw, '"appid"\s+"(\d+)"').Groups[1].Value
            $name  = [regex]::Match($raw, '"name"\s+"([^"]+)"').Groups[1].Value
            $idir  = [regex]::Match($raw, '"installdir"\s+"([^"]+)"').Groups[1].Value
            if ($appid -and $name -and $exclIds -notcontains $appid -and
                $name -notmatch 'Redistributable|Runtime|Proton |Steamworks|SteamVR') {
                [pscustomobject]@{
                    AppId      = $appid
                    Name       = $name
                    InstallDir = (Join-Path $lib "common\$idir")
                }
            }
        }
    }
    $games | Sort-Object Name -Unique
}

function Get-ProcessCandidates {
    # Best-guess process names for a game: scan its install dir's exes,
    # skip junk, prefer UE 'Binaries\Win64\*Shipping' + name matches + big exes.
    param($Game)
    if (-not (Test-Path $Game.InstallDir)) { return @() }
    $junk = 'crash|redist|vc_|vcredist|directx|dxsetup|dotnet|eac|easyanticheat|battleye|helper|setup|unins|install|report|diagnostic|cleanup|touchup'
    $exes = Get-ChildItem $Game.InstallDir -Recurse -Filter *.exe -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch $junk }
    if (-not $exes) { return @() }
    $simple = ($Game.Name -replace '[^A-Za-z0-9]', '')
    $scored = foreach ($e in $exes) {
        $s = 0
        if ($e.FullName -match 'Binaries\\Win64') { $s += 4 }
        if ($e.BaseName -match 'Shipping$') { $s += 4 }
        $eb = ($e.BaseName -replace '[^A-Za-z0-9]', '')
        if ($simple -and $eb -and ($eb -like "*$simple*" -or $simple -like "*$eb*")) { $s += 3 }
        $s += [Math]::Min(2, [int]($e.Length / 50MB))
        [pscustomobject]@{ BaseName = $e.BaseName; Score = $s }
    }
    $scored | Sort-Object Score -Descending | Select-Object -First 3 -ExpandProperty BaseName | Select-Object -Unique
}

function Add-Tile {
    # Wraps add-app.ps1; returns a status string.
    param([string]$Name, [string]$ProcessNames, [int]$SteamAppId = 0,
          [string]$LaunchCmd = '', [string]$LaunchArgs = '', [bool]$CloseOnQuit = $true)
    $params = @{ Name = $Name; ProcessNames = $ProcessNames }
    if ($SteamAppId -gt 0) { $params.SteamAppId = $SteamAppId }
    if ($LaunchCmd)  { $params.LaunchCmd = $LaunchCmd }
    if ($LaunchArgs) { $params.LaunchArgs = $LaunchArgs }
    if (-not $CloseOnQuit) { $params.NoCloseOnQuit = $true }
    try {
        & (Join-Path $Root 'add-app.ps1') @params *>&1 | Out-Null
        return "OK: added '$Name'"
    } catch {
        return "FAILED: '$Name' - $($_.Exception.Message)"
    }
}

function Remove-Tile {
    param([string]$Name)
    Copy-Item $AppsJson ("$AppsJson.bak-" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
    $j = Get-Content $AppsJson -Raw | ConvertFrom-Json
    $j.apps = @($j.apps | Where-Object { $_.name -ne $Name })
    $j | ConvertTo-Json -Depth 12 | Set-Content $AppsJson -Encoding utf8
    $null = Get-Content $AppsJson -Raw | ConvertFrom-Json   # validate
}

function Restart-Apollo {
    Restart-Service ApolloService -Force
}

# ============================== self-test mode ==============================
if ($SelfTest) {
    "Apollo service running : $(Test-ApolloRunning)"
    "Watcher running        : $([bool](Get-WatcherProcess))"
    "Startup shortcut       : $(Test-Path $StartupLnk)"
    "Watchdog task          : $(Test-WatchdogTask)"
    $tiles = Get-ApolloTiles
    "Tiles in apps.json     : $($tiles.Count)"
    $games = @(Get-InstalledSteamGames)
    "Installed Steam games  : $($games.Count)"
    $notAdded = @($games | Where-Object { $tiles.name -notcontains $_.Name })
    "Not yet added          : $($notAdded.Count) -> $(($notAdded | Select-Object -First 5 -ExpandProperty Name) -join ', ')"
    if ($notAdded) {
        $g = $notAdded[0]
        "Candidates for '$($g.Name)': $((Get-ProcessCandidates $g) -join ', ')"
    }
    exit 0
}

# ============================== GUI ==============================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Apollo Mirror Manager'
$form.Size = New-Object System.Drawing.Size(780, 600)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = $form.Size

$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Dock = 'Fill'
$form.Controls.Add($tabs)

$mono = New-Object System.Drawing.Font('Consolas', 9)
$green = [System.Drawing.Color]::FromArgb(0, 140, 0)
$red   = [System.Drawing.Color]::FromArgb(190, 0, 0)

function New-Label($text, $x, $y, $w, $h) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text; $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    return $l
}
function New-Button($text, $x, $y, $w, $h) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text; $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    return $b
}

# ---------------------------- TAB 1: Health ----------------------------
$tabHealth = New-Object System.Windows.Forms.TabPage
$tabHealth.Text = 'Health'
$tabs.TabPages.Add($tabHealth)

$statApollo   = New-Label '...' 20 20 700 22
$statWatcher  = New-Label '...' 20 46 700 22
$statStartup  = New-Label '...' 20 72 700 22
$statWatchdog = New-Label '...' 20 98 700 22
foreach ($l in @($statApollo, $statWatcher, $statStartup, $statWatchdog)) {
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $tabHealth.Controls.Add($l)
}

$btnFix     = New-Button 'Fix everything' 20 130 150 32
$btnRestart = New-Button 'Restart Apollo service' 180 130 170 32
$btnRefresh = New-Button 'Refresh' 360 130 90 32
$btnLog     = New-Button 'Open scripts folder' 460 130 150 32
$tabHealth.Controls.AddRange(@($btnFix, $btnRestart, $btnRefresh, $btnLog))

$tabHealth.Controls.Add((New-Label 'Recent watcher activity:' 20 175 300 20))
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true; $txtLog.ReadOnly = $true; $txtLog.ScrollBars = 'Vertical'
$txtLog.Font = $mono
$txtLog.Location = New-Object System.Drawing.Point(20, 198)
$txtLog.Size = New-Object System.Drawing.Size(715, 300)
$txtLog.Anchor = 'Top,Left,Right,Bottom'
$tabHealth.Controls.Add($txtLog)

$script:refreshHealth = {
    $ok = Test-ApolloRunning
    $statApollo.Text = "Apollo streaming service:  " + $(if ($ok) { 'RUNNING' } else { 'STOPPED' })
    $statApollo.ForeColor = if ($ok) { $green } else { $red }

    $w = Get-WatcherProcess
    $statWatcher.Text = "Game mirror watcher:  " + $(if ($w) { "RUNNING (PID $($w.ProcessId))" } else { 'NOT RUNNING - Retroid will show a black/empty screen' })
    $statWatcher.ForeColor = if ($w) { $green } else { $red }

    $ok = Test-Path $StartupLnk
    $statStartup.Text = "Starts with Windows:  " + $(if ($ok) { 'YES' } else { 'NO - watcher will not survive a reboot' })
    $statStartup.ForeColor = if ($ok) { $green } else { $red }

    $ok = Test-WatchdogTask
    $statWatchdog.Text = "Auto-repair watchdog (every 10 min):  " + $(if ($ok) { 'ENABLED' } else { 'NOT SET UP' })
    $statWatchdog.ForeColor = if ($ok) { $green } else { $red }

    $logFile = Join-Path $Root 'mirror-watcher.log'
    if (Test-Path $logFile) {
        $txtLog.Text = (Get-Content $logFile -Tail 15) -join "`r`n"
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
}

$btnRefresh.Add_Click({ & $script:refreshHealth })
$btnLog.Add_Click({ Start-Process explorer.exe $Root })
$btnFix.Add_Click({
    if (-not (Get-WatcherProcess)) { Start-Watcher; Start-Sleep -Milliseconds 1500 }
    Repair-StartupShortcut
    Repair-WatchdogTask
    if (-not (Test-ApolloRunning)) { try { Start-Service ApolloService } catch {} }
    & $script:refreshHealth
    [System.Windows.Forms.MessageBox]::Show('Done. If the watcher keeps dying right after starting, add the ApolloScripts folder to BOTH Bitdefender exception lists (Antivirus AND Advanced Threat Defense).', 'Fix everything') | Out-Null
})
$btnRestart.Add_Click({
    $r = [System.Windows.Forms.MessageBox]::Show('Restarting Apollo drops any active Moonlight stream. Continue?', 'Restart Apollo', 'YesNo', 'Warning')
    if ($r -eq 'Yes') { Restart-Apollo; & $script:refreshHealth }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 5000
$timer.Add_Tick({ & $script:refreshHealth })
$timer.Start()

# ---------------------------- TAB 2: Add Steam game ----------------------------
$tabSteam = New-Object System.Windows.Forms.TabPage
$tabSteam.Text = 'Add Steam game'
$tabs.TabPages.Add($tabSteam)

$tabSteam.Controls.Add((New-Label 'Installed Steam games (games already on Moonlight are marked):' 20 15 600 20))

$lvGames = New-Object System.Windows.Forms.ListView
$lvGames.View = 'Details'; $lvGames.FullRowSelect = $true; $lvGames.MultiSelect = $true
$lvGames.Location = New-Object System.Drawing.Point(20, 38)
$lvGames.Size = New-Object System.Drawing.Size(715, 330)
$lvGames.Anchor = 'Top,Left,Right,Bottom'
[void]$lvGames.Columns.Add('Game', 420)
[void]$lvGames.Columns.Add('AppId', 90)
[void]$lvGames.Columns.Add('On Moonlight?', 150)
$tabSteam.Controls.Add($lvGames)

$chkClose = New-Object System.Windows.Forms.CheckBox
$chkClose.Text = 'Close the game on my PC when I quit the stream'
$chkClose.Checked = $true
$chkClose.Location = New-Object System.Drawing.Point(20, 378)
$chkClose.Size = New-Object System.Drawing.Size(340, 22)
$chkClose.Anchor = 'Left,Bottom'
$tabSteam.Controls.Add($chkClose)

$chkRestartAfter = New-Object System.Windows.Forms.CheckBox
$chkRestartAfter.Text = 'Restart Apollo after adding (required for the tile to appear; drops any active stream)'
$chkRestartAfter.Checked = $true
$chkRestartAfter.Location = New-Object System.Drawing.Point(20, 402)
$chkRestartAfter.Size = New-Object System.Drawing.Size(560, 22)
$chkRestartAfter.Anchor = 'Left,Bottom'
$tabSteam.Controls.Add($chkRestartAfter)

$btnScan = New-Button 'Rescan Steam' 20 432 120 30
$btnScan.Anchor = 'Left,Bottom'
$btnAddSteam = New-Button 'Add selected game(s) to Moonlight' 150 432 240 30
$btnAddSteam.Anchor = 'Left,Bottom'
$lblSteamStatus = New-Label '' 400 437 330 22
$lblSteamStatus.Anchor = 'Left,Bottom'
$tabSteam.Controls.AddRange(@($btnScan, $btnAddSteam, $lblSteamStatus))

$script:steamGames = @()
$script:scanSteam = {
    $lblSteamStatus.Text = 'Scanning...'
    $form.Refresh()
    $tileNames = @((Get-ApolloTiles).name)
    $script:steamGames = @(Get-InstalledSteamGames)
    $lvGames.Items.Clear()
    foreach ($g in $script:steamGames) {
        $added = $tileNames -contains $g.Name
        $item = New-Object System.Windows.Forms.ListViewItem($g.Name)
        [void]$item.SubItems.Add($g.AppId)
        [void]$item.SubItems.Add($(if ($added) { 'Yes' } else { '' }))
        $item.Tag = $g
        if ($added) { $item.ForeColor = [System.Drawing.Color]::Gray }
        [void]$lvGames.Items.Add($item)
    }
    $lblSteamStatus.Text = "$($script:steamGames.Count) games found"
}
$btnScan.Add_Click({ & $script:scanSteam })

$btnAddSteam.Add_Click({
    $sel = @($lvGames.SelectedItems | Where-Object { $_.SubItems[2].Text -ne 'Yes' })
    if (-not $sel) {
        [System.Windows.Forms.MessageBox]::Show('Select at least one game that is not already on Moonlight.', 'Add game') | Out-Null
        return
    }
    $results = @()
    foreach ($item in $sel) {
        $g = $item.Tag
        $lblSteamStatus.Text = "Adding $($g.Name)..."
        $form.Refresh()
        $procs = @(Get-ProcessCandidates $g)
        if (-not $procs) { $procs = @(($g.Name -replace '[^\w.-]', '_')) }
        $results += Add-Tile -Name $g.Name -ProcessNames ($procs -join ',') -SteamAppId ([int]$g.AppId) -CloseOnQuit $chkClose.Checked
    }
    if ($chkRestartAfter.Checked) {
        $lblSteamStatus.Text = 'Restarting Apollo...'
        $form.Refresh()
        try { Restart-Apollo; $results += 'Apollo restarted - tile(s) are live.' }
        catch { $results += "Apollo restart FAILED: $($_.Exception.Message)" }
    } else {
        $results += 'NOTE: tile(s) appear only after Apollo restarts (Health tab button).'
    }
    & $script:scanSteam
    [System.Windows.Forms.MessageBox]::Show(($results -join "`r`n"), 'Add Steam game') | Out-Null
})

# ---------------------------- TAB 3: Add other app ----------------------------
$tabOther = New-Object System.Windows.Forms.TabPage
$tabOther.Text = 'Add other app'
$tabs.TabPages.Add($tabOther)

$tabOther.Controls.Add((New-Label 'Add any non-Steam program (like Discord) as a Moonlight tile.' 20 15 600 20))
$tabOther.Controls.Add((New-Label 'Name on Moonlight:' 20 50 140 20))
$txtName = New-Object System.Windows.Forms.TextBox
$txtName.Location = New-Object System.Drawing.Point(170, 47); $txtName.Size = New-Object System.Drawing.Size(300, 24)
$tabOther.Controls.Add($txtName)

$tabOther.Controls.Add((New-Label 'Program (.exe):' 20 82 140 20))
$txtExe = New-Object System.Windows.Forms.TextBox
$txtExe.Location = New-Object System.Drawing.Point(170, 79); $txtExe.Size = New-Object System.Drawing.Size(430, 24)
$btnBrowse = New-Button 'Browse...' 610 78 90 26
$tabOther.Controls.AddRange(@($txtExe, $btnBrowse))

$tabOther.Controls.Add((New-Label 'Arguments (optional):' 20 114 140 20))
$txtArgs = New-Object System.Windows.Forms.TextBox
$txtArgs.Location = New-Object System.Drawing.Point(170, 111); $txtArgs.Size = New-Object System.Drawing.Size(430, 24)
$tabOther.Controls.Add($txtArgs)

$tabOther.Controls.Add((New-Label 'Process name(s):' 20 146 140 20))
$txtProcs = New-Object System.Windows.Forms.TextBox
$txtProcs.Location = New-Object System.Drawing.Point(170, 143); $txtProcs.Size = New-Object System.Drawing.Size(300, 24)
$tabOther.Controls.Add($txtProcs)
$tabOther.Controls.Add((New-Label '(auto-filled from the exe; comma-separated, no .exe â€” this is how the mirror finds the window)' 170 170 540 34))

$chkClose2 = New-Object System.Windows.Forms.CheckBox
$chkClose2.Text = 'Close the app on my PC when I quit the stream (uncheck for always-on apps like Discord)'
$chkClose2.Checked = $true
$chkClose2.Location = New-Object System.Drawing.Point(20, 210)
$chkClose2.Size = New-Object System.Drawing.Size(600, 22)
$tabOther.Controls.Add($chkClose2)

$chkRestartAfter2 = New-Object System.Windows.Forms.CheckBox
$chkRestartAfter2.Text = 'Restart Apollo after adding (required for the tile to appear; drops any active stream)'
$chkRestartAfter2.Checked = $true
$chkRestartAfter2.Location = New-Object System.Drawing.Point(20, 236)
$chkRestartAfter2.Size = New-Object System.Drawing.Size(600, 22)
$tabOther.Controls.Add($chkRestartAfter2)

$btnAddOther = New-Button 'Add to Moonlight' 20 272 160 32
$tabOther.Controls.Add($btnAddOther)

$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Programs (*.exe)|*.exe'
    if ($dlg.ShowDialog() -eq 'OK') {
        $txtExe.Text = $dlg.FileName
        $base = [System.IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
        if (-not $txtProcs.Text) { $txtProcs.Text = $base }
        if (-not $txtName.Text)  { $txtName.Text = $base }
    }
})

$btnAddOther.Add_Click({
    if (-not $txtName.Text -or -not $txtExe.Text -or -not $txtProcs.Text) {
        [System.Windows.Forms.MessageBox]::Show('Fill in Name, Program and Process name(s) first.', 'Add app') | Out-Null
        return
    }
    $msg = Add-Tile -Name $txtName.Text -ProcessNames $txtProcs.Text -LaunchCmd $txtExe.Text -LaunchArgs $txtArgs.Text -CloseOnQuit $chkClose2.Checked
    if ($chkRestartAfter2.Checked -and $msg -like 'OK*') {
        try { Restart-Apollo; $msg += "`r`nApollo restarted - tile is live." }
        catch { $msg += "`r`nApollo restart FAILED: $($_.Exception.Message)" }
    }
    [System.Windows.Forms.MessageBox]::Show($msg, 'Add app') | Out-Null
})

# ---------------------------- TAB 4: Manage tiles ----------------------------
$tabManage = New-Object System.Windows.Forms.TabPage
$tabManage.Text = 'Manage tiles'
$tabs.TabPages.Add($tabManage)

$tabManage.Controls.Add((New-Label 'Current Moonlight tiles:' 20 15 300 20))
$lbTiles = New-Object System.Windows.Forms.ListBox
$lbTiles.Location = New-Object System.Drawing.Point(20, 38)
$lbTiles.Size = New-Object System.Drawing.Size(400, 380)
$lbTiles.Anchor = 'Top,Left,Bottom'
$tabManage.Controls.Add($lbTiles)

$btnReloadTiles = New-Button 'Refresh' 440 38 130 30
$btnRemoveTile  = New-Button 'Remove selected' 440 76 130 30
$tabManage.Controls.AddRange(@($btnReloadTiles, $btnRemoveTile))
$tabManage.Controls.Add((New-Label 'Removing a tile only takes it off Moonlight - nothing is uninstalled. Apollo restarts to apply (drops any active stream).' 440 116 290 80))

$script:reloadTiles = {
    $lbTiles.Items.Clear()
    foreach ($t in (Get-ApolloTiles)) { [void]$lbTiles.Items.Add($t.name) }
}
$btnReloadTiles.Add_Click({ & $script:reloadTiles })
$btnRemoveTile.Add_Click({
    $name = $lbTiles.SelectedItem
    if (-not $name) { return }
    if ($name -eq 'Desktop') {
        [System.Windows.Forms.MessageBox]::Show('The Desktop tile stays - Moonlight needs it.', 'Remove tile') | Out-Null
        return
    }
    $r = [System.Windows.Forms.MessageBox]::Show("Remove '$name' from Moonlight and restart Apollo?", 'Remove tile', 'YesNo', 'Warning')
    if ($r -eq 'Yes') {
        Remove-Tile -Name $name
        try { Restart-Apollo } catch {}
        & $script:reloadTiles
    }
})

# ---------------------------- go ----------------------------
$form.Add_Shown({
    & $script:refreshHealth
    & $script:reloadTiles
    & $script:scanSteam
})
if ($Screenshot) {
    # -Screenshot <outDir>: render each tab and save a PNG (used for the README)
    New-Item -ItemType Directory -Force -Path $Screenshot | Out-Null
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 800
    [System.Windows.Forms.Application]::DoEvents()
    $tabNames = @('health','add-steam-game','add-other-app','manage-tiles')
    for ($i = 0; $i -lt $tabs.TabPages.Count; $i++) {
        $tabs.SelectedIndex = $i
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object System.Drawing.Bitmap $form.Width, $form.Height
        $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle 0, 0, $form.Width, $form.Height))
        $out = Join-Path $Screenshot ("{0}.png" -f $tabNames[$i])
        $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Output "saved $out"
    }
    $form.Close()
} elseif ($TestGui) {
    $form.Show()
    $deadline = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $deadline) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    $form.Close()
    Write-Output "GUI OK - built and rendered all 4 tabs without error"
} else {
    [void]$form.ShowDialog()
}
$timer.Stop()


