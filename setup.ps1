# =====================================================================
#  SnapIt - one-time setup
#   * ensures ~\.snapit folders + default config.json
#   * clones the Hermes profile `snapit` from `default` (idempotent)
#   * writes the SnapIt workflow SOUL into the cloned profile
#   * optional: -AutoStart to launch SnapIt at logon
#
#  Run:
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\setup.ps1 -AutoStart
# =====================================================================
#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$AutoStart,
    [switch]$SkipProfileClone
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
. (Join-Path $root 'lib\snapit-hermes.ps1')

Write-Host ''
Write-Host '  SnapIt setup' -ForegroundColor Cyan
Write-Host '  ============' -ForegroundColor Cyan

# ---- 1) hermes
$hermes = Get-HermesExe
if (-not $hermes) {
    Write-Host '  [X] hermes.exe not found on PATH or LOCALAPPDATA.' -ForegroundColor Red
    Write-Host '      Install Hermes Agent first, then re-run setup.' -ForegroundColor Yellow
    exit 1
}
Write-Host ("  [ok] hermes: " + $hermes) -ForegroundColor Green

$homeDir = Get-HermesHome
if (-not $homeDir) {
    Write-Host '  [X] Hermes home not found.' -ForegroundColor Red
    exit 1
}

# ---- 2) snapit data + config
$null = Get-SnapitHome
$cfg = Get-SnapitConfig
Write-Host ("  [ok] config: " + $cfg.__path) -ForegroundColor Green

# ---- 3) clone `snapit` profile from `default`
$cloneName = 'snapit'
$cloned = $false
if (-not $SkipProfileClone) {
    $profiles = @(Get-HermesProfiles | Where-Object { $_.Name -eq $cloneName })
    if ($profiles.Count -gt 0) {
        Write-Host ("  [ok] profile '" + $cloneName + "' already exists at " + $profiles[0].Home) -ForegroundColor Green
    } else {
        Write-Host ("  [..] creating Hermes profile '" + $cloneName + "' cloned from 'default' (copies config/.env/SOUL/skills)...") -ForegroundColor Yellow
        $desc = "SnapIt executor: understands the SnapIt capture workflow (screenshots with pointer/text/rect/circle marks) and executes dispatched tasks as the active agent."
        $out = & $hermes profile create $cloneName --clone-from default --description $desc 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) {
            Write-Host '  [X] profile create failed:' -ForegroundColor Red
            Write-Host ($out | Out-String) -ForegroundColor Red
            exit 1
        }
        Write-Host '  [ok] profile created (clone of default)' -ForegroundColor Green
        $cloned = $true
    }
}

# ---- 4) write SnapIt SOUL into the cloned profile
$soulSrc = Join-Path $root 'hermes\snapit-soul.md'
$profileHome = Join-Path $homeDir ('profiles\{0}' -f $cloneName)
if (Test-Path $profileHome) {
    if (Test-Path $soulSrc) {
        $soulTarget = Join-Path $profileHome 'SOUL.md'
        $content = Get-Content $soulSrc -Raw -Encoding UTF8
        Set-Content -Path $soulTarget -Value $content -Encoding UTF8
        Write-Host ("  [ok] SOUL.md written: " + $soulTarget) -ForegroundColor Green
    }
    # convenience alias wrapper (hermes profile alias)
    try {
        $al = & $hermes profile alias $cloneName 2>&1
        Write-Host ("  [ok] alias wrapper ready (hermes profile alias snapit)") -ForegroundColor Green
    } catch {
        Write-Host '  [..] alias wrapper skipped' -ForegroundColor DarkGray
    }
} else {
    Write-Host ("  [..] profile home not found yet: " + $profileHome) -ForegroundColor Yellow
}

# ---- 5) sanity: invoke cloned profile version
if (-not $SkipProfileClone -or (Test-Path $profileHome)) {
    try {
        $v = & $hermes -p $cloneName --version 2>&1 | Select-Object -First 1
        Write-Host ("  [ok] hermes -p " + $cloneName + " responds: " + $v) -ForegroundColor Green
    } catch {
        Write-Host '  [..] could not run the cloned profile yet' -ForegroundColor Yellow
    }
}

# ---- 6) prereqs for the DeepSeek route
$node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
if (-not $node) {
    $cand = Join-Path $env:LOCALAPPDATA 'OpenDesign\toolchains\dsh\node-v24.19.0-win-x64\node.exe'
    if (Test-Path $cand) { $node = $cand }
}
if ($node) { Write-Host ("  [ok] node: " + $node) -ForegroundColor Green } else { Write-Host '  [..] node not found - DeepSeek auto-paste bridge will fall back to clipboard' -ForegroundColor Yellow }

$edge = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'C:\Program Files\Microsoft\Edge\Application\msedge.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($edge) { Write-Host ("  [ok] edge: " + $edge) -ForegroundColor Green } else { Write-Host '  [..] Edge not found - DeepSeek auto-paste bridge will fall back to clipboard' -ForegroundColor Yellow }

# ---- 7) autostart
if ($AutoStart) {
    $startupDir = [Environment]::GetFolderPath('Startup')
    $main = Join-Path $root 'snapit.ps1'
    $watchdog = Join-Path $root 'snapit-watchdog.ps1'
    $cmdPath = Join-Path $startupDir 'SnapIt.cmd'
    $cmd = "@echo off`r`nrem SnapIt autostart watchdog - relaunches the tray app if it crashes.`r`nrem Exit SnapIt from the tray (writes ~\.snapit\.exit) to stop the loop.`r`nstart """" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$watchdog`"`r`n"
    Set-Content -Path $cmdPath -Value $cmd -Encoding ASCII
    Write-Host ("  [ok] autostart watchdog created: " + $cmdPath) -ForegroundColor Green
    Write-Host '      SnapIt auto-relaunches after a crash; Exit from the tray stops the loop.' -ForegroundColor DarkGray
} else {
    Write-Host '  [..] autostart skipped (re-run with -AutoStart to launch SnapIt at logon)' -ForegroundColor DarkGray
}

# ---- 8) summary
$snapitMain = Join-Path $root 'snapit.ps1'
Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ("  Start SnapIt now:   powershell -NoProfile -ExecutionPolicy Bypass -File `"" + $snapitMain + "`"") -ForegroundColor White
Write-Host '  Then press Alt+Shift+S anywhere.' -ForegroundColor White
Write-Host ''
