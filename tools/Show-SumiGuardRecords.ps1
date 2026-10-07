[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('List', 'Detail', 'StoreStatus')]
    [string]$Action,

    [Parameter(Mandatory = $true)][string]$ExecutionStorePath,
    [Parameter(Mandatory = $true)][string]$LocalStorePath,
    [string]$ExecutionId = '',
    [string]$OsObservationPath = '',
    [ValidateRange(1, 2147483647)][int]$MaxItemBytes = 1MB,
    [ValidateRange(1, 9223372036854775807)][long]$MaxTotalBytes = 250MB,
    [ValidateRange(1, 36500)][int]$RetentionDays = 30
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:Jst = [TimeZoneInfo]::FindSystemTimeZoneById('Tokyo Standard Time')
$script:AdapterManifest = Join-Path (Split-Path -Parent $PSScriptRoot) `
    'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1'

function Get-Value {
    param($Object, [Parameter(Mandatory = $true)][string]$Name, $Default = $null)

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Format-JstTime {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '不明' }
    try {
        $time = [DateTimeOffset]::Parse([string]$Value)
        return [TimeZoneInfo]::ConvertTime($time, $script:Jst).ToString('yyyy-MM-dd HH:mm:ss.fff zzz')
    }
    catch { return '不明' }
}

function Test-ReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-ReadOnlyStore {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$MarkerName
    )

    $full = [IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        throw [IO.DirectoryNotFoundException]::new('Store unavailable.')
    }
    $root = [IO.Path]::GetPathRoot($full).TrimEnd([char[]]@('\', '/'))
    if ($full -ceq $root -or (Test-ReparsePoint -Path $full)) {
        throw [IO.InvalidDataException]::new('Store path invalid.')
    }
    $marker = Join-Path $full $MarkerName
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf) -or (Test-ReparsePoint -Path $marker)) {
        throw [IO.InvalidDataException]::new('Store marker invalid.')
    }
    $markerValue = [IO.File]::ReadAllText($marker, $script:Utf8Strict) |
        ConvertFrom-Json -ErrorAction Stop
    $storeId = [Guid]::Empty
    if ([int](Get-Value $markerValue 'schema_version' 0) -ne 1 -or
        -not [Guid]::TryParseExact([string](Get-Value $markerValue 'store_id' ''), 'N', [ref]$storeId)) {
        throw [IO.InvalidDataException]::new('Store marker invalid.')
    }
    return $full
}

function Read-NdjsonReadOnly {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Test-ReparsePoint -Path $Path)) {
        throw [IO.InvalidDataException]::new('Metadata file invalid.')
    }
    $stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = New-Object IO.StreamReader($stream, $script:Utf8Strict, $true)
    $records = New-Object System.Collections.Generic.List[object]
    try {
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $records.Add(($line | ConvertFrom-Json -ErrorAction Stop))
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
    return $records.ToArray()
}

function Get-BodyHeaderState {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [AllowNull()][string]$BodyRef
    )

    if ([string]::IsNullOrWhiteSpace($BodyRef)) {
        return [pscustomobject]@{ status = 'NOT_STORED'; stored_bytes = 0L; created_at_utc = $null }
    }
    if ($BodyRef -cnotmatch '^[0-9a-f]{32}$') {
        return [pscustomobject]@{ status = 'REFERENCE_INVALID'; stored_bytes = 0L; created_at_utc = $null }
    }
    $path = Join-Path $StorePath ($BodyRef + '.sgb')
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ status = 'REFERENCE_MISSING'; stored_bytes = 0L; created_at_utc = $null }
    }
    try {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Test-ReparsePoint -Path $path)) {
            throw [IO.InvalidDataException]::new('Managed body invalid.')
        }
        $stream = New-Object IO.FileStream(
            $path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = New-Object IO.BinaryReader($stream)
        try {
            if ($stream.Length -lt 32) { throw [IO.InvalidDataException]::new('Header invalid.') }
            $magic = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(8))
            $version = $reader.ReadInt32()
            $ticks = $reader.ReadInt64()
            $plainBytes = $reader.ReadInt64()
            $cipherBytes = $reader.ReadInt32()
            if ($magic -cne 'SUMIGD01' -or $version -ne 1 -or $ticks -le 0 -or
                $plainBytes -lt 0 -or $cipherBytes -le 0 -or
                $stream.Length -ne (32L + [long]$cipherBytes)) {
                throw [IO.InvalidDataException]::new('Header invalid.')
            }
            $created = New-Object DateTime($ticks, [DateTimeKind]::Utc)
            return [pscustomobject]@{
                status = 'AVAILABLE'
                stored_bytes = [long]$stream.Length
                created_at_utc = (New-Object DateTimeOffset($created)).ToString('o')
            }
        }
        finally {
            $reader.Dispose()
            $stream.Dispose()
        }
    }
    catch {
        return [pscustomobject]@{ status = 'READ_FAILED'; stored_bytes = 0L; created_at_utc = $null }
    }
}

function Get-DirectExecutionRecords {
    param([string]$ExecutionStore, [string]$LocalStore, [string]$Id)

    $events = @(Read-NdjsonReadOnly -Path (Join-Path $ExecutionStore 'events.ndjson'))
    $retention = @(Read-NdjsonReadOnly -Path (Join-Path $ExecutionStore 'retention.ndjson'))
    $deleted = @{}
    foreach ($item in $retention) {
        $ref = [string](Get-Value $item 'body_ref' '')
        if (-not [string]::IsNullOrWhiteSpace($ref)) { $deleted[$ref] = $true }
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($event in $events) {
        $idValue = [string](Get-Value $event 'execution_id' '')
        if (-not [string]::IsNullOrWhiteSpace($Id) -and $idValue -cne $Id.ToLowerInvariant()) { continue }
        $ref = [string](Get-Value $event 'body_ref' '')
        $referenceStatus = 'NOT_STORED'
        $referenceCollectionStatus = [string](Get-Value $event 'collection_status' 'COLLECTION_FAILED')
        if (-not [string]::IsNullOrWhiteSpace($ref)) {
            if ($deleted.ContainsKey($ref)) {
                $referenceStatus = 'DELETED_BY_RETENTION'
                $referenceCollectionStatus = 'RECORDS_FOUND'
            }
            else {
                $header = Get-BodyHeaderState -StorePath $LocalStore -BodyRef $ref
                $referenceStatus = [string]$header.status
                if ($referenceStatus -cne 'AVAILABLE') { $referenceCollectionStatus = 'COLLECTION_FAILED' }
            }
        }
        $result.Add([pscustomobject][ordered]@{
            schema_version = Get-Value $event 'schema_version'
            record_id = Get-Value $event 'record_id'
            record_type = Get-Value $event 'record_type'
            execution_id = $idValue
            occurred_at_utc = Get-Value $event 'occurred_at_utc'
            observed_at_utc = Get-Value $event 'observed_at_utc'
            body_sha256 = Get-Value $event 'body_sha256'
            hash_scope = Get-Value $event 'hash_scope'
            content_status = Get-Value $event 'content_status' 'CONTENT_UNKNOWN'
            collection_status = Get-Value $event 'collection_status' 'COLLECTION_FAILED'
            body_ref = if ([string]::IsNullOrWhiteSpace($ref)) { $null } else { $ref }
            body_reference_status = $referenceStatus
            body_reference_collection_status = $referenceCollectionStatus
            failure_reason_code = Get-Value $event 'failure_reason_code'
        })
    }
    return $result.ToArray()
}

function Get-ExecutionRecordsReadOnly {
    param([string]$ExecutionStore, [string]$LocalStore, [string]$Id)

    $lockPath = Join-Path $ExecutionStore '.sumi-guard-execution-store.lock'
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $result = SumiGuard.ExecutionAdapter\Get-SumiGuardExecutionRecord `
            -ExecutionStorePath $ExecutionStore -LocalStorePath $LocalStore -ExecutionId $Id
        if (-not $result.success) { throw [IO.IOException]::new('Metadata read failed.') }
        $records = @($result.records)
        foreach ($record in $records) {
            if ([string](Get-Value $record 'body_reference_status' '') -ceq 'AVAILABLE') {
                $header = Get-BodyHeaderState -StorePath $LocalStore `
                    -BodyRef ([string](Get-Value $record 'body_ref' ''))
                if ($header.status -cne 'AVAILABLE') {
                    $record.body_reference_status = [string]$header.status
                    $record.body_reference_collection_status = 'COLLECTION_FAILED'
                }
            }
        }
        return $records
    }

    # The public read API opens its lock with OpenOrCreate.  If no lock exists,
    # use the same version-1 metadata format directly so this CLI creates no file.
    return @(Get-DirectExecutionRecords -ExecutionStore $ExecutionStore -LocalStore $LocalStore -Id $Id)
}

function Get-FailureNoticesReadOnly {
    param([string]$ExecutionStore, [string]$Id)

    $lockPath = Join-Path $ExecutionStore '.sumi-guard-execution-store.lock'
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $result = SumiGuard.ExecutionAdapter\Get-SumiGuardCollectionFailureNotice `
            -ExecutionStorePath $ExecutionStore -ExecutionId $Id
        if (-not $result.success) { throw [IO.IOException]::new('Failure notice read failed.') }
        return @($result.notices)
    }
    $notices = @(Read-NdjsonReadOnly -Path (Join-Path $ExecutionStore 'failures.ndjson'))
    if ([string]::IsNullOrWhiteSpace($Id)) { return $notices }
    return @($notices | Where-Object {
        [string](Get-Value $_ 'execution_id' '') -ceq $Id.ToLowerInvariant()
    })
}

function Get-Correlation {
    param($Intent, $Outcome, [object[]]$Observations, [object[]]$HookRuntime)

    if ($null -eq $Intent) {
        return [pscustomobject]@{ classification = 'UNMATCHED'; candidates = @(); reason = '実行前イベントがないため未照合' }
    }
    $id = [string](Get-Value $Intent 'execution_id' '')
    $processRecords = @($Observations | Where-Object {
        [string](Get-Value $_ 'event_type' '') -ceq 'ProcessObserved'
    })
    $direct = @($processRecords | Where-Object {
        [string](Get-Value $_ 'execution_id' '') -ceq $id
    })
    if ($direct.Count -eq 1) {
        return [pscustomobject]@{
            classification = 'DIRECT_MATCH'; candidates = $direct
            reason = 'OS観測のexecution_idが直接一致し、候補が1件'
        }
    }
    if ($direct.Count -gt 1) {
        return [pscustomobject]@{
            classification = 'UNMATCHED'; candidates = $direct
            reason = 'execution_id直接一致の候補が複数'
        }
    }
    if ($null -eq $Outcome) {
        return [pscustomobject]@{ classification = 'UNMATCHED'; candidates = @(); reason = '実行結果がないため時刻窓を確定できない' }
    }
    try {
        $start = [DateTimeOffset]::Parse([string](Get-Value $Intent 'occurred_at_utc' ''))
        $end = [DateTimeOffset]::Parse([string](Get-Value $Outcome 'occurred_at_utc' ''))
    }
    catch {
        return [pscustomobject]@{ classification = 'UNMATCHED'; candidates = @(); reason = '時刻を解釈できないため未照合' }
    }
    $hookPids = @($HookRuntime | ForEach-Object { [int](Get-Value $_ 'hook_process_id' 0) } |
        Where-Object { $_ -gt 0 } | Select-Object -Unique)
    $candidates = @($processRecords | Where-Object {
        $pidValue = [int](Get-Value $_ 'process_id' 0)
        if ($pidValue -le 0 -or $hookPids -contains $pidValue) { return $false }
        try {
            $processStart = [DateTimeOffset]::Parse([string](Get-Value $_ 'process_start_time_utc' ''))
            return $processStart -ge $start -and $processStart -le $end
        }
        catch { return $false }
    })
    if ($candidates.Count -eq 1) {
        return [pscustomobject]@{
            classification = 'INFERRED_MATCH'; candidates = $candidates
            reason = 'フック自身を除外後、実行前から結果までの時刻窓にOS候補が1件'
        }
    }
    $reason = '条件に合うOS候補がないため未照合'
    if ($candidates.Count -gt 1) { $reason = '条件に合うOS候補が複数のため未照合' }
    return [pscustomobject]@{ classification = 'UNMATCHED'; candidates = $candidates; reason = $reason }
}

function Get-JapaneseExecutionStatus {
    param($Outcome)
    if ($null -eq $Outcome) { return '結果未記録' }
    switch ([string](Get-Value $Outcome 'execution_status' 'UNKNOWN')) {
        'SUCCEEDED' { return '成功 (SUCCEEDED)' }
        'FAILED' { return '失敗 (FAILED)' }
        'OUTPUT_NOT_CONFIRMED' { return '出力未確認 (OUTPUT_NOT_CONFIRMED)' }
        default { return '不明 (UNKNOWN)' }
    }
}

function Get-JapaneseBodyStatus {
    param($Record)
    switch ([string](Get-Value $Record 'body_reference_status' 'UNKNOWN')) {
        'AVAILABLE' { return '暗号化保存済み' }
        'DELETED_BY_RETENTION' { return '保持期限により削除' }
        'REFERENCE_MISSING' { return '参照切れ' }
        'READ_FAILED' { return '取得失敗' }
        'REFERENCE_INVALID' { return '参照不正' }
        'NOT_STORED' {
            if ([string](Get-Value $Record 'collection_status' '') -ceq 'COLLECTION_FAILED') {
                return '取得失敗（未保存）'
            }
            return '本文なし'
        }
        default { return '内容不明' }
    }
}

function Get-JapaneseCorrelation {
    param([string]$Value)
    switch ($Value) {
        'DIRECT_MATCH' { return '直接一致 (DIRECT_MATCH)' }
        'INFERRED_MATCH' { return '推定一致 (INFERRED_MATCH)' }
        default { return '未照合 (UNMATCHED)' }
    }
}

function Write-Footer {
    Write-Output '注意: この表示はSUMI Guardが保存した記録の状態であり、PC全体の安全・感染・誤検知を判定するものではありません。'
    Write-Output '既知事項: 2026-10-03の実フック試験ではCLI標準エラーが非空でしたが、内容未保存のため原因は未特定です。'
    Write-Output '本文は復号・表示していません。自動削除・修復も実行していません。'
}

function Write-ReadFailure {
    Write-Output '状態: 読み取り失敗'
    Write-Output '収集状態: COLLECTION_FAILED'
    Write-Footer
}

try {
    if ($Action -ceq 'Detail' -and $ExecutionId -cnotmatch '^[0-9a-fA-F]{32}$') {
        throw [ArgumentException]::new('Invalid execution id.')
    }
    if (-not (Test-Path -LiteralPath $script:AdapterManifest -PathType Leaf)) {
        throw [IO.FileNotFoundException]::new('Adapter unavailable.')
    }
    Import-Module $script:AdapterManifest -Force -ErrorAction Stop
    $executionStore = Assert-ReadOnlyStore `
        -Path $ExecutionStorePath -MarkerName '.sumi-guard-execution-store.json'
    $localStore = Assert-ReadOnlyStore `
        -Path $LocalStorePath -MarkerName '.sumi-guard-store.json'
    $filterId = ''
    if ($Action -ceq 'Detail') { $filterId = $ExecutionId.ToLowerInvariant() }
    $records = @(Get-ExecutionRecordsReadOnly `
        -ExecutionStore $executionStore -LocalStore $localStore -Id $filterId)
    $outcomes = @(Read-NdjsonReadOnly -Path (Join-Path $executionStore 'outcomes.ndjson'))
    $runtime = @(Read-NdjsonReadOnly -Path (Join-Path $executionStore 'hook-runtime.ndjson'))
    $failures = @(Get-FailureNoticesReadOnly -ExecutionStore $executionStore -Id $filterId)
    $hookFailures = @(Read-NdjsonReadOnly -Path (Join-Path $executionStore 'hook-failures.ndjson'))
    $observations = @()
    if (-not [string]::IsNullOrWhiteSpace($OsObservationPath)) {
        $observations = @(Read-NdjsonReadOnly -Path $OsObservationPath)
    }

    if ($Action -ceq 'List') {
        Write-Output 'SUMI Guard 保存済み実行記録'
        if ($records.Count -eq 0) {
            Write-Output '状態: 記録なし (NO_RECORD)'
        }
        else {
            foreach ($record in @($records | Sort-Object occurred_at_utc)) {
                $id = [string](Get-Value $record 'execution_id' '')
                $outcome = @($outcomes | Where-Object {
                    [string](Get-Value $_ 'execution_id' '') -ceq $id
                } | Sort-Object occurred_at_utc | Select-Object -Last 1)
                $outcomeOne = $null
                if ($outcome.Count -gt 0) { $outcomeOne = $outcome[0] }
                $correlation = Get-Correlation `
                    -Intent $record -Outcome $outcomeOne -Observations $observations -HookRuntime $runtime
                Write-Output ('日時: {0}' -f (Format-JstTime (Get-Value $record 'occurred_at_utc')))
                Write-Output ('execution_id: {0}' -f $id)
                Write-Output ('実行状態: {0}' -f (Get-JapaneseExecutionStatus $outcomeOne))
                Write-Output ('本文保存状態: {0}' -f (Get-JapaneseBodyStatus $record))
                Write-Output ('相関強度: {0}' -f (Get-JapaneseCorrelation $correlation.classification))
                Write-Output ''
            }
        }
        Write-Footer
        exit 0
    }

    if ($Action -ceq 'Detail') {
        Write-Output 'SUMI Guard 実行記録詳細'
        if ($records.Count -eq 0) {
            Write-Output '状態: 記録なし (NO_RECORD)'
            Write-Output ('execution_id: {0}' -f $ExecutionId.ToLowerInvariant())
            Write-Footer
            exit 0
        }
        if ($records.Count -ne 1) { throw [IO.InvalidDataException]::new('Record count invalid.') }
        $record = $records[0]
        $id = [string](Get-Value $record 'execution_id' '')
        $matchingOutcomes = @($outcomes | Where-Object {
            [string](Get-Value $_ 'execution_id' '') -ceq $id
        } | Sort-Object occurred_at_utc)
        $outcome = $null
        if ($matchingOutcomes.Count -gt 0) { $outcome = $matchingOutcomes[$matchingOutcomes.Count - 1] }
        $correlation = Get-Correlation `
            -Intent $record -Outcome $outcome -Observations $observations -HookRuntime $runtime
        Write-Output ('execution_id: {0}' -f $id)
        Write-Output ('実行前: {0} / {1}' -f `
            (Format-JstTime (Get-Value $record 'occurred_at_utc')), `
            [string](Get-Value $record 'collection_status' 'COLLECTION_FAILED'))
        Write-Output ('実行結果: {0}' -f (Get-JapaneseExecutionStatus $outcome))
        if ($null -ne $outcome) {
            Write-Output ('結果時刻: {0}' -f (Format-JstTime (Get-Value $outcome 'occurred_at_utc')))
        }
        Write-Output ('本文保存状態: {0}' -f (Get-JapaneseBodyStatus $record))
        Write-Output ('本文参照: {0}' -f [string](Get-Value $record 'body_ref' 'なし'))
        Write-Output ('本文SHA-256: {0}' -f [string](Get-Value $record 'body_sha256' '不明'))
        Write-Output ('OS候補数: {0}' -f @($correlation.candidates).Count)
        foreach ($candidate in @($correlation.candidates)) {
            Write-Output ('OS観測: PID {0}, 親PID {1}, 起動 {2}, ソース {3}' -f `
                [string](Get-Value $candidate 'process_id' '不明'), `
                [string](Get-Value $candidate 'parent_process_id' '不明'), `
                (Format-JstTime (Get-Value $candidate 'process_start_time_utc')), `
                [string](Get-Value $candidate 'source' '不明'))
        }
        Write-Output ('相関強度: {0}' -f (Get-JapaneseCorrelation $correlation.classification))
        Write-Output ('照合根拠: {0}' -f $correlation.reason)
        $matchingFailures = @((@($failures) + @($hookFailures)) | Where-Object {
            [string](Get-Value $_ 'execution_id' '') -ceq $id
        })
        Write-Output ('収集失敗通知数: {0}' -f $matchingFailures.Count)
        Write-Footer
        exit 0
    }

    Write-Output 'SUMI Guard 保存状態'
    [long]$used = 0
    $bodyCount = 0
    $containerFailures = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $localStore -Force -File -Filter '*.sgb')) {
        if ($file.Name -cnotmatch '^[0-9a-f]{32}\.sgb$') { continue }
        $state = Get-BodyHeaderState `
            -StorePath $localStore -BodyRef ([IO.Path]::GetFileNameWithoutExtension($file.Name))
        if ($state.status -ceq 'AVAILABLE') {
            $used += [long]$state.stored_bytes
            $bodyCount++
        }
        else { $containerFailures++ }
    }
    $brokenCount = @($records | Where-Object {
        @('REFERENCE_MISSING', 'REFERENCE_INVALID') -contains
            [string](Get-Value $_ 'body_reference_status' '')
    }).Count
    $expiredCount = @($records | Where-Object {
        [string](Get-Value $_ 'body_reference_status' '') -ceq 'DELETED_BY_RETENTION'
    }).Count
    $collectionFailureCount = @($records | Where-Object {
        [string](Get-Value $_ 'collection_status' '') -ceq 'COLLECTION_FAILED'
    }).Count
    Write-Output ('使用容量: {0} bytes' -f $used)
    Write-Output ('設定上限: {0} bytes（CLI指定値、既定は250 MiB）' -f $MaxTotalBytes)
    Write-Output ('1件上限: {0} bytes（CLI指定値、既定は1 MiB）' -f $MaxItemBytes)
    Write-Output ('保持期間: {0}日（CLI指定値、既定は30日）' -f $RetentionDays)
    Write-Output ('暗号化本文件数: {0}' -f $bodyCount)
    Write-Output ('参照切れ・参照不正: {0}' -f $brokenCount)
    Write-Output ('保持期限により削除: {0}' -f $expiredCount)
    Write-Output ('取得失敗（実行前収集）: {0}' -f $collectionFailureCount)
    Write-Output ('コンテナ読取失敗: {0}' -f $containerFailures)
    Write-Output ('失敗通知: {0}' -f (@($failures).Count + @($hookFailures).Count))
    Write-Footer
    exit 0
}
catch {
    Write-ReadFailure
    exit 2
}
