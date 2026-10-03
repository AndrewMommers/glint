# One-time Appwrite setup: creates the "uno" database with the players and
# feedback tables (server-only access). Safe to re-run.
#
# Before running, put your Appwrite API key (Console -> Overview -> API keys)
# in beta\server-data\appwrite.key  (that folder is ignored by git).
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$exe = Join-Path $here "uno-server.exe"
Push-Location (Join-Path (Split-Path $here -Parent) "server")
try { go build -o $exe . } finally { Pop-Location }
$data = Join-Path $here "server-data"
New-Item -ItemType Directory -Force $data | Out-Null
if (-not (Test-Path (Join-Path $data "appwrite.key")) -and -not $env:APPWRITE_API_KEY) {
    Write-Host "Missing API key. Create one in the Appwrite console and save it to:" -ForegroundColor Yellow
    Write-Host "  $(Join-Path $data 'appwrite.key')"
    exit 1
}
& $exe appwrite-setup -config (Join-Path $here "appwrite.json") -data $data
