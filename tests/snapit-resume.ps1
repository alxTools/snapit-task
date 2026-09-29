# Integration contract for profile-aware, automatic Hermes session resume.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$gluePath = Join-Path $root 'lib\snapit-hermes.ps1'
. $gluePath

$testRoot = Join-Path $env:TEMP ('snapit-resume-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$script:jobIndex = 0

function New-SnapitJob {
    param([string]$ImagePath)
    $script:jobIndex++
    $path = Join-Path $testRoot ('job' + $script:jobIndex)
    New-Item -ItemType Directory -Path $path | Out-Null
    return $path
}

function Get-HermesExe {
    return (Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\venv\Scripts\hermes.exe')
}

# Prevent the integration probe from opening a real PowerShell/Wave executor.
function Start-Process {
    param($FilePath, $ArgumentList, $WorkingDirectory)
    return [pscustomobject]@{ Id = 0 }
}

function Require-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw $Message }
}

try {
    $cfg = @{
        terminalHost        = 'none'
        executorAutoApprove = $true
        executorAutoResume  = $true
        executorWindow      = $true
        executorWorkdir     = 'home'
    }

    $imageProbe = Join-Path $root 'README.md'
    if (-not (Start-HermesExecutor -ProfileName 'spotifycanvas' -ImagePath $imageProbe -ImprovedPrompt 'integration probe' -Config $cfg)) {
        throw 'Image executor runner generation failed.'
    }
    if (-not (Start-HermesTextExecutor -ProfileName 'spotifycanvas' -ImprovedPrompt 'integration probe' -Config $cfg)) {
        throw 'Voice executor runner generation failed.'
    }

    $runners = @(
        (Join-Path $testRoot 'job1\run-agent.ps1'),
        (Join-Path $testRoot 'job2\run-voice-agent.ps1')
    )
    foreach ($runner in $runners) {
        $tokens = $null
        $parseErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $runner,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) {
            throw ((Split-Path $runner -Leaf) + ' parse errors: ' + (($parseErrors | ForEach-Object Message) -join '; '))
        }

        $body = Get-Content -LiteralPath $runner -Raw -Encoding UTF8
        Require-Match $body 'hermes -p ''spotifycanvas'' chat --resume ' ((Split-Path $runner -Leaf) + ' lacks the profile-aware command order.')
        Require-Match $body '-q ''<nuevo prompt>'' --yolo --accept-hooks' ((Split-Path $runner -Leaf) + ' lacks the follow-up prompt hint.')
        Require-Match $body '& ''.*hermes\.exe'' -p ''spotifycanvas'' chat --resume \$sessionId --yolo --accept-hooks' ((Split-Path $runner -Leaf) + ' lacks interactive auto-resume.')
        if ($body -match 'chat --resume \$sessionId -q') {
            throw ((Split-Path $runner -Leaf) + ' would repeat the completed prompt during automatic resume.')
        }
        Write-Output ('PASS: ' + (Split-Path $runner -Leaf) + ' generated, parsed, and auto-resume verified')
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
