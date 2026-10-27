[CmdletBinding()]
param()

# Synthetic tests for hooks/Invoke-SumiGuardEnforcementHook.ps1 (docs/37).
#
# The hook runs in this process with -RawHookInputJson and a test seam in
# place of the execution adapter, so no DPAPI store is touched and no host is
# involved. Each case has its own control directory under %TEMP%, removed at
# the end. What these cases cannot show (real stdin from Claude Code, the
# real adapter, a host honouring the deny) is left to the operator
# measurement in docs/37.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$hookPath = Join-Path $projectRoot 'hooks\Invoke-SumiGuardEnforcementHook.ps1'
$controlManifest = Join-Path $projectRoot 'src\SumiGuard.EnforcementControl\SumiGuard.EnforcementControl.psd1'
$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$testRootPrefix = 'sumi-guard-enforcement-hook-tests-'
$testRoot = [System.IO.Path]::GetFullPath(
    (Join-Path $tempRoot ($testRootPrefix + [Guid]::NewGuid().ToString('N'))))
$results = New-Object System.Collections.Generic.List[object]
$failure = $null
$utf8 = New-Object System.Text.UTF8Encoding($false)
$canary = 'SUMI_GUARD_HOOK_CANARY_' + [Guid]::NewGuid().ToString('N')
$golden = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"SUMI Guard: required recording not confirmed."}}'
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

function Invoke-HookCase {
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

function Initialize-CaseControl {
    param(
        [AllowNull()][string]$ConfigText = '{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":["claude-code:PreToolUse:Bash"]}',
        [switch]$KillSwitch
    )

    $script:caseIndex++
    $caseRoot = Join-Path $testRoot ('case-' + $script:caseIndex)
    [void](New-Item -ItemType Directory -Path $caseRoot)
    $control = Join-Path $caseRoot 'control'
    $created = Initialize-SumiGuardEnforcementControlDirectory -Path $control
    Assert-Test ($created.status -ceq 'CREATED') 'A control directory could not be created.'
    if ($null -ne $ConfigText) {
        [System.IO.File]::WriteAllText((Join-Path $control 'enforcement.json'), $ConfigText, $utf8)
    }
    if ($KillSwitch) {
        [System.IO.File]::WriteAllText((Join-Path $control 'ENFORCEMENT_OFF'), '', $utf8)
    }
    return [pscustomobject]@{ root = $caseRoot; control = $control }
}

function Get-EventJson {
    param(
        [string]$ToolName = 'Bash',
        [string]$Command = 'echo hello',
        [string]$ToolUseId = 'toolu_test_1',
        [switch]$OmitCommand
    )

    $toolInput = [ordered]@{ description = 'synthetic' }
    if (-not $OmitCommand) { $toolInput.command = $Command }
    return ([ordered]@{
        session_id = 'session_test'
        transcript_path = 'C:\synthetic\transcript.jsonl'
        cwd = 'C:\synthetic'
        hook_event_name = 'PreToolUse'
        tool_name = $ToolName
        tool_input = $toolInput
        tool_use_id = $ToolUseId
    } | ConvertTo-Json -Compress -Depth 4)
}

function Invoke-EnforcementHook {
    param(
        [Parameter(Mandatory = $true)]$Case,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EventJson,
        [string]$Outcome = 'TEST_RECORDED',
        [switch]$ForceInternalError
    )

    $resultPath = Join-Path $Case.root 'result.json'
    if (Test-Path -LiteralPath $resultPath) { Remove-Item -LiteralPath $resultPath }
    $arguments = @{
        RawHookInputJson = $EventJson
        ExecutionStorePath = (Join-Path $Case.root 'execution-store')
        LocalStorePath = (Join-Path $Case.root 'body-store')
        ControlDirectory = $Case.control
        ResultPath = $resultPath
        TestIntentSaveOutcome = $Outcome
    }
    if ($ForceInternalError) { $arguments.TestForceInternalError = $true }
    $output = @(& $hookPath @arguments)
    $detail = $null
    if (Test-Path -LiteralPath $resultPath) {
        $detail = [System.IO.File]::ReadAllText($resultPath) | ConvertFrom-Json
    }
    $noticePath = Join-Path $Case.control 'enforcement-notices.ndjson'
    $notices = @()
    if (Test-Path -LiteralPath $noticePath) {
        $notices = @([System.IO.File]::ReadAllText($noticePath) -split "`n" |
            Where-Object { $_ -ne '' } | ForEach-Object { $_ | ConvertFrom-Json })
    }
    return [pscustomobject]@{
        output = $output
        detail = $detail
        notices = $notices
        exit_code = $LASTEXITCODE
    }
}

function Assert-StepsAside {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$HookStatus
    )

    Assert-Test ($Run.output.Count -eq 0) 'The hook wrote to standard output while not enforcing.'
    Assert-Test ($null -ne $Run.detail -and $Run.detail.hook_status -ceq $HookStatus) `
        ('Expected hook status ' + $HookStatus + '.')
    Assert-Test ($Run.detail.intent_status -ceq 'NOT_ATTEMPTED') 'The hook recorded while not enforcing.'
    Assert-Test ($Run.notices.Count -eq 0) 'The hook wrote a notice while not enforcing.'
    Assert-Test ($Run.exit_code -eq 0) 'The hook exit code was not 0.'
}

function Assert-Denied {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    Assert-Test ($Run.output.Count -eq 1 -and [string]$Run.output[0] -ceq $golden) `
        'The hook did not write exactly the fixed deny response.'
    Assert-Test ($Run.detail.decision -ceq 'DENY' -and $Run.detail.reason_code -ceq $Reason) `
        ('Expected a deny with reason ' + $Reason + '.')
    Assert-Test ($Run.notices.Count -eq 1 -and $Run.notices[0].reason_code -ceq $Reason -and
        $Run.notices[0].decision -ceq 'DENY') 'The deny was not noted.'
    Assert-Test ($Run.exit_code -eq 0) 'The hook exit code was not 0.'
}

try {
    if (-not $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $testRoot) -notlike ($testRootPrefix + '*')) {
        throw 'Refusing to create the test root outside the resolved temporary directory.'
    }
    [void](New-Item -ItemType Directory -Path $testRoot -ErrorAction Stop)
    Import-Module $controlManifest -Force -ErrorAction Stop

    Invoke-HookCase -Name 'absent_setting_steps_aside' -Body {
        $case = Initialize-CaseControl -ConfigText $null
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_LOCK_TIMEOUT'
        Assert-StepsAside -Run $run -HookStatus 'NOT_ENFORCED'
        Assert-Test ($run.detail.setting_status -ceq 'CONFIG_ABSENT') 'The absent setting was not reported.'
        @{ setting_status = $run.detail.setting_status }
    }

    Invoke-HookCase -Name 'kill_switch_steps_aside' -Body {
        $case = Initialize-CaseControl -KillSwitch
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_LOCK_TIMEOUT'
        Assert-StepsAside -Run $run -HookStatus 'NOT_ENFORCED'
        Assert-Test ($run.detail.setting_status -ceq 'KILL_SWITCH_ACTIVE') 'The kill switch was not reported.'
        @{ setting_status = $run.detail.setting_status }
    }

    Invoke-HookCase -Name 'monitor_setting_steps_aside' -Body {
        $case = Initialize-CaseControl -ConfigText '{"schema_version":1,"mode":"MONITOR","routes":["claude-code:PreToolUse:Bash"]}'
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_LOCK_TIMEOUT'
        Assert-StepsAside -Run $run -HookStatus 'NOT_ENFORCED'
        @{ requested_mode = $run.detail.requested_mode }
    }

    Invoke-HookCase -Name 'unlisted_route_steps_aside' -Body {
        $case = Initialize-CaseControl
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson -ToolName 'PowerShell') -Outcome 'TEST_LOCK_TIMEOUT'
        Assert-StepsAside -Run $run -HookStatus 'NOT_ENFORCED'
        Assert-Test ($run.detail.route_id -ceq 'claude-code:PreToolUse:PowerShell') 'The route id is wrong.'
        @{ route_id = $run.detail.route_id }
    }

    Invoke-HookCase -Name 'unroutable_event_steps_aside' -Body {
        $case = Initialize-CaseControl
        $statuses = New-Object System.Collections.Generic.List[string]
        # An empty string is left out on purpose: the hook would then read
        # standard input, which belongs to the test runner here.
        foreach ($eventText in @('not json', '[]', '{"tool_name":"Bash tool"}', '{"tool_name":7}', '{}')) {
            $run = Invoke-EnforcementHook -Case $case -EventJson $eventText -Outcome 'TEST_LOCK_TIMEOUT'
            Assert-Test ($run.output.Count -eq 0) 'An unroutable event produced output.'
            Assert-Test ($run.detail.hook_status -ceq 'NO_ROUTE' -or $run.detail.hook_status -ceq 'NOT_ENFORCED') `
                'An unroutable event was enforced.'
            Assert-Test ($run.notices.Count -eq 0) 'An unroutable event wrote a notice.'
            $statuses.Add([string]$run.detail.hook_status)
        }
        @{ statuses = $statuses.ToArray() }
    }

    Invoke-HookCase -Name 'confirmed_recording_allows_silently' -Body {
        $case = Initialize-CaseControl
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_RECORDED'
        Assert-Test ($run.output.Count -eq 0) 'A confirmed recording produced host output.'
        Assert-Test ($run.detail.hook_status -ceq 'ENFORCED') 'The listed route was not enforced.'
        Assert-Test ($run.detail.decision -ceq 'ALLOW' -and $run.detail.reason_code -ceq 'RECORDING_CONFIRMED') `
            'A confirmed recording was not allowed.'
        Assert-Test ($run.notices.Count -eq 0) 'A confirmed recording wrote a notice.'
        @{ reason_code = $run.detail.reason_code }
    }

    $denyCases = @(
        [pscustomobject]@{ name = 'lock_timeout_denies'; outcome = 'TEST_LOCK_TIMEOUT'; reason = 'LOCK_TIMEOUT'; hint = 'RETRY_LATER' },
        [pscustomobject]@{ name = 'capacity_denies_with_cleanup_hint'; outcome = 'TEST_CAPACITY'; reason = 'STORE_CAPACITY_REACHED'; hint = 'RUN_RETENTION_CLEANUP' },
        [pscustomobject]@{ name = 'invalid_store_denies'; outcome = 'TEST_STORE_INVALID'; reason = 'STORE_VALIDATION_FAILED'; hint = 'CHECK_STORE_ACL' },
        [pscustomobject]@{ name = 'metadata_only_denies'; outcome = 'TEST_METADATA_ONLY'; reason = 'BODY_NOT_CAPTURED'; hint = $null },
        [pscustomobject]@{ name = 'adapter_exception_denies'; outcome = 'TEST_THROW'; reason = 'RECORDING_NOT_VERIFIED'; hint = $null }
    )
    # The case body runs synchronously inside this loop, so it reads the
    # current $current through ordinary scoping; no closure is needed.
    foreach ($denyCase in $denyCases) {
        $current = $denyCase
        Invoke-HookCase -Name $current.name -Body {
            $case = Initialize-CaseControl
            $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome $current.outcome
            Assert-Denied -Run $run -Reason $current.reason
            Assert-Test ($run.notices[0].action_hint -ceq $current.hint) 'The notice carried the wrong action hint.'
            Assert-Test ($run.notices[0].execution_id -ceq $run.detail.execution_id) `
                'The notice did not carry the execution id.'
            @{ reason_code = $run.detail.reason_code; notice_status = $run.detail.notice_status }
        }
    }

    Invoke-HookCase -Name 'invalid_event_on_enforced_route_fails_open_with_notice' -Body {
        $case = Initialize-CaseControl
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson -OmitCommand) -Outcome 'TEST_LOCK_TIMEOUT'
        Assert-Test ($run.output.Count -eq 0) 'An unreadable event was denied.'
        Assert-Test ($run.detail.decision -ceq 'ALLOW' -and $run.detail.reason_code -ceq 'INVALID_HOOK_INPUT_NOT_ENFORCED') `
            'An unreadable event did not follow the documented fail-open.'
        Assert-Test ($run.detail.intent_status -ceq 'NOT_ATTEMPTED') 'An unreadable event was recorded.'
        Assert-Test ($run.notices.Count -eq 1 -and $run.notices[0].decision -ceq 'ALLOW' -and
            $run.notices[0].reason_code -ceq 'INVALID_HOOK_INPUT_NOT_ENFORCED') 'The fail-open was not noted.'
        @{ reason_code = $run.detail.reason_code }
    }

    Invoke-HookCase -Name 'internal_error_fails_open_with_notice' -Body {
        $case = Initialize-CaseControl
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_LOCK_TIMEOUT' -ForceInternalError
        Assert-Test ($run.output.Count -eq 0) 'An internal error produced host output.'
        Assert-Test ($run.exit_code -eq 0) 'An internal error changed the exit code.'
        Assert-Test ($run.detail.hook_status -ceq 'HOOK_INTERNAL_ERROR') 'The internal error was not reported.'
        Assert-Test ($run.notices.Count -eq 1 -and $run.notices[0].reason_code -ceq 'HOOK_INTERNAL_ERROR' -and
            $run.notices[0].decision -ceq 'ALLOW') 'The internal error was not noted.'
        @{ hook_status = $run.detail.hook_status }
    }

    Invoke-HookCase -Name 'notice_failure_does_not_change_deny' -Body {
        $case = Initialize-CaseControl
        $stream = [System.IO.File]::Open((Join-Path $case.control 'enforcement-notices.ndjson'), [System.IO.FileMode]::CreateNew)
        try { $stream.SetLength(1MB) } finally { $stream.Dispose() }
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_LOCK_TIMEOUT'
        Assert-Test ($run.output.Count -eq 1 -and [string]$run.output[0] -ceq $golden) `
            'A failed notice changed the deny.'
        Assert-Test ($run.detail.notice_status -ceq 'NOTICE_NOT_PERSISTED' -and
            $run.detail.notice_failure_code -ceq 'NOTICE_FILE_FULL') 'The notice failure was not reported.'
        @{ notice_failure_code = $run.detail.notice_failure_code }
    }

    Invoke-HookCase -Name 'kill_switch_takes_effect_on_next_call' -Body {
        $case = Initialize-CaseControl
        $first = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_LOCK_TIMEOUT'
        $killPath = Join-Path $case.control 'ENFORCEMENT_OFF'
        [System.IO.File]::WriteAllText($killPath, '', $utf8)
        $second = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson -ToolUseId 'toolu_test_2') -Outcome 'TEST_LOCK_TIMEOUT'
        Remove-Item -LiteralPath $killPath
        $third = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson -ToolUseId 'toolu_test_3') -Outcome 'TEST_LOCK_TIMEOUT'
        Assert-Test ($first.output.Count -eq 1) 'The first call was not denied.'
        Assert-Test ($second.output.Count -eq 0 -and $second.detail.setting_status -ceq 'KILL_SWITCH_ACTIVE') `
            'The kill switch did not stop enforcement on the next call.'
        Assert-Test ($third.output.Count -eq 1) 'Removing the kill switch did not restore enforcement.'
        @{ first = $first.detail.hook_status; second = $second.detail.hook_status; third = $third.detail.hook_status }
    }

    Invoke-HookCase -Name 'command_text_never_leaves_the_hook' -Body {
        $case = Initialize-CaseControl
        $command = 'echo ' + $canary
        $run = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson -Command $command) -Outcome 'TEST_CAPACITY'
        $resultText = [System.IO.File]::ReadAllText((Join-Path $case.root 'result.json'))
        $noticeText = [System.IO.File]::ReadAllText((Join-Path $case.control 'enforcement-notices.ndjson'))
        Assert-Test (-not ([string]$run.output[0]).Contains($canary)) 'The host response carried the command.'
        Assert-Test (-not $resultText.Contains($canary)) 'The result file carried the command.'
        Assert-Test (-not $noticeText.Contains($canary)) 'The notice carried the command.'
        Assert-Test (-not $noticeText.Contains('synthetic')) 'The notice carried event paths.'
        @{ canary_absent = $true }
    }

    Invoke-HookCase -Name 'execution_id_is_stable_and_separate_from_monitor' -Body {
        $case = Initialize-CaseControl
        $a = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_RECORDED'
        $b = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson) -Outcome 'TEST_RECORDED'
        $c = Invoke-EnforcementHook -Case $case -EventJson (Get-EventJson -ToolUseId 'toolu_other') -Outcome 'TEST_RECORDED'
        $material = 'CLAUDE_PRETOOLUSE_HOOK|12:session_test|12:toolu_test_1'
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $monitorId = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($material)))).Replace('-', '').ToLowerInvariant().Substring(0, 32)
        }
        finally {
            $sha.Dispose()
        }
        Assert-Test ([string]$a.detail.execution_id -cmatch '^[0-9a-f]{32}$') 'The execution id is not 32 hex characters.'
        Assert-Test ($a.detail.execution_id -ceq $b.detail.execution_id) 'The execution id is not stable.'
        Assert-Test ($a.detail.execution_id -cne $c.detail.execution_id) 'Different tool calls share an execution id.'
        Assert-Test ($a.detail.execution_id -cne $monitorId) 'The id collides with the MONITOR hook id.'
        @{ stable = $true; separate_from_monitor = $true }
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
        message = 'One or more enforcement hook cases failed.'
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
    host_invoked = $false
    adapter_invoked = $false
    test_root_cleaned = -not (Test-Path -LiteralPath $testRoot)
}
$summary | ConvertTo-Json -Depth 8
if ($null -ne $failure) {
    exit 1
}
