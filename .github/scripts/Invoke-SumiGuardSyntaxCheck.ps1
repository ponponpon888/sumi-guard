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

$extensions = @('.ps1', '.psm1', '.psd1')
$findings = New-Object System.Collections.Generic.List[object]
$checkedFiles = New-Object System.Collections.Generic.List[string]

$files = Get-ChildItem -LiteralPath $RepositoryRoot -Recurse -File |
    Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } |
    Sort-Object FullName

foreach ($file in $files) {
    $relative = $file.FullName.Substring($RepositoryRoot.Length).TrimStart('\')
    $checkedFiles.Add($relative)

    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors)

    if ($null -ne $parseErrors) {
        foreach ($parseError in @($parseErrors)) {
            $findings.Add([pscustomobject][ordered]@{
                file = $relative
                kind = 'PARSE_ERROR'
                line = $parseError.Extent.StartLineNumber
                detail = $parseError.Message
            })
        }
    }

    # Windows PowerShell 5.1 reads a script without a UTF-8 BOM using the active
    # ANSI code page. A non-ASCII script stored without the BOM is decoded as
    # mojibake, so fixed Japanese warning text can change meaning at runtime.
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $offset = 0
    if ($hasBom) {
        $offset = 3
    }

    $hasNonAscii = $false
    for ($index = $offset; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -gt 0x7F) {
            $hasNonAscii = $true
            break
        }
    }

    if ($hasNonAscii -and -not $hasBom) {
        $findings.Add([pscustomobject][ordered]@{
            file = $relative
            kind = 'MISSING_UTF8_BOM'
            line = 0
            detail = 'File contains non-ASCII bytes but has no UTF-8 BOM. Windows PowerShell 5.1 decodes it with the active ANSI code page.'
        })
    }
}

foreach ($finding in $findings) {
    Write-Host ("{0}: {1} (line {2}) {3}" -f $finding.kind, $finding.file, $finding.line, $finding.detail)
}

$summary = [pscustomobject][ordered]@{
    check = 'syntax-and-encoding'
    success = $findings.Count -eq 0
    powershell_version = $PSVersionTable.PSVersion.ToString()
    repository_root = $RepositoryRoot
    file_count = $checkedFiles.Count
    finding_count = $findings.Count
    findings = $findings.ToArray()
    files_parsed_without_execution = $true
    scripts_executed = $false
}
$summary | ConvertTo-Json -Depth 6

if ($findings.Count -gt 0) {
    exit 1
}
