[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost',
    '',
    Justification = 'Human-readable lines belong in the CI log only. Standard output carries this script''s JSON summary, so sending them to the output stream would mix two formats in one stream.')]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

# Test scripts that use only synthetic input and do not depend on DPAPI
# CurrentUser. These run on a GitHub-hosted runner.
#
# arguments: passed to the script. A test whose cases only run behind a switch
#   needs that switch here, otherwise the script reports an idle mode and exits
#   0 without testing anything.
# needs_empty_demo_data: the script snapshots a demo data directory before it
#   starts. That directory is generated at demo time and is not in the
#   repository, so the runner creates an empty one and passes its path.
# success_property: the property its JSON summary reports the overall result
#   in. Most use 'success'; the synthetic runner uses 'synthetic_all_passed'.
$includedTests = @(
    [pscustomobject]@{ name = 'Invoke-AssessmentStoreTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-ClaudeMonitorHookProfileSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-CommandAssessmentHookIntegrationTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-CommandAssessmentTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-EnforcementDecisionSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-EnforcementControlSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-EnforcementHookSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-EnforcementDemoSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-ClaudeResponseSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-LogIntegrityTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-HookAssessmentStoreAdapterTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-ManagedAssessmentStoreDemoTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-ManagedAssessmentVerificationConnectionTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-ManagedAssessmentVerificationTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-ManagedProcessEvidenceTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-OsProcessCorrelationSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-ManagedPowerShellAssessmentDemoTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-MonitorHookStandardInputEncodingTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-MonitorHookSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-ManagedPowerShellAssessmentRunnerSyntheticTests.ps1'; arguments = @('-RunSyntheticTests'); needs_empty_demo_data = $true; success_property = 'synthetic_all_passed' },
    [pscustomobject]@{ name = 'Invoke-PowerShellCommandCliTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' },
    [pscustomobject]@{ name = 'Invoke-RealHookRunnerSyntheticTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' }
    [pscustomobject]@{ name = 'Invoke-ExecutionAdapterMetadataLogLimitTests.ps1'; arguments = @(); needs_empty_demo_data = $false; success_property = 'success' }
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
    },
    [pscustomobject][ordered]@{
        name = 'Invoke-LocalStoreOperatorHardeningTests.ps1'
        reason = 'Gate 3 operator check: inspects the DPAPI CurrentUser blob and master key of the user running it. Run on the operator machine through tools/Invoke-SumiGuardGate3OperatorCheck.ps1.'
    },
    [pscustomobject][ordered]@{
        name = 'Invoke-ManagedProcessEvidenceRealSmokeTests.ps1'
        reason = 'Starts one real fixed-command Windows PowerShell child. It runs in the separate managed-process-real-smoke CI job with explicit -RunSmoke, not in the synthetic/DPAPI-independent suite.'
    },
    [pscustomobject][ordered]@{
        name = 'Invoke-ManagedProcessEvidenceFailureSmokeTests.ps1'
        reason = 'Starts two real fixed-command Windows PowerShell children for nonzero-exit and timeout handling. It runs in the separate managed-process-failure-smoke CI job with explicit -RunSmoke, not in the synthetic/DPAPI-independent suite.'
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

        if ($null -ne $parsed) {
            return $parsed
        }
    }

    return $null
}

# Pull the stage and exception a failing test reported, when it reported one.
function Get-SumiGuardTestDiagnostic {
    param($Summary)

    if ($null -eq $Summary) {
        return ''
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $names = $Summary.PSObject.Properties.Name
    foreach ($field in @('failure_stage', 'failure_line', 'failure_exception_type', 'last_completed_case', 'test_count', 'passed_count', 'failed_cases')) {
        if ($names -contains $field) {
            $value = $Summary.$field
            if ($null -ne $value -and "$value" -ne '') {
                $parts.Add(("{0}={1}" -f $field, (@($value) -join ',')))
            }
        }
    }

    if ($names -contains 'setup_diagnostic' -and $null -ne $Summary.setup_diagnostic) {
        $setup = $Summary.setup_diagnostic
        $setupNames = $setup.PSObject.Properties.Name
        foreach ($field in @('stage', 'exception_type')) {
            if ($setupNames -contains $field) {
                $parts.Add(("setup_{0}={1}" -f $field, $setup.$field))
            }
        }
    }

    if ($parts.Count -eq 0) {
        return ''
    }

    return (' [' + ($parts -join ' ') + ']')
}

# A test that reports per-case rows says which ones failed. Carrying those rows
# into the failure line keeps a diagnosis at the end of the job log, instead of
# a few hundred lines up inside the test's own output.
function Get-SumiGuardFailedCaseDigest {
    param($Summary)

    if ($null -eq $Summary) { return '' }
    $names = $Summary.PSObject.Properties.Name
    # The test scripts do not agree on one name for the per-case array. Without
    # all of them, a failing suite reports only its counts and the failing case
    # has to be found by re-reading the whole log.
    $rowsProperty = @('results', 'tests', 'cases') | Where-Object { $names -contains $_ } |
        Select-Object -First 1
    if ([string]::IsNullOrEmpty($rowsProperty)) { return '' }

    $failedRows = @(@($Summary.$rowsProperty) | Where-Object {
        $null -ne $_ -and (
            (($_.PSObject.Properties.Name -contains 'pass') -and (-not [bool]$_.pass)) -or
            (($_.PSObject.Properties.Name -contains 'passed') -and (-not [bool]$_.passed)) -or
            (($_.PSObject.Properties.Name -contains 'result') -and ([string]$_.result -cne 'PASS'))
        )
    })
    if ($failedRows.Count -eq 0) { return '' }

    $parts = @($failedRows | ForEach-Object { ($_ | ConvertTo-Json -Compress -Depth 5) })
    return (' cases=' + ($parts -join ' '))
}

$results = New-Object System.Collections.Generic.List[object]
$failures = New-Object System.Collections.Generic.List[string]
$temporaryDirectories = New-Object System.Collections.Generic.List[string]

# A test file that is in neither list fails the run. Without this, adding a
# test would silently leave it unchecked by CI.
$includedNames = @($includedTests | ForEach-Object { $_.name })
$excludedNames = @($excludedTests | ForEach-Object { $_.name })
$presentTests = @(Get-ChildItem -LiteralPath $testsDirectory -Filter '*.ps1' -File |
    Select-Object -ExpandProperty Name |
    Sort-Object)

foreach ($name in $presentTests) {
    if (($includedNames -notcontains $name) -and ($excludedNames -notcontains $name)) {
        $failures.Add("UNCLASSIFIED_TEST: $name is in neither the included nor the excluded list")
    }
}

try {
    foreach ($test in $includedTests) {
        $name = $test.name
        $path = Join-Path $testsDirectory $name
        if (-not (Test-Path -LiteralPath $path)) {
            $failures.Add("MISSING_TEST: $name is listed as included but does not exist")
            continue
        }

        $arguments = @($test.arguments)
        if ($test.needs_empty_demo_data) {
            $demoDataPath = Join-Path ([System.IO.Path]::GetTempPath()) ('sumi-guard-ci-demo-data-' + [Guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $demoDataPath
            $temporaryDirectories.Add($demoDataPath)
            $arguments += @('-DemoDataPath', $demoDataPath)
        }

        Write-Host "=== $name $($arguments -join ' ')"

        # Windows PowerShell 5.1 turns a native command's stderr into error
        # records. With $ErrorActionPreference = 'Stop' in effect, one stderr
        # line from a test would abort this runner instead of being recorded as
        # that test's result, so the preference is relaxed for the call only.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $powerShell51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path @arguments 2>&1
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousPreference
        }

        $text = ($output | Out-String)
        Write-Host $text

        $summary = Get-SumiGuardTestSummary -Text $text
        $successProperty = $test.success_property
        $reportedSuccess = $null
        $summaryHasSuccess = $false
        if ($null -ne $summary) {
            $summaryHasSuccess = $summary.PSObject.Properties.Name -contains $successProperty
            if ($summaryHasSuccess) {
                $reportedSuccess = [bool]$summary.$successProperty
            }
        }

        # Carry whatever stage the test itself named into the failure line, so
        # the job summary explains a failure without opening the raw log.
        $diagnostic = Get-SumiGuardTestDiagnostic -Summary $summary
        $diagnostic = $diagnostic + (Get-SumiGuardFailedCaseDigest -Summary $summary)

        $results.Add([pscustomobject][ordered]@{
            name = $name
            arguments = $arguments
            exit_code = $exitCode
            reported_success = $reportedSuccess
        })

        if ($exitCode -ne 0) {
            $failures.Add("NONZERO_EXIT: $name exited with $exitCode$diagnostic")
        } elseif ($null -eq $summary) {
            $failures.Add("SUMMARY_UNPARSED: $name exited 0 but no JSON summary could be read from its output")
        } elseif (-not $summaryHasSuccess) {
            # An idle or dry mode ends here: exit 0 with a summary that reports
            # no result. Treating it as a pass would hide a test that ran nothing.
            $failures.Add("NO_SUCCESS_FIELD: $name exited 0 but its summary has no $successProperty field, so no case was judged")
        } elseif (-not $reportedSuccess) {
            $failures.Add("SUMMARY_FAILURE: $name exited 0 but reported $successProperty=false$diagnostic")
        }
    }
} finally {
    foreach ($directory in $temporaryDirectories) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force
        }
    }
}

foreach ($failure in $failures) {
    Write-Host $failure
}

# The same lines as workflow annotations. Annotations can be read through the
# checks API, so a failing case can be named without downloading the job log.
if ($env:GITHUB_ACTIONS -eq 'true') {
    foreach ($failure in $failures) {
        $annotation = $failure
        if ($annotation.Length -gt 3000) {
            $annotation = $annotation.Substring(0, 3000) + '...'
        }
        $annotation = $annotation.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
        Write-Host ('::error title=SUMI Guard test failure::' + $annotation)
    }
}

$summaryObject = [pscustomobject][ordered]@{
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
$summaryObject | ConvertTo-Json -Depth 6

# Repeated after the summary so the last lines of the job log carry the reason.
if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'FAILURES:'
    foreach ($failure in $failures) {
        Write-Host ('  ' + $failure)
    }
    exit 1
}
