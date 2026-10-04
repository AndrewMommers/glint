# Builds a release of Glint and, with -Publish, puts it live.
#
#   .\release.cmd -Version 0.9.0-beta.12            # build only (build\web)
#   .\release.cmd -Version 0.9.0-beta.12 -Publish   # build, then deploy server + game to the VPS
#
# Glint is played in the browser, on the website's Play page, which loads the
# game from the VPS. There's no desktop download any more; export.ps1 still
# makes a Windows build for local testing.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Godot = "$env:TEMP\gd462\Godot_v4.6.2-stable_win64.exe",
    [switch]$Publish
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') { throw "Version must look like 0.9.0-beta.1" }
if (-not (Test-Path $Godot)) { throw "Godot not found at $Godot (pass -Godot <path to Godot_v4.6.2-stable_win64.exe>)" }
$beta = Join-Path $root "beta"
$website = (Get-Content (Join-Path $beta "appwrite.json") -Raw | ConvertFrom-Json).website

# 1. Server version + tests (the server checks clients are at least this version).
(Get-Content (Join-Path $root "server\beta.go") -Raw) -replace 'const Version = "[^"]*"', "const Version = `"$Version`"" |
    Set-Content (Join-Path $root "server\beta.go") -NoNewline
Push-Location (Join-Path $root "server")
try { go test ./... | Out-Null; if ($LASTEXITCODE) { throw "server tests failed (run: cd server; go test ./...)" } } finally { Pop-Location }

# 2. Bake the release config into the game and export the browser build.
$cfgPath = Join-Path $root "client\release.cfg"
# Release notes travel inside the build, for the "What's new" dialog after an update.
$notesFile = Join-Path $beta "notes\$Version.md"
$notesEscaped = ""
if (Test-Path $notesFile) {
    $notesEscaped = (Get-Content $notesFile -Raw) -replace "\\", "\\" -replace '"', '\"' -replace "`r", "" -replace "`n", "\n"
}
$cfgText = @"
[release]

version="$Version"
channel="release"
download_url="$website/play/"
notes="$notesEscaped"
"@
# No byte-order mark: Godot's ConfigFile can't see the section after one.
[IO.File]::WriteAllText($cfgPath, $cfgText, (New-Object System.Text.UTF8Encoding $false))
$web = Join-Path $root "build\web"
try {
    Remove-Item $web -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force $web | Out-Null
    Write-Host "Importing and exporting the web build..."
    & $Godot --headless --path (Join-Path $root "client") --import | Out-Null
    # Piping makes PowerShell wait for the (GUI) Godot exe to finish.
    & $Godot --headless --path (Join-Path $root "client") --export-release "Web" (Join-Path $web "index.html") | Out-Null
    if (-not (Test-Path (Join-Path $web "index.wasm"))) { throw "web export failed (are the web export templates installed?)" }
} finally {
    Remove-Item $cfgPath -ErrorAction SilentlyContinue
}
[IO.File]::WriteAllText((Join-Path $beta "VERSION"), $Version)

$mb = [math]::Round(((Get-ChildItem $web | Measure-Object Length -Sum).Sum) / 1MB, 1)
Write-Host ""
Write-Host "Built Glint $Version for the browser: build\web ($mb MB before compression)" -ForegroundColor Green

# 3. Publish: the VPS serves the game; the website's Play page embeds it.
if ($Publish) {
    & (Join-Path $root "deploy\deploy.ps1") -Web -SkipTests
    Write-Host "Live: $website/play/" -ForegroundColor Green
    Write-Host "Commit server\beta.go and beta\VERSION to record the release."
}
