[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $root 'tools\Test-SumiGuardPowerShellCommand.ps1'
$rows = New-Object System.Collections.Generic.List[object]

. $cli -CommandText ''

function Add-CaseResult([string]$Name, [bool]$Pass) { $rows.Add([pscustomobject]@{ name = $Name; pass = $Pass }) }
function Invoke-ExternalCase([string]$Name, [string]$Text, [int]$ExpectedExit, [string[]]$Labels, [string[]]$AbsentLabels) {
    $output = @(& $cli -CommandText $Text)
    $exitCode = $LASTEXITCODE
    $joined = $output -join "`n"
    $pass = ($exitCode -eq $ExpectedExit)
    foreach ($label in $Labels) { $pass = $pass -and $joined.Contains($label) }
    foreach ($label in $AbsentLabels) { $pass = $pass -and (-not $joined.Contains($label)) }
    $pass = $pass -and (-not $joined.Contains($Text))
    Add-CaseResult $Name $pass
}

Invoke-ExternalCase 'RULE_001' 'Invoke-WebRequest ''https://example.invalid/a.ps1'' -OutFile $p; & $p' 0 @('注意：不審な操作パターンを検知', 'SG-CMD-001', '取得結果が実行処理へ渡る') @()
Invoke-ExternalCase 'RULE_002' 'Set-MpPreference -DisableRealtimeMonitoring $true' 0 @('SG-CMD-002', 'セキュリティ・監査・ログを無効化') @()
Invoke-ExternalCase 'RULE_003' 'Register-ScheduledTask -TaskName ''Synthetic'' -Action $a' 0 @('SG-CMD-003', '自動起動・タスク・サービス') @()
Invoke-ExternalCase 'NO_DETECTION' 'Get-ScheduledTask' 0 @('対応範囲で該当なし', '評価のみ・未実行') @('理由: なし')
Invoke-ExternalCase 'UNASSESSABLE' 'powershell.exe -EncodedCommand synthetic' 0 @('評価不能', 'エンコード済み本文は検査していません') @()
Invoke-ExternalCase 'COMMENTS_AND_SECRET' '# Set-MpPreference -DisableRealtimeMonitoring $true; SECRET_CANARY' 0 @('対応範囲で該当なし') @('SECRET_CANARY')
Invoke-ExternalCase 'PARTIAL' 'Set-MpPreference -DisableRealtimeMonitoring $true; & $dynamicCommand' 0 @('注意：不審な操作パターンを検知', '一部は評価不能です') @()

$evaluationFailure = Invoke-SumiGuardPowerShellCommandAssessmentCli -CommandText 'synthetic' -AssessmentInvoker {
    param($Unused)
    [pscustomobject]@{ assessment_status = 'EVALUATION_FAILED'; assessment_reason_code = 'RULE_ENGINE_ERROR'; findings = @() }
}
Add-CaseResult 'EVALUATOR_FAILURE' (($evaluationFailure.exit_code -eq 2) -and (($evaluationFailure.lines -join "`n").Contains('評価処理失敗')) -and (($evaluationFailure.lines -join "`n").Contains('評価処理で内部エラーが発生しました')))

$internalFailure = Invoke-SumiGuardPowerShellCommandAssessmentCli -CommandText 'synthetic' -ModuleImporter { throw [System.InvalidOperationException]::new('synthetic internal failure') }
Add-CaseResult 'CLI_INTERNAL_FAILURE' (($internalFailure.exit_code -eq 3) -and ($internalFailure.lines.Count -eq 1) -and ($internalFailure.lines[0] -ceq '評価処理失敗'))

$unknownReason = Invoke-SumiGuardPowerShellCommandAssessmentCli -CommandText 'synthetic' -AssessmentInvoker {
    param($Unused)
    [pscustomobject]@{ assessment_status = 'UNASSESSABLE'; assessment_reason_code = 'UNKNOWN_REASON'; findings = @() }
}
Add-CaseResult 'UNKNOWN_REASON' (($unknownReason.exit_code -eq 0) -and (($unknownReason.lines -join "`n").Contains('理由: 説明未定義')))

$failed = @($rows | Where-Object { -not $_.pass }).Count
[pscustomobject]@{ success = ($failed -eq 0); test_count = $rows.Count; passed_count = $rows.Count - $failed; failed_count = $failed; input_executed = $false; input_saved = $false; network_accessed = $false; child_processes_started = 0 } | ConvertTo-Json -Compress
if ($failed -eq 0) { exit 0 } else { exit 1 }
