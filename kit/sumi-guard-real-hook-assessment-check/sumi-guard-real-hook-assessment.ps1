Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$eventPath = [Environment]::GetEnvironmentVariable('SUMI_GUARD_REAL_HOOK_EVENT_PATH', 'Process')
$assessmentManifest = [Environment]::GetEnvironmentVariable('SUMI_GUARD_ASSESSMENT_MANIFEST', 'Process')
try {
    $stages = New-Object System.Collections.Generic.List[string]
    $stages.Add('HOOK_PROCESS_STARTED')
    $hookInput = ([Console]::In.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop)
    $stages.Add('HOOK_JSON_PARSED')
    if ($hookInput.hook_event_name -cne 'PreToolUse' -or [string]$hookInput.tool_name -cne 'Bash' -or $null -eq $hookInput.tool_input -or $hookInput.tool_input.command -isnot [string]) { throw [IO.InvalidDataException]::new() }
    $identity=([string]$hookInput.session_id)+'|'+([string]$hookInput.turn_id)+'|'+([string]$hookInput.tool_use_id);$bytes=(New-Object Text.UTF8Encoding($false,$true)).GetBytes($identity);$sha=[Security.Cryptography.SHA256]::Create()
    try {$id=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant().Substring(0,32)} finally {$sha.Dispose();[Array]::Clear($bytes,0,$bytes.Length)}
    Import-Module $assessmentManifest -Force -ErrorAction Stop
    $assessment=SumiGuard.CommandAssessment\Invoke-SumiGuardCommandAssessment -CommandText ([string]$hookInput.tool_input.command) -ExecutionId $id -InterpreterKind 'UNKNOWN' -InterpreterVerified $false
    $stages.Add('HOOK_EVALUATION_COMPLETED')
    $responseJson = (([ordered]@{systemMessage='SUMI Guard MONITOR: evaluation=UNASSESSABLE; storage=NOT_ATTEMPTED.'}|ConvertTo-Json -Compress))
    [Console]::Out.WriteLine($responseJson)
    [Console]::Out.Flush()
    $stages.Add('HOOK_RESPONSE_EMITTED')
    [IO.File]::WriteAllText($eventPath,(([ordered]@{hook_reached=$true;stages=@($stages);assessment_status=[string]$assessment.assessment_status;response_generated=$true;storage_status='NOT_ATTEMPTED';content_included=$false}|ConvertTo-Json -Compress)),(New-Object Text.UTF8Encoding($false)))
} catch {
    if(-not [string]::IsNullOrWhiteSpace($eventPath)){[IO.File]::WriteAllText($eventPath,(([ordered]@{hook_reached=$true;assessment_status='NOT_OBTAINED';response_generated=$true;storage_status='NOT_ATTEMPTED';content_included=$false}|ConvertTo-Json -Compress)),(New-Object Text.UTF8Encoding($false)))}
    [Console]::Out.WriteLine((([ordered]@{systemMessage='SUMI Guard MONITOR: evaluation=NOT_OBTAINED; storage=NOT_ATTEMPTED.'}|ConvertTo-Json -Compress)))
}
