# Shows tester feedback collected by the beta server.
#   .\beta\feedback.ps1            # latest 20
#   .\beta\feedback.ps1 -Last 50
#   .\beta\feedback.ps1 -Log       # include attached game logs
param([int]$Last = 20, [switch]$Log)
$file = Join-Path $PSScriptRoot "server-data\feedback.jsonl"
if (-not (Test-Path $file)) { Write-Host "No feedback yet."; return }
$entries = Get-Content $file -Encoding UTF8 | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }
Write-Host "$($entries.Count) feedback entries total`n" -ForegroundColor Cyan
foreach ($e in ($entries | Select-Object -Last $Last)) {
    $who = if ($e.user) { $e.user } else { "$($e.name) (not signed in)" }
    $color = switch ($e.category) { "bug" { "Red" } "idea" { "Green" } default { "Gray" } }
    Write-Host ("[{0}] {1}  {2}" -f $e.category.ToUpper(), $e.time, $who) -ForegroundColor $color
    if ($e.info) { Write-Host ("  v{0} · {1} {2} · {3} · {4}" -f $e.info.version, $e.info.os, $e.info.os_version, $e.info.screen, $e.info.gpu) -ForegroundColor DarkGray }
    Write-Host ("  " + ($e.text -replace "`n", "`n  "))
    if ($Log -and $e.log) { Write-Host "  --- log ---`n$($e.log)" -ForegroundColor DarkGray }
    Write-Host ""
}
