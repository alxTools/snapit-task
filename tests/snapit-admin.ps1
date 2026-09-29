# Tests for SnapIt admin configuration and automatic routing contract.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\snapit-hermes.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$defaults = Get-SnapitDefaultConfig
Assert-True ($defaults.routingMode -eq 'ask') 'Default routingMode must be ask.'
Assert-True ($defaults.autoRouterProfile -eq 'camarita') 'Default auto router must be camarita.'
Assert-True ($defaults.terminalHost -eq 'wave') 'Executors must default to visible Wave terminals.'

$endpoints = @(Get-SnapitEndpoints -Config $defaults -IncludeDisabled)
Assert-True ($endpoints.Count -ge 1) 'At least one endpoint must be configured by default.'
Assert-True ($endpoints[0].Id -eq 'dsh-local') 'The default DSH endpoint must have a stable id.'
Assert-True ($endpoints[0].Url -eq 'http://127.0.0.1:18080') 'The default DSH endpoint URL is wrong.'

$cfg = @{
    harnesses = @(
        [pscustomobject]@{ id = 'cam'; name = 'Camera router'; profile = 'camarita'; enabled = $true },
        @{ id = 'off'; name = 'Disabled'; profile = 'default'; enabled = $false }
    )
}
$harnesses = @(Get-SnapitHarnesses -Config $cfg -IncludeDisabled)
Assert-True ($harnesses.Count -eq 2) 'Harness conversion must preserve both JSON objects and dictionaries.'
Assert-True ($harnesses[0].Profile -eq 'camarita') 'Harness profile normalization failed.'
Assert-True ($harnesses[1].Enabled -eq $false) 'Disabled harness state was not preserved.'

$enabled = @(Get-SnapitHarnesses -Config $cfg)
Assert-True ($enabled.Count -eq 1 -and $enabled[0].Profile -eq 'camarita') 'Disabled harnesses must be excluded by default.'

$routePrompt = Get-SnapitRoutePrompt -ImprovedPrompt 'Fix the Wi-Fi access point' -Harnesses @(
    [pscustomobject]@{ Name = 'Network operations'; Profile = 'unifi-ops'; Enabled = $true },
    [pscustomobject]@{ Name = 'General'; Profile = 'default'; Enabled = $true }
)
Assert-True ($routePrompt -match 'unifi-ops') 'Router prompt must include candidate profile names.'
Assert-True ($routePrompt -match 'Fix the Wi-Fi access point') 'Router prompt must include the improved request.'
Assert-True ($routePrompt -match 'do not execute') 'Router prompt must explicitly forbid execution.'

$parsed = Resolve-SnapitRouteOutput -Output "PROFILE=unifi-ops`n" -Harnesses @(
    [pscustomobject]@{ Name = 'Network operations'; Profile = 'unifi-ops'; Enabled = $true }
)
Assert-True ($parsed -eq 'unifi-ops') 'Valid router output was not resolved.'
$invalid = Resolve-SnapitRouteOutput -Output 'PROFILE=not-real' -Harnesses @(
    [pscustomobject]@{ Name = 'General'; Profile = 'default'; Enabled = $true }
)
Assert-True ($null -eq $invalid) 'Unknown router output must fail closed.'

Write-Output 'PASS: SnapIt admin and auto-routing contract'
