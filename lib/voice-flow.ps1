#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$EventFile,
    [switch]$DryRun
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'snapit-hermes.ps1')
$script:SnapitLogFile = Join-Path (Get-SnapitHome) 'logs\snapit.log'

$event = Get-Content -Raw -Encoding UTF8 $EventFile | ConvertFrom-Json
$transcript = [string]$event.transcript
$profile = [string]$event.target_profile
if (-not $profile.Trim()) { $profile = 'default' }
$cfg = Get-SnapitConfig
$cfgObj = $cfg.Clone()
$cfgObj.Remove('__path')

function Save-CamaritaAuditMirror {
    param([Parameter(Mandatory=$true)][System.Collections.IDictionary]$Audit)

    $auditDir = Join-Path (Get-SnapitHome) 'voice-audit'
    New-Item -ItemType Directory -Path $auditDir -Force | Out-Null
    $safeId = ([string]$Audit.correlation_id) -replace '[^A-Za-z0-9._-]', '_'
    if (-not $safeId) { $safeId = [Guid]::NewGuid().ToString('N') }
    $finalPath = Join-Path $auditDir ($safeId + '.json')
    $tempPath = $finalPath + '.tmp'
    $json = $Audit | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Force $tempPath $finalPath

    $voiceConfigPath = Join-Path (Get-SnapitHome) 'voice-config.json'
    $voiceCfg = if (Test-Path $voiceConfigPath) { Get-Content -Raw -Encoding UTF8 $voiceConfigPath | ConvertFrom-Json } else { $null }
    $mirrorEnabled = $null -ne $voiceCfg -and $voiceCfg.PSObject.Properties['mirror_enabled'] -and [bool]$voiceCfg.mirror_enabled
    $mirrorReady = $null -ne $voiceCfg -and $voiceCfg.PSObject.Properties['mirror_url'] -and $voiceCfg.PSObject.Properties['mirror_token']
    if ($mirrorEnabled -and $mirrorReady) {
        try {
            $headers = @{ 'X-Camarita-Mirror-Token' = [string]$voiceCfg.mirror_token }
            Invoke-RestMethod -Uri ([string]$voiceCfg.mirror_url) -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 6 | Out-Null
            Write-SnapitLog -Message ("Camarita audit mirrored correlation_id={0}" -f $Audit.correlation_id)
        } catch {
            Write-SnapitLog -Message ("Camarita audit mirror failed correlation_id={0}: {1}" -f $Audit.correlation_id, $_.Exception.Message)
        }
    }
}

$improved = Invoke-SnapitImproveText -Transcript $transcript -TargetProfile $profile -Config $cfgObj
$prompt = if ($improved.Text) { [string]$improved.Text } else { $transcript }
$correlationId = if ($event.PSObject.Properties['correlation_id'] -and [string]$event.correlation_id) {
    [string]$event.correlation_id
} elseif ($event.PSObject.Properties['event_id'] -and [string]$event.event_id) {
    [string]$event.event_id
} else {
    [System.IO.Path]::GetFileNameWithoutExtension($EventFile)
}
$source = if ($event.PSObject.Properties['source'] -and [string]$event.source) { [string]$event.source } else { 'voice-listener' }
$result = [ordered]@{
    correlation_id = $correlationId
    recorded_at = [DateTime]::UtcNow.ToString('o')
    source = $source
    transcript_raw = $transcript
    prompt_improved = $prompt
    # Backward-compatible aliases for existing SnapIt readers.
    transcript = $transcript
    improved_prompt = $prompt
    target_profile = $profile
    requires_confirmation = [bool]$event.requires_confirmation
    confirmation_state = 'pending'
    execution_state = 'not_started'
    event = [ordered]@{
        activation = if ($event.PSObject.Properties['activation']) { [string]$event.activation } else { '' }
        addressed = if ($event.PSObject.Properties['addressed']) { [bool]$event.addressed } else { $true }
    }
}
$result | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 (Join-Path (Split-Path -Parent $EventFile) 'last-normalized.json')
Save-CamaritaAuditMirror -Audit $result
if ($DryRun) { $result | ConvertTo-Json -Depth 8; exit 0 }

$risk = if ([bool]$event.requires_confirmation) { "`n`nACCION SENSIBLE: requiere confirmacion antes del efecto final." } else { '' }
$message = "Camarita entendio:`n`n$prompt`n`nDestino recomendado: $profile$risk`n`nSI = ejecutar por Hermes`nNO = abrir DeepSeek :18080 sin enviar`nCANCELAR = descartar"
$choice = [System.Windows.MessageBox]::Show(
    $message,
    'Camarita - confirma el destino',
    [System.Windows.MessageBoxButton]::YesNoCancel,
    [System.Windows.MessageBoxImage]::Question
)
if ($choice -eq [System.Windows.MessageBoxResult]::Yes) {
    [void](Start-HermesTextExecutor -ProfileName $profile -ImprovedPrompt $prompt -Config $cfgObj)
    $result.confirmation_state = 'approved'
    $result.execution_state = 'hermes_launched'
} elseif ($choice -eq [System.Windows.MessageBoxResult]::No) {
    [void](Invoke-SnapitWebPrefill -Prompt $prompt -Config $cfgObj -JobDir (Split-Path -Parent $EventFile))
    $result.confirmation_state = 'redirected_to_deepseek'
    $result.execution_state = 'prefilled_not_submitted'
} else {
    $result.confirmation_state = 'cancelled'
    $result.execution_state = 'cancelled'
}
$result.recorded_at = [DateTime]::UtcNow.ToString('o')
Save-CamaritaAuditMirror -Audit $result
