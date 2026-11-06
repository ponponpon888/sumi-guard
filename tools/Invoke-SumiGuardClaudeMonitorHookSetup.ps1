[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Uninstall')]
    [string]$Action,

    # The Claude Code settings file to change, named explicitly: for example
    # <project>\.claude\settings.local.json or %USERPROFILE%\.claude\settings.json.
    # Its folder must already exist.
    [Parameter(Mandatory = $true)][string]$SettingsPath,

    # Install only. The folder that holds execution-store, body-store and
    # assessment-store.
    [string]$StoreRoot,

    # Install only. Create the stores that are missing through each module's
    # public initialiser. Without it, missing stores stop the install.
    [switch]$InitializeStores,

    # Install only. Defaults to Windows PowerShell 5.1.
    [string]$PowerShellPath
)

# Registers (Install) or removes (Uninstall) the SUMI Guard MONITOR hook for
# Claude Code's PowerShell tool in one settings file.
#
# - Only the SUMI Guard monitor hook entry is touched. Everything else in the
#   file is checked to be unchanged before anything is written.
# - Running Install twice changes nothing the second time.
# - A changed file is first copied to <name>.sumi-guard-backup-<UTC time>
#   beside it. The new content is written to a temporary file and swapped in,
#   then read back and compared; on a mismatch the original is restored.
# - Never registers the enforcement hook, never deletes a store or a record.
# - -WhatIf reports what would happen and writes nothing.
#
# Standard output is one JSON summary with fixed codes: no path, no setting
# value. Exit codes: 0 = done or nothing to do, 1 = refused or failed.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$srcRoot = Join-Path $projectRoot 'src'
$hookScript = [IO.Path]::GetFullPath((Join-Path (Join-Path $projectRoot 'hooks') 'Invoke-SumiGuardMonitorHook.ps1'))
$setupManifest = Join-Path (Join-Path $srcRoot 'SumiGuard.HookSetup') 'SumiGuard.HookSetup.psd1'
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$stores = @(
    [pscustomobject]@{ kind = 'execution'; folder = 'execution-store'; marker = '.sumi-guard-execution-store.json' },
    [pscustomobject]@{ kind = 'body'; folder = 'body-store'; marker = '.sumi-guard-store.json' },
    [pscustomobject]@{ kind = 'assessment'; folder = 'assessment-store'; marker = '.sumi-guard-assessment-store.json' }
)

function Write-SumiGuardSetupSummary {
    param(
        [Parameter(Mandatory = $true)][string]$Status,
        [System.Collections.IDictionary]$Extra = @{},
        [int]$ExitCode = 1
    )

    $summary = [ordered]@{
        action = $Action
        status = $Status
        what_if = [bool]$WhatIfPreference
        hook_mode = 'MONITOR'
    }
    foreach ($key in $Extra.Keys) { $summary[$key] = $Extra[$key] }
    $summary['enforcement_hook_registered'] = $false
    $summary['stores_deleted'] = $false
    [pscustomobject]$summary | ConvertTo-Json -Depth 4 -Compress
    exit $ExitCode
}

function Test-SumiGuardLinkPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $current = $root
    foreach ($segment in $fullPath.Substring($root.Length).Split(
        [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar),
        [StringSplitOptions]::RemoveEmptyEntries)) {
        $current = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $current)) { continue }
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    }
    return $false
}

function Read-SumiGuardSettingsFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ exists = $false; bytes = $null; text = '' }
    }
    [byte[]]$bytes = [IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3
    }
    try {
        $text = $utf8.GetString($bytes, $offset, $bytes.Length - $offset)
    }
    catch {
        throw [InvalidOperationException]::new('SETTINGS_NOT_UTF8')
    }
    return [pscustomobject]@{ exists = $true; bytes = $bytes; text = $text }
}

function Test-SumiGuardSameContent {
    param([AllowNull()][byte[]]$Left, [AllowNull()][byte[]]$Right)

    if ($null -eq $Left -or $null -eq $Right) { return ($null -eq $Left -and $null -eq $Right) }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Write-SumiGuardNewFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

# --- Validate the target ---------------------------------------------------
try {
    $settingsFull = [IO.Path]::GetFullPath($SettingsPath)
}
catch {
    Write-SumiGuardSetupSummary -Status 'SETTINGS_PATH_INVALID'
}
$settingsDirectory = Split-Path -Parent $settingsFull
if ([string]::IsNullOrEmpty($settingsDirectory) -or -not (Test-Path -LiteralPath $settingsDirectory -PathType Container)) {
    Write-SumiGuardSetupSummary -Status 'SETTINGS_DIRECTORY_MISSING'
}
if (Test-Path -LiteralPath $settingsFull -PathType Container) {
    Write-SumiGuardSetupSummary -Status 'SETTINGS_PATH_INVALID'
}
if (Test-SumiGuardLinkPath -Path $settingsFull) {
    Write-SumiGuardSetupSummary -Status 'SETTINGS_PATH_IS_LINK'
}
if (-not (Test-Path -LiteralPath $hookScript -PathType Leaf)) {
    Write-SumiGuardSetupSummary -Status 'HOOK_SCRIPT_MISSING'
}
try {
    Import-Module -Name $setupManifest -Force -ErrorAction Stop
}
catch {
    Write-SumiGuardSetupSummary -Status 'MODULE_LOAD_FAILED'
}

# --- Hook entry (Install) --------------------------------------------------
$hookArguments = @()
$resolvedPowerShell = $null
$storesInitialized = @()
if ($Action -ceq 'Install') {
    if ([string]::IsNullOrWhiteSpace($StoreRoot)) {
        Write-SumiGuardSetupSummary -Status 'STORE_ROOT_REQUIRED'
    }
    $storeRootFull = [IO.Path]::GetFullPath($StoreRoot)
    if (Test-SumiGuardLinkPath -Path $storeRootFull) {
        Write-SumiGuardSetupSummary -Status 'STORE_ROOT_IS_LINK'
    }
    $resolvedPowerShell = $PowerShellPath
    if ([string]::IsNullOrWhiteSpace($resolvedPowerShell)) {
        $systemRoot = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { 'C:\Windows' } else { $env:SystemRoot }
        $resolvedPowerShell = $systemRoot + '\System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    if ($onWindows -and -not (Test-Path -LiteralPath $resolvedPowerShell -PathType Leaf)) {
        Write-SumiGuardSetupSummary -Status 'POWERSHELL_NOT_FOUND'
    }
    # The registration verified on 2026-10-20 (docs/28): exec form with args so
    # Claude Code does not route through Git Bash, CLAUDE_PRETOOLUSE profile, no
    # trusted-route declaration and no body capture.
    $hookArguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $hookScript,
        '-HookInputProfile', 'CLAUDE_PRETOOLUSE',
        '-ExecutionStorePath', (Join-Path $storeRootFull 'execution-store'),
        '-LocalStorePath', (Join-Path $storeRootFull 'body-store'),
        '-AssessmentStorePath', (Join-Path $storeRootFull 'assessment-store')
    )
}

# --- Plan ------------------------------------------------------------------
try {
    $before = Read-SumiGuardSettingsFile -Path $settingsFull
}
catch {
    Write-SumiGuardSetupSummary -Status 'SETTINGS_NOT_UTF8'
}
$plan = SumiGuard.HookSetup\Get-SumiGuardClaudeMonitorHookPlan `
    -Action $Action `
    -SettingsText $before.text `
    -PowerShellPath $resolvedPowerShell `
    -HookArguments $hookArguments
$common = [ordered]@{
    settings_existed = [bool]$before.exists
    stores_initialized = @($storesInitialized)
}
if (-not $plan.success) {
    Write-SumiGuardSetupSummary -Status $plan.status -Extra $common
}

# --- Stores (Install) -------------------------------------------------------
# Checked after the plan so a settings file that cannot be changed never
# leaves newly created stores behind.
if ($Action -ceq 'Install') {
    $missing = @($stores | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path (Join-Path $storeRootFull $_.folder) $_.marker) -PathType Leaf) })
    if ($missing.Count -gt 0) {
        if (-not $InitializeStores) {
            Write-SumiGuardSetupSummary -Status 'STORES_NOT_READY' -Extra ([ordered]@{
                settings_existed = [bool]$before.exists
                missing_stores = @($missing | ForEach-Object { $_.kind })
            })
        }
        if (-not $onWindows) {
            Write-SumiGuardSetupSummary -Status 'STORE_INIT_REQUIRES_WINDOWS'
        }
        if ($PSCmdlet.ShouldProcess('SUMI Guard stores', 'Initialize')) {
            try {
                if (-not (Test-Path -LiteralPath $storeRootFull -PathType Container)) {
                    $null = New-Item -ItemType Directory -Path $storeRootFull -ErrorAction Stop
                }
                Import-Module -Name (Join-Path (Join-Path $srcRoot 'SumiGuard.LocalStore') 'SumiGuard.LocalStore.psd1') -Force -ErrorAction Stop
                Import-Module -Name (Join-Path (Join-Path $srcRoot 'SumiGuard.ExecutionAdapter') 'SumiGuard.ExecutionAdapter.psd1') -Force -ErrorAction Stop
                Import-Module -Name (Join-Path (Join-Path $srcRoot 'SumiGuard.AssessmentStore') 'SumiGuard.AssessmentStore.psd1') -Force -ErrorAction Stop
                foreach ($store in $missing) {
                    $path = Join-Path $storeRootFull $store.folder
                    $init = switch ($store.kind) {
                        'body' { SumiGuard.LocalStore\Initialize-SumiGuardLocalStore -Path $path }
                        'execution' { SumiGuard.ExecutionAdapter\Initialize-SumiGuardExecutionStore -Path $path }
                        'assessment' { SumiGuard.AssessmentStore\New-SumiGuardAssessmentStore -StorePath $path }
                    }
                    if ($null -eq $init -or -not $init.success) {
                        $code = if ($null -ne $init) { [string]$init.status } else { 'NO_RESULT' }
                        Write-SumiGuardSetupSummary -Status 'STORE_INIT_FAILED' -Extra ([ordered]@{
                            store = $store.kind
                            store_status = $code
                        })
                    }
                    $storesInitialized += $store.kind
                }
            }
            catch {
                Write-SumiGuardSetupSummary -Status 'STORE_INIT_FAILED'
            }
        }
    }

}
$common['stores_initialized'] = @($storesInitialized)
if (-not $plan.change_required) {
    Write-SumiGuardSetupSummary -Status $plan.status -Extra $common -ExitCode 0
}
$doneStatus = switch ($plan.status) {
    'INSTALL' { 'INSTALLED' }
    'UPDATE' { 'UPDATED' }
    'REMOVE' { 'REMOVED' }
}
if (-not $PSCmdlet.ShouldProcess('Claude Code settings file', $Action + ' SUMI Guard monitor hook')) {
    $common['planned_status'] = $doneStatus
    Write-SumiGuardSetupSummary -Status 'WHATIF' -Extra $common -ExitCode 0
}

# --- Write -----------------------------------------------------------------
[byte[]]$newBytes = $utf8.GetBytes($plan.new_text.Replace("`r`n", "`n") + "`n")
$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ', [Globalization.CultureInfo]::InvariantCulture)
$settingsLeaf = Split-Path -Leaf $settingsFull
$backupName = $null
$backupPath = $null
$temporaryPath = Join-Path $settingsDirectory ('.sumi-guard-settings-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    if ($before.exists) {
        $backupName = $settingsLeaf + '.sumi-guard-backup-' + $stamp
        $backupPath = Join-Path $settingsDirectory $backupName
        try {
            Write-SumiGuardNewFile -Path $backupPath -Bytes $before.bytes
        }
        catch {
            $backupPath = $null
            Write-SumiGuardSetupSummary -Status 'BACKUP_FAILED' -Extra $common
        }
    }

    # Claude Code also writes this file. Refuse if it changed after it was read.
    $recheck = Read-SumiGuardSettingsFile -Path $settingsFull
    if ($recheck.exists -ne $before.exists -or -not (Test-SumiGuardSameContent -Left $recheck.bytes -Right $before.bytes)) {
        if ($null -ne $backupPath) { [IO.File]::Delete($backupPath) }
        Write-SumiGuardSetupSummary -Status 'SETTINGS_CHANGED_DURING_WRITE' -Extra $common
    }

    try {
        Write-SumiGuardNewFile -Path $temporaryPath -Bytes $newBytes
        if ($before.exists) {
            [IO.File]::Replace($temporaryPath, $settingsFull, [NullString]::Value)
        }
        else {
            [IO.File]::Move($temporaryPath, $settingsFull)
        }
    }
    catch {
        Write-SumiGuardSetupSummary -Status 'WRITE_FAILED' -Extra $common
    }

    $after = Read-SumiGuardSettingsFile -Path $settingsFull
    if (-not (Test-SumiGuardSameContent -Left $after.bytes -Right $newBytes)) {
        try {
            if ($before.exists) {
                [IO.File]::WriteAllBytes($settingsFull, $before.bytes)
            }
            else {
                [IO.File]::Delete($settingsFull)
            }
            Write-SumiGuardSetupSummary -Status 'VERIFY_FAILED_RESTORED' -Extra $common
        }
        catch {
            Write-SumiGuardSetupSummary -Status 'VERIFY_FAILED_RESTORE_FAILED' -Extra $common
        }
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        try { [IO.File]::Delete($temporaryPath) } catch { $null = $_ }
    }
}

$common['backup_file_name'] = $backupName
$common['entries_removed'] = $plan.entries_removed
if ($Action -ceq 'Uninstall') { $common['stores_kept'] = $true }
Write-SumiGuardSetupSummary -Status $doneStatus -Extra $common -ExitCode 0
