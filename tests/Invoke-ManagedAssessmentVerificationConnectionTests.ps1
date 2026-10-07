[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList
function Add-Result { param([string]$Name,[bool]$Pass) [void]$results.Add([pscustomobject]@{name=$Name;pass=$Pass}) }
function New-Config { param([string]$Assessment="Write-Output 'CONNECTION_OK'",[string]$Launch="Write-Output 'CONNECTION_OK'",[string]$Path='C:\Synthetic\WindowsPowerShell\powershell.exe',[string]$Version='5.1.9999.1') [pscustomobject]@{assessment_command_text=$Assessment;launch_command_text=$Launch;executable_path=$Path;expected_interpreter_version=$Version} }
function New-Verification { param([bool]$Verified=$true,[bool]$Executable=$true,[bool]$Runner=$true,[bool]$Launch=$true,[string]$Version='5.1.9999.1',[string]$Path='C:\Synthetic\WindowsPowerShell\powershell.exe') [pscustomobject]@{verified=$Verified;executable_is_standard_path=$Executable;runner_process_is_standard_path=$Runner;launch_configuration_verified=$Launch;evidence_source='MANAGED_RUNNER_PROCESS_AND_LAUNCH_CONFIGURATION';interpreter_version=$Version;executable_file_version=$Version;observed_executable_path=$Path} }
$runner=Join-Path (Split-Path -Parent $PSScriptRoot) 'demo\Invoke-SumiGuardManagedAssessmentVerificationDemo.ps1';$id='0123456789abcdef0123456789abcdef';$other='fedcba9876543210fedcba9876543210';$starts=0
try {
 . $runner
 $runnerText=[IO.File]::ReadAllText($runner)
 Add-Result 'RUN_FIXED_SWITCH_ISOLATED_FROM_DOT_SOURCE' ($runnerText.Contains('$script:ManagedAssessmentConnectionRequestedFixedCommand = [bool]$RunFixedCommand') -and $runnerText.Contains('-RunFixedCommand ([bool]$script:ManagedAssessmentConnectionRequestedFixedCommand)'))
 Add-Result 'ENTRY_USES_ONE_EXECUTION_ID' ($runnerText.Contains('-AssessmentExecutionId $executionId -PlannedExecutionId $executionId'))
 Add-Result 'ENTRY_FAILURE_POLICY_IS_NONZERO' ($runnerText.Contains("assessment_status -cin @('EVALUATION_FAILED', 'NOT_OBTAINED')") -and $runnerText.Contains('exit 1'))
 $config=New-Config;$verification=New-Verification
 $r=Invoke-SumiGuardManagedAssessmentVerificationConnection -AssessmentExecutionId $id -PlannedExecutionId $id
 Add-Result 'NORMAL_HOST_EVIDENCE_ASSEMBLED' ($r.reconciliation_status -ceq 'VERIFIED_LAUNCH_PLAN' -and $r.assessment_status -ceq 'NO_DETECTION' -and $r.execution_start_count -eq 0)
 $powershellPath=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
 $psi=New-Object System.Diagnostics.ProcessStartInfo
 $psi.FileName=$powershellPath
 $psi.Arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $runner + '"'
 $psi.UseShellExecute=$false
 $psi.RedirectStandardOutput=$true
 $psi.RedirectStandardError=$true
 $psi.CreateNoWindow=$true
 $process=New-Object System.Diagnostics.Process
 $process.StartInfo=$psi
 [void]$process.Start()
 $stdoutTask=$process.StandardOutput.ReadToEndAsync()
 $stderrTask=$process.StandardError.ReadToEndAsync()
 $process.WaitForExit()
 $stdout=$stdoutTask.Result
 $stderr=$stderrTask.Result
 $dryExit=$process.ExitCode
 $dryStderrNonempty=($stderr.Length -gt 0)
 $dryReport=$null
 try { $dryReport=$stdout | ConvertFrom-Json -ErrorAction Stop } catch { $dryReport=$null }
 Add-Result 'FILE_ENTRY_DRY_EXIT_ZERO' ($dryExit -eq 0 -and -not $dryStderrNonempty)
 Add-Result 'FILE_ENTRY_DRY_REPORT' ($null -ne $dryReport -and $dryReport.reconciliation_status -ceq 'VERIFIED_LAUNCH_PLAN' -and $dryReport.assessment_status -ceq 'NO_DETECTION' -and $dryReport.execution_start_count -eq 0 -and $dryReport.execution_status -ceq 'NOT_STARTED')
 $r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id
 Add-Result 'NORMAL_PLAN' ($r.reconciliation_status -ceq 'VERIFIED_LAUNCH_PLAN' -and $r.assessment_status -ceq 'NO_DETECTION' -and $r.execution_status -ceq 'NOT_STARTED' -and $r.storage_status -ceq 'NOT_ATTEMPTED' -and $r.evaluation_origin -ceq 'DRY_RUN')
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride (New-Config -Launch "Write-Output 'OTHER'") -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id -RequestDryStart $true -TestDoubleStart {$script:starts++;$null};Add-Result 'COMMAND_MISMATCH_BLOCKS_START' ($r.reconciliation_reason_code -ceq 'COMMAND_MISMATCH' -and $r.execution_start_count -eq 0 -and $starts -eq 0)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $other -RequestDryStart $true -TestDoubleStart {$script:starts++;$null};Add-Result 'ID_MISMATCH_BLOCKS_START' ($r.reconciliation_reason_code -ceq 'EXECUTION_ID_MISMATCH' -and $r.execution_start_count -eq 0 -and $starts -eq 0)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride (New-Verification -Path 'C:\Synthetic\Other\other.exe') -AssessmentExecutionId $id -PlannedExecutionId $id -RequestDryStart $true -TestDoubleStart {$script:starts++;$null};Add-Result 'EXECUTABLE_MISMATCH_BLOCKS_START' ($r.reconciliation_reason_code -ceq 'EXECUTABLE_MISMATCH' -and $r.execution_start_count -eq 0 -and $starts -eq 0)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride (New-Verification -Version '7.0.1.1') -AssessmentExecutionId $id -PlannedExecutionId $id -RequestDryStart $true -TestDoubleStart {$script:starts++;$null};Add-Result 'VERSION_MISMATCH_BLOCKS_START' ($r.reconciliation_reason_code -ceq 'UNSUPPORTED_VERSION' -and $r.execution_start_count -eq 0 -and $starts -eq 0)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride (New-Verification -Launch $false) -AssessmentExecutionId $id -PlannedExecutionId $id -RequestDryStart $true -TestDoubleStart {$script:starts++;$null};Add-Result 'CONFIGURATION_MISMATCH_BLOCKS_START' ($r.reconciliation_reason_code -ceq 'LAUNCH_CONFIGURATION_UNVERIFIED' -and $r.execution_start_count -eq 0 -and $starts -eq 0)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride ([pscustomobject]@{verified=$true}) -AssessmentExecutionId $id -PlannedExecutionId $id -RequestDryStart $true -TestDoubleStart {$script:starts++;$null};Add-Result 'MISSING_EVIDENCE_BLOCKS_START' ($r.reconciliation_reason_code -ceq 'EVIDENCE_MISSING' -and $r.execution_start_count -eq 0 -and $starts -eq 0)
 $r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id -AssessmentInvoker {param($body,$eid,$verified) throw [InvalidOperationException]::new()};Add-Result 'EVALUATION_FAILURE_IS_SEPARATE' ($r.assessment_status -ceq 'EVALUATION_FAILED' -and $r.reconciliation_status -ceq 'VERIFIED_LAUNCH_PLAN' -and $r.execution_start_count -eq 0)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id -RequestDryStart $true -TestDoubleStart {$script:starts++;[pscustomobject]@{process_started=$true;execution_id=$other;observed_executable_path='C:\Synthetic\WindowsPowerShell\powershell.exe'}};Add-Result 'POST_CONFIRMATION_FAILURE_IS_SEPARATE' ($r.reconciliation_status -ceq 'VERIFIED_LAUNCH_PLAN' -and $r.process_confirmation_status -ceq 'PROCESS_UNVERIFIED' -and $r.execution_start_count -eq 1 -and $starts -eq 1)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride (New-Config -Launch "Write-Output 'OTHER'") -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id -RunFixedCommand $true -TestDoubleFixedExecution {$script:starts++;[pscustomobject]@{execution_started=$true;execution_start_count=1;execution_status='SUCCEEDED';stdout_matches_expected=$true;exit_code=0;stderr_nonempty=$false;timed_out=$false}};Add-Result 'FIXED_SWITCH_MISMATCH_BLOCKS_START' ($r.execution_start_count -eq 0 -and $starts -eq 0 -and $r.execution_start_status -ceq 'START_BLOCKED_BY_RECONCILIATION')
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id -RunFixedCommand $true -TestDoubleFixedExecution {$script:starts++;[pscustomobject]@{execution_started=$false;execution_start_count=0;execution_status='START_OR_CAPTURE_FAILED';stdout_matches_expected=$null;exit_code=$null;stderr_nonempty=$null;timed_out=$false}};Add-Result 'FIXED_START_FAILURE_RETAINED' ($r.execution_start_count -eq 0 -and $starts -eq 1 -and $r.execution_status -ceq 'START_OR_CAPTURE_FAILED' -and $null -eq $r.exit_code)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id -RunFixedCommand $true -TestDoubleFixedExecution {$script:starts++;[pscustomobject]@{execution_started=$true;execution_start_count=1;execution_status='TIMED_OUT';stdout_matches_expected=$false;exit_code=-1;stderr_nonempty=$false;timed_out=$true}};Add-Result 'FIXED_TIMEOUT_RETAINED' ($r.execution_start_count -eq 1 -and $starts -eq 1 -and $r.execution_status -ceq 'TIMED_OUT' -and $r.timed_out -and $r.exit_code -eq -1)
 $starts=0;$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride $config -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id -RunFixedCommand $true -TestDoubleFixedExecution {$script:starts++;[pscustomobject]@{execution_started=$true;execution_start_count=1;execution_status='SUCCEEDED';stdout_matches_expected=$true;exit_code=0;stderr_nonempty=$false;timed_out=$false}};Add-Result 'POST_EVIDENCE_MISSING_NOT_CONFIRMED' ($r.execution_start_count -eq 1 -and $starts -eq 1 -and $r.process_confirmation_status -ceq 'NOT_ATTEMPTED' -and $r.execution_status -ceq 'SUCCEEDED')
 $canary="SYNTHETIC-SECRET|C:\Synthetic\secret";$r=Invoke-SumiGuardManagedAssessmentVerificationConnection -ConfigurationOverride (New-Config -Assessment $canary -Launch $canary) -VerificationOverride $verification -AssessmentExecutionId $id -PlannedExecutionId $id;$json=$r|ConvertTo-Json -Compress;Add-Result 'RESULT_OMITS_CONTENT' (-not $json.Contains('SYNTHETIC-SECRET') -and -not $json.Contains('secret'))
} catch { Add-Result 'TEST_INTERNAL_FAILURE' $false }
$failed=@($results|Where-Object{-not $_.pass}).Count
[pscustomobject]@{success=($failed -eq 0);test_count=$results.Count;passed_count=$results.Count-$failed;failed_count=$failed;child_codex_started=0;actual_command_started=0;network_access_performed=$false;results=@($results)}|ConvertTo-Json -Compress -Depth 4
if($failed -gt 0){exit 1}
