# Builds a standalone game into .\build:
#   build\UNO.exe          - the game (double-click to play)
#   build\UNO.pck          - game data
#   build\uno-server.exe   - Go server, started automatically for singleplayer / hosting
#
# Usage:  .\export.ps1 -Godot "C:\path\to\Godot_v4.6.2-stable_win64.exe"
#
# If Godot export templates are installed (Editor > Manage Export Templates),
# this does a proper release export. Otherwise it exports just the game pack
# and uses the Godot binary itself as the runtime (a Godot exe automatically
# runs a .pck with the same name next to it).
param([Parameter(Mandatory = $true)][string]$Godot)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$build = Join-Path $root "build"
New-Item -ItemType Directory -Force $build | Out-Null

Write-Host "Building server..."
Push-Location (Join-Path $root "server")
try { go build -o (Join-Path $build "uno-server.exe") . } finally { Pop-Location }

$client = Join-Path $root "client"
$version = (& $Godot --version 2>$null | Select-Object -First 1)
$templates = Join-Path $env:APPDATA "Godot\export_templates"
$hasTemplates = (Test-Path $templates) -and (Get-ChildItem $templates -Directory -ErrorAction SilentlyContinue)

Write-Host "Importing project ($version)..."
& $Godot --headless --path $client --import | Out-Null

if ($hasTemplates) {
    Write-Host "Exporting release build..."
    & $Godot --headless --path $client --export-release "Windows Desktop" (Join-Path $build "UNO.exe") | Out-Null
} else {
    Write-Host "No export templates found - exporting game pack and using the Godot runtime..."
    & $Godot --headless --path $client --export-pack "Windows Desktop" (Join-Path $build "UNO.pck") | Out-Null
    Copy-Item $Godot (Join-Path $build "UNO.exe") -Force
}

if (-not (Test-Path (Join-Path $build "UNO.pck"))) { throw "Export failed: build\UNO.pck was not created" }
Write-Host ""
Write-Host "Done. Play with: build\UNO.exe"
