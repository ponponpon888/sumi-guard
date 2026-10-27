Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Operator-owned control plane for ENFORCE_RECORDING (docs/26, docs/36).
#
# - Get-SumiGuardEnforcementSetting reads the operator's setting and turns
#   every doubt into MONITOR: no directory, no file, kill switch, loose ACL,
#   reparse point, oversize, unknown key, bad value, read error.
# - Write-SumiGuardEnforcementNotice appends one fixed-field line to a
#   notice file that is separate from the recording stores. It never throws
#   and its result never changes a decision.
# - Initialize-SumiGuardEnforcementControlDirectory creates the restricted
#   directory. It never writes a setting: turning enforcement on stays a
#   manual operator step.
#
# Nothing here registers a hook, emits a host response, executes a command
# or touches the recording stores.

$script:SchemaVersion = 1
$script:ConfigFileName = 'enforcement.json'
$script:KillSwitchName = 'ENFORCEMENT_OFF'
$script:NoticeFileName = 'enforcement-notices.ndjson'
$script:MarkerFileName = '.sumi-guard-enforcement-control.json'
$script:MaxConfigBytes = 16KB
$script:MaxNoticeBytes = 1MB
$script:MaxRoutes = 16
$script:DefaultLockTimeoutMilliseconds = 2000
$script:MinLockTimeoutMilliseconds = 100
$script:MaxLockTimeoutMilliseconds = 10000
$script:NoticeLockAttempts = 20
$script:NoticeLockWaitMilliseconds = 25
# host:event:tool, for example claude-code:PreToolUse:Bash
$script:RoutePattern = '^[a-z0-9-]{1,32}:[A-Za-z]{1,32}:[A-Za-z0-9_]{1,64}$'
$script:ReasonPattern = '^[A-Z][A-Z_]{0,63}$'
$script:ExecutionIdPattern = '^[0-9a-f]{32}$'
$script:AllowedConfigKeys = @('schema_version', 'mode', 'routes', 'lock_timeout_milliseconds')
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$script:SystemSid = 'S-1-5-18'

function ConvertTo-SumiGuardSettingResult {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$RequestedMode = 'MONITOR',
        [bool]$RouteAllowlisted = $false,
        [bool]$KillSwitchActive = $false,
        [int]$LockTimeoutMilliseconds = $script:DefaultLockTimeoutMilliseconds,
        [int]$ConfiguredRouteCount = 0
    )

    return [pscustomobject][ordered]@{
        schema_version = $script:SchemaVersion
        setting_status = $Status
        requested_mode = $RequestedMode
        route_allowlisted = $RouteAllowlisted
        kill_switch_active = $KillSwitchActive
        lock_timeout_milliseconds = $LockTimeoutMilliseconds
        configured_route_count = $ConfiguredRouteCount
    }
}

function ConvertTo-SumiGuardNoticeResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Persisted,
        # Untyped: a [string] parameter would turn $null into an empty string.
        [AllowNull()]$FailureCode
    )

    $status = if ($Persisted) { 'NOTICE_PERSISTED' } else { 'NOTICE_NOT_PERSISTED' }
    return [pscustomobject][ordered]@{
        notice_status = $status
        failure_code = $FailureCode
    }
}

function Test-SumiGuardControlReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Test-SumiGuardControlPathContainsReparsePoint {
    param([Parameter(Mandatory = $true)][string]$Path)

    $current = [System.IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            if (Test-SumiGuardControlReparsePoint -Path $current) {
                return $true
            }
        }
        $parent = [System.IO.Path]::GetDirectoryName($current)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
    return $false
}

# True when every rule is an Allow for the current user or SYSTEM, and both
# hold full control through some rule. With -RequireProtected, inheritance
# from the parent must also be cut.
function Test-SumiGuardControlAcl {
    param(
        [Parameter(Mandatory = $true)]$Security,
        [switch]$RequireProtected,
        [switch]$RequireOwnFullControl
    )

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $rules = @($Security.GetAccessRules(
        $true,
        $true,
        [System.Security.Principal.SecurityIdentifier]))
    if ($rules.Count -eq 0) {
        return $false
    }
    $userFull = $false
    $systemFull = $false
    foreach ($rule in $rules) {
        $sid = $rule.IdentityReference.Value
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
            return $false
        }
        if ($sid -cne $currentSid -and $sid -cne $script:SystemSid) {
            return $false
        }
        $full = (($rule.FileSystemRights -band
            [System.Security.AccessControl.FileSystemRights]::FullControl) -eq
            [System.Security.AccessControl.FileSystemRights]::FullControl)
        if ($full -and $sid -ceq $currentSid) { $userFull = $true }
        if ($full -and $sid -ceq $script:SystemSid) { $systemFull = $true }
    }
    if ($RequireProtected -and -not $Security.AreAccessRulesProtected) {
        return $false
    }
    if ($RequireOwnFullControl -and -not ($userFull -and $systemFull)) {
        return $false
    }
    return $true
}

function Protect-SumiGuardControlDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier($script:SystemSid)
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    foreach ($sid in @($currentSid, $systemSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        [void]$security.AddAccessRule($rule)
    }
    $directory = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $directory.SetAccessControl($security)
}

# Returns $null when the directory is usable, otherwise a fixed status code.
function Get-SumiGuardControlDirectoryProblem {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (Test-SumiGuardControlPathContainsReparsePoint -Path $Path) {
        return 'CONTROL_DIRECTORY_INVALID'
    }
    $markerPath = Join-Path $Path $script:MarkerFileName
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        return 'CONTROL_DIRECTORY_INVALID'
    }
    $directory = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $security = $directory.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
    if (-not (Test-SumiGuardControlAcl -Security $security -RequireProtected -RequireOwnFullControl)) {
        return 'CONTROL_DIRECTORY_ACL_NOT_RESTRICTED'
    }
    return $null
}

function Resolve-SumiGuardControlPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        throw [System.ArgumentException]::new('The control directory must be an absolute path.')
    }
    return [System.IO.Path]::GetFullPath($Path).TrimEnd([char[]]@('\', '/'))
}

function Initialize-SumiGuardEnforcementControlDirectory {
    <#
    .SYNOPSIS
    Creates the operator's enforcement control directory, restricted to the
    current user and SYSTEM. Never writes a setting and never adopts an
    existing directory.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $resolved = Resolve-SumiGuardControlPath -Path $Path
    }
    catch {
        return [pscustomobject][ordered]@{ success = $false; status = 'INVALID_CONTROL_DIRECTORY_PATH' }
    }

    try {
        if (Test-Path -LiteralPath $resolved) {
            if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
                return [pscustomobject][ordered]@{ success = $false; status = 'CONTROL_PATH_NOT_DIRECTORY' }
            }
            $problem = Get-SumiGuardControlDirectoryProblem -Path $resolved
            if ($null -ne $problem) {
                # An existing directory is never re-permissioned or adopted.
                return [pscustomobject][ordered]@{ success = $false; status = 'EXISTING_DIRECTORY_NOT_VALID_CONTROL_DIRECTORY' }
            }
            return [pscustomobject][ordered]@{ success = $true; status = 'READY' }
        }

        $parent = [System.IO.Path]::GetDirectoryName($resolved)
        if ([string]::IsNullOrEmpty($parent) -or
            (Test-SumiGuardControlPathContainsReparsePoint -Path $parent)) {
            return [pscustomobject][ordered]@{ success = $false; status = 'REPARSE_PATH_NOT_ALLOWED' }
        }
        [void](New-Item -ItemType Directory -Path $resolved -ErrorAction Stop)
        Protect-SumiGuardControlDirectory -Path $resolved
        $marker = [ordered]@{
            schema_version = $script:SchemaVersion
            purpose = 'SUMI Guard enforcement control directory'
        } | ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText((Join-Path $resolved $script:MarkerFileName), $marker, $script:Utf8Strict)
        $problem = Get-SumiGuardControlDirectoryProblem -Path $resolved
        if ($null -ne $problem) {
            return [pscustomobject][ordered]@{ success = $false; status = 'ACL_RESTRICTION_FAILED' }
        }
        return [pscustomobject][ordered]@{ success = $true; status = 'CREATED' }
    }
    catch {
        return [pscustomobject][ordered]@{ success = $false; status = 'CONTROL_DIRECTORY_CREATE_FAILED' }
    }
}

function Test-SumiGuardIntegralValue {
    param([AllowNull()]$Value)

    return ($Value -is [int] -or $Value -is [long])
}

function Get-SumiGuardEnforcementSetting {
    <#
    .SYNOPSIS
    Reads the operator's enforcement setting for one route. Any doubt,
    including the ENFORCEMENT_OFF kill switch, yields requested_mode MONITOR.
    Never throws.
    #>
    [CmdletBinding()]
    param(
        # Operator-owned directory, for example %LOCALAPPDATA%\SumiGuard\enforcement.
        # Never derived from hook input or repository content.
        [Parameter(Mandatory = $true)][string]$ControlDirectory,
        # host:event:tool of the hook being evaluated.
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RouteId
    )

    try {
        if ($RouteId -cnotmatch $script:RoutePattern) {
            return ConvertTo-SumiGuardSettingResult -Status 'INVALID_ROUTE_ID'
        }
        try {
            $resolved = Resolve-SumiGuardControlPath -Path $ControlDirectory
        }
        catch {
            return ConvertTo-SumiGuardSettingResult -Status 'CONTROL_DIRECTORY_INVALID'
        }
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_ABSENT'
        }

        # The kill switch is checked before anything can fail: its presence,
        # as a file or a directory, always wins.
        if (Test-Path -LiteralPath (Join-Path $resolved $script:KillSwitchName)) {
            return ConvertTo-SumiGuardSettingResult -Status 'KILL_SWITCH_ACTIVE' -KillSwitchActive $true
        }

        $problem = Get-SumiGuardControlDirectoryProblem -Path $resolved
        if ($null -ne $problem) {
            return ConvertTo-SumiGuardSettingResult -Status $problem
        }

        $configPath = Join-Path $resolved $script:ConfigFileName
        if (-not (Test-Path -LiteralPath $configPath)) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_ABSENT'
        }
        if (-not (Test-Path -LiteralPath $configPath -PathType Leaf) -or
            (Test-SumiGuardControlReparsePoint -Path $configPath)) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
        }
        $file = Get-Item -LiteralPath $configPath -Force -ErrorAction Stop
        if ($file.Length -gt $script:MaxConfigBytes) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_TOO_LARGE'
        }
        $fileSecurity = $file.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        if (-not (Test-SumiGuardControlAcl -Security $fileSecurity)) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_ACL_NOT_RESTRICTED'
        }

        try {
            [byte[]]$bytes = [System.IO.File]::ReadAllBytes($configPath)
            $offset = 0
            if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
                $offset = 3
            }
            $text = $script:Utf8Strict.GetString($bytes, $offset, $bytes.Length - $offset)
            $config = $text | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
        }

        if ($null -eq $config -or $config -isnot [System.Management.Automation.PSCustomObject]) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
        }
        $keys = @($config.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($key in $keys) {
            if ($script:AllowedConfigKeys -cnotcontains $key) {
                return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
            }
        }
        if ($keys -cnotcontains 'schema_version' -or $keys -cnotcontains 'mode' -or $keys -cnotcontains 'routes') {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
        }
        if (-not (Test-SumiGuardIntegralValue -Value $config.schema_version) -or
            $config.schema_version -ne $script:SchemaVersion) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
        }
        if ($config.mode -isnot [string] -or
            ($config.mode -cne 'MONITOR' -and $config.mode -cne 'ENFORCE_RECORDING')) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
        }
        if ($config.routes -isnot [System.Array]) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
        }
        $routes = @($config.routes)
        if ($routes.Count -gt $script:MaxRoutes) {
            return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
        }
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($route in $routes) {
            if ($route -isnot [string] -or $route -cnotmatch $script:RoutePattern -or -not $seen.Add($route)) {
                return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
            }
        }
        $lockTimeout = $script:DefaultLockTimeoutMilliseconds
        if ($keys -ccontains 'lock_timeout_milliseconds') {
            $value = $config.lock_timeout_milliseconds
            if (-not (Test-SumiGuardIntegralValue -Value $value) -or
                $value -lt $script:MinLockTimeoutMilliseconds -or
                $value -gt $script:MaxLockTimeoutMilliseconds) {
                return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_INVALID'
            }
            $lockTimeout = [int]$value
        }

        return ConvertTo-SumiGuardSettingResult `
            -Status 'CONFIG_LOADED' `
            -RequestedMode $config.mode `
            -RouteAllowlisted ($seen.Contains($RouteId)) `
            -LockTimeoutMilliseconds $lockTimeout `
            -ConfiguredRouteCount $routes.Count
    }
    catch {
        return ConvertTo-SumiGuardSettingResult -Status 'CONFIG_UNREADABLE'
    }
}

function Get-SumiGuardNoticeActionHint {
    param([Parameter(Mandatory = $true)][string]$ReasonCode)

    switch -CaseSensitive ($ReasonCode) {
        'STORE_CAPACITY_REACHED' { return 'RUN_RETENTION_CLEANUP' }
        'LOCK_TIMEOUT' { return 'RETRY_LATER' }
        'STORE_VALIDATION_FAILED' { return 'CHECK_STORE_ACL' }
    }
    return $null
}

function Write-SumiGuardEnforcementNotice {
    <#
    .SYNOPSIS
    Appends one fixed-field notice line to the control directory. Never
    throws; the result must not change an enforcement decision.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ControlDirectory,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$RouteId,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Decision,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ReasonCode,
        [AllowEmptyString()][string]$ExecutionId = ''
    )

    try {
        if ($RouteId -cnotmatch $script:RoutePattern -or
            ($Decision -cne 'ALLOW' -and $Decision -cne 'DENY') -or
            $ReasonCode -cnotmatch $script:ReasonPattern -or
            ($ExecutionId -ne '' -and $ExecutionId -cnotmatch $script:ExecutionIdPattern)) {
            return ConvertTo-SumiGuardNoticeResult -Persisted $false -FailureCode 'INVALID_NOTICE_FIELD'
        }
        try {
            $resolved = Resolve-SumiGuardControlPath -Path $ControlDirectory
        }
        catch {
            return ConvertTo-SumiGuardNoticeResult -Persisted $false -FailureCode 'CONTROL_DIRECTORY_INVALID'
        }
        if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
            return ConvertTo-SumiGuardNoticeResult -Persisted $false -FailureCode 'CONTROL_DIRECTORY_INVALID'
        }
        $problem = Get-SumiGuardControlDirectoryProblem -Path $resolved
        if ($null -ne $problem) {
            return ConvertTo-SumiGuardNoticeResult -Persisted $false -FailureCode $problem
        }

        $executionValue = $null
        if ($ExecutionId -ne '') {
            $executionValue = $ExecutionId
        }
        $line = ([ordered]@{
            schema_version = $script:SchemaVersion
            recorded_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            route_id = $RouteId
            decision = $Decision
            reason_code = $ReasonCode
            execution_id = $executionValue
            action_hint = (Get-SumiGuardNoticeActionHint -ReasonCode $ReasonCode)
        } | ConvertTo-Json -Compress) + "`n"
        [byte[]]$lineBytes = $script:Utf8Strict.GetBytes($line)

        $noticePath = Join-Path $resolved $script:NoticeFileName
        if (Test-Path -LiteralPath $noticePath) {
            if (-not (Test-Path -LiteralPath $noticePath -PathType Leaf) -or
                (Test-SumiGuardControlReparsePoint -Path $noticePath)) {
                return ConvertTo-SumiGuardNoticeResult -Persisted $false -FailureCode 'NOTICE_FILE_INVALID'
            }
        }

        for ($attempt = 1; $attempt -le $script:NoticeLockAttempts; $attempt++) {
            $stream = $null
            try {
                $stream = New-Object System.IO.FileStream(
                    $noticePath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::Read)
            }
            catch {
                # A sharing violation arrives wrapped by the method call.
                # Only that is waited out; anything else ends the attempt.
                $cause = $_.Exception
                if ($cause -isnot [System.IO.IOException] -and
                    $cause.InnerException -isnot [System.IO.IOException]) {
                    throw
                }
                $stream = $null
            }
            if ($null -eq $stream) {
                Start-Sleep -Milliseconds $script:NoticeLockWaitMilliseconds
                continue
            }
            try {
                if (($stream.Length + $lineBytes.Length) -gt $script:MaxNoticeBytes) {
                    return ConvertTo-SumiGuardNoticeResult -Persisted $false -FailureCode 'NOTICE_FILE_FULL'
                }
                $stream.Write($lineBytes, 0, $lineBytes.Length)
                $stream.Flush()
                return ConvertTo-SumiGuardNoticeResult -Persisted $true -FailureCode $null
            }
            finally {
                $stream.Dispose()
            }
        }
        return ConvertTo-SumiGuardNoticeResult -Persisted $false -FailureCode 'NOTICE_LOCK_TIMEOUT'
    }
    catch {
        return ConvertTo-SumiGuardNoticeResult -Persisted $false -FailureCode 'NOTICE_WRITE_FAILED'
    }
}

Export-ModuleMember -Function @(
    'Initialize-SumiGuardEnforcementControlDirectory',
    'Get-SumiGuardEnforcementSetting',
    'Write-SumiGuardEnforcementNotice'
)
