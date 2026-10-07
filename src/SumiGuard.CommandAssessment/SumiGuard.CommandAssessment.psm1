Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:SchemaVersion = 1
$script:RulesetVersion = 'sumi-guard-command-rules/1.0.0'
$script:SumiGuardTestForceEvaluationFailure = $false

function New-SumiGuardStaticValue {
    param(
        [Parameter(Mandatory = $true)][bool]$Known,
        [AllowNull()]$Value
    )

    return [pscustomobject][ordered]@{
        known = $Known
        value = $Value
    }
}

function Get-SumiGuardStaticValue {
    param([Parameter(Mandatory = $true)]$Ast)

    if ($Ast -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return New-SumiGuardStaticValue -Known $true -Value ([string]$Ast.Value)
    }
    if ($Ast -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) {
        if (@($Ast.NestedExpressions).Count -eq 0) {
            return New-SumiGuardStaticValue -Known $true -Value ([string]$Ast.Value)
        }
        return New-SumiGuardStaticValue -Known $false -Value $null
    }
    if ($Ast -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return New-SumiGuardStaticValue -Known $true -Value $Ast.Value
    }
    if ($Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = $Ast.VariablePath.UserPath.ToLowerInvariant()
        switch ($name) {
            'true' { return New-SumiGuardStaticValue -Known $true -Value $true }
            'false' { return New-SumiGuardStaticValue -Known $true -Value $false }
            'null' { return New-SumiGuardStaticValue -Known $true -Value $null }
        }
    }
    return New-SumiGuardStaticValue -Known $false -Value $null
}

function Get-SumiGuardVariableName {
    param([AllowNull()]$Ast)

    if ($null -ne $Ast -and
        $Ast -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return $Ast.VariablePath.UserPath.ToLowerInvariant()
    }
    return $null
}

function Get-SumiGuardCommandName {
    param([Parameter(Mandatory = $true)]$CommandAst)

    $name = $CommandAst.GetCommandName()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $null
    }
    $separator = $name.LastIndexOf('\')
    if ($separator -ge 0 -and $separator -lt ($name.Length - 1)) {
        $name = $name.Substring($separator + 1)
    }
    return $name.ToLowerInvariant()
}

function Get-SumiGuardParameterArgumentAst {
    param(
        [Parameter(Mandatory = $true)]$CommandAst,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $wanted = @{}
    foreach ($name in $Names) {
        $wanted[$name.ToLowerInvariant()] = $true
    }
    $elements = @($CommandAst.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            continue
        }
        $parameterName = $element.ParameterName.ToLowerInvariant()
        if (-not $wanted.ContainsKey($parameterName)) {
            continue
        }
        if ($null -ne $element.Argument) {
            return $element.Argument
        }
        if (($index + 1) -lt $elements.Count -and
            $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
            return $elements[$index + 1]
        }
        return $null
    }
    return $null
}

function Test-SumiGuardHasParameter {
    param(
        [Parameter(Mandatory = $true)]$CommandAst,
        [Parameter(Mandatory = $true)][string[]]$Names
    )

    $wanted = @{}
    foreach ($name in $Names) {
        $wanted[$name.ToLowerInvariant()] = $true
    }
    foreach ($element in @($CommandAst.CommandElements)) {
        if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
            $wanted.ContainsKey($element.ParameterName.ToLowerInvariant())) {
            return $true
        }
    }
    return $false
}

function Get-SumiGuardFirstPositionalArgumentAst {
    param([Parameter(Mandatory = $true)]$CommandAst)

    $elements = @($CommandAst.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($null -eq $element.Argument -and
                ($index + 1) -lt $elements.Count -and
                $elements[$index + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                $index++
            }
            continue
        }
        return $element
    }
    return $null
}

function Get-SumiGuardStaticCommandValues {
    param([Parameter(Mandatory = $true)]$CommandAst)

    $values = New-Object System.Collections.Generic.List[string]
    $hasDynamic = $false
    $elements = @($CommandAst.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
            if ($null -ne $element.Argument) {
                $value = Get-SumiGuardStaticValue -Ast $element.Argument
                if ($value.known -and $null -ne $value.value) {
                    $values.Add(([string]$value.value).ToLowerInvariant())
                }
                else {
                    $hasDynamic = $true
                }
            }
            continue
        }
        $staticValue = Get-SumiGuardStaticValue -Ast $element
        if ($staticValue.known -and $null -ne $staticValue.value) {
            $values.Add(([string]$staticValue.value).ToLowerInvariant())
        }
        else {
            $hasDynamic = $true
        }
    }
    return [pscustomobject][ordered]@{
        values = $values.ToArray()
        has_dynamic = $hasDynamic
    }
}

function Test-SumiGuardStaticBoolean {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][bool]$Expected
    )

    $value = Get-SumiGuardStaticValue -Ast $Ast
    if (-not $value.known) {
        return $false
    }
    if ($value.value -is [bool]) {
        return ([bool]$value.value -eq $Expected)
    }
    $text = ([string]$value.value).Trim().ToLowerInvariant()
    if ($Expected) {
        return ($text -ceq 'true' -or $text -ceq '$true' -or $text -ceq '1')
    }
    return ($text -ceq 'false' -or $text -ceq '$false' -or $text -ceq '0')
}

function Test-SumiGuardStaticText {
    param(
        [Parameter(Mandatory = $true)]$Ast,
        [Parameter(Mandatory = $true)][string[]]$ExpectedValues
    )

    $value = Get-SumiGuardStaticValue -Ast $Ast
    if (-not $value.known -or $null -eq $value.value) {
        return $false
    }
    $text = ([string]$value.value).Trim().ToLowerInvariant()
    foreach ($expected in $ExpectedValues) {
        if ($text -ceq $expected.ToLowerInvariant()) {
            return $true
        }
    }
    return $false
}

function Test-SumiGuardDownloadCommand {
    param([AllowNull()][string]$Name)

    return $Name -cin @(
        'invoke-webrequest', 'iwr', 'wget', 'curl', 'curl.exe',
        'invoke-restmethod', 'irm', 'start-bitstransfer')
}

function Test-SumiGuardPowerShellHostCommand {
    param([AllowNull()][string]$Name)

    return $Name -cin @('powershell', 'powershell.exe', 'pwsh', 'pwsh.exe')
}

function Test-SumiGuardRunKeyPath {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Replace('/', '\').ToLowerInvariant()
    return ($normalized -match '\\software\\microsoft\\windows\\currentversion\\run(once)?(?:\\|$)')
}

function Test-SumiGuardStartupPath {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Replace('/', '\').ToLowerInvariant()
    return $normalized.Contains('\microsoft\windows\start menu\programs\startup\') -or
        $normalized.EndsWith('\microsoft\windows\start menu\programs\startup')
}

function New-SumiGuardFinding {
    param(
        [Parameter(Mandatory = $true)][string]$RuleId,
        [Parameter(Mandatory = $true)][string]$RuleVersion,
        [Parameter(Mandatory = $true)][ValidateSet('HIGH', 'MEDIUM')][string]$Severity,
        [Parameter(Mandatory = $true)][string]$ReasonCode
    )

    return [pscustomobject][ordered]@{
        rule_id = $RuleId
        rule_version = $RuleVersion
        severity = $Severity
        reason_code = $ReasonCode
    }
}

function New-SumiGuardAssessmentResult {
    param(
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('DETECTED', 'NO_DETECTION', 'UNASSESSABLE', 'EVALUATION_FAILED')]
        [string]$Status,
        [AllowNull()][string]$ReasonCode,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Findings
    )

    return [pscustomobject][ordered]@{
        schema_version = $script:SchemaVersion
        record_id = [Guid]::NewGuid().ToString('N')
        record_type = 'ExecutionSafetyAssessment'
        execution_id = $ExecutionId.ToLowerInvariant()
        occurred_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        assessment_status = $Status
        assessment_reason_code = $ReasonCode
        ruleset_version = $script:RulesetVersion
        findings = @($Findings)
        content_included = $false
        source_excerpt_included = $false
        monitor_action = 'WARN_ONLY'
        automatic_deny = $false
    }
}

function Invoke-SumiGuardCommandAssessment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CommandText,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{32}$')][string]$ExecutionId,
        [Parameter(Mandatory = $true)]
        [ValidateSet('WINDOWS_POWERSHELL', 'OTHER', 'UNKNOWN')]
        [string]$InterpreterKind,
        [Parameter(Mandatory = $true)][bool]$InterpreterVerified
    )

    $tokens = $null
    $parseErrors = $null
    $ast = $null
    try {
        if (-not $InterpreterVerified -or $InterpreterKind -cne 'WINDOWS_POWERSHELL') {
            return New-SumiGuardAssessmentResult `
                -ExecutionId $ExecutionId `
                -Status 'UNASSESSABLE' `
                -ReasonCode 'UNSUPPORTED_LANGUAGE' `
                -Findings @()
        }
        if ([string]::IsNullOrWhiteSpace($CommandText)) {
            return New-SumiGuardAssessmentResult `
                -ExecutionId $ExecutionId `
                -Status 'UNASSESSABLE' `
                -ReasonCode 'CONTENT_UNAVAILABLE' `
                -Findings @()
        }
        if ($script:SumiGuardTestForceEvaluationFailure) {
            throw [System.InvalidOperationException]::new('SYNTHETIC_RULE_ENGINE_FAILURE_CANARY')
        }

        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $CommandText,
            [ref]$tokens,
            [ref]$parseErrors)
        if (@($parseErrors).Count -gt 0) {
            return New-SumiGuardAssessmentResult `
                -ExecutionId $ExecutionId `
                -Status 'UNASSESSABLE' `
                -ReasonCode 'PARSE_INCOMPLETE' `
                -Findings @()
        }

        $commands = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst]
        }, $true))
        $assignments = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst]
        }, $true))
        $pipelines = @($ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.PipelineAst]
        }, $true))

        $downloadValueVariables = @{}
        $downloadPathVariables = @{}
        $downloadPaths = @{}
        foreach ($assignment in $assignments) {
            $leftName = Get-SumiGuardVariableName -Ast $assignment.Left
            if ([string]::IsNullOrWhiteSpace($leftName)) { continue }
            $rightDownloads = @($assignment.Right.FindAll({
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
                    return $false
                }
                return Test-SumiGuardDownloadCommand -Name (Get-SumiGuardCommandName -CommandAst $node)
            }, $true))
            if ($rightDownloads.Count -gt 0) {
                $downloadValueVariables[$leftName] = $true
            }
        }
        foreach ($command in $commands) {
            $name = Get-SumiGuardCommandName -CommandAst $command
            if (-not (Test-SumiGuardDownloadCommand -Name $name)) { continue }
            $destinationNames = if ($name -ceq 'start-bitstransfer') {
                @('destination')
            }
            else {
                @('outfile', 'o', 'output')
            }
            $destinationAst = Get-SumiGuardParameterArgumentAst `
                -CommandAst $command `
                -Names $destinationNames
            if ($null -eq $destinationAst) { continue }
            $variableName = Get-SumiGuardVariableName -Ast $destinationAst
            if (-not [string]::IsNullOrWhiteSpace($variableName)) {
                $downloadPathVariables[$variableName] = $true
                continue
            }
            $staticDestination = Get-SumiGuardStaticValue -Ast $destinationAst
            if ($staticDestination.known -and $null -ne $staticDestination.value) {
                $downloadPaths[([string]$staticDestination.value).ToLowerInvariant()] = $true
            }
        }

        $sg001Detected = $false
        $resolvedDynamicInvocations = @{}
        foreach ($pipeline in $pipelines) {
            $seenDownload = $false
            foreach ($element in @($pipeline.PipelineElements)) {
                if ($element -isnot [System.Management.Automation.Language.CommandAst]) { continue }
                $name = Get-SumiGuardCommandName -CommandAst $element
                if (Test-SumiGuardDownloadCommand -Name $name) {
                    $seenDownload = $true
                    continue
                }
                if ($seenDownload -and $name -cin @('invoke-expression', 'iex')) {
                    $sg001Detected = $true
                    $resolvedDynamicInvocations[[string]$element.Extent.StartOffset] = $true
                }
            }
        }
        foreach ($command in $commands) {
            $name = Get-SumiGuardCommandName -CommandAst $command
            if ($name -cin @('invoke-expression', 'iex')) {
                $nestedDownload = @($command.FindAll({
                    param($node)
                    if ($node -isnot [System.Management.Automation.Language.CommandAst]) {
                        return $false
                    }
                    return Test-SumiGuardDownloadCommand -Name (Get-SumiGuardCommandName -CommandAst $node)
                }, $true)).Count -gt 0
                $argument = Get-SumiGuardFirstPositionalArgumentAst -CommandAst $command
                $argumentVariable = Get-SumiGuardVariableName -Ast $argument
                if ($nestedDownload -or
                    (-not [string]::IsNullOrWhiteSpace($argumentVariable) -and
                        $downloadValueVariables.ContainsKey($argumentVariable))) {
                    $sg001Detected = $true
                    $resolvedDynamicInvocations[[string]$command.Extent.StartOffset] = $true
                }
                continue
            }

            $invocation = [string]$command.InvocationOperator
            if ($invocation -ceq 'Ampersand' -or $invocation -ceq 'Dot') {
                $targetAst = if (@($command.CommandElements).Count -gt 0) {
                    $command.CommandElements[0]
                }
                else {
                    $null
                }
                $targetVariable = Get-SumiGuardVariableName -Ast $targetAst
                $targetStatic = if ($null -ne $targetAst) {
                    Get-SumiGuardStaticValue -Ast $targetAst
                }
                else {
                    New-SumiGuardStaticValue -Known $false -Value $null
                }
                $matchesDownload = (
                    (-not [string]::IsNullOrWhiteSpace($targetVariable) -and
                        ($downloadPathVariables.ContainsKey($targetVariable) -or
                            $downloadValueVariables.ContainsKey($targetVariable))) -or
                    ($targetStatic.known -and $null -ne $targetStatic.value -and
                        $downloadPaths.ContainsKey(([string]$targetStatic.value).ToLowerInvariant())))
                if ($matchesDownload) {
                    $sg001Detected = $true
                    $resolvedDynamicInvocations[[string]$command.Extent.StartOffset] = $true
                }
                continue
            }

            if (Test-SumiGuardPowerShellHostCommand -Name $name) {
                $fileAst = Get-SumiGuardParameterArgumentAst -CommandAst $command -Names @('file', 'f')
                $commandAst = Get-SumiGuardParameterArgumentAst -CommandAst $command -Names @('command', 'c')
                foreach ($targetAst in @($fileAst, $commandAst)) {
                    if ($null -eq $targetAst) { continue }
                    $targetVariable = Get-SumiGuardVariableName -Ast $targetAst
                    $targetStatic = Get-SumiGuardStaticValue -Ast $targetAst
                    if ((-not [string]::IsNullOrWhiteSpace($targetVariable) -and
                            ($downloadPathVariables.ContainsKey($targetVariable) -or
                                $downloadValueVariables.ContainsKey($targetVariable))) -or
                        ($targetStatic.known -and $null -ne $targetStatic.value -and
                            $downloadPaths.ContainsKey(([string]$targetStatic.value).ToLowerInvariant()))) {
                        $sg001Detected = $true
                        $resolvedDynamicInvocations[[string]$command.Extent.StartOffset] = $true
                    }
                }
                continue
            }

            if ($name -ceq 'start-process') {
                $targetAst = Get-SumiGuardParameterArgumentAst `
                    -CommandAst $command `
                    -Names @('filepath')
                if ($null -eq $targetAst) {
                    $targetAst = Get-SumiGuardFirstPositionalArgumentAst -CommandAst $command
                }
                if ($null -ne $targetAst) {
                    $targetVariable = Get-SumiGuardVariableName -Ast $targetAst
                    $targetStatic = Get-SumiGuardStaticValue -Ast $targetAst
                    if ((-not [string]::IsNullOrWhiteSpace($targetVariable) -and
                            $downloadPathVariables.ContainsKey($targetVariable)) -or
                        ($targetStatic.known -and $null -ne $targetStatic.value -and
                            $downloadPaths.ContainsKey(([string]$targetStatic.value).ToLowerInvariant()))) {
                        $sg001Detected = $true
                        $resolvedDynamicInvocations[[string]$command.Extent.StartOffset] = $true
                    }
                }
            }
        }

        $sg002Detected = $false
        $securityUnresolved = $false
        $defenderDisableParameters = @(
            'disablerealtimemonitoring',
            'disablebehaviormonitoring',
            'disableioavprotection',
            'disablescriptscanning')
        foreach ($command in $commands) {
            $name = Get-SumiGuardCommandName -CommandAst $command
            if ($name -ceq 'set-mppreference') {
                foreach ($parameterName in $defenderDisableParameters) {
                    if (-not (Test-SumiGuardHasParameter -CommandAst $command -Names @($parameterName))) {
                        continue
                    }
                    $valueAst = Get-SumiGuardParameterArgumentAst -CommandAst $command -Names @($parameterName)
                    if ($null -eq $valueAst -or -not (Get-SumiGuardStaticValue -Ast $valueAst).known) {
                        $securityUnresolved = $true
                    }
                    elseif (Test-SumiGuardStaticBoolean -Ast $valueAst -Expected $true) {
                        $sg002Detected = $true
                    }
                }
                continue
            }
            if ($name -ceq 'set-netfirewallprofile' -or $name -ceq 'set-logproperties') {
                if (Test-SumiGuardHasParameter -CommandAst $command -Names @('enabled')) {
                    $enabledAst = Get-SumiGuardParameterArgumentAst -CommandAst $command -Names @('enabled')
                    if ($null -eq $enabledAst -or -not (Get-SumiGuardStaticValue -Ast $enabledAst).known) {
                        $securityUnresolved = $true
                    }
                    elseif (Test-SumiGuardStaticBoolean -Ast $enabledAst -Expected $false) {
                        $sg002Detected = $true
                    }
                }
                continue
            }
            if ($name -ceq 'stop-service' -or $name -ceq 'set-service') {
                $serviceAst = Get-SumiGuardParameterArgumentAst `
                    -CommandAst $command `
                    -Names @('name', 'displayname')
                if ($null -eq $serviceAst) {
                    $serviceAst = Get-SumiGuardFirstPositionalArgumentAst -CommandAst $command
                }
                $serviceValue = if ($null -ne $serviceAst) {
                    Get-SumiGuardStaticValue -Ast $serviceAst
                }
                else {
                    New-SumiGuardStaticValue -Known $false -Value $null
                }
                if (-not $serviceValue.known) {
                    $securityUnresolved = $true
                    continue
                }
                if (([string]$serviceValue.value).ToLowerInvariant() -notin @('eventlog', 'windows event log')) {
                    continue
                }
                if ($name -ceq 'stop-service') {
                    $sg002Detected = $true
                    continue
                }
                $startupAst = Get-SumiGuardParameterArgumentAst `
                    -CommandAst $command `
                    -Names @('startuptype')
                if ($null -eq $startupAst -or -not (Get-SumiGuardStaticValue -Ast $startupAst).known) {
                    $securityUnresolved = $true
                }
                elseif (Test-SumiGuardStaticText -Ast $startupAst -ExpectedValues @('disabled')) {
                    $sg002Detected = $true
                }
                continue
            }
            if ($name -cin @('auditpol', 'auditpol.exe', 'wevtutil', 'wevtutil.exe')) {
                $argumentInfo = Get-SumiGuardStaticCommandValues -CommandAst $command
                $values = @($argumentInfo.values)
                if ($name -cin @('auditpol', 'auditpol.exe')) {
                    if ($values -ccontains '/clear' -or
                        $values -ccontains '/success:disable' -or
                        $values -ccontains '/failure:disable') {
                        $sg002Detected = $true
                    }
                    elseif ($argumentInfo.has_dynamic -and $values -ccontains '/set') {
                        $securityUnresolved = $true
                    }
                }
                elseif (($values -ccontains 'sl' -or $values -ccontains 'set-log') -and
                    $values -ccontains '/e:false') {
                    $sg002Detected = $true
                }
                elseif ($argumentInfo.has_dynamic -and
                    ($values -ccontains 'sl' -or $values -ccontains 'set-log')) {
                    $securityUnresolved = $true
                }
            }
        }

        $sg003Detected = $false
        $persistenceUnresolved = $false
        foreach ($command in $commands) {
            $name = Get-SumiGuardCommandName -CommandAst $command
            if ($name -ceq 'register-scheduledtask') {
                $sg003Detected = $true
                continue
            }
            if ($name -cin @('schtasks', 'schtasks.exe')) {
                $argumentInfo = Get-SumiGuardStaticCommandValues -CommandAst $command
                if (@($argumentInfo.values) -ccontains '/create') {
                    $sg003Detected = $true
                }
                elseif ($argumentInfo.has_dynamic -and
                    -not (@($argumentInfo.values) -ccontains '/delete') -and
                    -not (@($argumentInfo.values) -ccontains '/query')) {
                    $persistenceUnresolved = $true
                }
                continue
            }
            if ($name -cin @('new-itemproperty', 'set-itemproperty')) {
                $pathAst = Get-SumiGuardParameterArgumentAst -CommandAst $command -Names @('path', 'literalpath')
                if ($null -eq $pathAst) {
                    $pathAst = Get-SumiGuardFirstPositionalArgumentAst -CommandAst $command
                }
                $pathValue = if ($null -ne $pathAst) {
                    Get-SumiGuardStaticValue -Ast $pathAst
                }
                else {
                    New-SumiGuardStaticValue -Known $false -Value $null
                }
                if (-not $pathValue.known) {
                    $persistenceUnresolved = $true
                }
                elseif ($null -ne $pathValue.value -and
                    (Test-SumiGuardRunKeyPath -Value ([string]$pathValue.value))) {
                    $sg003Detected = $true
                }
                continue
            }
            if ($name -cin @('reg', 'reg.exe')) {
                $argumentInfo = Get-SumiGuardStaticCommandValues -CommandAst $command
                $values = @($argumentInfo.values)
                if ($values -ccontains 'add') {
                    $runPathFound = $false
                    foreach ($value in $values) {
                        if (Test-SumiGuardRunKeyPath -Value $value) {
                            $runPathFound = $true
                            break
                        }
                    }
                    if ($runPathFound) {
                        $sg003Detected = $true
                    }
                    elseif ($argumentInfo.has_dynamic) {
                        $persistenceUnresolved = $true
                    }
                }
                continue
            }
            if ($name -cin @('new-service', 'set-service')) {
                $startupAst = Get-SumiGuardParameterArgumentAst -CommandAst $command -Names @('startuptype')
                if ($null -ne $startupAst) {
                    $startupValue = Get-SumiGuardStaticValue -Ast $startupAst
                    if (-not $startupValue.known) {
                        $persistenceUnresolved = $true
                    }
                    elseif (Test-SumiGuardStaticText `
                        -Ast $startupAst `
                        -ExpectedValues @('automatic', 'automaticdelayedstart', 'delayed-auto')) {
                        $sg003Detected = $true
                    }
                }
                continue
            }
            if ($name -cin @('sc', 'sc.exe')) {
                $argumentInfo = Get-SumiGuardStaticCommandValues -CommandAst $command
                $values = @($argumentInfo.values)
                $operationIsPersistent = $values -ccontains 'create' -or $values -ccontains 'config'
                $autoStart = $values -ccontains 'auto' -or $values -ccontains 'delayed-auto'
                if ($operationIsPersistent -and $autoStart) {
                    $sg003Detected = $true
                }
                elseif ($operationIsPersistent -and $argumentInfo.has_dynamic) {
                    $persistenceUnresolved = $true
                }
                continue
            }
            if ($name -cin @(
                'copy-item', 'move-item', 'new-item', 'set-content',
                'add-content', 'out-file')) {
                $pathNames = if ($name -cin @('copy-item', 'move-item')) {
                    @('destination')
                }
                elseif ($name -ceq 'out-file') {
                    @('filepath')
                }
                else {
                    @('path', 'literalpath')
                }
                $pathAst = Get-SumiGuardParameterArgumentAst -CommandAst $command -Names $pathNames
                if ($null -eq $pathAst) {
                    continue
                }
                $pathValue = Get-SumiGuardStaticValue -Ast $pathAst
                if (-not $pathValue.known) {
                    $persistenceUnresolved = $true
                }
                elseif ($null -ne $pathValue.value -and
                    (Test-SumiGuardStartupPath -Value ([string]$pathValue.value))) {
                    $sg003Detected = $true
                }
            }
        }

        $encodedPayload = $false
        $dynamicExecution = $securityUnresolved -or $persistenceUnresolved
        foreach ($command in $commands) {
            $name = Get-SumiGuardCommandName -CommandAst $command
            if ((Test-SumiGuardPowerShellHostCommand -Name $name) -and
                (Test-SumiGuardHasParameter -CommandAst $command -Names @('encodedcommand', 'enc'))) {
                $encodedPayload = $true
            }
            $offsetKey = [string]$command.Extent.StartOffset
            $invocation = [string]$command.InvocationOperator
            if (($invocation -ceq 'Ampersand' -or $invocation -ceq 'Dot') -and
                -not $resolvedDynamicInvocations.ContainsKey($offsetKey)) {
                $targetAst = if (@($command.CommandElements).Count -gt 0) {
                    $command.CommandElements[0]
                }
                else {
                    $null
                }
                $targetValue = if ($null -ne $targetAst) {
                    Get-SumiGuardStaticValue -Ast $targetAst
                }
                else {
                    New-SumiGuardStaticValue -Known $false -Value $null
                }
                if (-not $targetValue.known) {
                    $dynamicExecution = $true
                }
            }
            if ($name -cin @('invoke-expression', 'iex') -and
                -not $resolvedDynamicInvocations.ContainsKey($offsetKey)) {
                $dynamicExecution = $true
            }
            if (Test-SumiGuardPowerShellHostCommand -Name $name) {
                foreach ($parameterName in @('command', 'c', 'file', 'f')) {
                    if (-not (Test-SumiGuardHasParameter -CommandAst $command -Names @($parameterName))) {
                        continue
                    }
                    $argumentAst = Get-SumiGuardParameterArgumentAst `
                        -CommandAst $command `
                        -Names @($parameterName)
                    if ($null -ne $argumentAst -and
                        -not (Get-SumiGuardStaticValue -Ast $argumentAst).known -and
                        -not $resolvedDynamicInvocations.ContainsKey($offsetKey)) {
                        $dynamicExecution = $true
                    }
                }
            }
            if ($name -ceq 'start-process' -and
                -not $resolvedDynamicInvocations.ContainsKey($offsetKey)) {
                $targetAst = Get-SumiGuardParameterArgumentAst `
                    -CommandAst $command `
                    -Names @('filepath')
                if ($null -eq $targetAst) {
                    $targetAst = Get-SumiGuardFirstPositionalArgumentAst -CommandAst $command
                }
                if ($null -ne $targetAst -and
                    -not (Get-SumiGuardStaticValue -Ast $targetAst).known) {
                    $dynamicExecution = $true
                }
            }
            if ($name -ceq 'add-type' -and
                (Test-SumiGuardHasParameter -CommandAst $command -Names @('typedefinition'))) {
                $dynamicExecution = $true
            }
            if ($name -ceq 'invoke-command' -and
                (Test-SumiGuardHasParameter -CommandAst $command -Names @('scriptblock'))) {
                $scriptBlockAst = Get-SumiGuardParameterArgumentAst `
                    -CommandAst $command `
                    -Names @('scriptblock')
                if ($null -eq $scriptBlockAst -or
                    $scriptBlockAst -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) {
                    $dynamicExecution = $true
                }
            }
        }

        $findings = New-Object System.Collections.Generic.List[object]
        if ($sg001Detected) {
            $findings.Add((New-SumiGuardFinding `
                -RuleId 'SG-CMD-001' `
                -RuleVersion '1.0.0' `
                -Severity 'HIGH' `
                -ReasonCode 'DOWNLOAD_TO_EXECUTION_FLOW'))
        }
        if ($sg002Detected) {
            $findings.Add((New-SumiGuardFinding `
                -RuleId 'SG-CMD-002' `
                -RuleVersion '1.0.0' `
                -Severity 'HIGH' `
                -ReasonCode 'SECURITY_CONTROL_DISABLE_MUTATION'))
        }
        if ($sg003Detected) {
            $findings.Add((New-SumiGuardFinding `
                -RuleId 'SG-CMD-003' `
                -RuleVersion '1.0.0' `
                -Severity 'MEDIUM' `
                -ReasonCode 'PERSISTENCE_REGISTRATION_MUTATION'))
        }

        if ($findings.Count -gt 0) {
            $partialReason = if ($encodedPayload -or $dynamicExecution) {
                'PARTIAL_UNASSESSABLE'
            }
            else {
                $null
            }
            return New-SumiGuardAssessmentResult `
                -ExecutionId $ExecutionId `
                -Status 'DETECTED' `
                -ReasonCode $partialReason `
                -Findings $findings.ToArray()
        }
        if ($encodedPayload) {
            return New-SumiGuardAssessmentResult `
                -ExecutionId $ExecutionId `
                -Status 'UNASSESSABLE' `
                -ReasonCode 'ENCODED_PAYLOAD_NOT_INSPECTED' `
                -Findings @()
        }
        if ($dynamicExecution) {
            return New-SumiGuardAssessmentResult `
                -ExecutionId $ExecutionId `
                -Status 'UNASSESSABLE' `
                -ReasonCode 'DYNAMIC_COMMAND_TARGET' `
                -Findings @()
        }
        return New-SumiGuardAssessmentResult `
            -ExecutionId $ExecutionId `
            -Status 'NO_DETECTION' `
            -ReasonCode $null `
            -Findings @()
    }
    catch {
        return New-SumiGuardAssessmentResult `
            -ExecutionId $ExecutionId `
            -Status 'EVALUATION_FAILED' `
            -ReasonCode 'RULE_ENGINE_ERROR' `
            -Findings @()
    }
    finally {
        $tokens = $null
        $parseErrors = $null
        $ast = $null
    }
}

Export-ModuleMember -Function @('Invoke-SumiGuardCommandAssessment')
