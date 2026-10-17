[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost',
    '',
    Justification = 'Human-readable lines belong in the CI log only. Standard output carries this script''s JSON summary, so sending them to the output stream would mix two formats in one stream.')]
param(
    [string]$RepositoryRoot,

    # Only this severity fails the check. Lower severities are printed so their
    # counts are visible before any rule is made blocking.
    [ValidateSet('Error', 'Warning', 'Information')]
    [string]$FailOnSeverity = 'Error',

    # Per-rule counts the repository currently carries. A rule above its
    # recorded number, or a rule absent from the file, fails the check. This
    # holds the counts from going up without fixing the existing findings
    # first, which would otherwise take one change per rule to even start.
    [string]$BaselinePath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}

if ([string]::IsNullOrWhiteSpace($BaselinePath)) {
    $BaselinePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'analyzer-baseline.json'
}

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    # Windows PowerShell 5.1 negotiates TLS 1.0 by default, which PowerShell
    # Gallery refuses. Without this line the install fails before any download.
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Force -Scope CurrentUser |
        Out-Null
    Install-Module -Name PSScriptAnalyzer -Scope CurrentUser -Force -AllowClobber |
        Out-Null
}

Import-Module -Name PSScriptAnalyzer -ErrorAction Stop
$analyzerModule = Get-Module -Name PSScriptAnalyzer

$results = @(Invoke-ScriptAnalyzer -Path $RepositoryRoot -Recurse)

foreach ($result in $results) {
    $relative = $result.ScriptPath
    if ([string]::IsNullOrEmpty($relative)) {
        $relative = '(unknown path)'
    } elseif ($relative.StartsWith($RepositoryRoot)) {
        $relative = $relative.Substring($RepositoryRoot.Length).TrimStart('\')
    }

    Write-Host ("{0}: {1} ({2}:{3}) {4}" -f
        $result.Severity,
        $result.RuleName,
        $relative,
        $result.Line,
        $result.Message)
}

# Per-rule counts, so a decision about which rules to make blocking can be
# made from numbers instead of by reading every finding in the raw log.
$byRule = @($results |
    Group-Object -Property @{ Expression = { "$($_.Severity)/$($_.RuleName)" } } |
    Sort-Object -Property Count -Descending)

Write-Host ''
Write-Host 'Findings per rule:'
foreach ($group in $byRule) {
    Write-Host ("  {0,4}  {1}" -f $group.Count, $group.Name)
}
Write-Host ''

$errorCount = @($results | Where-Object { $_.Severity -eq 'Error' }).Count
$warningCount = @($results | Where-Object { $_.Severity -eq 'Warning' }).Count
$informationCount = @($results | Where-Object { $_.Severity -eq 'Information' }).Count

$baselineRules = $null
if (Test-Path -LiteralPath $BaselinePath) {
    $baselineRules = (Get-Content -LiteralPath $BaselinePath -Raw -Encoding UTF8 | ConvertFrom-Json).rules
}

$baselineViolations = New-Object System.Collections.Generic.List[string]
$baselineImprovements = New-Object System.Collections.Generic.List[string]

if ($null -eq $baselineRules) {
    Write-Host "No baseline file at $BaselinePath; per-rule comparison skipped."
} else {
    $baselineNames = $baselineRules.PSObject.Properties.Name

    foreach ($group in $byRule) {
        $allowed = 0
        if ($baselineNames -contains $group.Name) {
            $allowed = [int]$baselineRules.($group.Name)
        }

        if ($group.Count -gt $allowed) {
            $baselineViolations.Add(("{0}: {1} findings, baseline {2}" -f $group.Name, $group.Count, $allowed))
        } elseif ($group.Count -lt $allowed) {
            $baselineImprovements.Add(("{0}: {1} findings, baseline {2}" -f $group.Name, $group.Count, $allowed))
        }
    }

    $presentNames = @($byRule | ForEach-Object { $_.Name })
    foreach ($name in $baselineNames) {
        if ($presentNames -notcontains $name -and [int]$baselineRules.$name -gt 0) {
            $baselineImprovements.Add(("{0}: 0 findings, baseline {1}" -f $name, [int]$baselineRules.$name))
        }
    }

    foreach ($violation in $baselineViolations) {
        Write-Host ("ABOVE_BASELINE: " + $violation)
    }

    # Below baseline is not a failure. It means the number in the baseline file
    # can be lowered, which is how the count ratchets down.
    foreach ($improvement in $baselineImprovements) {
        Write-Host ("BELOW_BASELINE (lower the baseline): " + $improvement)
    }
}

$blocking = 0
switch ($FailOnSeverity) {
    'Error' { $blocking = $errorCount }
    'Warning' { $blocking = $errorCount + $warningCount }
    'Information' { $blocking = $errorCount + $warningCount + $informationCount }
}

$summary = [pscustomobject][ordered]@{
    check = 'script-analyzer'
    success = ($blocking -eq 0) -and ($baselineViolations.Count -eq 0)
    powershell_version = $PSVersionTable.PSVersion.ToString()
    analyzer_version = $analyzerModule.Version.ToString()
    fail_on_severity = $FailOnSeverity
    error_count = $errorCount
    warning_count = $warningCount
    information_count = $informationCount
    blocking_count = $blocking
    baseline_path = $BaselinePath
    baseline_loaded = ($null -ne $baselineRules)
    above_baseline = $baselineViolations.ToArray()
    below_baseline = $baselineImprovements.ToArray()
    findings_per_rule = @($byRule | ForEach-Object {
        [pscustomobject][ordered]@{ rule = $_.Name; count = $_.Count }
    })
    scripts_executed = $false
}
$summary | ConvertTo-Json -Depth 4

if ($blocking -gt 0 -or $baselineViolations.Count -gt 0) {
    exit 1
}
