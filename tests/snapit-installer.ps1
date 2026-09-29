# Contract for the graphical installer and the community packaging.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installerPath = Join-Path $root 'installer\SnapIt-Setup.ps1'
if (-not (Test-Path $installerPath)) { throw 'installer\SnapIt-Setup.ps1 is missing.' }

function Require-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw $Message }
}

$source = Get-Content -LiteralPath $installerPath -Raw -Encoding UTF8

# --- parses cleanly under Windows PowerShell 5.1 -------------------------
$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($installerPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw ('Installer parse errors: ' + (($parseErrors | ForEach-Object Message) -join '; '))
}

# --- stays ASCII-only so PS 5.1 never misreads the encoding --------------
$bytes = [System.IO.File]::ReadAllBytes($installerPath)
$nonAscii = @($bytes | Where-Object { $_ -gt 127 })
if ($nonAscii.Count -gt 0) { throw ('Installer source must stay ASCII-only; found ' + $nonAscii.Count + ' non-ASCII byte(s).') }

# --- the wizard actually covers every step the docs promise --------------
Require-Match $source 'WPF|PresentationFramework' 'The installer must build a real WPF window.'
Require-Match $source 'function\s+Get-SnapitProviderCatalog' 'Provider catalog is missing.'
Require-Match $source 'function\s+Get-SnapitPrereqReport' 'Prerequisite report is missing.'
Require-Match $source 'function\s+Add-SnapitProviderCredential' 'Credential writer is missing.'
Require-Match $source 'function\s+Set-SnapitDefaultModel' 'Default-model writer is missing.'
Require-Match $source 'hermes\W+auth\W+add' 'Credential step must go through hermes auth add.'
Require-Match $source 'config\W+set\W+model\.provider' 'Model step must set model.provider.'
Require-Match $source 'config\W+set\W+model\.default' 'Model step must set model.default.'
Require-Match $source 'Get-SnapitVoiceEnvFile|ELEVENLABS_API_KEY' 'Voice credential step is missing.'
Require-Match $source 'Agregar los modelos' 'The models page heading is missing.'
Require-Match $source '\[switch\]\$Unattended' 'Headless install mode is missing.'
Require-Match $source '\[switch\]\$SelfTest' 'Self-test mode is missing.'
Require-Match $source '\[switch\]\$SmokeTest' 'Smoke-test mode is missing.'
Require-Match $source 'function\s+Invoke-PumpedProcess' 'The installer must keep the window responsive while running children.'

# --- self-test actually passes -------------------------------------------
$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerPath -SelfTest 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw ('Installer self-test failed: ' + $out.Trim()) }
if ($out -notmatch 'PASS: SnapIt installer self-test') { throw 'Installer self-test did not report PASS.' }

# --- launcher + docs + license are present -------------------------------
foreach ($file in @('Instalar SnapIt.cmd', 'README.md', 'LICENSE', '.gitignore', 'docs\INSTALACION.md', 'docs\MODELOS.md', 'voice-config.example.json', 'setup.ps1', 'snapit.ps1', 'snapit-watchdog.ps1')) {
    if (-not (Test-Path (Join-Path $root $file))) { throw ("Missing community file: " + $file) }
}

# --- no personal data leaks into the distributed sources ------------------
$scan = @('snapit.ps1', 'setup.ps1', 'snapit-watchdog.ps1', 'lib\snapit-hermes.ps1', 'lib\snapit-prefill.mjs', 'lib\voice-flow.ps1', 'lib\camarita-bridge.py', 'installer\SnapIt-Setup.ps1', 'README.md', 'docs\INSTALACION.md', 'docs\MODELOS.md')
$patterns = @{
    'absolute G:\AI_DEV path' = 'G:\\AI_DEV'
    'personal Windows user'    = 'AlexSerrano'
    'personal ElevenLabs id'   = 'agent_1001m1tvx8syejptras60rpdvv15'
    'private Tailscale host'   = '100\.(108|65)\.'
}
foreach ($file in $scan) {
    $path = Join-Path $root $file
    if (-not (Test-Path $path)) { continue }
    $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    foreach ($name in $patterns.Keys) {
        if ($text -match $patterns[$name]) { throw ($file + ' still contains a ' + $name + '.') }
    }
}

# --- the installer must not require administrator rights -------------------
Require-Match $source 'LOCALAPPDATA|\.snapit' 'The installer must write only to user-scope locations.'
if ($source -match 'RunAs|requireAdministrator|Start-Process[^\r\n]*-Verb\s+RunAs') {
    throw 'The installer must not require elevation.'
}
$launcher = Get-Content -LiteralPath (Join-Path $root 'Instalar SnapIt.cmd') -Raw -Encoding UTF8
Require-Match $launcher 'SnapIt-Setup.ps1' 'The .cmd launcher does not point at the installer.'

Write-Output 'PASS: SnapIt graphical installer and packaging contract'
