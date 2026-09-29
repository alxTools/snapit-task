# Behavioral checks for Ultra Focus draft persistence and cron wiring.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'lib\snapit-hermes.ps1')

$oldUserProfile = $env:USERPROFILE
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('snapit-focus-actions-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $env:USERPROFILE = $tempRoot
    $draft = Save-SnapitPromptDraft -Text "  Review the release notes.  " -ProfileName 'snapit'
    if (-not $draft.Ok -or -not (Test-Path -LiteralPath $draft.Path)) { throw 'Draft file was not created.' }
    $saved = Get-Content -LiteralPath $draft.Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($saved.text -ne 'Review the release notes.') { throw 'Draft text was not trimmed/persisted correctly.' }
    if ($saved.profile -ne 'snapit') { throw 'Draft profile was not persisted.' }
    if ((Split-Path -Parent $draft.Path) -ne (Join-Path $tempRoot '.snapit\drafts')) { throw 'Draft was saved outside the SnapIt drafts folder.' }

    $drafts = @(Get-SnapitPromptDrafts)
    if ($drafts.Count -ne 1) { throw "Expected one listed draft, found $($drafts.Count)." }
    if ($drafts[0].Text -ne 'Review the release notes.' -or $drafts[0].Profile -ne 'snapit') { throw 'Listed draft data is incorrect.' }
    if (-not $drafts[0].Display) { throw 'Listed draft has no display label.' }
    $outside = Join-Path $tempRoot 'outside.json'
    '{}' | Set-Content -LiteralPath $outside -Encoding UTF8
    $blocked = $false
    try { [void](Remove-SnapitPromptDraft -Path $outside) } catch { $blocked = $true }
    if (-not $blocked -or -not (Test-Path -LiteralPath $outside)) { throw 'Draft deletion escaped its protected folder.' }
    [void](Remove-SnapitPromptDraft -Path $draft.Path)
    if (@(Get-SnapitPromptDrafts).Count -ne 0) { throw 'Draft deletion did not refresh persisted state.' }

    $argsPath = Join-Path $tempRoot 'cron-args.txt'
    $mockHermes = Join-Path $tempRoot 'hermes.cmd'
    @"
@echo off
echo %* > "%SNAPIT_TEST_ARGS%"
exit /b 0
"@ | Set-Content -LiteralPath $mockHermes -Encoding ASCII
    $env:SNAPIT_TEST_ARGS = $argsPath
    function Get-HermesExe { return $mockHermes }

    $scheduled = New-SnapitScheduledTask -Text 'Run the focused check.' -Schedule '30m' -ProfileName 'snapit' -Name 'Focused check'
    if (-not $scheduled.Ok) { throw ("Scheduled task helper failed: " + $scheduled.Error) }
    if (-not (Test-Path -LiteralPath $argsPath)) { throw 'Hermes cron was not invoked.' }
    $argsText = (Get-Content -LiteralPath $argsPath -Raw -Encoding Default).Trim()
    foreach ($expected in @('-p snapit', 'cron create', '30m', 'Run the focused check.', '--name *Focused check*', '--deliver local')) {
        if ($argsText -notlike ('*' + $expected + '*')) { throw "Cron invocation is missing: $expected`n$argsText" }
    }

    Write-Output 'PASS: Ultra Focus drafts and scheduled-task behavior'
} finally {
    $env:USERPROFILE = $oldUserProfile
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
