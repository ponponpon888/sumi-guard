Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Plans the change to a Claude Code settings file that registers or removes the
# SUMI Guard MONITOR hook. Text in, text out: this module reads and writes no
# file, so every decision it makes can be checked on synthetic input.
#
# The hook entry is recognised by its -File argument ending in
# Invoke-SumiGuardMonitorHook.ps1, never by position or by a custom key
# (Claude Code validates settings, so an unknown key could break the file).
# Everything that is not a SUMI Guard monitor hook entry is left as it was;
# Get-SumiGuardClaudeMonitorHookPlan checks that before it returns new text.

$script:HookFilePattern = '(^|[\\/])Invoke-SumiGuardMonitorHook\.ps1$'

function ConvertTo-SumiGuardHookSetupResult {
    param(
        [Parameter(Mandatory = $true)][bool]$Success,
        [Parameter(Mandatory = $true)][string]$Status,
        [Collections.IDictionary]$Properties = @{}
    )

    $result = [ordered]@{
        success = $Success
        status = $Status
    }
    foreach ($key in $Properties.Keys) {
        $result[$key] = $Properties[$key]
    }
    return [pscustomobject]$result
}

function Test-SumiGuardHasProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return @($Object.PSObject.Properties | Where-Object { $_.Name -ceq $Name }).Count -gt 0
}

function Test-SumiGuardJsonObject {
    param([AllowNull()]$Value)

    return ($null -ne $Value -and $Value -is [Management.Automation.PSCustomObject])
}

function Test-SumiGuardJsonArray {
    param([AllowNull()]$Value)

    return ($null -ne $Value -and $Value -is [Array])
}

# True when one hook object is the SUMI Guard monitor hook.
function Test-SumiGuardMonitorHookObject {
    param([AllowNull()]$Hook)

    if (-not (Test-SumiGuardJsonObject -Value $Hook)) { return $false }
    if (-not (Test-SumiGuardHasProperty -Object $Hook -Name 'args')) { return $false }
    $hookArgs = $Hook.args
    if (-not (Test-SumiGuardJsonArray -Value $hookArgs)) { return $false }
    for ($index = 0; $index -lt $hookArgs.Length - 1; $index++) {
        if ($hookArgs[$index] -is [string] -and $hookArgs[$index] -ieq '-File' -and
            $hookArgs[$index + 1] -is [string] -and $hookArgs[$index + 1] -imatch $script:HookFilePattern) {
            return $true
        }
    }
    return $false
}

function ConvertFrom-SumiGuardSettingsText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return [pscustomobject]@{}
    }
    try {
        $parsed = $Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [InvalidOperationException]::new('SETTINGS_INVALID_JSON')
    }
    if (-not (Test-SumiGuardJsonObject -Value $parsed)) {
        throw [InvalidOperationException]::new('SETTINGS_NOT_OBJECT')
    }
    return $parsed
}

# Refuses a hooks section this module would have to guess about.
function Assert-SumiGuardHookShape {
    param([Parameter(Mandatory = $true)]$Settings)

    if (-not (Test-SumiGuardHasProperty -Object $Settings -Name 'hooks')) { return }
    if (-not (Test-SumiGuardJsonObject -Value $Settings.hooks)) {
        throw [InvalidOperationException]::new('HOOKS_SHAPE_UNSUPPORTED')
    }
    if (-not (Test-SumiGuardHasProperty -Object $Settings.hooks -Name 'PreToolUse')) { return }
    $groups = $Settings.hooks.PreToolUse
    if (-not (Test-SumiGuardJsonArray -Value $groups)) {
        throw [InvalidOperationException]::new('HOOKS_SHAPE_UNSUPPORTED')
    }
    foreach ($group in $groups) {
        if (-not (Test-SumiGuardJsonObject -Value $group)) {
            throw [InvalidOperationException]::new('HOOKS_SHAPE_UNSUPPORTED')
        }
        if ((Test-SumiGuardHasProperty -Object $group -Name 'hooks') -and
            -not (Test-SumiGuardJsonArray -Value $group.hooks)) {
            throw [InvalidOperationException]::new('HOOKS_SHAPE_UNSUPPORTED')
        }
    }
}

# Removes every SUMI Guard monitor hook object in place. A matcher group left
# with no hooks by that removal is dropped, and so are a PreToolUse array and a
# hooks object left empty by it. Returns how many hook objects were removed.
function Clear-SumiGuardMonitorHookObject {
    param([Parameter(Mandatory = $true)]$Settings)

    if (-not (Test-SumiGuardHasProperty -Object $Settings -Name 'hooks')) { return 0 }
    if (-not (Test-SumiGuardHasProperty -Object $Settings.hooks -Name 'PreToolUse')) { return 0 }
    $removed = 0
    $keptGroups = New-Object System.Collections.Generic.List[object]
    foreach ($group in $Settings.hooks.PreToolUse) {
        if (-not (Test-SumiGuardHasProperty -Object $group -Name 'hooks')) {
            $keptGroups.Add($group)
            continue
        }
        $keptHooks = New-Object System.Collections.Generic.List[object]
        $removedHere = 0
        foreach ($hook in $group.hooks) {
            if (Test-SumiGuardMonitorHookObject -Hook $hook) {
                $removedHere++
            }
            else {
                $keptHooks.Add($hook)
            }
        }
        $removed += $removedHere
        if ($removedHere -gt 0 -and $keptHooks.Count -eq 0) {
            continue
        }
        if ($removedHere -gt 0) {
            $group.hooks = [object[]]$keptHooks.ToArray()
        }
        $keptGroups.Add($group)
    }
    if ($removed -eq 0) { return 0 }
    if ($keptGroups.Count -eq 0) {
        $Settings.hooks.PSObject.Properties.Remove('PreToolUse')
        if (@($Settings.hooks.PSObject.Properties).Count -eq 0) {
            $Settings.PSObject.Properties.Remove('hooks')
        }
    }
    else {
        $Settings.hooks.PreToolUse = [object[]]$keptGroups.ToArray()
    }
    return $removed
}

# Compact JSON of everything except SUMI Guard monitor hooks, with an empty
# PreToolUse array or hooks object dropped. Two settings texts with the same
# value here differ only in the SUMI Guard entry.
function Get-SumiGuardSettingsFingerprint {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $settings = ConvertFrom-SumiGuardSettingsText -Text $Text
    $null = Clear-SumiGuardMonitorHookObject -Settings $settings
    if (Test-SumiGuardHasProperty -Object $settings -Name 'hooks') {
        if ((Test-SumiGuardHasProperty -Object $settings.hooks -Name 'PreToolUse') -and
            @($settings.hooks.PreToolUse).Count -eq 0) {
            $settings.hooks.PSObject.Properties.Remove('PreToolUse')
        }
        if (@($settings.hooks.PSObject.Properties).Count -eq 0) {
            $settings.PSObject.Properties.Remove('hooks')
        }
    }
    return ($settings | ConvertTo-Json -Depth 100 -Compress)
}

function Get-SumiGuardMonitorHookEntry {
    param([Parameter(Mandatory = $true)]$Settings)

    $entries = New-Object System.Collections.Generic.List[object]
    if (-not (Test-SumiGuardHasProperty -Object $Settings -Name 'hooks')) { return ,$entries.ToArray() }
    if (-not (Test-SumiGuardHasProperty -Object $Settings.hooks -Name 'PreToolUse')) { return ,$entries.ToArray() }
    foreach ($group in $Settings.hooks.PreToolUse) {
        if (-not (Test-SumiGuardHasProperty -Object $group -Name 'hooks')) { continue }
        foreach ($hook in $group.hooks) {
            if (Test-SumiGuardMonitorHookObject -Hook $hook) {
                $matcher = $null
                if (Test-SumiGuardHasProperty -Object $group -Name 'matcher') { $matcher = $group.matcher }
                $entries.Add([pscustomobject]@{ matcher = $matcher; hook = $hook })
            }
        }
    }
    return ,$entries.ToArray()
}

function Get-SumiGuardClaudeMonitorHookPlan {
    <#
    .SYNOPSIS
    Plans registering or removing the SUMI Guard MONITOR hook in Claude Code settings text.
    .DESCRIPTION
    Returns the planned status and, when the file must change, the new settings
    text. Reads and writes nothing. Before returning new text it checks that
    everything other than the SUMI Guard monitor hook entry is unchanged.
    .PARAMETER Action
    Install or Uninstall.
    .PARAMETER SettingsText
    Current settings file content without a BOM. An empty string means the file
    does not exist yet.
    .PARAMETER PowerShellPath
    The Windows PowerShell 5.1 executable the hook entry starts (Install).
    .PARAMETER HookArguments
    The complete args array for the hook entry (Install). It must contain -File
    followed by the path of Invoke-SumiGuardMonitorHook.ps1.
    .PARAMETER Matcher
    The PreToolUse matcher for the entry (Install).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Install', 'Uninstall')][string]$Action,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SettingsText,
        [string]$PowerShellPath,
        [string[]]$HookArguments = @(),
        [string]$Matcher = 'PowerShell'
    )

    try {
        $settings = ConvertFrom-SumiGuardSettingsText -Text $SettingsText
        Assert-SumiGuardHookShape -Settings $settings
        $existing = Get-SumiGuardMonitorHookEntry -Settings $settings

        if ($Action -ceq 'Uninstall') {
            if ($existing.Length -eq 0) {
                return ConvertTo-SumiGuardHookSetupResult -Success $true -Status 'NOT_INSTALLED' -Properties ([ordered]@{
                    change_required = $false
                    entries_before = 0
                    new_text = $null
                })
            }
            $removed = Clear-SumiGuardMonitorHookObject -Settings $settings
            $newText = $settings | ConvertTo-Json -Depth 100
        }
        else {
            $desiredHook = [pscustomobject][ordered]@{
                type = 'command'
                command = $PowerShellPath
                args = [object[]]$HookArguments
            }
            if ([string]::IsNullOrWhiteSpace($PowerShellPath) -or
                -not (Test-SumiGuardMonitorHookObject -Hook $desiredHook)) {
                return ConvertTo-SumiGuardHookSetupResult -Success $false -Status 'HOOK_ENTRY_INVALID' -Properties ([ordered]@{
                    change_required = $false
                    new_text = $null
                })
            }
            $desiredJson = $desiredHook | ConvertTo-Json -Depth 10 -Compress
            if ($existing.Length -eq 1 -and $existing[0].matcher -ceq $Matcher -and
                ($existing[0].hook | ConvertTo-Json -Depth 10 -Compress) -ceq $desiredJson) {
                return ConvertTo-SumiGuardHookSetupResult -Success $true -Status 'ALREADY_INSTALLED' -Properties ([ordered]@{
                    change_required = $false
                    entries_before = 1
                    new_text = $null
                })
            }
            $removed = Clear-SumiGuardMonitorHookObject -Settings $settings
            if (-not (Test-SumiGuardHasProperty -Object $settings -Name 'hooks')) {
                $settings | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([pscustomobject]@{})
            }
            $group = [pscustomobject][ordered]@{
                matcher = $Matcher
                hooks = [object[]]@($desiredHook)
            }
            if (Test-SumiGuardHasProperty -Object $settings.hooks -Name 'PreToolUse') {
                $settings.hooks.PreToolUse = [object[]](@($settings.hooks.PreToolUse) + @($group))
            }
            else {
                $settings.hooks | Add-Member -NotePropertyName 'PreToolUse' -NotePropertyValue ([object[]]@($group))
            }
            $newText = $settings | ConvertTo-Json -Depth 100
        }

        # The one invariant this module promises: outside the SUMI Guard entry,
        # the settings value is unchanged.
        if ((Get-SumiGuardSettingsFingerprint -Text $SettingsText) -cne
            (Get-SumiGuardSettingsFingerprint -Text $newText)) {
            return ConvertTo-SumiGuardHookSetupResult -Success $false -Status 'PRESERVATION_CHECK_FAILED' -Properties ([ordered]@{
                change_required = $false
                new_text = $null
            })
        }
        $after = Get-SumiGuardMonitorHookEntry -Settings (ConvertFrom-SumiGuardSettingsText -Text $newText)
        $expectedAfter = if ($Action -ceq 'Install') { 1 } else { 0 }
        if ($after.Length -ne $expectedAfter) {
            return ConvertTo-SumiGuardHookSetupResult -Success $false -Status 'PLAN_CHECK_FAILED' -Properties ([ordered]@{
                change_required = $false
                new_text = $null
            })
        }

        $status = 'REMOVE'
        if ($Action -ceq 'Install') {
            $status = if ($existing.Length -eq 0) { 'INSTALL' } else { 'UPDATE' }
        }
        return ConvertTo-SumiGuardHookSetupResult -Success $true -Status $status -Properties ([ordered]@{
            change_required = $true
            entries_before = $existing.Length
            entries_removed = [int]$removed
            new_text = $newText
        })
    }
    catch {
        $code = $_.Exception.Message
        if ($code -cnotin @('SETTINGS_INVALID_JSON', 'SETTINGS_NOT_OBJECT', 'HOOKS_SHAPE_UNSUPPORTED')) {
            $code = 'PLAN_FAILED'
        }
        return ConvertTo-SumiGuardHookSetupResult -Success $false -Status $code -Properties ([ordered]@{
            change_required = $false
            new_text = $null
        })
    }
}

Export-ModuleMember -Function @('Get-SumiGuardClaudeMonitorHookPlan')
