# Deploys the Glint server to a Linux VPS (Ubuntu 24.04, e.g. Vultr) over SSH.
#
#   .\deploy\deploy.cmd -Server 203.0.113.10 -FirstTime   # new VPS: harden it, install, upload data
#   .\deploy\deploy.cmd                                   # later: upload a new server build and restart
#   .\deploy\deploy.cmd -SyncData                         # also re-upload the certificate, keys and invites
#
# The first run saves the address in beta\vps.json, so later runs don't need -Server.
# Uses the Windows OpenSSH client; set up an SSH key first (see deploy\VPS.md).
param(
    [string]$Server,
    [string]$User = "root",
    [switch]$FirstTime,
    [switch]$SyncData,
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$beta = Join-Path $root "beta"
$data = Join-Path $beta "server-data"
$vpsFile = Join-Path $beta "vps.json"

if (-not $Server) {
    if (-not (Test-Path $vpsFile)) { throw "Pass -Server <VPS IP> the first time." }
    $saved = Get-Content $vpsFile -Raw | ConvertFrom-Json
    $Server = $saved.host
    if (-not $PSBoundParameters.ContainsKey("User")) { $User = $saved.user }
}
$target = "$User@$Server"
$sshOpts = @("-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15")

function Invoke-Remote([string]$script) {
    # Pipe the script to bash so quoting stays simple; strip Windows line endings.
    ($script -replace "`r", "") | ssh @sshOpts $target "bash -s"
    if ($LASTEXITCODE) { throw "remote command failed (exit $LASTEXITCODE)" }
}

# 1. Build a static Linux binary.
Push-Location (Join-Path $root "server")
try {
    if (-not $SkipTests) {
        Write-Host "Running server tests..."
        go test ./... | Out-Null
        if ($LASTEXITCODE) { throw "server tests failed (run: cd server; go test ./...)" }
    }
    Write-Host "Building linux/amd64 server..."
    $env:GOOS = "linux"; $env:GOARCH = "amd64"; $env:CGO_ENABLED = "0"
    go build -trimpath -ldflags "-s -w" -o (Join-Path $root "build\glint-server-linux") .
    if ($LASTEXITCODE) { throw "build failed" }
} finally {
    Remove-Item Env:GOOS, Env:GOARCH, Env:CGO_ENABLED -ErrorAction SilentlyContinue
    Pop-Location
}

# 2. Stage the upload.
$stage = Join-Path $env:TEMP "glint-deploy"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item (Join-Path $root "build\glint-server-linux") (Join-Path $stage "glint-server")
foreach ($f in "glint.service", "setup-vps.sh") {
    $text = (Get-Content (Join-Path $PSScriptRoot $f) -Raw) -replace "`r", ""
    [IO.File]::WriteAllText((Join-Path $stage $f), $text)
}

$flags = @()
$aw = Join-Path $beta "appwrite.json"
if ((Test-Path $aw) -and (Test-Path (Join-Path $data "appwrite.key"))) {
    $cfg = Get-Content $aw -Raw | ConvertFrom-Json
    $flags += "-appwrite-endpoint $($cfg.endpoint) -appwrite-project $($cfg.project) -appwrite-db $($cfg.database)"
}
$versionFile = Join-Path $beta "VERSION"
if (Test-Path $versionFile) { $flags += "-min-client $((Get-Content $versionFile -Raw).Trim())" }
[IO.File]::WriteAllText((Join-Path $stage "glint.env"), "GLINT_FLAGS=$($flags -join ' ')`n")

$uploadData = $FirstTime -or $SyncData
if ($uploadData) {
    $cert = Join-Path $data "tls\server.crt"
    if (-not (Test-Path $cert)) { throw "No certificate in beta\server-data\tls. Run a release (or glint-server gencert) first." }
    $sd = New-Item -ItemType Directory -Force (Join-Path $stage "data")
    # Same certificate as the game builds pin, or players can't connect.
    Copy-Item (Join-Path $data "tls\server.crt"), (Join-Path $data "tls\server.key") $sd
    foreach ($f in "appwrite.key", "invites.json") {
        if (Test-Path (Join-Path $data $f)) { Copy-Item (Join-Path $data $f) $sd }
    }
}

# 3. Upload.
Write-Host "Uploading to $target..."
ssh @sshOpts $target "rm -rf /tmp/glint-deploy"
scp @sshOpts -r -q $stage "${target}:/tmp/glint-deploy"
if ($LASTEXITCODE) { throw "upload failed" }

# 4. First time: harden the box and install the service.
if ($FirstTime) {
    Write-Host "Setting up the VPS (updates, firewall, service user)... this takes a few minutes."
    Invoke-Remote "bash /tmp/glint-deploy/setup-vps.sh"
}

# 5. Install and restart.
Invoke-Remote @'
set -e
cd /tmp/glint-deploy
install -o root -g root -m 755 glint-server /opt/glint/glint-server
install -o root -g glint -m 640 glint.env /opt/glint/glint.env
install -m 644 glint.service /etc/systemd/system/glint.service
if [ -d data ]; then
  install -o glint -g glint -m 600 data/server.crt data/server.key /opt/glint/data/tls/
  for f in appwrite.key invites.json; do
    [ -f data/$f ] && install -o glint -g glint -m 600 data/$f /opt/glint/data/
  done
  echo "data uploaded"
fi
rm -rf /tmp/glint-deploy
systemctl daemon-reload
systemctl restart glint
sleep 2
systemctl is-active glint
journalctl -u glint -n 8 --no-pager -o cat
'@

# 6. Check it's reachable from here.
$tcp = New-Object Net.Sockets.TcpClient
try {
    $tcp.ConnectAsync($Server, 7777).Wait(5000) | Out-Null
    if ($tcp.Connected) { Write-Host "Port 7777 is reachable." -ForegroundColor Green }
    else { Write-Host "Port 7777 didn't answer. Check the Vultr firewall group allows TCP 7777." -ForegroundColor Yellow }
} finally { $tcp.Dispose() }

@{ host = $Server; user = $User } | ConvertTo-Json | Set-Content $vpsFile -Encoding utf8
Write-Host ""
Write-Host "Deployed. Players connect to $($Server):7777" -ForegroundColor Green
Write-Host "Build a release that points at it:  .\release.cmd -Version <x> -Server $($Server):7777 -Godot <path> -Publish"
