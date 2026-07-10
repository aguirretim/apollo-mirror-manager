# close-app.ps1 — GENERIC session-end teardown for ANY Apollo tile.
# Wire a tile's prep-cmd "undo" to this (only for apps you want closed on quit).
# Symmetric with launch-app.ps1: it ONLY closes the app if WE launched it this
# session (the ownership marker exists). If the app was already running when you
# connected (mirror-only), or it's an always-on app launched without
# -CloseOnQuit, there is no marker and we leave it running.

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$ProcessNames   # comma-separated
)

$root    = $PSScriptRoot
$safe    = ($Name -replace '[^\w.-]','_')
$LogFile = Join-Path $root ("launch-{0}.log" -f $safe)
function Log($m) { Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) }

$marker = Join-Path $root ("{0}.owned.flag" -f $safe)
$names  = $ProcessNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

if (-not (Test-Path $marker)) {
    Log "$Name session ended -> not Apollo-owned (no marker). Leaving it running."
    exit 0
}

Log "$Name session ended -> Apollo-owned. Closing."
foreach ($n in $names) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
}
Start-Sleep -Seconds 5   # let it save + exit gracefully
foreach ($n in $names) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
        Log "Force-stopping leftover $($_.Name) (pid $($_.Id))."
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
    }
}
Remove-Item $marker -ErrorAction SilentlyContinue
Log "$Name closed; ownership marker cleared."
exit 0
