# Manage closed-beta invite codes (works while the server is running).
#
#   .\beta\invites.ps1 create -n 5 -note "Discord friends"   # make 5 single-use codes
#   .\beta\invites.ps1 list                                  # who used which code
#   .\beta\invites.ps1 revoke UNO-ABCD-EFGH                  # revoke a code (and its account)
#   .\beta\invites.ps1 revoke SomeUsername                   # same, by username
$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$exe = Join-Path $here "uno-server.exe"
if (-not (Test-Path $exe)) {
    Push-Location (Join-Path (Split-Path $here -Parent) "server")
    try { go build -o $exe . } finally { Pop-Location }
}
if ($args.Count -eq 0) { $cmd = @("list") } else { $cmd = @($args[0]) }
$rest = @()
if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
& $exe invites @cmd -data (Join-Path $here "server-data") @rest
