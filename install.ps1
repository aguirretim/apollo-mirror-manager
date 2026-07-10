# install.ps1 — one-shot installer for Apollo Mirror Manager.
# Run from the repo root:  right-click > Run with PowerShell,  or:
#   powershell -ExecutionPolicy Bypass -File .\install.ps1
#
# What it does (all per-user, no admin needed for the install itself):
#   1. Copies everything in scripts\ to  %LOCALAPPDATA%\ApolloScripts
#   2. Puts "Apollo Mirror Watcher" in your Startup folder (watcher starts at logon)
#   3. Registers the ApolloMirrorWatchdog scheduled task (restarts the watcher
#      every 10 min if something killed it)
#   4. Puts an "Apollo Mirror Manager" shortcut on your Desktop
#   5. Starts the watcher right now

$ErrorActionPreference = 'Stop'
$src  = Join-Path $PSScriptRoot 'scripts'
$dest = Join-Path $env:LOCALAPPDATA 'ApolloScripts'

if (-not (Test-Path (Join-Path $src 'mirror-watcher.ps1'))) {
    throw "Run this from the repo root (scripts\mirror-watcher.ps1 not found next to install.ps1)."
}

Write-Host "1/5 Copying scripts to $dest ..."
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item "$src\*" $dest -Force

Write-Host "2/5 Creating Startup entry (watcher starts when you log in) ..."
$ws = New-Object -ComObject WScript.Shell
$lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'Apollo Mirror Watcher.lnk'))
$lnk.TargetPath = 'C:\Windows\System32\wscript.exe'
$lnk.Arguments  = "`"$dest\start-mirror-watcher.vbs`""
$lnk.WorkingDirectory = $dest
$lnk.Description = 'Starts the Apollo/Moonlight game mirror watcher'
$lnk.Save()

Write-Host "3/5 Registering the self-repair watchdog task (every 10 min) ..."
$action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$dest\watchdog-mirror.vbs`""
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650))
)
Register-ScheduledTask -TaskName 'ApolloMirrorWatchdog' -Action $action -Trigger $triggers -Force | Out-Null

Write-Host "4/5 Creating the Desktop shortcut ..."
$lnk = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'Apollo Mirror Manager.lnk'))
$lnk.TargetPath = 'C:\Windows\System32\wscript.exe'
$lnk.Arguments  = "`"$dest\mirror-manager.vbs`""
$lnk.WorkingDirectory = $dest
$lnk.IconLocation = 'C:\Windows\System32\shell32.dll,18'
$lnk.Description = 'Health-check the game mirror and add games to Moonlight'
$lnk.Save()

Write-Host "5/5 Starting the watcher now ..."
Start-Process wscript.exe -ArgumentList "`"$dest\start-mirror-watcher.vbs`""

Write-Host ""
Write-Host "Done! Double-click 'Apollo Mirror Manager' on your Desktop to open the app." -ForegroundColor Green
Write-Host "IMPORTANT if you use Bitdefender (or similar AV): add $dest"
Write-Host "to its exception lists (Antivirus AND Advanced Threat Defense), or the"
Write-Host "watcher will keep getting killed. See the README's Troubleshooting section."
