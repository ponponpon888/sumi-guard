[CmdletBinding(DefaultParameterSetName = 'Create')]
param(
    [Parameter(Mandatory = $true)][string]$StorePath,

    [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
    [ValidateSet('Event', 'Failure', 'Retention', 'Assessment')]
    [string]$Kind,

    # Where to keep the checkpoint. It must be outside the store: a checkpoint
    # the log's writer can also rewrite proves nothing. An existing file is
    # never overwritten.
    [Parameter(Mandatory = $true, ParameterSetName = 'Create')]
    [string]$OutFile,

    [Parameter(Mandatory = $true, ParameterSetName = 'Verify')]
    [string]$CheckpointFile
)

# Operator wrapper around SumiGuard.LogIntegrity. Standard output carries one
# JSON summary with fixed codes and counts only: no path, no log content.
#
# Exit codes: 0 = checkpoint written / log INTACT, 2 = MODIFIED or TRUNCATED,
# 1 = could not create or verify (see status).

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$manifest = Join-Path (Join-Path (Join-Path $projectRoot 'src') 'SumiGuard.LogIntegrity') 'SumiGuard.LogIntegrity.psd1'
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

function Write-SumiGuardSummary {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Summary,
        [Parameter(Mandatory = $true)][int]$ExitCode
    )

    $Summary['content_included'] = $false
    [pscustomobject]$Summary | ConvertTo-Json -Depth 4 -Compress
    exit $ExitCode
}

try {
    Import-Module -Name $manifest -Force -ErrorAction Stop
}
catch {
    Write-SumiGuardSummary -Summary ([ordered]@{ mode = $PSCmdlet.ParameterSetName; status = 'MODULE_LOAD_FAILED' }) -ExitCode 1
}

if ($PSCmdlet.ParameterSetName -ceq 'Create') {
    try {
        $storeFull = [IO.Path]::GetFullPath($StorePath).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $outFull = [IO.Path]::GetFullPath($OutFile)
    }
    catch {
        Write-SumiGuardSummary -Summary ([ordered]@{ mode = 'Create'; status = 'PATH_INVALID' }) -ExitCode 1
    }
    $storePrefix = $storeFull + [IO.Path]::DirectorySeparatorChar
    if ($outFull.StartsWith($storePrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $outFull.Equals($storeFull, [StringComparison]::OrdinalIgnoreCase)) {
        Write-SumiGuardSummary -Summary ([ordered]@{ mode = 'Create'; status = 'CHECKPOINT_PATH_INSIDE_STORE' }) -ExitCode 1
    }
    if (Test-Path -LiteralPath $outFull) {
        Write-SumiGuardSummary -Summary ([ordered]@{ mode = 'Create'; status = 'CHECKPOINT_FILE_EXISTS' }) -ExitCode 1
    }

    $result = SumiGuard.LogIntegrity\New-SumiGuardLogCheckpoint -StorePath $storeFull -Kind $Kind
    if (-not $result.success) {
        Write-SumiGuardSummary -Summary ([ordered]@{ mode = 'Create'; status = $result.status }) -ExitCode 1
    }

    $stream = $null
    try {
        [byte[]]$bytes = $utf8Strict.GetBytes(($result.checkpoint | ConvertTo-Json -Depth 4) + "`n")
        $stream = New-Object IO.FileStream(
            $outFull,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    catch {
        Write-SumiGuardSummary -Summary ([ordered]@{ mode = 'Create'; status = 'CHECKPOINT_WRITE_FAILED' }) -ExitCode 1
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    Write-SumiGuardSummary -Summary ([ordered]@{
        mode = 'Create'
        status = 'CHECKPOINT_WRITTEN'
        log_kind = $result.checkpoint.log_kind
        covered_bytes = $result.checkpoint.covered_bytes
        covered_lines = $result.checkpoint.covered_lines
        incomplete_tail_bytes = $result.incomplete_tail_bytes
        sha256 = $result.checkpoint.sha256
    }) -ExitCode 0
}

try {
    $text = [IO.File]::ReadAllText([IO.Path]::GetFullPath($CheckpointFile), $utf8Strict)
    $checkpoint = $text | ConvertFrom-Json -ErrorAction Stop
}
catch {
    Write-SumiGuardSummary -Summary ([ordered]@{ mode = 'Verify'; status = 'CHECKPOINT_UNREADABLE' }) -ExitCode 1
}

$verify = SumiGuard.LogIntegrity\Test-SumiGuardLogCheckpoint -StorePath $StorePath -Checkpoint $checkpoint
$summary = [ordered]@{ mode = 'Verify' }
foreach ($property in $verify.PSObject.Properties) {
    if ($property.Name -cne 'content_included') {
        $summary[$property.Name] = $property.Value
    }
}
$exitCode = 1
if ($verify.status -ceq 'INTACT') {
    $exitCode = 0
}
elseif ($verify.status -ceq 'MODIFIED' -or $verify.status -ceq 'TRUNCATED') {
    $exitCode = 2
}
Write-SumiGuardSummary -Summary $summary -ExitCode $exitCode
