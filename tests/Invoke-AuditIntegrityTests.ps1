# Verify audit-log digests and structural failures using disposable fixtures.
[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$tool = Join-Path $root 'tools\Test-SumiGuardAuditIntegrity.ps1'
$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$utf8 = New-Object Text.UTF8Encoding($false, $true)
$base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$work = Join-Path $base ('sumi-guard-audit-integrity-' + [Guid]::NewGuid().ToString('N'))
$cases = New-Object System.Collections.Generic.List[object]
$stage = 'INIT'
$failure = $null

function Add-Check {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory results for a disposable synthetic test only.')]
    param([string]$Name, [bool]$Pass)
    $script:cases.Add([pscustomobject][ordered]@{ name = $Name; pass = $Pass })
}
function Invoke-IntegrityCheck {
    param([string]$Kind, [string]$Store, [string]$Mode = 'Snapshot', [string]$Baseline = '')
    $args51 = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', $tool,
        '-StoreKind', $Kind, '-StorePath', $Store, '-Action', $Mode)
    if ($Baseline) { $args51 += @('-BaselinePath', $Baseline) }
    $output = @(& $ps51 @args51)
    $code = $LASTEXITCODE
    $raw = ($output -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{
        exit_code = $code
        raw = $raw
        data = ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
}
function New-StoreFixture {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only GUID-named disposable test fixtures in TEMP.')]
    param([string]$Path, [string]$Kind)
    $null = New-Item -ItemType Directory -Path $Path -ErrorAction Stop
    if ($Kind -ceq 'Execution') {
        $markerName = '.sumi-guard-execution-store.json'
        $lockName = '.sumi-guard-execution-store.lock'
        $marker = @{schema_version=1;store_id=[Guid]::NewGuid().ToString('N');body_provider='SumiGuard.LocalStore'}
    }
    else {
        $markerName = '.sumi-guard-assessment-store.json'
        $lockName = '.sumi-guard-assessment-store.lock'
        $marker = @{
            schema_version=1;store_id=[Guid]::NewGuid().ToString('N')
            store_type='SumiGuard.AssessmentStore';maximum_bytes=1048576
            created_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
        }
    }
    [IO.File]::WriteAllText((Join-Path $Path $markerName),($marker | ConvertTo-Json -Compress),$utf8)
    $lockStream = New-Object IO.FileStream(
        (Join-Path $Path $lockName),[IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,[IO.FileShare]::Read)
    $lockStream.Dispose()
}
try {
    if ((Split-Path -Leaf $work) -cnotmatch '^sumi-guard-audit-integrity-[0-9a-f]{32}$' -or
        -not $work.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) {
        throw [InvalidOperationException]::new('Unsafe temp root')
    }
    $null = New-Item -ItemType Directory -Path $work -ErrorAction Stop
    $exec = Join-Path $work 'execution-store'
    New-StoreFixture -Path $exec -Kind Execution
    $eventPath = Join-Path $exec 'events.ndjson'
    $sampleEvent = [ordered]@{
        schema_version=1;record_id=[Guid]::NewGuid().ToString('N')
        record_type='ExecutionIntentRecorded';execution_id=[Guid]::NewGuid().ToString('N')
        occurred_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
        body_sha256=('a' * 64);content_status='HASH_ONLY'
        collection_status='RECORDS_FOUND';body_ref=$null
    }
    $original = ($sampleEvent | ConvertTo-Json -Compress) + [Environment]::NewLine
    [IO.File]::WriteAllText($eventPath,$original,$utf8)
    $checksum = (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash
    $stage = 'SNAPSHOT'
    $snap = Invoke-IntegrityCheck -Kind Execution -Store $exec
    Add-Check -Name 'UNANCHORED_STRUCTURE_VALID' -Pass ($snap.exit_code -eq 0 -and
        $snap.data.status -ceq 'STRUCTURE_VALID_UNANCHORED' -and
        @($snap.data.files).Count -eq 3 -and $snap.data.files[0].record_count -eq 1)
    Add-Check -Name 'READ_ONLY_AND_NO_MISSING_FILES_CREATED' -Pass (
        (Get-FileHash -LiteralPath $eventPath -Algorithm SHA256).Hash -ceq $checksum -and
        -not (Test-Path -LiteralPath (Join-Path $exec 'failures.ndjson')) -and
        -not (Test-Path -LiteralPath (Join-Path $exec 'retention.ndjson')))
    $trusted = Join-Path $work 'trusted-baseline.json'
    [IO.File]::WriteAllText($trusted,$snap.raw,$utf8)
    $stage = 'COMPARE'
    $ok = Invoke-IntegrityCheck -Kind Execution -Store $exec -Mode Compare -Baseline $trusted
    Add-Check -Name 'TRUSTED_BASELINE_MATCHES' -Pass ($ok.exit_code -eq 0 -and
        $ok.data.status -ceq 'MATCHES_SUPPLIED_BASELINE')
    $stage = 'TAMPER'
    [IO.File]::WriteAllText($eventPath,$original.Replace(('a'*64),('b'*64)),$utf8)
    $tampered = Invoke-IntegrityCheck -Kind Execution -Store $exec -Mode Compare -Baseline $trusted
    Add-Check -Name 'VALID_JSON_TAMPER_MISMATCH' -Pass ($tampered.exit_code -eq 1 -and
        $tampered.data.status -ceq 'BASELINE_MISMATCH')
    [IO.File]::WriteAllText($eventPath,$original,$utf8)
    $stage = 'MARKER_MODIFIED'
    $markerFile = Join-Path $exec '.sumi-guard-execution-store.json'
    $markerText = [IO.File]::ReadAllText($markerFile,$utf8)
    try {
        $changedMarker = $markerText | ConvertFrom-Json
        $changedMarker.store_id = [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($markerFile,($changedMarker | ConvertTo-Json -Compress),$utf8)
        $markerMismatch = Invoke-IntegrityCheck -Kind Execution -Store $exec -Mode Compare -Baseline $trusted
        Add-Check -Name 'VALID_MARKER_CHANGE_MISMATCH' -Pass ($markerMismatch.exit_code -eq 1 -and
            $markerMismatch.data.status -ceq 'BASELINE_MISMATCH')
    }
    finally { [IO.File]::WriteAllText($markerFile,$markerText,$utf8) }
    $stage = 'TRUNCATE'
    [IO.File]::WriteAllText($eventPath,$original.TrimEnd([char[]]@([char]13,[char]10)),$utf8)
    $bad = Invoke-IntegrityCheck -Kind Execution -Store $exec
    Add-Check -Name 'TRUNCATED_LINE_REJECTED' -Pass ($bad.exit_code -eq 2 -and
        $bad.data.failure_code -ceq 'AUDIT_FILE_INCOMPLETE')
    [IO.File]::WriteAllText($eventPath,$original,$utf8)
    $stage = 'DUPLICATE'
    [IO.File]::WriteAllText($eventPath,($original+$original),$utf8)
    $duplicate = Invoke-IntegrityCheck -Kind Execution -Store $exec
    Add-Check -Name 'DUPLICATE_ID_REJECTED' -Pass ($duplicate.exit_code -eq 2 -and
        $duplicate.data.failure_code -ceq 'RECORD_DUPLICATE')
    [IO.File]::WriteAllText($eventPath,$original,$utf8)
    $stage = 'CONTENT_FIELD'
    $line = $original.TrimEnd([char[]]@([char]13,[char]10))
    $sensitive = $line.Substring(0,$line.Length-1) + ',"body":"SYNTHETIC_SHOULD_NOT_BE_LOGGED"}' + [Environment]::NewLine
    [IO.File]::WriteAllText($eventPath,$sensitive,$utf8)
    $leak = Invoke-IntegrityCheck -Kind Execution -Store $exec
    Add-Check -Name 'CONTENT_FIELD_REJECTED_WITHOUT_ECHO' -Pass ($leak.exit_code -eq 2 -and
        $leak.data.failure_code -ceq 'UNEXPECTED_CONTENT_FIELD' -and
        -not $leak.raw.Contains('SYNTHETIC_SHOULD_NOT_BE_LOGGED'))
    [IO.File]::WriteAllText($eventPath,$original,$utf8)
    $stage = 'RETENTION'
    $retention = [ordered]@{
        schema_version=1;record_id=[Guid]::NewGuid().ToString('N')
        record_type='BodyRetentionExpired';execution_id=$sampleEvent.execution_id
        body_ref=[Guid]::NewGuid().ToString('N')
    }
    $retentionPath = Join-Path $exec 'retention.ndjson'
    [IO.File]::WriteAllText($retentionPath,(($retention | ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8)
    $orphan = Invoke-IntegrityCheck -Kind Execution -Store $exec
    Add-Check -Name 'UNMATCHED_RETENTION_REF_REJECTED' -Pass ($orphan.exit_code -eq 2 -and
        $orphan.data.failure_code -ceq 'RETENTION_REFERENCE_MISSING')
    [IO.File]::Delete($retentionPath)
    $stage = 'ADDED_FILE'
    $newFile = Join-Path $exec 'failures.ndjson'
    [IO.File]::WriteAllText($newFile,'',$utf8)
    $added = Invoke-IntegrityCheck -Kind Execution -Store $exec -Mode Compare -Baseline $trusted
    Add-Check -Name 'NEW_EMPTY_AUDIT_FILE_IS_A_CHANGE' -Pass ($added.exit_code -eq 1 -and
        $added.data.status -ceq 'BASELINE_MISMATCH')
    [IO.File]::Delete($newFile)
    $stage = 'UNTRUSTED_BASELINE'
    $inside = Join-Path $exec 'baseline.json'
    [IO.File]::WriteAllText($inside,$snap.raw,$utf8)
    $unsafe = Invoke-IntegrityCheck -Kind Execution -Store $exec -Mode Compare -Baseline $inside
    Add-Check -Name 'BASELINE_INSIDE_STORE_REJECTED' -Pass ($unsafe.exit_code -eq 2 -and
        $unsafe.data.failure_code -ceq 'BASELINE_INSIDE_STORE')
    [IO.File]::Delete($inside)
    $stage = 'ASSESSMENT'
    $assessmentStore = Join-Path $work 'assessment-store'
    New-StoreFixture -Path $assessmentStore -Kind Assessment
    $assessment = [ordered]@{
        schema_version=1;assessment_id=[Guid]::NewGuid().ToString('N')
        record_type='ExecutionSafetyAssessment';execution_id=$null
        assessment_status='NO_DETECTION';content_included=$false
        source_excerpt_included=$false
    }
    [IO.File]::WriteAllText((Join-Path $assessmentStore 'assessments.ndjson'),
        (($assessment | ConvertTo-Json -Compress)+[Environment]::NewLine),$utf8)
    $assessmentRead = Invoke-IntegrityCheck -Kind Assessment -Store $assessmentStore
    Add-Check -Name 'ASSESSMENT_SNAPSHOT_VALID' -Pass ($assessmentRead.exit_code -eq 0 -and
        @($assessmentRead.data.files).Count -eq 1 -and
        $assessmentRead.data.files[0].record_count -eq 1)
    $stage = 'MISSING_LOCK'
    $lockPath = Join-Path $exec '.sumi-guard-execution-store.lock'
    [IO.File]::Delete($lockPath)
    $locked = Invoke-IntegrityCheck -Kind Execution -Store $exec
    Add-Check -Name 'MISSING_LOCK_NOT_CREATED' -Pass ($locked.exit_code -eq 2 -and
        $locked.data.failure_code -ceq 'LOCK_MISSING' -and
        -not (Test-Path -LiteralPath $lockPath))
}
catch {
    $failure = [pscustomobject]@{
        stage = [string]$stage
        exception_type = $_.Exception.GetType().FullName
    }
}
finally {
    if (Test-Path -LiteralPath $work) {
        $resolved = [IO.Path]::GetFullPath($work)
        if ($resolved.StartsWith($base,[StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolved) -match '^sumi-guard-audit-integrity-[0-9a-f]{32}$') {
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
        }
        else { $failure = [pscustomobject]@{stage='CLEANUP_REFUSED'} }
    }
}
$failed = @($cases | Where-Object { -not $_.pass })
$passed = ($null -eq $failure -and $failed.Count -eq 0)
[pscustomobject][ordered]@{
    success=$passed
    test_count=$cases.Count
    passed_count=$cases.Count-$failed.Count
    failed_cases=@($failed | ForEach-Object { $_.name })
    failure=$failure
    fixture_cleaned=(-not (Test-Path -LiteralPath $work))
    production_data_read=$false
    commands_executed_from_fixtures=$false
} | ConvertTo-Json -Compress -Depth 5
if ($passed) { exit 0 } else { exit 1 }
