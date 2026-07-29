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
    [string]$ProcessNames = '',  # comma-separated; omit when -Aumid is used
    [string]$LaunchCmd  = '',   # a URI (steam://...) OR an .exe path
    [string]$LaunchArgs = '',   # space-separated args, only for .exe launches
    [string]$Aumid      = '',   # Xbox / Game Pass / Store app: launch + match by package
    [switch]$CloseOnQuit
)

$root    = $PSScriptRoot
$safe    = ($Name -replace '[^\w.-]','_')
$LogFile = Join-Path $root ("launch-{0}.log" -f $safe)
function Log($m) { Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) }

$names = $ProcessNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }

# Packaged apps (Xbox / Game Pass / Store) have no dependable exe name and report
# MainWindowHandle == 0, so they are tracked by PACKAGE IDENTITY instead.
if ($Aumid) {
    Add-Type @"
using System; using System.Text; using System.Runtime.InteropServices;
public class PkgLite {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(int a, bool i, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    static extern int GetApplicationUserModelId(IntPtr p, ref uint len, StringBuilder id);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
    static extern int GetPackageFamilyName(IntPtr p, ref uint len, StringBuilder n);
    public static string IdentityOf(uint pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return "";
        try {
            string a = "", f = "";
            uint n = 260; StringBuilder sb = new StringBuilder((int)n);
            if (GetApplicationUserModelId(h, ref n, sb) == 0) a = sb.ToString();
            n = 260; sb = new StringBuilder((int)n);
            if (GetPackageFamilyName(h, ref n, sb) == 0) f = sb.ToString();
            return a + "|" + f;
        } finally { CloseHandle(h); }
    }
}
"@
    # The family name is the stable part of an AUMID ("Family!AppId") and is what
    # every process of the package reports, so match on that.
    $script:PkgNeedle = ($Aumid -split '!')[0]
    function Test-PackageRunning {
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            try {
                $id = [PkgLite]::IdentityOf([uint32]$p.Id)
                if ($id -and $id -like "*$script:PkgNeedle*") { return $true }
            } catch { }
        }
        return $false
    }
}

# 1. Tell the mirror watcher which window to copy this session.
$targetLine = if ($Aumid) { "package:$PkgNeedle" } else { $names -join ',' }
Set-Content -Path (Join-Path $root 'mirror-target.txt') -Value $targetLine -Encoding ascii

# 2. Already running? -> mirror-only, never relaunch.
$running = $false
if ($Aumid) {
    $running = Test-PackageRunning
} else {
    foreach ($n in $names) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { $running = $true; break } }
}

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
    if ($Aumid) {
        # Store/Xbox apps are not launchable by exe path; go through the shell.
        Start-Process explorer.exe -ArgumentList ("shell:appsFolder\{0}" -f $Aumid)
        Log "Launched packaged app via AUMID $Aumid"
    } elseif ($LaunchCmd -match '://') {
        Start-Process $LaunchCmd                                   # protocol/URI (e.g. steam://)
    } elseif ($LaunchCmd) {
        if ($LaunchArgs) { Start-Process -FilePath $LaunchCmd -ArgumentList ($LaunchArgs -split ' ') }
        else             { Start-Process -FilePath $LaunchCmd }
    } else {
        Log "No -LaunchCmd given; nothing to start (mirror-only of a not-yet-running app)."
    }
}
exit 0

