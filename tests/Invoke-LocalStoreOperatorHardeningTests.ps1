[CmdletBinding()]
param()

# Gate 3 checks for SUMI Guard LocalStore that only mean something on the
# operator's Windows machine: DPAPI CurrentUser binding, and that the store
# refuses to work once its ACL has been widened or its contents tampered with.
#
# Every case uses a disposable store under %TEMP% and fake text only. Cases
# run independently, so one failure does not hide the rest. The summary holds
# no SID, user name, path, master key id or body text.
#
# DPAPI-dependent: excluded from the GitHub-hosted CI suite with its reason.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$moduleManifest = Join-Path $projectRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRootPrefix = 'sumi-guard-operator-hardening-tests-'
$testRoot = Join-Path $tempRoot ($testRootPrefix + [Guid]::NewGuid().ToString('N'))
$testRootFullPath = [System.IO.Path]::GetFullPath($testRoot)
$results = New-Object System.Collections.Generic.List[object]
$failure = $null
$module = $null

# DPAPI blob layout (DPAPI_BLOB): dwVersion, guidProvider, dwMasterKeyVersion,
# guidMasterKey, dwFlags. CRYPTPROTECT_LOCAL_MACHINE marks a machine-scope blob.
$dpapiProviderGuid = [Guid]'df9d8cd0-1501-11d1-8c7a-00c04fc297eb'
$cryptProtectLocalMachine = [uint32]4
$containerHeaderBytes = 32
$containerCipherLengthOffset = 28
$everyoneSid = 'S-1-1-0'
$systemSid = 'S-1-5-18'

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

# Runs one case. Only the fixed Assert-Test text is kept from a failure; other
# exception messages can carry paths, so only their type is recorded.
function Invoke-HardeningCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )

    try {
        $output = @(& $Body)
        $evidence = $null
        if ($output.Count -eq 1) {
            $evidence = $output[0]
        }
        Assert-Test ($evidence -is [hashtable]) 'The case produced output other than its evidence.'
        $results.Add([pscustomobject][ordered]@{
            name = $Name
            passed = $true
            evidence = [pscustomobject]$evidence
            failure_type = $null
            failure_message = $null
        })
    }
    catch {
        $exception = $_.Exception
        $message = $null
        if ($exception -is [System.InvalidOperationException]) {
            $message = $exception.Message
        }
        $results.Add([pscustomobject][ordered]@{
            name = $Name
            passed = $false
            evidence = $null
            failure_type = $exception.GetType().FullName
            failure_message = $message
        })
    }
}

function Get-FakeBody {
    param([Parameter(Mandatory = $true)][string]$Label)

    return 'SUMI_GUARD_FAKE_GATE3_' + $Label + '_' + [Guid]::NewGuid().ToString('N')
}

function Initialize-CaseStore {
    param([Parameter(Mandatory = $true)][string]$Name)

    $path = Join-Path $testRootFullPath $Name
    $initialized = Initialize-SumiGuardLocalStore -Path $path
    Assert-Test ($initialized.success -and $initialized.status -ceq 'CREATED') `
        'A disposable store could not be created.'
    return $path
}

function Get-BodyPath {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$BodyId
    )

    return Join-Path $StorePath ($BodyId.ToLowerInvariant() + '.sgb')
}

function Read-CipherBlob {
    param([Parameter(Mandatory = $true)][string]$Path)

    [byte[]]$container = [System.IO.File]::ReadAllBytes($Path)
    $cipherLength = [BitConverter]::ToInt32($container, $containerCipherLengthOffset)
    Assert-Test ($cipherLength -gt 0 -and
        $container.Length -eq ($containerHeaderBytes + $cipherLength)) `
        'The container header does not describe its ciphertext length.'
    $cipher = New-Object byte[] $cipherLength
    [Array]::Copy($container, $containerHeaderBytes, $cipher, 0, $cipherLength)
    return ,$cipher
}

function Get-GuidAt {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset
    )

    $slice = New-Object byte[] 16
    [Array]::Copy($Bytes, $Offset, $slice, 0, 16)
    return New-Object Guid -ArgumentList (,$slice)
}

function Get-SidRuleSummary {
    param([Parameter(Mandatory = $true)]$Security)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules = @($Security.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]))
    $unexpected = 0
    $notInherited = 0
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if (($sid -cne $currentSid -and $sid -cne $systemSid) -or
            $rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            $unexpected++
        }
        if (-not $rule.IsInherited) {
            $notInherited++
        }
    }
    return [pscustomobject][ordered]@{
        rule_count = $rules.Count
        unexpected_rule_count = $unexpected
        explicit_rule_count = $notInherited
    }
}

function Test-TextAbsentFromStore {
    param(
        [Parameter(Mandatory = $true)][string]$StorePath,
        [Parameter(Mandatory = $true)][string]$Text
    )

    # Latin-1 maps every byte to one character, so a byte search becomes a
    # string search. The fake bodies are ASCII.
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $needle = $latin1.GetString([System.Text.Encoding]::UTF8.GetBytes($Text))
    foreach ($filePath in [System.IO.Directory]::GetFiles($StorePath)) {
        $haystack = $latin1.GetString([System.IO.File]::ReadAllBytes($filePath))
        if ($haystack.Contains($needle)) {
            return $false
        }
    }
    return $true
}

try {
    if (-not $testRootFullPath.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $testRootFullPath) -notlike ($testRootPrefix + '*')) {
        throw 'Refusing to create the test root outside the resolved temporary directory.'
    }
    [void](New-Item -ItemType Directory -Path $testRootFullPath -ErrorAction Stop)
    Import-Module $moduleManifest -Force -ErrorAction Stop
    $module = Get-Module 'SumiGuard.LocalStore' -ErrorAction Stop

    Invoke-HardeningCase -Name 'dpapi_blob_is_current_user_scope' -Body {
        $store = Initialize-CaseStore -Name 'scope-store'
        $saved = Save-SumiGuardBody -StorePath $store -Body (Get-FakeBody -Label 'SCOPE')
        Assert-Test ($saved.success -and $saved.status -ceq 'SAVED') 'Saving a fake body failed.'
        [byte[]]$cipher = Read-CipherBlob -Path (Get-BodyPath -StorePath $store -BodyId $saved.body_id)
        Assert-Test ($cipher.Length -ge 44) 'The ciphertext is shorter than a DPAPI blob header.'
        $blobVersion = [BitConverter]::ToUInt32($cipher, 0)
        $provider = Get-GuidAt -Bytes $cipher -Offset 4
        $flags = [BitConverter]::ToUInt32($cipher, 40)
        Assert-Test ($provider -eq $dpapiProviderGuid) 'The ciphertext is not a DPAPI blob.'
        Assert-Test (($flags -band $cryptProtectLocalMachine) -eq 0) `
            'The DPAPI blob carries the LOCAL_MACHINE flag; it is not CurrentUser scope.'
        @{
            blob_version = $blobVersion
            dpapi_provider_matches = $true
            local_machine_flag_set = $false
        }
    }

    Invoke-HardeningCase -Name 'dpapi_master_key_belongs_to_current_user' -Body {
        $store = Initialize-CaseStore -Name 'masterkey-store'
        $saved = Save-SumiGuardBody -StorePath $store -Body (Get-FakeBody -Label 'MASTERKEY')
        Assert-Test ($saved.success) 'Saving a fake body failed.'
        [byte[]]$cipher = Read-CipherBlob -Path (Get-BodyPath -StorePath $store -BodyId $saved.body_id)
        $masterKey = Get-GuidAt -Bytes $cipher -Offset 24
        Assert-Test ($masterKey -ne [Guid]::Empty) 'The DPAPI blob names no master key.'
        Assert-Test (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) 'APPDATA is not set.'
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $protectDirectory = Join-Path $env:APPDATA ('Microsoft\Protect\' + $currentSid)
        $masterKeyFile = Join-Path $protectDirectory $masterKey.ToString('D')
        $found = Test-Path -LiteralPath $masterKeyFile -PathType Leaf
        Assert-Test $found `
            'The master key named in the blob is not in the current user DPAPI key directory.'
        @{
            master_key_named = $true
            master_key_in_current_user_profile = $true
        }
    }

    Invoke-HardeningCase -Name 'dpapi_entropy_is_bound' -Body {
        $store = Initialize-CaseStore -Name 'entropy-store'
        $fake = Get-FakeBody -Label 'ENTROPY'
        $saved = Save-SumiGuardBody -StorePath $store -Body $fake
        Assert-Test ($saved.success) 'Saving a fake body failed.'
        [byte[]]$cipher = Read-CipherBlob -Path (Get-BodyPath -StorePath $store -BodyId $saved.body_id)
        [byte[]]$rightEntropy = & $module { ,$script:DpapiEntropy }
        [byte[]]$wrongEntropy = [System.Text.Encoding]::UTF8.GetBytes('SUMI Guard gate 3 wrong entropy')
        $scope = [System.Security.Cryptography.DataProtectionScope]::CurrentUser

        $wrongRejected = $false
        try {
            [void][System.Security.Cryptography.ProtectedData]::Unprotect($cipher, $wrongEntropy, $scope)
        }
        catch [System.Security.Cryptography.CryptographicException] {
            $wrongRejected = $true
        }
        $missingRejected = $false
        try {
            [void][System.Security.Cryptography.ProtectedData]::Unprotect($cipher, $null, $scope)
        }
        catch [System.Security.Cryptography.CryptographicException] {
            $missingRejected = $true
        }
        [byte[]]$plain = [System.Security.Cryptography.ProtectedData]::Unprotect($cipher, $rightEntropy, $scope)
        try {
            $roundTripMatches = [System.Text.Encoding]::UTF8.GetString($plain) -ceq $fake
        }
        finally {
            [Array]::Clear($plain, 0, $plain.Length)
        }
        Assert-Test $wrongRejected 'The blob decrypted with the wrong entropy.'
        Assert-Test $missingRejected 'The blob decrypted without entropy.'
        Assert-Test $roundTripMatches 'The blob did not decrypt to the fake body with the module entropy.'
        @{
            wrong_entropy_rejected = $true
            missing_entropy_rejected = $true
            module_entropy_round_trip = $true
        }
    }

    Invoke-HardeningCase -Name 'tampered_ciphertext_fails_closed' -Body {
        $store = Initialize-CaseStore -Name 'tamper-store'
        $fake = Get-FakeBody -Label 'TAMPER'
        $saved = Save-SumiGuardBody -StorePath $store -Body $fake
        Assert-Test ($saved.success) 'Saving a fake body failed.'
        $path = Get-BodyPath -StorePath $store -BodyId $saved.body_id
        $length = (Get-Item -LiteralPath $path).Length
        $stream = New-Object System.IO.FileStream(
            $path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        try {
            $position = $length - 8
            [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
            $original = $stream.ReadByte()
            [void]$stream.Seek($position, [System.IO.SeekOrigin]::Begin)
            $stream.WriteByte([byte]($original -bxor 0xFF))
            $stream.Flush()
        }
        finally {
            $stream.Dispose()
        }
        $loaded = Get-SumiGuardBody -StorePath $store -BodyId $saved.body_id
        $loadedJson = $loaded | ConvertTo-Json -Compress -Depth 5
        Assert-Test (-not $loaded.success) 'A tampered body was returned as decrypted.'
        Assert-Test ($loaded.status -ceq 'DECRYPTION_FAILED') `
            'A tampered body returned an unexpected status.'
        Assert-Test (-not $loadedJson.Contains($fake)) 'The failure result carried plaintext.'
        @{
            status = $loaded.status
            plaintext_in_result = $false
        }
    }

    Invoke-HardeningCase -Name 'body_file_acl_is_inherited_restriction' -Body {
        $store = Initialize-CaseStore -Name 'fileacl-store'
        $fake = Get-FakeBody -Label 'FILEACL'
        $saved = Save-SumiGuardBody -StorePath $store -Body $fake
        Assert-Test ($saved.success) 'Saving a fake body failed.'
        $path = Get-BodyPath -StorePath $store -BodyId $saved.body_id
        $summary = Get-SidRuleSummary -Security (Get-Acl -LiteralPath $path)
        Assert-Test ($summary.rule_count -gt 0) 'The body file has no access rules.'
        Assert-Test ($summary.unexpected_rule_count -eq 0) `
            'The body file grants access to someone other than the user and SYSTEM.'
        Assert-Test ($summary.explicit_rule_count -eq 0) `
            'The body file carries explicit rules instead of the store restriction.'
        Assert-Test (Test-TextAbsentFromStore -StorePath $store -Text $fake) `
            'Plaintext was found in the store.'
        @{
            rule_count = $summary.rule_count
            unexpected_rule_count = 0
            explicit_rule_count = 0
            plaintext_absent_on_disk = $true
        }
    }

    Invoke-HardeningCase -Name 'widened_store_acl_is_refused' -Body {
        $store = Initialize-CaseStore -Name 'widened-store'
        $saved = Save-SumiGuardBody -StorePath $store -Body (Get-FakeBody -Label 'WIDEN')
        Assert-Test ($saved.success) 'Saving a fake body failed.'
        $before = @([System.IO.Directory]::GetFiles($store, '*.sgb')).Count
        # Only the DACL section is read and written back, so the owner is
        # never rewritten (that needs privileges an ordinary token lacks).
        $directory = Get-Item -LiteralPath $store
        $security = $directory.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($everyoneSid)),
            [System.Security.AccessControl.FileSystemRights]::ReadData,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$security.AddAccessRule($rule)
        $directory.SetAccessControl($security)

        $reinit = Initialize-SumiGuardLocalStore -Path $store
        $save = Save-SumiGuardBody -StorePath $store -Body (Get-FakeBody -Label 'WIDEN2')
        $read = Get-SumiGuardBody -StorePath $store -BodyId $saved.body_id
        $after = @([System.IO.Directory]::GetFiles($store, '*.sgb')).Count
        Assert-Test ($reinit.status -ceq 'EXISTING_DIRECTORY_NOT_VALID_STORE') `
            'Initialization accepted a store whose ACL was widened.'
        Assert-Test ($save.status -ceq 'STORE_VALIDATION_FAILED') `
            'Saving into a widened store was not refused.'
        Assert-Test ($read.status -ceq 'STORE_VALIDATION_FAILED') `
            'Reading from a widened store was not refused.'
        Assert-Test ($before -eq $after) 'A body was written into a widened store.'
        @{
            initialize_status = $reinit.status
            save_status = $save.status
            read_status = $read.status
            body_count_unchanged = $true
        }
    }

    Invoke-HardeningCase -Name 'inherited_store_acl_is_refused' -Body {
        $store = Initialize-CaseStore -Name 'inherit-store'
        $saved = Save-SumiGuardBody -StorePath $store -Body (Get-FakeBody -Label 'INHERIT')
        Assert-Test ($saved.success) 'Saving a fake body failed.'
        $directory = Get-Item -LiteralPath $store
        $security = $directory.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $security.SetAccessRuleProtection($false, $true)
        $directory.SetAccessControl($security)

        $save = Save-SumiGuardBody -StorePath $store -Body (Get-FakeBody -Label 'INHERIT2')
        $read = Get-SumiGuardBody -StorePath $store -BodyId $saved.body_id
        Assert-Test ($save.status -ceq 'STORE_VALIDATION_FAILED') `
            'Saving into a store with inheritance re-enabled was not refused.'
        Assert-Test ($read.status -ceq 'STORE_VALIDATION_FAILED') `
            'Reading from a store with inheritance re-enabled was not refused.'
        @{
            save_status = $save.status
            read_status = $read.status
        }
    }

    Invoke-HardeningCase -Name 'existing_plain_directory_is_not_adopted' -Body {
        $plain = Join-Path $testRootFullPath 'plain-directory'
        [void](New-Item -ItemType Directory -Path $plain -ErrorAction Stop)
        $sddlBefore = (Get-Acl -LiteralPath $plain).Sddl
        $result = Initialize-SumiGuardLocalStore -Path $plain
        $sddlAfter = (Get-Acl -LiteralPath $plain).Sddl
        $markerCreated = Test-Path -LiteralPath (Join-Path $plain '.sumi-guard-store.json')
        Assert-Test ($result.status -ceq 'EXISTING_DIRECTORY_NOT_VALID_STORE') `
            'An ordinary existing directory was accepted as a store.'
        Assert-Test ($sddlBefore -ceq $sddlAfter) 'The ACL of an ordinary directory was changed.'
        Assert-Test (-not $markerCreated) 'A store marker was written into an ordinary directory.'
        @{
            status = $result.status
            acl_unchanged = $true
            marker_created = $false
        }
    }
}
catch {
    $failure = [pscustomobject][ordered]@{
        type = $_.Exception.GetType().FullName
        message = 'Setup failed before or between cases.'
    }
}
finally {
    if (Test-Path -LiteralPath $testRootFullPath) {
        $resolvedForDelete = [System.IO.Path]::GetFullPath($testRootFullPath)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -like ($testRootPrefix + '*')) {
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

$failedCases = @($results | Where-Object { -not $_.passed } | ForEach-Object { $_.name })
if ($null -eq $failure -and $failedCases.Count -gt 0) {
    $failure = [pscustomobject][ordered]@{
        type = 'CaseFailure'
        message = 'One or more gate 3 cases failed.'
    }
}

$summary = [pscustomobject][ordered]@{
    success = $null -eq $failure
    powershell_version = $PSVersionTable.PSVersion.ToString()
    test_count = $results.Count
    passed_count = @($results | Where-Object { $_.passed }).Count
    failed_cases = $failedCases
    tests = $results.ToArray()
    failure = $failure
    plaintext_included = $false
    identity_included = $false
    test_root_cleaned = -not (Test-Path -LiteralPath $testRootFullPath)
}
$summary | ConvertTo-Json -Depth 8
if ($null -ne $failure) {
    exit 1
}
