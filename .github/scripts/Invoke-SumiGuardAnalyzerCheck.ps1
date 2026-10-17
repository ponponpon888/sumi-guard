[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    # Only this severity fails the check. Lower severities are printed so their
    # counts are visible before any rule is made blocking.
    [ValidateSet('Error', 'Warning', 'Information')]
    [string]$FailOnSeverity = 'Error'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
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

$blocking = 0
switch ($FailOnSeverity) {
    'Error' { $blocking = $errorCount }
    'Warning' { $blocking = $errorCount + $warningCount }
    'Information' { $blocking = $errorCount + $warningCount + $informationCount }
}

$summary = [pscustomobject][ordered]@{
    check = 'script-analyzer'
    success = $blocking -eq 0
    powershell_version = $PSVersionTable.PSVersion.ToString()
    analyzer_version = $analyzerModule.Version.ToString()
    fail_on_severity = $FailOnSeverity
    error_count = $errorCount
    warning_count = $warningCount
    information_count = $informationCount
    blocking_count = $blocking
    findings_per_rule = @($byRule | ForEach-Object {
        [pscustomobject][ordered]@{ rule = $_.Name; count = $_.Count }
    })
    scripts_executed = $false
}
$summary | ConvertTo-Json -Depth 4

if ($blocking -gt 0) {
    exit 1
}
