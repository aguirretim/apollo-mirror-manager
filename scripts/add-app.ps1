# add-app.ps1 â€” register a NEW Apollo tile with the full "Palworld treatment"
# in one command: virtual display + mirror + idempotent launch + (by default)
# close-on-quit, wired to the generic launch-app.ps1 / close-app.ps1.
#
# Examples:
#   # A Steam game (auto-downloads its Steam cover art):
#   .\add-app.ps1 -Name "Lethal Company" -ProcessNames "Lethal Company" -SteamAppId 1966720
#
#   # A Steam game with a known process exe name different from the title:
#   .\add-app.ps1 -Name "Deep Rock" -ProcessNames "FSD-Win64-Shipping" -SteamAppId 548430
#
#   # A non-Steam .exe app that should stay running on quit (like Discord):
#   .\add-app.ps1 -Name "OBS" -ProcessNames "obs64" -LaunchCmd "C:\Program Files\obs-studio\bin\64bit\obs64.exe" -NoCloseOnQuit
#
# After it runs, restart Apollo to load:  Restart-Service ApolloService -Force

param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$ProcessNames,   # comma-separated, no .exe
    [int]$SteamAppId    = 0,                              # if set: launch via steam:// + grab cover
    [string]$LaunchCmd  = '',                             # OR a URI / .exe path
    [string]$LaunchArgs = '',
    [switch]$NoCloseOnQuit,                               # omit marker + prep-cmd (always-on app)
    [string]$ImagePath  = '',                             # optional explicit cover .png
    [string]$AppsJson   = 'C:\Program Files\Apollo\config\apps.json',
    [string]$ScriptRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
$safe = ($Name -replace '[^\w.-]','_')
$ps   = 'powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'

# --- resolve launch command -------------------------------------------------
if (-not $LaunchCmd -and $SteamAppId -gt 0) { $LaunchCmd = "steam://rungameid/$SteamAppId" }
if (-not $LaunchCmd) { throw "Provide -LaunchCmd or -SteamAppId so the app can be launched." }

# --- cover art --------------------------------------------------------------
if (-not $ImagePath -and $SteamAppId -gt 0) {
    $coversDir = Join-Path $ScriptRoot 'covers'
    New-Item -ItemType Directory -Force -Path $coversDir | Out-Null
    $jpg = Join-Path $coversDir "$safe.jpg"; $png = Join-Path $coversDir "$safe.png"
    $urls = @(
        "https://steamcdn-a.akamaihd.net/steam/apps/$SteamAppId/library_600x900_2x.jpg",
        "https://steamcdn-a.akamaihd.net/steam/apps/$SteamAppId/library_600x900.jpg",
        "https://cdn.cloudflare.steamstatic.com/steam/apps/$SteamAppId/library_600x900.jpg"
    )
    foreach ($u in $urls) {
        try {
            Invoke-WebRequest -Uri $u -OutFile $jpg -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            Add-Type -AssemblyName System.Drawing
            $img = [System.Drawing.Image]::FromFile($jpg); $img.Save($png, [System.Drawing.Imaging.ImageFormat]::Png); $img.Dispose()
            Remove-Item $jpg -ErrorAction SilentlyContinue
            $ImagePath = $png; Write-Host "Cover downloaded -> $png"; break
        } catch { Write-Host "cover try failed: $u" }
    }
}

# --- build the tile's commands ----------------------------------------------
$launchScript = Join-Path $ScriptRoot 'launch-app.ps1'
$closeScript  = Join-Path $ScriptRoot 'close-app.ps1'
$detached = "$ps `"$launchScript`" -Name `"$Name`" -ProcessNames `"$ProcessNames`" -LaunchCmd `"$LaunchCmd`""
if ($LaunchArgs)      { $detached += " -LaunchArgs `"$LaunchArgs`"" }
if (-not $NoCloseOnQuit) { $detached += " -CloseOnQuit" }

$app = [ordered]@{ name = $Name }
if ($ImagePath) { $app['image-path'] = $ImagePath }
$app['detached'] = @($detached)
if (-not $NoCloseOnQuit) {
    $undo = "$ps `"$closeScript`" -Name `"$Name`" -ProcessNames `"$ProcessNames`""
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
Write-Host "Added '$Name' to apps.json (close-on-quit = $(-not $NoCloseOnQuit), virtual-display = on)."
Write-Host "Now run:  Restart-Service ApolloService -Force"

