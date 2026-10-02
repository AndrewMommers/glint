# Builds the Go game server into the Godot project so the client can launch it.
$ErrorActionPreference = "Stop"
Push-Location "$PSScriptRoot\server"
try {
    go test ./...
    go build -o ..\client\bin\uno-server.exe .
    Write-Host "Built client\bin\uno-server.exe"
} finally {
    Pop-Location
}
