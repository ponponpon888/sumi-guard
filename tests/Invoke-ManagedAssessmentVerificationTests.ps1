[CmdletBinding()]
param()
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$results = New-Object System.Collections.ArrayList
function Add-Result { param([string]$Name,[bool]$Pass) [void]$results.Add([pscustomobject]@{name=$Name;pass=$Pass}) }
function New-HostEvidence { param([string]$ObservedExecutable='C:\Synthetic\WindowsPowerShell\powershell.exe',[string]$ExpectedVersion='5.1.9999.1',[string]$ObservedVersion='5.1.9999.1',[bool]$LaunchVerified=$true,[AllowNull()]$FixedExecutable='C:\Synthetic\WindowsPowerShell\powershell.exe') return [pscustomobject]@{fixed_executable_path=$FixedExecutable;observed_executable_path=$ObservedExecutable;expected_interpreter_version=$ExpectedVersion;observed_interpreter_version=$ObservedVersion;expected_file_version='5.1.9999.1';observed_file_version='5.1.9999.1';launch_configuration_verified=$LaunchVerified} }
$modulePath=Join-Path (Split-Path -Parent $PSScriptRoot) 'src\SumiGuard.ManagedAssessmentVerification\SumiGuard.ManagedAssessmentVerification.psd1';$id='0123456789abcdef0123456789abcdef';$command="Write-Output 'MANAGED_VERIFICATION_OK'";$secret='SYNTHETIC-SECRET-NOT-RETURNED'
try {
 Import-Module $modulePath -Force -ErrorAction Stop
 $normal=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id (New-HostEvidence)
 Add-Result 'NORMAL_LAUNCH_PLAN_VERIFIED' ($normal.interpreter_verified -and $normal.launch_plan_status -ceq 'VERIFIED_LAUNCH_PLAN' -and $normal.process_confirmation_status -ceq 'NOT_ATTEMPTED' -and $normal.execution_status -ceq 'NOT_STARTED' -and $normal.storage_status -ceq 'NOT_ATTEMPTED')
 $r=Test-SumiGuardManagedAssessmentEvidence $command ($command+' x') $id $id (New-HostEvidence);Add-Result 'COMMAND_MISMATCH_UNVERIFIED' (-not $r.interpreter_verified -and $r.launch_plan_reason_code -ceq 'COMMAND_MISMATCH')
 $r=Test-SumiGuardManagedAssessmentEvidence $command $command $id 'fedcba9876543210fedcba9876543210' (New-HostEvidence);Add-Result 'ID_MISMATCH_UNVERIFIED' (-not $r.interpreter_verified -and $r.launch_plan_reason_code -ceq 'EXECUTION_ID_MISMATCH')
 $r=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id (New-HostEvidence -ObservedExecutable 'C:\Synthetic\Other\other.exe');Add-Result 'EXECUTABLE_MISMATCH_UNVERIFIED' (-not $r.interpreter_verified -and $r.launch_plan_reason_code -ceq 'EXECUTABLE_MISMATCH')
 $r=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id (New-HostEvidence -ObservedVersion '5.1.9998.1');Add-Result 'VERSION_MISMATCH_UNVERIFIED' (-not $r.interpreter_verified -and $r.launch_plan_reason_code -ceq 'VERSION_MISMATCH')
 $r=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id (New-HostEvidence -ExpectedVersion '7.0.1.1' -ObservedVersion '7.0.1.1');Add-Result 'UNSUPPORTED_VERSION_UNVERIFIED' (-not $r.interpreter_verified -and $r.launch_plan_reason_code -ceq 'UNSUPPORTED_VERSION')
 $r=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id (New-HostEvidence -LaunchVerified $false);Add-Result 'CONFIGURATION_MISMATCH_UNVERIFIED' (-not $r.interpreter_verified -and $r.launch_plan_reason_code -ceq 'LAUNCH_CONFIGURATION_UNVERIFIED')
 $r=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id (New-HostEvidence -FixedExecutable $null);Add-Result 'MISSING_EVIDENCE_UNVERIFIED' (-not $r.interpreter_verified -and $r.launch_plan_reason_code -ceq 'EVIDENCE_MISSING')
 $r=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id ([pscustomobject]@{self_declared_interpreter='WINDOWS_POWERSHELL'}) -CallerInterpreterVerified $true;Add-Result 'SELF_DECLARATION_NOT_TRUSTED' (-not $r.interpreter_verified -and $r.launch_plan_reason_code -ceq 'EVIDENCE_MISSING')
 $post=[pscustomobject]@{process_started=$true;execution_id=$id;observed_executable_path='C:\Synthetic\WindowsPowerShell\powershell.exe'};$r=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id (New-HostEvidence) $post;Add-Result 'POST_PROCESS_SEPARATE_AND_CONFIRMED' ($r.launch_plan_status -ceq 'VERIFIED_LAUNCH_PLAN' -and $r.process_confirmation_status -ceq 'PROCESS_CONFIRMED' -and $r.execution_status -ceq 'PROCESS_CONFIRMED')
 $post=[pscustomobject]@{process_started=$true;execution_id='fedcba9876543210fedcba9876543210';observed_executable_path='C:\Synthetic\WindowsPowerShell\powershell.exe'};$r=Test-SumiGuardManagedAssessmentEvidence $command $command $id $id (New-HostEvidence) $post;Add-Result 'POST_ID_MISMATCH_DOES_NOT_REWRITE_PLAN' ($r.launch_plan_status -ceq 'VERIFIED_LAUNCH_PLAN' -and $r.process_confirmation_status -ceq 'PROCESS_UNVERIFIED' -and $r.process_confirmation_reason_code -ceq 'PROCESS_EXECUTION_ID_MISMATCH')
 $canary=$secret+'|C:\Synthetic\secret-path';$r=Test-SumiGuardManagedAssessmentEvidence $canary $canary $id $id (New-HostEvidence);$serialized=$r|ConvertTo-Json -Compress -Depth 4;Add-Result 'RESULT_OMITS_CONTENT_AND_PATHS' (-not $serialized.Contains($secret) -and -not $serialized.Contains('secret-path') -and -not ($r.PSObject.Properties.Name -contains 'exception_message'))
} catch { Add-Result 'TEST_INTERNAL_FAILURE' $false }
$failed=@($results|Where-Object{-not $_.pass}).Count
[pscustomobject]@{success=($failed -eq 0);test_count=$results.Count;passed_count=$results.Count-$failed;failed_count=$failed;child_codex_started=0;command_inputs_executed=$false;network_access_performed=$false;results=@($results)}|ConvertTo-Json -Compress -Depth 4
if($failed -gt 0){exit 1}
