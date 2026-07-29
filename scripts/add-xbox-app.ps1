# add-xbox-app.ps1 - register an Xbox / Game Pass / Microsoft Store app as an
# Apollo tile, with the same treatment Steam games get (virtual display + mirror
# + idempotent launch + optional close-on-quit).
#
# Why this is separate from add-app.ps1:
#   * Store apps are NOT launchable by exe path - they launch through the shell
#     via their AUMID:  explorer.exe shell:appsFolder\<AUMID>
#   * "C:\Program Files\WindowsApps" is ACL-locked even for administrators, so
#     the exe-scoring trick add-app.ps1 uses for Steam games cannot work here.
#   * Packaged apps report Process.MainWindowHandle == 0, so the mirror watcher
#     has to find their window by PACKAGE IDENTITY instead of by process name.
#     These tiles therefore pass -Aumid (not -ProcessNames) to launch-app.ps1.
#
# Examples:
#   .\add-xbox-app.ps1 -List
#   .\add-xbox-app.ps1 -Name "Hi-Fi RUSH"
#   .\add-xbox-app.ps1 -Aumid "Microsoft.Maine_8wekyb3d8bbwe!AppGroundedShipping"
#   .\add-xbox-app.ps1 -Name "Xbox" -NoCloseOnQuit
#
# After it runs:  Restart-Service ApolloService -Force

param(
    [switch]$List,                                        # just show what is installed
    [switch]$AsObject,                                    # with -List: emit objects, not a table
                                                          # (the GUI needs data, not formatting)
    [string]$Name       = '',                             # friendly name (from -List)
    [string]$Aumid      = '',                             # or the AUMID directly
    [switch]$NoCloseOnQuit,
    [switch]$IncludeAllStoreApps,                         # -List: don't filter to games
    [string]$ImagePath  = '',                             # optional explicit cover .png
    [string]$AppsJson   = 'C:\Program Files\Apollo\config\apps.json',
    [string]$ScriptRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# --------------------------------------------------------------------------
# Shell thumbnail extraction. Store apps ship their own tile artwork, but the
# asset files live under the locked WindowsApps tree - the shell will hand us a
# rendered image for a "shell:appsFolder\<AUMID>" item without needing any of
# those permissions.
# --------------------------------------------------------------------------
Add-Type -ReferencedAssemblies System.Drawing @"
using System;
using System.Drawing;
using System.Runtime.InteropServices;
public class ShellArt {
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory { void GetImage(SIZE size, int flags, out IntPtr phbm); }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; public SIZE(int x,int y){cx=x;cy=y;} }
    [DllImport("shell32.dll", CharSet=CharSet.Unicode, PreserveSig=false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr bc,
        [MarshalAs(UnmanagedType.LPStruct)] Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);

    // SIIGBF_BIGGERSIZEOK(0x01) only. Deliberately NOT SIIGBF_ICONONLY(0x04):
    // without it the shell hands back the app's TILE artwork where one exists,
    // which is far better cover material than a small padded icon.
    public static Bitmap Get(string aumid, int size) {
        IShellItemImageFactory f;
        SHCreateItemFromParsingName(@"shell:appsFolder\" + aumid, IntPtr.Zero,
            new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), out f);
        IntPtr hbm = IntPtr.Zero;
        Bitmap raw = null;
        try {
            f.GetImage(new SIZE(size, size), 0x01, out hbm);
            if (hbm == IntPtr.Zero) return null;
            raw = Bitmap.FromHbitmap(hbm);
            Bitmap copy = raw.Clone(new Rectangle(0, 0, raw.Width, raw.Height),
                                    System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            return Trim(copy);
        } catch { return null; }
        finally {
            if (raw != null) raw.Dispose();
            if (hbm != IntPtr.Zero) DeleteObject(hbm);
            if (f != null) Marshal.ReleaseComObject(f);
        }
    }

    // The shell centres small icons on a large uniform canvas. Strip that border
    // so the real artwork fills the cover instead of floating in a grey box.
    static Bitmap Trim(Bitmap b) {
        Color bg = b.GetPixel(0, 0);
        Func<Color,bool> same = c =>
            Math.Abs(c.R-bg.R) <= 8 && Math.Abs(c.G-bg.G) <= 8 && Math.Abs(c.B-bg.B) <= 8 && c.A == bg.A;
        int x0 = 0, y0 = 0, x1 = b.Width - 1, y1 = b.Height - 1;
        bool blank;
        while (x0 < x1) { blank = true; for (int y=y0;y<=y1;y++) if(!same(b.GetPixel(x0,y))){blank=false;break;} if(!blank)break; x0++; }
        while (x1 > x0) { blank = true; for (int y=y0;y<=y1;y++) if(!same(b.GetPixel(x1,y))){blank=false;break;} if(!blank)break; x1--; }
        while (y0 < y1) { blank = true; for (int x=x0;x<=x1;x++) if(!same(b.GetPixel(x,y0))){blank=false;break;} if(!blank)break; y0++; }
        while (y1 > y0) { blank = true; for (int x=x0;x<=x1;x++) if(!same(b.GetPixel(x,y1))){blank=false;break;} if(!blank)break; y1--; }
        int w = x1-x0+1, h = y1-y0+1;
        if (w < 16 || h < 16 || (w == b.Width && h == b.Height)) return b;   // nothing to trim
        Bitmap t = b.Clone(new Rectangle(x0, y0, w, h), b.PixelFormat);
        b.Dispose();
        return t;
    }
}
"@

function New-CoverPng {
    param([string]$Aumid, [string]$Title, [string]$OutFile)
    # 600x900 portrait to match the Steam covers already in use.
    $W = 600; $H = 900
    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = 'AntiAlias'
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    # dark gradient backdrop (same look as the generated Steam fallback tiles)
    $rect = New-Object System.Drawing.Rectangle 0,0,$W,$H
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect,
        [System.Drawing.Color]::FromArgb(255,26,30,38),
        [System.Drawing.Color]::FromArgb(255,12,14,18), 90.0)
    $g.FillRectangle($brush, $rect)

    # NOTE ON ARTWORK QUALITY: the real tile assets live under
    # C:\Program Files\WindowsApps, which is ACL-locked even for administrators,
    # so they cannot be read. The shell will only hand back a small icon
    # (~40x40 for most Game Pass titles). Blowing that up to cover size looks
    # broken, so the icon is used as a BADGE and the tile is driven by type
    # instead - that reads as deliberate at a glance on the handheld.
    $icon = $null
    try { $icon = [ShellArt]::Get($Aumid, 256) } catch { }
    if ($icon) {
        $scale = [Math]::Min(3.0, 150.0 / [Math]::Max($icon.Width, $icon.Height))
        $iw = [int]($icon.Width * $scale); $ih = [int]($icon.Height * $scale)
        $g.InterpolationMode = 'NearestNeighbor'   # keep small pixel art crisp
        $g.DrawImage($icon, [int](($W - $iw)/2), 150, $iw, $ih)
        $g.InterpolationMode = 'HighQualityBicubic'
        $icon.Dispose()
    }

    # Title: the main visual. Shrink to fit so long names stay on the tile.
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'; $sf.Trimming = 'EllipsisWord'
    $tr = New-Object System.Drawing.RectangleF 40, 360, ($W - 80), 330
    $size = 62
    while ($size -gt 22) {
        $font = New-Object System.Drawing.Font('Segoe UI', $size, [System.Drawing.FontStyle]::Bold)
        $m = $g.MeasureString($Title, $font, [int]($W - 80))
        if ($m.Height -le 300) { break }
        $font.Dispose(); $size -= 4
    }
    $g.DrawString($Title, $font, [System.Drawing.Brushes]::White, $tr, $sf)
    $font.Dispose()

    # "GAME PASS" wordmark + green accent so these read differently from Steam tiles
    $small = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
    $green = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,107,201,62))
    $lr = New-Object System.Drawing.RectangleF 40, ($H - 150), ($W - 80), 40
    $g.DrawString('XBOX / GAME PASS', $small, $green, $lr, $sf)
    $small.Dispose()
    $accent = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255,16,124,16))
    $g.FillRectangle($accent, 0, $H - 14, $W, 14)

    $g.Dispose()
    $bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return $OutFile
}

# --------------------------------------------------------------------------
# Enumerate installed packaged apps. Get-StartApps is the reliable source: it
# returns launchable AUMIDs and real display names, and unlike the Appx manifest
# APIs it is not blocked by the WindowsApps ACLs.
# --------------------------------------------------------------------------
function Get-PackagedApps {
    param([switch]$All)
    # A real package family name is "<Name>_<13-char publisher id>". Filtering on
    # that shape drops the pseudo-AUMIDs Office registers (e.g. "zn=BV5!!!!...").
    $start = Get-StartApps | Where-Object { $_.AppID -match '^[A-Za-z0-9._+-]+_[a-z0-9]{13}![^!]+$' }

    # Publisher/vendor packages that are never a game tile. Game Pass titles often
    # have OBFUSCATED family names (Forza Horizon 5 = Microsoft.624F8B84B80), so
    # family-name filtering alone is not enough - the display-name list below does
    # the rest of the work.
    $noiseFamily = 'Microsoft\.(Windows|VCLibs|NET|UI|Services|Advertising|Store|Desktop|MicrosoftEdge|' +
             'MSPaint|ScreenSketch|Photos|People|Zune|Bing|Get|Office|Skype|Mixed|Sway|Todos|' +
             'Whiteboard|PowerAutomate|OneNote|Outlook|Teams|LinkedIn|Clipchamp|StickyNotes|' +
             'SecHealth|Notepad|Terminal|QuickAssist|Family|YourPhone|Copilot|Wallet|' +
             'Winget|Print3D|CrossDevice|WebpImage|HEIF|HEVC|RawImage|VP9|AV1|Microsoft3DViewer|' +
             'MicrosoftOfficeHub|XboxGamingOverlay|XboxSpeechToTextOverlay|XboxGameOverlay|' +
             'XboxGameCallableUI|XboxIdentityProvider|Xbox\.TCUI|GamingServices)|' +
             'WinAppRuntime|PythonSoftwareFoundation|RealtekSemiconductor|AdvancedMicroDevices|' +
             'NVIDIACorp|AppUp\.|A-Volute|DolbyLaboratories|DTSInc|AD2F1837|ASUSAmbient|' +
             'B9ECED6F\.ArmouryCrate|57540AMZNMobileLLC|MSTeams|^Claude_|windows\.immersivecontrolpanel|' +
             'MicrosoftWindows\.(Client|CrossDevice)'

    # Display names of system utilities that survive the family filter.
    $noiseName = '^(Settings|Cortana|Game Bar|Windows Backup|3D Viewer|Paint 3D|Sticky Notes|' +
                 'Microsoft 365.*|Office 20.*|Xbox Console Companion|Xbox Insider Hub|' +
                 'Xbox One SmartGlass|Mixed Reality Portal|Feedback Hub|Phone Link|Windows Security)$'

    foreach ($s in $start) {
        $fam = ($s.AppID -split '!')[0]
        if (-not $All) {
            if ($fam -match $noiseFamily)   { continue }
            if ($s.Name -match $noiseName)  { continue }
        }
        [pscustomobject]@{
            Name   = $s.Name
            Aumid  = $s.AppID
            Family = $fam
        }
    }
}

# --------------------------------------------------------------------------
if ($List) {
    $apps = @(Get-PackagedApps -All:$IncludeAllStoreApps)
    if (-not $apps) { if (-not $AsObject) { Write-Host "No packaged apps found." }; return }
    $existing = @()
    if (Test-Path $AppsJson) {
        try { $existing = (Get-Content $AppsJson -Raw | ConvertFrom-Json).apps.name } catch { }
    }
    $rows = $apps | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Added = if ($existing -contains $_.Name) { 'yes' } else { '' }
            Name  = $_.Name
            Aumid = $_.Aumid
        }
    }
    # Format-Table would emit formatting records, which are useless to a caller
    # that wants the data (the GUI). Only format for human/CLI use.
    if ($AsObject) { $rows } else { $rows | Format-Table -AutoSize }
    return
}

# --- resolve which app to add ----------------------------------------------
if (-not $Aumid) {
    if (-not $Name) { throw "Give -Name (see -List) or -Aumid, or use -List to see what is installed." }
    $hits = @(Get-PackagedApps -All | Where-Object { $_.Name -eq $Name })
    if (-not $hits) { $hits = @(Get-PackagedApps -All | Where-Object { $_.Name -like "*$Name*" }) }
    if (-not $hits)          { throw "No installed packaged app matches '$Name'. Run -List to see the options." }
    if ($hits.Count -gt 1)   { throw "'$Name' is ambiguous - matches: $($hits.Name -join ', '). Use -Aumid." }
    $Aumid = $hits[0].Aumid
    $Name  = $hits[0].Name
}
if (-not $Name) {
    $match = Get-PackagedApps -All | Where-Object { $_.Aumid -eq $Aumid } | Select-Object -First 1
    $Name  = if ($match) { $match.Name } else { ($Aumid -split '!')[0] }
}

$safe = ($Name -replace '[^\w.-]','_')
$ps   = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'

# --- cover art --------------------------------------------------------------
if (-not $ImagePath) {
    $coversDir = Join-Path $ScriptRoot 'covers'
    New-Item -ItemType Directory -Force -Path $coversDir | Out-Null
    $png = Join-Path $coversDir "$safe.png"
    try   { $ImagePath = New-CoverPng -Aumid $Aumid -Title $Name -OutFile $png; Write-Host "Cover generated -> $png" }
    catch { Write-Warning "Could not build cover art: $($_.Exception.Message)" }
}

# --- build the tile's commands ---------------------------------------------
$launchScript = Join-Path $ScriptRoot 'launch-app.ps1'
$closeScript  = Join-Path $ScriptRoot 'close-app.ps1'
$detached = "$ps `"$launchScript`" -Name `"$Name`" -Aumid `"$Aumid`""
if (-not $NoCloseOnQuit) { $detached += " -CloseOnQuit" }

$app = [ordered]@{ name = $Name }
if ($ImagePath) { $app['image-path'] = $ImagePath }
$app['detached'] = @($detached)
if (-not $NoCloseOnQuit) {
    $undo = "$ps `"$closeScript`" -Name `"$Name`" -Aumid `"$Aumid`""
    $app['prep-cmd'] = @( [ordered]@{ do = ''; elevated = $false; undo = $undo } )
}
$app['uuid'] = ([guid]::NewGuid()).ToString().ToUpper()
$app['virtual-display'] = $true

# --- splice into apps.json (backup + validate) ------------------------------
Copy-Item $AppsJson ("$AppsJson.bak-" + (Get-Date).ToString('yyyyMMdd-HHmmss'))
$j = Get-Content $AppsJson -Raw | ConvertFrom-Json
if ($j.apps.name -contains $Name) { throw "An app named '$Name' already exists in apps.json. Remove it first or pick a new name." }
$j.apps = @($j.apps) + (New-Object psobject -Property $app)
$j | ConvertTo-Json -Depth 12 | Set-Content $AppsJson -Encoding utf8
$null = Get-Content $AppsJson -Raw | ConvertFrom-Json   # validate

Write-Host "Added '$Name' (Xbox/Store) to apps.json."
Write-Host "  AUMID          : $Aumid"
Write-Host "  close-on-quit  : $(-not $NoCloseOnQuit)"
Write-Host "  window matching: by package identity (exe name not required)"
Write-Host "Now run:  Restart-Service ApolloService -Force"
