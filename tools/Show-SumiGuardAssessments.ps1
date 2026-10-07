[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StorePath,
    [string]$AssessmentId = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SumiGuardAssessmentStoreManifest = Join-Path `
    (Split-Path -Parent $PSScriptRoot) `
    'src\SumiGuard.AssessmentStore\SumiGuard.AssessmentStore.psd1'

function Get-SumiGuardAssessmentStatusText {
    param([Parameter(Mandatory = $true)][string]$Code)

    switch ($Code) {
        'DETECTED' { return '検知あり' }
        'NO_DETECTION' { return '対応範囲で該当なし' }
        'UNASSESSABLE' { return '評価不能' }
        'EVALUATION_FAILED' { return '評価処理失敗' }
        default { return '説明未定義 [' + $Code + ']' }
    }
}

function Get-SumiGuardAssessmentReasonText {
    param([AllowNull()]$Code)

    if ($null -eq $Code -or [string]::IsNullOrEmpty([string]$Code)) {
        return 'なし'
    }
    switch ([string]$Code) {
        'PARTIAL_UNASSESSABLE' { return '一部に評価不能な要素があります' }
        'CONTENT_UNAVAILABLE' { return '評価対象の本文を利用できません' }
        'UNSUPPORTED_LANGUAGE' { return '確認済みの対応言語ではありません' }
        'PARSE_INCOMPLETE' { return '構文を完全に解析できません' }
        'DYNAMIC_COMMAND_TARGET' { return '動的な実行対象を確定できません' }
        'ENCODED_PAYLOAD_NOT_INSPECTED' { return 'エンコード済み本文は検査していません' }
        'NOT_EVALUATED_AT_CAPTURE' { return '取得時に評価されていません' }
        'RULE_ENGINE_ERROR' { return '評価処理で内部エラーが発生しました' }
        default { return '説明未定義 [' + [string]$Code + ']' }
    }
}

function Get-SumiGuardAssessmentOriginText {
    param([Parameter(Mandatory = $true)][string]$Code)

    switch ($Code) {
        'SYNTHETIC_TEST' { return '試験データ' }
        'MANAGED_EXECUTION' { return '管理下実行の評価' }
        default { return '説明未定義 [' + $Code + ']' }
    }
}

function Get-SumiGuardAssessmentScopeText {
    param([Parameter(Mandatory = $true)][string]$Code)

    if ($Code -ceq 'WINDOWS_POWERSHELL_COMMAND_V1') {
        return 'Windows PowerShellコマンド・初期ルール範囲'
    }
    return '説明未定義 [' + $Code + ']'
}

function Get-SumiGuardAssessmentRuleText {
    param([Parameter(Mandatory = $true)]$Finding)

    $key = ([string]$Finding.rule_id) + '|' + ([string]$Finding.reason_code)
    switch ($key) {
        'SG-CMD-001|DOWNLOAD_TO_EXECUTION_FLOW' {
            return '取得結果が実行処理へ渡る確認可能な構造'
        }
        'SG-CMD-002|SECURITY_CONTROL_DISABLE_MUTATION' {
            return 'セキュリティ・監査・ログを無効化する既知の変更操作'
        }
        'SG-CMD-003|PERSISTENCE_REGISTRATION_MUTATION' {
            return '自動起動・タスク・サービス等の既知の永続化登録操作'
        }
        default {
            return '説明未定義 [' + [string]$Finding.rule_id + ' / ' +
                [string]$Finding.reason_code + ']'
        }
    }
}

function Get-SumiGuardAssessmentSeverityText {
    param([Parameter(Mandatory = $true)][string]$Code)

    switch ($Code) {
        'HIGH' { return '高' }
        'MEDIUM' { return '中' }
        default { return '説明未定義 [' + $Code + ']' }
    }
}

function Invoke-SumiGuardAssessmentDisplay {
    param(
        [Parameter(Mandatory = $true)][string]$AssessmentStorePath,
        [string]$RequestedAssessmentId = '',
        [Parameter(Mandatory = $true)][ref]$ExitCode
    )

    $ExitCode.Value = 1
    try {
        $null = Import-Module `
            -Name $script:SumiGuardAssessmentStoreManifest `
            -Force `
            -ErrorAction Stop
        $readResult = SumiGuard.AssessmentStore\Get-SumiGuardAssessmentRecord `
            -StorePath $AssessmentStorePath `
            -AssessmentId $RequestedAssessmentId
    }
    catch {
        Write-Output '評価記録の読取り: 失敗 [CLI_INTERNAL_ERROR]'
        return
    }
    if (-not $readResult.success) {
        Write-Output ('評価記録の読取り: 失敗 [' + [string]$readResult.status + ']')
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($RequestedAssessmentId) -and
        $readResult.record_count -eq 0) {
        Write-Output '評価結果詳細'
        Write-Output '該当記録: なし'
        $ExitCode.Value = 0
        return
    }

    $records = @($readResult.records | Sort-Object occurred_at_utc, assessment_id)
    if ([string]::IsNullOrWhiteSpace($RequestedAssessmentId)) {
        Write-Output '評価結果一覧'
        Write-Output ('件数: ' + $records.Count)
        foreach ($record in $records) {
            Write-Output (
                '評価ID: ' + $record.assessment_id +
                ' | 種別: ' + (Get-SumiGuardAssessmentOriginText -Code $record.evaluation_origin) +
                ' | 判定: ' + (Get-SumiGuardAssessmentStatusText -Code $record.assessment_status) +
                ' | 評価日時: ' + $record.occurred_at_utc)
            if ($record.evaluation_origin -ceq 'SYNTHETIC_TEST') {
                Write-Output '  注意: 試験データです。実際に実行された操作の記録ではありません。'
            }
        }
        $ExitCode.Value = 0
        return
    }

    $record = $records[0]
    Write-Output '評価結果詳細'
    Write-Output ('評価ID: ' + $record.assessment_id)
    Write-Output ('種別: ' + (Get-SumiGuardAssessmentOriginText -Code $record.evaluation_origin))
    if ($record.evaluation_origin -ceq 'SYNTHETIC_TEST') {
        Write-Output '注意: 試験データです。実際に実行された操作の記録ではありません。'
    }
    else {
        Write-Output '注意: 評価記録です。この記録だけでは実行状態を確認できません。'
    }
    $relatedExecution = if ($null -eq $record.execution_id) {
        'なし'
    }
    else {
        [string]$record.execution_id
    }
    Write-Output ('関連execution_id: ' + $relatedExecution)
    Write-Output ('評価日時: ' + $record.occurred_at_utc)
    Write-Output ('評価範囲: ' + (Get-SumiGuardAssessmentScopeText -Code $record.assessment_scope))
    Write-Output ('ルールセット版: ' + $record.ruleset_version)
    Write-Output ('判定: ' + (Get-SumiGuardAssessmentStatusText -Code $record.assessment_status))
    Write-Output ('理由: ' + (Get-SumiGuardAssessmentReasonText -Code $record.assessment_reason_code))
    if ($record.assessment_reason_code -ceq 'PARTIAL_UNASSESSABLE') {
        Write-Output '制約: 一部は評価不能です。確認できた検知結果だけを表示します。'
    }
    Write-Output ('検知ルール件数: ' + @($record.findings).Count)
    foreach ($finding in @($record.findings)) {
        Write-Output (
            'ルール: ' + $finding.rule_id +
            ' | 版: ' + $finding.rule_version +
            ' | 重大度: ' + (Get-SumiGuardAssessmentSeverityText -Code $finding.severity))
        Write-Output ('  説明: ' + (Get-SumiGuardAssessmentRuleText -Finding $finding))
    }
    $ExitCode.Value = 0
}

if ($MyInvocation.InvocationName -cne '.') {
    $displayExitCode = 1
    Invoke-SumiGuardAssessmentDisplay `
        -AssessmentStorePath $StorePath `
        -RequestedAssessmentId $AssessmentId `
        -ExitCode ([ref]$displayExitCode)
    exit $displayExitCode
}
