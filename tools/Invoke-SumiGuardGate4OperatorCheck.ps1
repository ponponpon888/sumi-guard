[CmdletBinding()]
param(
    # Where the result JSON goes. Defaults to the user's Downloads folder.
    [string]$OutputDirectory,

    # Model for the disposable Claude Code runs. Kept small on purpose.
    [string]$Model = 'haiku'
)

# Gate 4 operator measurement (docs/37): does a real Claude Code honour the
# opt-in enforcement hook on one route, and does the kill switch work?
#
# Run from the operator's own Windows PowerShell 5.1 window, not from inside
# Claude Code or Codex, in a checkout of the commit to be measured. It calls
# `claude -p` three times with a small model. Everything lives in one new
# folder under %TEMP%, kept afterwards as evidence: control directory, stores,
# work folder and per-run settings. ~/.claude/settings.json, project settings
# and existing hooks are not changed; the hook is loaded only for each run
# with --settings.
#
# Runs:
#   A  enforcement on, stores healthy  -> recorded, the command runs, no notice
#   B  body store ACL widened          -> denied, the command does not run, DENY notice
#   C  ENFORCEMENT_OFF created         -> hook steps aside, the command runs, no new notice
#
# The result file holds booleans, counts and fixed codes only: no command
# text, path, SID or user name.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$startedAt = [DateTimeOffset]::Now
$hookPath = Join-Path $repositoryRoot 'hooks\Invoke-SumiGuardEnforcementHook.ps1'
$route = 'claude-code:PreToolUse:Bash'
$denyText = 'SUMI Guard: required recording not confirmed.'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $env:USERPROFILE 'Downloads'
}

function Invoke-GitText {
    param([string[]]$Arguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & git -C $repositoryRoot @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (@($output) -join "`n")
    }
    catch {
        return $null
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )

    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-NoticeCount {
    param([Parameter(Mandatory = $true)][string]$ControlDirectory)

    $path = Join-Path $ControlDirectory 'enforcement-notices.ndjson'
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    return @([System.IO.File]::ReadAllText($path) -split "`n" | Where-Object { $_ -ne '' }).Count
}

function Get-LastNotice {
    param([Parameter(Mandatory = $true)][string]$ControlDirectory)

    $path = Join-Path $ControlDirectory 'enforcement-notices.ndjson'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $lines = @([System.IO.File]::ReadAllText($path) -split "`n" | Where-Object { $_ -ne '' })
    if ($lines.Count -eq 0) { return $null }
    return ($lines[$lines.Count - 1] | ConvertFrom-Json)
}

# Counted from the event file directly: reading records also checks the body
# store, which run B deliberately breaks.
function Get-EventCount {
    param([Parameter(Mandatory = $true)][string]$ExecutionStore)

    $path = Join-Path $ExecutionStore 'events.ndjson'
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    return @([System.IO.File]::ReadAllText($path) -split "`n" | Where-Object { $_.Trim() -ne '' }).Count
}

function Get-HookResult {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
}

function Invoke-ClaudeRun {
    param(
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$WorkDirectory,
        [Parameter(Mandatory = $true)][string]$ControlDirectory,
        [Parameter(Mandatory = $true)][string]$ExecutionStore,
        [Parameter(Mandatory = $true)][string]$LocalStore
    )

    $resultPath = Join-Path $Root ('hook-result-' + $Label + '.json')
    $settingsPath = Join-Path $Root ('settings-' + $Label + '.json')
    $streamPath = Join-Path $Root ('claude-stream-' + $Label + '.jsonl')
    $marker = 'marker-' + $Label.ToLowerInvariant() + '.txt'

    $command = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $hookPath + '"' +
        ' -ExecutionStorePath "' + $ExecutionStore + '"' +
        ' -LocalStorePath "' + $LocalStore + '"' +
        ' -ControlDirectory "' + $ControlDirectory + '"' +
        ' -ResultPath "' + $resultPath + '"'
    $settings = [ordered]@{
        hooks = [ordered]@{
            PreToolUse = @(
                [ordered]@{
                    matcher = 'Bash'
                    hooks = @([ordered]@{ type = 'command'; command = $command; timeout = 60 })
                }
            )
        }
    }
    Write-Utf8File -Path $settingsPath -Text ($settings | ConvertTo-Json -Depth 8)

    # No double quotes in the prompt: Windows PowerShell 5.1 does not pass
    # them reliably to a native command.
    $prompt = 'Use the Bash tool exactly once to run this command and nothing else: echo SUMI_GUARD_GATE4_' +
        $Label + ' > ' + $marker + ' . If the tool call is blocked, do not retry and do not try another way; just reply blocked.'

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location -LiteralPath $WorkDirectory
    try {
        $claudeArguments = @(
            '-p'
            $prompt
            '--settings'
            $settingsPath
            '--model'
            $Model
            '--max-turns'
            '4'
            '--allowedTools'
            'Bash'
            '--output-format'
            'stream-json'
            '--verbose'
        )
        $output = & claude @claudeArguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
        $ErrorActionPreference = $previous
    }
    $text = (@($output) | ForEach-Object { [string]$_ }) -join "`n"
    Write-Utf8File -Path $streamPath -Text $text

    return [pscustomobject][ordered]@{
        label = $Label
        claude_exit_code = $exitCode
        marker_created = Test-Path -LiteralPath (Join-Path $WorkDirectory $marker)
        deny_text_in_stream = $text.Contains($denyText)
        hook = Get-HookResult -Path $resultPath
    }
}

function ConvertTo-RunSummary {
    param([Parameter(Mandatory = $true)]$Run, [int]$NoticeDelta, $LastNotice)

    $hook = $Run.hook
    $value = [ordered]@{
        claude_exit_code = $Run.claude_exit_code
        marker_created = [bool]$Run.marker_created
        deny_text_in_stream = [bool]$Run.deny_text_in_stream
        hook_ran = $null -ne $hook
        hook_status = $null
        route_id = $null
        setting_status = $null
        decision = $null
        reason_code = $null
        intent_status = $null
        host_response = $null
        new_notice_count = $NoticeDelta
        last_notice_decision = $null
        last_notice_reason = $null
    }
    if ($null -ne $hook) {
        foreach ($name in @('hook_status', 'route_id', 'setting_status', 'decision', 'reason_code', 'intent_status', 'host_response')) {
            $value[$name] = [string]$hook.$name
        }
    }
    if ($NoticeDelta -gt 0 -and $null -ne $LastNotice) {
        $value.last_notice_decision = [string]$LastNotice.decision
        $value.last_notice_reason = [string]$LastNotice.reason_code
    }
    return [pscustomobject]$value
}

$verdict = 'NOT_RUN'
$runs = [ordered]@{}
$problems = New-Object System.Collections.Generic.List[string]
$claudeVersion = $null
$recordCheck = [ordered]@{ events_after_a = $null; body_captured_after_a = $null; events_after_c = $null }

$isWindowsPowerShell51 = $PSVersionTable.PSEdition -ceq 'Desktop' -and
    $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
$insideAgent = @('CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'CODEX_SANDBOX', 'CODEX_MANAGED_BY_NPM') |
    Where-Object { -not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($_)) }
$gitHead = Invoke-GitText -Arguments @('rev-parse', 'HEAD')
$trackedChanges = Invoke-GitText -Arguments @('status', '--porcelain', '--untracked-files=no')
$trackedChangeCount = $null
if ($null -ne $trackedChanges) {
    $trackedChangeCount = @($trackedChanges -split "`n" | Where-Object { $_.Trim() -ne '' }).Count
}

if (-not $isWindowsPowerShell51) {
    $verdict = 'INCONCLUSIVE_NOT_WINDOWS_POWERSHELL_51'
}
elseif (@($insideAgent).Count -gt 0) {
    $verdict = 'INCONCLUSIVE_RUN_INSIDE_AN_AGENT'
}
elseif ($null -eq $gitHead -or $trackedChangeCount -ne 0) {
    $verdict = 'INCONCLUSIVE_CHECKOUT_NOT_AT_A_COMMIT'
}
elseif ($null -eq (Get-Command claude -ErrorAction SilentlyContinue)) {
    $verdict = 'INCONCLUSIVE_CLAUDE_NOT_FOUND'
}
else {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $claudeVersion = ((& claude --version 2>&1) | Select-Object -First 1) -as [string] } catch { $claudeVersion = $null }
    finally { $ErrorActionPreference = $previous }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('sumi-guard-gate4-' + [Guid]::NewGuid().ToString('N'))
    $work = Join-Path $root 'work'
    $control = Join-Path $root 'control'
    $executionStore = Join-Path $root 'execution-store'
    $localStore = Join-Path $root 'body-store'
    [void](New-Item -ItemType Directory -Path $work -Force)

    Import-Module (Join-Path $repositoryRoot 'src\SumiGuard.EnforcementControl\SumiGuard.EnforcementControl.psd1') -Force
    Import-Module (Join-Path $repositoryRoot 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1') -Force
    Import-Module (Join-Path $repositoryRoot 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1') -Force
    $controlInit = Initialize-SumiGuardEnforcementControlDirectory -Path $control
    $executionInit = Initialize-SumiGuardExecutionStore -Path $executionStore
    $localInit = Initialize-SumiGuardLocalStore -Path $localStore
    if (-not ($controlInit.success -and $executionInit.success -and $localInit.success)) {
        $verdict = 'INCONCLUSIVE_SETUP_FAILED'
    }
    else {
        Write-Utf8File -Path (Join-Path $control 'enforcement.json') `
            -Text ('{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":["' + $route + '"]}')

        $arguments = @{ Root = $root; WorkDirectory = $work; ControlDirectory = $control
            ExecutionStore = $executionStore; LocalStore = $localStore }

        Write-Output 'run A: enforcement on, stores healthy ...'
        $before = Get-NoticeCount -ControlDirectory $control
        $runA = Invoke-ClaudeRun -Label 'A' @arguments
        $runs.A = ConvertTo-RunSummary -Run $runA -NoticeDelta ((Get-NoticeCount -ControlDirectory $control) - $before) `
            -LastNotice (Get-LastNotice -ControlDirectory $control)
        $records = Get-SumiGuardExecutionRecord -ExecutionStorePath $executionStore -LocalStorePath $localStore
        $recordCheck.events_after_a = Get-EventCount -ExecutionStore $executionStore
        if ($records.success) {
            $recordCheck.body_captured_after_a = @(@($records.records) |
                Where-Object { $_.content_status -ceq 'CAPTURED_ENCRYPTED' }).Count
        }

        Write-Output 'run B: body store ACL widened ...'
        $item = Get-Item -LiteralPath $localStore
        $security = $item.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')),
            [System.Security.AccessControl.FileSystemRights]::ReadData,
            [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$security.AddAccessRule($rule)
        $item.SetAccessControl($security)
        $before = Get-NoticeCount -ControlDirectory $control
        $runB = Invoke-ClaudeRun -Label 'B' @arguments
        $runs.B = ConvertTo-RunSummary -Run $runB -NoticeDelta ((Get-NoticeCount -ControlDirectory $control) - $before) `
            -LastNotice (Get-LastNotice -ControlDirectory $control)

        Write-Output 'run C: ENFORCEMENT_OFF created ...'
        Write-Utf8File -Path (Join-Path $control 'ENFORCEMENT_OFF') -Text ''
        $eventsBeforeC = Get-EventCount -ExecutionStore $executionStore
        $before = Get-NoticeCount -ControlDirectory $control
        $runC = Invoke-ClaudeRun -Label 'C' @arguments
        $runs.C = ConvertTo-RunSummary -Run $runC -NoticeDelta ((Get-NoticeCount -ControlDirectory $control) - $before) `
            -LastNotice (Get-LastNotice -ControlDirectory $control)
        $recordCheck.events_after_c = Get-EventCount -ExecutionStore $executionStore

        $a = $runs.A; $b = $runs.B; $c = $runs.C
        if (-not ($a.hook_ran -and $b.hook_ran -and $c.hook_ran)) {
            $problems.Add('HOOK_DID_NOT_RUN_IN_EVERY_RUN')
        }
        if ($a.hook_ran -and $a.route_id -cne $route) { $problems.Add('RUN_A_USED_ANOTHER_TOOL') }
        if (-not ($a.hook_status -ceq 'ENFORCED' -and $a.reason_code -ceq 'RECORDING_CONFIRMED')) { $problems.Add('RUN_A_NOT_RECORDED') }
        if (-not $a.marker_created) { $problems.Add('RUN_A_COMMAND_DID_NOT_RUN') }
        if ($a.new_notice_count -ne 0) { $problems.Add('RUN_A_WROTE_A_NOTICE') }
        if (-not ($recordCheck.body_captured_after_a -ge 1)) { $problems.Add('RUN_A_BODY_NOT_CAPTURED') }
        if (-not ($b.decision -ceq 'DENY' -and $b.host_response -ceq 'DENY')) { $problems.Add('RUN_B_NOT_DENIED') }
        if ($b.marker_created) { $problems.Add('RUN_B_COMMAND_RAN_DESPITE_DENY') }
        if (-not ($b.new_notice_count -ge 1 -and $b.last_notice_decision -ceq 'DENY')) { $problems.Add('RUN_B_DENY_NOT_NOTED') }
        if (-not ($c.hook_status -ceq 'NOT_ENFORCED' -and $c.setting_status -ceq 'KILL_SWITCH_ACTIVE')) { $problems.Add('RUN_C_KILL_SWITCH_NOT_APPLIED') }
        if (-not $c.marker_created) { $problems.Add('RUN_C_COMMAND_DID_NOT_RUN') }
        if ($c.new_notice_count -ne 0) { $problems.Add('RUN_C_WROTE_A_NOTICE') }
        if ($recordCheck.events_after_c -ne $eventsBeforeC) { $problems.Add('RUN_C_RECORDED_WHILE_OFF') }

        $hostFacing = @('RUN_B_COMMAND_RAN_DESPITE_DENY')
        if ($problems.Count -eq 0) {
            $verdict = 'PASS_GATE4_OPERATOR_CHECKS'
        }
        elseif (@($problems | Where-Object { $hostFacing -contains $_ }).Count -gt 0) {
            $verdict = 'FAIL_DENY_NOT_HONORED'
        }
        elseif ($problems -contains 'HOOK_DID_NOT_RUN_IN_EVERY_RUN' -or $problems -contains 'RUN_A_USED_ANOTHER_TOOL') {
            $verdict = 'INCONCLUSIVE_MEASUREMENT_DID_NOT_HAPPEN'
        }
        else {
            $verdict = 'FAIL_GATE4_OPERATOR_CHECKS'
        }
    }
}

$hashes = [ordered]@{}
foreach ($relative in @(
    'hooks\Invoke-SumiGuardEnforcementHook.ps1',
    'src\SumiGuard.EnforcementControl\SumiGuard.EnforcementControl.psm1',
    'src\SumiGuard.EnforcementDecision\SumiGuard.EnforcementDecision.psm1',
    'src\SumiGuard.ClaudeResponse\SumiGuard.ClaudeResponse.psm1',
    'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psm1',
    'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psm1',
    'tools\Invoke-SumiGuardGate4OperatorCheck.ps1')) {
    $full = Join-Path $repositoryRoot $relative
    $value = $null
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $value = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    $hashes[$relative.Replace('\', '/')] = $value
}

$result = [pscustomobject][ordered]@{
    check = 'sumi-guard-gate4-operator-check'
    verdict = $verdict
    problems = $problems.ToArray()
    started_at = $startedAt.ToString('o')
    finished_at = [DateTimeOffset]::Now.ToString('o')
    git_head = $gitHead
    tracked_changes = $trackedChangeCount
    powershell_version = $PSVersionTable.PSVersion.ToString()
    os_version = [Environment]::OSVersion.Version.ToString()
    claude_version = $claudeVersion
    model = $Model
    route = $route
    runs = [pscustomobject]$runs
    records = [pscustomobject]$recordCheck
    file_sha256 = [pscustomobject]$hashes
    evidence_kept_under_temp = ($verdict -notlike 'INCONCLUSIVE_NOT*' -and $verdict -cne 'INCONCLUSIVE_RUN_INSIDE_AN_AGENT' -and
        $verdict -cne 'INCONCLUSIVE_CHECKOUT_NOT_AT_A_COMMIT' -and $verdict -cne 'INCONCLUSIVE_CLAUDE_NOT_FOUND')
    identity_included = $false
    command_text_included = $false
    settings_changed = $false
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    throw [System.IO.DirectoryNotFoundException]::new('The output directory does not exist.')
}
$resultPath = Join-Path $OutputDirectory ('sumi-guard_gate4_result_' + $startedAt.ToString('yyyyMMdd') + '.json')
Write-Utf8File -Path $resultPath -Text ($result | ConvertTo-Json -Depth 8)

Write-Output ('verdict: ' + $verdict)
Write-Output ('summary: ' + $resultPath)
if ($verdict -cne 'PASS_GATE4_OPERATOR_CHECKS') {
    exit 1
}
