Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SchemaVersion = 1
$script:MarkerFileName = '.sumi-guard-assessment-store.json'
$script:LockFileName = '.sumi-guard-assessment-store.lock'
$script:RecordFileName = 'assessments.ndjson'
$script:DefaultMaximumBytes = 1048576
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:SumiGuardAssessmentStoreTestForceAtomicWriteFailure = $false

# The accepted values of evaluation_origin, and which of them require a related
# execution record. SYNTHETIC_TEST must not carry one, so test data can never be
# mistaken for a record of something that ran. Every other origin must carry one,
# because the whole value of the record is that it points at a specific execution.
$script:EvaluationOrigins = @('SYNTHETIC_TEST', 'MANAGED_EXECUTION', 'CODEX_PRETOOLUSE_HOOK')
$script:EvaluationOriginsRequiringExecutionId = @('MANAGED_EXECUTION', 'CODEX_PRETOOLUSE_HOOK')

function New-SumiGuardAssessmentStoreResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $true)][string]$Status,
        [hashtable]$Properties = @{}
    )

    $result = [ordered]@{
        success = $Success
        status = $Status
    }
    foreach ($key in $Properties.Keys) {
        $result[$key] = $Properties[$key]
    }
    return [pscustomobject]$result
}

# Creates the tagged exception; the caller throws it. The code travels in
# Data so Get-SumiGuardAssessmentStoreErrorCode can turn it back into a fixed
# status, and the exception message stays empty so no input text can reach it.
function New-SumiGuardAssessmentStoreError {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Creates an in-memory exception object and changes no state.')]
    param([Parameter(Mandatory = $true)][string]$Code)

    $exception = [System.IO.InvalidDataException]::new()
    $exception.Data['SumiGuardAssessmentStoreCode'] = $Code
    return $exception
}

function Get-SumiGuardAssessmentStoreErrorCode {
    param(
        [AllowNull()]$Exception,
        [Parameter(Mandatory = $true)][string]$DefaultCode
    )

    $current = $Exception
    for ($level = 0; $level -le 4 -and $null -ne $current; $level++) {
        try {
            if ($current.Data.Contains('SumiGuardAssessmentStoreCode')) {
                return [string]$current.Data['SumiGuardAssessmentStoreCode']
            }
        }
        catch {
            # Deliberately empty: an exception whose Data cannot be read carries
            # no code at this level. Nothing is lost by it, because the caller
            # still receives a failure, and with the default code if no level
            # carries one. Reading further is the only alternative, which is
            # what the loop does next.
        }
        $current = $current.InnerException
    }
    return $DefaultCode
}

function Test-SumiGuardAssessmentSharingViolation {
    param([Parameter(Mandatory = $true)]$Exception)

    $current = $Exception
    for ($level = 0; $level -le 3 -and $null -ne $current; $level++) {
        $hex = ([BitConverter]::ToUInt32(
            [BitConverter]::GetBytes([int]$current.HResult), 0)).ToString(
                'X8', [Globalization.CultureInfo]::InvariantCulture)
        if ($hex -ceq '80070020' -or $hex -ceq '80070021') {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
}

function Test-SumiGuardAssessmentPathContainsReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $remainder = $fullPath.Substring($root.Length)
    $current = $root
    foreach ($segment in $remainder.Split(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) {
            continue
        }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return $true
        }
    }
    return $false
}

# Assessment records contain execution identifiers and detection metadata.
# Keep the same current-user/SYSTEM DACL boundary as the protected body store.
function Set-SumiGuardAssessmentStoreAcl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal helper runs only during explicit store initialization; fail closed if ACL setup fails.')]
    param([Parameter(Mandatory = $true)][string]$StorePath)

    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    foreach ($sid in @($userSid, $systemSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            $propagation,
            $allow)
        [void]$acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $StorePath -AclObject $acl -ErrorAction Stop
}

function Test-SumiGuardAssessmentAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequireProtected
    )

    $userSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $expected = @($userSid, 'S-1-5-18')
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if ($RequireProtected -and -not $acl.AreAccessRulesProtected) { return $false }
    $userFull = $false
    $systemFull = $false
    $aces = @($acl.GetAccessRules($true, $true,
        [System.Security.Principal.SecurityIdentifier]))
    foreach ($ace in $aces) {
        $sid = $ace.IdentityReference.Value
        if ($expected -cnotcontains $sid -or
            $ace.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            return $false
        }
        $full = (($ace.FileSystemRights -band
            [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
            [System.Security.AccessControl.FileSystemRights]::FullControl)
        if ($sid -ceq $userSid -and $full) { $userFull = $true }
        if ($sid -ceq 'S-1-5-18' -and $full) { $systemFull = $true }
    }
    return ($userFull -and $systemFull)
}

function Test-SumiGuardExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected
    )

    if ($null -eq $Value -or $Value -is [Array]) {
        return $false
    }
    $actual = @($Value.PSObject.Properties.Name)
    if ($actual.Count -ne $Expected.Count) {
        return $false
    }
    foreach ($name in $Expected) {
        if ($actual -cnotcontains $name) {
            return $false
        }
    }
    return $true
}

function Test-SumiGuardStringValue {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][int]$MaximumLength
    )

    return ($Value -is [string] -and
        $Value.Length -le $MaximumLength -and
        $Value -cmatch $Pattern)
}

function ConvertTo-SumiGuardUtcTimestamp {
    param([AllowNull()]$Value)

    if ($Value -isnot [string] -or $Value.Length -gt 64) {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }
    $timestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind,
        [ref]$timestamp)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }
    return $timestamp.ToUniversalTime().ToString('o')
}

function Get-SumiGuardAssessmentStoreMetadata {
    param([Parameter(Mandatory = $true)][string]$StorePath)

    $resolvedPath = [IO.Path]::GetFullPath($StorePath)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container) -or
        (Test-SumiGuardAssessmentPathContainsReparsePoint -Path $resolvedPath)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_INVALID')
    }
    if (-not (Test-SumiGuardAssessmentAcl -Path $resolvedPath -RequireProtected)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_ACL_INVALID')
    }
    $markerPath = Join-Path $resolvedPath $script:MarkerFileName
    $lockPath = Join-Path $resolvedPath $script:LockFileName
    $recordPath = Join-Path $resolvedPath $script:RecordFileName
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_LOCK_MISSING')
    }
    foreach ($path in @($markerPath, $lockPath, $recordPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_INVALID')
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_INVALID')
        }
        if (-not (Test-SumiGuardAssessmentAcl -Path $path)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_ACL_INVALID')
        }
    }
    try {
        $markerText = [IO.File]::ReadAllText($markerPath, $script:Utf8Strict)
        $marker = $markerText | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_INVALID')
    }
    if (-not (Test-SumiGuardExactProperties -Value $marker -Expected @(
        'schema_version', 'store_type', 'store_id', 'created_at_utc', 'maximum_bytes'))) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_INVALID')
    }
    if ($marker.schema_version -isnot [int] -or
        [int]$marker.schema_version -ne $script:SchemaVersion -or
        [string]$marker.store_type -cne 'SumiGuard.AssessmentStore' -or
        -not (Test-SumiGuardStringValue -Value $marker.store_id -Pattern '^[0-9a-f]{32}$' -MaximumLength 32) -or
        $marker.maximum_bytes -isnot [long] -and $marker.maximum_bytes -isnot [int] -or
        [long]$marker.maximum_bytes -lt 512 -or
        [long]$marker.maximum_bytes -gt 1073741824) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_INVALID')
    }
    $created = [DateTimeOffset]::MinValue
    if ($marker.created_at_utc -isnot [string] -or
        -not [DateTimeOffset]::TryParse(
            [string]$marker.created_at_utc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$created)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_INVALID')
    }
    $recordInfo = Get-Item -LiteralPath $recordPath -Force -ErrorAction Stop
    if ($recordInfo.Length -gt [long]$marker.maximum_bytes) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_CAPACITY_INVALID')
    }
    return [pscustomobject][ordered]@{
        store_path = $resolvedPath
        marker_path = $markerPath
        lock_path = $lockPath
        record_path = $recordPath
        store_id = [string]$marker.store_id
        maximum_bytes = [long]$marker.maximum_bytes
    }
}

function Enter-SumiGuardAssessmentWriteLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_LOCK_MISSING')
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        try {
            return New-Object IO.FileStream(
                $LockPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
        }
        catch {
            if (-not (Test-SumiGuardAssessmentSharingViolation -Exception $_.Exception)) {
                throw
            }
            $remaining = $TimeoutMilliseconds - $clock.ElapsedMilliseconds
            if ($remaining -le 0) { break }
            Start-Sleep -Milliseconds ([Math]::Min(25, $remaining))
        }
    }
    throw (New-SumiGuardAssessmentStoreError -Code 'STORE_LOCK_TIMEOUT')
}

function Enter-SumiGuardAssessmentReadLock {
    param(
        [Parameter(Mandatory = $true)][string]$LockPath,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_LOCK_MISSING')
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        try {
            return New-Object IO.FileStream(
                $LockPath,
                [IO.FileMode]::Open,
                [IO.FileAccess]::Read,
                [IO.FileShare]::Read)
        }
        catch {
            if (-not (Test-SumiGuardAssessmentSharingViolation -Exception $_.Exception)) {
                throw
            }
            $remaining = $TimeoutMilliseconds - $clock.ElapsedMilliseconds
            if ($remaining -le 0) { break }
            Start-Sleep -Milliseconds ([Math]::Min(25, $remaining))
        }
    }
    throw (New-SumiGuardAssessmentStoreError -Code 'STORE_LOCK_TIMEOUT')
}

function Test-SumiGuardKnownAssessmentReason {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [AllowNull()]$Reason
    )

    $reasonText = if ($null -eq $Reason) { '' } else { [string]$Reason }
    switch ($Status) {
        'DETECTED' { return $reasonText -cin @('', 'PARTIAL_UNASSESSABLE') }
        'NO_DETECTION' { return [string]::IsNullOrEmpty($reasonText) }
        'UNASSESSABLE' {
            return $reasonText -cin @(
                'CONTENT_UNAVAILABLE', 'UNSUPPORTED_LANGUAGE', 'PARSE_INCOMPLETE',
                'DYNAMIC_COMMAND_TARGET', 'ENCODED_PAYLOAD_NOT_INSPECTED',
                'NOT_EVALUATED_AT_CAPTURE')
        }
        'EVALUATION_FAILED' { return $reasonText -ceq 'RULE_ENGINE_ERROR' }
    }
    return $false
}

function ConvertTo-SumiGuardFindingForSave {
    param([Parameter(Mandatory = $true)]$Finding)

    if ($null -eq $Finding -or $Finding -is [Array]) {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }
    foreach ($name in @('rule_id', 'rule_version', 'severity', 'reason_code')) {
        if ($Finding.PSObject.Properties.Name -cnotcontains $name) {
            throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
        }
    }
    $ruleId = [string]$Finding.rule_id
    $ruleVersion = [string]$Finding.rule_version
    $severity = [string]$Finding.severity
    $reasonCode = [string]$Finding.reason_code
    $expected = switch ($ruleId) {
        'SG-CMD-001' { @('1.0.0', 'HIGH', 'DOWNLOAD_TO_EXECUTION_FLOW') }
        'SG-CMD-002' { @('1.0.0', 'HIGH', 'SECURITY_CONTROL_DISABLE_MUTATION') }
        'SG-CMD-003' { @('1.0.0', 'MEDIUM', 'PERSISTENCE_REGISTRATION_MUTATION') }
        default { $null }
    }
    if ($null -eq $expected -or
        $ruleVersion -cne $expected[0] -or
        $severity -cne $expected[1] -or
        $reasonCode -cne $expected[2]) {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }
    return [pscustomobject][ordered]@{
        rule_id = $ruleId
        rule_version = $ruleVersion
        severity = $severity
        reason_code = $reasonCode
    }
}

function ConvertTo-SumiGuardAssessmentRecordForSave {
    param(
        [Parameter(Mandatory = $true)]$Assessment,
        [Parameter(Mandatory = $true)][string]$EvaluationOrigin,
        [Parameter(Mandatory = $true)][string]$AssessmentScope,
        [AllowNull()]$RelatedExecutionId
    )

    if ($null -eq $Assessment -or $Assessment -is [Array]) {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }
    $required = @(
        'schema_version', 'record_id', 'record_type', 'execution_id',
        'occurred_at_utc', 'assessment_status', 'assessment_reason_code',
        'ruleset_version', 'findings', 'content_included',
        'source_excerpt_included', 'monitor_action', 'automatic_deny')
    foreach ($name in $required) {
        if ($Assessment.PSObject.Properties.Name -cnotcontains $name) {
            throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
        }
    }
    if ($Assessment.schema_version -isnot [int] -or
        [int]$Assessment.schema_version -ne 1 -or
        [string]$Assessment.record_type -cne 'ExecutionSafetyAssessment' -or
        -not (Test-SumiGuardStringValue -Value $Assessment.record_id -Pattern '^[0-9a-f]{32}$' -MaximumLength 32) -or
        -not (Test-SumiGuardStringValue -Value $Assessment.ruleset_version -Pattern '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$' -MaximumLength 128) -or
        $Assessment.content_included -ne $false -or
        $Assessment.source_excerpt_included -ne $false -or
        [string]$Assessment.monitor_action -cne 'WARN_ONLY' -or
        $Assessment.automatic_deny -ne $false) {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }
    $status = [string]$Assessment.assessment_status
    if ($status -cnotin @('DETECTED', 'NO_DETECTION', 'UNASSESSABLE', 'EVALUATION_FAILED') -or
        -not (Test-SumiGuardKnownAssessmentReason -Status $status -Reason $Assessment.assessment_reason_code)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }
    if ($EvaluationOrigin -cnotin $script:EvaluationOrigins -or
        $AssessmentScope -cne 'WINDOWS_POWERSHELL_COMMAND_V1') {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }

    $relatedId = $null
    if ($EvaluationOrigin -ceq 'SYNTHETIC_TEST') {
        if ($null -ne $RelatedExecutionId -and
            -not [string]::IsNullOrWhiteSpace([string]$RelatedExecutionId)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
        }
    }
    else {
        if (-not (Test-SumiGuardStringValue -Value $RelatedExecutionId -Pattern '^[0-9a-f]{32}$' -MaximumLength 32) -or
            -not (Test-SumiGuardStringValue -Value $Assessment.execution_id -Pattern '^[0-9a-f]{32}$' -MaximumLength 32) -or
            [string]$Assessment.execution_id -cne [string]$RelatedExecutionId) {
            throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
        }
        $relatedId = ([string]$RelatedExecutionId).ToLowerInvariant()
    }

    $inputFindings = @()
    if ($null -ne $Assessment.findings) {
        $inputFindings = @($Assessment.findings)
    }
    if ($inputFindings.Count -gt 16 -or
        ($status -ceq 'DETECTED' -and $inputFindings.Count -lt 1) -or
        ($status -cne 'DETECTED' -and $inputFindings.Count -ne 0)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
    }
    $storedFindings = New-Object System.Collections.Generic.List[object]
    $seenRuleIds = @{}
    foreach ($finding in $inputFindings) {
        $stored = ConvertTo-SumiGuardFindingForSave -Finding $finding
        if ($seenRuleIds.ContainsKey($stored.rule_id)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'INVALID_ASSESSMENT')
        }
        $seenRuleIds[$stored.rule_id] = $true
        $storedFindings.Add($stored)
    }
    $reason = if ([string]::IsNullOrEmpty([string]$Assessment.assessment_reason_code)) {
        $null
    }
    else {
        [string]$Assessment.assessment_reason_code
    }
    return [pscustomobject][ordered]@{
        schema_version = $script:SchemaVersion
        assessment_id = ([string]$Assessment.record_id).ToLowerInvariant()
        record_type = 'ExecutionSafetyAssessment'
        execution_id = $relatedId
        occurred_at_utc = ConvertTo-SumiGuardUtcTimestamp -Value $Assessment.occurred_at_utc
        assessment_status = $status
        assessment_reason_code = $reason
        assessment_scope = $AssessmentScope
        evaluation_origin = $EvaluationOrigin
        ruleset_version = [string]$Assessment.ruleset_version
        findings = $storedFindings.ToArray()
        content_included = $false
        source_excerpt_included = $false
    }
}

function ConvertFrom-SumiGuardStoredAssessmentRecord {
    param([Parameter(Mandatory = $true)]$Record)

    $expectedProperties = @(
        'schema_version', 'assessment_id', 'record_type', 'execution_id',
        'occurred_at_utc', 'assessment_status', 'assessment_reason_code',
        'assessment_scope', 'evaluation_origin', 'ruleset_version',
        'findings', 'content_included', 'source_excerpt_included')
    if (-not (Test-SumiGuardExactProperties -Value $Record -Expected $expectedProperties) -or
        $Record.schema_version -isnot [int] -or [int]$Record.schema_version -ne 1 -or
        [string]$Record.record_type -cne 'ExecutionSafetyAssessment' -or
        -not (Test-SumiGuardStringValue -Value $Record.assessment_id -Pattern '^[0-9a-f]{32}$' -MaximumLength 32) -or
        -not (Test-SumiGuardStringValue -Value $Record.assessment_status -Pattern '^[A-Z][A-Z0-9_]{0,63}$' -MaximumLength 64) -or
        -not (Test-SumiGuardStringValue -Value $Record.assessment_scope -Pattern '^[A-Z][A-Z0-9_]{0,63}$' -MaximumLength 64) -or
        -not (Test-SumiGuardStringValue -Value $Record.evaluation_origin -Pattern '^[A-Z][A-Z0-9_]{0,63}$' -MaximumLength 64) -or
        -not (Test-SumiGuardStringValue -Value $Record.ruleset_version -Pattern '^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$' -MaximumLength 128) -or
        $Record.content_included -ne $false -or
        $Record.source_excerpt_included -ne $false) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
    }
    try {
        $occurredAt = ConvertTo-SumiGuardUtcTimestamp -Value $Record.occurred_at_utc
    }
    catch {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
    }
    if ($null -ne $Record.assessment_reason_code -and
        -not (Test-SumiGuardStringValue -Value $Record.assessment_reason_code -Pattern '^[A-Z][A-Z0-9_]{0,63}$' -MaximumLength 64)) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
    }
    $executionId = $null
    if ($null -ne $Record.execution_id) {
        if (-not (Test-SumiGuardStringValue -Value $Record.execution_id -Pattern '^[0-9a-f]{32}$' -MaximumLength 32)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
        }
        $executionId = [string]$Record.execution_id
    }
    if ([string]$Record.evaluation_origin -ceq 'SYNTHETIC_TEST' -and $null -ne $executionId) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
    }
    if ([string]$Record.evaluation_origin -cin $script:EvaluationOriginsRequiringExecutionId -and
        $null -eq $executionId) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
    }
    $inputFindings = @()
    if ($null -ne $Record.findings) {
        $inputFindings = @($Record.findings)
    }
    if ($inputFindings.Count -gt 16) {
        throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
    }
    $findings = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($finding in $inputFindings) {
        if (-not (Test-SumiGuardExactProperties -Value $finding -Expected @(
            'rule_id', 'rule_version', 'severity', 'reason_code')) -or
            -not (Test-SumiGuardStringValue -Value $finding.rule_id -Pattern '^[A-Z][A-Z0-9-]{0,31}$' -MaximumLength 32) -or
            -not (Test-SumiGuardStringValue -Value $finding.rule_version -Pattern '^[0-9][0-9A-Za-z.-]{0,31}$' -MaximumLength 32) -or
            -not (Test-SumiGuardStringValue -Value $finding.severity -Pattern '^[A-Z][A-Z0-9_]{0,31}$' -MaximumLength 32) -or
            -not (Test-SumiGuardStringValue -Value $finding.reason_code -Pattern '^[A-Z][A-Z0-9_]{0,63}$' -MaximumLength 64)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
        }
        if ($seen.ContainsKey([string]$finding.rule_id)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
        }
        $knownExpected = switch ([string]$finding.rule_id) {
            'SG-CMD-001' { @('1.0.0', 'HIGH', 'DOWNLOAD_TO_EXECUTION_FLOW') }
            'SG-CMD-002' { @('1.0.0', 'HIGH', 'SECURITY_CONTROL_DISABLE_MUTATION') }
            'SG-CMD-003' { @('1.0.0', 'MEDIUM', 'PERSISTENCE_REGISTRATION_MUTATION') }
            default { $null }
        }
        if ($null -ne $knownExpected -and
            ([string]$finding.rule_version -cne $knownExpected[0] -or
                [string]$finding.severity -cne $knownExpected[1] -or
                [string]$finding.reason_code -cne $knownExpected[2])) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
        }
        $seen[[string]$finding.rule_id] = $true
        $findings.Add([pscustomobject][ordered]@{
            rule_id = [string]$finding.rule_id
            rule_version = [string]$finding.rule_version
            severity = [string]$finding.severity
            reason_code = [string]$finding.reason_code
        })
    }
    $storedStatus = [string]$Record.assessment_status
    if ($storedStatus -cin @(
        'DETECTED', 'NO_DETECTION', 'UNASSESSABLE', 'EVALUATION_FAILED')) {
        if (-not (Test-SumiGuardKnownAssessmentReason `
            -Status $storedStatus `
            -Reason $Record.assessment_reason_code) -or
            ($storedStatus -ceq 'DETECTED' -and $findings.Count -lt 1) -or
            ($storedStatus -cne 'DETECTED' -and $findings.Count -ne 0)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
        }
    }
    return [pscustomobject][ordered]@{
        schema_version = 1
        assessment_id = [string]$Record.assessment_id
        record_type = 'ExecutionSafetyAssessment'
        execution_id = $executionId
        occurred_at_utc = $occurredAt
        assessment_status = $storedStatus
        assessment_reason_code = if ($null -eq $Record.assessment_reason_code) { $null } else { [string]$Record.assessment_reason_code }
        assessment_scope = [string]$Record.assessment_scope
        evaluation_origin = [string]$Record.evaluation_origin
        ruleset_version = [string]$Record.ruleset_version
        findings = $findings.ToArray()
        content_included = $false
        source_excerpt_included = $false
    }
}

function Read-SumiGuardAssessmentRecordsUnsafe {
    param([Parameter(Mandatory = $true)][string]$RecordPath)

    [byte[]]$bytes = $null
    $reader = $null
    try {
        $bytes = [IO.File]::ReadAllBytes($RecordPath)
        if ($bytes.Length -eq 0) {
            return @()
        }
        if ($bytes[$bytes.Length - 1] -ne 10) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_FILE_INCOMPLETE')
        }
        try {
            $text = $script:Utf8Strict.GetString($bytes)
        }
        catch {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
        }
        $records = New-Object System.Collections.Generic.List[object]
        $seenIds = @{}
        $reader = New-Object IO.StringReader($text)
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ([string]::IsNullOrWhiteSpace($line)) {
                throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
            }
            try {
                $parsed = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_INVALID')
            }
            $record = ConvertFrom-SumiGuardStoredAssessmentRecord -Record $parsed
            if ($seenIds.ContainsKey($record.assessment_id)) {
                throw (New-SumiGuardAssessmentStoreError -Code 'STORE_RECORD_DUPLICATE')
            }
            $seenIds[$record.assessment_id] = $true
            $records.Add($record)
        }
        return $records.ToArray()
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $bytes -and $bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function New-SumiGuardAssessmentStore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [ValidateRange(512, 1073741824)][long]$MaximumBytes = $script:DefaultMaximumBytes
    )

    try {
        $resolvedPath = [IO.Path]::GetFullPath($StorePath)
        if (Test-SumiGuardAssessmentPathContainsReparsePoint -Path $resolvedPath) {
            return New-SumiGuardAssessmentStoreResult -Success $false -Status 'REPARSE_PATH_NOT_ALLOWED'
        }
        if (Test-Path -LiteralPath $resolvedPath) {
            $metadata = Get-SumiGuardAssessmentStoreMetadata -StorePath $resolvedPath
            return New-SumiGuardAssessmentStoreResult -Success $true -Status 'READY' -Properties @{
                store_path = $metadata.store_path
                created = $false
                maximum_bytes = $metadata.maximum_bytes
            }
        }
        $null = New-Item -ItemType Directory -Path $resolvedPath -ErrorAction Stop
        # Refuse to create marker or records if the private DACL cannot be set.
        Set-SumiGuardAssessmentStoreAcl -StorePath $resolvedPath
        if (-not (Test-SumiGuardAssessmentAcl -Path $resolvedPath -RequireProtected)) {
            throw (New-SumiGuardAssessmentStoreError -Code 'STORE_ACL_INVALID')
        }
        $marker = [ordered]@{
            schema_version = $script:SchemaVersion
            store_type = 'SumiGuard.AssessmentStore'
            store_id = [Guid]::NewGuid().ToString('N')
            created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            maximum_bytes = $MaximumBytes
        }
        [IO.File]::WriteAllText(
            (Join-Path $resolvedPath $script:MarkerFileName),
            ($marker | ConvertTo-Json -Compress),
            $script:Utf8Strict)
        $lockStream = New-Object IO.FileStream(
            (Join-Path $resolvedPath $script:LockFileName),
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::Read)
        $lockStream.Dispose()
        $recordStream = New-Object IO.FileStream(
            (Join-Path $resolvedPath $script:RecordFileName),
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::Read)
        $recordStream.Flush($true)
        $recordStream.Dispose()
        $metadata = Get-SumiGuardAssessmentStoreMetadata -StorePath $resolvedPath
        return New-SumiGuardAssessmentStoreResult -Success $true -Status 'CREATED' -Properties @{
            store_path = $metadata.store_path
            created = $true
            maximum_bytes = $metadata.maximum_bytes
        }
    }
    catch {
        return New-SumiGuardAssessmentStoreResult -Success $false -Status (
            Get-SumiGuardAssessmentStoreErrorCode -Exception $_.Exception -DefaultCode 'STORE_CREATE_FAILED')
    }
}

function Save-SumiGuardAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)]$Assessment,
        [Parameter(Mandatory = $true)][string]$EvaluationOrigin,
        [string]$AssessmentScope = 'WINDOWS_POWERSHELL_COMMAND_V1',
        [AllowNull()]$RelatedExecutionId = $null,
        [ValidateRange(100, 60000)][int]$LockTimeoutMilliseconds = 10000
    )

    $lock = $null
    $temporaryPath = $null
    $backupPath = $null
    [byte[]]$existingBytes = $null
    [byte[]]$recordBytes = $null
    [byte[]]$combinedBytes = $null
    try {
        try {
            $record = ConvertTo-SumiGuardAssessmentRecordForSave `
                -Assessment $Assessment `
                -EvaluationOrigin $EvaluationOrigin `
                -AssessmentScope $AssessmentScope `
                -RelatedExecutionId $RelatedExecutionId
        }
        catch {
            return New-SumiGuardAssessmentStoreResult -Success $false -Status 'INVALID_ASSESSMENT'
        }
        $metadata = Get-SumiGuardAssessmentStoreMetadata -StorePath $StorePath
        $lock = Enter-SumiGuardAssessmentWriteLock `
            -LockPath $metadata.lock_path `
            -TimeoutMilliseconds $LockTimeoutMilliseconds
        $existingRecords = @(Read-SumiGuardAssessmentRecordsUnsafe -RecordPath $metadata.record_path)
        if (@($existingRecords | Where-Object {
            $_.assessment_id -ceq $record.assessment_id }).Count -gt 0) {
            return New-SumiGuardAssessmentStoreResult -Success $false -Status 'DUPLICATE_ASSESSMENT_ID'
        }
        $recordJson = $record | ConvertTo-Json -Compress -Depth 8
        $recordBytes = $script:Utf8Strict.GetBytes($recordJson + [Environment]::NewLine)
        $existingBytes = [IO.File]::ReadAllBytes($metadata.record_path)
        $newLength = [long]$existingBytes.LongLength + [long]$recordBytes.LongLength
        if ($newLength -gt $metadata.maximum_bytes) {
            return New-SumiGuardAssessmentStoreResult -Success $false -Status 'CAPACITY_EXCEEDED' -Properties @{
                current_bytes = [long]$existingBytes.LongLength
                attempted_record_bytes = [long]$recordBytes.LongLength
                maximum_bytes = [long]$metadata.maximum_bytes
            }
        }
        $combinedBytes = New-Object byte[] $newLength
        if ($existingBytes.Length -gt 0) {
            [Array]::Copy($existingBytes, 0, $combinedBytes, 0, $existingBytes.Length)
        }
        [Array]::Copy(
            $recordBytes,
            0,
            $combinedBytes,
            $existingBytes.Length,
            $recordBytes.Length)
        $temporaryPath = Join-Path $metadata.store_path (
            '.pending-assessment-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        $stream = $null
        try {
            $stream = New-Object IO.FileStream(
                $temporaryPath,
                [IO.FileMode]::CreateNew,
                [IO.FileAccess]::Write,
                [IO.FileShare]::None)
            $stream.Write($combinedBytes, 0, $combinedBytes.Length)
            $stream.Flush($true)
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        if ($script:SumiGuardAssessmentStoreTestForceAtomicWriteFailure) {
            throw (New-SumiGuardAssessmentStoreError -Code 'ATOMIC_WRITE_FAILED')
        }
        $backupPath = Join-Path $metadata.store_path (
            '.previous-assessment-' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::Replace($temporaryPath, $metadata.record_path, $backupPath)
            $temporaryPath = $null
        }
        catch {
            throw (New-SumiGuardAssessmentStoreError -Code 'ATOMIC_WRITE_FAILED')
        }
        try {
            [IO.File]::Delete($backupPath)
            $backupPath = $null
        }
        catch {
            throw (New-SumiGuardAssessmentStoreError -Code 'SAVED_BACKUP_CLEANUP_FAILED')
        }
        return New-SumiGuardAssessmentStoreResult -Success $true -Status 'SAVED' -Properties @{
            assessment_id = $record.assessment_id
            execution_id = $record.execution_id
            evaluation_origin = $record.evaluation_origin
            assessment_status = $record.assessment_status
            record_bytes = [long]$recordBytes.LongLength
            store_bytes = $newLength
            content_included = $false
        }
    }
    catch {
        return New-SumiGuardAssessmentStoreResult -Success $false -Status (
            Get-SumiGuardAssessmentStoreErrorCode -Exception $_.Exception -DefaultCode 'SAVE_FAILED')
    }
    finally {
        if ($null -ne $lock) { $lock.Dispose() }
        # Both deletes below are reached only when the save did not complete,
        # because the success path clears each path as soon as it is done with
        # it. The caller therefore already has a failure result with its own
        # code, so these catches are deliberately empty: they cannot turn a
        # failure into a success. That a failed save leaves no residue is a
        # separate claim, and it is asserted by the test case
        # ATOMIC_SAVE_FAILURE_PRESERVES_STORE rather than trusted here.
        if ($null -ne $temporaryPath -and
            (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
            try { [IO.File]::Delete($temporaryPath) } catch { }
        }
        if ($null -ne $backupPath -and
            (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            try { [IO.File]::Delete($backupPath) } catch { }
        }
        foreach ($bytes in @($existingBytes, $recordBytes, $combinedBytes)) {
            if ($null -ne $bytes -and $bytes.Length -gt 0) {
                [Array]::Clear($bytes, 0, $bytes.Length)
            }
        }
    }
}

function Get-SumiGuardAssessmentRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [string]$AssessmentId = '',
        [ValidateRange(100, 60000)][int]$LockTimeoutMilliseconds = 10000
    )

    if (-not [string]::IsNullOrWhiteSpace($AssessmentId) -and
        $AssessmentId -cnotmatch '^[0-9a-f]{32}$') {
        return New-SumiGuardAssessmentStoreResult -Success $false -Status 'INVALID_ASSESSMENT_ID' -Properties @{
            records = @()
        }
    }
    $lock = $null
    try {
        $metadata = Get-SumiGuardAssessmentStoreMetadata -StorePath $StorePath
        $lock = Enter-SumiGuardAssessmentReadLock `
            -LockPath $metadata.lock_path `
            -TimeoutMilliseconds $LockTimeoutMilliseconds
        $records = @(Read-SumiGuardAssessmentRecordsUnsafe -RecordPath $metadata.record_path)
        if (-not [string]::IsNullOrWhiteSpace($AssessmentId)) {
            $records = @($records | Where-Object {
                $_.assessment_id -ceq $AssessmentId })
        }
        $status = if (-not [string]::IsNullOrWhiteSpace($AssessmentId) -and
            $records.Count -eq 0) {
            'RECORD_NOT_FOUND'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($AssessmentId)) {
            'RECORD_FOUND'
        }
        else {
            'RECORDS_READ'
        }
        return New-SumiGuardAssessmentStoreResult -Success $true -Status $status -Properties @{
            record_count = $records.Count
            records = $records
            content_included = $false
        }
    }
    catch {
        return New-SumiGuardAssessmentStoreResult -Success $false -Status (
            Get-SumiGuardAssessmentStoreErrorCode -Exception $_.Exception -DefaultCode 'READ_FAILED') -Properties @{
            record_count = 0
            records = @()
            content_included = $false
        }
    }
    finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

Export-ModuleMember -Function @(
    'New-SumiGuardAssessmentStore',
    'Save-SumiGuardAssessment',
    'Get-SumiGuardAssessmentRecord')
