# Tests for SnapIt crash resilience and pending-dispatch persistence.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\snapit-hermes.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

$testRoot = Join-Path $env:TEMP ('snapit-persistence-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null

try {
    # ---- 1) parse gates (PS 5.1-compatible grammar)
    foreach ($file in @((Join-Path $root 'snapit.ps1'), (Join-Path $root 'snapit-watchdog.ps1'), (Join-Path $root 'lib\snapit-hermes.ps1'))) {
        $src = Get-Content -LiteralPath $file -Raw
        $tokens = $null; $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) {
            throw ((Split-Path $file -Leaf) + ' parse errors: ' + (($parseErrors | ForEach-Object Message) -join '; '))
        }
    }
    Write-Output 'PASS: snapit.ps1, snapit-watchdog.ps1 and glue parse cleanly'

    # ---- 2) crash fix: no instance ClearFocus calls remain
    $main = Get-Content -LiteralPath (Join-Path $root 'snapit.ps1') -Raw
    Assert-True ($main -notmatch '\$s\.ClearFocus\s*\(') 'WPF TextBox ClearFocus() call still present.'
    $hits = ([regex]::Matches($main, '\[System\.Windows\.Input\.Keyboard\]::ClearFocus\(\)')).Count
    Assert-True ($hits -ge 2) 'Both text-draft focus clears must use Keyboard.ClearFocus().'

    # ---- 3) resume checkpoint helpers round-trip
    $resumePath = Join-Path $testRoot 'resume.json'
    $capture = Join-Path $testRoot 'capture.png'
    Set-Content -LiteralPath $capture -Value 'fake png' -Encoding ASCII

    Save-SnapitResume -CapturePath $capture -Prompt 'arregla el dashboard' -Path $resumePath
    Assert-True (Test-Path -LiteralPath $resumePath) 'Save-SnapitResume did not create the file.'
    $rec = Get-SnapitResume -Path $resumePath
    Assert-True ($null -ne $rec) 'Get-SnapitResume returned nothing for a valid checkpoint.'
    Assert-True ($rec.capture -eq $capture) 'Checkpoint capture path mismatch.'
    Assert-True ([string]$rec.prompt -eq 'arregla el dashboard') 'Checkpoint prompt mismatch.'
    Assert-True (Test-SnapitResumePending -Path $resumePath) 'Test-SnapitResumePending must report pending.'

    Clear-SnapitResume -Path $resumePath
    Assert-True (-not (Test-Path -LiteralPath $resumePath)) 'Clear-SnapitResume did not remove the file.'
    Assert-True (-not (Test-SnapitResumePending -Path $resumePath)) 'Test-SnapitResumePending must be false after clear.'

    # ---- 4) a checkpoint whose capture image vanished is not "pending" (fail closed)
    Save-SnapitResume -CapturePath (Join-Path $testRoot 'gone.png') -Prompt 'x' -Path $resumePath
    Assert-True (-not (Test-SnapitResumePending -Path $resumePath)) 'Missing capture must not be offered for recovery.'
    Clear-SnapitResume -Path $resumePath

    # ---- 5) resilience & recovery wiring exists in the app
    Assert-True ($main -match 'UnhandledException') 'Dispatcher safety net missing.'
    Assert-True ($main -match 'function Restart-SnapitSelf') 'Auto-restart helper missing.'
    Assert-True ($main -match 'function Invoke-SnapitDispatch') 'Dispatch checkpoint wrapper missing.'
    Assert-True ($main -match 'function Show-SnapitPendingRecovery') 'Recovery prompt missing.'
    Assert-True ($main -match 'Save-SnapitResume -CapturePath') 'Dispatch must checkpoint the pending capture.'
    Assert-True ($main -match '\.exit') 'Clean-Exit marker (watchdog stop) missing.'
    Assert-True ($main -match 'SnapitRecoveryOffered') 'One-off recovery gating missing.'
    Assert-True ((Test-Path (Join-Path $root 'snapit-watchdog.ps1'))) 'Watchdog script missing.'
    $watch = Get-Content -LiteralPath (Join-Path $root 'snapit-watchdog.ps1') -Raw
    Assert-True ($watch -match 'WaitForExit') 'Watchdog must wait on the SnapIt process.'
    Assert-True ($watch -match '\.exit') 'Watchdog must honor the clean-exit marker.'

    Write-Output 'PASS: SnapIt crash resilience and pending-dispatch persistence contract'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
