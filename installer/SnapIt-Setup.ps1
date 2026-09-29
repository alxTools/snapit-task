# =====================================================================
#  SnapIt - graphical installer (Windows PowerShell 5.1 + WPF)
#
#  A visual, click-through setup wizard for SnapIt:
#    1. Bienvenida   - what SnapIt is and what the wizard will do
#    2. Requisitos   - live check of every prerequisite
#    3. Modelos      - ADD THE MODELS / PROVIDERS SnapIt needs (the key step)
#    4. Opciones     - autostart, hotkey, web destination, agent autonomy
#    5. Instalar     - runs setup.ps1 and streams the log
#    6. Listo        - launch SnapIt right away
#
#  Nothing here needs administrator rights: everything is written under
#  %USERPROFILE%\.snapit and %LOCALAPPDATA%\hermes.
#
#  Run it:
#    powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\SnapIt-Setup.ps1
#  or just double-click "Instalar SnapIt.cmd" in the repository root.
#
#  Automation / verification switches:
#    -SelfTest    non-GUI checks (catalog, parsers, paths) then exit
#    -SmokeTest   builds the whole window, renders it and closes; exit code
#                 is 0 when every control was created
#    -Unattended  console-only install (no GUI) - good for CI and remote boxes
#    -CapturePages <dir>  render every wizard page to a PNG (docs + UI checks)
#
#  ASCII-only source on purpose: every emoji and box glyph is built at
#  runtime from codepoints, so PowerShell 5.1 never misreads the encoding.
# =====================================================================
#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Unattended,
    [switch]$AutoStart,
    [switch]$SkipLaunch,
    [switch]$SkipProfileClone,
    [switch]$SelfTest,
    [switch]$SmokeTest,
    [string]$CapturePages = '',
    [string]$Hotkey = '',
    [string]$WebUrl = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------- paths / glue
$script:Root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $script:Root 'snapit.ps1'))) { $script:Root = $PSScriptRoot }
$script:Glue = Join-Path $script:Root 'lib\snapit-hermes.ps1'
if (-not (Test-Path $script:Glue)) {
    Write-Host ('[X] No encuentro lib\snapit-hermes.ps1 junto al instalador (' + $script:Glue + ')') -ForegroundColor Red
    exit 2
}
. $script:Glue

$script:NL = [string][char]13 + [string][char]10
$script:SnapitLogFile = Join-Path (Get-SnapitHome) 'logs\snapit.log'
$script:LogFile = Join-Path (Get-SnapitHome) 'logs\install.log'
# Declared up front so the headless (-Unattended) path can log and run child
# processes without tripping StrictMode: the GUI fills these in later.
$script:LogBox = $null
$script:Window = $null

try { Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml } catch {}
try { Add-Type -AssemblyName System.Windows.Forms } catch {}

# =====================================================================
#  logging
# =====================================================================
function Write-SetupLog {
    param([string]$Message, [string]$Kind = 'info')
    $stamp = (Get-Date).ToString('HH:mm:ss')
    $line = '[' + $stamp + '] ' + $Message
    try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch {}
    if ($script:LogBox) {
        try {
            $script:LogBox.AppendText($line + $script:NL)
            $script:LogBox.ScrollToEnd()
        } catch {}
    }
    switch ($Kind) {
        'error' { Write-Host $line -ForegroundColor Red }
        'warn'  { Write-Host $line -ForegroundColor Yellow }
        'ok'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

# =====================================================================
#  provider catalog - the canonical Hermes provider ids and the env var
#  each one reads its API key from (mirrors hermes_cli/auth.py PROVIDER_REGISTRY)
# =====================================================================
function Get-SnapitProviderCatalog {
    return @(
        [pscustomobject]@{ Id='nous';           Label='Nous Portal (login en navegador)'; Env='';                        Kind='login';    KeyUrl='https://portal.nousresearch.com';        Note='Recomendado si no tienes claves: abre el navegador y elige un modelo Nous.' }
        [pscustomobject]@{ Id='openai-api';     Label='OpenAI (API key)';                  Env='OPENAI_API_KEY';           Kind='api-key';  KeyUrl='https://platform.openai.com/api-keys';   Note='Modelos GPT con vision.' }
        [pscustomobject]@{ Id='anthropic';      Label='Anthropic Claude';                  Env='ANTHROPIC_API_KEY';        Kind='api-key';  KeyUrl='https://console.anthropic.com/settings/keys'; Note='Claude entiende imagenes muy bien.' }
        [pscustomobject]@{ Id='gemini';         Label='Google Gemini';                     Env='GEMINI_API_KEY';           Kind='api-key';  KeyUrl='https://aistudio.google.com/apikey';     Note='Tiene capa gratuita y vision.' }
        [pscustomobject]@{ Id='deepseek';       Label='DeepSeek';                          Env='DEEPSEEK_API_KEY';         Kind='api-key';  KeyUrl='https://platform.deepseek.com/api_keys'; Note='Barato y rapido.' }
        [pscustomobject]@{ Id='openrouter';     Label='OpenRouter (muchos modelos)';       Env='OPENROUTER_API_KEY';       Kind='api-key';  KeyUrl='https://openrouter.ai/keys';             Note='Una sola clave para cientos de modelos.' }
        [pscustomobject]@{ Id='xai';            Label='xAI Grok';                          Env='XAI_API_KEY';              Kind='api-key';  KeyUrl='https://console.x.ai';                   Note='' }
        [pscustomobject]@{ Id='kimi-coding';    Label='Moonshot Kimi';                     Env='KIMI_API_KEY';             Kind='api-key';  KeyUrl='https://platform.moonshot.ai/console/api-keys'; Note='' }
        [pscustomobject]@{ Id='zai';            Label='Z.ai GLM';                          Env='GLM_API_KEY';              Kind='api-key';  KeyUrl='https://open.bigmodel.cn';               Note='' }
        [pscustomobject]@{ Id='minimax';        Label='MiniMax';                           Env='MINIMAX_API_KEY';          Kind='api-key';  KeyUrl='https://platform.minimaxi.com';          Note='' }
        [pscustomobject]@{ Id='alibaba';        Label='Alibaba Qwen (DashScope)';          Env='DASHSCOPE_API_KEY';        Kind='api-key';  KeyUrl='https://bailian.console.aliyun.com';     Note='' }
        [pscustomobject]@{ Id='nvidia';         Label='NVIDIA NIM';                        Env='NVIDIA_API_KEY';           Kind='api-key';  KeyUrl='https://build.nvidia.com';               Note='' }
        [pscustomobject]@{ Id='huggingface';    Label='Hugging Face';                      Env='HF_TOKEN';                 Kind='api-key';  KeyUrl='https://huggingface.co/settings/tokens'; Note='' }
        [pscustomobject]@{ Id='ollama-cloud';   Label='Ollama Cloud';                      Env='OLLAMA_API_KEY';           Kind='api-key';  KeyUrl='https://ollama.com/settings/keys';       Note='' }
        [pscustomobject]@{ Id='lmstudio';       Label='LM Studio (modelo local)';          Env='LM_API_KEY';               Kind='api-key';  KeyUrl='http://127.0.0.1:1234';                  Note='Sin coste: corre en tu PC. Necesita un modelo con vision cargado.' }
        [pscustomobject]@{ Id='azure-foundry';  Label='Azure AI Foundry';                  Env='AZURE_FOUNDRY_API_KEY';    Kind='api-key';  KeyUrl='https://ai.azure.com';                   Note='' }
        [pscustomobject]@{ Id='vertex';         Label='Google Vertex AI';                  Env='';                         Kind='login';    KeyUrl='https://cloud.google.com/vertex-ai';     Note='Usa login de Google Cloud.' }
        [pscustomobject]@{ Id='copilot';        Label='GitHub Copilot';                    Env='COPILOT_GITHUB_TOKEN';     Kind='api-key';  KeyUrl='https://github.com/settings/tokens';     Note='' }
    )
}

function Get-SnapitProviderById {
    param([string]$Id)
    foreach ($p in (Get-SnapitProviderCatalog)) { if ($p.Id -eq $Id) { return $p } }
    return $null
}

# =====================================================================
#  hermes introspection helpers
# =====================================================================
function Get-HermesEnvPath {
    $hermes = Get-HermesExe
    if ($hermes) {
        try {
            $r = Invoke-ExternalProcess -FileName $hermes -Arguments @('config','env-path') -TimeoutSeconds 60
            if ($r.Ok) {
                $cand = @(([string]$r.Stdout) -split ([string][char]10) | Where-Object { $_.Trim() -ne '' })
                if ($cand.Count -gt 0) {
                    $p = ([string]$cand[$cand.Count - 1]).Trim()
                    if ($p -match '[\\/]') { return $p }
                }
            }
        } catch {}
    }
    $fallback = Join-Path $env:LOCALAPPDATA 'hermes\.env'
    return $fallback
}

function Get-HermesEnvMap {
    param([string]$Path)
    $map = @{}
    if ($Path -and (Test-Path $Path)) {
        foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
            if ($line -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
                $map[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
            }
        }
    }
    return $map
}

function Set-HermesEnvValue {
    param([string]$Path, [string]$Name, [string]$Value)
    if (-not $Path) { throw 'ruta de .env desconocida' }
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (Test-Path $Path) {
        $backup = $Path + '.snapit-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -Path $Path -Destination $backup -Force -ErrorAction SilentlyContinue
    }
    $lines = @()
    if (Test-Path $Path) { $lines = @([System.IO.File]::ReadAllLines($Path)) }
    $pattern = '^\s*' + [regex]::Escape($Name) + '\s*='
    $found = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { $lines[$i] = $Name + '=' + $Value; $found = $true }
    }
    if (-not $found) {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -ne '') { $lines += '' }
        $lines += '# Anadido por el instalador de SnapIt'
        $lines += ($Name + '=' + $Value)
    }
    [System.IO.File]::WriteAllLines($Path, $lines, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Get-HermesModelInfo {
    $info = [pscustomobject]@{ Ok = $false; Provider = ''; Model = ''; Detail = '' }
    $hermes = Get-HermesExe
    if (-not $hermes) { $info.Detail = 'hermes.exe no encontrado'; return $info }
    try {
        $r = Invoke-ExternalProcess -FileName $hermes -Arguments @('config','get','model','--json') -TimeoutSeconds 60
        if ($r.Ok -and ([string]$r.Stdout).Trim() -ne '') {
            $json = ([string]$r.Stdout).Trim()
            $obj = $json | ConvertFrom-Json
            $provider = ''
            $model = ''
            if ($obj.PSObject.Properties['provider']) { $provider = [string]$obj.provider }
            if ($obj.PSObject.Properties['default']) { $model = [string]$obj.default }
            if (-not $model -and $obj.PSObject.Properties['name']) { $model = [string]$obj.name }
            $info.Provider = $provider
            $info.Model = $model
            $info.Ok = (($provider -ne '') -or ($model -ne ''))
            $info.Detail = ($provider + ' / ' + $model)
            return $info
        }
    } catch {}
    try {
        $r2 = Invoke-ExternalProcess -FileName $hermes -Arguments @('config','get','model') -TimeoutSeconds 60
        if ($r2.Ok) {
            foreach ($line in (([string]$r2.Stdout) -split ([string][char]10))) {
                if ($line -match '^\s*provider\s*:\s*(.+)$') { $info.Provider = $Matches[1].Trim() }
                if ($line -match '^\s*default\s*:\s*(.+)$') { $info.Model = $Matches[1].Trim() }
            }
            $info.Ok = (($info.Provider -ne '') -or ($info.Model -ne ''))
            $info.Detail = ($info.Provider + ' / ' + $info.Model)
        }
    } catch {}
    return $info
}

function Set-SnapitDefaultModel {
    param([string]$Provider, [string]$Model)
    $hermes = Get-HermesExe
    if (-not $hermes) { return [pscustomobject]@{ Ok = $false; Detail = 'hermes.exe no encontrado' } }
    $work = Split-Path $hermes -Parent
    $notes = @()
    if ($Provider) {
        $r = Invoke-ExternalProcess -FileName $hermes -Arguments @('config','set','model.provider',$Provider) -TimeoutSeconds 90 -WorkingDirectory $work
        $notes += ('model.provider=' + $Provider + ' (exit ' + $r.ExitCode + ')')
        if (-not $r.Ok) { return [pscustomobject]@{ Ok = $false; Detail = (($notes -join '; ') + ' ' + ([string]$r.Stderr).Trim()) } }
    }
    if ($Model) {
        $r2 = Invoke-ExternalProcess -FileName $hermes -Arguments @('config','set','model.default',$Model) -TimeoutSeconds 90 -WorkingDirectory $work
        $notes += ('model.default=' + $Model + ' (exit ' + $r2.ExitCode + ')')
        if (-not $r2.Ok) { return [pscustomobject]@{ Ok = $false; Detail = (($notes -join '; ') + ' ' + ([string]$r2.Stderr).Trim()) } }
    }
    return [pscustomobject]@{ Ok = $true; Detail = ($notes -join '; ') }
}

function Add-SnapitProviderCredential {
    param([string]$Provider, [string]$ApiKey, [string]$EnvName, [string]$Label = '')
    $hermes = Get-HermesExe
    $fallbackNote = ''
    if ($hermes) {
        try {
            $cliArgs = @('auth','add',$Provider,'--type','api-key','--api-key',$ApiKey)
            if ($Label) { $cliArgs += @('--label', $Label) }
            $r = Invoke-ExternalProcess -FileName $hermes -Arguments $cliArgs -TimeoutSeconds 180 -WorkingDirectory (Split-Path $hermes -Parent)
            if ($r.Ok) {
                return [pscustomobject]@{ Ok = $true; Method = 'hermes auth add'; Detail = ('credencial guardada para ' + $Provider) }
            }
            $fallbackNote = ('hermes auth add no acepto la credencial: ' + (([string]$r.Stderr + ' ' + [string]$r.Stdout).Trim()))
        } catch {
            $fallbackNote = ('hermes auth add fallo: ' + $_.Exception.Message)
        }
    }
    if (-not $EnvName) {
        return [pscustomobject]@{ Ok = $false; Method = ''; Detail = ($fallbackNote + ' | este proveedor no usa clave en .env') }
    }
    try {
        $envPath = Get-HermesEnvPath
        [void](Set-HermesEnvValue -Path $envPath -Name $EnvName -Value $ApiKey)
        return [pscustomobject]@{ Ok = $true; Method = '.env'; Detail = ($EnvName + ' guardado en ' + $envPath + $(if ($fallbackNote) { ' | ' + $fallbackNote } else { '' })) }
    } catch {
        return [pscustomobject]@{ Ok = $false; Method = ''; Detail = ($fallbackNote + ' | ' + $_.Exception.Message) }
    }
}

function Test-ConfiguredProviders {
    $map = Get-HermesEnvMap -Path (Get-HermesEnvPath)
    $list = @()
    foreach ($p in (Get-SnapitProviderCatalog)) {
        if (-not $p.Env) { continue }
        $has = $map.ContainsKey($p.Env) -and ([string]$map[$p.Env]).Trim() -ne ''
        $list += [pscustomobject]@{ Id = $p.Id; Label = $p.Label; Env = $p.Env; Configured = $has }
    }
    return $list
}

# =====================================================================
#  prerequisites
# =====================================================================
function Get-SnapitPrereqReport {
    $rows = @()

    $os = 'Windows'
    try { $os = [System.Environment]::OSVersion.VersionString } catch {}
    $rows += [pscustomobject]@{ Key='os'; Name='Windows 10/11'; Ok=$true; Required=$true; Detail=$os; Hint='SnapIt usa WPF y atajos globales de Windows.' }

    $psv = ''
    try { $psv = $PSVersionTable.PSVersion.ToString() } catch {}
    $rows += [pscustomobject]@{ Key='ps'; Name='Windows PowerShell 5.1'; Ok=$true; Required=$true; Detail=$psv; Hint='Viene con Windows; no hay que instalar nada.' }

    $hermes = Get-HermesExe
    $rows += [pscustomobject]@{
        Key='hermes'; Name='Hermes Agent CLI'; Ok=[bool]$hermes; Required=$true
        Detail=$(if ($hermes) { $hermes } else { 'no encontrado' })
        Hint='SnapIt usa Hermes para mejorar el prompt y para ejecutar los agentes. Instala Hermes y vuelve a abrir este instalador.'
    }

    $model = Get-HermesModelInfo
    $rows += [pscustomobject]@{
        Key='model'; Name='Modelo de Hermes configurado'; Ok=[bool]$model.Ok; Required=$true
        Detail=$(if ($model.Ok) { $model.Detail } else { 'sin proveedor/modelo por defecto' })
        Hint='Paso 3 de este asistente: agrega un proveedor y elige el modelo. SnapIt necesita un modelo que VEA imagenes.'
    }

    $node = $null
    try {
        $c = Get-Command node.exe -ErrorAction SilentlyContinue
        if ($c) { $node = $c.Source }
    } catch {}
    if (-not $node) {
        $cand = Join-Path $env:LOCALAPPDATA 'OpenDesign\toolchains\dsh\node-v24.19.0-win-x64\node.exe'
        if (Test-Path $cand) { $node = $cand }
    }
    $nodeVersion = ''
    if ($node) {
        try {
            $r = Invoke-ExternalProcess -FileName $node -Arguments @('-v') -TimeoutSeconds 30
            if ($r.Ok) { $nodeVersion = ([string]$r.Stdout).Trim() }
        } catch {}
    }
    $rows += [pscustomobject]@{
        Key='node'; Name='Node.js 22 o superior (opcional)'; Ok=[bool]$node; Required=$false
        Detail=$(if ($node) { ($nodeVersion + '  ' + $node) } else { 'no encontrado' })
        Hint='Solo hace falta para pegar el prompt automaticamente en la web (ruta DeepSeek). Sin Node, SnapIt copia el prompt al portapapeles.'
    }

    $edge = @(
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    $rows += [pscustomobject]@{
        Key='edge'; Name='Microsoft Edge (opcional)'; Ok=[bool]$edge; Required=$false
        Detail=$(if ($edge) { $edge } else { 'no encontrado' })
        Hint='Solo se usa para abrir el destino web en una ventana aislada. Viene con Windows.'
    }

    return $rows
}

# =====================================================================
#  process runner that keeps the window alive (pumps the message loop)
# =====================================================================
function Invoke-PumpedProcess {
    param(
        [string]$FileName,
        [string[]]$CliArgs = @(),
        [string]$WorkingDirectory = '',
        [int]$TimeoutSeconds = 900,
        [scriptblock]$OnLine = $null
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    $psi.Arguments = (($CliArgs | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $outSb = New-Object System.Text.StringBuilder
    $errSb = New-Object System.Text.StringBuilder
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $timedOut = $false
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadLineAsync()
    $errTask = $proc.StandardError.ReadLineAsync()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ($true) {
        $busy = $false
        if ($outTask -and $outTask.IsCompleted) {
            $line = $outTask.Result
            if ($null -eq $line) { $outTask = $null } else {
                [void]$outSb.AppendLine($line)
                if ($OnLine) { & $OnLine $line }
                $outTask = $proc.StandardOutput.ReadLineAsync()
            }
            $busy = $true
        }
        if ($errTask -and $errTask.IsCompleted) {
            $line = $errTask.Result
            if ($null -eq $line) { $errTask = $null } else {
                [void]$errSb.AppendLine($line)
                if ($OnLine) { & $OnLine $line }
                $errTask = $proc.StandardError.ReadLineAsync()
            }
            $busy = $true
        }
        if (-not $busy) {
            $done = $false
            try { $done = $proc.HasExited } catch { $done = $true }
            if ($done -and (-not $outTask) -and (-not $errTask)) { break }
            Start-Sleep -Milliseconds 40
        }
        if ($script:Window) { try { [System.Windows.Forms.Application]::DoEvents() } catch {} }
        if ((Get-Date) -gt $deadline) {
            $timedOut = $true
            try { $proc.Kill() } catch {}
            break
        }
    }
    try { $proc.WaitForExit(5000) | Out-Null } catch {}
    $code = -1
    try { $code = $proc.ExitCode } catch {}
    return [pscustomobject]@{
        Ok       = (($code -eq 0) -and (-not $timedOut))
        ExitCode = $code
        Stdout   = $outSb.ToString()
        Stderr   = $errSb.ToString()
        TimedOut = $timedOut
    }
}

function Start-SnapitConsoleCommand {
    param([string]$Command)
    $full = '-NoExit -NoProfile -ExecutionPolicy Bypass -Command "' + ($Command -replace '"', '\"') + '"'
    try { Start-Process -FilePath 'powershell.exe' -ArgumentList $full | Out-Null; return $true } catch { return $false }
}

# =====================================================================
#  the actual install work (shared by the GUI and -Unattended)
# =====================================================================
function Get-SnapitInstallPlan {
    param([hashtable]$Options)
    $steps = @()
    $steps += [pscustomobject]@{ Id='config';   Title='Preparar carpetas y configuracion'; Kind='native' }
    if (-not $Options.SkipProfileClone) {
        $steps += [pscustomobject]@{ Id='profile'; Title='Crear el perfil Hermes "snapit"'; Kind='setup' }
    }
    $steps += [pscustomobject]@{ Id='autostart'; Title='Configurar el arranque con Windows'; Kind='setup' }
    $steps += [pscustomobject]@{ Id='verify';   Title='Verificar la instalacion'; Kind='verify' }
    return $steps
}

function Invoke-SnapitConfigStep {
    param([hashtable]$Options)
    [void](Get-SnapitHome)
    $cfg = Get-SnapitConfig
    if ($Options.Hotkey) { $cfg['hotkey'] = [string]$Options.Hotkey }
    if ($Options.WebUrl) {
        $cfg['webUrl'] = [string]$Options.WebUrl
        $eps = @($cfg['endpoints'])
        if ($eps.Count -gt 0) {
            $first = $eps[0]
            if ($first -is [System.Collections.IDictionary]) { $first['url'] = [string]$Options.WebUrl }
            elseif ($null -ne $first -and $first.PSObject.Properties['url']) { $first.url = [string]$Options.WebUrl }
        }
    }
    if ($null -ne $Options.AutoApprove) { $cfg['executorAutoApprove'] = [bool]$Options.AutoApprove }
    if ($Options.ContainsKey('VoiceAgentId') -and $Options['VoiceAgentId']) { $cfg['voiceAgentId'] = [string]$Options['VoiceAgentId'] }
    Save-SnapitConfig $cfg
    Write-SetupLog ('configuracion escrita en ' + (Join-Path (Get-SnapitHome) 'config.json')) 'ok'
    Write-SetupLog ('  atajo de captura: ' + [string]$cfg['hotkey'])
    Write-SetupLog ('  destino web:      ' + [string]$cfg['webUrl'])
    return $true
}

function Invoke-SnapitInstall {
    param([hashtable]$Options)
    $results = @()

    # ---- step 1: native config
    try {
        [void](Invoke-SnapitConfigStep -Options $Options)
        $results += [pscustomobject]@{ Id='config'; Ok=$true; Detail='carpetas y config.json listos' }
    } catch {
        $results += [pscustomobject]@{ Id='config'; Ok=$false; Detail=$_.Exception.Message }
    }

    # ---- step 2: setup.ps1 (profile clone + SOUL + optional autostart)
    $setup = Join-Path $script:Root 'setup.ps1'
    $setupArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$setup)
    if ($Options.SkipProfileClone) { $setupArgs += '-SkipProfileClone' }
    if ($Options.AutoStart) { $setupArgs += '-AutoStart' }
    Write-SetupLog ('ejecutando: powershell ' + (($setupArgs | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' '))
    try {
        $r = Invoke-PumpedProcess -FileName 'powershell.exe' -CliArgs $setupArgs -WorkingDirectory $script:Root -TimeoutSeconds 900 -OnLine {
            param($line)
            if (([string]$line).Trim() -ne '') { Write-SetupLog ('  ' + ([string]$line).Trim()) }
        }
        if ($r.Ok) {
            $results += [pscustomobject]@{ Id='setup'; Ok=$true; Detail='setup.ps1 completo' }
        } else {
            $results += [pscustomobject]@{ Id='setup'; Ok=$false; Detail=('setup.ps1 termino con codigo ' + $r.ExitCode + $(if ($r.TimedOut) { ' (tiempo agotado)' } else { '' })) }
        }
    } catch {
        $results += [pscustomobject]@{ Id='setup'; Ok=$false; Detail=$_.Exception.Message }
    }

    # ---- step 2b: optional ElevenLabs credential for the voice call
    if ($Options.ContainsKey('VoiceApiKey') -and $Options['VoiceApiKey']) {
        try {
            $envPath = Get-HermesEnvPath
            [void](Set-HermesEnvValue -Path $envPath -Name 'ELEVENLABS_API_KEY' -Value ([string]$Options['VoiceApiKey']))
            Write-SetupLog ('ELEVENLABS_API_KEY guardada en ' + $envPath) 'ok'
            $results += [pscustomobject]@{ Id='voice'; Ok=$true; Detail='credencial de voz guardada' }
        } catch {
            $results += [pscustomobject]@{ Id='voice'; Ok=$false; Detail=$_.Exception.Message }
        }
    }

    # ---- step 3: verify
    $hermes = Get-HermesExe
    if ($hermes -and -not $Options.SkipProfileClone) {
        try {
            $v = Invoke-PumpedProcess -FileName $hermes -CliArgs @('-p','snapit','--version') -WorkingDirectory (Split-Path $hermes -Parent) -TimeoutSeconds 180
            $first = @((([string]$v.Stdout) -split ([string][char]10)) | Where-Object { $_.Trim() -ne '' })
            $txt = $(if ($first.Count -gt 0) { $first[0].Trim() } else { 'sin salida' })
            Write-SetupLog ('perfil snapit responde: ' + $txt) $(if ($v.Ok) { 'ok' } else { 'warn' })
            $results += [pscustomobject]@{ Id='verify'; Ok=[bool]$v.Ok; Detail=$txt }
        } catch {
            $results += [pscustomobject]@{ Id='verify'; Ok=$false; Detail=$_.Exception.Message }
        }
    } else {
        $results += [pscustomobject]@{ Id='verify'; Ok=$true; Detail='perfil omitido' }
    }

    return $results
}

# =====================================================================
#  WPF building blocks
# =====================================================================
$script:Accent = '#E53935'
$script:Ink = '#1B1B22'
$script:Muted = '#6F6F78'
$script:Sidebar = '#17171F'
$script:SidebarText = '#C9C9D4'
$script:Line = '#E4E4EA'

function New-SnapitBrush {
    param([string]$Hex)
    try { return (New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))) }
    catch { return [System.Windows.Media.Brushes]::Transparent }
}

function New-SnapitText {
    param(
        [string]$Text,
        [double]$Size = 13,
        [string]$Color = '#1B1B22',
        [string]$Weight = 'Normal',
        [double]$WrapWidth = 0,
        [string]$Family = 'Segoe UI'
    )
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.FontSize = $Size
    $t.Foreground = (New-SnapitBrush $Color)
    $t.FontFamily = New-Object System.Windows.Media.FontFamily($Family)
    $fw = [System.Windows.FontWeights]::Normal
    if ($Weight -eq 'Bold') { $fw = [System.Windows.FontWeights]::Bold }
    elseif ($Weight -eq 'SemiBold') { $fw = [System.Windows.FontWeights]::SemiBold }
    elseif ($Weight -eq 'Light') { $fw = [System.Windows.FontWeights]::Light }
    $t.FontWeight = $fw
    if ($WrapWidth -gt 0) { $t.TextWrapping = [System.Windows.TextWrapping]::Wrap; $t.Width = $WrapWidth }
    $t.Margin = New-Object System.Windows.Thickness(0,0,0,4)
    return $t
}

function New-SnapitButton {
    param([string]$Text, [string]$Bg = '#EFEFF4', [string]$Fg = '#1B1B22', [double]$Width = 0)
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.FontSize = 13
    $b.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $b.Background = (New-SnapitBrush $Bg)
    $b.Foreground = (New-SnapitBrush $Fg)
    $b.BorderThickness = New-Object System.Windows.Thickness(0)
    $b.Padding = New-Object System.Windows.Thickness(16,8,16,8)
    $b.Margin = New-Object System.Windows.Thickness(0,4,8,4)
    $b.Cursor = [System.Windows.Input.Cursors]::Hand
    if ($Width -gt 0) { $b.Width = $Width }
    return $b
}

function New-SnapitTextBox {
    param([string]$Text = '', [double]$Width = 380)
    $t = New-Object System.Windows.Controls.TextBox
    $t.Text = $Text
    $t.Width = $Width
    $t.FontSize = 13
    $t.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $t.Padding = New-Object System.Windows.Thickness(8,6,8,6)
    $t.Margin = New-Object System.Windows.Thickness(0,3,0,8)
    $t.BorderBrush = (New-SnapitBrush '#D3D3DC')
    $t.BorderThickness = New-Object System.Windows.Thickness(1)
    $t.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    return $t
}

function New-SnapitPasswordBox {
    param([double]$Width = 380)
    $p = New-Object System.Windows.Controls.PasswordBox
    $p.Width = $Width
    $p.FontSize = 13
    $p.Padding = New-Object System.Windows.Thickness(8,6,8,6)
    $p.Margin = New-Object System.Windows.Thickness(0,3,0,8)
    $p.BorderBrush = (New-SnapitBrush '#D3D3DC')
    $p.BorderThickness = New-Object System.Windows.Thickness(1)
    $p.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    return $p
}

function New-SnapitCombo {
    param([double]$Width = 380)
    $c = New-Object System.Windows.Controls.ComboBox
    $c.Width = $Width
    $c.FontSize = 13
    $c.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $c.Padding = New-Object System.Windows.Thickness(6,4,6,4)
    $c.Margin = New-Object System.Windows.Thickness(0,3,0,10)
    $c.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
    return $c
}

function New-SnapitCheck {
    param([string]$Text, [bool]$Checked = $false)
    $c = New-Object System.Windows.Controls.CheckBox
    $c.Content = $Text
    $c.IsChecked = $Checked
    $c.FontSize = 13
    $c.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')
    $c.Foreground = (New-SnapitBrush $script:Ink)
    $c.Margin = New-Object System.Windows.Thickness(0,6,0,6)
    return $c
}

function New-SnapitCard {
    param([string]$Title, [string]$Subtitle = '')
    $border = New-Object System.Windows.Controls.Border
    $border.Background = (New-SnapitBrush '#FFFFFF')
    $border.BorderBrush = (New-SnapitBrush $script:Line)
    $border.BorderThickness = New-Object System.Windows.Thickness(1)
    $border.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $border.Padding = New-Object System.Windows.Thickness(16,14,16,14)
    $border.Margin = New-Object System.Windows.Thickness(0,0,0,12)
    $stack = New-Object System.Windows.Controls.StackPanel
    if ($Title) { [void]$stack.Children.Add((New-SnapitText -Text $Title -Size 15 -Weight 'SemiBold')) }
    if ($Subtitle) { [void]$stack.Children.Add((New-SnapitText -Text $Subtitle -Size 12 -Color $script:Muted -WrapWidth 640)) }
    $border.Child = $stack
    $border.Tag = $stack
    return $border
}

function Get-SnapitCardBody {
    param($Card)
    return $Card.Tag
}

# =====================================================================
#  GUI
# =====================================================================
function Show-SnapitSetupWindow {
    $script:LogBox = $null
    $script:PageIndex = 0
    $script:Pages = @()
    $script:StepItems = @()
    $script:InstallDone = $false
    $script:LastLogLine = ''

    $catalog = Get-SnapitProviderCatalog
    $cfg = Get-SnapitConfig

    # ---------------------------------------------------------- window
    $win = New-Object System.Windows.Window
    $script:Window = $win
    $win.Title = 'SnapIt - Instalador'
    $win.Width = 1000
    $win.Height = 680
    $win.MinWidth = 900
    $win.MinHeight = 620
    $win.WindowStartupLocation = [System.Windows.WindowStartupLocation]::CenterScreen
    $win.Background = (New-SnapitBrush '#F6F6F9')
    $win.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe UI')

    $rootGrid = New-Object System.Windows.Controls.Grid
    $colSide = New-Object System.Windows.Controls.ColumnDefinition
    $colSide.Width = New-Object System.Windows.GridLength(248)
    $colMain = New-Object System.Windows.Controls.ColumnDefinition
    $colMain.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    [void]$rootGrid.ColumnDefinitions.Add($colSide)
    [void]$rootGrid.ColumnDefinitions.Add($colMain)
    $rowBody = New-Object System.Windows.Controls.RowDefinition
    $rowBody.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $rowFoot = New-Object System.Windows.Controls.RowDefinition
    $rowFoot.Height = New-Object System.Windows.GridLength(72)
    [void]$rootGrid.RowDefinitions.Add($rowBody)
    [void]$rootGrid.RowDefinitions.Add($rowFoot)
    $win.Content = $rootGrid

    # ---------------------------------------------------------- sidebar
    $side = New-Object System.Windows.Controls.Border
    $side.Background = (New-SnapitBrush $script:Sidebar)
    [System.Windows.Controls.Grid]::SetColumn($side, 0)
    [System.Windows.Controls.Grid]::SetRow($side, 0)
    [System.Windows.Controls.Grid]::SetRowSpan($side, 2)
    $sideStack = New-Object System.Windows.Controls.StackPanel
    $sideStack.Margin = New-Object System.Windows.Thickness(22,26,18,18)
    $side.Child = $sideStack
    [void]$rootGrid.Children.Add($side)

    $brand = New-SnapitText -Text 'SnapIt' -Size 26 -Weight 'Bold' -Color '#FFFFFF'
    $brand.Margin = New-Object System.Windows.Thickness(0,0,0,2)
    [void]$sideStack.Children.Add($brand)
    $tagline = New-SnapitText -Text 'captura -> prompt -> agente' -Size 11 -Color '#8C8C9C'
    $tagline.Margin = New-Object System.Windows.Thickness(0,0,0,26)
    [void]$sideStack.Children.Add($tagline)

    $stepTitles = @('Bienvenida','Requisitos','Modelos','Opciones','Instalar','Listo')
    for ($i = 0; $i -lt $stepTitles.Count; $i++) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = [System.Windows.Controls.Orientation]::Horizontal
        $row.Margin = New-Object System.Windows.Thickness(0,5,0,5)
        $num = New-SnapitText -Text ([string]($i + 1)) -Size 11 -Weight 'SemiBold' -Color $script:SidebarText
        $num.Width = 22
        $num.Margin = New-Object System.Windows.Thickness(0,1,0,0)
        $lbl = New-SnapitText -Text $stepTitles[$i] -Size 13 -Color $script:SidebarText
        [void]$row.Children.Add($num)
        [void]$row.Children.Add($lbl)
        [void]$sideStack.Children.Add($row)
        $script:StepItems += [pscustomobject]@{ Row = $row; Num = $num; Label = $lbl }
    }

    $sideFoot = New-SnapitText -Text ('v1.0  -  ' + $script:Root) -Size 10 -Color '#6A6A7A' -WrapWidth 200
    $sideFoot.Margin = New-Object System.Windows.Thickness(0,30,0,0)
    [void]$sideStack.Children.Add($sideFoot)

    # ---------------------------------------------------------- page host
    $pageHost = New-Object System.Windows.Controls.Grid
    $pageHost.Margin = New-Object System.Windows.Thickness(0)
    [System.Windows.Controls.Grid]::SetColumn($pageHost, 1)
    [System.Windows.Controls.Grid]::SetRow($pageHost, 0)
    [void]$rootGrid.Children.Add($pageHost)

    function New-SnapitPage {
        param([string]$Title, [string]$Subtitle)
        $scroll = New-Object System.Windows.Controls.ScrollViewer
        $scroll.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
        $scroll.Padding = New-Object System.Windows.Thickness(30,26,30,20)
        $scroll.Visibility = [System.Windows.Visibility]::Collapsed
        $stack = New-Object System.Windows.Controls.StackPanel
        $h = New-SnapitText -Text $Title -Size 24 -Weight 'Bold'
        $h.Margin = New-Object System.Windows.Thickness(0,0,0,6)
        [void]$stack.Children.Add($h)
        if ($Subtitle) {
            $s = New-SnapitText -Text $Subtitle -Size 13 -Color $script:Muted -WrapWidth 660
            $s.Margin = New-Object System.Windows.Thickness(0,0,0,18)
            [void]$stack.Children.Add($s)
        }
        $scroll.Content = $stack
        [void]$pageHost.Children.Add($scroll)
        $script:Pages += $scroll
        return $stack
    }

    # ======================================================= PAGE 1
    $p1 = New-SnapitPage -Title 'Bienvenido a SnapIt' -Subtitle 'Un atajo, una captura y un agente que ya sabe que hacer.'
    $card1 = New-SnapitCard -Title 'Que hace SnapIt' -Subtitle 'Alt+Shift+S abre el recorte de pantalla. Marcas lo importante, escribes tu idea en una linea y SnapIt la convierte en un prompt preciso para el agente que elijas.'
    [void](Get-SnapitCardBody $card1).Children.Add((New-SnapitText -Text '  1.  Alt+Shift+S  ->  seleccionas la zona de la pantalla' -Size 13))
    [void](Get-SnapitCardBody $card1).Children.Add((New-SnapitText -Text '  2.  marcas con puntero, texto, rectangulo o circulo' -Size 13))
    [void](Get-SnapitCardBody $card1).Children.Add((New-SnapitText -Text '  3.  Hermes reescribe tu intencion en un prompt limpio' -Size 13))
    [void](Get-SnapitCardBody $card1).Children.Add((New-SnapitText -Text '  4.  eliges destino: terminal (agente) o web (DeepSeek/DSH)' -Size 13))
    [void]$p1.Children.Add($card1)

    $card1b = New-SnapitCard -Title 'Que va a hacer este asistente' -Subtitle 'Todo se queda en tu PC. No se envia nada a ningun servicio.'
    [void](Get-SnapitCardBody $card1b).Children.Add((New-SnapitText -Text 'Revisa los requisitos, te ayuda a AGREGAR LOS MODELOS que SnapIt necesita, escribe la configuracion, crea el perfil de agente "snapit" y deja todo listo.' -Size 13 -WrapWidth 640))
    [void]$p1.Children.Add($card1b)

    $card1c = New-SnapitCard -Title 'Lo mas importante: el modelo' -Subtitle 'SnapIt le manda tu captura a un modelo. Ese modelo tiene que VER imagenes.'
    [void](Get-SnapitCardBody $card1c).Children.Add((New-SnapitText -Text 'En el paso 3 puedes pegar una API key de cualquier proveedor (OpenAI, Anthropic, Gemini, DeepSeek, OpenRouter, LM Studio local...) o iniciar sesion con Nous Portal. El asistente guarda la credencial y te deja elegir el modelo por defecto.' -Size 13 -WrapWidth 640))
    [void]$p1.Children.Add($card1c)

    # ======================================================= PAGE 2
    $p2 = New-SnapitPage -Title 'Requisitos' -Subtitle 'Comprobacion en vivo de tu PC. Lo marcado como obligatorio tiene que estar en verde para que SnapIt funcione.'
    $reqCard = New-SnapitCard -Title 'Estado del sistema'
    $reqBody = Get-SnapitCardBody $reqCard
    $script:ReqPanel = New-Object System.Windows.Controls.StackPanel
    [void]$reqBody.Children.Add($script:ReqPanel)
    $btnRecheck = New-SnapitButton -Text 'Volver a comprobar' -Bg '#EFEFF4'
    $btnRecheck.add_Click({
        try { Update-SnapitPrereqUI } catch { }
    })
    [void]$reqBody.Children.Add($btnRecheck)
    [void]$p2.Children.Add($reqCard)

    $reqHelp = New-SnapitCard -Title 'Si algo sale en rojo'
    [void](Get-SnapitCardBody $reqHelp).Children.Add((New-SnapitText -Text 'Hermes Agent es el motor: SnapIt lo usa para mejorar el prompt y para lanzar los agentes. Instalalo y vuelve a abrir este instalador.' -Size 13 -WrapWidth 640))
    [void](Get-SnapitCardBody $reqHelp).Children.Add((New-SnapitText -Text 'Node.js y Edge son opcionales: solo mejoran la ruta web. Sin ellos SnapIt copia el prompt al portapapeles y abre la pagina igual.' -Size 13 -WrapWidth 640))
    [void]$p2.Children.Add($reqHelp)

    # ======================================================= PAGE 3 (MODELS)
    $p3 = New-SnapitPage -Title 'Agregar los modelos' -Subtitle 'Este es el paso que hace que SnapIt piense. Elige un proveedor, pega su API key y define el modelo por defecto.'

    $statusCard = New-SnapitCard -Title 'Estado actual de Hermes'
    $statusBody = Get-SnapitCardBody $statusCard
    $script:ModelStatusText = New-SnapitText -Text 'comprobando...' -Size 14 -Weight 'SemiBold'
    [void]$statusBody.Children.Add($script:ModelStatusText)
    $script:KeyStatusText = New-SnapitText -Text '' -Size 12 -Color $script:Muted -WrapWidth 640
    [void]$statusBody.Children.Add($script:KeyStatusText)
    $btnRefresh = New-SnapitButton -Text 'Refrescar estado'
    $btnRefresh.add_Click({ try { Update-SnapitModelUI } catch { } })
    [void]$statusBody.Children.Add($btnRefresh)
    [void]$p3.Children.Add($statusCard)

    $keyCard = New-SnapitCard -Title 'Paso A - Agregar un proveedor (API key)' -Subtitle 'Elige el proveedor, pega la clave y guarda. SnapIt ejecuta "hermes auth add"; si esa orden no esta disponible, escribe la clave en el .env de Hermes.'
    $keyBody = Get-SnapitCardBody $keyCard
    [void]$keyBody.Children.Add((New-SnapitText -Text 'Proveedor' -Size 12 -Weight 'SemiBold'))
    $script:ProviderCombo = New-SnapitCombo -Width 520
    foreach ($p in $catalog) {
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = ($p.Label + '   [' + $p.Id + ']')
        $item.Tag = $p.Id
        [void]$script:ProviderCombo.Items.Add($item)
    }
    $script:ProviderCombo.SelectedIndex = 0
    [void]$keyBody.Children.Add($script:ProviderCombo)
    $script:ProviderHint = New-SnapitText -Text '' -Size 12 -Color $script:Muted -WrapWidth 620
    [void]$keyBody.Children.Add($script:ProviderHint)
    [void]$keyBody.Children.Add((New-SnapitText -Text 'API key (se guarda en tu PC; nunca sale de aqui)' -Size 12 -Weight 'SemiBold'))
    $script:KeyBox = New-SnapitPasswordBox -Width 520
    [void]$keyBody.Children.Add($script:KeyBox)
    $keyButtons = New-Object System.Windows.Controls.StackPanel
    $keyButtons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnSaveKey = New-SnapitButton -Text 'Guardar credencial' -Bg $script:Accent -Fg '#FFFFFF'
    $btnOpenKeyUrl = New-SnapitButton -Text 'Abrir la pagina de la API key'
    $btnSaveKey.add_Click({
        try {
            $item = $script:ProviderCombo.SelectedItem
            $id = [string]$item.Tag
            $prov = Get-SnapitProviderById -Id $id
            $key = [string]$script:KeyBox.Password
            if (-not $prov) { $script:KeyStatusText.Text = 'Proveedor desconocido.'; return }
            if ($prov.Kind -eq 'login') {
                $script:KeyStatusText.Text = 'Este proveedor usa login en el navegador: usa el boton "Iniciar sesion / elegir modelo".'
                return
            }
            if ([string]::IsNullOrWhiteSpace($key)) { $script:KeyStatusText.Text = 'Pega primero la API key.'; return }
            $script:KeyStatusText.Text = 'Guardando...'
            $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
            $res = Add-SnapitProviderCredential -Provider $prov.Id -ApiKey $key -EnvName $prov.Env -Label 'SnapIt'
            $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
            if ($res.Ok) {
                $script:KeyBox.Password = ''
                $script:KeyStatusText.Text = ('OK - ' + $res.Method + ': ' + $res.Detail)
                Write-SetupLog ('credencial ' + $prov.Id + ' guardada via ' + $res.Method) 'ok'
            } else {
                $script:KeyStatusText.Text = ('No se pudo guardar: ' + $res.Detail)
                Write-SetupLog ('credencial ' + $prov.Id + ' fallo: ' + $res.Detail) 'error'
            }
            Update-SnapitModelUI
        } catch {
            $script:KeyStatusText.Text = ('Error: ' + $_.Exception.Message)
        }
    })
    $btnOpenKeyUrl.add_Click({
        try {
            $item = $script:ProviderCombo.SelectedItem
            $prov = Get-SnapitProviderById -Id ([string]$item.Tag)
            if ($prov -and $prov.KeyUrl) { Start-Process $prov.KeyUrl | Out-Null }
        } catch { }
    })
    [void]$keyButtons.Children.Add($btnSaveKey)
    [void]$keyButtons.Children.Add($btnOpenKeyUrl)
    [void]$keyBody.Children.Add($keyButtons)
    $script:ProviderCombo.add_SelectionChanged({
        try {
            $item = $script:ProviderCombo.SelectedItem
            if (-not $item) { return }
            $prov = Get-SnapitProviderById -Id ([string]$item.Tag)
            if (-not $prov) { return }
            $hint = 'Variable de entorno: ' + $(if ($prov.Env) { $prov.Env } else { 'no usa clave' })
            if ($prov.Note) { $hint = $hint + '  -  ' + $prov.Note }
            $script:ProviderHint.Text = $hint
        } catch { }
    })
    [void]$p3.Children.Add($keyCard)

    $defCard = New-SnapitCard -Title 'Paso B - Elegir el modelo por defecto' -Subtitle 'SnapIt lanza Hermes con el perfil por defecto para leer la captura. Escribe aqui el proveedor y el nombre exacto del modelo.'
    $defBody = Get-SnapitCardBody $defCard
    [void]$defBody.Children.Add((New-SnapitText -Text 'Proveedor por defecto' -Size 12 -Weight 'SemiBold'))
    $script:DefaultProviderBox = New-SnapitTextBox -Width 320
    [void]$defBody.Children.Add($script:DefaultProviderBox)
    [void]$defBody.Children.Add((New-SnapitText -Text 'Modelo por defecto (ejemplos: gpt-4o, claude-sonnet-4-5, gemini-2.5-flash, deepseek-chat)' -Size 12 -Weight 'SemiBold'))
    $script:DefaultModelBox = New-SnapitTextBox -Width 420
    [void]$defBody.Children.Add($script:DefaultModelBox)
    $defButtons = New-Object System.Windows.Controls.StackPanel
    $defButtons.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnApplyModel = New-SnapitButton -Text 'Aplicar modelo por defecto' -Bg '#1B1B22' -Fg '#FFFFFF'
    $btnTestModel = New-SnapitButton -Text 'Probar ahora'
    $btnOpenPicker = New-SnapitButton -Text 'Iniciar sesion / elegir modelo (hermes model)'
    $btnApplyModel.add_Click({
        try {
            $script:ModelStatusText.Text = 'Aplicando modelo...'
            $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
            $res = Set-SnapitDefaultModel -Provider ([string]$script:DefaultProviderBox.Text).Trim() -Model ([string]$script:DefaultModelBox.Text).Trim()
            $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
            if ($res.Ok) { Write-SetupLog ('modelo por defecto aplicado: ' + $res.Detail) 'ok' } else { Write-SetupLog ('no se pudo aplicar el modelo: ' + $res.Detail) 'error' }
            Update-SnapitModelUI
        } catch { Write-SetupLog ('error aplicando el modelo: ' + $_.Exception.Message) 'error' }
    })
    $btnTestModel.add_Click({
        try {
            $hermes = Get-HermesExe
            if (-not $hermes) { $script:ModelStatusText.Text = 'hermes.exe no encontrado.'; return }
            $script:ModelStatusText.Text = 'Probando el modelo (puede tardar)...'
            $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
            $profile = 'default'
            $res = Invoke-PumpedProcess -FileName $hermes -CliArgs @('-p',$profile,'chat','-Q','-q','Responde unicamente con: SNAPIT-OK') -WorkingDirectory (Split-Path $hermes -Parent) -TimeoutSeconds 180
            $script:Window.Cursor = [System.Windows.Input.Cursors]::Arrow
            $clean = ConvertTo-CleanHermesText ([string]$res.Stdout)
            if ($res.Ok -and $clean) {
                $script:ModelStatusText.Text = ('El modelo respondio: ' + $clean)
                Write-SetupLog ('prueba del modelo OK: ' + $clean) 'ok'
            } else {
                $script:ModelStatusText.Text = 'El modelo no respondio. Revisa la credencial y el nombre del modelo.'
                Write-SetupLog ('prueba del modelo fallo (exit ' + $res.ExitCode + '): ' + (([string]$res.Stderr).Trim())) 'error'
            }
        } catch { Write-SetupLog ('error probando el modelo: ' + $_.Exception.Message) 'error' }
    })
    $btnOpenPicker.add_Click({
        try {
            $hermes = Get-HermesExe
            if (-not $hermes) { Write-SetupLog 'hermes.exe no encontrado.' 'error'; return }
            $cmd = '& ' + (ConvertTo-CmdArg $hermes) + ' model'
            [void](Start-SnapitConsoleCommand -Command $cmd)
            Write-SetupLog 'se abrio una consola con "hermes model": elige proveedor y modelo ahi y luego pulsa Refrescar estado.' 'ok'
        } catch { Write-SetupLog ('no se pudo abrir hermes model: ' + $_.Exception.Message) 'error' }
    })
    [void]$defButtons.Children.Add($btnApplyModel)
    [void]$defButtons.Children.Add($btnTestModel)
    [void]$defButtons.Children.Add($btnOpenPicker)
    [void]$defBody.Children.Add($defButtons)
    [void]$p3.Children.Add($defCard)

    $visionCard = New-SnapitCard -Title 'Paso C - Comprobar la vision (importante)' -Subtitle 'SnapIt manda la captura como imagen. Si el modelo no ve imagenes, el prompt mejorado saldra vacio y SnapIt usara un texto generico.'
    [void](Get-SnapitCardBody $visionCard).Children.Add((New-SnapitText -Text 'Recomendados con vision: OpenAI gpt-4o / gpt-4.1, Anthropic claude-sonnet, Google gemini-2.5-flash, y cualquier modelo multimodal de OpenRouter.' -Size 13 -WrapWidth 640))
    [void](Get-SnapitCardBody $visionCard).Children.Add((New-SnapitText -Text 'Puedes cambiar SOLO el modelo del mejorador de prompts sin tocar el resto: en ~\.snapit\config.json pon "improverModel" con el nombre del modelo con vision.' -Size 13 -WrapWidth 640))
    [void]$p3.Children.Add($visionCard)

    # ======================================================= PAGE 4
    $p4 = New-SnapitPage -Title 'Opciones' -Subtitle 'Ajustes de SnapIt. Puedes cambiarlos despues desde el panel de administracion en la bandeja del sistema.'
    $optCard = New-SnapitCard -Title 'Preferencias'
    $optBody = Get-SnapitCardBody $optCard
    $script:OptAutoStart = New-SnapitCheck -Text 'Iniciar SnapIt al encender Windows (con vigilante que lo reinicia si se cae)' -Checked ([bool]$AutoStart)
    $script:OptClone = New-SnapitCheck -Text 'Crear el perfil Hermes "snapit" (recomendado: hereda tu perfil default)' -Checked (-not [bool]$SkipProfileClone)
    $script:OptAutoApprove = New-SnapitCheck -Text 'Que los agentes despachados trabajen sin pedir permiso (--yolo)' -Checked ([bool]$cfg['executorAutoApprove'])
    [void]$optBody.Children.Add($script:OptAutoStart)
    [void]$optBody.Children.Add($script:OptClone)
    [void]$optBody.Children.Add($script:OptAutoApprove)
    [void]$optBody.Children.Add((New-SnapitText -Text 'Si desmarcas lo de --yolo, cada agente te pedira confirmacion antes de tocar algo peligroso.' -Size 12 -Color $script:Muted -WrapWidth 640))
    [void]$optBody.Children.Add((New-SnapitText -Text 'Atajo de captura' -Size 12 -Weight 'SemiBold'))
    $script:OptHotkey = New-SnapitTextBox -Text $(if ($Hotkey) { $Hotkey } else { [string]$cfg['hotkey'] }) -Width 220
    [void]$optBody.Children.Add($script:OptHotkey)
    [void]$optBody.Children.Add((New-SnapitText -Text 'Destino web (se abre con el prompt ya escrito, sin enviar)' -Size 12 -Weight 'SemiBold'))
    $script:OptWebUrl = New-SnapitTextBox -Text $(if ($WebUrl) { $WebUrl } else { [string]$cfg['webUrl'] }) -Width 320
    [void]$optBody.Children.Add($script:OptWebUrl)
    [void]$p4.Children.Add($optCard)

    $voiceCard = New-SnapitCard -Title 'Voz (opcional)' -Subtitle 'Alt+Shift+A puede abrir una llamada de voz que entiende tu dictado y lo manda al agente. Necesita una cuenta de ElevenLabs.'
    $voiceBody = Get-SnapitCardBody $voiceCard
    [void]$voiceBody.Children.Add((New-SnapitText -Text 'ElevenLabs API key (se guarda en el .env de Hermes)' -Size 12 -Weight 'SemiBold'))
    $script:VoiceKeyBox = New-SnapitPasswordBox -Width 420
    [void]$voiceBody.Children.Add($script:VoiceKeyBox)
    [void]$voiceBody.Children.Add((New-SnapitText -Text 'ElevenLabs agent id (empieza con agent_)' -Size 12 -Weight 'SemiBold'))
    $script:VoiceAgentBox = New-SnapitTextBox -Text ([string]$cfg['voiceAgentId']) -Width 420
    [void]$voiceBody.Children.Add($script:VoiceAgentBox)
    [void]$voiceBody.Children.Add((New-SnapitText -Text 'Dejalo vacio si no usas voz: SnapIt funciona igual sin esta parte.' -Size 12 -Color $script:Muted -WrapWidth 640))
    [void]$p4.Children.Add($voiceCard)

    # ======================================================= PAGE 5
    $p5 = New-SnapitPage -Title 'Instalar' -Subtitle 'SnapIt escribe su configuracion, crea el perfil de agente y deja el arranque listo. Nada sale de tu PC.'
    $installCard = New-SnapitCard -Title 'Progreso'
    $installBody = Get-SnapitCardBody $installCard
    $btnInstall = New-SnapitButton -Text 'Instalar SnapIt' -Bg $script:Accent -Fg '#FFFFFF' -Width 200
    $script:InstallSummary = New-SnapitText -Text '' -Size 13 -Weight 'SemiBold' -WrapWidth 640
    $script:LogBox = New-Object System.Windows.Controls.TextBox
    $script:LogBox.IsReadOnly = $true
    $script:LogBox.AcceptsReturn = $true
    $script:LogBox.TextWrapping = [System.Windows.TextWrapping]::Wrap
    $script:LogBox.VerticalScrollBarVisibility = [System.Windows.Controls.ScrollBarVisibility]::Auto
    $script:LogBox.Height = 260
    $script:LogBox.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas')
    $script:LogBox.FontSize = 12
    $script:LogBox.Background = (New-SnapitBrush '#11111A')
    $script:LogBox.Foreground = (New-SnapitBrush '#D6F5D6')
    $script:LogBox.Padding = New-Object System.Windows.Thickness(10)
    $script:LogBox.Margin = New-Object System.Windows.Thickness(0,8,0,8)
    $btnInstall.add_Click({
        try {
            $btnInstall.IsEnabled = $false
            $script:InstallSummary.Text = 'Instalando...'
            $script:LogBox.Clear()
            $opts = @{
                Hotkey           = ([string]$script:OptHotkey.Text).Trim()
                WebUrl           = ([string]$script:OptWebUrl.Text).Trim()
                AutoStart        = [bool]$script:OptAutoStart.IsChecked
                AutoApprove      = [bool]$script:OptAutoApprove.IsChecked
                SkipProfileClone = (-not [bool]$script:OptClone.IsChecked)
                VoiceApiKey      = [string]$script:VoiceKeyBox.Password
                VoiceAgentId     = ([string]$script:VoiceAgentBox.Text).Trim()
            }
            Write-SetupLog 'iniciando instalacion de SnapIt'
            $results = Invoke-SnapitInstall -Options $opts
            $failed = @($results | Where-Object { -not $_.Ok })
            $script:InstallDone = ($failed.Count -eq 0)
            if ($script:InstallDone) {
                $script:InstallSummary.Text = 'Instalacion completa. Ya puedes usar Alt+Shift+S.'
            } else {
                $script:InstallSummary.Text = ('Termino con ' + $failed.Count + ' problema(s). Revisa el registro de arriba.')
            }
            $script:EnableFinish = $true
        } catch {
            $script:InstallSummary.Text = ('Error: ' + $_.Exception.Message)
            Write-SetupLog ('error de instalacion: ' + $_.Exception.Message) 'error'
        } finally {
            $btnInstall.IsEnabled = $true
        }
    })
    [void]$installBody.Children.Add($btnInstall)
    [void]$installBody.Children.Add($script:InstallSummary)
    [void]$installBody.Children.Add($script:LogBox)
    [void]$p5.Children.Add($installCard)

    # ======================================================= PAGE 6
    $p6 = New-SnapitPage -Title 'Listo' -Subtitle 'SnapIt queda en la bandeja del sistema esperando el atajo.'
    $doneCard = New-SnapitCard -Title 'Como se usa'
    [void](Get-SnapitCardBody $doneCard).Children.Add((New-SnapitText -Text '1.  Pulsa Alt+Shift+S en cualquier momento.' -Size 13))
    [void](Get-SnapitCardBody $doneCard).Children.Add((New-SnapitText -Text '2.  Marca o escribe lo que quieres (la nota de texto manda).' -Size 13))
    [void](Get-SnapitCardBody $doneCard).Children.Add((New-SnapitText -Text '3.  Enter para terminar la captura.' -Size 13))
    [void](Get-SnapitCardBody $doneCard).Children.Add((New-SnapitText -Text '4.  Elige destino: terminal (agente Hermes) o web (DeepSeek/DSH).' -Size 13))
    [void](Get-SnapitCardBody $doneCard).Children.Add((New-SnapitText -Text 'Alt+Shift+A abre el panel de escritura (Ultra Focus) con borradores y tareas programadas.' -Size 13))
    [void]$p6.Children.Add($doneCard)

    $doneCard2 = New-SnapitCard -Title 'Si algo no funciona'
    [void](Get-SnapitCardBody $doneCard2).Children.Add((New-SnapitText -Text 'Los registros estan en %USERPROFILE%\.snapit\logs\ (snapit.log e install.log).' -Size 13 -WrapWidth 640))
    [void](Get-SnapitCardBody $doneCard2).Children.Add((New-SnapitText -Text 'Panel de administracion: clic derecho en el icono de la bandeja -> "Admin panel - routes, endpoints, harnesses".' -Size 13 -WrapWidth 640))
    [void]$p6.Children.Add($doneCard2)

    $finishActions = New-Object System.Windows.Controls.StackPanel
    $finishActions.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $btnLaunch = New-SnapitButton -Text 'Iniciar SnapIt ahora' -Bg $script:Accent -Fg '#FFFFFF'
    $btnFolder = New-SnapitButton -Text 'Abrir la carpeta de datos'
    $btnGuide = New-SnapitButton -Text 'Ver la guia de instalacion'
    $btnLaunch.add_Click({
        try {
            $main = Join-Path $script:Root 'snapit.ps1'
            Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $main + '"') -WorkingDirectory $script:Root | Out-Null
            Write-SetupLog 'SnapIt lanzado.' 'ok'
        } catch { Write-SetupLog ('no se pudo lanzar SnapIt: ' + $_.Exception.Message) 'error' }
    })
    $btnFolder.add_Click({ try { Start-Process explorer.exe (Get-SnapitHome) | Out-Null } catch { } })
    $btnGuide.add_Click({
        try {
            $guide = Join-Path $script:Root 'docs\INSTALACION.md'
            if (Test-Path $guide) { Start-Process $guide | Out-Null } else { Start-Process (Join-Path $script:Root 'README.md') | Out-Null }
        } catch { }
    })
    [void]$finishActions.Children.Add($btnLaunch)
    [void]$finishActions.Children.Add($btnFolder)
    [void]$finishActions.Children.Add($btnGuide)
    [void]$p6.Children.Add($finishActions)

    # ---------------------------------------------------------- footer
    $foot = New-Object System.Windows.Controls.Border
    $foot.Background = (New-SnapitBrush '#FFFFFF')
    $foot.BorderBrush = (New-SnapitBrush $script:Line)
    $foot.BorderThickness = New-Object System.Windows.Thickness(0,1,0,0)
    [System.Windows.Controls.Grid]::SetColumn($foot, 1)
    [System.Windows.Controls.Grid]::SetRow($foot, 1)
    $footGrid = New-Object System.Windows.Controls.Grid
    $footGrid.Margin = New-Object System.Windows.Thickness(30,0,30,0)
    $fc1 = New-Object System.Windows.Controls.ColumnDefinition
    $fc1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $fc2 = New-Object System.Windows.Controls.ColumnDefinition
    $fc2.Width = New-Object System.Windows.GridLength(0, [System.Windows.GridUnitType]::Auto)
    [void]$footGrid.ColumnDefinitions.Add($fc1)
    [void]$footGrid.ColumnDefinitions.Add($fc2)
    $foot.Child = $footGrid
    $script:FootStatus = New-SnapitText -Text '' -Size 12 -Color $script:Muted
    $script:FootStatus.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($script:FootStatus, 0)
    [void]$footGrid.Children.Add($script:FootStatus)
    $navStack = New-Object System.Windows.Controls.StackPanel
    $navStack.Orientation = [System.Windows.Controls.Orientation]::Horizontal
    $navStack.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
    [System.Windows.Controls.Grid]::SetColumn($navStack, 1)
    [void]$footGrid.Children.Add($navStack)
    $btnBack = New-SnapitButton -Text 'Atras'
    $btnNext = New-SnapitButton -Text 'Siguiente' -Bg $script:Accent -Fg '#FFFFFF' -Width 120
    [void]$navStack.Children.Add($btnBack)
    [void]$navStack.Children.Add($btnNext)
    [void]$rootGrid.Children.Add($foot)

    function Show-SnapitPage {
        param([int]$Index)
        if ($Index -lt 0) { $Index = 0 }
        if ($Index -ge $script:Pages.Count) { $Index = $script:Pages.Count - 1 }
        $script:PageIndex = $Index
        for ($i = 0; $i -lt $script:Pages.Count; $i++) {
            if ($i -eq $Index) { $script:Pages[$i].Visibility = [System.Windows.Visibility]::Visible }
            else { $script:Pages[$i].Visibility = [System.Windows.Visibility]::Collapsed }
        }
        for ($i = 0; $i -lt $script:StepItems.Count; $i++) {
            if ($i -eq $Index) {
                $script:StepItems[$i].Num.Foreground = (New-SnapitBrush $script:Accent)
                $script:StepItems[$i].Label.Foreground = (New-SnapitBrush '#FFFFFF')
                $script:StepItems[$i].Label.FontWeight = [System.Windows.FontWeights]::SemiBold
            } elseif ($i -lt $Index) {
                $script:StepItems[$i].Num.Foreground = (New-SnapitBrush '#7ED07E')
                $script:StepItems[$i].Label.Foreground = (New-SnapitBrush $script:SidebarText)
                $script:StepItems[$i].Label.FontWeight = [System.Windows.FontWeights]::Normal
            } else {
                $script:StepItems[$i].Num.Foreground = (New-SnapitBrush '#6A6A7A')
                $script:StepItems[$i].Label.Foreground = (New-SnapitBrush '#8C8C9C')
                $script:StepItems[$i].Label.FontWeight = [System.Windows.FontWeights]::Normal
            }
        }
        $btnBack.IsEnabled = ($Index -gt 0)
        if ($Index -eq ($script:Pages.Count - 1)) { $btnNext.Content = 'Cerrar' } else { $btnNext.Content = 'Siguiente' }
        $script:FootStatus.Text = ('Paso ' + ($Index + 1) + ' de ' + $script:Pages.Count)
        if ($Index -eq 1) { try { Update-SnapitPrereqUI } catch { } }
        if ($Index -eq 2) { try { Update-SnapitModelUI } catch { } }
        if ($Index -eq 4) { try { Seed-SnapitInstallLog } catch { } }
    }

    function Update-SnapitPrereqUI {
        $script:ReqPanel.Children.Clear()
        $rows = Get-SnapitPrereqReport
        foreach ($row in $rows) {
            $line = New-Object System.Windows.Controls.StackPanel
            $line.Orientation = [System.Windows.Controls.Orientation]::Horizontal
            $line.Margin = New-Object System.Windows.Thickness(0,4,0,4)
            $mark = $(if ($row.Ok) { '[ OK ]' } elseif ($row.Required) { '[FALTA]' } else { '[ -- ]' })
            $markColor = $(if ($row.Ok) { '#1E8E3E' } elseif ($row.Required) { '#C5221F' } else { '#B08500' })
            $m = New-SnapitText -Text $mark -Size 11 -Weight 'Bold' -Color $markColor -Family 'Consolas'
            $m.Width = 64
            $m.Margin = New-Object System.Windows.Thickness(0,2,6,0)
            $n = New-SnapitText -Text $row.Name -Size 13 -Weight 'SemiBold'
            $n.Width = 260
            $d = New-SnapitText -Text ([string]$row.Detail) -Size 12 -Color $script:Muted -WrapWidth 380
            [void]$line.Children.Add($m)
            [void]$line.Children.Add($n)
            [void]$line.Children.Add($d)
            [void]$script:ReqPanel.Children.Add($line)
            if (-not $row.Ok) {
                $hint = New-SnapitText -Text ('        ' + $row.Hint) -Size 11 -Color '#8A6D00' -WrapWidth 620
                [void]$script:ReqPanel.Children.Add($hint)
            }
        }
    }

    function Update-SnapitModelUI {
        $info = Get-HermesModelInfo
        if (-not (Get-HermesExe)) {
            $script:ModelStatusText.Text = 'Hermes Agent no esta instalado.'
            $script:ModelStatusText.Foreground = (New-SnapitBrush '#C5221F')
        } elseif ($info.Ok) {
            $script:ModelStatusText.Text = ('Proveedor: ' + $info.Provider + '    Modelo: ' + $info.Model)
            $script:ModelStatusText.Foreground = (New-SnapitBrush '#1E8E3E')
        } else {
            $script:ModelStatusText.Text = 'Hermes no tiene modelo por defecto todavia.'
            $script:ModelStatusText.Foreground = (New-SnapitBrush '#B08500')
        }
        if (-not [string]$script:DefaultProviderBox.Text) { $script:DefaultProviderBox.Text = [string]$info.Provider }
        if (-not [string]$script:DefaultModelBox.Text) { $script:DefaultModelBox.Text = [string]$info.Model }
        $configured = @(Test-ConfiguredProviders | Where-Object { $_.Configured })
        if ($configured.Count -gt 0) {
            $script:KeyStatusText.Text = ('Proveedores con credencial guardada: ' + (($configured | ForEach-Object { $_.Id }) -join ', '))
        } else {
            $script:KeyStatusText.Text = 'Todavia no hay ninguna API key guardada.'
        }
    }

    function Seed-SnapitInstallLog {
        if ($script:InstallDone) { return }
        if ([string]$script:LogBox.Text -ne '') { return }
        Write-SetupLog 'Listo para instalar. Pulsa "Instalar SnapIt".'
        Write-SetupLog ('Carpeta de SnapIt: ' + $script:Root)
        Write-SetupLog ('Datos y registros: ' + (Get-SnapitHome))
        $info = Get-HermesModelInfo
        if ($info.Ok) { Write-SetupLog ('Modelo detectado: ' + $info.Detail) 'ok' }
        else { Write-SetupLog 'Aviso: no hay modelo por defecto en Hermes. SnapIt funcionara pero el prompt mejorado usara texto generico.' 'warn' }
    }

    $btnBack.add_Click({ try { Show-SnapitPage -Index ($script:PageIndex - 1) } catch { } })
    $btnNext.add_Click({
        try {
            if ($script:PageIndex -ge ($script:Pages.Count - 1)) {
                if (-not $SkipLaunch -and $script:InstallDone) {
                    try {
                        $main = Join-Path $script:Root 'snapit.ps1'
                        Start-Process -FilePath 'powershell.exe' -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "' + $main + '"') -WorkingDirectory $script:Root | Out-Null
                    } catch { }
                }
                $script:Window.Close()
                return
            }
            if ($script:PageIndex -eq 1) {
                $rows = @(Get-SnapitPrereqReport | Where-Object { $_.Required -and -not $_.Ok })
                if ($rows.Count -gt 0) {
                    $names = ($rows | ForEach-Object { $_.Name }) -join ', '
                    $answer = [System.Windows.MessageBox]::Show(
                        ('Falta lo siguiente: ' + $names + [Environment]::NewLine + [Environment]::NewLine + 'Puedes continuar igual, pero SnapIt no funcionara completo hasta resolverlo.' + [Environment]::NewLine + [Environment]::NewLine + 'Continuar de todos modos?'),
                        'Requisitos pendientes',
                        [System.Windows.MessageBoxButton]::YesNo,
                        [System.Windows.MessageBoxImage]::Warning)
                    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
                }
            }
            Show-SnapitPage -Index ($script:PageIndex + 1)
        } catch { }
    })

    # ---------------------------------------------------------- go
    Show-SnapitPage -Index 0
    try { Update-SnapitPrereqUI } catch { }
    try { Update-SnapitModelUI } catch { }

    if ($SmokeTest) {
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(1200)
        $timer.add_Tick({
            try {
                $timer.Stop()
                [void]$script:Window.UpdateLayout()
                Write-Host ('LAYOUT|window=' + [int]$script:Window.ActualWidth + 'x' + [int]$script:Window.ActualHeight)
                Write-Host ('LAYOUT|steps=' + $script:StepItems.Count + ' pages=' + $script:Pages.Count)
                Write-Host ('LAYOUT|nav back=' + [int]$btnBack.ActualWidth + ' next=' + [int]$btnNext.ActualWidth + ' foot=' + [int]$script:FootStatus.ActualWidth)
                for ($i = 0; $i -lt $script:Pages.Count; $i++) {
                    Show-SnapitPage -Index $i
                    [void]$script:Window.UpdateLayout()
                    $page = $script:Pages[$i]
                    $body = $page.Content
                    Write-Host ('LAYOUT|page' + ($i + 1) + '=' + [int]$page.ActualWidth + 'x' + [int]$page.ActualHeight + ' children=' + $body.Children.Count + ' scrollable=' + [int]$page.ScrollableHeight)
                }
                Show-SnapitPage -Index 0
                [void]$script:Window.UpdateLayout()
                Write-Host 'SMOKE PASS: window, pages and navigation built'
            } catch {
                Write-Host ('SMOKE FAIL: ' + $_.Exception.Message)
            }
            try { $script:Window.Close() } catch { }
        })
        $timer.Start()
    }

    if ($CapturePages) {
        $win.Show()
        [void]$win.UpdateLayout()
        $shotDir = $CapturePages
        if (-not [System.IO.Path]::IsPathRooted($shotDir)) { $shotDir = Join-Path $script:Root $shotDir }
        if (-not (Test-Path $shotDir)) { New-Item -ItemType Directory -Path $shotDir -Force | Out-Null }
        for ($i = 0; $i -lt $script:Pages.Count; $i++) {
            Show-SnapitPage -Index $i
            [void]$win.UpdateLayout()
            try { [void]$win.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Render, [Action]{ }) } catch { }
            try { [System.Windows.Forms.Application]::DoEvents() } catch { }
            $w = [int]$win.ActualWidth
            $h = [int]$win.ActualHeight
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32))
            $rtb.Render($win)
            $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
            $file = Join-Path $shotDir ('step' + ($i + 1) + '.png')
            $stream = [System.IO.File]::Create($file)
            $encoder.Save($stream)
            $stream.Close()
            Write-Host ('CAPTURED|' + $file)
        }
        $win.Close()
        $script:Window = $null
        return $true
    }

    [void]$win.ShowDialog()
    $script:Window = $null
    return $true
}

# =====================================================================
#  non-GUI modes
# =====================================================================
function Invoke-SnapitUnattended {
    Write-Host ''
    Write-Host '  SnapIt - instalacion sin interfaz' -ForegroundColor Cyan
    Write-Host '  =================================' -ForegroundColor Cyan
    $rows = Get-SnapitPrereqReport
    foreach ($row in $rows) {
        $mark = $(if ($row.Ok) { '[ OK ]' } else { '[FALTA]' })
        $color = $(if ($row.Ok) { 'Green' } elseif ($row.Required) { 'Red' } else { 'Yellow' })
        Write-Host ('  ' + $mark + ' ' + $row.Name + ' :: ' + $row.Detail) -ForegroundColor $color
    }
    $opts = @{
        Hotkey           = $Hotkey
        WebUrl           = $WebUrl
        AutoStart        = [bool]$AutoStart
        AutoApprove      = $null
        SkipProfileClone = [bool]$SkipProfileClone
        VoiceApiKey      = ''
        VoiceAgentId     = ''
    }
    $results = Invoke-SnapitInstall -Options $opts
    $failed = @($results | Where-Object { -not $_.Ok })
    Write-Host ''
    foreach ($r in $results) {
        $color = $(if ($r.Ok) { 'Green' } else { 'Red' })
        Write-Host ('  ' + $(if ($r.Ok) { '[ OK ]' } else { '[FALLA]' }) + ' ' + $r.Id + ' :: ' + $r.Detail) -ForegroundColor $color
    }
    Write-Host ''
    if ($failed.Count -eq 0) { Write-Host '  Instalacion completa.' -ForegroundColor Green; return 0 }
    Write-Host ('  Termino con ' + $failed.Count + ' problema(s).') -ForegroundColor Yellow
    return 1
}

function Invoke-SnapitSelfTest {
    $fail = 0
    $catalog = Get-SnapitProviderCatalog
    if ($catalog.Count -lt 10) { Write-Host '[X] catalogo de proveedores demasiado corto' -ForegroundColor Red; $fail++ }
    foreach ($p in $catalog) {
        if (-not $p.Id) { Write-Host '[X] proveedor sin id' -ForegroundColor Red; $fail++ }
        if ($p.Kind -eq 'api-key' -and -not $p.Env) { Write-Host ('[X] ' + $p.Id + ' sin variable de entorno') -ForegroundColor Red; $fail++ }
    }
    $notus = Get-SnapitProviderById -Id 'openai-api'
    if (-not $notus -or $notus.Env -ne 'OPENAI_API_KEY') { Write-Host '[X] Get-SnapitProviderById fallo' -ForegroundColor Red; $fail++ }
    $p = Get-SnapitProviderById -Id 'no-existe'
    if ($null -ne $p) { Write-Host '[X] Get-SnapitProviderById deberia devolver null' -ForegroundColor Red; $fail++ }
    $rows = Get-SnapitPrereqReport
    if ($rows.Count -lt 5) { Write-Host '[X] informe de requisitos incompleto' -ForegroundColor Red; $fail++ }
    foreach ($r in $rows) {
        if (-not $r.PSObject.Properties['Required']) { Write-Host '[X] requisito sin campo Required' -ForegroundColor Red; $fail++ }
    }
    $envPath = Get-HermesEnvPath
    if (-not $envPath -or $envPath -notmatch '[\\/]') { Write-Host '[X] ruta de .env invalida' -ForegroundColor Red; $fail++ }
    $tmp = Join-Path $env:TEMP ('snapit-envtest-' + [Guid]::NewGuid().ToString('N') + '.env')
    try {
        [void](Set-HermesEnvValue -Path $tmp -Name 'SNAPIT_TEST_KEY' -Value 'abc')
        [void](Set-HermesEnvValue -Path $tmp -Name 'OTHER_KEY' -Value 'zzz')
        [void](Set-HermesEnvValue -Path $tmp -Name 'SNAPIT_TEST_KEY' -Value 'def')
        $map = Get-HermesEnvMap -Path $tmp
        if ($map['SNAPIT_TEST_KEY'] -ne 'def') { Write-Host '[X] Set-HermesEnvValue no sobrescribe' -ForegroundColor Red; $fail++ }
        if ($map['OTHER_KEY'] -ne 'zzz') { Write-Host '[X] Set-HermesEnvValue perdio otras claves' -ForegroundColor Red; $fail++ }
        $text = [System.IO.File]::ReadAllText($tmp)
        $count = ([regex]::Matches($text, 'SNAPIT_TEST_KEY')).Count
        if ($count -ne 1) { Write-Host ('[X] Set-HermesEnvValue duplico la clave (' + $count + ')') -ForegroundColor Red; $fail++ }
    } catch {
        Write-Host ('[X] prueba de .env fallo: ' + $_.Exception.Message) -ForegroundColor Red
        $fail++
    } finally {
        if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        Get-ChildItem (Split-Path $tmp -Parent) -Filter ((Split-Path $tmp -Leaf) + '.snapit-backup-*') -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    }
    $plan = Get-SnapitInstallPlan -Options @{ SkipProfileClone = $false }
    if ($plan.Count -lt 3) { Write-Host '[X] plan de instalacion vacio' -ForegroundColor Red; $fail++ }
    $setup = Join-Path $script:Root 'setup.ps1'
    if (-not (Test-Path $setup)) { Write-Host '[X] no encuentro setup.ps1' -ForegroundColor Red; $fail++ }
    if ($fail -eq 0) { Write-Host 'PASS: SnapIt installer self-test' -ForegroundColor Green; return 0 }
    Write-Host ('FAIL: ' + $fail + ' comprobacion(es)') -ForegroundColor Red
    return 1
}

# =====================================================================
#  entry point
# =====================================================================
if ($SelfTest) { exit (Invoke-SnapitSelfTest) }
if ($Unattended) { exit (Invoke-SnapitUnattended) }

try {
    [void](Show-SnapitSetupWindow)
    exit 0
} catch {
    Write-Host ''
    Write-Host ('[X] El instalador fallo: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Puedes usar la instalacion sin interfaz:' -ForegroundColor Yellow
    Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -File .\installer\SnapIt-Setup.ps1 -Unattended' -ForegroundColor White
    exit 3
}
