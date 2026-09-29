# =====================================================================
#  SnapIt - Hermes glue (Windows PowerShell 5.1 compatible)
#  ASCII-only source: all emoji are built at runtime from codepoints.
#  Dot-source from snapit.ps1:  . "<here>\lib\snapit-hermes.ps1"
# =====================================================================
Set-StrictMode -Version 2.0

# ----------------------------------------------------------------- emoji helper
function Get-SnapitEmoji {
    param([int]$CodePoint, [switch]$WithVariation)
    $s = [string][char]::ConvertFromUtf32($CodePoint)
    if ($WithVariation) { $s = $s + [string][char]::ConvertFromUtf32(0xFE0F) }
    return $s
}

$script:SnapitLogFile = $null
function Write-SnapitLog {
    param([string]$Message)
    if ($script:SnapitLogFile) {
        $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message
        try { Add-Content -Path $script:SnapitLogFile -Value $line -Encoding UTF8 } catch {}
    }
}

# ----------------------------------------------------------------- paths
function Get-SnapitHome {
    $homeDir = Join-Path $env:USERPROFILE '.snapit'
    foreach ($d in @($homeDir,
                     (Join-Path $homeDir 'captures'),
                     (Join-Path $homeDir 'jobs'),
                     (Join-Path $homeDir 'drafts'),
                     (Join-Path $homeDir 'logs'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    return $homeDir
}

# ----------------------------------------------------------------- default config
function Get-SnapitDefaultConfig {
    return @{
        hotkey              = 'Alt+Shift+S'
        promptHotkey        = 'Alt+Shift+A'
        improvePrompt       = $true
        improverProfile     = 'default'
        improverModel       = ''
        executorAutoApprove = $true
        executorAutoResume  = $true
        executorWindow      = $true
        executorWorkdir     = 'profile'
        lastTool            = 'square'
        toolColor           = '#E53935'
        toolThickness       = 4
        textFontSize        = 30
        webUrl              = 'http://127.0.0.1:18080'
        routingMode         = 'ask'
        autoRouterProfile   = 'camarita'
        terminalHost        = 'wave'
        # ElevenLabs agent for the Alt+Shift+A voice call. Ships EMPTY on
        # purpose: every user sets their own agent id (the installer and the
        # admin panel both write it into config.json).
        voiceAgentId        = ''
        voicePort           = 3847
        # Optional explicit path to the .env that holds ELEVENLABS_API_KEY.
        # Empty means: auto-discover (see Get-SnapitVoiceEnvFile).
        voiceEnvFile        = ''
        endpoints           = @(
            @{ id = 'dsh-local'; name = 'DeepSeek DSH'; url = 'http://127.0.0.1:18080'; enabled = $true }
        )
        # Empty means: discover every installed Hermes profile. The admin panel
        # materializes this list when the user customizes harnesses.
        harnesses           = @()
        profileEmojis       = @{
            'default'         = (Get-SnapitEmoji 0x25C6)                                   # diamond
            'g-master-switch' = (Get-SnapitEmoji 0x1F3AE)                                  # video game
            'kimi-intel'      = (Get-SnapitEmoji 0x1F9E0)                                  # brain
            'spotifycanvas'   = (Get-SnapitEmoji 0x1F3A8)                                  # palette
            'unifi-ops'       = (Get-SnapitEmoji 0x1F4E1)                                  # satellite
            'snapit'          = (Get-SnapitEmoji 0x1F4F8)                                  # camera
        }
    }
}

# ----------------------------------------------------------------- config load/save
function Get-SnapitConfig {
    $snapHome = Get-SnapitHome
    $cfgPath = Join-Path $snapHome 'config.json'
    $defaults = Get-SnapitDefaultConfig
    if (Test-Path $cfgPath) {
        try {
            $user = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $merged = @{}
            foreach ($k in $defaults.Keys) { $merged[$k] = $defaults[$k] }
            foreach ($p in $user.PSObject.Properties) {
                # profileEmojis is merged below into the default hashtable
                if ($p.Name -eq 'profileEmojis') { continue }
                if ($defaults.ContainsKey($p.Name)) { $merged[$p.Name] = $p.Value }
            }
            # profileEmojis merge: accept PSCustomObject (JSON object) or IDictionary safely
            $pe = $user.profileEmojis
            $peMap = @{}
            if ($null -ne $pe) {
                if ($pe -is [System.Management.Automation.PSCustomObject]) {
                    foreach ($p in $pe.PSObject.Properties) { $peMap[$p.Name] = [string]$p.Value }
                } elseif ($pe -is [System.Collections.IDictionary]) {
                    foreach ($k in @($pe.Keys)) { $peMap[[string]$k] = [string]$pe[$k] }
                }
            }
            foreach ($k in $peMap.Keys) {
                if ($merged.ContainsKey('profileEmojis')) { $merged['profileEmojis'][$k] = $peMap[$k] }
            }
            $merged['__path'] = $cfgPath
            return $merged
        } catch {
            Write-SnapitLog "config.json invalid ($($_.Exception.Message)); using defaults"
        }
    }
    Save-SnapitConfig $defaults
    $defaults['__path'] = $cfgPath
    return $defaults
}

function Save-SnapitConfig {
    param($Config)
    $snapHome = Get-SnapitHome
    $cfgPath = Join-Path $snapHome 'config.json'
    $clean = @{}
    foreach ($k in $Config.Keys) { if ($k -ne '__path') { $clean[$k] = $Config[$k] } }
    ($clean | ConvertTo-Json -Depth 6) | Set-Content -Path $cfgPath -Encoding UTF8
}

# ----------------------------------------------------------------- admin records
function Get-SnapitValue {
    param($Item, [string]$Name, $Default = $null)
    if ($null -eq $Item) { return $Default }
    if ($Item -is [System.Collections.IDictionary]) {
        if ($Item.Contains($Name)) { return $Item[$Name] }
        return $Default
    }
    $prop = $Item.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
}

function ConvertTo-SnapitBool {
    param($Value, [bool]$Default = $true)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    if ($text -in @('false', '0', 'no', 'off')) { return $false }
    if ($text -in @('true', '1', 'yes', 'on')) { return $true }
    return $Default
}

function Get-SnapitEndpoints {
    param($Config, [switch]$IncludeDisabled)
    $raw = @(Get-SnapitValue -Item $Config -Name 'endpoints' -Default @())
    $result = @()
    $i = 0
    foreach ($item in $raw) {
        if ($null -eq $item) { continue }
        $i++
        $url = [string](Get-SnapitValue -Item $item -Name 'url' -Default '')
        if (-not $url.Trim()) { continue }
        $enabled = ConvertTo-SnapitBool (Get-SnapitValue -Item $item -Name 'enabled' -Default $true)
        if (-not $IncludeDisabled -and -not $enabled) { continue }
        $id = [string](Get-SnapitValue -Item $item -Name 'id' -Default ("endpoint-$i"))
        $name = [string](Get-SnapitValue -Item $item -Name 'name' -Default $id)
        $result += [pscustomobject]@{ Id = $id; Name = $name; Url = $url; Enabled = $enabled }
    }
    return $result
}

function Get-SnapitHarnesses {
    param($Config, [switch]$IncludeDisabled)
    $raw = @(Get-SnapitValue -Item $Config -Name 'harnesses' -Default @())
    if ($raw.Count -eq 0) {
        $raw = @(Get-HermesProfiles | ForEach-Object {
            [pscustomobject]@{ id = $_.Name; name = $_.Name; profile = $_.Name; enabled = $true }
        })
    }
    $result = @()
    $i = 0
    foreach ($item in $raw) {
        if ($null -eq $item) { continue }
        $i++
        $profile = [string](Get-SnapitValue -Item $item -Name 'profile' -Default '')
        if (-not $profile.Trim()) { continue }
        $enabled = ConvertTo-SnapitBool (Get-SnapitValue -Item $item -Name 'enabled' -Default $true)
        if (-not $IncludeDisabled -and -not $enabled) { continue }
        $id = [string](Get-SnapitValue -Item $item -Name 'id' -Default ("harness-$i"))
        $name = [string](Get-SnapitValue -Item $item -Name 'name' -Default $profile)
        $result += [pscustomobject]@{ Id = $id; Name = $name; Profile = $profile; Enabled = $enabled }
    }
    return $result
}

function Get-SnapitRoutePrompt {
    param([string]$ImprovedPrompt, [object[]]$Harnesses)
    $lines = @()
    foreach ($h in @($Harnesses)) {
        $lines += ("- PROFILE={0} | {1}" -f $h.Profile, $h.Name)
    }
    return @"
You are SnapIt's routing classifier. Inspect the attached screenshot and the
request below, then choose exactly one candidate Hermes profile. You classify
only: do not execute the task, do not use tools, and do not explain.

REQUEST:
$ImprovedPrompt

CANDIDATES:
$($lines -join "`n")

Output exactly one line: PROFILE=<candidate profile name>
"@
}

function Resolve-SnapitRouteOutput {
    param([string]$Output, [object[]]$Harnesses)
    if (-not $Output) { return $null }
    $match = [regex]::Match($Output, '(?im)^\s*PROFILE\s*=\s*([A-Za-z0-9._-]+)\s*$')
    if (-not $match.Success) { return $null }
    $selected = $match.Groups[1].Value
    foreach ($h in @($Harnesses)) {
        if ([string]::Equals([string]$h.Profile, $selected, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [string]$h.Profile
        }
    }
    return $null
}

# ----------------------------------------------------------------- hermes exe discovery
function Get-HermesExe {
    $c = Get-Command hermes.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = Join-Path $env:LOCALAPPDATA 'hermes\hermes-agent\venv\Scripts\hermes.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

# ----------------------------------------------------------------- hermes home discovery
function Get-HermesHome {
    $candidate = $env:LOCALAPPDATA + '\hermes'
    if (Test-Path $candidate) { return $candidate }
    $alt = Join-Path $env:USERPROFILE '.hermes'
    if (Test-Path $alt) { return $alt }
    return $null
}

# ----------------------------------------------------------------- tiny yaml description reader
function Read-ProfileDescription {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return '' }
    $lines = Get-Content $Path -Encoding UTF8
    $desc = $null
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i]
        if ($t -match '^description\s*:\s*(.*)$') {
            $val = $Matches[1].Trim().Trim('"').Trim("'")
            if ($val -eq '' -or $val -eq '|' -or $val -eq '>') { $desc = '' } else { $desc = $val }
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j] -match '^\s{2,}(\S.*)$') {
                    $desc = ($desc + ' ' + $Matches[1].Trim('"')).Trim()
                } else { break }
            }
            break
        }
    }
    if ($null -eq $desc) { return '' }
    # unescape common yaml sequences (folded/quoted descriptions)
    $evalU = { param($m) [string][char][int]('0x' + $m.Groups[1].Value) }
    $evalX = { param($m) [string][char][int]('0x' + $m.Groups[1].Value) }
    $desc = [regex]::Replace($desc, '\\u([0-9a-fA-F]{4})', $evalU)
    $desc = [regex]::Replace($desc, '\\x([0-9a-fA-F]{2})', $evalX)
    return $desc
}

# ----------------------------------------------------------------- profiles discovery
function Get-HermesProfiles {
    $snapHome = Get-HermesHome
    $result = @()
    if (-not $snapHome) { return $result }
    $defaultDesc = Read-ProfileDescription (Join-Path $snapHome 'profile.yaml')
    if (-not $defaultDesc) { $defaultDesc = 'Default Hermes profile' }
    $result += [pscustomobject]@{
        Name        = 'default'
        Emoji       = ''
        Description = $defaultDesc
        IsDefault   = $true
        Home        = $snapHome
    }
    $profRoot = Join-Path $snapHome 'profiles'
    if (Test-Path $profRoot) {
        Get-ChildItem $profRoot -Directory -Force | Where-Object { $_.Name -notlike '.*' } | Sort-Object Name | ForEach-Object {
            $pHome = $_.FullName
            if ((Test-Path (Join-Path $pHome 'config.yaml')) -or (Test-Path (Join-Path $pHome 'profile.yaml'))) {
                $desc = Read-ProfileDescription (Join-Path $pHome 'profile.yaml')
                $result += [pscustomobject]@{
                    Name        = $_.Name
                    Emoji       = ''
                    Description = $desc
                    IsDefault   = $false
                    Home        = $pHome
                }
            }
        }
    }
    return $result
}

# ----------------------------------------------------------------- cmdline arg quoting
function ConvertTo-CmdArg {
    param([string]$Value)
    if ($Value -match '[\s"]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }
    return $Value
}

# ----------------------------------------------------------------- run external process, capture output
function Invoke-ExternalProcess {
    param(
        [string]$FileName,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 300,
        [switch]$NoWindow
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = (($Arguments | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    try {
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            try { $p.Kill() } catch {}
            return [pscustomobject]@{ Ok = $false; Stdout = ''; Stderr = "timed out after ${TimeoutSeconds}s"; ExitCode = -2 }
        }
        return [pscustomobject]@{
            Ok       = ($p.ExitCode -eq 0)
            Stdout   = $outTask.Result
            Stderr   = $errTask.Result
            ExitCode = $p.ExitCode
        }
    } catch {
        return [pscustomobject]@{ Ok = $false; Stdout = ''; Stderr = $_.Exception.Message; ExitCode = -3 }
    }
}

# ----------------------------------------------------------------- hermes one-shot (chat -Q -q ... --image)
function Invoke-HermesOneShot {
    param(
        [string]$Profile,
        [string]$Prompt,
        [string]$ImagePath = '',
        [string]$Model = '',
        [int]$TimeoutSeconds = 300,
        [switch]$AutoApprove
    )
    $hermes = Get-HermesExe
    if (-not $hermes) {
        return [pscustomobject]@{ Ok = $false; Output = ''; Error = 'hermes.exe not found on PATH or LOCALAPPDATA'; ExitCode = -1 }
    }
    $args = @('-p', $Profile, 'chat', '-Q', '-q', $Prompt)
    if ($ImagePath -and (Test-Path $ImagePath)) { $args += @('--image', $ImagePath) }
    if ($Model) { $args += @('-m', $Model) }
    if ($AutoApprove) { $args += @('--yolo', '--accept-hooks') }

    $r = Invoke-ExternalProcess -FileName $hermes -Arguments $args -WorkingDirectory (Split-Path $hermes -Parent) -TimeoutSeconds $TimeoutSeconds
    return [pscustomobject]@{
        Ok       = $r.Ok
        Output   = $r.Stdout
        Error    = $r.Stderr
        ExitCode = $r.ExitCode
    }
}

# ----------------------------------------------------------------- clean one-shot text
function ConvertTo-CleanHermesText {
    param([string]$Text)
    # strip ANSI color/control escapes Hermes emits even in quiet mode
    $esc = [char]27
    $Text = $Text -replace ($esc + '\[[0-9;]*[A-Za-z]'), ''
    # normalize CR-only / CRLF line endings (Hermes streams progress with CR)
    $Text = $Text -replace "`r`n", "`n"
    $Text = $Text -replace "`r", "`n"
    $lines = $Text -split "`n"

    # Hermes quiet mode still echoes reasoning/tool markers before the real answer.
    # Structural rule: the answer is the text AFTER the last marker-ish line.
    $lastMarker = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $raw = $lines[$i]
        $t = $raw.Trim([char[]](0x200B, 0x200C, 0x200D, 0xFEFF, 0x20, 0x09))
        if ($t -eq '') { continue }
        $isMarker = ($t -match '^(\*\*|\*)') -or
                    ($t -match '[\u2500-\u257F\u2580-\u259F]') -or
                    ($t -match '^(Session|session|SESSION)(\s|:|\b)') -or
                    ($t -match '^session[_ -]?id\s*:') -or
                    ($t -match '^Warning:\s')
        if ($isMarker) { $lastMarker = $i }
    }
    if ($lastMarker -ge 0) {
        $kept = @()
        for ($i = $lastMarker + 1; $i -lt $lines.Count; $i++) {
            $t = $lines[$i].Trim()
            if ($t -ne '') { $kept += $lines[$i] }
        }
        return ($kept -join "`n").Trim()
    }
    # no markers seen: drop obvious chrome and return the rest
    $kept = @()
    foreach ($l in $lines) {
        $t = $l.Trim()
        if ($t -eq '') { continue }
        if ($t -match '^(Session|session|SESSION)(\s|:|\b)') { continue }
        if ($t -match '^session[_ -]?id\s*:') { continue }
        if ($t -match '[\u2500-\u257F\u2580-\u259F]') { continue }
        if ($t -match '^Warning:\s') { continue }
        $kept += $l
    }
    return ($kept -join "`n").Trim()
}

# ----------------------------------------------------------------- improver prompt factory
function Get-ImproverPrompt {
    $pointer = Get-SnapitEmoji 0x1F5B1 -WithVariation
    $p = @'
You receive a screenshot captured on the user's PC with SnapIt.
The user may have: (1) drawn rectangles/ellipses or placed a pointer mark
({POINTER}) around what matters, (2) typed a short text note -- that note is their
instruction, (3) simply selected an area with no marks -- infer the most plausible
intent from the visible content (window titles, error messages, code, UI, values).

Your ONLY job: rewrite that into ONE polished, self-contained task prompt that
captures exactly what the user wants -- the "magic prompt" they would have typed if
they could articulate it perfectly. Ground it in the concrete context visible on
screen so a receiving agent does not need to guess. Keep the user's language
(Spanish unless the capture is clearly in another language).

Output rules -- print ONLY the final prompt:
- no preamble, no commentary, no bullet explanations, no code fences,
- no surrounding quotes.
If the image carries no actionable intent, output exactly: NO_INTENT
'@
    return $p.Replace('{POINTER}', $pointer)
}

# ----------------------------------------------------------------- improver
function Invoke-SnapitImprove {
    param(
        [string]$ImagePath,
        $Config
    )
    $profile = 'default'
    if ($Config -and $Config.improverProfile) { $profile = [string]$Config.improverProfile }
    $model = ''
    if ($Config -and $Config.improverModel) { $model = [string]$Config.improverModel }
    $prompt = Get-ImproverPrompt
    Write-SnapitLog "improver: hermes -p $profile reading $ImagePath"
    $r = Invoke-HermesOneShot -Profile $profile -Prompt $prompt -ImagePath $ImagePath -Model $model -TimeoutSeconds 300
    if (-not $r.Ok) {
        Write-SnapitLog "improver failed: $($r.Error)"
        return [pscustomobject]@{ Ok = $false; Text = ''; Raw = $r.Output }
    }
    $clean = ConvertTo-CleanHermesText $r.Output
    if ($clean -match '^NO_INTENT\s*$') {
        return [pscustomobject]@{ Ok = $true; Text = ''; Raw = $r.Output }
    }
    return [pscustomobject]@{ Ok = $true; Text = $clean; Raw = $r.Output }
}

# ----------------------------------------------------------------- automatic router
function Invoke-SnapitAutoRoute {
    param(
        [string]$ImagePath,
        [string]$ImprovedPrompt,
        $Config
    )
    $harnesses = @(Get-SnapitHarnesses -Config $Config)
    if ($harnesses.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Profile = ''; Error = 'no-enabled-harnesses' }
    }
    $routerProfile = [string](Get-SnapitValue -Item $Config -Name 'autoRouterProfile' -Default 'camarita')
    if (-not $routerProfile.Trim()) { $routerProfile = 'camarita' }
    $prompt = Get-SnapitRoutePrompt -ImprovedPrompt $ImprovedPrompt -Harnesses $harnesses
    Write-SnapitLog "auto route: $routerProfile choosing among $($harnesses.Count) harnesses"
    $r = Invoke-HermesOneShot -Profile $routerProfile -Prompt $prompt -ImagePath $ImagePath -TimeoutSeconds 180
    if (-not $r.Ok) {
        Write-SnapitLog "auto route failed: $($r.Error)"
        return [pscustomobject]@{ Ok = $false; Profile = ''; Error = $r.Error }
    }
    $clean = ConvertTo-CleanHermesText $r.Output
    $selected = Resolve-SnapitRouteOutput -Output $clean -Harnesses $harnesses
    if (-not $selected) {
        Write-SnapitLog "auto route invalid output: $clean"
        return [pscustomobject]@{ Ok = $false; Profile = ''; Error = 'invalid-router-output' }
    }
    Write-SnapitLog "auto route selected: $selected"
    return [pscustomobject]@{ Ok = $true; Profile = $selected; Error = '' }
}

# ----------------------------------------------------------------- spoken-text improver
function Invoke-SnapitImproveText {
    param(
        [string]$Transcript,
        [string]$TargetProfile = 'default',
        $Config
    )
    if (-not $Transcript.Trim()) {
        return [pscustomobject]@{ Ok = $false; Text = ''; Raw = '' }
    }
    $profile = 'default'
    if ($Config -and $Config.improverProfile) { $profile = [string]$Config.improverProfile }
    $model = ''
    if ($Config -and $Config.improverModel) { $model = [string]$Config.improverModel }
    $prompt = @"
Convierte la siguiente transcripcion de voz en un unico prompt operativo, claro y autocontenido para el perfil Hermes '$TargetProfile'. Conserva exactamente la intencion, nombres propios, restricciones y destino. Corrige errores obvios de transcripcion sin inventar hechos ni acciones. Prioriza: intencion, contexto, restricciones, verificacion y siguiente accion. Espanol conciso. Devuelve SOLO el prompt final, sin preambulo, comillas ni markdown.

TRANSCRIPCION:
$Transcript
"@
    $r = Invoke-HermesOneShot -Profile $profile -Prompt $prompt -ImagePath '' -Model $model -TimeoutSeconds 300
    if (-not $r.Ok) {
        Write-SnapitLog "voice improver failed: $($r.Error)"
        return [pscustomobject]@{ Ok = $false; Text = $Transcript.Trim(); Raw = $r.Output }
    }
    $clean = ConvertTo-CleanHermesText $r.Output
    if (-not $clean) { $clean = $Transcript.Trim() }
    return [pscustomobject]@{ Ok = $true; Text = $clean; Raw = $r.Output }
}

# Backward-compatible text-only improver used by the focus prompt.
function Invoke-SnapitTextImprove {
    param([string]$Text, [string]$TargetProfile = 'default', $Config)
    return Invoke-SnapitImproveText -Transcript $Text -TargetProfile $TargetProfile -Config $Config
}

# ----------------------------------------------------------------- ElevenLabs local voice bridge

# Resolve the .env file that holds ELEVENLABS_API_KEY. Order:
#   1. config.json  voiceEnvFile          (explicit override)
#   2. <hermes home>profiles<profile>.env  (per-profile installs)
#   3. <hermes home>.env                 (standard install)
#   4. ~.hermes.env                     (legacy layout)
function Get-SnapitVoiceEnvFile {
    param($Config)
    $explicitPath = [string](Get-SnapitValue -Item $Config -Name 'voiceEnvFile' -Default '')
    if ($explicitPath -and (Test-Path $explicitPath)) { return $explicitPath }

    $profile = [string](Get-SnapitValue -Item $Config -Name 'improverProfile' -Default 'default')
    if (-not $profile) { $profile = 'default' }
    $candidates = @()
    $hermesHome = Get-HermesHome
    if ($hermesHome) {
        $candidates += (Join-Path $hermesHome ('profiles{0}.env' -f $profile))
        $candidates += (Join-Path $hermesHome '.env')
    }
    $candidates += (Join-Path $env:USERPROFILE '.hermes.env')

    foreach ($candidate in $candidates) {
        if (-not (Test-Path $candidate)) { continue }
        try {
            $text = Get-Content -LiteralPath $candidate -Raw -Encoding UTF8
            if ($text -match '(?m)^s*ELEVENLABS_API_KEYs*=s*S') { return $candidate }
        } catch {}
    }
    foreach ($candidate in $candidates) { if (Test-Path $candidate) { return $candidate } }
    return ''
}

function Start-SnapitVoiceServer {
    param($Config, [string]$RootPath)
    if (-not $RootPath) { $RootPath = Split-Path -Parent $PSScriptRoot }
    $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if (-not $nodeCmd) { $nodeCmd = Get-Command node -ErrorAction SilentlyContinue }
    $server = Join-Path $RootPath 'voice\server.mjs'
    $port = [int](Get-SnapitValue -Item $Config -Name 'voicePort' -Default 3847)
    $agentId = [string](Get-SnapitValue -Item $Config -Name 'voiceAgentId' -Default '')
    $envFile = Get-SnapitVoiceEnvFile -Config $Config
    $baseUrl = "http://127.0.0.1:$port"
    if (-not $nodeCmd -or -not (Test-Path $server) -or -not $agentId -or -not (Test-Path $envFile)) {
        return [pscustomobject]@{ Ok = $false; Url = ''; Pid = 0; Existing = $false; Error = 'voice-prerequisites-missing' }
    }
    try {
        $health = Invoke-RestMethod -Uri ($baseUrl + '/health') -TimeoutSec 2
        if ($health.ok -and [string]$health.agentId -eq $agentId) {
            return [pscustomobject]@{ Ok = $true; Url = $baseUrl; Pid = [int]$health.pid; Existing = $true; Error = '' }
        }
        return [pscustomobject]@{ Ok = $false; Url = ''; Pid = 0; Existing = $true; Error = 'voice-port-owned-by-another-service' }
    } catch {}

    try {
        $args = @($server, '--port', [string]$port, '--agent-id', $agentId, '--env-file', $envFile, '--root', $RootPath)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $nodeCmd.Source
        $psi.Arguments = (($args | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $psi
        [void]$process.Start()
        for ($i = 0; $i -lt 30; $i++) {
            Start-Sleep -Milliseconds 200
            try {
                $health = Invoke-RestMethod -Uri ($baseUrl + '/health') -TimeoutSec 2
                if ($health.ok -and [string]$health.agentId -eq $agentId) {
                    Write-SnapitLog "voice server ready pid=$($health.pid) port=$port"
                    return [pscustomobject]@{ Ok = $true; Url = $baseUrl; Pid = [int]$health.pid; Existing = $false; Error = '' }
                }
            } catch {}
            if ($process.HasExited) { break }
        }
        Write-SnapitLog 'voice server failed to become healthy'
        return [pscustomobject]@{ Ok = $false; Url = ''; Pid = 0; Existing = $false; Error = 'voice-server-start-failed' }
    } catch {
        Write-SnapitLog "voice server exception: $($_.Exception.Message)"
        return [pscustomobject]@{ Ok = $false; Url = ''; Pid = 0; Existing = $false; Error = $_.Exception.Message }
    }
}

function Open-SnapitVoiceCall {
    param($Config, [string]$RootPath)
    $voice = Start-SnapitVoiceServer -Config $Config -RootPath $RootPath
    if (-not $voice.Ok) { return $voice }
    $edge = $null
    foreach ($candidate in @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'C:\Program Files\Microsoft\Edge\Application\msedge.exe')) {
        if (Test-Path $candidate) { $edge = $candidate; break }
    }
    if (-not $edge) {
        return [pscustomobject]@{ Ok = $false; Url = $voice.Url; Pid = $voice.Pid; Existing = $voice.Existing; Error = 'edge-not-found' }
    }
    try {
        $userData = Join-Path (Get-SnapitHome) 'voice-edge-profile'
        $args = @('--app=' + $voice.Url, '--window-size=740,780', '--user-data-dir=' + $userData, '--autoplay-policy=no-user-gesture-required')
        Start-Process -FilePath $edge -ArgumentList $args | Out-Null
        Write-SnapitLog "voice call opened agent=$([string](Get-SnapitValue -Item $Config -Name 'voiceAgentId' -Default ''))"
        return [pscustomobject]@{ Ok = $true; Url = $voice.Url; Pid = $voice.Pid; Existing = $voice.Existing; Error = '' }
    } catch {
        return [pscustomobject]@{ Ok = $false; Url = $voice.Url; Pid = $voice.Pid; Existing = $voice.Existing; Error = $_.Exception.Message }
    }
}

# ----------------------------------------------------------------- focus drafts + scheduled tasks
function Save-SnapitPromptDraft {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$ProfileName = 'default'
    )
    $cleanText = $Text.Trim()
    if (-not $cleanText) { throw 'Draft text cannot be empty.' }

    $draftDir = Join-Path (Get-SnapitHome) 'drafts'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $path = Join-Path $draftDir ("{0}.json" -f $stamp)
    $draft = [ordered]@{
        createdAt = (Get-Date).ToString('o')
        profile   = $ProfileName
        text      = $cleanText
    }
    ($draft | ConvertTo-Json -Depth 3) | Set-Content -LiteralPath $path -Encoding UTF8
    Write-SnapitLog "focus draft saved: $path"
    return [pscustomobject]@{ Ok = $true; Path = $path }
}

function Get-SnapitPromptDrafts {
    $draftDir = Join-Path (Get-SnapitHome) 'drafts'
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath $draftDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        try {
            $data = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $text = [string]$data.text
            if (-not $text.Trim()) { continue }
            $profile = [string]$data.profile
            if (-not $profile.Trim()) { $profile = 'default' }
            $created = [string]$data.createdAt
            $when = $file.LastWriteTime.ToString('MMM d  HH:mm')
            try { if ($created) { $when = ([datetime]$created).ToLocalTime().ToString('MMM d  HH:mm') } } catch {}
            $preview = @($text -split "`r?`n")[0].Trim()
            if ($preview.Length -gt 36) { $preview = $preview.Substring(0, 36).TrimEnd() + '...' }
            $items += [pscustomobject]@{
                Path    = $file.FullName
                Text    = $text
                Profile = $profile
                Created = $created
                Display = ("{0}`n{1}  |  {2}" -f $preview, $when, $profile)
            }
        } catch {
            Write-SnapitLog "draft read skipped: $($file.FullName) $($_.Exception.Message)"
        }
    }
    return $items
}

function Remove-SnapitPromptDraft {
    param([Parameter(Mandatory = $true)][string]$Path)
    $draftDir = [System.IO.Path]::GetFullPath((Join-Path (Get-SnapitHome) 'drafts')).TrimEnd('\') + '\'
    $candidate = [System.IO.Path]::GetFullPath($Path)
    if (-not $candidate.StartsWith($draftDir, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to delete a file outside the SnapIt drafts folder.'
    }
    if ([System.IO.Path]::GetExtension($candidate) -ne '.json') { throw 'Only SnapIt JSON drafts can be deleted.' }
    if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Force }
    Write-SnapitLog "focus draft deleted: $candidate"
    return $true
}

# ----------------------------------------------------------------- pending dispatch recovery
# A capture whose dispatch was interrupted (crash, power loss, killed process) is
# checkpointed to ~/.snapit/resume.json while the destination flow is open. On the
# next start SnapIt can offer to re-open it instead of losing the user's work.
function Get-SnapitResumePath {
    param([string]$Path)
    if ($Path) { return $Path }
    return (Join-Path (Get-SnapitHome) 'resume.json')
}

function Save-SnapitResume {
    param(
        [Parameter(Mandatory = $true)][string]$CapturePath,
        [Parameter(Mandatory = $true)][string]$Prompt,
        [string]$Path
    )
    $target = Get-SnapitResumePath -Path $Path
    $rec = @{
        version   = 1
        createdAt = (Get-Date).ToString('o')
        capture   = $CapturePath
        prompt    = $Prompt
    }
    try {
        ($rec | ConvertTo-Json -Depth 4) | Set-Content -Path $target -Encoding UTF8
    } catch {
        Write-SnapitLog "save resume failed: $($_.Exception.Message)"
    }
}

function Get-SnapitResume {
    param([string]$Path)
    $target = Get-SnapitResumePath -Path $Path
    if (-not (Test-Path -LiteralPath $target)) { return $null }
    try {
        $rec = Get-Content -LiteralPath $target -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $rec.capture -or -not (Test-Path -LiteralPath ([string]$rec.capture))) { return $null }
        return $rec
    } catch {
        Write-SnapitLog "read resume failed: $($_.Exception.Message)"
        return $null
    }
}

function Test-SnapitResumePending {
    param([string]$Path)
    return ($null -ne (Get-SnapitResume -Path $Path))
}

function Clear-SnapitResume {
    param([string]$Path)
    $target = Get-SnapitResumePath -Path $Path
    try {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    } catch {
        Write-SnapitLog "clear resume failed: $($_.Exception.Message)"
    }
}

function New-SnapitScheduledTask {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Schedule,
        [string]$ProfileName = 'default',
        [string]$Name = ''
    )
    $cleanText = $Text.Trim()
    $cleanSchedule = $Schedule.Trim()
    if (-not $cleanText) { return [pscustomobject]@{ Ok = $false; Output = ''; Error = 'Task text cannot be empty.' } }
    if (-not $cleanSchedule) { return [pscustomobject]@{ Ok = $false; Output = ''; Error = 'Schedule cannot be empty.' } }

    $hermes = Get-HermesExe
    if (-not $hermes) { return [pscustomobject]@{ Ok = $false; Output = ''; Error = 'hermes.exe was not found.' } }
    if (-not $Name.Trim()) {
        $firstLine = @($cleanText -split "`r?`n")[0].Trim()
        if ($firstLine.Length -gt 52) { $firstLine = $firstLine.Substring(0, 52).TrimEnd() + '...' }
        $Name = 'SnapIt - ' + $firstLine
    }

    try {
        $arguments = @('-p', $ProfileName, 'cron', 'create', $cleanSchedule, $cleanText, '--name', $Name, '--deliver', 'local')
        $output = (& $hermes @arguments 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
        if ($exitCode -eq 0) {
            Write-SnapitLog "focus task scheduled: profile=$ProfileName schedule=$cleanSchedule"
            return [pscustomobject]@{ Ok = $true; Output = $output; Error = '' }
        }
        Write-SnapitLog "focus schedule failed: exit=$exitCode output=$output"
        return [pscustomobject]@{ Ok = $false; Output = $output; Error = ("Hermes cron exited with code {0}." -f $exitCode) }
    } catch {
        Write-SnapitLog "focus schedule exception: $($_.Exception.Message)"
        return [pscustomobject]@{ Ok = $false; Output = ''; Error = $_.Exception.Message }
    }
}

# ----------------------------------------------------------------- job creation
function New-SnapitJob {
    param([string]$ImagePath)
    $snapHome = Get-SnapitHome
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $job = Join-Path $snapHome ("jobs\{0}" -f $stamp)
    New-Item -ItemType Directory -Path $job -Force | Out-Null
    $meta = @{ createdAt = (Get-Date).ToString('o'); image = $ImagePath }
    ($meta | ConvertTo-Json) | Set-Content -Path (Join-Path $job 'meta.json') -Encoding UTF8
    return $job
}

# ----------------------------------------------------------------- dispatch (director) prompt factory
function Get-DispatchText {
    param(
        [string]$ImagePath,
        [string]$ImprovedPrompt,
        [string]$ProfileName
    )
    $request = $ImprovedPrompt
    if (-not $request.Trim()) {
        $request = "Inspect the image at $ImagePath (the capture) and act on what the user marked or highlighted there; if no marks exist, infer the single most plausible task from the visible content and execute it."
    }
    return @"
SNAPIT DISPATCH - Hermes agent task (you are the ACTIVE agent)

A capture was just made on this PC with SnapIt. You are the active agent for the
task below: understand it, then EXECUTE it yourself with your tools. Do not merely
describe how it could be done.

Image attached to this message: $ImagePath
(also available as env SNAPIT_IMG; job folder as env SNAPIT_JOB)

How to read the capture:
- Rectangles, ellipses and pointer marks drawn by the user highlight what the
  capture is about; treat their position and content as context, not decoration.
- Any text the user typed in the capture is the user's own note -- highest
  priority signal.
- Visible on-screen text (errors, titles, values) is the real state of the app or
  system the task refers to.

User's request (already improved and rewritten from the raw capture):
-----BEGIN REQUEST-----
$request
-----END REQUEST-----

Working rules:
1. Inspect the image first; ground every step in what is actually visible.
2. If something critical is ambiguous, pick the most reasonable interpretation,
   state it in ONE line, then continue. Do not stall asking questions.
3. Prefer safe, reversible steps. If the request risks destructive or system-wide
   change, do it in the least invasive way and clearly report what you changed.
4. Execute to completion, verify the outcome, then finish with a short summary in
   the same language the user used in the capture (Spanish by default).
"@
}

# ----------------------------------------------------------------- executor launch (visible agent terminal)
function Start-HermesExecutor {
    param(
        [string]$ProfileName,
        [string]$ImagePath,
        [string]$ImprovedPrompt,
        $Config
    )
    $hermes = Get-HermesExe
    if (-not $hermes) { Write-SnapitLog 'no hermes.exe'; return $false }
    $job = New-SnapitJob -ImagePath $ImagePath
    $dispatch = Get-DispatchText -ImagePath $ImagePath -ImprovedPrompt $ImprovedPrompt -ProfileName $ProfileName
    $dispatchFile = Join-Path $job 'dispatch.txt'
    $dispatch | Set-Content -Path $dispatchFile -Encoding UTF8

    $profiles = Get-HermesProfiles
    $prof = $profiles | Where-Object { $_.Name -eq $ProfileName } | Select-Object -First 1
    $workDir = $env:USERPROFILE
    $wdMode = 'profile'
    if ($Config -and $Config.executorWorkdir) { $wdMode = [string]$Config.executorWorkdir }
    if ($prof -and $wdMode -eq 'profile') {
        $ws = Join-Path $prof.Home 'workspace'
        if (Test-Path $ws) { $workDir = $ws } else { $workDir = $prof.Home }
    }

    $flags = ''
    if ($Config -and $Config.executorAutoApprove) { $flags = '--yolo --accept-hooks' }
    $autoResumeLiteral = '$true'
    if ($Config -and (Get-SnapitValue -Item $Config -Name 'executorAutoResume' -Default $true) -eq $false) {
        $autoResumeLiteral = '$false'
    }
    $useWindow = $true
    if ($Config -and ($Config.executorWindow -eq $false -or [string]$Config.executorWindow -eq 'False')) { $useWindow = $false }

    $esc = { param($s) return $s.Replace("'", "''") }
    $imgQ  = & $esc $ImagePath
    $jobQ  = & $esc $job
    $profQ = & $esc $ProfileName
    $hermQ = & $esc $hermes
    $dispQ = & $esc $dispatchFile

    $runner = Join-Path $job 'run-agent.ps1'
    $runnerBody = @"
`$ErrorActionPreference = 'Continue'
Write-Host ''
Write-Host '  SnapIt -> Hermes agent: $profQ' -ForegroundColor Cyan
Write-Host '  capture : $imgQ' -ForegroundColor DarkGray
Write-Host '  job     : $jobQ' -ForegroundColor DarkGray
Write-Host '  (Ctrl+C or closing this window aborts the agent run)' -ForegroundColor DarkGray
Write-Host ''
`$env:SNAPIT_JOB = '$jobQ'
`$env:SNAPIT_IMG = '$imgQ'
`$sessionId = ''
& '$hermQ' -p '$profQ' chat -q (Get-Content -Raw '$dispQ') --image '$imgQ' $flags 2>&1 | ForEach-Object {
    `$line = [string]`$_
    `$resumeMatch = [regex]::Match(`$line, 'hermes\s+--resume\s+([A-Za-z0-9_-]+)')
    if (`$resumeMatch.Success) {
        `$sessionId = `$resumeMatch.Groups[1].Value
        Write-Host '  Resume this session with:' -ForegroundColor DarkGray
        Write-Host ("  hermes -p '$profQ' chat --resume " + `$sessionId + " -q '<nuevo prompt>' $flags") -ForegroundColor Yellow
    } else {
        Write-Host `$line
    }
}
`$runExit = `$LASTEXITCODE
Write-Host ''
if ($autoResumeLiteral -and `$sessionId) {
    Write-Host ("  Agent run finished (exit " + `$runExit + '). Resuming interactively with --yolo...') -ForegroundColor Green
    Write-Host ("  hermes -p '$profQ' chat --resume " + `$sessionId + " $flags") -ForegroundColor Cyan
    Write-Host ''
    & '$hermQ' -p '$profQ' chat --resume `$sessionId $flags
} else {
    Write-Host '  Agent run finished. (window stays open - close when done)' -ForegroundColor Green
    Write-Host ''
}
"@
    $runnerBody | Set-Content -Path $runner -Encoding UTF8
    Write-SnapitLog "launch executor: $ProfileName job=$job window=$useWindow"

    if ($useWindow) {
        $terminalHost = [string](Get-SnapitValue -Item $Config -Name 'terminalHost' -Default 'wave')
        $waveLaunched = $false
        if ($terminalHost -eq 'wave') {
            $wsh = Get-Command wsh -ErrorAction SilentlyContinue
            if ($wsh) {
                try {
                    $waveArgs = @('run', '-m', '--cwd', $workDir, '--', 'powershell.exe', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner)
                    $wavePsi = New-Object System.Diagnostics.ProcessStartInfo
                    $wavePsi.FileName = $wsh.Source
                    $wavePsi.Arguments = (($waveArgs | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
                    $wavePsi.UseShellExecute = $false
                    $wavePsi.CreateNoWindow = $true
                    $waveProcess = [System.Diagnostics.Process]::Start($wavePsi)
                    if ($waveProcess.WaitForExit(15000) -and $waveProcess.ExitCode -eq 0) {
                        $waveLaunched = $true
                        Write-SnapitLog "executor opened in Wave: $ProfileName"
                    }
                } catch {
                    Write-SnapitLog "Wave launch failed; using PowerShell window: $($_.Exception.Message)"
                }
            }
        }
        if (-not $waveLaunched) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) -WorkingDirectory $workDir | Out-Null
        }
    } else {
        $log = Join-Path $job 'agent.out.log'
        $argL = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $runner)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = (($argL | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WorkingDirectory = $workDir
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()
        $p.StandardOutput.ReadToEndAsync() | Out-Null
        $p.StandardError.ReadToEndAsync() | Out-Null
        Start-Sleep -Milliseconds 300
    }
    return $true
}

# ----------------------------------------------------------------- spoken-text executor launch
function Start-HermesTextExecutor {
    param(
        [string]$ProfileName,
        [string]$ImprovedPrompt,
        $Config
    )
    $hermes = Get-HermesExe
    if (-not $hermes -or -not $ImprovedPrompt.Trim()) { return $false }
    $job = New-SnapitJob -ImagePath ''
    $dispatch = @"
CAMARITA VOICE DISPATCH - Hermes agent task

You are the active agent for the spoken task below. Execute it with your tools; do not merely describe a plan. Verify the real outcome. Use Spanish by default. For destructive, financial, public, account-changing, or irreversible actions, request explicit confirmation before the side effect.

-----BEGIN REQUEST-----
$ImprovedPrompt
-----END REQUEST-----
"@
    $dispatchFile = Join-Path $job 'dispatch.txt'
    $dispatch | Set-Content -Path $dispatchFile -Encoding UTF8
    $profiles = Get-HermesProfiles
    $prof = $profiles | Where-Object { $_.Name -eq $ProfileName } | Select-Object -First 1
    $workDir = $env:USERPROFILE
    if ($prof) {
        $ws = Join-Path $prof.Home 'workspace'
        if (Test-Path $ws) { $workDir = $ws } else { $workDir = $prof.Home }
    }
    $esc = { param($s) return $s.Replace("'", "''") }
    $hermQ = & $esc $hermes
    $profQ = & $esc $ProfileName
    $dispQ = & $esc $dispatchFile
    $jobQ = & $esc $job
    $flags = ''
    if ($Config -and (ConvertTo-SnapitBool (Get-SnapitValue -Item $Config -Name 'executorAutoApprove' -Default $true))) { $flags = '--yolo --accept-hooks' }
    $autoResumeLiteral = '$true'
    if ($Config -and -not (ConvertTo-SnapitBool (Get-SnapitValue -Item $Config -Name 'executorAutoResume' -Default $true))) {
        $autoResumeLiteral = '$false'
    }
    $runner = Join-Path $job 'run-voice-agent.ps1'
    $runnerBody = @"
`$ErrorActionPreference = 'Continue'
Write-Host ''
Write-Host '  Camarita -> Hermes agent: $profQ' -ForegroundColor Cyan
Write-Host '  job: $jobQ' -ForegroundColor DarkGray
Write-Host ''
`$env:SNAPIT_JOB = '$jobQ'
`$sessionId = ''
& '$hermQ' -p '$profQ' chat -q (Get-Content -Raw '$dispQ') $flags 2>&1 | ForEach-Object {
    `$line = [string]`$_
    `$resumeMatch = [regex]::Match(`$line, 'hermes\s+--resume\s+([A-Za-z0-9_-]+)')
    if (`$resumeMatch.Success) {
        `$sessionId = `$resumeMatch.Groups[1].Value
        Write-Host '  Resume this session with:' -ForegroundColor DarkGray
        Write-Host ("  hermes -p '$profQ' chat --resume " + `$sessionId + " -q '<nuevo prompt>' $flags") -ForegroundColor Yellow
    } else {
        Write-Host `$line
    }
}
`$runExit = `$LASTEXITCODE
Write-Host ''
if ($autoResumeLiteral -and `$sessionId) {
    Write-Host ("  Voice task finished (exit " + `$runExit + '). Resuming interactively with --yolo...') -ForegroundColor Green
    Write-Host ("  hermes -p '$profQ' chat --resume " + `$sessionId + " $flags") -ForegroundColor Cyan
    Write-Host ''
    & '$hermQ' -p '$profQ' chat --resume `$sessionId $flags
} else {
    Write-Host '  Voice task finished.' -ForegroundColor Green
}
"@
    $runnerBody | Set-Content -Path $runner -Encoding UTF8
    $waveLaunched = $false
    $terminalHost = [string](Get-SnapitValue -Item $Config -Name 'terminalHost' -Default 'wave')
    if ($terminalHost -eq 'wave') {
        $wsh = Get-Command wsh -ErrorAction SilentlyContinue
        if ($wsh) {
            try {
                $waveArgs = @('run', '-m', '--cwd', $workDir, '--', 'powershell.exe', '-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner)
                $waveResult = Invoke-ExternalProcess -FileName $wsh.Source -Arguments $waveArgs -WorkingDirectory $workDir -TimeoutSeconds 20
                $waveLaunched = $waveResult.Ok
            } catch {}
        }
    }
    if (-not $waveLaunched) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) -WorkingDirectory $workDir | Out-Null
    }
    Write-SnapitLog "focus executor opened: $ProfileName job=$job wave=$waveLaunched"
    return $true
}

# ----------------------------------------------------------------- web prefill (DeepSeek route)
function Invoke-SnapitWebPrefill {
    param(
        [string]$Prompt,
        $Config,
        [string]$JobDir
    )
    $node = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
    if (-not $node) {
        $cand = Join-Path $env:LOCALAPPDATA 'OpenDesign\toolchains\dsh\node-v24.19.0-win-x64\node.exe'
        if (Test-Path $cand) { $node = $cand }
    }
    $edge = $null
    foreach ($p in @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
                     'C:\Program Files\Microsoft\Edge\Application\msedge.exe')) {
        if (Test-Path $p) { $edge = $p; break }
    }
    $script = Join-Path $PSScriptRoot 'snapit-prefill.mjs'
    if (-not $node -or -not $edge -or -not (Test-Path $script)) {
        Write-SnapitLog "prefill prereqs missing (node=$node edge=$edge script=$(Test-Path $script))"
        return [pscustomobject]@{ Ok = $false; Reason = 'missing-prereqs'; PromptCopied = $false }
    }

    $snapHome = Get-SnapitHome
    if (-not $JobDir) { $JobDir = New-SnapitJob -ImagePath '' }
    $textFile = Join-Path $JobDir 'web_prompt.txt'
    $Prompt | Set-Content -Path $textFile -Encoding UTF8
    $url = 'http://127.0.0.1:18080'
    if ($Config -and $Config.webUrl) { $url = [string]$Config.webUrl }

    $r = Invoke-ExternalProcess -FileName $node -Arguments @($script, '--text-file', $textFile, '--url', $url, '--edge', $edge) -WorkingDirectory (Split-Path $node -Parent) -TimeoutSeconds 90
    Write-SnapitLog "prefill exit=$($r.ExitCode) out=$($r.Stdout) err=$($r.Stderr)"

    # always keep the prompt on the clipboard as the reliable fallback
    $copied = $false
    try { Set-Clipboard -Value $Prompt; $copied = $true } catch {}
    return [pscustomobject]@{
        Ok           = $r.Ok
        Reason       = $r.Stderr
        PromptCopied = $copied
        Detail       = $r.Stdout
    }
}
