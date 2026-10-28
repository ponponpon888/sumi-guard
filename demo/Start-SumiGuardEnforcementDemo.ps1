<#
    SUMI Guard enforcement demo: six scenes, no Claude, no Codex, no API cost.

    It feeds Claude Code shaped PreToolUse events to the real enforcement hook
    (hooks/Invoke-SumiGuardEnforcementHook.ps1) through standard input, as a
    separate Windows PowerShell 5.1 process, and shows what the hook answers,
    records and notes:

      1  no setting                         -> steps aside
      2  Bash enforced, stores healthy      -> recorded, allowed
      3  body store ACL widened             -> denied, noted
      4  same, but the PowerShell tool      -> not enforced (Bash only)
      5  ENFORCEMENT_OFF created            -> steps aside
      6  ENFORCEMENT_OFF removed            -> denied again

    Whether a host honours the deny is not shown here; gates 2 and 4 measured
    that (measurements/2026-10-23 and 2026-10-28). Everything lives in one new
    folder under %TEMP%, removed at the end unless -KeepEvidence is given. No
    Claude Code setting, existing hook or operational store is touched.

    -AdapterMode SYNTHETIC is for CI: the hook's test seam stands in for the
    DPAPI-protected body store, and the stores are plain folders.

    Exit code: 0 when every scene matched, 1 when one did not, 2 when the demo
    could not start.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingWriteHost',
    '',
    Justification = 'A demo screen for a person to read. Standard output carries nothing, so the colored host output is the whole interface.')]
param(
    [ValidateRange(0, 10)][int]$PauseSeconds = 3,
    [switch]$Interactive,
    # Writes the screen as an asciicast v2 file, for the README GIF.
    [string]$CastPath,
    # Writes a machine-readable result for tests.
    [string]$ResultPath,
    [switch]$KeepEvidence,
    [ValidateSet('ADAPTER', 'SYNTHETIC')][string]$AdapterMode = 'ADAPTER'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:RepositoryRoot = Split-Path -Path $PSScriptRoot -Parent
$script:PauseSeconds = $PauseSeconds
$script:Interactive = $Interactive
$script:CastPath = $CastPath
$script:ResultPath = $ResultPath
$script:HookPath = Join-Path -Path $script:RepositoryRoot -ChildPath 'hooks\Invoke-SumiGuardEnforcementHook.ps1'
$script:PowerShell51 = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:Utf8 = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$script:DenyJson = '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"SUMI Guard: required recording not confirmed."}}'
$script:Route = 'claude-code:PreToolUse:Bash'
$script:TempPrefix = 'sumi-guard-enforcement-demo-'
$script:Clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:CastLines = New-Object -TypeName System.Collections.Generic.List[string]
$script:AnsiCodes = @{
    Green = '32'; Red = '31'; Yellow = '33'; Cyan = '36'; DarkGray = '90'; White = '0'
}

function Write-DemoLine {
    param(
        [AllowEmptyString()][string]$Text = '',
        [ValidateSet('Green', 'Red', 'Yellow', 'Cyan', 'DarkGray', 'White')][string]$Color = 'White'
    )

    Write-Host -Object $Text -ForegroundColor $Color
    if (-not [string]::IsNullOrWhiteSpace($script:CastPath)) {
        $seconds = [Math]::Round($script:Clock.Elapsed.TotalSeconds, 3)
        $escape = [string][char]27
        $painted = $Text
        if ($Color -cne 'White' -and $Text.Length -gt 0) {
            $painted = $escape + '[' + $script:AnsiCodes[$Color] + 'm' + $Text + $escape + '[0m'
        }
        $frame = ConvertTo-Json -InputObject @($seconds, 'o', ($painted + "`r`n")) -Compress
        $script:CastLines.Add($frame)
    }
}

function Wait-DemoScene {
    if ($script:Interactive) {
        [void](Read-Host -Prompt 'Enter で次へ')
    }
    elseif ($script:PauseSeconds -gt 0) {
        Start-Sleep -Seconds $script:PauseSeconds
    }
}

function Get-QuotedArgument {
    param([Parameter(Mandatory = $true)][string]$Value)

    return ('"' + $Value + '"')
}

function Get-NonEmptyLine {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @([System.IO.File]::ReadAllText($Path, $script:Utf8) -split "`n" | Where-Object { $_.Trim() -ne '' })
}

# Counted from the files directly: reading records through the adapter also
# checks the body store, which scene 3 deliberately breaks.
function Get-DemoCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    return @(Get-NonEmptyLine -Path $Path).Count
}

function Get-CapturedEventCount {
    param([Parameter(Mandatory = $true)][string]$Path)

    $count = 0
    foreach ($line in @(Get-NonEmptyLine -Path $Path)) {
        $record = $null
        try { $record = $line | ConvertFrom-Json } catch { $record = $null }
        if ($null -ne $record -and
            @($record.PSObject.Properties | ForEach-Object { $_.Name }) -ccontains 'content_status' -and
            [string]$record.content_status -ceq 'CAPTURED_ENCRYPTED') {
            $count++
        }
    }
    return $count
}

function Get-LastNotice {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = @(Get-NonEmptyLine -Path $Path)
    if ($lines.Count -eq 0) { return $null }
    try { return ($lines[$lines.Count - 1] | ConvertFrom-Json) } catch { return $null }
}

function Get-DemoField {
    param($Object, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Object) { return $null }
    if (@($Object.PSObject.Properties | ForEach-Object { $_.Name }) -cnotcontains $Name) { return $null }
    return $Object.$Name
}

function Get-DemoEventJson {
    param(
        [Parameter(Mandatory = $true)][int]$Scene,
        [Parameter(Mandatory = $true)][string]$ToolName
    )

    return ([ordered]@{
        hook_event_name = 'PreToolUse'
        session_id = 'sumi-guard-demo-session'
        tool_use_id = ('sumi-guard-demo-' + $Scene)
        tool_name = $ToolName
        tool_input = [ordered]@{ command = ('echo SUMI_GUARD_DEMO_' + $Scene) }
    } | ConvertTo-Json -Compress -Depth 4)
}

# Runs the hook as Claude Code does: a separate process, the event as raw
# UTF-8 bytes on standard input, the answer on standard output.
function Invoke-DemoHook {
    param(
        [Parameter(Mandatory = $true)][int]$Scene,
        [Parameter(Mandatory = $true)][string]$ToolName,
        [Parameter(Mandatory = $true)][string]$Outcome
    )

    $hookResultPath = Join-Path -Path $script:WorkRoot -ChildPath ('hook-result-' + $Scene + '.json')
    $argumentText = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ' + (Get-QuotedArgument -Value $script:HookPath) +
        ' -ExecutionStorePath ' + (Get-QuotedArgument -Value $script:ExecutionStore) +
        ' -LocalStorePath ' + (Get-QuotedArgument -Value $script:BodyStore) +
        ' -ControlDirectory ' + (Get-QuotedArgument -Value $script:ControlDirectory) +
        ' -ResultPath ' + (Get-QuotedArgument -Value $hookResultPath)
    if ($Outcome -cne 'ADAPTER') {
        $argumentText = $argumentText + ' -TestIntentSaveOutcome ' + $Outcome
    }

    $startInfo = New-Object -TypeName System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $script:PowerShell51
    $startInfo.Arguments = $argumentText
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $script:Utf8
    $startInfo.StandardErrorEncoding = $script:Utf8

    $timedOut = $false
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        [byte[]]$bytes = $script:Utf8.GetBytes((Get-DemoEventJson -Scene $Scene -ToolName $ToolName))
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $timedOut = $true
            try { $process.Kill() } catch { $timedOut = $true }
        }
        else {
            $process.WaitForExit()
        }
        $standardOutput = ''
        $standardError = ''
        if (-not $timedOut) {
            $standardOutput = [string]$outputTask.Result
            $standardError = [string]$errorTask.Result
        }
    }
    finally {
        $process.Dispose()
    }

    $hookResult = $null
    if (Test-Path -LiteralPath $hookResultPath -PathType Leaf) {
        try { $hookResult = [System.IO.File]::ReadAllText($hookResultPath) | ConvertFrom-Json } catch { $hookResult = $null }
    }

    $trimmed = $standardOutput.Trim()
    $kind = 'OTHER'
    if ($trimmed.Length -eq 0) { $kind = 'EMPTY' }
    elseif ($trimmed -ceq $script:DenyJson) { $kind = 'DENY_JSON' }

    return [pscustomobject][ordered]@{
        hook_ran = $null -ne $hookResult
        hook = $hookResult
        stdout_text = $trimmed
        stdout_kind = $kind
        stderr_nonempty = $standardError.Trim().Length -gt 0
        timed_out = $timedOut
    }
}

# Scene 3: the same change gate 4's run B made. LocalStore refuses a store
# whose ACL lets anyone else read it.
function Grant-DemoBodyStoreWideRead {
    $item = Get-Item -LiteralPath $script:BodyStore
    $security = $item.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    $everyone = New-Object -TypeName System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-1-0'
    $rule = New-Object -TypeName System.Security.AccessControl.FileSystemAccessRule -ArgumentList @(
        $everyone,
        [System.Security.AccessControl.FileSystemRights]::ReadData,
        [System.Security.AccessControl.AccessControlType]::Allow)
    [void]$security.AddAccessRule($rule)
    $item.SetAccessControl($security)
}

function Write-DemoResultFile {
    param([Parameter(Mandatory = $true)]$Result)

    if ([string]::IsNullOrWhiteSpace($script:ResultPath)) { return }
    [System.IO.File]::WriteAllText($script:ResultPath, ($Result | ConvertTo-Json -Depth 6), $script:Utf8)
}

function Write-DemoCastFile {
    if ([string]::IsNullOrWhiteSpace($script:CastPath)) { return }
    $header = [ordered]@{
        version = 2
        width = 100
        height = 32
        timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        title = 'SUMI Guard enforcement demo'
    } | ConvertTo-Json -Compress
    $all = New-Object -TypeName System.Collections.Generic.List[string]
    $all.Add($header)
    $all.AddRange($script:CastLines)
    [System.IO.File]::WriteAllText($script:CastPath, (($all.ToArray() -join "`n") + "`n"), $script:Utf8)
}

$cases = New-Object -TypeName System.Collections.Generic.List[object]
$setupFailure = $null
$failureStage = $null
$failureExceptionType = $null
$tempRemoved = $false
$script:WorkRoot = $null

$isWindowsPowerShell51 = $PSVersionTable.PSEdition -ceq 'Desktop' -and
    $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1
if (-not $isWindowsPowerShell51) {
    $setupFailure = 'NOT_WINDOWS_POWERSHELL_51'
}
elseif (-not (Test-Path -LiteralPath $script:HookPath -PathType Leaf)) {
    $setupFailure = 'HOOK_NOT_FOUND'
}
elseif (-not (Test-Path -LiteralPath $script:PowerShell51 -PathType Leaf)) {
    $setupFailure = 'POWERSHELL_51_NOT_FOUND'
}

if ($null -ne $setupFailure) {
    Write-DemoLine -Text ('デモを始められません: ' + $setupFailure) -Color Red
    Write-DemoResultFile -Result ([pscustomobject][ordered]@{
        demo = 'sumi-guard-enforcement-demo'; adapter_mode = $AdapterMode; success = $false
        setup_failure = $setupFailure; scene_count = 0; passed_count = 0; cases = @()
        temp_removed = $true; paths_included = $false; identity_included = $false
    })
    exit 2
}

$tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$script:WorkRoot = [System.IO.Path]::GetFullPath(
    (Join-Path -Path $tempRoot -ChildPath ($script:TempPrefix + [Guid]::NewGuid().ToString('N'))))
$script:ControlDirectory = Join-Path -Path $script:WorkRoot -ChildPath 'control'
$script:ExecutionStore = Join-Path -Path $script:WorkRoot -ChildPath 'execution-store'
$script:BodyStore = Join-Path -Path $script:WorkRoot -ChildPath 'body-store'
$noticePath = Join-Path -Path $script:ControlDirectory -ChildPath 'enforcement-notices.ndjson'
$eventPath = Join-Path -Path $script:ExecutionStore -ChildPath 'events.ndjson'
$synthetic = $AdapterMode -ceq 'SYNTHETIC'

try {
    $failureStage = 'SETUP'
    [void](New-Item -ItemType Directory -Path $script:WorkRoot)
    Import-Module -Name (Join-Path -Path $script:RepositoryRoot -ChildPath 'src\SumiGuard.EnforcementControl\SumiGuard.EnforcementControl.psd1') -Force
    $controlInit = Initialize-SumiGuardEnforcementControlDirectory -Path $script:ControlDirectory
    $storesReady = [bool]$controlInit.success
    if ($synthetic) {
        # The hook's test seam never opens the stores. Plain folders keep the
        # ACL change in scene 3 meaningful without DPAPI on a CI runner.
        [void](New-Item -ItemType Directory -Path $script:ExecutionStore)
        [void](New-Item -ItemType Directory -Path $script:BodyStore)
    }
    else {
        Import-Module -Name (Join-Path -Path $script:RepositoryRoot -ChildPath 'src\SumiGuard.LocalStore\SumiGuard.LocalStore.psd1') -Force
        Import-Module -Name (Join-Path -Path $script:RepositoryRoot -ChildPath 'src\SumiGuard.ExecutionAdapter\SumiGuard.ExecutionAdapter.psd1') -Force
        $executionInit = Initialize-SumiGuardExecutionStore -Path $script:ExecutionStore
        $bodyInit = Initialize-SumiGuardLocalStore -Path $script:BodyStore
        $storesReady = $storesReady -and [bool]$executionInit.success -and [bool]$bodyInit.success
    }
    if (-not $storesReady) {
        throw [System.InvalidOperationException]::new('SETUP_FAILED')
    }

    $recordedOutcome = 'ADAPTER'
    $brokenOutcome = 'ADAPTER'
    if ($synthetic) {
        $recordedOutcome = 'TEST_RECORDED'
        $brokenOutcome = 'TEST_STORE_INVALID'
    }

    $scenes = @(
        [pscustomobject]@{
            number = 1; title = '強制モード オフ（設定なし）'; tool = 'Bash'; outcome = 'ADAPTER'
            setup = 'enforcement.json は置かない'
            prepare = { }
            explain = '→ Claude Code はいつもどおり動く'
            expect = @{ setting_status = 'CONFIG_ABSENT'; hook_status = 'NOT_ENFORCED'; stdout_kind = 'EMPTY'; notice_delta = 0; event_delta = 0 }
        },
        [pscustomobject]@{
            number = 2; title = '強制モード オン（Bash だけ）・保存先は正常'; tool = 'Bash'; outcome = $recordedOutcome
            setup = 'enforcement.json に Bash だけを書く'
            prepare = {
                [System.IO.File]::WriteAllText((Join-Path -Path $script:ControlDirectory -ChildPath 'enforcement.json'),
                    ('{"schema_version":1,"mode":"ENFORCE_RECORDING","routes":["' + $script:Route + '"]}'), $script:Utf8)
            }
            explain = '→ 記録できたので、そのまま実行してよい'
            expect = @{ setting_status = 'CONFIG_LOADED'; hook_status = 'ENFORCED'; reason_code = 'RECORDING_CONFIRMED'; stdout_kind = 'EMPTY'; notice_delta = 0 }
        },
        [pscustomobject]@{
            number = 3; title = '本文の保存先を壊す（権限を広げる）'; tool = 'Bash'; outcome = $brokenOutcome
            setup = '本文の保存先に「全員が読める」権限を足す'
            prepare = { Grant-DemoBodyStoreWideRead }
            explain = '→ Claude Code はこの返答を受け取ると実行しない（ゲート2・4で実測済み）'
            expect = @{ hook_status = 'ENFORCED'; decision = 'DENY'; stdout_kind = 'DENY_JSON'; notice_delta = 1; last_notice_decision = 'DENY' }
        },
        [pscustomobject]@{
            number = 4; title = '対象外の道具（PowerShell）'; tool = 'PowerShell'; outcome = $brokenOutcome
            setup = '保存先は壊れたまま。道具だけ変える'
            prepare = { }
            explain = '→ 強制するのは Bash だけ'
            expect = @{ setting_status = 'CONFIG_LOADED'; route_allowlisted = $false; hook_status = 'NOT_ENFORCED'; stdout_kind = 'EMPTY'; notice_delta = 0; event_delta = 0 }
        },
        [pscustomobject]@{
            number = 5; title = '緊急停止：ENFORCEMENT_OFF を置く'; tool = 'Bash'; outcome = $brokenOutcome
            setup = '制御フォルダに空のファイル ENFORCEMENT_OFF を置く'
            prepare = { [System.IO.File]::WriteAllText((Join-Path -Path $script:ControlDirectory -ChildPath 'ENFORCEMENT_OFF'), '', $script:Utf8) }
            explain = '→ 保存先は壊れたままでも、いつもどおり動く'
            expect = @{ setting_status = 'KILL_SWITCH_ACTIVE'; hook_status = 'NOT_ENFORCED'; stdout_kind = 'EMPTY'; notice_delta = 0; event_delta = 0 }
        },
        [pscustomobject]@{
            number = 6; title = '緊急停止を外す'; tool = 'Bash'; outcome = $brokenOutcome
            setup = 'ENFORCEMENT_OFF を消す'
            prepare = { Remove-Item -LiteralPath (Join-Path -Path $script:ControlDirectory -ChildPath 'ENFORCEMENT_OFF') -Force }
            explain = '→ また止まる。戻すのもファイル1つ'
            expect = @{ setting_status = 'CONFIG_LOADED'; hook_status = 'ENFORCED'; decision = 'DENY'; stdout_kind = 'DENY_JSON'; notice_delta = 1; last_notice_decision = 'DENY' }
        }
    )
    if (-not $synthetic) {
        $scenes[1].expect.event_delta = 1
        $scenes[1].expect.captured_delta = 1
    }

    Write-DemoLine -Text 'SUMI Guard 強制モード デモ' -Color Cyan
    Write-DemoLine -Text 'Claude も Codex も呼びません。費用はかかりません。'
    if ($synthetic) {
        Write-DemoLine -Text '合成モード（CI 用）：暗号化保存は実行していません' -Color Yellow
    }
    Write-DemoLine -Text 'Claude Code がフックに渡すのと同じ形の入力を、フックへ直接渡します。'
    Write-DemoLine -Text '使うのは使い捨てフォルダだけ。設定ファイルや既存のフックには触れません。'
    Wait-DemoScene

    foreach ($scene in $scenes) {
        $failureStage = 'SCENE_' + $scene.number
        Write-DemoLine
        Write-DemoLine -Text ('[' + $scene.number + '/6] ' + $scene.title) -Color Cyan
        Write-DemoLine -Text ('  準備  ' + $scene.setup) -Color DarkGray
        & $scene.prepare

        $noticesBefore = Get-DemoCount -Path $noticePath
        $eventsBefore = Get-DemoCount -Path $eventPath
        $capturedBefore = Get-CapturedEventCount -Path $eventPath
        $run = Invoke-DemoHook -Scene $scene.number -ToolName $scene.tool -Outcome $scene.outcome
        $noticeDelta = (Get-DemoCount -Path $noticePath) - $noticesBefore
        $eventDelta = (Get-DemoCount -Path $eventPath) - $eventsBefore
        $capturedDelta = (Get-CapturedEventCount -Path $eventPath) - $capturedBefore
        $lastNotice = $null
        if ($noticeDelta -gt 0) { $lastNotice = Get-LastNotice -Path $noticePath }

        $observed = [ordered]@{
            hook_ran = $run.hook_ran
            hook_status = [string](Get-DemoField -Object $run.hook -Name 'hook_status')
            setting_status = [string](Get-DemoField -Object $run.hook -Name 'setting_status')
            route_allowlisted = [bool](Get-DemoField -Object $run.hook -Name 'route_allowlisted')
            decision = [string](Get-DemoField -Object $run.hook -Name 'decision')
            reason_code = [string](Get-DemoField -Object $run.hook -Name 'reason_code')
            stdout_kind = $run.stdout_kind
            stderr_nonempty = $run.stderr_nonempty
            notice_delta = $noticeDelta
            event_delta = $eventDelta
            captured_delta = $capturedDelta
            last_notice_decision = [string](Get-DemoField -Object $lastNotice -Name 'decision')
            last_notice_reason = [string](Get-DemoField -Object $lastNotice -Name 'reason_code')
            last_notice_hint = [string](Get-DemoField -Object $lastNotice -Name 'action_hint')
            timed_out = $run.timed_out
        }

        $failedChecks = New-Object -TypeName System.Collections.Generic.List[string]
        if (-not $run.hook_ran) { $failedChecks.Add('hook_ran') }
        if ($run.timed_out) { $failedChecks.Add('timed_out') }
        foreach ($key in @($scene.expect.Keys | Sort-Object)) {
            $expected = $scene.expect[$key]
            $actual = $observed[$key]
            if ($expected -is [bool]) {
                if ([bool]$actual -ne $expected) { $failedChecks.Add($key) }
            }
            elseif ($expected -is [int]) {
                if ([int]$actual -ne $expected) { $failedChecks.Add($key) }
            }
            elseif ([string]$actual -cne [string]$expected) {
                $failedChecks.Add($key)
            }
        }

        Write-DemoLine -Text ('  入力  ' + $scene.tool + ': echo SUMI_GUARD_DEMO_' + $scene.number)
        if ($run.stdout_kind -ceq 'EMPTY') {
            Write-DemoLine -Text ('  返答  （なし）' + $scene.explain) -Color Green
        }
        elseif ($run.stdout_kind -ceq 'DENY_JSON') {
            Write-DemoLine -Text ('  返答  ' + $run.stdout_text) -Color Red
            Write-DemoLine -Text ('        ' + $scene.explain) -Color Red
        }
        else {
            Write-DemoLine -Text '  返答  想定外の出力（内容は表示しない）' -Color Yellow
        }

        if ($observed.decision -ceq 'DENY') {
            Write-DemoLine -Text ('  記録  確かめられなかった（' + $observed.reason_code + '）')
        }
        elseif ($observed.reason_code -ceq 'RECORDING_CONFIRMED') {
            if ($synthetic) {
                Write-DemoLine -Text '  記録  した（合成モード：保存は確認しない）'
            }
            else {
                Write-DemoLine -Text '  記録  した（本文は暗号化して保存）'
            }
        }
        else {
            Write-DemoLine -Text '  記録  しない'
        }

        if ($noticeDelta -gt 0) {
            $hint = $observed.last_notice_hint
            if ([string]::IsNullOrEmpty($hint)) { $hint = 'なし' }
            Write-DemoLine -Text ('  通知  ' + $observed.last_notice_decision + ' ／ ヒント: ' + $hint)
        }
        else {
            Write-DemoLine -Text '  通知  なし'
        }
        if ($run.stderr_nonempty) {
            Write-DemoLine -Text '  標準エラーに出力あり（内容は表示しない）' -Color Yellow
        }

        $passed = $failedChecks.Count -eq 0
        if ($passed) {
            Write-DemoLine -Text '  ○ 想定どおり' -Color Green
        }
        else {
            Write-DemoLine -Text ('  × 想定と違う：' + ($failedChecks.ToArray() -join ', ')) -Color Red
        }

        $cases.Add([pscustomobject][ordered]@{
            scene = $scene.number
            passed = $passed
            failed_checks = $failedChecks.ToArray()
            observed = [pscustomobject]$observed
        })
        if ($scene.number -lt 6) { Wait-DemoScene }
    }

    $failureStage = 'NOTICE_SUMMARY'
    Write-DemoLine
    $notices = @(Get-NonEmptyLine -Path $noticePath)
    Write-DemoLine -Text ('通知ファイル（enforcement-notices.ndjson）: ' + $notices.Count + ' 件') -Color Cyan
    foreach ($line in $notices) {
        $notice = $null
        try { $notice = $line | ConvertFrom-Json } catch { $notice = $null }
        $hint = [string](Get-DemoField -Object $notice -Name 'action_hint')
        if ([string]::IsNullOrEmpty($hint)) { $hint = 'なし' }
        Write-DemoLine -Text ('  ' + [string](Get-DemoField -Object $notice -Name 'decision') + '  ' +
            [string](Get-DemoField -Object $notice -Name 'reason_code') + '  ヒント: ' + $hint)
    }
    $failureStage = $null
}
catch {
    $setupFailure = 'DEMO_INTERRUPTED'
    $failureExceptionType = $_.Exception.GetType().FullName
    Write-DemoLine -Text ('デモが途中で止まりました（段階: ' + $failureStage + '、' + $failureExceptionType + '）') -Color Red
}
finally {
    if ($KeepEvidence) {
        $tempRemoved = $false
    }
    elseif ($null -ne $script:WorkRoot -and (Test-Path -LiteralPath $script:WorkRoot)) {
        $resolved = [System.IO.Path]::GetFullPath($script:WorkRoot)
        if ($resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Path $resolved -Leaf) -like ($script:TempPrefix + '*')) {
            try {
                Remove-Item -LiteralPath $resolved -Recurse -Force
                $tempRemoved = $true
            }
            catch {
                $tempRemoved = $false
            }
        }
    }
    else {
        $tempRemoved = $true
    }
}

$passedCount = @($cases | Where-Object { $_.passed }).Count
$success = $null -eq $setupFailure -and $cases.Count -eq 6 -and $passedCount -eq 6

Write-DemoLine
if ($success) {
    Write-DemoLine -Text ([string]$passedCount + '/6 場面が想定どおり。') -Color Green
}
else {
    Write-DemoLine -Text ([string]$passedCount + '/6 場面が想定どおり。想定と違う場面があります。') -Color Red
}
if ($KeepEvidence) {
    Write-DemoLine -Text '後片付け: 一時フォルダを残しました（場所は下の行。記録ファイルには書きません）。'
    Write-Host -Object ('  ' + $script:WorkRoot) -ForegroundColor DarkGray
}
elseif ($tempRemoved) {
    Write-DemoLine -Text '後片付け: 一時フォルダを削除しました。'
}
else {
    Write-DemoLine -Text '後片付け: 一時フォルダを消せませんでした。' -Color Yellow
}

Write-DemoCastFile
Write-DemoResultFile -Result ([pscustomobject][ordered]@{
    demo = 'sumi-guard-enforcement-demo'
    adapter_mode = $AdapterMode
    success = $success
    setup_failure = $setupFailure
    failure_stage = $failureStage
    failure_exception_type = $failureExceptionType
    scene_count = $cases.Count
    passed_count = $passedCount
    cases = $cases.ToArray()
    temp_removed = $tempRemoved
    powershell_version = $PSVersionTable.PSVersion.ToString()
    paths_included = $false
    identity_included = $false
    host_invoked = $false
})

if ($null -ne $setupFailure) { exit 2 }
if (-not $success) { exit 1 }
exit 0
