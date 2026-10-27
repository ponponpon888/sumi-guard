[CmdletBinding()]
param(
    # Where the result JSON goes. Defaults to the user's Downloads folder.
    [string]$OutputDirectory
)

# Gate 3 (docs/33, docs/35): run the DPAPI-dependent test scripts on the
# operator's own Windows machine, as the operator, and keep one result file.
#
# Run from the operator's own Windows PowerShell 5.1 window, from a clean
# checkout. It changes no settings, registers no hook and touches no real
# store: every test works in its own disposable folder under %TEMP% and
# removes it. The result file holds no SID, user name, path or body text.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$checkName = 'sumi-guard-gate3-operator-check'
$startedAt = [DateTimeOffset]::Now

$testNames = @(
    'Invoke-LocalStoreTests.ps1',
    'Invoke-LocalStoreOperatorHardeningTests.ps1',
    'Invoke-ExecutionAdapterIntegrationTests.ps1',
    'Invoke-ReadOnlyCliTests.ps1'
)
$hashedFiles = @(
    'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psm1',
    'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1',
    'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psm1',
    'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.ReadOnly.psm1',
    'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psm1',
    'hooks\Invoke-SumiGuardMonitorHook.ps1',
    'tools\Invoke-SumiGuardGate3OperatorCheck.ps1'
) + @($testNames | ForEach-Object { 'tests\' + $_ })

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:USERPROFILE 'Downloads'
}

# Strings that would identify the operator if they reached the result file.
$identitySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$redactions = @(
    @{ value = $repositoryRoot; label = '<repo>' },
    @{ value = [System.IO.Path]::GetTempPath().TrimEnd('\'); label = '<temp>' },
    @{ value = $env:USERPROFILE; label = '<profile>' },
    @{ value = $identitySid; label = '<sid>' },
    @{ value = $env:USERNAME; label = '<user>' },
    @{ value = $env:COMPUTERNAME; label = '<computer>' }
)

function ConvertTo-RedactedText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }
    $value = $Text
    foreach ($redaction in $redactions) {
        if (-not [string]::IsNullOrEmpty($redaction.value)) {
            $value = [regex]::Replace(
                $value,
                [regex]::Escape($redaction.value),
                $redaction.label,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    if ($value.Length -gt 300) {
        $value = $value.Substring(0, 300) + '...'
    }
    return $value
}

# Test scripts print lines before their final JSON summary. Scan backwards for
# the last line that opens an object and parses to the end of the output.
function Get-TestSummary {
    param([AllowEmptyString()][string]$Text)

    $lines = $Text -split "`r?`n"
    for ($index = $lines.Length - 1; $index -ge 0; $index--) {
        if (-not $lines[$index].TrimStart().StartsWith('{')) {
            continue
        }
        $candidate = ($lines[$index..($lines.Length - 1)] -join "`n")
        try {
            return ($candidate | ConvertFrom-Json)
        }
        catch {
            continue
        }
    }
    return $null
}

function Get-PropertyValue {
    param($InputObject, [string]$Name)

    if ($null -ne $InputObject -and ($InputObject.PSObject.Properties.Name -contains $Name)) {
        return $InputObject.$Name
    }
    return $null
}

function Invoke-GitText {
    param([string[]]$Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $repositoryRoot @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $null
        }
        return (@($output) -join "`n")
    }
    catch {
        return $null
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

$isWindowsPowerShell51 = $PSVersionTable.PSEdition -ceq 'Desktop' -and
    $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
$principal = New-Object System.Security.Principal.WindowsPrincipal(
    [System.Security.Principal.WindowsIdentity]::GetCurrent())
$isElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
$agentEnvironment = @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CODEX_SANDBOX', 'CODEX_MANAGED_BY_NPM') |
    Where-Object { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) }

$gitHead = Invoke-GitText -Arguments @('rev-parse', 'HEAD')
$gitBranch = Invoke-GitText -Arguments @('rev-parse', '--abbrev-ref', 'HEAD')
$gitStatus = Invoke-GitText -Arguments @('status', '--porcelain')
$dirtyCount = $null
if ($null -ne $gitStatus) {
    $dirtyCount = @($gitStatus -split "`n" | Where-Object { $_.Trim() -ne '' }).Count
}

$hashes = [ordered]@{}
foreach ($relative in $hashedFiles) {
    $full = Join-Path $repositoryRoot $relative
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $hashes[$relative.Replace('\', '/')] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    else {
        $hashes[$relative.Replace('\', '/')] = $null
    }
}

$powerShell51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$testResults = New-Object System.Collections.Generic.List[object]

if ($isWindowsPowerShell51 -and (Test-Path -LiteralPath $powerShell51)) {
    foreach ($name in $testNames) {
        $path = Join-Path (Join-Path $repositoryRoot 'tests') $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $testResults.Add([pscustomobject][ordered]@{
                name = $name
                ran = $false
                success = $false
                exit_code = $null
                test_count = $null
                passed_cases = @()
                failed_cases = @()
                failure_type = 'MissingTestScript'
                failure_message = $null
                seconds = 0
            })
            continue
        }

        Write-Output ("running {0} ..." -f $name)
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $powerShell51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $path 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previous
        }
        $clock.Stop()

        $summary = Get-TestSummary -Text ($output | Out-String)
        # The test scripts do not agree on one name for the per-case array.
        $rows = @(Get-PropertyValue -InputObject $summary -Name 'tests')
        if ($rows.Count -eq 0 -or $null -eq $rows[0]) {
            $rows = @(Get-PropertyValue -InputObject $summary -Name 'results')
        }
        $rows = @($rows | Where-Object { $null -ne $_ })
        $passedCases = @($rows |
            Where-Object { [bool](Get-PropertyValue -InputObject $_ -Name 'passed') } |
            ForEach-Object { [string](Get-PropertyValue -InputObject $_ -Name 'name') })
        $failedCases = @($rows |
            Where-Object { -not [bool](Get-PropertyValue -InputObject $_ -Name 'passed') } |
            ForEach-Object { [string](Get-PropertyValue -InputObject $_ -Name 'name') })
        $cleaned = Get-PropertyValue -InputObject $summary -Name 'test_root_cleaned'
        if ($null -eq $cleaned) {
            $cleaned = Get-PropertyValue -InputObject $summary -Name 'test_material_removed'
        }
        $failure = Get-PropertyValue -InputObject $summary -Name 'failure'
        $reportedSuccess = [bool](Get-PropertyValue -InputObject $summary -Name 'success')

        $testResults.Add([pscustomobject][ordered]@{
            name = $name
            ran = $true
            success = ($exitCode -eq 0) -and ($null -ne $summary) -and $reportedSuccess
            exit_code = $exitCode
            test_count = Get-PropertyValue -InputObject $summary -Name 'test_count'
            passed_cases = $passedCases
            failed_cases = $failedCases
            failure_type = ConvertTo-RedactedText -Text ([string](Get-PropertyValue -InputObject $failure -Name 'type'))
            failure_message = ConvertTo-RedactedText -Text ([string](Get-PropertyValue -InputObject $failure -Name 'message'))
            summary_parsed = $null -ne $summary
            test_root_cleaned = $cleaned
            seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
        })
    }
}

$allRan = $testResults.Count -eq $testNames.Count -and
    @($testResults | Where-Object { -not $_.ran }).Count -eq 0
$allPassed = $allRan -and @($testResults | Where-Object { -not $_.success }).Count -eq 0

$verdict = if (-not $isWindowsPowerShell51) {
    'INCONCLUSIVE_NOT_WINDOWS_POWERSHELL_51'
}
elseif ($null -eq $gitHead) {
    'INCONCLUSIVE_NOT_A_GIT_CHECKOUT'
}
elseif ($dirtyCount -ne 0) {
    'INCONCLUSIVE_WORKTREE_NOT_CLEAN'
}
elseif (-not $allRan) {
    'INCONCLUSIVE_TEST_NOT_RUN'
}
elseif ($allPassed) {
    'PASS_GATE3_OPERATOR_CHECKS'
}
else {
    'FAIL_GATE3_OPERATOR_CHECKS'
}

$result = [pscustomobject][ordered]@{
    check = $checkName
    verdict = $verdict
    started_at = $startedAt.ToString('o')
    finished_at = [DateTimeOffset]::Now.ToString('o')
    git_head = $gitHead
    git_branch = $gitBranch
    worktree_dirty_entries = $dirtyCount
    powershell_version = $PSVersionTable.PSVersion.ToString()
    powershell_edition = $PSVersionTable.PSEdition
    os_version = [Environment]::OSVersion.Version.ToString()
    elevated = $isElevated
    agent_environment_variables_present = @($agentEnvironment)
    tests = $testResults.ToArray()
    file_sha256 = [pscustomobject]$hashes
    identity_included = $false
    plaintext_included = $false
    settings_changed = $false
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    throw [System.IO.DirectoryNotFoundException]::new('The output directory does not exist.')
}
$resultPath = Join-Path $OutputDirectory ('sumi-guard_gate3_result_' + $startedAt.ToString('yyyyMMdd') + '.json')
$json = $result | ConvertTo-Json -Depth 8
[System.IO.File]::WriteAllText($resultPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Output ('verdict: ' + $verdict)
Write-Output ('summary: ' + $resultPath)
if ($verdict -cne 'PASS_GATE3_OPERATOR_CHECKS') {
    exit 1
}
