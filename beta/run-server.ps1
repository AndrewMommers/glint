# Runs the UNO Glass closed-beta server on this PC.
#   - TLS with a self-signed certificate (the game pins it; no domain needed)
#   - registration needs an invite code  (see .\beta\invites.ps1)
#   - clients older than beta\VERSION are asked to update
#   - restarts automatically if it ever stops
#
# Usage:  .\beta\run-server.ps1 [-Port 7777]
# Stop with Ctrl+C. Data (accounts, invites, feedback, certificate) lives in beta\server-data.
param([int]$Port = 7777)
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$root = Split-Path $here -Parent
$data = Join-Path $here "server-data"
$exe = Join-Path $here "uno-server.exe"

Write-Host "Building server..."
Push-Location (Join-Path $root "server")
try { go build -o $exe . } finally { Pop-Location }

$minClient = ""
$versionFile = Join-Path $here "VERSION"
if (Test-Path $versionFile) { $minClient = (Get-Content $versionFile -Raw).Trim() }

$serverArgs = @("-addr", ":$Port", "-data", $data, "-tls", "-invite-only")

# Use Appwrite for accounts/friends/feedback when configured (beta\appwrite.json
# + key in beta\server-data\appwrite.key); otherwise a local JSON file.
$awConfig = Join-Path $here "appwrite.json"
$backend = "local file (beta\server-data\accounts.json)"
if ((Test-Path $awConfig) -and ((Test-Path (Join-Path $data "appwrite.key")) -or $env:APPWRITE_API_KEY)) {
    $aw = Get-Content $awConfig -Raw | ConvertFrom-Json
    $serverArgs += @("-appwrite-endpoint", $aw.endpoint, "-appwrite-project", $aw.project, "-appwrite-db", $aw.database)
    $backend = "Appwrite ($($aw.endpoint), project $($aw.project))"
}
if ($minClient) { $serverArgs += @("-min-client", $minClient) }

Write-Host ""
Write-Host "UNO Glass beta server" -ForegroundColor Cyan
Write-Host "  Port:        $Port (TCP)"
Write-Host "  Min client:  $(if ($minClient) { $minClient } else { 'any' })"
Write-Host "  Data:        $data"
Write-Host "  Accounts:    $backend"
Write-Host ""
Write-Host "Testers connect to  <your public IP or DDNS name>:$Port"
Write-Host "You can play on this PC using 127.0.0.1:$Port"
Write-Host "Make sure TCP port $Port is forwarded on your router and allowed in Windows Firewall (see beta\HOSTING.md)."
Write-Host ""

while ($true) {
    & $exe @serverArgs
    Write-Host "Server stopped (exit code $LASTEXITCODE). Restarting in 3 seconds... (Ctrl+C to quit)" -ForegroundColor Yellow
    Start-Sleep -Seconds 3
}
