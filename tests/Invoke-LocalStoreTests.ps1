[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$moduleManifest = Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('sumi-guard-localstore-tests-' + [Guid]::NewGuid().ToString('N'))
$testRootFullPath = [System.IO.Path]::GetFullPath($testRoot)
$results = New-Object System.Collections.Generic.List[object]
$failure = $null

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][hashtable]$Evidence
    )

    $results.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $true
        evidence = [pscustomobject]$Evidence
    })
}

function Test-ByteSequenceInFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Needle
    )

    [byte[]]$haystack = [System.IO.File]::ReadAllBytes($Path)
    try {
        if ($Needle.Length -eq 0 -or $haystack.Length -lt $Needle.Length) {
            return $false
        }
        for ($offset = 0; $offset -le ($haystack.Length - $Needle.Length); $offset++) {
            $match = $true
            for ($index = 0; $index -lt $Needle.Length; $index++) {
                if ($haystack[$offset + $index] -ne $Needle[$index]) {
                    $match = $false
                    break
                }
            }
            if ($match) {
                return $true
            }
        }
        return $false
    }
    finally {
        if ($haystack.Length -gt 0) {
            [Array]::Clear($haystack, 0, $haystack.Length)
        }
    }
}

function Test-PlaintextAbsentFromDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $encoding = New-Object System.Text.UTF8Encoding($false, $true)
    [byte[]]$needle = $encoding.GetBytes($Text)
    try {
        foreach ($filePath in [System.IO.Directory]::GetFiles(
            $Path,
            '*',
            [System.IO.SearchOption]::TopDirectoryOnly)) {
            if (Test-ByteSequenceInFile -Path $filePath -Needle $needle) {
                return $false
            }
        }
        return $true
    }
    finally {
        if ($needle.Length -gt 0) {
            [Array]::Clear($needle, 0, $needle.Length)
        }
    }
}

try {
    if (-not $testRootFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $testRootFullPath) -notlike 'sumi-guard-localstore-tests-*') {
        throw 'Refusing to create the test root outside the resolved temporary directory.'
    }
    [void](New-Item -ItemType Directory -Path $testRootFullPath -ErrorAction Stop)
    Import-Module $moduleManifest -Force -ErrorAction Stop
    $module = Get-Module 'SumiGuard.LocalStore' -ErrorAction Stop

    $defaults = & $module {
        [pscustomobject]@{
            max_item_bytes = $script:DefaultMaxItemBytes
            max_total_bytes = $script:DefaultMaxTotalBytes
            retention_days = $script:DefaultRetentionDays
        }
    }
    Assert-Test ($defaults.max_item_bytes -eq 1MB) 'Default item capacity is not 1 MiB.'
    Assert-Test ($defaults.max_total_bytes -eq 250MB) 'Default total capacity is not 250 MiB.'
    Assert-Test ($defaults.retention_days -eq 30) 'Default retention is not 30 days.'
    Add-TestResult -Name 'defaults' -Evidence @{
        max_item_bytes = $defaults.max_item_bytes
        max_total_bytes = $defaults.max_total_bytes
        retention_days = $defaults.retention_days
    }

    $roundTripStore = Join-Path $testRootFullPath 'roundtrip-store'
    $initialized = Initialize-SumiGuardLocalStore -Path $roundTripStore
    Assert-Test $initialized.success 'Round-trip store initialization failed.'
    Assert-Test $initialized.acl.valid 'The store ACL did not validate.'
    Assert-Test $initialized.acl.inheritance_disabled 'ACL inheritance was not disabled.'
    Assert-Test $initialized.acl.current_user_full_control 'Current-user access is missing.'
    Assert-Test $initialized.acl.system_full_control 'SYSTEM access is missing.'
    Assert-Test ($initialized.acl.unexpected_rule_count -eq 0) 'Unexpected ACL entries remain.'

    $roundTripBody = 'SUMI_GUARD_FAKE_' + [Guid]::NewGuid().ToString('N')
    $saved = Save-SumiGuardBody -StorePath $roundTripStore -Body $roundTripBody
    Assert-Test $saved.success 'Round-trip save failed.'
    Assert-Test ($saved.status -ceq 'SAVED') 'Round-trip save returned an unexpected status.'
    $loaded = Get-SumiGuardBody -StorePath $roundTripStore -BodyId $saved.body_id
    Assert-Test $loaded.success 'Round-trip decrypt failed.'
    Assert-Test ($loaded.status -ceq 'DECRYPTED') 'Round-trip decrypt returned an unexpected status.'
    Assert-Test ($loaded.body -ceq $roundTripBody) 'Decrypted text did not match the original fake text.'
    Assert-Test (Test-PlaintextAbsentFromDirectory -Path $roundTripStore -Text $roundTripBody) `
        'Plaintext was found in the protected store.'
    Add-TestResult -Name 'dpapi_round_trip_and_acl' -Evidence @{
        save_status = $saved.status
        decrypt_status = $loaded.status
        plaintext_match = $true
        plaintext_absent_on_disk = $true
        acl_restricted_to_current_user_and_system = $true
    }

    $failureStore = Join-Path $testRootFullPath 'encryption-failure-store'
    $failureInitialized = Initialize-SumiGuardLocalStore -Path $failureStore
    Assert-Test $failureInitialized.success 'Encryption-failure store initialization failed.'
    $failureBody = 'SUMI_GUARD_FAKE_FAILURE_' + [Guid]::NewGuid().ToString('N')
    $beforeFailureFiles = @([System.IO.Directory]::GetFiles($failureStore, '*.sgb')).Count
    try {
        & $module { $script:SumiGuardTestForceEncryptionFailure = $true }
        $failureResult = Save-SumiGuardBody -StorePath $failureStore -Body $failureBody
    }
    finally {
        & $module { $script:SumiGuardTestForceEncryptionFailure = $false }
    }
    $afterFailureFiles = @([System.IO.Directory]::GetFiles($failureStore, '*.sgb')).Count
    Assert-Test (-not $failureResult.success) 'Injected encryption failure unexpectedly succeeded.'
    Assert-Test ($failureResult.status -ceq 'ENCRYPTION_FAILED') `
        'Injected encryption failure returned an unexpected status.'
    Assert-Test ($beforeFailureFiles -eq $afterFailureFiles) `
        'An encrypted-body file appeared after encryption failure.'
    $failureResultJson = $failureResult | ConvertTo-Json -Compress -Depth 5
    Assert-Test (-not $failureResultJson.Contains($failureBody)) `
        'Encryption-failure result included plaintext.'
    Assert-Test (@([System.IO.Directory]::GetFiles($failureStore, '*.tmp')).Count -eq 0) `
        'Encryption failure left a temporary file.'
    Assert-Test (Test-PlaintextAbsentFromDirectory -Path $failureStore -Text $failureBody) `
        'Failed encryption left plaintext in the store.'
    Add-TestResult -Name 'encryption_failure_no_plaintext_fallback' -Evidence @{
        status = $failureResult.status
        body_file_count_unchanged = $true
        failure_result_contains_plaintext = $false
        temporary_file_count = 0
        plaintext_absent_on_disk = $true
    }

    $capacityStore = Join-Path $testRootFullPath 'capacity-store'
    $capacityInitialized = Initialize-SumiGuardLocalStore -Path $capacityStore
    Assert-Test $capacityInitialized.success 'Capacity store initialization failed.'
    $capacityOne = Save-SumiGuardBody `
        -StorePath $capacityStore -Body ('A' * 64) -MaxItemBytes 64 -MaxTotalBytes 1MB
    $exactStoredLimit = [long]$capacityOne.stored_bytes * 2
    $capacityTwo = Save-SumiGuardBody `
        -StorePath $capacityStore -Body ('B' * 64) -MaxItemBytes 64 -MaxTotalBytes $exactStoredLimit
    $capacityOverTotal = Save-SumiGuardBody `
        -StorePath $capacityStore -Body 'C' -MaxItemBytes 64 -MaxTotalBytes $exactStoredLimit
    $capacityOverItem = Save-SumiGuardBody `
        -StorePath $capacityStore -Body ('D' * 65) -MaxItemBytes 64 -MaxTotalBytes $exactStoredLimit
    Assert-Test $capacityOne.success 'First capacity-boundary save failed.'
    Assert-Test $capacityTwo.success 'Exact total-capacity boundary was not accepted.'
    Assert-Test ($capacityTwo.total_stored_bytes_after_save -eq $exactStoredLimit) `
        'Exact total-capacity accounting is incorrect.'
    Assert-Test ($capacityOverTotal.status -ceq 'TOTAL_LIMIT_EXCEEDED') `
        'Total-capacity overflow was not rejected.'
    Assert-Test ($capacityOverItem.status -ceq 'ITEM_LIMIT_EXCEEDED') `
        'Per-item overflow was not rejected.'
    Assert-Test (@([System.IO.Directory]::GetFiles($capacityStore, '*.sgb')).Count -eq 2) `
        'Rejected capacity writes created body files.'
    Add-TestResult -Name 'capacity_boundaries' -Evidence @{
        exact_item_boundary = 'SAVED'
        exact_total_boundary = 'SAVED'
        total_overflow = $capacityOverTotal.status
        item_overflow = $capacityOverItem.status
        committed_body_count = 2
    }

    $calibrationStore = Join-Path $testRootFullPath 'concurrent-calibration-store'
    $calibrationInitialized = Initialize-SumiGuardLocalStore -Path $calibrationStore
    Assert-Test $calibrationInitialized.success 'Concurrent calibration store initialization failed.'
    $calibrationSave = Save-SumiGuardBody `
        -StorePath $calibrationStore -Body ('W' * 700) -MaxItemBytes 800 -MaxTotalBytes 1MB
    Assert-Test $calibrationSave.success 'Concurrent stored-size calibration failed.'
    $concurrentTotalLimit = [long]$calibrationSave.stored_bytes + 1

    $concurrentStore = Join-Path $testRootFullPath 'concurrent-store'
    $concurrentInitialized = Initialize-SumiGuardLocalStore -Path $concurrentStore
    Assert-Test $concurrentInitialized.success 'Concurrent-write store initialization failed.'
    $gatePath = Join-Path $testRootFullPath 'concurrent-start.signal'
    $worker = {
        param($ManifestPath, $StorePath, $GatePath, $TotalLimit)
        $ErrorActionPreference = 'Stop'
        Import-Module $ManifestPath -Force
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while (-not (Test-Path -LiteralPath $GatePath) -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 20
        }
        if (-not (Test-Path -LiteralPath $GatePath)) {
            return [pscustomobject]@{ success = $false; status = 'TEST_GATE_TIMEOUT' }
        }
        return Save-SumiGuardBody `
            -StorePath $StorePath `
            -Body ('W' * 700) `
            -MaxItemBytes 800 `
            -MaxTotalBytes $TotalLimit
    }
    $jobs = @(
        Start-Job -ScriptBlock $worker -ArgumentList $moduleManifest, $concurrentStore, $gatePath, $concurrentTotalLimit
        Start-Job -ScriptBlock $worker -ArgumentList $moduleManifest, $concurrentStore, $gatePath, $concurrentTotalLimit
    )
    try {
        [System.IO.File]::WriteAllText($gatePath, 'go')
        [void](Wait-Job -Job $jobs -Timeout 60)
        Assert-Test (@($jobs | Where-Object { $_.State -ne 'Completed' }).Count -eq 0) `
            'Concurrent writers did not finish.'
        $concurrentResults = @($jobs | Receive-Job -ErrorAction Stop)
    }
    finally {
        $jobs | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    $concurrentSaved = @($concurrentResults | Where-Object { $_.status -ceq 'SAVED' }).Count
    $concurrentRejected = @($concurrentResults | Where-Object {
        $_.status -ceq 'TOTAL_LIMIT_EXCEEDED'
    }).Count
    Assert-Test ($concurrentSaved -eq 1) 'Concurrent quota allowed an unexpected number of saves.'
    Assert-Test ($concurrentRejected -eq 1) 'Concurrent quota did not reject exactly one writer.'
    Assert-Test (@([System.IO.Directory]::GetFiles($concurrentStore, '*.sgb')).Count -eq 1) `
        'Concurrent quota committed an unexpected number of files.'
    Add-TestResult -Name 'concurrent_capacity_lock' -Evidence @{
        writer_count = 2
        saved_count = $concurrentSaved
        rejected_count = $concurrentRejected
        rejection_status = 'TOTAL_LIMIT_EXCEEDED'
        committed_body_count = 1
    }

    $retentionStore = Join-Path $testRootFullPath 'retention-store'
    $retentionInitialized = Initialize-SumiGuardLocalStore -Path $retentionStore
    Assert-Test $retentionInitialized.success 'Retention store initialization failed.'
    try {
        & $module {
            $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow.AddDays(-31) }
        }
        $expiredSave = Save-SumiGuardBody -StorePath $retentionStore -Body ('E' * 16)
    }
    finally {
        & $module { $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow } }
    }
    $freshSave = Save-SumiGuardBody -StorePath $retentionStore -Body ('F' * 16)
    Assert-Test $expiredSave.success 'Expired fixture save failed.'
    Assert-Test $freshSave.success 'Fresh fixture save failed.'

    $outsideTextPath = Join-Path $retentionStore 'outside.txt'
    $invalidSgbPath = Join-Path $retentionStore 'not-managed.sgb'
    $siblingPath = Join-Path $testRootFullPath 'outside-sibling.sgb'
    [System.IO.File]::WriteAllText($outsideTextPath, 'outside-file')
    [System.IO.File]::WriteAllText($invalidSgbPath, 'not-a-managed-container')
    [System.IO.File]::WriteAllText($siblingPath, 'outside-store')

    $cleanup = Remove-SumiGuardExpiredBody `
        -StorePath $retentionStore `
        -RetentionDays 30 `
        -Confirm:$false
    $expiredPath = Join-Path $retentionStore ($expiredSave.body_id + '.sgb')
    $freshPath = Join-Path $retentionStore ($freshSave.body_id + '.sgb')
    Assert-Test $cleanup.success 'Retention cleanup returned failure.'
    Assert-Test ($cleanup.deleted_count -eq 1) 'Retention cleanup did not delete exactly one expired body.'
    Assert-Test (-not (Test-Path -LiteralPath $expiredPath)) 'Expired managed body was retained.'
    Assert-Test (Test-Path -LiteralPath $freshPath -PathType Leaf) 'Fresh managed body was deleted.'
    Assert-Test (Test-Path -LiteralPath $outsideTextPath -PathType Leaf) 'Outside text file was deleted.'
    Assert-Test (Test-Path -LiteralPath $invalidSgbPath -PathType Leaf) 'Non-managed SGB file was deleted.'
    Assert-Test (Test-Path -LiteralPath $siblingPath -PathType Leaf) 'File outside the store was deleted.'
    Add-TestResult -Name 'retention_and_deletion_scope' -Evidence @{
        cleanup_status = $cleanup.status
        expired_deleted_count = $cleanup.deleted_count
        fresh_retained = $true
        nonmanaged_inside_retained = $true
        outside_store_retained = $true
        recursive_deletion_used = $false
    }
}
catch {
    $failure = [pscustomobject][ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
    }
}
finally {
    if ($null -ne (Get-Module 'SumiGuard.LocalStore' -ErrorAction SilentlyContinue)) {
        $module = Get-Module 'SumiGuard.LocalStore'
        & $module {
            $script:SumiGuardTestForceEncryptionFailure = $false
            $script:SumiGuardUtcNowProvider = { [DateTimeOffset]::UtcNow }
        }
    }
    if (Test-Path -LiteralPath $testRootFullPath) {
        $resolvedForDelete = [System.IO.Path]::GetFullPath($testRootFullPath)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -like 'sumi-guard-localstore-tests-*') {
            Remove-Item -LiteralPath $resolvedForDelete -Recurse -Force
        }
        else {
            $failure = [pscustomobject][ordered]@{
                type = 'CleanupSafetyFailure'
                message = 'Refused to remove a test path outside the resolved temporary root.'
            }
        }
    }
}

$summary = [pscustomobject][ordered]@{
    success = $null -eq $failure
    powershell_version = $PSVersionTable.PSVersion.ToString()
    test_count = $results.Count
    tests = $results.ToArray()
    failure = $failure
    plaintext_included = $false
    test_root_cleaned = -not (Test-Path -LiteralPath $testRootFullPath)
}
$summary | ConvertTo-Json -Depth 8
if ($null -ne $failure) {
    exit 1
}
