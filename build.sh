#!/usr/bin/env sh
# Builds the Go game server into the Godot project so the client can launch it.
set -e
cd "$(dirname "$0")/server"
go test ./...
go build -o ../client/bin/uno-server .
echo "Built client/bin/uno-server"
