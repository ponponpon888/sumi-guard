Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AssessmentStoreCurrentAssertion = 'INITIALIZATION'
$script:AssessmentStoreTestResults = New-Object System.Collections.Generic.List[object]
$script:AssessmentStoreTestRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('sumi-guard-assessment-store-tests-' + [Guid]::NewGuid().ToString('N'))
$script:AssessmentStoreManifest = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1'
$script:CommandAssessmentManifest = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1'
$script:ShowScript = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'tools\Show-SumiGuardAssessments.ps1'

function Assert-SumiGuardAssessmentStoreTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )

    $script:AssessmentStoreCurrentAssertion = $Code
    if (-not $Condition) {
        throw [InvalidOperationException]::new()
    }
}

function Invoke-SumiGuardAssessmentStoreTestCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    $script:AssessmentStoreCurrentAssertion = 'CASE_START'
    try {
        & $Body
        $script:AssessmentStoreTestResults.Add([pscustomobject][ordered]@{
            name = $Name
            result = 'PASS'
            failure_stage = $null
            exception_type = $null
        })
    }
    catch {
        $exceptionType = $null
        try {
            if ($null -ne $_.Exception) {
                $exceptionType = $_.Exception.GetType().FullName
            }
        }
        catch {
            $exceptionType = $null
        }
        $script:AssessmentStoreTestResults.Add([pscustomobject][ordered]@{
            name = $Name
            result = 'FAIL'
            failure_stage = $script:AssessmentStoreCurrentAssertion
            exception_type = $exceptionType
        })
    }
}

function Invoke-SumiGuardSyntheticAssessment {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandText,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [string]$InterpreterKind = 'WINDOWS_POWERSHELL',
        [bool]$InterpreterVerified = $true
    )

    return SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment `
        -CommandText $CommandText `
        -ExecutionId $ExecutionId `
        -InterpreterKind $InterpreterKind `
        -InterpreterVerified $InterpreterVerified
}

function Get-SumiGuardDisplayOutput {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [string]$AssessmentId = ''
    )

    $exitCode = 1
    $lines = @(
        Invoke-SumiGuardAssessmentDisplay `
            -AssessmentStorePath $StorePath `
            -RequestedAssessmentId $AssessmentId `
            -ExitCode ([ref]$exitCode))
    return [pscustomobject][ordered]@{
        exit_code = $exitCode
        text = $lines -join "`n"
    }
}

$topLevelFailureStage = $null
$topLevelExceptionType = $null
$cleanupSucceeded = $false
try {
    $script:AssessmentStoreCurrentAssertion = 'CREATE_TEST_ROOT'
    $null = New-Item -ItemType Directory -Path $script:AssessmentStoreTestRoot
    $script:AssessmentStoreCurrentAssertion = 'IMPORT_MODULES'
    $null = Import-Module -Name $script:CommandAssessmentManifest -Force -ErrorAction Stop
    $null = Import-Module -Name $script:AssessmentStoreManifest -Force -ErrorAction Stop
    . $script:ShowScript -StorePath $script:AssessmentStoreTestRoot

    $assessmentModule = @(Get-Module -Name 'SumiGuard.CommandAssessment' -All)[0]
    $storeModule = @(Get-Module -Name 'SumiGuard.AssessmentStore' -All)[0]
    $mainStore = Join-Path $script:AssessmentStoreTestRoot 'main-store'
    $createMain = New-SumiGuardAssessmentStore -StorePath $mainStore
    Assert-SumiGuardAssessmentStoreTest ($createMain.success) 'MAIN_STORE_CREATE'

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'ASSESSMENT_STORE_PRIVATE_ACL' -Body {
        $acl = Get-Acl -LiteralPath $mainStore
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $allowed = @($sid, 'S-1-5-18')
        Assert-SumiGuardAssessmentStoreTest ([bool]$acl.AreAccessRulesProtected) 'ACL_NOT_PROTECTED'
        foreach ($file in @(
            $mainStore,
            (Join-Path $mainStore '.sumi-guard-assessment-store.json'),
            (Join-Path $mainStore '.sumi-guard-assessment-store.lock'),
            (Join-Path $mainStore 'assessments.ndjson'))) {
            $fileAcl = Get-Acl -LiteralPath $file
            $rules = @($fileAcl.GetAccessRules($true, $true,
                [Security.Principal.SecurityIdentifier]))
            Assert-SumiGuardAssessmentStoreTest ($rules.Count -gt 0) 'MISSING_ACL_RULES'
            foreach ($rule in $rules) {
                Assert-SumiGuardAssessmentStoreTest (
                    $allowed -ccontains $rule.IdentityReference.Value -and
                    $rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow
                ) 'UNEXPECTED_ACL_RULE'
            }
        }
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'TAMPERED_ASSESSMENT_FILE_ACL_IS_REJECTED' -Body {
        $recordFile = Join-Path $mainStore 'assessments.ndjson'
        $originalAcl = Get-Acl -LiteralPath $recordFile
        try {
            $tamperedAcl = Get-Acl -LiteralPath $recordFile
            $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
            $otherRule = New-Object Security.AccessControl.FileSystemAccessRule(
                $users,
                [Security.AccessControl.FileSystemRights]::Read,
                [Security.AccessControl.AccessControlType]::Allow)
            [void]$tamperedAcl.AddAccessRule($otherRule)
            Set-Acl -LiteralPath $recordFile -AclObject $tamperedAcl -ErrorAction Stop
            $read = Get-SumiGuardAssessmentRecord -StorePath $mainStore
            Assert-SumiGuardAssessmentStoreTest (
                -not $read.success -and $read.status -ceq 'STORE_ACL_INVALID'
            ) 'TAMPERED_FILE_ACL_ACCEPTED'
        }
        finally {
            Set-Acl -LiteralPath $recordFile -AclObject $originalAcl -ErrorAction Stop
        }
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'LEGACY_UNPROTECTED_DIRECTORY_REJECTED' -Body {
        $legacyStore = Join-Path $script:AssessmentStoreTestRoot 'legacy-acl-store'
        $created = New-SumiGuardAssessmentStore -StorePath $legacyStore
        Assert-SumiGuardAssessmentStoreTest ($created.success) 'LEGACY_FIXTURE_CREATE'
        $acl = Get-Acl -LiteralPath $legacyStore
        $acl.SetAccessRuleProtection($false, $true)
        Set-Acl -LiteralPath $legacyStore -AclObject $acl -ErrorAction Stop
        $read = Get-SumiGuardAssessmentRecord -StorePath $legacyStore
        Assert-SumiGuardAssessmentStoreTest (
            -not $read.success -and $read.status -ceq 'STORE_ACL_INVALID'
        ) 'LEGACY_ACL_ACCEPTED'
        $retry = New-SumiGuardAssessmentStore -StorePath $legacyStore
        Assert-SumiGuardAssessmentStoreTest (
            -not $retry.success -and $retry.status -ceq 'STORE_ACL_INVALID'
        ) 'LEGACY_ACL_AUTO_REPAIRED'
    }


    $detected = Invoke-SumiGuardSyntheticAssessment `
        -CommandText 'Set-MpPreference -DisableRealtimeMonitoring $true' `
        -ExecutionId '00000000000000000000000000000011'
    $noDetection = Invoke-SumiGuardSyntheticAssessment `
        -CommandText "Write-Output 'synthetic normal sample'" `
        -ExecutionId '00000000000000000000000000000012'
    $unassessable = Invoke-SumiGuardSyntheticAssessment `
        -CommandText 'Get-ChildItem' `
        -ExecutionId '00000000000000000000000000000013' `
        -InterpreterKind 'UNKNOWN' `
        -InterpreterVerified $false
    try {
        $assessmentModule.SessionState.PSVariable.Set(
            'SumiGuardTestForceEvaluationFailure',
            $true)
        $evaluationFailed = Invoke-SumiGuardSyntheticAssessment `
            -CommandText 'Get-ChildItem' `
            -ExecutionId '00000000000000000000000000000014'
    }
    finally {
        $assessmentModule.SessionState.PSVariable.Set(
            'SumiGuardTestForceEvaluationFailure',
            $false)
    }
    $partial = Invoke-SumiGuardSyntheticAssessment `
        -CommandText 'Set-MpPreference -DisableRealtimeMonitoring $true; & $dynamicTarget' `
        -ExecutionId '00000000000000000000000000000015'
    $managed = Invoke-SumiGuardSyntheticAssessment `
        -CommandText "Write-Output 'managed fixed sample'" `
        -ExecutionId '00000000000000000000000000000016'

    $secretMarker = 'SYNTHETIC_SECRET_56a07f'
    $urlMarker = 'https://example.invalid/private?token=SYNTHETIC_TOKEN_84'
    $pathMarker = 'C:\SyntheticPrivate\assessment-input.txt'
    $detected | Add-Member -NotePropertyName command_text -NotePropertyValue $secretMarker
    $detected | Add-Member -NotePropertyName source_excerpt -NotePropertyValue $urlMarker
    $detected | Add-Member -NotePropertyName exception_detail -NotePropertyValue $pathMarker

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'FOUR_STATES_AND_PARTIAL_ROUND_TRIP' -Body {
        $items = @($detected, $noDetection, $unassessable, $evaluationFailed, $partial)
        $expectedStates = @(
            'DETECTED', 'NO_DETECTION', 'UNASSESSABLE',
            'EVALUATION_FAILED', 'DETECTED')
        for ($index = 0; $index -lt $items.Count; $index++) {
            $save = Save-SumiGuardAssessment `
                -StorePath $mainStore `
                -Assessment $items[$index] `
                -EvaluationOrigin 'SYNTHETIC_TEST'
            Assert-SumiGuardAssessmentStoreTest `
                ($save.success -eq $true) `
                ('SAVE_STATE_' + $index)
            Assert-SumiGuardAssessmentStoreTest `
                ($save.status -ceq 'SAVED') `
                ('SAVE_STATUS_' + $index)
            Assert-SumiGuardAssessmentStoreTest `
                ($null -eq $save.execution_id) `
                ('SYNTHETIC_EXECUTION_ID_' + $index)
        }
        $read = Get-SumiGuardAssessmentRecord -StorePath $mainStore
        Assert-SumiGuardAssessmentStoreTest ($read.success) 'ROUND_TRIP_READ'
        Assert-SumiGuardAssessmentStoreTest `
            ($read.record_count -eq 5) `
            'ROUND_TRIP_COUNT'
        for ($index = 0; $index -lt $read.records.Count; $index++) {
            $record = $read.records[$index]
            Assert-SumiGuardAssessmentStoreTest `
                ($record.assessment_status -ceq $expectedStates[$index]) `
                ('ROUND_TRIP_STATE_' + $index)
            Assert-SumiGuardAssessmentStoreTest `
                ($record.evaluation_origin -ceq 'SYNTHETIC_TEST') `
                ('ROUND_TRIP_ORIGIN_' + $index)
            Assert-SumiGuardAssessmentStoreTest `
                ($null -eq $record.execution_id) `
                ('ROUND_TRIP_NO_EXECUTION_' + $index)
        }
        Assert-SumiGuardAssessmentStoreTest `
            ($read.records[4].assessment_reason_code -ceq 'PARTIAL_UNASSESSABLE') `
            'PARTIAL_REASON'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'MANAGED_EXECUTION_RELATION_IS_EXPLICIT' -Body {
        $save = Save-SumiGuardAssessment `
            -StorePath $mainStore `
            -Assessment $managed `
            -EvaluationOrigin 'MANAGED_EXECUTION' `
            -RelatedExecutionId '00000000000000000000000000000016'
        Assert-SumiGuardAssessmentStoreTest ($save.success) 'MANAGED_SAVE'
        $read = Get-SumiGuardAssessmentRecord `
            -StorePath $mainStore `
            -AssessmentId $managed.record_id
        Assert-SumiGuardAssessmentStoreTest ($read.success) 'MANAGED_READ'
        Assert-SumiGuardAssessmentStoreTest `
            ($read.record_count -eq 1) `
            'MANAGED_READ_COUNT'
        Assert-SumiGuardAssessmentStoreTest `
            ($read.records[0].evaluation_origin -ceq 'MANAGED_EXECUTION') `
            'MANAGED_ORIGIN'
        Assert-SumiGuardAssessmentStoreTest `
            ($read.records[0].execution_id -ceq '00000000000000000000000000000016') `
            'MANAGED_EXECUTION_ID'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'DUPLICATE_ID_IS_REJECTED' -Body {
        $before = Get-SumiGuardAssessmentRecord -StorePath $mainStore
        $duplicate = Save-SumiGuardAssessment `
            -StorePath $mainStore `
            -Assessment $detected `
            -EvaluationOrigin 'SYNTHETIC_TEST'
        $after = Get-SumiGuardAssessmentRecord -StorePath $mainStore
        Assert-SumiGuardAssessmentStoreTest `
            (-not $duplicate.success) `
            'DUPLICATE_SUCCESS_FALSE'
        Assert-SumiGuardAssessmentStoreTest `
            ($duplicate.status -ceq 'DUPLICATE_ASSESSMENT_ID') `
            'DUPLICATE_STATUS'
        Assert-SumiGuardAssessmentStoreTest `
            ($after.record_count -eq $before.record_count) `
            'DUPLICATE_COUNT_UNCHANGED'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'INVALID_INPUT_IS_REJECTED' -Body {
        $invalidStatus = $noDetection | Select-Object *
        $invalidStatus.assessment_status = 'SAFE'
        $invalidType = $noDetection | Select-Object *
        $invalidType.record_id = 123
        $invalidLength = $noDetection | Select-Object *
        $invalidLength.ruleset_version = 'X' * 129
        $before = Get-SumiGuardAssessmentRecord -StorePath $mainStore
        $invalidItems = @($invalidStatus, $invalidType, $invalidLength)
        for ($index = 0; $index -lt $invalidItems.Count; $index++) {
            $save = Save-SumiGuardAssessment `
                -StorePath $mainStore `
                -Assessment $invalidItems[$index] `
                -EvaluationOrigin 'SYNTHETIC_TEST'
            Assert-SumiGuardAssessmentStoreTest `
                (-not $save.success) `
                ('INVALID_SUCCESS_FALSE_' + $index)
            Assert-SumiGuardAssessmentStoreTest `
                ($save.status -ceq 'INVALID_ASSESSMENT') `
                ('INVALID_STATUS_' + $index)
        }
        $after = Get-SumiGuardAssessmentRecord -StorePath $mainStore
        Assert-SumiGuardAssessmentStoreTest `
            ($after.record_count -eq $before.record_count) `
            'INVALID_COUNT_UNCHANGED'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'ATOMIC_SAVE_FAILURE_PRESERVES_STORE' -Body {
        $candidate = Invoke-SumiGuardSyntheticAssessment `
            -CommandText "Write-Output 'atomic failure sample'" `
            -ExecutionId '00000000000000000000000000000017'
        $recordPath = Join-Path $mainStore 'assessments.ndjson'
        $beforeHash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash
        try {
            $storeModule.SessionState.PSVariable.Set(
                'SumiGuardAssessmentStoreTestForceAtomicWriteFailure',
                $true)
            $save = Save-SumiGuardAssessment `
                -StorePath $mainStore `
                -Assessment $candidate `
                -EvaluationOrigin 'SYNTHETIC_TEST'
        }
        finally {
            $storeModule.SessionState.PSVariable.Set(
                'SumiGuardAssessmentStoreTestForceAtomicWriteFailure',
                $false)
        }
        $afterHash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash
        $pending = @(Get-ChildItem -LiteralPath $mainStore -Filter '.pending-assessment-*.tmp' -File)
        Assert-SumiGuardAssessmentStoreTest (-not $save.success) 'ATOMIC_FAILURE_SUCCESS_FALSE'
        Assert-SumiGuardAssessmentStoreTest `
            ($save.status -ceq 'ATOMIC_WRITE_FAILED') `
            'ATOMIC_FAILURE_STATUS'
        Assert-SumiGuardAssessmentStoreTest `
            ($beforeHash -ceq $afterHash) `
            'ATOMIC_FAILURE_HASH_UNCHANGED'
        Assert-SumiGuardAssessmentStoreTest `
            ($pending.Count -eq 0) `
            'ATOMIC_FAILURE_NO_PENDING_FILE'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'CAPACITY_LIMIT_IS_ENFORCED' -Body {
        $capacityStore = Join-Path $script:AssessmentStoreTestRoot 'capacity-store'
        $created = New-SumiGuardAssessmentStore `
            -StorePath $capacityStore `
            -MaximumBytes 700
        Assert-SumiGuardAssessmentStoreTest ($created.success) 'CAPACITY_STORE_CREATE'
        $first = Invoke-SumiGuardSyntheticAssessment `
            -CommandText "Write-Output 'capacity first'" `
            -ExecutionId '00000000000000000000000000000021'
        $second = Invoke-SumiGuardSyntheticAssessment `
            -CommandText "Write-Output 'capacity second'" `
            -ExecutionId '00000000000000000000000000000022'
        $firstSave = Save-SumiGuardAssessment `
            -StorePath $capacityStore `
            -Assessment $first `
            -EvaluationOrigin 'SYNTHETIC_TEST'
        $secondSave = Save-SumiGuardAssessment `
            -StorePath $capacityStore `
            -Assessment $second `
            -EvaluationOrigin 'SYNTHETIC_TEST'
        $read = Get-SumiGuardAssessmentRecord -StorePath $capacityStore
        Assert-SumiGuardAssessmentStoreTest ($firstSave.success) 'CAPACITY_FIRST_SAVE'
        Assert-SumiGuardAssessmentStoreTest `
            (-not $secondSave.success) `
            'CAPACITY_SECOND_SUCCESS_FALSE'
        Assert-SumiGuardAssessmentStoreTest `
            ($secondSave.status -ceq 'CAPACITY_EXCEEDED') `
            'CAPACITY_STATUS'
        Assert-SumiGuardAssessmentStoreTest `
            ($read.record_count -eq 1) `
            'CAPACITY_RECORD_COUNT'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'INCOMPLETE_FILE_IS_NOT_REPAIRED' -Body {
        $incompleteStore = Join-Path $script:AssessmentStoreTestRoot 'incomplete-store'
        $created = New-SumiGuardAssessmentStore -StorePath $incompleteStore
        Assert-SumiGuardAssessmentStoreTest ($created.success) 'INCOMPLETE_STORE_CREATE'
        $recordPath = Join-Path $incompleteStore 'assessments.ndjson'
        [IO.File]::AppendAllText(
            $recordPath,
            '{"schema_version":1',
            (New-Object Text.UTF8Encoding($false, $true)))
        $read = Get-SumiGuardAssessmentRecord -StorePath $incompleteStore
        $candidate = Invoke-SumiGuardSyntheticAssessment `
            -CommandText "Write-Output 'must not repair'" `
            -ExecutionId '00000000000000000000000000000031'
        $save = Save-SumiGuardAssessment `
            -StorePath $incompleteStore `
            -Assessment $candidate `
            -EvaluationOrigin 'SYNTHETIC_TEST'
        Assert-SumiGuardAssessmentStoreTest (-not $read.success) 'INCOMPLETE_READ_FALSE'
        Assert-SumiGuardAssessmentStoreTest `
            ($read.status -ceq 'STORE_FILE_INCOMPLETE') `
            'INCOMPLETE_READ_STATUS'
        Assert-SumiGuardAssessmentStoreTest (-not $save.success) 'INCOMPLETE_SAVE_FALSE'
        Assert-SumiGuardAssessmentStoreTest `
            ($save.status -ceq 'STORE_FILE_INCOMPLETE') `
            'INCOMPLETE_SAVE_STATUS'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'READ_DOES_NOT_CREATE_MISSING_LOCK' -Body {
        $readOnlyStore = Join-Path $script:AssessmentStoreTestRoot 'read-no-create-store'
        $created = New-SumiGuardAssessmentStore -StorePath $readOnlyStore
        Assert-SumiGuardAssessmentStoreTest ($created.success) 'READ_ONLY_STORE_CREATE'
        $lockPath = Join-Path $readOnlyStore '.sumi-guard-assessment-store.lock'
        [IO.File]::Delete($lockPath)
        $read = Get-SumiGuardAssessmentRecord -StorePath $readOnlyStore
        Assert-SumiGuardAssessmentStoreTest (-not $read.success) 'READ_NO_LOCK_FALSE'
        Assert-SumiGuardAssessmentStoreTest `
            (-not (Test-Path -LiteralPath $lockPath)) `
            'READ_DID_NOT_CREATE_LOCK'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'STORED_AND_DISPLAYED_DATA_OMIT_SECRETS' -Body {
        $recordPath = Join-Path $mainStore 'assessments.ndjson'
        $storedText = [IO.File]::ReadAllText(
            $recordPath,
            (New-Object Text.UTF8Encoding($false, $true)))
        $listDisplay = Get-SumiGuardDisplayOutput -StorePath $mainStore
        $detailDisplay = Get-SumiGuardDisplayOutput `
            -StorePath $mainStore `
            -AssessmentId $detected.record_id
        foreach ($canary in @($secretMarker, $urlMarker, $pathMarker)) {
            Assert-SumiGuardAssessmentStoreTest `
                (-not $storedText.Contains($canary)) `
                'CANARY_NOT_STORED'
            Assert-SumiGuardAssessmentStoreTest `
                (-not $listDisplay.text.Contains($canary)) `
                'CANARY_NOT_IN_LIST'
            Assert-SumiGuardAssessmentStoreTest `
                (-not $detailDisplay.text.Contains($canary)) `
                'CANARY_NOT_IN_DETAIL'
        }
        Assert-SumiGuardAssessmentStoreTest `
            ($listDisplay.exit_code -eq 0) `
            'LIST_EXIT_CODE'
        Assert-SumiGuardAssessmentStoreTest `
            ($detailDisplay.exit_code -eq 0) `
            'DETAIL_EXIT_CODE'
        Assert-SumiGuardAssessmentStoreTest `
            ($listDisplay.text.Contains('試験データ')) `
            'LIST_SYNTHETIC_LABEL'
        Assert-SumiGuardAssessmentStoreTest `
            ($detailDisplay.text.Contains('実際に実行された操作の記録ではありません')) `
            'DETAIL_NOT_EXECUTED_NOTICE'
        Assert-SumiGuardAssessmentStoreTest `
            ($detailDisplay.text.Contains('セキュリティ・監査・ログを無効化する既知の変更操作')) `
            'DETAIL_FIXED_RULE_DESCRIPTION'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'DISPLAY_DISTINGUISHES_ALL_STATES_AND_PARTIAL' -Body {
        $noDetectionDisplay = Get-SumiGuardDisplayOutput `
            -StorePath $mainStore `
            -AssessmentId $noDetection.record_id
        $unassessableDisplay = Get-SumiGuardDisplayOutput `
            -StorePath $mainStore `
            -AssessmentId $unassessable.record_id
        $failedDisplay = Get-SumiGuardDisplayOutput `
            -StorePath $mainStore `
            -AssessmentId $evaluationFailed.record_id
        $partialDisplay = Get-SumiGuardDisplayOutput `
            -StorePath $mainStore `
            -AssessmentId $partial.record_id
        Assert-SumiGuardAssessmentStoreTest `
            ($noDetectionDisplay.text.Contains('判定: 対応範囲で該当なし')) `
            'DISPLAY_NO_DETECTION'
        Assert-SumiGuardAssessmentStoreTest `
            (-not $noDetectionDisplay.text.Contains('判定: 安全')) `
            'DISPLAY_NOT_SAFE'
        Assert-SumiGuardAssessmentStoreTest `
            ($unassessableDisplay.text.Contains('判定: 評価不能')) `
            'DISPLAY_UNASSESSABLE'
        Assert-SumiGuardAssessmentStoreTest `
            ($failedDisplay.text.Contains('判定: 評価処理失敗')) `
            'DISPLAY_EVALUATION_FAILED'
        Assert-SumiGuardAssessmentStoreTest `
            ($partialDisplay.text.Contains('制約: 一部は評価不能です')) `
            'DISPLAY_PARTIAL_CONSTRAINT'
    }

    Invoke-SumiGuardAssessmentStoreTestCase -Name 'UNKNOWN_CODES_ARE_NOT_GUESSED' -Body {
        $statusText = Get-SumiGuardAssessmentStatusText -Code 'FUTURE_STATE'
        $reasonText = Get-SumiGuardAssessmentReasonText -Code 'FUTURE_REASON'
        $finding = [pscustomobject]@{
            rule_id = 'SG-CMD-999'
            reason_code = 'FUTURE_REASON'
        }
        $ruleText = Get-SumiGuardAssessmentRuleText -Finding $finding
        Assert-SumiGuardAssessmentStoreTest `
            ($statusText -ceq '説明未定義 [FUTURE_STATE]') `
            'UNKNOWN_STATUS_TEXT'
        Assert-SumiGuardAssessmentStoreTest `
            ($reasonText -ceq '説明未定義 [FUTURE_REASON]') `
            'UNKNOWN_REASON_TEXT'
        Assert-SumiGuardAssessmentStoreTest `
            ($ruleText.Contains('説明未定義')) `
            'UNKNOWN_RULE_TEXT'
    }
}
catch {
    $topLevelFailureStage = $script:AssessmentStoreCurrentAssertion
    try {
        if ($null -ne $_.Exception) {
            $topLevelExceptionType = $_.Exception.GetType().FullName
        }
    }
    catch {
        $topLevelExceptionType = $null
    }
}
finally {
    try {
        if (Test-Path -LiteralPath $script:AssessmentStoreTestRoot) {
            [IO.Directory]::Delete($script:AssessmentStoreTestRoot, $true)
        }
        $cleanupSucceeded = -not (Test-Path -LiteralPath $script:AssessmentStoreTestRoot)
    }
    catch {
        $cleanupSucceeded = $false
    }
    $failedCount = @(
        $script:AssessmentStoreTestResults |
            Where-Object { $_.result -cne 'PASS' }).Count
    $success = (
        $null -eq $topLevelFailureStage -and
        $failedCount -eq 0 -and
        $cleanupSucceeded)
    [pscustomobject][ordered]@{
        success = $success
        powershell_version = $PSVersionTable.PSVersion.ToString()
        test_count = $script:AssessmentStoreTestResults.Count
        passed_count = $script:AssessmentStoreTestResults.Count - $failedCount
        failed_count = $failedCount
        tests = $script:AssessmentStoreTestResults.ToArray()
        top_level_failure_stage = $topLevelFailureStage
        top_level_exception_type = $topLevelExceptionType
        disposable_store_cleanup = $cleanupSucceeded
        suspicious_commands_executed = $false
        command_content_saved = $false
        raw_exception_details_saved = $false
        external_communication_performed = $false
    } | ConvertTo-Json -Depth 8 -Compress
    if ($success) {
        exit 0
    }
    exit 1
}
