[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

# Test scripts that use only synthetic input and do not import
# SumiGuard.LocalStore. These run on a GitHub-hosted runner.
$includedTests = @(
    'Invoke-AssessmentStoreTests.ps1',
    'Invoke-CommandAssessmentHookIntegrationTests.ps1',
    'Invoke-CommandAssessmentTests.ps1',
    'Invoke-HookAssessmentStoreAdapterTests.ps1',
    'Invoke-ManagedAssessmentStoreDemoTests.ps1',
    'Invoke-ManagedAssessmentVerificationConnectionTests.ps1',
    'Invoke-ManagedAssessmentVerificationTests.ps1',
    'Invoke-ManagedPowerShellAssessmentDemoTests.ps1',
    'Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1',
    'Invoke-PowerShellCommandCliTests.ps1',
    'Invoke-RealHookRunnerSyntheticTests.ps1'
)

# Test scripts this runner does not execute, with the reason. A passing run of
# the suite below says nothing about these.
$excludedTests = @(
    [pscustomobject][ordered]@{
        name = 'Invoke-LocalStoreTests.ps1'
        reason = 'Imports SumiGuard.LocalStore, which protects bodies with DPAPI CurrentUser. The protection is bound to the runner user profile, so a result here would not correspond to the operator machine.'
    },
    [pscustomobject][ordered]@{
        name = 'Invoke-ExecutionAdapterIntegrationTests.ps1'
        reason = 'Imports SumiGuard.LocalStore. Same DPAPI CurrentUser dependency as above.'
    },
    [pscustomobject][ordered]@{
        name = 'Invoke-ReadOnlyCliTests.ps1'
        reason = 'Imports SumiGuard.LocalStore. Same DPAPI CurrentUser dependency as above.'
    }
)

$testsDirectory = Join-Path $RepositoryRoot 'tests'
$powerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $powerShell51)) {
    throw [System.InvalidOperationException]::new(
        "Windows PowerShell 5.1 host not found at $powerShell51")
}

# Test scripts print human-readable lines and intermediate JSON before their
# final summary, so the whole output is not one JSON document. Scan backwards
# for the last line that opens an object and still parses to the end of the
# output: that is the summary.
function Get-SumiGuardTestSummary {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $lines = $Text -split "`r?`n"
    for ($index = $lines.Length - 1; $index -ge 0; $index--) {
        if (-not $lines[$index].TrimStart().StartsWith('{')) {
            continue
        }

        $candidate = ($lines[$index..($lines.Length - 1)] -join "`n")
        $parsed = $null
        try {
            $parsed = $candidate | ConvertFrom-Json
        } catch {
            $parsed = $null
        }

        if ($null -ne $parsed -and
            ($parsed.PSObject.Properties.Name -contains 'success')) {
            return $parsed
        }
    }

    return $null
}

$results = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]

# A test file that is in neither list fails the run. Without this, adding a
# test would silently leave it unchecked by CI.
$excludedNames = @($excludedTests | ForEach-Object { $_.name })
$presentTests = @(Get-ChildItem -LiteralPath $testsDirectory -Filter '*.ps1' -File |
    Select-Object -ExpandProperty Name |
    Sort-Object)

foreach ($name in $presentTests) {
    if (($includedTests -notcontains $name) -and ($excludedNames -notcontains $name)) {
        $failures.Add("UNCLASSIFIED_TEST: $name is in neither the included nor the excluded list")
    }
}

foreach ($name in $includedTests) {
    $path = Join-Path $testsDirectory $name
    if (-not (Test-Path -LiteralPath $path)) {
        $failures.Add("MISSING_TEST: $name is listed as included but does not exist")
        continue
    }

    Write-Host "=== $name"

    # Windows PowerShell 5.1 turns a native command's stderr into error records.
    # With $ErrorActionPreference = 'Stop' in effect, one stderr line from a
    # test would abort this runner instead of being recorded as that test's
    # result, so the preference is relaxed for the call only.
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $powerShell51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $text = ($output | Out-String)
    Write-Host $text

    $reportedSuccess = $null
    $summaryObject = Get-SumiGuardTestSummary -Text $text
    if ($null -ne $summaryObject) {
        $reportedSuccess = [bool]$summaryObject.success
    }

    $results.Add([pscustomobject][ordered]@{
        name = $name
        exit_code = $exitCode
        reported_success = $reportedSuccess
    })

    if ($exitCode -ne 0) {
        $failures.Add("NONZERO_EXIT: $name exited with $exitCode")
    } elseif ($null -eq $reportedSuccess) {
        $failures.Add("SUMMARY_UNPARSED: $name exited 0 but its JSON summary could not be read")
    } elseif (-not $reportedSuccess) {
        $failures.Add("SUMMARY_FAILURE: $name exited 0 but reported success=false")
    }
}

foreach ($failure in $failures) {
    Write-Host $failure
}

$summary = [pscustomobject][ordered]@{
    check = 'dpapi-independent-test-suite'
    success = $failures.Count -eq 0
    powershell_version = $PSVersionTable.PSVersion.ToString()
    host_path = $powerShell51
    executed_count = $results.Count
    excluded_count = $excludedTests.Count
    failures = $failures.ToArray()
    results = $results.ToArray()
    excluded = $excludedTests
    dpapi_dependent_tests_executed = $false
    operator_machine_verification_performed = $false
}
$summary | ConvertTo-Json -Depth 6

if ($failures.Count -gt 0) {
    exit 1
}
