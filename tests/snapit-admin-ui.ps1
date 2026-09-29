# Static integration contract for the SnapIt admin UI and dispatch flow.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$main = Get-Content -LiteralPath (Join-Path $root 'snapit.ps1') -Raw -Encoding UTF8
$glue = Get-Content -LiteralPath (Join-Path $root 'lib\snapit-hermes.ps1') -Raw -Encoding UTF8

function Require-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw $Message }
}

Require-Match $main 'function\s+Show-SnapitAdminPanel' 'Admin panel function is missing.'
Require-Match $main '\[switch\]\$Admin' 'The direct -Admin launch switch is missing.'
Require-Match $main 'if\s*\(\$Admin\).*Show-SnapitAdminPanel' 'The -Admin entry point is not wired.'
Require-Match $main "ToolStripMenuItem\('Admin panel" 'Tray menu does not expose the admin panel.'
Require-Match $main 'function\s+Show-EndpointPicker' 'Configured endpoint picker is missing.'
Require-Match $main 'Get-SnapitHarnesses\s+-Config' 'Manual picker is not driven by configured harnesses.'
Require-Match $main "routingMode.*-eq\s*'auto'" 'Main flow does not branch into automatic routing.'
Require-Match $main 'Invoke-SnapitAutoRoute' 'Main flow does not invoke the automatic router.'
Require-Match $main 'autoRouterProfile' 'Main flow does not use the configured router profile.'
Require-Match $glue 'function\s+Invoke-SnapitAutoRoute' 'Automatic routing implementation is missing.'
Require-Match $glue 'Get-Command\s+wsh' 'Visible executor does not discover Wave wsh.'
Require-Match $glue "terminalHost.*wave" 'Visible executor does not honor the Wave terminal setting.'

Write-Output 'PASS: SnapIt admin UI and dispatch integration contract'
