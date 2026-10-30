<#
    Prepares a temporary copy of SumiGuard.AssessmentStore and runs its existing
    New-SumiGuardAssessmentStore implementation against two isolated paths.
    It never changes the source module or an existing store.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceModule = Join-Path $repoRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psm1'
$sourceManifest = Join-Path $repoRoot 'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1'
$diagnosticRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'sumi-guard-assessment-stage-diagnostic-' + [Guid]::NewGuid().ToString('N'))

function Get-SafeDiagnosticResult {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)]$Result
    )

    $names = @($Result.PSObject.Properties.Name)
    return [pscustomobject][ordered]@{
        case = $Label
        status = if ($names -contains 'status') { [string]$Result.status } else { 'DIAGNOSTIC_UNAVAILABLE' }
        stage = if ($names -contains 'diagnostic_stage') { [string]$Result.diagnostic_stage } else { 'DIAGNOSTIC_UNAVAILABLE' }
        exception_type = if ($names -contains 'diagnostic_exception_type') { $Result.diagnostic_exception_type } else { $null }
        exception_hresult = if ($names -contains 'diagnostic_exception_hresult') { $Result.diagnostic_exception_hresult } else { $null }
        inner_exception_type = if ($names -contains 'diagnostic_inner_exception_type') { $Result.diagnostic_inner_exception_type } else { $null }
        inner_exception_hresult = if ($names -contains 'diagnostic_inner_exception_hresult') { $Result.diagnostic_inner_exception_hresult } else { $null }
    }
}

try {
    New-Item -ItemType Directory -Path $diagnosticRoot -ErrorAction Stop | Out-Null
    $copyRoot = Join-Path $diagnosticRoot 'SumiGuard.AssessmentStore'
    New-Item -ItemType Directory -Path $copyRoot -ErrorAction Stop | Out-Null
    $copyModule = Join-Path $copyRoot 'SumiGuard.AssessmentStore.psm1'
    $copyManifest = Join-Path $copyRoot 'SumiGuard.AssessmentStore.psd1'
    Copy-Item -LiteralPath $sourceModule -Destination $copyModule -ErrorAction Stop
    Copy-Item -LiteralPath $sourceManifest -Destination $copyManifest -ErrorAction Stop

    # These replacements alter only the existing initializer's local stage value
    # and its catch return. No function, ACL rule, or success path is replaced.
    $moduleText = [IO.File]::ReadAllText($copyModule, [Text.UTF8Encoding]::new($false, $true))
    $newLine = if ($moduleText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $tokens = $null
    $parseErrors = $null
    $moduleAst = [Management.Automation.Language.Parser]::ParseInput($moduleText, [ref]$tokens, [ref]$parseErrors)
    $storeInitializers = @($moduleAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'New-SumiGuardAssessmentStore'
    }, $true))
    if ($parseErrors.Count -ne 0 -or $storeInitializers.Count -ne 1) {
        throw [InvalidOperationException]::new('ANCHOR_FUNCTION_RANGE:0')
    }
    $initializer = $storeInitializers[0]
    $functionStart = $initializer.Extent.StartOffset
    $functionLength = $initializer.Extent.EndOffset - $functionStart
    $functionText = $moduleText.Substring($functionStart, $functionLength)
    $replacements = @(
        [pscustomobject]@{ id = 'PATH_RESOLUTION'; find = '        $resolvedPath = [IO.Path]::GetFullPath($StorePath)'; replace = '        $diagnosticStage = ''PATH_RESOLUTION''' + $newLine + '        $resolvedPath = [IO.Path]::GetFullPath($StorePath)'; },
        [pscustomobject]@{ id = 'DIRECTORY_CREATE'; find = '        $null = New-Item -ItemType Directory -Path $resolvedPath -ErrorAction Stop'; replace = '        $diagnosticStage = ''DIRECTORY_CREATE''' + $newLine + '        $null = New-Item -ItemType Directory -Path $resolvedPath -ErrorAction Stop'; },
        [pscustomobject]@{ id = 'ACL_SET'; find = '        Set-SumiGuardAssessmentStoreAcl -StorePath $resolvedPath'; replace = '        $diagnosticStage = ''ACL_SET''' + $newLine + '        Set-SumiGuardAssessmentStoreAcl -StorePath $resolvedPath'; },
        [pscustomobject]@{ id = 'ACL_VERIFY'; find = '        if (-not (Test-SumiGuardAssessmentAcl -Path $resolvedPath -RequireProtected)) {'; replace = '        $diagnosticStage = ''ACL_VERIFY''' + $newLine + '        if (-not (Test-SumiGuardAssessmentAcl -Path $resolvedPath -RequireProtected)) {'; },
        [pscustomobject]@{ id = 'MARKER_CREATE'; find = '        [IO.File]::WriteAllText('; replace = '        $diagnosticStage = ''MARKER_CREATE''' + $newLine + '        [IO.File]::WriteAllText('; },
        [pscustomobject]@{ id = 'LOCK_CREATE'; find = '        $lockStream = New-Object IO.FileStream('; replace = '        $diagnosticStage = ''LOCK_CREATE''' + $newLine + '        $lockStream = New-Object IO.FileStream('; },
        [pscustomobject]@{ id = 'RECORD_CREATE'; find = '        $recordStream = New-Object IO.FileStream('; replace = '        $diagnosticStage = ''RECORD_CREATE''' + $newLine + '        $recordStream = New-Object IO.FileStream('; },
        [pscustomobject]@{ id = 'FINAL_METADATA_VERIFY'; find = '        $metadata = Get-SumiGuardAssessmentStoreMetadata -StorePath $resolvedPath' + $newLine + '        return New-SumiGuardAssessmentStoreResult -Success $true -Status ''CREATED'''; replace = '        $diagnosticStage = ''FINAL_METADATA_VERIFY''' + $newLine + '        $metadata = Get-SumiGuardAssessmentStoreMetadata -StorePath $resolvedPath' + $newLine + '        return New-SumiGuardAssessmentStoreResult -Success $true -Status ''CREATED'''; }
    )
    foreach ($replacement in $replacements) {
        $matchCount = 0
        $offset = 0
        while (($offset = $functionText.IndexOf($replacement.find, $offset, [StringComparison]::Ordinal)) -ge 0) {
            $matchCount++
            $offset += $replacement.find.Length
        }
        if ($matchCount -ne 1) {
            throw [InvalidOperationException]::new(('ANCHOR_{0}:{1}' -f $replacement.id, $matchCount))
        }
        $functionText = $functionText.Replace($replacement.find, $replacement.replace)
    }
    $oldCatch = '    catch {' + $newLine +
        '        return New-SumiGuardAssessmentStoreResult -Success $false -Status (' + $newLine +
        '            Get-SumiGuardAssessmentStoreErrorCode -Exception $_.Exception -DefaultCode ''STORE_CREATE_FAILED'')' + $newLine +
        '    }'
    $newCatch = '    catch {' + $newLine +
        '        $diagnosticException = $_.Exception' + $newLine +
        '        $diagnosticInner = $diagnosticException.InnerException' + $newLine +
        '        return New-SumiGuardAssessmentStoreResult -Success $false -Status (' + $newLine +
        '            Get-SumiGuardAssessmentStoreErrorCode -Exception $diagnosticException -DefaultCode ''STORE_CREATE_FAILED'') -Properties @{' + $newLine +
        '            diagnostic_stage = $diagnosticStage' + $newLine +
        '            diagnostic_exception_type = $diagnosticException.GetType().FullName' + $newLine +
        '            diagnostic_exception_hresult = (''0x{0:X8}'' -f ([int32]$diagnosticException.HResult))' + $newLine +
        '            diagnostic_inner_exception_type = if ($null -eq $diagnosticInner) { $null } else { $diagnosticInner.GetType().FullName }' + $newLine +
        '            diagnostic_inner_exception_hresult = if ($null -eq $diagnosticInner) { $null } else { (''0x{0:X8}'' -f ([int32]$diagnosticInner.HResult)) }' + $newLine +
        '        }' + $newLine +
        '    }'
    $catchCount = 0
    $offset = 0
    while (($offset = $functionText.IndexOf($oldCatch, $offset, [StringComparison]::Ordinal)) -ge 0) {
        $catchCount++
        $offset += $oldCatch.Length
    }
    if ($catchCount -ne 1) {
        throw [InvalidOperationException]::new(('ANCHOR_CATCH_RETURN:{0}' -f $catchCount))
    }
    $functionText = $functionText.Replace($oldCatch, $newCatch)
    $moduleText = $moduleText.Substring(0, $functionStart) + $functionText +
        $moduleText.Substring($functionStart + $functionLength)
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($moduleText, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count -ne 0) {
        throw [InvalidOperationException]::new('ANCHOR_GENERATED_MODULE_PARSE:0')
    }
    [IO.File]::WriteAllText($copyModule, $moduleText, [Text.UTF8Encoding]::new($true))

    # The manifest already exports New-SumiGuardAssessmentStore; no temporary
    # public API is added. Importing the copy therefore uses the same call site.
    Import-Module $copyManifest -Force -ErrorAction Stop
    $shallow = New-SumiGuardAssessmentStore -StorePath (Join-Path $diagnosticRoot 'shallow-store')
    $caseRoot = Join-Path $diagnosticRoot 'claude-accepts'
    New-Item -ItemType Directory -Path $caseRoot -ErrorAction Stop | Out-Null
    $nested = New-SumiGuardAssessmentStore -StorePath (Join-Path $caseRoot 'assessment-store')
    @(
        Get-SafeDiagnosticResult -Label 'SHALLOW' -Result $shallow
        Get-SafeDiagnosticResult -Label 'TEST_EQUIVALENT' -Result $nested
    ) | ConvertTo-Json -Depth 5
}
finally {
    if (Test-Path -LiteralPath $diagnosticRoot) {
        Remove-Item -LiteralPath $diagnosticRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
