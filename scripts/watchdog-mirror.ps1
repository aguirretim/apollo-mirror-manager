# watchdog-mirror.ps1 — restart the mirror watcher if it is not running.
# Run every 10 min by the 'ApolloMirrorWatchdog' scheduled task (via watchdog-mirror.vbs).
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Log  = Join-Path $Root 'watchdog.log'

function Test-WatcherAlive {
    # 1) command-line match (fails across elevation boundaries: a non-elevated
    #    checker sees a NULL CommandLine on an elevated watcher)
    $w = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*-File*mirror-watcher.ps1*' -and $_.CommandLine -notlike '*-Command*' }
    if ($w) { return $true }
    # 2) PID-file fallback (mirror-watcher.ps1 writes its PID at startup)
    $pf = Join-Path $Root 'mirror-watcher.pid'
    if (Test-Path $pf) {
        $watcherPid = (Get-Content $pf -ErrorAction SilentlyContinue | Select-Object -First 1) -as [int]
        if ($watcherPid) {
            $p = Get-Process -Id $watcherPid -ErrorAction SilentlyContinue
            # guard against PID reuse: the watcher wrote the file right after ITS
            # start, so its StartTime must not be later than the file's timestamp
            if ($p -and $p.ProcessName -eq 'powershell' -and
                $p.StartTime -le (Get-Item $pf).LastWriteTime.AddSeconds(5)) { return $true }
        }
    }
    return $false
}

if (-not (Test-WatcherAlive)) {
    Add-Content $Log "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] Watcher not running - restarting it."
    Start-Process wscript.exe -ArgumentList "`"$Root\start-mirror-watcher.vbs`""
}
