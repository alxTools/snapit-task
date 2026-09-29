# Contract for Alt+Shift+A ultra-focus text + ElevenLabs voice mode.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$mainPath = Join-Path $root 'snapit.ps1'
$gluePath = Join-Path $root 'lib\snapit-hermes.ps1'
$main = Get-Content -LiteralPath $mainPath -Raw -Encoding UTF8
$glue = Get-Content -LiteralPath $gluePath -Raw -Encoding UTF8

function Require-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw $Message }
}

Require-Match $glue "promptHotkey\s*=\s*'Alt\+Shift\+A'" 'Default prompt hotkey is missing.'
Require-Match $glue "voiceAgentId\s*=\s*''" 'ElevenLabs voice agent id must ship empty so each user sets their own.'
Require-Match $glue 'function\s+Get-SnapitVoiceEnvFile' 'Voice API key discovery helper is missing.'
Require-Match $glue 'function\s+Invoke-SnapitTextImprove' 'Text-only prompt improver is missing.'
Require-Match $glue 'function\s+Start-SnapitVoiceServer' 'Secure local voice server launcher is missing.'
Require-Match $glue 'function\s+Open-SnapitVoiceCall' 'Voice call browser launcher is missing.'
Require-Match $glue 'function\s+Save-SnapitPromptDraft' 'Prompt draft persistence is missing.'
Require-Match $glue 'function\s+Get-SnapitPromptDrafts' 'Prompt draft listing is missing.'
Require-Match $glue 'function\s+Remove-SnapitPromptDraft' 'Prompt draft deletion is missing.'
Require-Match $glue 'function\s+New-SnapitScheduledTask' 'Hermes scheduled-task creation is missing.'
Require-Match $glue 'Join-Path\s+\$homeDir\s+''drafts''' 'SnapIt home does not provision the drafts directory.'
Require-Match $glue "'cron',\s*'create'" 'Scheduled tasks are not wired to Hermes cron.'
Require-Match $glue "--deliver', 'local'" 'Scheduled focus tasks must default to local delivery.'
Require-Match $glue 'executorAutoResume\s*=\s*\$true' 'Executor auto-resume must be enabled by default.'
Require-Match $glue 'hermes -p ''\$profQ'' chat --resume' 'Profile-aware resume command is missing.'
Require-Match $glue '-q ''<nuevo prompt>''' 'Resume hint must include the follow-up prompt placeholder.'
Require-Match $glue 'chat --resume `\$sessionId \$flags' 'Executor must auto-resume interactively without repeating the original prompt.'

Require-Match $main '\$script:SnapitLogFile\s*=.*\r?\n\$script:SnapitFocusOpen\s*=\s*\$false' 'Focus re-entry guard is not initialized under StrictMode.'
Require-Match $main '\[switch\]\$Focus' 'Direct -Focus entry point is missing.'
Require-Match $main 'function\s+New-SnapitFocusOverlays' 'Multi-monitor focus overlay builder is missing.'
Require-Match $main 'AllScreens' 'Focus mode does not enumerate all screens.'
Require-Match $main 'function\s+Show-SnapitFocusPanel' 'Central focus panel is missing.'
Require-Match $main 'Invoke-SnapitTextImprove' 'Focus panel is not wired to prompt improvement.'
Require-Match $main 'Show-HarnessPicker|Get-SnapitHarnesses\s+-Config' 'Focus panel is not wired to configured harnesses.'
Require-Match $main 'Open-SnapitVoiceCall' 'Focus panel is not wired to ElevenLabs voice calls.'
Require-Match $main "New-SnapitFocusButton\s+-Text\s+'Save to Draft'" 'Focus panel is missing Save to Draft.'
Require-Match $main "New-SnapitFocusButton\s+-Text\s+'Schedule Task'" 'Focus panel is missing Schedule Task.'
Require-Match $main 'function\s+Show-SnapitScheduleDialog' 'Schedule input dialog is missing.'
Require-Match $main 'Save-SnapitPromptDraft' 'Save to Draft is not wired to persistence.'
Require-Match $main 'Get-SnapitPromptDrafts' 'Draft sidebar is not wired to persisted drafts.'
Require-Match $main "New-WpfTextBlock\s+-Text\s+'DRAFTS'" 'Draft sidebar heading is missing.'
Require-Match $main "New-SnapitFocusButton\s+-Text\s+'Load Draft'" 'Draft sidebar is missing Load Draft.'
Require-Match $main "New-SnapitFocusButton\s+-Text\s+'Delete'" 'Draft sidebar is missing Delete.'
Require-Match $main 'ItemContainerStyle\s*=\s*\$comboItemStyle' 'Agent dropdown items do not use the dark readable style.'
Require-Match $main '\$comboItemBackground\.Value\s*=.*#24242A' 'Agent dropdown dark background setter is missing.'
Require-Match $main '\$comboItemForeground\.Value\s*=.*#F2F0F0' 'Agent dropdown readable foreground setter is missing.'
Require-Match $main 'New-SnapitScheduledTask' 'Schedule Task is not wired to Hermes cron.'
Require-Match $main 'promptHotkey' 'Tray app does not read the second hotkey.'
Require-Match $main 'hotkey prompt pressed' 'Second hotkey event is not wired.'
Require-Match $main 'Focus prompt' 'Tray menu does not expose focus mode.'

$voiceDir = Join-Path $root 'voice'
foreach ($file in @('server.mjs', 'package.json', 'public\index.html', 'public\app.js')) {
    if (-not (Test-Path (Join-Path $voiceDir $file))) { throw "Voice client file missing: $file" }
}
$avatar = Join-Path $root 'assets\sektor-chibi-avatar.png'
if (-not (Test-Path $avatar)) { throw 'Sektor chibi avatar is missing.' }
if ((Get-Item -LiteralPath $avatar).Length -lt 10000) { throw 'Sektor avatar file is unexpectedly small.' }

Write-Output 'PASS: SnapIt Alt+Shift+A focus and voice contract'
