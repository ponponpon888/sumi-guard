[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$cliPath = Join-Path $projectRoot 'tools\Show-SumiGuardRecords.ps1'
$localManifest = Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1'
$adapterManifest = Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1'
$readOnlyManifest = Join-Path $projectRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.ReadOnly.psd1'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempBase ('sumi-guard-readonly-cli-tests-' + [Guid]::NewGuid().ToString('N'))
$results = New-Object System.Collections.Generic.List[object]
$failure = $null

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw [InvalidOperationException]::new($Message) }
}

function Add-Result {
    param([string]$Name, [hashtable]$Evidence)
    $results.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $true
        evidence = [pscustomobject]$Evidence
    })
}

function Write-NdjsonFixture {
    param([string]$Path, $Value)
    $json = $Value | ConvertTo-Json -Compress -Depth 8
    [IO.File]::AppendAllText(
        $Path,
        $json + [Environment]::NewLine,
        (New-Object Text.UTF8Encoding($false)))
}

function Invoke-Cli {
    param(
        [string]$Action,
        [string]$ExecutionStore,
        [string]$LocalStore,
        [string]$ExecutionId = '',
        [string]$ObservationPath = ''
    )

    $quote = { param([string]$Value) "'" + $Value.Replace("'", "''") + "'" }
    $command = '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); & ' +
        (& $quote $cliPath) + ' -Action ' + (& $quote $Action) +
        ' -ExecutionStorePath ' + (& $quote $ExecutionStore) +
        ' -LocalStorePath ' + (& $quote $LocalStore)
    if (-not [string]::IsNullOrWhiteSpace($ExecutionId)) {
        $command += ' -ExecutionId ' + (& $quote $ExecutionId)
    }
    if (-not [string]::IsNullOrWhiteSpace($ObservationPath)) {
        $command += ' -OsObservationPath ' + (& $quote $ObservationPath)
    }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' +
        $command + '"'
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $psi
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{
            exit_code = $process.ExitCode
            stdout = $stdout
            stderr = $stderr
        }
    }
    finally { $process.Dispose() }
}

function Get-TreeSnapshot {
    param([string[]]$Roots)
    $snapshot = [ordered]@{}
    foreach ($root in $Roots) {
        foreach ($file in @(Get-ChildItem -LiteralPath $root -Force -File -Recurse | Sort-Object FullName)) {
            $relative = $file.FullName.Substring($root.Length).TrimStart('\')
            $key = $root + '|' + $relative
            $snapshot[$key] = '{0}|{1}|{2}' -f `
                $file.Length,
                $file.LastWriteTimeUtc.Ticks,
                (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return ($snapshot | ConvertTo-Json -Compress)
}

try {
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    Assert-Test `
        ($resolvedTestRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedTestRoot) -like 'sumi-guard-readonly-cli-tests-*') `
        'Unsafe test root.'
    [void](New-Item -ItemType Directory -Path $resolvedTestRoot -ErrorAction Stop)
    Import-Module $localManifest -Force -ErrorAction Stop
    Import-Module $adapterManifest -Force -ErrorAction Stop
    Import-Module $readOnlyManifest -Force -ErrorAction Stop
    $localModule = Get-Module SumiGuard.LocalStore -ErrorAction Stop
    $adapterModule = Get-Module SumiGuard.ExecutionAdapter -ErrorAction Stop
    $readOnlyModule = Get-Module SumiGuard.ExecutionAdapter.ReadOnly -ErrorAction Stop
    $expectedReadOnlyExports = @(
        'Get-SumiGuardCollectionFailureNotice',
        'Get-SumiGuardExecutionRecord'
    ) | Sort-Object
    $actualReadOnlyExports = @($readOnlyModule.ExportedFunctions.Keys) | Sort-Object
    Assert-Test (($actualReadOnlyExports -join '|') -ceq ($expectedReadOnlyExports -join '|')) `
        ('ReadOnly API export mismatch: expected={0}, actual={1}.' -f `
            ($expectedReadOnlyExports -join ','), ($actualReadOnlyExports -join ','))
    Add-Result -Name 'readonly_api_surface' -Evidence @{
        exported_functions = $actualReadOnlyExports -join ','
        write_and_decrypt_functions_exported = $false
    }

    $bodyStore = Join-Path $resolvedTestRoot 'body-store'
    $executionStore = Join-Path $resolvedTestRoot 'execution-store'
    $emptyBodyStore = Join-Path $resolvedTestRoot 'empty-body-store'
    $emptyExecutionStore = Join-Path $resolvedTestRoot 'empty-execution-store'
    foreach ($init in @(
        (Initialize-SumiGuardLocalStore -Path $bodyStore),
        (Initialize-SumiGuardExecutionStore -Path $executionStore),
        (Initialize-SumiGuardLocalStore -Path $emptyBodyStore),
        (Initialize-SumiGuardExecutionStore -Path $emptyExecutionStore))) {
        Assert-Test ([bool]$init.success) 'Store initialization failed.'
    }

    # Construct the synthetic secret at runtime so test reports never need to contain it.
    $syntheticSecret = @('CLI', 'SYNTHETIC', 'SECRET', [Guid]::NewGuid().ToString('N')) -join '_'
    $normalId = [Guid]::NewGuid().ToString('N')
    $normalSave = Save-SumiGuardExecutionIntent `
        -ExecutionStorePath $executionStore -LocalStorePath $bodyStore `
        -Body $syntheticSecret -ExecutionId $normalId
    Assert-Test $normalSave.success 'Normal fixture save failed.'
    $normalRecordResult = Get-SumiGuardExecutionRecord `
        -ExecutionStorePath $executionStore -LocalStorePath $bodyStore -ExecutionId $normalId
    $normalRecord = $normalRecordResult.records[0]
    $intentTime = [DateTimeOffset]::Parse([string]$normalRecord.occurred_at_utc)
    $outcomeTime = $intentTime.AddSeconds(1)
    Write-NdjsonFixture -Path (Join-Path $executionStore 'outcomes.ndjson') -Value ([ordered]@{
        schema_version = 1
        record_type = 'ExecutionOutcomeObserved'
        execution_id = $normalId
        occurred_at_utc = $outcomeTime.ToString('o')
        execution_status = 'SUCCEEDED'
        command_sha256 = [string]$normalRecord.body_sha256
        body_ref = [string]$normalRecord.body_ref
        body_reference_status = 'AVAILABLE'
        response_body_included = $false
    })
    Write-NdjsonFixture -Path (Join-Path $executionStore 'hook-runtime.ndjson') -Value ([ordered]@{
        schema_version = 1
        record_type = 'HookRuntimeObserved'
        execution_id = $normalId
        occurred_at_utc = $intentTime.ToString('o')
        hook_process_id = 41001
        content_status = 'CONTENT_NOT_INCLUDED'
    })
    $observationPath = Join-Path $resolvedTestRoot 'os-observations.ndjson'
    Write-NdjsonFixture -Path $observationPath -Value ([ordered]@{
        event_type = 'ProcessObserved'
        observed_at_utc = $intentTime.AddMilliseconds(100).ToString('o')
        process_start_time_utc = $intentTime.AddMilliseconds(50).ToString('o')
        source = 'SyntheticProcessFixture'
        process_id = 41001
        parent_process_id = 40000
    })
    Write-NdjsonFixture -Path $observationPath -Value ([ordered]@{
        event_type = 'ProcessObserved'
        observed_at_utc = $intentTime.AddMilliseconds(300).ToString('o')
        process_start_time_utc = $intentTime.AddMilliseconds(250).ToString('o')
        source = 'SyntheticProcessFixture'
        process_id = 41002
        parent_process_id = 40000
    })

    $brokenId = [Guid]::NewGuid().ToString('N')
    $brokenSave = Save-SumiGuardExecutionIntent `
        -ExecutionStorePath $executionStore -LocalStorePath $bodyStore `
        -Body $syntheticSecret -ExecutionId $brokenId
    Assert-Test $brokenSave.success 'Broken-reference fixture save failed.'
    $brokenPath = Join-Path $bodyStore ([string]$brokenSave.body_ref + '.sgb')
    Remove-Item -LiteralPath $brokenPath -Force -ErrorAction Stop

    $expiredId = [Guid]::NewGuid().ToString('N')
    try {
        & $localModule { $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow.AddDays(-31) } }
        & $adapterModule { $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow.AddDays(-31) } }
        $expiredSave = Save-SumiGuardExecutionIntent `
            -ExecutionStorePath $executionStore -LocalStorePath $bodyStore `
            -Body $syntheticSecret -ExecutionId $expiredId
    }
    finally {
        & $localModule { $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow } }
        & $adapterModule { $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow } }
    }
    Assert-Test $expiredSave.success 'Expired fixture save failed.'
    $cleanup = Invoke-SumiGuardExecutionRetentionCleanup `
        -ExecutionStorePath $executionStore -LocalStorePath $bodyStore `
        -RetentionDays 30 -Confirm:$false
    Assert-Test ($cleanup.success -and $cleanup.retention_tombstone_count -eq 1) `
        'Expired fixture cleanup failed.'

    $roots = @($executionStore, $bodyStore, $emptyExecutionStore, $emptyBodyStore, $resolvedTestRoot)
    $before = Get-TreeSnapshot -Roots $roots

    $list = Invoke-Cli -Action List -ExecutionStore $executionStore `
        -LocalStore $bodyStore -ObservationPath $observationPath
    Assert-Test ($list.exit_code -eq 0 -and [string]::IsNullOrEmpty($list.stderr)) `
        'List command failed or wrote stderr.'
    $listHasSuccess = $list.stdout.Contains('成功 (SUCCEEDED)')
    $listHasBody = $list.stdout.Contains('暗号化保存済み')
    $listHasCorrelation = $list.stdout.Contains('推定一致 (INFERRED_MATCH)')
    Assert-Test ($listHasSuccess -and $listHasBody -and $listHasCorrelation) `
        ('Normal list display was incomplete: success={0}, body={1}, correlation={2}.' -f `
            $listHasSuccess, $listHasBody, $listHasCorrelation)

    $detail = Invoke-Cli -Action Detail -ExecutionStore $executionStore `
        -LocalStore $bodyStore -ExecutionId $normalId -ObservationPath $observationPath
    Assert-Test ($detail.exit_code -eq 0 -and [string]::IsNullOrEmpty($detail.stderr)) `
        'Detail command failed or wrote stderr.'
    Assert-Test ($detail.stdout.Contains('OS候補数: 1') -and
        $detail.stdout.Contains('PID 41002') -and
        $detail.stdout.Contains('フック自身を除外後')) 'Detail correlation display was incomplete.'
    Assert-Test ($detail.stdout.Contains('原因は未特定')) 'Known stderr limitation was not preserved.'

    $noRecord = Invoke-Cli -Action List -ExecutionStore $emptyExecutionStore `
        -LocalStore $emptyBodyStore
    Assert-Test ($noRecord.exit_code -eq 0 -and $noRecord.stdout.Contains('記録なし (NO_RECORD)')) `
        'No-record display was incorrect.'
    Assert-Test (-not (Test-Path -LiteralPath `
        (Join-Path $emptyExecutionStore '.sumi-guard-execution-store.lock'))) `
        'Read-only no-record query created an execution lock file.'

    $broken = Invoke-Cli -Action Detail -ExecutionStore $executionStore `
        -LocalStore $bodyStore -ExecutionId $brokenId
    Assert-Test ($broken.exit_code -eq 0 -and $broken.stdout.Contains('参照切れ')) `
        'Broken-reference display was incorrect.'

    $expired = Invoke-Cli -Action Detail -ExecutionStore $executionStore `
        -LocalStore $bodyStore -ExecutionId $expiredId
    Assert-Test ($expired.exit_code -eq 0 -and $expired.stdout.Contains('保持期限により削除')) `
        'Expired display was incorrect.'

    $status = Invoke-Cli -Action StoreStatus -ExecutionStore $executionStore `
        -LocalStore $bodyStore
    Assert-Test ($status.exit_code -eq 0 -and $status.stdout.Contains('使用容量:') -and
        $status.stdout.Contains('参照切れ・参照不正: 1') -and
        $status.stdout.Contains('保持期限により削除: 1')) 'Store status was incomplete.'

    $eventsPath = Join-Path $executionStore 'events.ndjson'
    $exclusive = New-Object IO.FileStream(
        $eventsPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $denied = Invoke-Cli -Action List -ExecutionStore $executionStore -LocalStore $bodyStore
    }
    finally { $exclusive.Dispose() }
    $deniedHasReadFailure = $denied.stdout.Contains('読み取り失敗')
    $deniedHasCollectionFailed = $denied.stdout.Contains('COLLECTION_FAILED')
    $deniedStderrEmpty = [string]::IsNullOrEmpty($denied.stderr)
    Assert-Test ($denied.exit_code -ne 0 -and $deniedHasReadFailure -and
        $deniedHasCollectionFailed -and $deniedStderrEmpty) `
        ('Access-failure display was incorrect: exit={0}, readFailure={1}, collectionFailed={2}, stderrEmpty={3}.' -f `
            $denied.exit_code, $deniedHasReadFailure, $deniedHasCollectionFailed, $deniedStderrEmpty)

    $allOutput = @($list.stdout, $list.stderr, $detail.stdout, $detail.stderr,
        $noRecord.stdout, $broken.stdout, $expired.stdout, $status.stdout,
        $denied.stdout, $denied.stderr) -join "`n"
    Assert-Test (-not $allOutput.Contains($syntheticSecret)) `
        'Synthetic secret leaked to CLI output.'

    $after = Get-TreeSnapshot -Roots $roots
    Assert-Test ($before -ceq $after) 'A read-only CLI operation changed a saved file.'

    Add-Result -Name 'normal_list_and_detail' -Evidence @{
        execution_status = 'SUCCEEDED'
        body_status = 'AVAILABLE'
        correlation = 'INFERRED_MATCH'
        candidate_count = 1
    }
    Add-Result -Name 'distinct_empty_and_missing_states' -Evidence @{
        no_record = 'NO_RECORD'
        broken_reference = 'REFERENCE_MISSING'
        expired = 'DELETED_BY_RETENTION'
    }
    Add-Result -Name 'access_failure_is_sanitized' -Evidence @{
        cli_exit_code = $denied.exit_code
        state = 'COLLECTION_FAILED'
        stderr_empty = $true
    }
    Add-Result -Name 'read_only_and_no_plaintext' -Evidence @{
        file_snapshot_unchanged = $true
        empty_store_lock_not_created = $true
        synthetic_secret_absent_from_outputs = $true
        body_decryption_invoked = $false
    }
}
catch {
    $failure = [pscustomobject]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedCleanup = [IO.Path]::GetFullPath($testRoot)
        if ($resolvedCleanup.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedCleanup) -like 'sumi-guard-readonly-cli-tests-*') {
            Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$summary = [pscustomobject][ordered]@{
    success = ($null -eq $failure)
    test_count = $results.Count
    results = $results.ToArray()
    failure = $failure
    test_material_removed = (-not (Test-Path -LiteralPath $testRoot))
}
$summary | ConvertTo-Json -Depth 8
if ($null -ne $failure) { exit 1 }
