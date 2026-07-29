# close-app.ps1 — GENERIC session-end teardown for ANY Apollo tile.
# Wire a tile's prep-cmd "undo" to this (only for apps you want closed on quit).
# Symmetric with launch-app.ps1: it ONLY closes the app if WE launched it this
# session (the ownership marker exists). If the app was already running when you
# connected (mirror-only), or it's an always-on app launched without
# -CloseOnQuit, there is no marker and we leave it running.

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [string]$ProcessNames = '',  # comma-separated; omit when -Aumid is used
    [string]$Aumid        = ''   # Xbox / Game Pass / Store app: close by package identity
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

if ($Aumid) {
    # Packaged app: resolve the owning processes by package identity, since the
    # exe name is not stable (and may not even be readable under WindowsApps).
    Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class PkgClose {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int a, bool i, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    static extern int GetPackageFamilyName(IntPtr p, ref uint len, StringBuilder n);
    public static string FamilyOf(uint pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return "";
        try { uint n = 260; StringBuilder sb = new StringBuilder((int)n);
              return GetPackageFamilyName(h, ref n, sb) == 0 ? sb.ToString() : ""; }
        finally { CloseHandle(h); }
    }
}
"@
    $needle = ($Aumid -split '!')[0]
    function Get-PkgProcs {
        Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try { $f = [PkgClose]::FamilyOf([uint32]$_.Id); $f -and $f -like "*$needle*" } catch { $false }
        }
    }
    $procs = @(Get-PkgProcs)
    Log "Package $needle -> $($procs.Count) process(es) to close."
    $procs | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
    Start-Sleep -Seconds 5
    Get-PkgProcs | ForEach-Object {
        Log "Force-stopping leftover $($_.ProcessName) (pid $($_.Id))."
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop } catch {}
    }
} else {
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
}
Remove-Item $marker -ErrorAction SilentlyContinue
Log "$Name closed; ownership marker cleared."
exit 0
