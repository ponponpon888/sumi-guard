[CmdletBinding()]
param()

# Synthetic tests for SumiGuard.HookSetup and
# tools/Invoke-SumiGuardClaudeMonitorHookSetup.ps1. Every settings file and
# store is a disposable folder under %TEMP%; no real Claude Code settings are
# read or written. Stores are stand-ins (folders with their marker file), so
# -InitializeStores, which needs DPAPI, is not exercised here.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$setupManifest = Join-Path (Join-Path (Join-Path $projectRoot 'src') 'SumiGuard.HookSetup') 'SumiGuard.HookSetup.psd1'
$toolPath = Join-Path (Join-Path $projectRoot 'tools') 'Invoke-SumiGuardClaudeMonitorHookSetup.ps1'
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = [IO.Path]::GetFullPath((Join-Path $tempRoot ('sumi-guard-hook-setup-tests-' + [Guid]::NewGuid().ToString('N'))))
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$hostExecutable = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$secretSetting = 'SYNTHETIC_SETTING_VALUE_7d21'
$results = New-Object System.Collections.Generic.List[object]
$observedOutputs = New-Object System.Collections.Generic.List[string]
$failure = $null
$currentCase = '<none>'

$hookArgs = @('-NoProfile', '-File', 'C:\repo\hooks\Invoke-SumiGuardMonitorHook.ps1', '-HookInputProfile', 'CLAUDE_PRETOOLUSE')
$otherHookGroup = '{"matcher":"Bash","hooks":[{"type":"command","command":"powershell.exe","args":["-File","C:\\Users\\me\\.claude\\hooks\\guard-sql.ps1"]}]}'
$userSettings = '{"permissions":{"defaultMode":"default","deny":["Bash(rm -rf:*)"],"allow":[]},' +
    '"env":{"NOTE":"' + $secretSetting + ' 日本語 😀"},' +
    '"hooks":{"PreToolUse":[' + $otherHookGroup + '],"PostToolUse":[{"matcher":"*","hooks":[{"type":"command","command":"echo"}]}]},' +
    '"numbers":[1,2.5,-3],"flag":false,"nothing":null}'

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [InvalidOperationException]::new($Message)
    }
}

function Add-TestResult {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Evidence
    )

    $results.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $true
        evidence = [pscustomobject]$Evidence
    })
}

function Get-Plan {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string[]]$Arguments = $hookArgs
    )

    return SumiGuard.HookSetup\Get-SumiGuardClaudeMonitorHookPlan -Action $Action -SettingsText $Text `
        -PowerShellPath 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -HookArguments $Arguments
}

function ConvertTo-Canonical {
    param([Parameter(Mandatory = $true)][string]$Text)

    return ($Text | ConvertFrom-Json | ConvertTo-Json -Depth 100 -Compress)
}

function Get-MonitorEntryCount {
    param([Parameter(Mandatory = $true)][string]$Text)

    $settings = $Text | ConvertFrom-Json
    $count = 0
    foreach ($group in @($settings.hooks.PreToolUse)) {
        foreach ($hook in @($group.hooks)) {
            if (($hook | ConvertTo-Json -Depth 10 -Compress) -match 'Invoke-SumiGuardMonitorHook\.ps1') { $count++ }
        }
    }
    return $count
}

function Initialize-FakeStore {
    param([Parameter(Mandatory = $true)][string]$Root)

    foreach ($pair in @(
        @('execution-store', '.sumi-guard-execution-store.json'),
        @('body-store', '.sumi-guard-store.json'),
        @('assessment-store', '.sumi-guard-assessment-store.json'))) {
        $folder = Join-Path $Root $pair[0]
        $null = New-Item -ItemType Directory -Path $folder -Force
        [IO.File]::WriteAllBytes((Join-Path $folder $pair[1]), $utf8.GetBytes('{}'))
    }
}

function Invoke-Setup {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $toolPath) + $Arguments
    $output = & $hostExecutable @all 2>&1
    $code = $LASTEXITCODE
    $text = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    $observedOutputs.Add($text)
    # -WhatIf adds PowerShell's own "What if:" line before the summary, so the
    # summary is the last line, and it must be the only JSON line.
    $lines = @($text -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $jsonLines = @($lines | Where-Object { $_.TrimStart().StartsWith('{') })
    $parsed = $null
    if ($lines.Count -gt 0 -and $jsonLines.Count -eq 1 -and $jsonLines[0] -ceq $lines[$lines.Count - 1]) {
        try { $parsed = $jsonLines[0] | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    }
    Assert-Test ($null -ne $parsed) ('Setup output did not end in one JSON summary (exit ' + $code + ').')
    return [pscustomobject]@{ exit_code = $code; summary = $parsed }
}

function Get-FileText {
    param([Parameter(Mandatory = $true)][string]$Path)

    return $utf8.GetString([IO.File]::ReadAllBytes($Path))
}

function Get-BackupFile {
    param([Parameter(Mandatory = $true)][string]$Directory)

    return @(Get-ChildItem -LiteralPath $Directory -Force -File | Where-Object { $_.Name -like '*.sumi-guard-backup-*' })
}

try {
    $null = New-Item -ItemType Directory -Path $testRoot
    Import-Module -Name $setupManifest -Force -ErrorAction Stop

    # ---- Planning (pure) ---------------------------------------------------
    $currentCase = 'plan_install_preserves_everything_else'
    $install = Get-Plan -Action Install -Text $userSettings
    Assert-Test ($install.success -and $install.status -ceq 'INSTALL') ('Expected INSTALL, got ' + $install.status)
    Assert-Test ((Get-MonitorEntryCount $install.new_text) -eq 1) 'Install did not add exactly one entry.'
    $removedAgain = Get-Plan -Action Uninstall -Text $install.new_text
    Assert-Test ((ConvertTo-Canonical $removedAgain.new_text) -ceq (ConvertTo-Canonical $userSettings)) 'Install then uninstall did not give back the original settings value.'
    Assert-Test ($install.new_text.Contains('guard-sql.ps1') -and $install.new_text.Contains('PostToolUse')) 'Other hooks were lost.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        status = $install.status
        monitor_entries = 1
        round_trip_equal = $true
    })

    $currentCase = 'plan_install_is_idempotent'
    $again = Get-Plan -Action Install -Text $install.new_text
    Assert-Test ($again.success -and $again.status -ceq 'ALREADY_INSTALLED' -and -not $again.change_required -and $null -eq $again.new_text) (
        'Second install was not a no-op: ' + $again.status)
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $again.status })

    $currentCase = 'plan_changed_arguments_update_in_place'
    $changedArgs = @($hookArgs + @('-ExecutionStorePath', 'D:\other\execution-store'))
    $update = Get-Plan -Action Install -Text $install.new_text -Arguments $changedArgs
    Assert-Test ($update.status -ceq 'UPDATE' -and (Get-MonitorEntryCount $update.new_text) -eq 1) 'Update did not leave exactly one entry.'
    Assert-Test ($update.new_text.Contains('D:\\other\\execution-store')) 'Updated arguments were not written.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $update.status; monitor_entries = 1 })

    $currentCase = 'plan_hand_placed_entry_in_shared_group'
    $sharedGroup = '{"hooks":{"PreToolUse":[{"matcher":"PowerShell","hooks":[' +
        '{"type":"command","command":"x.exe","args":["-File","mine.ps1"]},' +
        '{"type":"command","command":"powershell.exe","args":["-NoProfile","-File","C:\\old\\hooks\\Invoke-SumiGuardMonitorHook.ps1"]}]}]}}'
    $shared = Get-Plan -Action Uninstall -Text $sharedGroup
    $sharedParsed = $shared.new_text | ConvertFrom-Json
    Assert-Test ($shared.status -ceq 'REMOVE' -and @($sharedParsed.hooks.PreToolUse).Count -eq 1 -and @($sharedParsed.hooks.PreToolUse[0].hooks).Count -eq 1) (
        'Removing from a shared group dropped the user hook or the group.')
    Assert-Test ($sharedParsed.hooks.PreToolUse[0].hooks[0].args[1] -ceq 'mine.ps1') 'The wrong hook was removed.'
    $sharedInstall = Get-Plan -Action Install -Text $sharedGroup
    Assert-Test ($sharedInstall.status -ceq 'UPDATE' -and (Get-MonitorEntryCount $sharedInstall.new_text) -eq 1) 'Install over a hand-placed entry did not leave exactly one.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        uninstall_status = $shared.status
        user_hook_kept = $true
        install_status = $sharedInstall.status
    })

    $currentCase = 'plan_install_into_missing_or_empty_settings'
    $fromNothing = Get-Plan -Action Install -Text ''
    $fromEmpty = Get-Plan -Action Install -Text '{}'
    $emptyHooks = Get-Plan -Action Install -Text '{"hooks":{"PreToolUse":[]}}'
    Assert-Test ($fromNothing.status -ceq 'INSTALL' -and $fromEmpty.status -ceq 'INSTALL' -and $emptyHooks.status -ceq 'INSTALL') 'Install into empty settings failed.'
    $backToNothing = Get-Plan -Action Uninstall -Text $fromNothing.new_text
    Assert-Test ((ConvertTo-Canonical $backToNothing.new_text) -ceq '{}') 'Uninstall did not drop the containers it emptied.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        missing = $fromNothing.status
        empty_object = $fromEmpty.status
        empty_pretooluse = $emptyHooks.status
        uninstall_result = '{}'
    })

    $currentCase = 'plan_refuses_what_it_would_have_to_guess'
    $refusals = [ordered]@{
        'not json' = @('{"hooks":', 'SETTINGS_INVALID_JSON')
        'array root' = @('[1,2]', 'SETTINGS_NOT_OBJECT')
        'hooks is array' = @('{"hooks":[]}', 'HOOKS_SHAPE_UNSUPPORTED')
        'pretooluse is object' = @('{"hooks":{"PreToolUse":{}}}', 'HOOKS_SHAPE_UNSUPPORTED')
        'group hooks is string' = @('{"hooks":{"PreToolUse":[{"matcher":"x","hooks":"y"}]}}', 'HOOKS_SHAPE_UNSUPPORTED')
        'group is string' = @('{"hooks":{"PreToolUse":["x"]}}', 'HOOKS_SHAPE_UNSUPPORTED')
    }
    foreach ($name in $refusals.Keys) {
        foreach ($action in @('Install', 'Uninstall')) {
            $refused = Get-Plan -Action $action -Text $refusals[$name][0]
            Assert-Test ((-not $refused.success) -and $refused.status -ceq $refusals[$name][1] -and $null -eq $refused.new_text) (
                'Not refused (' + $name + ', ' + $action + '): ' + $refused.status)
        }
    }
    $noFile = Get-Plan -Action Install -Text '{}' -Arguments @('-NoProfile', '-Command', 'Invoke-SumiGuardMonitorHook.ps1')
    Assert-Test ($noFile.status -ceq 'HOOK_ENTRY_INVALID') 'An entry without -File was accepted.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        refused_shapes = $refusals.Count
        hook_entry_without_file = $noFile.status
    })

    $currentCase = 'plan_uninstall_without_entry_is_noop'
    $nothingToRemove = Get-Plan -Action Uninstall -Text $userSettings
    Assert-Test ($nothingToRemove.status -ceq 'NOT_INSTALLED' -and -not $nothingToRemove.change_required) 'Uninstall without entry was not a no-op.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $nothingToRemove.status })

    # ---- Tool (file handling) ----------------------------------------------
    $storeRoot = Join-Path $testRoot 'stores'
    Initialize-FakeStore -Root $storeRoot

    $currentCase = 'tool_install_creates_bom_free_settings'
    $freshDir = Join-Path $testRoot 'fresh\.claude'
    $null = New-Item -ItemType Directory -Path $freshDir -Force
    $freshSettings = Join-Path $freshDir 'settings.local.json'
    $created = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', $freshSettings, '-StoreRoot', $storeRoot)
    Assert-Test ($created.exit_code -eq 0 -and $created.summary.status -ceq 'INSTALLED') ('Install failed: ' + $created.summary.status)
    [byte[]]$freshBytes = [IO.File]::ReadAllBytes($freshSettings)
    Assert-Test (-not ($freshBytes[0] -eq 0xEF)) 'Settings file was written with a BOM.'
    $freshText = Get-FileText $freshSettings
    Assert-Test ((Get-MonitorEntryCount $freshText) -eq 1) 'Written settings do not hold exactly one entry.'
    Assert-Test ($freshText.Contains('CLAUDE_PRETOOLUSE') -and $freshText.Contains('assessment-store') -and -not $freshText.Contains('EnforcementHook')) 'Entry is not the MONITOR registration.'
    Assert-Test (@(Get-BackupFile $freshDir).Count -eq 0) 'A backup was made of a file that did not exist.'
    Assert-Test ($created.summary.enforcement_hook_registered -eq $false) 'Summary did not state the enforcement hook stays unregistered.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        status = $created.summary.status
        bom = $false
        backups = 0
    })

    $currentCase = 'tool_second_install_changes_nothing'
    $second = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', $freshSettings, '-StoreRoot', $storeRoot)
    Assert-Test ($second.exit_code -eq 0 -and $second.summary.status -ceq 'ALREADY_INSTALLED') ('Second install: ' + $second.summary.status)
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($freshSettings)) -ceq [Convert]::ToBase64String($freshBytes)) 'Second install rewrote the file.'
    Assert-Test (@(Get-BackupFile $freshDir).Count -eq 0) 'Second install made a backup.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $second.summary.status; bytes_unchanged = $true })

    $currentCase = 'tool_install_keeps_user_settings_and_backs_up'
    $userDir = Join-Path $testRoot 'user\.claude'
    $null = New-Item -ItemType Directory -Path $userDir -Force
    $userPath = Join-Path $userDir 'settings.json'
    [byte[]]$originalBytes = @([byte]0xEF, [byte]0xBB, [byte]0xBF) + $utf8.GetBytes($userSettings)
    [IO.File]::WriteAllBytes($userPath, $originalBytes)
    $userInstall = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', $userPath, '-StoreRoot', $storeRoot)
    Assert-Test ($userInstall.exit_code -eq 0 -and $userInstall.summary.status -ceq 'INSTALLED') ('User install: ' + $userInstall.summary.status)
    $backups = @(Get-BackupFile $userDir)
    Assert-Test ($backups.Count -eq 1 -and $backups[0].Name -ceq $userInstall.summary.backup_file_name) 'Backup was not reported or not made once.'
    Assert-Test ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backups[0].FullName)) -ceq [Convert]::ToBase64String($originalBytes)) 'Backup is not the original bytes.'
    $installedText = Get-FileText $userPath
    $restoredValue = (Get-Plan -Action Uninstall -Text $installedText).new_text
    Assert-Test ((ConvertTo-Canonical $restoredValue) -ceq (ConvertTo-Canonical $userSettings)) 'User settings value changed outside the SUMI Guard entry.'
    Assert-Test ($installedText.Contains('日本語 😀')) 'Non-ASCII text in user settings was not kept as text.'
    Assert-Test (@(Get-ChildItem -LiteralPath $userDir -Force -File | Where-Object { $_.Name -like '.sumi-guard-settings-*' }).Count -eq 0) 'A temporary file was left behind.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        status = $userInstall.summary.status
        backup_equals_original = $true
        value_preserved = $true
        bom_input_accepted = $true
    })

    $currentCase = 'tool_whatif_writes_nothing'
    $whatIfDir = Join-Path $testRoot 'whatif\.claude'
    $null = New-Item -ItemType Directory -Path $whatIfDir -Force
    $whatIfPath = Join-Path $whatIfDir 'settings.json'
    [IO.File]::WriteAllBytes($whatIfPath, $utf8.GetBytes($userSettings))
    $whatIf = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', $whatIfPath, '-StoreRoot', $storeRoot, '-WhatIf')
    Assert-Test ($whatIf.exit_code -eq 0 -and $whatIf.summary.status -ceq 'WHATIF' -and $whatIf.summary.planned_status -ceq 'INSTALLED') ('WhatIf: ' + $whatIf.summary.status)
    Assert-Test ((Get-FileText $whatIfPath) -ceq $userSettings -and @(Get-BackupFile $whatIfDir).Count -eq 0) 'WhatIf changed the file or made a backup.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ status = $whatIf.summary.status; planned = $whatIf.summary.planned_status })

    $currentCase = 'tool_refuses_before_writing'
    $missingStores = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', $whatIfPath, '-StoreRoot', (Join-Path $testRoot 'no-stores'))
    Assert-Test ($missingStores.exit_code -eq 1 -and $missingStores.summary.status -ceq 'STORES_NOT_READY' -and @($missingStores.summary.missing_stores).Count -eq 3) (
        'Missing stores: ' + $missingStores.summary.status)
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $testRoot 'no-stores'))) 'A store folder was created without -InitializeStores.'
    $badJsonPath = Join-Path $whatIfDir 'broken.json'
    [IO.File]::WriteAllBytes($badJsonPath, $utf8.GetBytes('{"hooks": '))
    $badJson = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', $badJsonPath, '-StoreRoot', $storeRoot)
    Assert-Test ($badJson.exit_code -eq 1 -and $badJson.summary.status -ceq 'SETTINGS_INVALID_JSON' -and (Get-FileText $badJsonPath) -ceq '{"hooks": ') 'Broken settings were not left alone.'
    $noDir = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', (Join-Path $testRoot 'nowhere\.claude\settings.json'), '-StoreRoot', $storeRoot)
    Assert-Test ($noDir.summary.status -ceq 'SETTINGS_DIRECTORY_MISSING' -and -not (Test-Path -LiteralPath (Join-Path $testRoot 'nowhere'))) 'Missing settings folder was created.'
    $isDir = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', $whatIfDir, '-StoreRoot', $storeRoot)
    $noRoot = Invoke-Setup -Arguments @('-Action', 'Install', '-SettingsPath', $whatIfPath)
    Assert-Test ($isDir.summary.status -ceq 'SETTINGS_PATH_INVALID' -and $noRoot.summary.status -ceq 'STORE_ROOT_REQUIRED') 'Path checks did not refuse.'
    Assert-Test (@(Get-BackupFile $whatIfDir).Count -eq 0 -and (Get-FileText $whatIfPath) -ceq $userSettings) 'A refused run touched settings.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        missing_stores = $missingStores.summary.status
        invalid_json = $badJson.summary.status
        missing_folder = $noDir.summary.status
        directory_as_settings = $isDir.summary.status
        no_store_root = $noRoot.summary.status
    })

    $currentCase = 'tool_uninstall_removes_only_the_entry'
    $removed = Invoke-Setup -Arguments @('-Action', 'Uninstall', '-SettingsPath', $userPath)
    Assert-Test ($removed.exit_code -eq 0 -and $removed.summary.status -ceq 'REMOVED' -and $removed.summary.stores_kept -eq $true) ('Uninstall: ' + $removed.summary.status)
    Assert-Test ((ConvertTo-Canonical (Get-FileText $userPath)) -ceq (ConvertTo-Canonical $userSettings)) 'Uninstall did not give back the original settings value.'
    Assert-Test (Test-Path -LiteralPath (Join-Path (Join-Path $storeRoot 'execution-store') '.sumi-guard-execution-store.json')) 'Uninstall touched a store.'
    $removedAgain = Invoke-Setup -Arguments @('-Action', 'Uninstall', '-SettingsPath', $userPath)
    $missingFile = Invoke-Setup -Arguments @('-Action', 'Uninstall', '-SettingsPath', (Join-Path $userDir 'absent.json'))
    Assert-Test ($removedAgain.summary.status -ceq 'NOT_INSTALLED' -and $missingFile.summary.status -ceq 'NOT_INSTALLED') 'Repeated uninstall was not a no-op.'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $userDir 'absent.json'))) 'Uninstall created a settings file.'
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{
        status = $removed.summary.status
        repeated = $removedAgain.summary.status
        absent_file = $missingFile.summary.status
        stores_kept = $true
    })

    $currentCase = 'outputs_carry_no_path_or_setting_value'
    $leaks = 0
    foreach ($text in $observedOutputs) {
        if ($text.Contains($secretSetting) -or
            $text.IndexOf($testRoot, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $text.Contains('sumi-guard-hook-setup-tests-') -or
            $text.Contains('guard-sql')) {
            $leaks++
        }
    }
    Assert-Test ($leaks -eq 0) ('Tool output exposed a path or setting value in ' + $leaks + ' outputs.')
    Add-TestResult -Name $currentCase -Evidence ([ordered]@{ outputs_checked = $observedOutputs.Count; leaks = $leaks })
}
catch {
    $ownAssertion = $_.Exception.GetType() -eq [InvalidOperationException]
    $failure = [pscustomobject][ordered]@{
        failure_stage = $currentCase
        failure_line = $_.InvocationInfo.ScriptLineNumber
        type = $_.Exception.GetType().FullName
        message = if ($ownAssertion) { $_.Exception.Message } else { '<withheld>' }
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedForDelete = [IO.Path]::GetFullPath($testRoot)
        if ($resolvedForDelete.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedForDelete) -like 'sumi-guard-hook-setup-tests-*') {
            Remove-Item -LiteralPath $resolvedForDelete -Recurse -Force
        }
    }
}

$summary = [pscustomobject][ordered]@{
    success = $null -eq $failure
    powershell_version = $PSVersionTable.PSVersion.ToString()
    test_count = $results.Count
    results = $results.ToArray()
    failure = $failure
    failure_stage = if ($null -ne $failure) { $failure.failure_stage } else { $null }
    failure_line = if ($null -ne $failure) { $failure.failure_line } else { $null }
    failure_exception_type = if ($null -ne $failure) { $failure.type } else { $null }
    failed_cases = if ($null -ne $failure) { @($failure.failure_stage + ': ' + $failure.message) } else { @() }
    test_root_cleaned = -not (Test-Path -LiteralPath $testRoot)
}
$summary | ConvertTo-Json -Depth 10
if ($null -ne $failure) { exit 1 }
