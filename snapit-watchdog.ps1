# SnapIt autostart watchdog.
#
# Launched hidden at logon by Startup\SnapIt.cmd. Its only job: keep the SnapIt
# tray app alive. When the tray process exits WITHOUT writing ~\.snapit\.exit
# (crash, killed process, unexpected dispatcher stop), the watchdog relaunches it
# after a short pause. Choosing Exit SnapIt from the tray writes the marker, so the
# watchdog stops cleanly instead of relaunching.
$ErrorActionPreference = 'SilentlyContinue'

$scriptPath = Join-Path $PSScriptRoot 'snapit.ps1'
if (-not (Test-Path -LiteralPath $scriptPath)) { exit 0 }

$marker = Join-Path $env:USERPROFILE '.snapit\.exit'

while ($true) {
    if (Test-Path -LiteralPath $marker) { Remove-Item -LiteralPath $marker -Force }

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $scriptPath
    ) -WindowStyle Hidden -PassThru

    $proc.WaitForExit()

    # Marker present => the user chose Exit from the tray: stop the watchdog.
    if (Test-Path -LiteralPath $marker) {
        Remove-Item -LiteralPath $marker -Force
        exit 0
    }

    Start-Sleep -Seconds 3
}
