[CmdletBinding()]
param()

# Synthetic tests for SumiGuard.EnforcementControl: the operator setting,
# the ENFORCEMENT_OFF kill switch and the notice file (docs/36).
#
# Every case works in its own control directory under %TEMP% and removes it.
# Uses Windows ACLs but not DPAPI, so it runs on the GitHub-hosted runner.
# No hook is registered and no recording store is touched.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$controlManifest = Join-Path $projectRoot 'src\SumiGuard.EnforcementControl\SumiGuard.EnforcementControl.psd1'
$decisionManifest = Join-Path $projectRoot 'src\SumiGuard.EnforcementDecision\SumiGuard.EnforcementDecision.psd1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRootPrefix = 'sumi-guard-enforcement-control-tests-'
$testRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $tempRoot ($testRootPrefix + [Guid]::NewGuid().ToString('N'))))
$results = New-Object System.Collections.Generic.List[object]
$failure = $null
$route = 'claude-code:PreToolUse:Bash'
$otherRoute = 'claude-code:PreToolUse:PowerShell'
$canary = 'SUMI_GUARD_CONTROL_CANARY_' + [Guid]::NewGuid().ToString('N')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$caseIndex = 0

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

function Invoke-ControlCase {
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

function Get-CaseDirectory {
    $script:caseIndex++
    return Join-Path $testRoot ('case-' + $script:caseIndex)
}

function Initialize-CaseControlDirectory {
    $path = Get-CaseDirectory
    $created = Initialize-SumiGuardEnforcementControlDirectory -Path $path
    Assert-Test ($created.success -and $created.status -ceq 'CREATED') 'A control directory could not be created.'
    return $path
}

function Write-CaseConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    [System.IO.File]::WriteAllText((Join-Path $Directory 'enforcement.json'), $Text, $utf8)
}

function Get-ValidConfigText {
    param([string[]]$Routes = @('claude-code:PreToolUse:Bash'))

    return ([ordered]@{
        schema_version = 1
        mode = 'ENFORCE_RECORDING'
        routes = @($Routes)
    } | ConvertTo-Json -Compress)
}

# Adds an Everyone read rule through the DACL section only, so the owner is
# never rewritten.
function Add-EveryoneReadRule {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    $security = $item.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        (New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')),
        [System.Security.AccessControl.FileSystemRights]::ReadData,
        [System.Security.AccessControl.AccessControlType]::Allow)
    [void]$security.AddAccessRule($rule)
    $item.SetAccessControl($security)
}

function Assert-Monitor {
    param(
        [Parameter(Mandatory = $true)]$Setting,
        [Parameter(Mandatory = $true)][string]$Status
    )

    Assert-Test ($Setting.setting_status -ceq $Status) ('Expected setting status ' + $Status + '.')
    Assert-Test ($Setting.requested_mode -ceq 'MONITOR') 'The setting did not fall back to MONITOR.'
    Assert-Test (-not $Setting.route_allowlisted) 'A fallback setting allowlisted the route.'
}

function Get-NoticeLine {
    param([Parameter(Mandatory = $true)][string]$Directory)

    $path = Join-Path $Directory 'enforcement-notices.ndjson'
    if (-not (Test-Path -LiteralPath $path)) {
        return ,@()
    }
    $text = [System.IO.File]::ReadAllText($path)
    return ,@($text -split "`n" | Where-Object { $_ -ne '' })
}

try {
    if (-not $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $testRoot) -notlike ($testRootPrefix + '*')) {
        throw 'Refusing to create the test root outside the resolved temporary directory.'
    }
    [void](New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop)
    Import-Module $controlManifest -Force -ErrorAction Stop
    Import-Module $decisionManifest -Force -ErrorAction Stop

    Invoke-ControlCase -Name 'control_directory_created_restricted' -Body {
        $path = Get-CaseDirectory
        $created = Initialize-SumiGuardEnforcementControlDirectory -Path $path
        $again = Initialize-SumiGuardEnforcementControlDirectory -Path $path
        $security = (Get-Item -LiteralPath $path).GetAccessControl(
            [System.Security.AccessControl.AccessControlSections]::Access)
        $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sids = @($security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
            ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        Assert-Test ($created.status -ceq 'CREATED') 'The directory was not created.'
        Assert-Test ($again.status -ceq 'READY') 'A second initialize did not report READY.'
        Assert-Test $security.AreAccessRulesProtected 'Inheritance was not cut.'
        Assert-Test (@($sids | Where-Object { $_ -cne $currentSid -and $_ -cne 'S-1-5-18' }).Count -eq 0) `
            'The directory grants access to someone other than the user and SYSTEM.'
        Assert-Test (-not (Test-Path -LiteralPath (Join-Path $path 'enforcement.json'))) `
            'Initialize wrote a setting.'
        @{ first = $created.status; second = $again.status; setting_written = $false }
    }

    Invoke-ControlCase -Name 'existing_plain_directory_not_adopted' -Body {
        $path = Get-CaseDirectory
        [void](New-Item -ItemType Directory -Path $path)
        $before = (Get-Acl -LiteralPath $path).Sddl
        $result = Initialize-SumiGuardEnforcementControlDirectory -Path $path
        $after = (Get-Acl -LiteralPath $path).Sddl
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Test ($result.status -ceq 'EXISTING_DIRECTORY_NOT_VALID_CONTROL_DIRECTORY') `
            'An ordinary directory was accepted.'
        Assert-Test ($before -ceq $after) 'The ACL of an ordinary directory was changed.'
        Assert-Monitor -Setting $setting -Status 'CONTROL_DIRECTORY_INVALID'
        @{ status = $result.status; acl_unchanged = $true; setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'absent_directory_is_monitor' -Body {
        $path = Get-CaseDirectory
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Monitor -Setting $setting -Status 'CONFIG_ABSENT'
        Assert-Test (-not (Test-Path -LiteralPath $path)) 'Reading the setting created the directory.'
        @{ setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'absent_config_is_monitor' -Body {
        $path = Initialize-CaseControlDirectory
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Monitor -Setting $setting -Status 'CONFIG_ABSENT'
        @{ setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'listed_route_enforces' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Test ($setting.setting_status -ceq 'CONFIG_LOADED') 'A valid setting was not loaded.'
        Assert-Test ($setting.requested_mode -ceq 'ENFORCE_RECORDING') 'The mode was not read.'
        Assert-Test $setting.route_allowlisted 'The listed route was not allowlisted.'
        Assert-Test ($setting.lock_timeout_milliseconds -eq 2000) 'The default lock timeout is not 2000 ms.'
        Assert-Test ($setting.configured_route_count -eq 1) 'The route count is wrong.'
        $decision = Get-SumiGuardRecordingDecision -RequestedMode $setting.requested_mode `
            -RouteAllowlisted $setting.route_allowlisted
        Assert-Test ($decision.effective_mode -ceq 'ENFORCE_RECORDING') 'The decision did not enforce.'
        @{ setting_status = $setting.setting_status; effective_mode = $decision.effective_mode }
    }

    Invoke-ControlCase -Name 'unlisted_route_stays_monitor' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $otherRoute
        $decision = Get-SumiGuardRecordingDecision -RequestedMode $setting.requested_mode `
            -RouteAllowlisted $setting.route_allowlisted
        Assert-Test (-not $setting.route_allowlisted) 'An unlisted route was allowlisted.'
        Assert-Test ($decision.effective_mode -ceq 'MONITOR' -and $decision.reason_code -ceq 'ROUTE_NOT_ALLOWLISTED') `
            'An unlisted route did not stay MONITOR.'
        @{ route_allowlisted = $false; reason_code = $decision.reason_code }
    }

    Invoke-ControlCase -Name 'route_match_is_case_sensitive' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId 'claude-code:PreToolUse:bash'
        Assert-Test (-not $setting.route_allowlisted) 'A route differing in case was allowlisted.'
        @{ route_allowlisted = $false }
    }

    Invoke-ControlCase -Name 'monitor_mode_setting_is_monitor' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text '{"schema_version":1,"mode":"MONITOR","routes":["claude-code:PreToolUse:Bash"]}'
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        $decision = Get-SumiGuardRecordingDecision -RequestedMode $setting.requested_mode `
            -RouteAllowlisted $setting.route_allowlisted
        Assert-Test ($setting.setting_status -ceq 'CONFIG_LOADED' -and $setting.requested_mode -ceq 'MONITOR') `
            'A MONITOR setting was not read as MONITOR.'
        Assert-Test ($decision.effective_mode -ceq 'MONITOR') 'A MONITOR setting enforced.'
        @{ requested_mode = $setting.requested_mode }
    }

    Invoke-ControlCase -Name 'lock_timeout_read_within_bounds' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash"],"lock_timeout_milliseconds":500}'
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Test ($setting.setting_status -ceq 'CONFIG_LOADED') 'A valid lock timeout was rejected.'
        Assert-Test ($setting.lock_timeout_milliseconds -eq 500) 'The lock timeout was not read.'
        @{ lock_timeout_milliseconds = $setting.lock_timeout_milliseconds }
    }

    Invoke-ControlCase -Name 'kill_switch_file_overrides_valid_config' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        [System.IO.File]::WriteAllText((Join-Path $path 'ENFORCEMENT_OFF'), '', $utf8)
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Monitor -Setting $setting -Status 'KILL_SWITCH_ACTIVE'
        Assert-Test $setting.kill_switch_active 'The kill switch was not reported.'
        @{ setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'kill_switch_directory_also_counts' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        [void](New-Item -ItemType Directory -Path (Join-Path $path 'ENFORCEMENT_OFF'))
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Monitor -Setting $setting -Status 'KILL_SWITCH_ACTIVE'
        @{ setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'kill_switch_overrides_broken_directory' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text 'not json'
        Add-EveryoneReadRule -Path $path
        [System.IO.File]::WriteAllText((Join-Path $path 'ENFORCEMENT_OFF'), '', $utf8)
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Monitor -Setting $setting -Status 'KILL_SWITCH_ACTIVE'
        @{ setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'removing_kill_switch_or_config_is_reversible' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        $killPath = Join-Path $path 'ENFORCEMENT_OFF'
        [System.IO.File]::WriteAllText($killPath, '', $utf8)
        $off = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Remove-Item -LiteralPath $killPath
        $on = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Remove-Item -LiteralPath (Join-Path $path 'enforcement.json')
        $removed = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Test ($off.setting_status -ceq 'KILL_SWITCH_ACTIVE') 'The kill switch did not apply.'
        Assert-Test ($on.setting_status -ceq 'CONFIG_LOADED' -and $on.route_allowlisted) `
            'Removing the kill switch did not restore the setting.'
        Assert-Monitor -Setting $removed -Status 'CONFIG_ABSENT'
        @{ with_kill_switch = $off.setting_status; without = $on.setting_status; config_deleted = $removed.setting_status }
    }

    $invalidConfigs = @(
        [pscustomobject]@{ name = 'malformed_json'; text = '{"schema_version":1,' },
        [pscustomobject]@{ name = 'empty_file'; text = '' },
        [pscustomobject]@{ name = 'top_level_array'; text = '[1]' },
        [pscustomobject]@{ name = 'unknown_key'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash"],"note":"x"}' },
        [pscustomobject]@{ name = 'key_case_differs'; text = '{"schema_version":1,"Mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash"]}' },
        [pscustomobject]@{ name = 'missing_routes'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING"}' },
        [pscustomobject]@{ name = 'wrong_schema_version'; text = '{"schema_version":2,"mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash"]}' },
        [pscustomobject]@{ name = 'schema_version_as_string'; text = '{"schema_version":"1","mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash"]}' },
        [pscustomobject]@{ name = 'unknown_mode'; text = '{"schema_version":1,"mode":"ENFORCE","routes":["claude-code:PreToolUse:Bash"]}' },
        [pscustomobject]@{ name = 'mode_case_differs'; text = '{"schema_version":1,"mode":"enforce_recording","routes":["claude-code:PreToolUse:Bash"]}' },
        [pscustomobject]@{ name = 'routes_not_array'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":"claude-code:PreToolUse:Bash"}' },
        [pscustomobject]@{ name = 'route_bad_syntax'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash; rm"]}' },
        [pscustomobject]@{ name = 'route_not_string'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":[1]}' },
        [pscustomobject]@{ name = 'duplicate_route'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash","claude-code:PreToolUse:Bash"]}' },
        [pscustomobject]@{ name = 'lock_timeout_too_small'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":[],"lock_timeout_milliseconds":50}' },
        [pscustomobject]@{ name = 'lock_timeout_too_large'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":[],"lock_timeout_milliseconds":20000}' },
        [pscustomobject]@{ name = 'lock_timeout_fractional'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":[],"lock_timeout_milliseconds":500.5}' },
        [pscustomobject]@{ name = 'lock_timeout_as_string'; text = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":[],"lock_timeout_milliseconds":"500"}' }
    )
    $tooManyRoutes = @(1..17 | ForEach-Object { 'claude-code:PreToolUse:Tool' + $_ })
    $invalidConfigs += [pscustomobject]@{ name = 'too_many_routes'; text = (Get-ValidConfigText -Routes $tooManyRoutes) }

    Invoke-ControlCase -Name 'invalid_settings_fall_back_to_monitor' -Body {
        $rejected = New-Object System.Collections.Generic.List[string]
        $accepted = New-Object System.Collections.Generic.List[string]
        foreach ($config in $invalidConfigs) {
            $path = Initialize-CaseControlDirectory
            Write-CaseConfig -Directory $path -Text $config.text
            $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
            if ($setting.setting_status -ceq 'CONFIG_INVALID' -and
                $setting.requested_mode -ceq 'MONITOR' -and -not $setting.route_allowlisted) {
                $rejected.Add($config.name)
            }
            else {
                $accepted.Add($config.name + '=' + $setting.setting_status)
            }
        }
        Assert-Test ($accepted.Count -eq 0) ('Invalid settings were not rejected: ' + ($accepted -join ','))
        @{ rejected_count = $rejected.Count; rejected = $rejected.ToArray() }
    }

    Invoke-ControlCase -Name 'empty_route_list_enforces_nothing' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":[]}'
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Test ($setting.setting_status -ceq 'CONFIG_LOADED') 'An empty route list was rejected.'
        Assert-Test (-not $setting.route_allowlisted) 'An empty route list allowlisted a route.'
        @{ configured_route_count = $setting.configured_route_count }
    }

    Invoke-ControlCase -Name 'invalid_utf8_is_invalid' -Body {
        $path = Initialize-CaseControlDirectory
        [System.IO.File]::WriteAllBytes((Join-Path $path 'enforcement.json'), [byte[]]@(0x7B, 0xFF, 0xFE, 0x7D))
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Monitor -Setting $setting -Status 'CONFIG_INVALID'
        @{ setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'oversized_config_is_refused' -Body {
        $path = Initialize-CaseControlDirectory
        $padding = ' ' * (17 * 1024)
        Write-CaseConfig -Directory $path -Text ((Get-ValidConfigText) + $padding)
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Monitor -Setting $setting -Status 'CONFIG_TOO_LARGE'
        @{ setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'widened_directory_acl_is_monitor' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        Add-EveryoneReadRule -Path $path
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        $reinit = Initialize-SumiGuardEnforcementControlDirectory -Path $path
        Assert-Monitor -Setting $setting -Status 'CONTROL_DIRECTORY_ACL_NOT_RESTRICTED'
        Assert-Test ($reinit.status -ceq 'EXISTING_DIRECTORY_NOT_VALID_CONTROL_DIRECTORY') `
            'Initialize accepted a widened directory.'
        @{ setting_status = $setting.setting_status; initialize_status = $reinit.status }
    }

    Invoke-ControlCase -Name 'widened_config_file_acl_is_monitor' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        Add-EveryoneReadRule -Path (Join-Path $path 'enforcement.json')
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        Assert-Monitor -Setting $setting -Status 'CONFIG_ACL_NOT_RESTRICTED'
        @{ setting_status = $setting.setting_status }
    }

    Invoke-ControlCase -Name 'invalid_route_argument_is_monitor' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        $statuses = New-Object System.Collections.Generic.List[string]
        foreach ($bad in @('', 'Bash', 'claude-code:PreToolUse:Bash:extra', ('claude-code:PreToolUse:' + $canary + '/x'))) {
            $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $bad
            Assert-Monitor -Setting $setting -Status 'INVALID_ROUTE_ID'
            $statuses.Add($setting.setting_status)
        }
        $relative = Get-SumiGuardEnforcementSetting -ControlDirectory 'relative\dir' -RouteId $route
        Assert-Monitor -Setting $relative -Status 'CONTROL_DIRECTORY_INVALID'
        @{ invalid_route_count = $statuses.Count; relative_directory = $relative.setting_status }
    }

    Invoke-ControlCase -Name 'setting_result_has_fixed_shape_and_no_path' -Body {
        $path = Initialize-CaseControlDirectory
        Write-CaseConfig -Directory $path -Text (Get-ValidConfigText)
        $setting = Get-SumiGuardEnforcementSetting -ControlDirectory $path -RouteId $route
        $expected = @('schema_version', 'setting_status', 'requested_mode', 'route_allowlisted',
            'kill_switch_active', 'lock_timeout_milliseconds', 'configured_route_count')
        $actual = @($setting.PSObject.Properties.Name)
        $wire = $setting | ConvertTo-Json -Compress
        Assert-Test (($actual -join ',') -ceq ($expected -join ',')) 'The setting result shape changed.'
        Assert-Test (-not $wire.Contains($testRoot)) 'The setting result carried a path.'
        @{ property_count = $actual.Count }
    }

    Invoke-ControlCase -Name 'notice_persisted_with_fixed_fields' -Body {
        $path = Initialize-CaseControlDirectory
        $executionId = [Guid]::NewGuid().ToString('N')
        $first = Write-SumiGuardEnforcementNotice -ControlDirectory $path -RouteId $route `
            -Decision 'DENY' -ReasonCode 'STORE_CAPACITY_REACHED' -ExecutionId $executionId
        $second = Write-SumiGuardEnforcementNotice -ControlDirectory $path -RouteId $route `
            -Decision 'ALLOW' -ReasonCode 'INVALID_HOOK_INPUT_NOT_ENFORCED'
        $lines = Get-NoticeLine -Directory $path
        Assert-Test ($first.notice_status -ceq 'NOTICE_PERSISTED' -and $null -eq $first.failure_code) `
            'The first notice was not persisted.'
        Assert-Test ($second.notice_status -ceq 'NOTICE_PERSISTED') 'The second notice was not persisted.'
        Assert-Test ($lines.Count -eq 2) 'The notice file does not hold two lines.'
        $parsed = $lines[0] | ConvertFrom-Json
        $expected = @('schema_version', 'recorded_at_utc', 'route_id', 'decision', 'reason_code', 'execution_id', 'action_hint')
        Assert-Test ((@($parsed.PSObject.Properties.Name) -join ',') -ceq ($expected -join ',')) `
            'The notice line has unexpected fields.'
        Assert-Test ($parsed.reason_code -ceq 'STORE_CAPACITY_REACHED' -and $parsed.action_hint -ceq 'RUN_RETENTION_CLEANUP') `
            'The capacity notice did not carry the cleanup hint.'
        Assert-Test ($parsed.execution_id -ceq $executionId) 'The execution id was not kept.'
        $second = $lines[1] | ConvertFrom-Json
        Assert-Test ($null -eq $second.execution_id -and $null -eq $second.action_hint) `
            'An absent execution id or hint was not written as null.'
        Assert-Test (-not ([System.IO.File]::ReadAllText((Join-Path $path 'enforcement-notices.ndjson'))).Contains($testRoot)) `
            'The notice file carried a path.'
        @{ line_count = $lines.Count; action_hint = $parsed.action_hint }
    }

    Invoke-ControlCase -Name 'notice_rejects_untrusted_fields' -Body {
        $path = Initialize-CaseControlDirectory
        $attempts = @(
            @{ RouteId = $route; Decision = 'DENY'; ReasonCode = 'store_capacity_reached'; ExecutionId = '' },
            @{ RouteId = $route; Decision = 'DENY'; ReasonCode = ($canary + ' C:\x'); ExecutionId = '' },
            @{ RouteId = $route; Decision = 'BLOCK'; ReasonCode = 'LOCK_TIMEOUT'; ExecutionId = '' },
            @{ RouteId = 'bad route'; Decision = 'DENY'; ReasonCode = 'LOCK_TIMEOUT'; ExecutionId = '' },
            @{ RouteId = $route; Decision = 'DENY'; ReasonCode = 'LOCK_TIMEOUT'; ExecutionId = $canary }
        )
        foreach ($attempt in $attempts) {
            $result = Write-SumiGuardEnforcementNotice -ControlDirectory $path @attempt
            Assert-Test ($result.notice_status -ceq 'NOTICE_NOT_PERSISTED' -and $result.failure_code -ceq 'INVALID_NOTICE_FIELD') `
                'An untrusted notice field was accepted.'
        }
        Assert-Test (-not (Test-Path -LiteralPath (Join-Path $path 'enforcement-notices.ndjson'))) `
            'A rejected notice created the notice file.'
        @{ rejected_count = $attempts.Count }
    }

    Invoke-ControlCase -Name 'notice_failure_is_reported_not_thrown' -Body {
        $missing = Get-CaseDirectory
        $missingResult = Write-SumiGuardEnforcementNotice -ControlDirectory $missing -RouteId $route `
            -Decision 'DENY' -ReasonCode 'LOCK_TIMEOUT'
        $widened = Initialize-CaseControlDirectory
        Add-EveryoneReadRule -Path $widened
        $widenedResult = Write-SumiGuardEnforcementNotice -ControlDirectory $widened -RouteId $route `
            -Decision 'DENY' -ReasonCode 'LOCK_TIMEOUT'
        Assert-Test ($missingResult.failure_code -ceq 'CONTROL_DIRECTORY_INVALID') 'A missing directory was not reported.'
        Assert-Test (-not (Test-Path -LiteralPath $missing)) 'A notice created the control directory.'
        Assert-Test ($widenedResult.failure_code -ceq 'CONTROL_DIRECTORY_ACL_NOT_RESTRICTED') `
            'A widened directory accepted a notice.'
        @{ missing = $missingResult.failure_code; widened = $widenedResult.failure_code }
    }

    Invoke-ControlCase -Name 'notice_file_is_bounded' -Body {
        $path = Initialize-CaseControlDirectory
        $noticePath = Join-Path $path 'enforcement-notices.ndjson'
        $stream = [System.IO.File]::Open($noticePath, [System.IO.FileMode]::CreateNew)
        try {
            $stream.SetLength(1MB - 10)
        }
        finally {
            $stream.Dispose()
        }
        $result = Write-SumiGuardEnforcementNotice -ControlDirectory $path -RouteId $route `
            -Decision 'DENY' -ReasonCode 'LOCK_TIMEOUT'
        $length = (Get-Item -LiteralPath $noticePath).Length
        Assert-Test ($result.failure_code -ceq 'NOTICE_FILE_FULL') 'A full notice file accepted a line.'
        Assert-Test ($length -eq (1MB - 10)) 'A full notice file grew.'
        @{ failure_code = $result.failure_code }
    }

    Invoke-ControlCase -Name 'notice_lock_wait_is_bounded' -Body {
        $path = Initialize-CaseControlDirectory
        $noticePath = Join-Path $path 'enforcement-notices.ndjson'
        $holder = [System.IO.File]::Open(
            $noticePath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None)
        try {
            $clock = [System.Diagnostics.Stopwatch]::StartNew()
            $result = Write-SumiGuardEnforcementNotice -ControlDirectory $path -RouteId $route `
                -Decision 'DENY' -ReasonCode 'LOCK_TIMEOUT'
            $clock.Stop()
        }
        finally {
            $holder.Dispose()
        }
        Assert-Test ($result.failure_code -ceq 'NOTICE_LOCK_TIMEOUT') 'A held notice file did not time out.'
        Assert-Test ($clock.ElapsedMilliseconds -lt 5000) 'The notice lock wait was not bounded.'
        $after = Write-SumiGuardEnforcementNotice -ControlDirectory $path -RouteId $route `
            -Decision 'DENY' -ReasonCode 'LOCK_TIMEOUT'
        Assert-Test ($after.notice_status -ceq 'NOTICE_PERSISTED') 'The notice did not recover after the lock was released.'
        @{ failure_code = $result.failure_code; recovered = $true }
    }

    Invoke-ControlCase -Name 'only_expected_functions_exported' -Body {
        $exports = @(Get-Command -Module 'SumiGuard.EnforcementControl' -CommandType Function |
            Select-Object -ExpandProperty Name | Sort-Object)
        $expected = @('Get-SumiGuardEnforcementSetting', 'Initialize-SumiGuardEnforcementControlDirectory',
            'Write-SumiGuardEnforcementNotice')
        Assert-Test (($exports -join ',') -ceq ($expected -join ',')) 'The module exports unexpected functions.'
        @{ export_count = $exports.Count }
    }
}
catch {
    $failure = [pscustomobject][ordered]@{
        type = $_.Exception.GetType().FullName
        message = 'Setup failed before or between cases.'
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedForDelete = [System.IO.Path]::GetFullPath($testRoot)
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
        message = 'One or more enforcement control cases failed.'
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
    hook_registered = $false
    recording_store_used = $false
    test_root_cleaned = -not (Test-Path -LiteralPath $testRoot)
}
$summary | ConvertTo-Json -Depth 8
if ($null -ne $failure) {
    exit 1
}
