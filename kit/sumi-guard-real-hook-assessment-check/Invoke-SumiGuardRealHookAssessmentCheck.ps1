[CmdletBinding()]param()
Set-StrictMode -Version 2.0;$ErrorActionPreference='Stop'
function Quote([string]$v){if($v.Length -gt 0 -and $v -notmatch '[\s"]'){return $v};$b=New-Object Text.StringBuilder;[void]$b.Append('"');$n=0;foreach($c in $v.ToCharArray()){if($c -eq '\'){$n++;continue};if($c -eq '"'){[void]$b.Append(('\'*(($n*2)+1)));[void]$b.Append('"');$n=0;continue};if($n){[void]$b.Append(('\'*$n));$n=0};[void]$b.Append($c)};if($n){[void]$b.Append(('\'*($n*2)))};[void]$b.Append('"');$b.ToString()}
function Resolve-CodexExe {$n=Get-Command codex.exe -ErrorAction SilentlyContinue;if($n -and(Test-Path $n.Source -PathType Leaf)){return [IO.Path]::GetFullPath($n.Source)};$s=Get-Command codex -ErrorAction SilentlyContinue;if($s){$c=Join-Path (Split-Path $s.Source -Parent) 'node_modules\@openai\codex\node_modules\@openai\codex-win32-x64\vendor\x86_64-pc-windows-msvc\bin\codex.exe';if(Test-Path $c -PathType Leaf){return [IO.Path]::GetFullPath($c)}}}
function Summary([string]$text) {
    $ids = New-Object 'Collections.Generic.HashSet[string]'
    $valid = $true
    $matched = $false
    $completionSeen = $false
    $expectedCommand = 'Write-Output SUMI_GUARD_REAL_HOOK_OK'
    $expectedOutput = 'SUMI_GUARD_REAL_HOOK_OK'

    foreach ($line in $text -split "`r?`n") {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $entry = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $valid = $false
            continue
        }
        if ($null -eq $entry -or $null -eq $entry.PSObject.Properties['item'] -or $null -eq $entry.item) {
            $valid = $false
            continue
        }
        $typeProperty = $entry.item.PSObject.Properties['type']
        if ($null -eq $typeProperty -or [string]::IsNullOrWhiteSpace([string]$typeProperty.Value)) {
            $valid = $false
            continue
        }
        if ([string]$typeProperty.Value -cne 'command_execution') { continue }

        $idProperty = $entry.item.PSObject.Properties['id']
        if ($null -eq $idProperty -or [string]::IsNullOrWhiteSpace([string]$idProperty.Value)) {
            $valid = $false
            continue
        }
        [void]$ids.Add([string]$idProperty.Value)

        $commandProperty = $entry.item.PSObject.Properties['command']
        $outputProperty = $entry.item.PSObject.Properties['aggregated_output']
        $hasCommand = $null -ne $commandProperty
        $hasOutput = $null -ne $outputProperty
        if ($hasCommand -xor $hasOutput) {
            $valid = $false
            continue
        }
        if (-not $hasCommand) { continue }
        if ($commandProperty.Value -isnot [string] -or $outputProperty.Value -isnot [string]) {
            $valid = $false
            continue
        }

        $completionSeen = $true
        if ([string]$commandProperty.Value -ceq $expectedCommand -and [string]$outputProperty.Value -ceq $expectedOutput) {
            $matched = $true
        }
    }

    [pscustomobject]@{
        valid = $valid
        count = $ids.Count
        command = $matched
        output = $matched
        completion_seen = $completionSeen
    }
}

function Test-SumiGuardRealHookAssessmentResult(
    [int]$CodexStarted,
    [object]$CodexExitCode,
    [bool]$TimedOut,
    [object]$SummaryResult,
    [object]$EventData
) {
    $eventValid = $null -ne $EventData -and
        [string]$EventData.assessment_status -ceq 'UNASSESSABLE' -and
        [bool]$EventData.response_generated
    [pscustomobject]@{
        success = (
            $CodexStarted -eq 1 -and
            $CodexExitCode -eq 0 -and
            -not $TimedOut -and
            $null -ne $SummaryResult -and
            [bool]$SummaryResult.valid -and
            $SummaryResult.count -eq 1 -and
            [bool]$SummaryResult.command -and
            [bool]$SummaryResult.output -and
            $eventValid
        )
    }
}
function Invoke-SumiGuardRealHookAssessmentCheckMain {
$root='C:\Dev\sumi-guard';$temp=Join-Path ([IO.Path]::GetTempPath()) ('sumi-guard-real-hook-'+[Guid]::NewGuid().ToString('N'));$event=Join-Path $temp 'event.json';$hook=Join-Path $root 'kit\sumi-guard-real-hook-assessment-check\sumi-guard-real-hook-assessment.ps1';$manifest=Join-Path $root 'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1';$ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe';$stage='RESOLVE_CODEX_EXE';$started=0;$exit=$null;$timeout=$false;$raw='';$stderr='';$eventData=$null
try{$codex=Resolve-CodexExe;if(-not $codex){throw [IO.FileNotFoundException]::new()};$stage='CREATE_TEMP';New-Item -ItemType Directory $temp -ErrorAction Stop|Out-Null;$hc=(Quote $ps)+' -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File '+(Quote $hook);$toml="[{matcher='^Bash$',hooks=[{type='command',command='$hc',command_windows='$hc',timeout=20,statusMessage='SUMI Guard monitor'}]}]";$oe=[Environment]::GetEnvironmentVariable('SUMI_GUARD_REAL_HOOK_EVENT_PATH','Process');$om=[Environment]::GetEnvironmentVariable('SUMI_GUARD_ASSESSMENT_MANIFEST','Process');[Environment]::SetEnvironmentVariable('SUMI_GUARD_REAL_HOOK_EVENT_PATH',$event,'Process');[Environment]::SetEnvironmentVariable('SUMI_GUARD_ASSESSMENT_MANIFEST',$manifest,'Process');try{$stage='START_CHILD';$a=@('--no-daemon','--dangerously-bypass-hook-trust','-c',('hooks.PreToolUse='+$toml),'-C',$temp,'-s','read-only','-a','never','exec','--json','--skip-git-repo-check','--ephemeral','--ignore-rules','--color','never','Call exec_command exactly once using PowerShell and Write-Output SUMI_GUARD_REAL_HOOK_OK.');$si=New-Object Diagnostics.ProcessStartInfo;$si.FileName=$codex;$si.Arguments=(($a|%{Quote $_})-join ' ');$si.WorkingDirectory=$temp;$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true;$p=New-Object Diagnostics.Process;$p.StartInfo=$si;if(-not $p.Start()){throw [InvalidOperationException]::new()};$started=1;$ot=$p.StandardOutput.ReadToEndAsync();$et=$p.StandardError.ReadToEndAsync();$d=[DateTime]::UtcNow.AddSeconds(60);while(-not $p.HasExited -and [DateTime]::UtcNow -lt $d){Start-Sleep -Milliseconds 250};if(-not $p.HasExited){$timeout=$true;Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue};$p.WaitForExit();$raw=$ot.Result;$stderr=$et.Result;$exit=$p.ExitCode;$p.Dispose()}finally{[Environment]::SetEnvironmentVariable('SUMI_GUARD_REAL_HOOK_EVENT_PATH',$oe,'Process');[Environment]::SetEnvironmentVariable('SUMI_GUARD_ASSESSMENT_MANIFEST',$om,'Process')};$stage='PARSE_JSON';$s=Summary $raw;$stage='READ_EVENT';if(Test-Path $event){$eventData=[IO.File]::ReadAllText($event,(New-Object Text.UTF8Encoding($false,$true)))|ConvertFrom-Json};$ok=(Test-SumiGuardRealHookAssessmentResult -CodexStarted $started -CodexExitCode $exit -TimedOut $timeout -SummaryResult $s -EventData $eventData).success;[pscustomobject]@{success=$ok;failure_stage=if($ok){$null}else{'VALIDATION_FAILED'};codex_started=$started;codex_exit_code=$exit;timed_out=$timeout;tool_execution_count=$s.count;fixed_command_matched=$s.command;fixed_output_matched=$s.output;hook_stages=if($eventData){$eventData.stages}else{@()};assessment_status=if($eventData){$eventData.assessment_status}else{'NOT_OBSERVED'};response_generated=if($eventData){[bool]$eventData.response_generated}else{$false};storage_status='NOT_ATTEMPTED';ui_display_observed=$false;stderr_nonempty=(-not [string]::IsNullOrWhiteSpace($stderr))}|ConvertTo-Json -Compress;if(-not $ok){exit 1}}catch{[pscustomobject]@{success=$false;failure_stage=$stage;exception_type=$_.Exception.GetType().FullName;hresult=$_.Exception.HResult;codex_started=$started;codex_exit_code=$exit;timed_out=$timeout;storage_status='NOT_ATTEMPTED'}|ConvertTo-Json -Compress;exit 1}finally{$raw='';$stderr='';if(Test-Path $temp){Remove-Item $temp -Recurse -Force}}
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SumiGuardRealHookAssessmentCheckMain
}
