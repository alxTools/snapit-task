# Regression checks for the SnapIt PowerShell/WPF launcher.
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'snapit.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8

# PowerShell 5.1 parses arithmetic inside Canvas.SetLeft(...) / SetTop(...)
# badly when the WPF attached-property method uses dotted type syntax.
$unsafeCalls = [regex]::Matches($source, '(?m)^\s*Canvas\.(SetLeft|SetTop)\(')
if ($unsafeCalls.Count -gt 0) {
    throw ("Unsafe dotted Canvas attached-property calls remain: {0}" -f $unsafeCalls.Count)
}
if ($source -notmatch '\[System\.Windows\.Controls\.Canvas\]::SetLeft\(\$hintBorder,') {
    throw 'The hintBorder position must use an explicit static Canvas.SetLeft call.'
}
if ($source -notmatch '\[System\.Windows\.Controls\.Canvas\]::SetTop\(\$hintBorder,') {
    throw 'The hintBorder position must use an explicit static Canvas.SetTop call.'
}
if ($source -match '(?ms)\$win\.Show\(\)\s*\r?\n\s*\$win\.Activate\(\)\s*\r?\n\s*\$win\.ShowDialog\(\)') {
    throw 'Capture window must not call Show() before ShowDialog().'
}
if ($source -match '(?m)\.Add_MouseLeftButtonUp\([^\r\n]+,\s*\$true\s*\)') {
    throw 'Add_MouseLeftButtonUp supports only the event-handler argument in PowerShell 5.1.'
}
$leakyChildrenAdds = @($source -split "`r?`n" | Where-Object {
    $_ -match '\.Children\.Add\(' -and $_.TrimStart() -notmatch '^\[void\]'
})
if ($leakyChildrenAdds.Count -gt 0) {
    throw ("Children.Add output can pollute function return values: {0}" -f ($leakyChildrenAdds -join ' | '))
}
if ($source -notmatch '(?s)Add_MouseEnter\(\(\{.*?\}\)\.GetNewClosure\(\)\)') {
    throw 'Deferred MouseEnter handler must close over its brush variables.'
}
if ($source -notmatch '(?s)Add_MouseLeave\(\(\{.*?\}\)\.GetNewClosure\(\)\)') {
    throw 'Deferred MouseLeave handler must close over its brush variables.'
}
if ($source -notmatch 'Where-Object\s*\{\s*\$_\s+-is\s+\[System\.Collections\.IDictionary\].*?Contains\(''Choice''\)') {
    throw 'Destination picker output must be filtered to an IDictionary containing Choice.'
}
if ($source -match '\$pick\.(Choice|Prompt)') {
    throw 'Destination picker values must use safe IDictionary index access.'
}

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $sourcePath,
    [ref]$tokens,
    [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw ('PowerShell parse errors: ' + (($parseErrors | ForEach-Object Message) -join '; '))
}

Add-Type -AssemblyName PresentationFramework
$probe = New-Object System.Windows.Controls.Border
$screenWidth = [double]8320
$left = [double](($screenWidth - 320.0) / 2.0)
[System.Windows.Controls.Canvas]::SetLeft($probe, $left)
if ([System.Windows.Controls.Canvas]::GetLeft($probe) -ne 4000.0) {
    throw 'Explicit Canvas.SetLeft arithmetic probe returned the wrong position.'
}

Write-Output 'PASS: SnapIt WPF arithmetic regression checks'
