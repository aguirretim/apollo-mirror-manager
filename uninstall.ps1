# uninstall.ps1 — removes everything install.ps1 set up.
# Your Apollo apps.json tiles are NOT touched (remove those in the Manager first
# if you want them gone). The %LOCALAPPDATA%\ApolloScripts folder is left on
# disk in case Apollo tiles still point at launch-app.ps1 — delete it manually
# once you've removed those tiles.

$dest = Join-Path $env:LOCALAPPDATA 'ApolloScripts'

# stop the watcher
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*-File*mirror-watcher.ps1*' -and $_.CommandLine -notlike '*-Command*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Unregister-ScheduledTask -TaskName 'ApolloMirrorWatchdog' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'Apollo Mirror Watcher.lnk') -ErrorAction SilentlyContinue
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Apollo Mirror Manager.lnk') -ErrorAction SilentlyContinue

Write-Host "Uninstalled (watcher stopped, watchdog task + shortcuts removed)."
Write-Host "Script folder left at $dest - delete it manually once no Apollo tiles use it."
