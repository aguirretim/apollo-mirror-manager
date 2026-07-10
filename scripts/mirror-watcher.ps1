# mirror-watcher.ps1
# Persistent, SteamVR-dashboard-style mirror. Runs in YOUR interactive session
# (started at logon / by double-click), sits idle until Apollo creates a virtual
# display, then shows a LIVE COPY of the game window on it. The real game stays
# on your physical monitor, untouched. Loops forever.
#
# Design (idempotent + flap-proof):
#   * ONE persistent borderless form is created at startup and never disposed.
#     We only Show/Hide it and (re)register the DWM thumbnail. Repeatedly
#     creating + disposing WinForms forms in a long-lived STA pump wedges the
#     message loop -- that was the old "alive but no longer mirroring" bug.
#   * Each tick we ask: is a virtual display + game window present?
#       - present & not already mirroring  -> start the mirror once.
#       - present & already mirroring       -> just maintain (re-register on
#                                              window/VD change). DON'T restart.
#       - absent                            -> only tear the mirror down after
#                                              it's been gone for GraceTicks in a
#                                              row (debounce), so a transient
#                                              MainWindowHandle==0 (loading /
#                                              alt-tab) never causes a flap.
#
# Must run in the interactive desktop (NOT via Apollo's detached command, which
# runs on an isolated desktop that can't enumerate windows).

param(
    [string[]]$ProcessNames = @('Palworld-Win64-Shipping','Palworld'),
    [int]$MinWidth   = 1280,
    [int]$PollMs     = 250,   # tick interval while mirroring
    [int]$GraceTicks = 8      # consecutive "gone" ticks before teardown (~2s)
)

$LogFile = Join-Path $PSScriptRoot 'mirror-watcher.log'
function Log($m) { Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $m) }
Log "==================== WATCHER STARTED ===================="
Log "ProcessNames=$($ProcessNames -join ',')  MinWidth=$MinWidth  PollMs=$PollMs  GraceTicks=$GraceTicks"
# PID file: lets the watchdog/manager detect us even across elevation boundaries
# (a non-elevated checker can't read an elevated process's command line).
Set-Content -Path (Join-Path $PSScriptRoot 'mirror-watcher.pid') -Value $PID

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms @"
using System; using System.Runtime.InteropServices;
public class DMW {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
    [StructLayout(LayoutKind.Sequential)] public struct PSIZE { public int x,y; }
    [StructLayout(LayoutKind.Sequential)] public struct TP {
        public int f; public RECT d; public RECT s; public byte o; public bool v; public bool c; }
    [DllImport("dwmapi.dll")] public static extern int DwmRegisterThumbnail(IntPtr a,IntPtr b,out IntPtr t);
    [DllImport("dwmapi.dll")] public static extern int DwmUnregisterThumbnail(IntPtr t);
    [DllImport("dwmapi.dll")] public static extern int DwmUpdateThumbnailProperties(IntPtr t,ref TP p);
    [DllImport("dwmapi.dll")] public static extern int DwmQueryThumbnailSourceSize(IntPtr t,out PSIZE s);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h,int i);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h,int i,int v);
    public static void NoActivate(IntPtr h){ int e=GetWindowLong(h,-20); SetWindowLong(h,-20, e|0x08000000|0x80|0x20); }
    public static IntPtr Register(IntPtr dest,IntPtr src){ IntPtr t; if(DwmRegisterThumbnail(dest,src,out t)!=0) return IntPtr.Zero; return t; }
    public static void Fit(IntPtr t,int aw,int ah){
        PSIZE ss; DwmQueryThumbnailSourceSize(t,out ss);
        int dw=aw, dh=ah, dx=0, dy=0;
        if(ss.x>0 && ss.y>0){ double sa=(double)ss.x/ss.y, da=(double)aw/ah;
            if(sa>da){ dw=aw; dh=(int)(aw/sa); dy=(ah-dh)/2; } else { dh=ah; dw=(int)(ah*sa); dx=(aw-dw)/2; } }
        var p=new TP(); p.f=0x1|0x4|0x8|0x10; p.o=255; p.v=true; p.c=true;
        p.d=new RECT{L=dx,T=dy,R=dx+dw,B=dy+dh}; DwmUpdateThumbnailProperties(t,ref p);
    }
    public static void Stop(IntPtr t){ if(t!=IntPtr.Zero) DwmUnregisterThumbnail(t); }
}
"@

# Handoff file: each launch script writes the process name(s) of the app it
# wants mirrored (comma-separated). Lets ONE watcher mirror whichever tile you
# launched (Palworld, Discord, ...). Falls back to the param default.
$TargetFile = Join-Path $PSScriptRoot 'mirror-target.txt'
function Get-Targets {
    if (Test-Path $TargetFile) {
        $line = (Get-Content $TargetFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($line) { $t = $line -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }; if ($t) { return $t } }
    }
    return $ProcessNames
}
function Get-VD { [System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary -and $_.Bounds.Width -ge $MinWidth } | Select-Object -First 1 }
function Get-GameHwnd($targets) {
    foreach ($n in $targets) {
        $p = Get-Process -Name $n -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($p) { return $p.MainWindowHandle }
    }
    return [IntPtr]::Zero
}

# --- ONE persistent form, created once, never disposed --------------------
$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'; $f.ShowInTaskbar = $false
$f.TopMost = $true; $f.BackColor = [System.Drawing.Color]::Black
$f.Bounds = New-Object System.Drawing.Rectangle 0,0,$MinWidth,720
$f.Show(); $f.Hide()
[System.Windows.Forms.Application]::DoEvents()
[DMW]::NoActivate($f.Handle)

# --- mirror state ---------------------------------------------------------
$mirroring = $false      # are we currently showing a copy?
$thumb     = [IntPtr]::Zero
$curHwnd   = [IntPtr]::Zero
$curVD     = $null
$miss      = 0           # consecutive "stream gone" ticks (for debounce)

function Start-Mirror($vd, $gh) {
    $script:f.Bounds = $vd.Bounds
    $script:f.Show(); $script:f.BringToFront()
    [System.Windows.Forms.Application]::DoEvents()
    $script:thumb = [DMW]::Register($script:f.Handle, $gh)
    if ($script:thumb -ne [IntPtr]::Zero) { [DMW]::Fit($script:thumb, $script:f.ClientSize.Width, $script:f.ClientSize.Height) }
    [DMW]::SetForegroundWindow($gh) | Out-Null
    $script:curHwnd = $gh; $script:curVD = $vd; $script:mirroring = $true; $script:miss = 0
    Log ("Mirror active. VD={0} {1}x{2}, game hwnd={3}." -f $vd.DeviceName,$vd.Bounds.Width,$vd.Bounds.Height,$gh)
}
function Stop-Mirror($reason) {
    [DMW]::Stop($script:thumb); $script:thumb = [IntPtr]::Zero
    $script:f.Hide(); [System.Windows.Forms.Application]::DoEvents()
    $script:mirroring = $false; $script:curHwnd = [IntPtr]::Zero; $script:curVD = $null
    Log "Mirror stopped ($reason). Back to waiting."
}

while ($true) {
    try {
        $vd = Get-VD
        $gh = Get-GameHwnd (Get-Targets)
        $present = ($vd -and $gh -ne [IntPtr]::Zero)

        if ($present) {
            $miss = 0
            if (-not $mirroring) {
                # not mirroring yet -> start it once (idempotent)
                Start-Mirror $vd $gh
            } else {
                # already mirroring -> just maintain, never restart
                if ($gh -ne $curHwnd) {
                    # game window was recreated (borderless toggle / reload): re-point the copy
                    [DMW]::Stop($thumb)
                    $thumb = [DMW]::Register($f.Handle, $gh)
                    if ($thumb -ne [IntPtr]::Zero) { [DMW]::Fit($thumb, $f.ClientSize.Width, $f.ClientSize.Height) }
                    $curHwnd = $gh
                    Log ("Re-pointed mirror to new game hwnd={0}." -f $gh)
                }
                if ($curVD -eq $null -or $f.Bounds.Width -ne $vd.Bounds.Width -or $f.Bounds.Height -ne $vd.Bounds.Height -or $f.Bounds.X -ne $vd.Bounds.X -or $f.Bounds.Y -ne $vd.Bounds.Y) {
                    $f.Bounds = $vd.Bounds; $curVD = $vd
                    if ($thumb -ne [IntPtr]::Zero) { [DMW]::Fit($thumb, $f.ClientSize.Width, $f.ClientSize.Height) }
                    Log ("VD changed -> repositioned to {0} {1}x{2}." -f $vd.DeviceName,$vd.Bounds.Width,$vd.Bounds.Height)
                }
                [System.Windows.Forms.Application]::DoEvents()
            }
            Start-Sleep -Milliseconds $PollMs
        } else {
            if ($mirroring) {
                # debounce: only tear down after the stream has been gone a while
                $miss++
                if ($miss -ge $GraceTicks) {
                    Stop-Mirror "stream/game ended"
                } else {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds $PollMs
                }
            } else {
                # idle (no stream): keep pumping the persistent form's message
                # queue so it never wedges between sessions / after abrupt VD loss
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 500
            }
        }
    } catch {
        Log ("ERROR: {0}" -f $_.Exception.Message)
        Start-Sleep -Milliseconds 2000
    }
}
