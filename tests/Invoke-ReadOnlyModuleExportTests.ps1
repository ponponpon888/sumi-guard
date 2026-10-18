# Static export-contract check: never imports a DPAPI-dependent module.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.ReadOnly.psm1'
$cliPath = Join-Path $root 'tools\Show-SumiGuardRecords.ReadOnly.ps1'
$failure = New-Object System.Collections.Generic.List[string]

try {
    $source = [IO.File]::ReadAllText($modulePath)
    $match = [regex]::Match($source,
        'Export-ModuleMember\s+-Function\s+@\((?<members>[\s\S]*?)\)\s*$',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) {
        $failure.Add('EXPORT_STATEMENT_NOT_FOUND')
    }
    else {
        $names = @([regex]::Matches($match.Groups['members'].Value, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value })
        $expected = @('Get-SumiGuardExecutionRecord', 'Get-SumiGuardCollectionFailureNotice')
        if ($names.Count -ne $expected.Count) {
            $failure.Add('EXPORT_COUNT_CHANGED')
        }
        foreach ($name in $names) {
            if ($expected -cnotcontains $name) {
                $failure.Add('UNEXPECTED_EXPORT')
            }
        }
        foreach ($name in $expected) {
            if ($names -cnotcontains $name) {
                $failure.Add('REQUIRED_READ_MISSING')
            }
        }
    }
    $cliSource = [IO.File]::ReadAllText($cliPath)
    if ($cliSource -notmatch 'SumiGuard\.ExecutionAdapter\.ReadOnly\.psm1') {
        $failure.Add('READONLY_CLI_ADAPTER_CHANGED')
    }
}
catch {
    $failure.Add('STATIC_CHECK_ERROR')
}

$summary = [pscustomobject][ordered]@{
    success = ($failure.Count -eq 0)
    test_count = 1
    passed_count = $(if ($failure.Count -eq 0) { 1 } else { 0 })
    failed_cases = $failure.ToArray()
    module_imported = $false
    dpapi_executed = $false
}
$summary | ConvertTo-Json -Compress
if ($failure.Count -gt 0) { exit 1 }
exit 0
