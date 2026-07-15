# build-setup.ps1 — builds a single self-contained installer executable.
#
# Output:  dist\Apollo-Mirror-Manager-Setup.exe
#
# The .exe embeds every script in this repo. When a user runs it, it extracts
# the scripts to a temp folder and runs the normal installer — so a beginner
# can download ONE file and double-click it (no ZIP, no "Unblock", no
# right-click "Run with PowerShell").
#
# Requirements to BUILD (not to run the output):
#   Install-Module ps2exe -Scope CurrentUser
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build\build-setup.ps1

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$dist = Join-Path $repo 'dist'
$null = New-Item -ItemType Directory -Force -Path $dist

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    throw "ps2exe is not installed. Run:  Install-Module ps2exe -Scope CurrentUser -Force"
}
Import-Module ps2exe -ErrorAction Stop

# ---- files to embed (repo-relative paths) ----
$files = @()
$files += 'install.ps1'
$files += 'uninstall.ps1'
Get-ChildItem (Join-Path $repo 'scripts') -File | ForEach-Object {
    $files += "scripts\$($_.Name)"
}

Write-Host "Embedding $($files.Count) files..."
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('$Payload = @{')
foreach ($rel in $files) {
    $full = Join-Path $repo $rel
    if (-not (Test-Path $full)) { throw "Missing file: $full" }
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($full))
    [void]$sb.AppendLine(("  '{0}' = '{1}'" -f ($rel -replace "'","''"), $b64))
}
[void]$sb.AppendLine('}')
$payload = $sb.ToString()

# ---- the bootstrap logic that runs on the user's machine ----
$bootstrap = @'
$ErrorActionPreference = 'Stop'
Write-Host ''
Write-Host '  =========================================================='
Write-Host '     Apollo Mirror Manager - Setup'
Write-Host '  =========================================================='
Write-Host ''
Write-Host '  Extracting files...'

$work = Join-Path $env:TEMP 'ApolloMirrorSetup'
if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
$null = New-Item -ItemType Directory -Force -Path $work

foreach ($rel in $Payload.Keys) {
    $target = Join-Path $work $rel
    $dir = Split-Path $target -Parent
    if (-not (Test-Path $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
    [IO.File]::WriteAllBytes($target, [Convert]::FromBase64String($Payload[$rel]))
}

# Files we just wrote are local (no Mark of the Web), but be safe:
Get-ChildItem $work -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

Write-Host '  Running the installer...'
Write-Host ''
& (Join-Path $work 'install.ps1')

# Make sure the installed copy is unblocked too.
$dest = Join-Path $env:LOCALAPPDATA 'ApolloScripts'
if (Test-Path $dest) { Get-ChildItem $dest -Recurse -File | Unblock-File -ErrorAction SilentlyContinue }

Write-Host ''
Write-Host '  =========================================================='
Write-Host '   Done! Look for "Apollo Mirror Manager" on your Desktop.'
Write-Host '  =========================================================='
Write-Host ''
Write-Host '  Press any key to close this window...'
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
'@

$installerPs1 = Join-Path $dist '_setup-source.ps1'
Set-Content -LiteralPath $installerPs1 -Value ($payload + "`r`n" + $bootstrap) -Encoding UTF8

$exe = Join-Path $dist 'Apollo-Mirror-Manager-Setup.exe'
Write-Host "Compiling $exe ..."
Invoke-ps2exe -inputFile $installerPs1 -outputFile $exe `
    -title 'Apollo Mirror Manager Setup' `
    -description 'Installs Apollo Mirror Manager (game mirroring for Apollo/Moonlight)' `
    -company 'aguirretim' `
    -product 'Apollo Mirror Manager' `
    -copyright 'MIT License' `
    -version '1.0.2' `
    -requireAdmin $false `
    -noConfigFile

Remove-Item $installerPs1 -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "Built: $exe" -ForegroundColor Green
(Get-Item $exe) | Select-Object Name, @{n='SizeKB';e={[math]::Round($_.Length/1KB)}}
