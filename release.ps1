# Builds a closed-beta release of Glint.
#
#   .\release.ps1 -Version 0.9.0-beta.1 -Server yourname.duckdns.org:7777 -Godot C:\path\to\Godot_v4.6.2-stable_win64.exe
#   ... -Publish      uploads it to the website's download bucket (Appwrite Storage) and
#                     pushes website/release.json, which redeploys the site with the new version
#   ... -GitHub       with -Publish, also mirrors it as a pre-release on GitHub (-BetaRepo)
#
# Produces dist\Glint-<version>-windows.zip containing Glint.exe, Glint.pck,
# glint-server.exe (singleplayer) and README.txt. The build has the official
# server address, its pinned TLS certificate and the version baked in.
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$Server,
    [Parameter(Mandatory = $true)][string]$Godot,
    [string]$BetaRepo = "AndrewMommers/glint-beta",
    [switch]$Publish,
    [switch]$GitHub
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
if ($Version -notmatch '^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$') { throw "Version must look like 0.9.0-beta.1" }
if ($Server -notmatch '^[^:\s]+:\d+$') { throw "Server must be host:port, e.g. yourname.duckdns.org:7777" }
$website = (Get-Content (Join-Path $root "betappwrite.json") -Raw | ConvertFrom-Json).website
$downloadUrl = "$website/download/"

# 1. Server binary + TLS certificate (created once, then reused forever).
$beta = Join-Path $root "beta"
$serverExe = Join-Path $beta "glint-server.exe"
$data = Join-Path $beta "server-data"
(Get-Content (Join-Path $root "server\beta.go") -Raw) -replace 'const Version = "[^"]*"', "const Version = `"$Version`"" |
    Set-Content (Join-Path $root "server\beta.go") -NoNewline
Push-Location (Join-Path $root "server")
try { go test ./... | Out-Null; if ($LASTEXITCODE) { throw "server tests failed" }; go build -o $serverExe . } finally { Pop-Location }
& $serverExe gencert $data | Out-Null
$certPem = (Get-Content (Join-Path $data "tls\server.crt") -Raw).Trim()

# 2. Bake the release config into the game and export.
$cfgPath = Join-Path $root "client\release.cfg"
$certEscaped = $certPem -replace "`r", "" -replace "`n", "\n"
@"
[release]

version="$Version"
channel="beta"
server="$Server"
download_url="$downloadUrl"
cert="$certEscaped"
"@ | Set-Content $cfgPath -Encoding utf8
try {
    & (Join-Path $root "export.ps1") -Godot $Godot
} finally {
    Remove-Item $cfgPath -ErrorAction SilentlyContinue
}

# 3. Package.
$name = "Glint-$Version-windows"
$dist = Join-Path $root "dist"
$stage = Join-Path $dist $name
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $root "build\Glint.exe"), (Join-Path $root "build\Glint.pck"), (Join-Path $root "build\glint-server.exe") $stage
(Get-Content (Join-Path $beta "TESTER-README.txt") -Raw) -replace '\{VERSION\}', $Version -replace '\{SERVER\}', $Server |
    Set-Content (Join-Path $stage "README.txt") -Encoding utf8
$zip = Join-Path $dist "$name.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip -CompressionLevel Optimal
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
Set-Content (Join-Path $beta "VERSION") $Version -NoNewline

# Windows installer (Inno Setup, per-user, no admin).
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
$setup = Join-Path $dist "Glint-Setup-$Version.exe"
if ($iscc) {
    & $iscc /Q "/DVersion=$Version" "/DBuildDir=$(Join-Path $root 'build')" "/DReadme=$(Join-Path $stage 'README.txt')" (Join-Path $root "installer\glint.iss")
    if ($LASTEXITCODE) { throw "installer build failed" }
} else {
    Write-Host "Inno Setup not found - skipping the installer (zip only)." -ForegroundColor Yellow
    $setup = $null
}

$notes = Join-Path $dist "notes-$Version.md"
$custom = Join-Path $beta "notes\$Version.md"
$body = if (Test-Path $custom) { Get-Content $custom -Raw } else { "Closed beta build $Version." }
@"
$body

**Install:** download **``Glint-Setup-$Version.exe``** and run it (no admin needed). Prefer no install? Use ``$name.zip``: unzip and run ``Glint.exe``.
You need an invite code to create an account. Also available at $downloadUrl

SHA-256: ``$hash``
"@ | Set-Content $notes -Encoding utf8

Write-Host ""
Write-Host "Built $zip" -ForegroundColor Green
Write-Host "  size   $([math]::Round((Get-Item $zip).Length / 1MB, 1)) MB"
Write-Host "  sha256 $hash"
if ($setup) { Write-Host "Built $setup ($([math]::Round((Get-Item $setup).Length / 1MB, 1)) MB)" -ForegroundColor Green }
Write-Host "  server $Server (TLS, pinned certificate)"
Write-Host "  beta\VERSION = $Version -> restart .\beta\run-server.ps1 so older builds must update"

# 4. Publish.
if ($Publish) {
    if (-not $setup) { throw "publishing needs the installer (install Inno Setup)" }
    # Git's own bash (not WSL) runs the upload script.
    $bash = Join-Path (Split-Path (Split-Path (Get-Command git).Source)) "binash.exe"
    & $bash (Join-Path $root "tools/publish_download.sh") $Version $setup $zip
    if ($LASTEXITCODE) { throw "upload to Appwrite failed" }
    git -C $root add website/release.json
    git -C $root commit -m "Publish Glint $Version downloads" -- website/release.json | Out-Null
    git -C $root push -q
    Write-Host "Published: $downloadUrl (the site updates in about a minute)" -ForegroundColor Green

    if ($GitHub) {
        gh repo view $BetaRepo *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Creating $BetaRepo (builds only, no source)..."
            gh repo create $BetaRepo --public --description "Glint closed beta builds (invite only)" --add-readme | Out-Null
        }
        gh release create "v$Version" $setup $zip --repo $BetaRepo --prerelease --title "Glint $Version (closed beta)" --notes-file $notes
        # No tag on the source repo: tags there only show "Source code" downloads.
        Write-Host "Mirrored: https://github.com/$BetaRepo/releases/tag/v$Version" -ForegroundColor Green
    }
}
