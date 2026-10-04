# Day-to-day commands for the Glint server on the VPS (address from beta\vps.json).
#
#   .\deploy\server.cmd status                       # is it running, who's online
#   .\deploy\server.cmd logs                         # follow the log (Ctrl+C to stop)
#   .\deploy\server.cmd restart
#   .\deploy\server.cmd invites create -n 5 -note "Sam"
#   .\deploy\server.cmd invites list
#   .\deploy\server.cmd invites revoke GLINT-XXXX-XXXX
#   .\deploy\server.cmd ssh                          # open a shell on the server
param(
    [Parameter(Mandatory = $true, Position = 0)][ValidateSet("status", "logs", "restart", "invites", "ssh")][string]$Command,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = "Stop"
$vpsFile = Join-Path (Split-Path $PSScriptRoot -Parent) "beta\vps.json"
if (-not (Test-Path $vpsFile)) { throw "No VPS yet. Run .\deploy\deploy.cmd -Server <IP> -FirstTime first." }
$vps = Get-Content $vpsFile -Raw | ConvertFrom-Json
$target = "$($vps.user)@$($vps.host)"
$sshOpts = @("-o", "StrictHostKeyChecking=accept-new")

switch ($Command) {
    "status" { ssh @sshOpts $target "systemctl status glint --no-pager -n 15" }
    "logs" { ssh @sshOpts -t $target "journalctl -u glint -f -n 50 -o short-iso" }
    "restart" { ssh @sshOpts $target "systemctl restart glint && sleep 1 && systemctl is-active glint" }
    "ssh" { ssh @sshOpts $target }
    "invites" {
        # Runs as the service user so the server can still update the file.
        if (-not $Rest -or $Rest[0] -notin "create", "list", "revoke") { throw "usage: server.cmd invites create|list|revoke ..." }
        $quoted = ($Rest | Select-Object -Skip 1 | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join " "
        # -data must come before positional arguments (Go flag parsing).
        ssh @sshOpts $target "sudo -u glint /opt/glint/glint-server invites $($Rest[0]) -data /opt/glint/data $quoted"
    }
}
