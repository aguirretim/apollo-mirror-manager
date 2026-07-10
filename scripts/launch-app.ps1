# launch-app.ps1 â€” GENERIC idempotent launcher for ANY Apollo tile.
# One script for every app. Wire a tile's `detached` command to this with the
# app's parameters; it gives the app the full "Palworld treatment":
#   * writes mirror-target.txt so the watcher mirrors THIS app's window
#   * idempotent: if the app is already running it does NOT relaunch (mirror-only)
#   * if -CloseOnQuit is passed, drops an ownership marker so close-app.ps1 will
#     close it when the Moonlight session ends (omit it for always-on apps).
#
# Example detached command (in apps.json):
#   powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File
#     "%LOCALAPPDATA%\ApolloScripts\launch-app.ps1"
#     -Name "Palworld" -ProcessNames "Palworld-Win64-Shipping,Palworld"
#     -LaunchCmd "steam://rungameid/1623730" -CloseOnQuit

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$ProcessNames,  # comma-separated
    [string]$LaunchCmd  = '',   # a URI (steam://...) OR an .exe path
    [string]$LaunchArgs = '',   # space-separated args, only for .exe launches
    [switch]$CloseOnQuit
)

$root    = $PSScriptRoot
$safe    = ($Name -replace '[^\w.-]','_')
$LogFile = Join-Path $root ("launch-{0}.log" -f $safe)
function Log($m) { Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) }

$names = $ProcessNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# 1. Tell the mirror watcher which window to copy this session.
Set-Content -Path (Join-Path $root 'mirror-target.txt') -Value ($names -join ',') -Encoding ascii

# 2. Already running? -> mirror-only, never relaunch.
$running = $false
foreach ($n in $names) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { $running = $true; break } }

$marker = Join-Path $root ("{0}.owned.flag" -f $safe)
if ($running) {
    Log "$Name already running -> mirror-only (no relaunch)."
} else {
    if ($CloseOnQuit) {
        Set-Content -Path $marker -Value ((Get-Date).ToString('s')) -Encoding ascii
        Log "$Name not running -> launching (Apollo-owned, WILL close on quit)."
    } else {
        Log "$Name not running -> launching (will NOT close on quit)."
    }
    if ($LaunchCmd -match '://') {
        Start-Process $LaunchCmd                                   # protocol/URI (e.g. steam://)
    } elseif ($LaunchCmd) {
        if ($LaunchArgs) { Start-Process -FilePath $LaunchCmd -ArgumentList ($LaunchArgs -split ' ') }
        else             { Start-Process -FilePath $LaunchCmd }
    } else {
        Log "No -LaunchCmd given; nothing to start (mirror-only of a not-yet-running app)."
    }
}
exit 0

