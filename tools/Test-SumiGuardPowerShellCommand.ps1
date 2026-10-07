<#
.SYNOPSIS
Evaluates declared Windows PowerShell source without executing or saving it.
.DESCRIPTION
Exit code 0: evaluation completed (including DETECTED, NO_DETECTION, UNASSESSABLE).
Exit code 2: evaluator returned EVALUATION_FAILED. Exit code 3: CLI internal failure.
#>
[CmdletBinding()]
param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandText)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$manifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1'

function StatusText([string]$Value) { switch ($Value) { 'DETECTED' { '警告あり' } 'NO_DETECTION' { '対応範囲で該当なし' } 'UNASSESSABLE' { '評価不能' } 'EVALUATION_FAILED' { '評価処理失敗' } default { '説明未定義' } } }
function ReasonText([string]$Value) { switch ($Value) { 'PARTIAL_UNASSESSABLE' { '一部は評価不能です' } 'CONTENT_UNAVAILABLE' { '評価対象を利用できません' } 'UNSUPPORTED_LANGUAGE' { '対応言語として確認できません' } 'PARSE_INCOMPLETE' { '構文を完全に解析できません' } 'DYNAMIC_COMMAND_TARGET' { '動的な実行対象を確定できません' } 'ENCODED_PAYLOAD_NOT_INSPECTED' { 'エンコード済み本文は検査していません' } 'RULE_ENGINE_ERROR' { '評価処理で内部エラーが発生しました' } default { '説明未定義' } } }
function SeverityText([string]$Value) { switch ($Value) { 'HIGH' { '高' } 'MEDIUM' { '中' } default { '説明未定義' } } }
function RuleText([string]$RuleId, [string]$ReasonCode) { switch (($RuleId + '|' + $ReasonCode)) { 'SG-CMD-001|DOWNLOAD_TO_EXECUTION_FLOW' { '取得結果が実行処理へ渡る確認可能な構造' } 'SG-CMD-002|SECURITY_CONTROL_DISABLE_MUTATION' { 'セキュリティ・監査・ログを無効化する既知の変更操作' } 'SG-CMD-003|PERSISTENCE_REGISTRATION_MUTATION' { '自動起動・タスク・サービス等の既知の永続化登録操作' } default { '説明未定義' } } }

function Invoke-SumiGuardDeclaredPowerShellSourceAssessment {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandText)
    # CommandAssessment's verification flag selects the parser grammar only.
    # This adapter never represents it as confirmation of an execution host.
    return SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment -CommandText $CommandText -ExecutionId ([Guid]::NewGuid().ToString('N')) -InterpreterKind 'WINDOWS_POWERSHELL' -InterpreterVerified $true
}

function Invoke-SumiGuardPowerShellCommandAssessmentCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandText,
        [scriptblock]$AssessmentInvoker,
        [scriptblock]$ModuleImporter
    )

    $lines = New-Object System.Collections.Generic.List[string]
    try {
        if ($null -eq $ModuleImporter) { Import-Module $manifest -Force -ErrorAction Stop } else { & $ModuleImporter }
        if ($null -eq $AssessmentInvoker) {
            $result = Invoke-SumiGuardDeclaredPowerShellSourceAssessment -CommandText $CommandText
        } else { $result = & $AssessmentInvoker $CommandText }

        $lines.Add('評価のみ・未実行')
        $lines.Add('対象言語: Windows PowerShell 5.1 ソース（実行インタープリター未確認）')
        if ($result.assessment_status -ceq 'DETECTED') { $lines.Add('注意：不審な操作パターンを検知') }
        $lines.Add('判定: ' + (StatusText $result.assessment_status))
        if (-not [string]::IsNullOrEmpty([string]$result.assessment_reason_code)) { $lines.Add('理由: ' + (ReasonText $result.assessment_reason_code)) }
        if ($result.assessment_reason_code -ceq 'PARTIAL_UNASSESSABLE') { $lines.Add('制約: 一部は評価不能です。') }
        foreach ($finding in @($result.findings)) {
            $lines.Add('ルール: ' + $finding.rule_id + ' | 重大度: ' + (SeverityText $finding.severity))
            $lines.Add('  説明: ' + (RuleText $finding.rule_id $finding.reason_code))
        }
        return [pscustomobject]@{ exit_code = if ($result.assessment_status -ceq 'EVALUATION_FAILED') { 2 } else { 0 }; lines = @($lines); input_executed = $false; input_saved = $false }
    } catch {
        return [pscustomobject]@{ exit_code = 3; lines = @('評価処理失敗'); input_executed = $false; input_saved = $false }
    }
}

if ($MyInvocation.InvocationName -cne '.') {
    $report = Invoke-SumiGuardPowerShellCommandAssessmentCli -CommandText $CommandText
    foreach ($line in @($report.lines)) { Write-Output $line }
    exit $report.exit_code
}
