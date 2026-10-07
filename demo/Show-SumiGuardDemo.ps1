[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$demoRoot = Join-Path $projectRoot '.demo-data'
$cliPath = Join-Path $projectRoot 'tools\Show-SumiGuardRecords.ps1'
$executionStore = Join-Path $demoRoot 'execution-store'
$localStore = Join-Path $demoRoot 'body-store'
$observationPath = Join-Path $executionStore 'demo-os-processes.ndjson'
$manifestPath = Join-Path $demoRoot 'demo-manifest.json'
$rootMarkerPath = Join-Path $demoRoot '.sumi-guard-demo-root.json'
$powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-ReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Read-DemoJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -or (Test-ReparsePoint $Path)) {
        throw 'Demo metadata unavailable.'
    }
    return [IO.File]::ReadAllText($Path) | ConvertFrom-Json -ErrorAction Stop
}

function Get-OptionalValue {
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    if ($null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name) {
        return $Object.$Name
    }
    return $Default
}

function Format-OptionalValue {
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return '未記録' }
    return [string]$Value
}

function Format-OptionalBoolean {
    param($Value)
    if ($null -eq $Value) { return '未記録' }
    if ([bool]$Value) { return 'はい' }
    return 'いいえ'
}

function Write-DemoDiagnostics {
    param($Manifest)

    Write-Output '=== 4. 参考診断（正式相関は変更しません） ==='
    $diagnostics = Get-OptionalValue -Object $Manifest -Name 'diagnostics'
    $child = Get-OptionalValue -Object $diagnostics -Name 'child_codex'
    if ($null -eq $child) {
        Write-Output '子Codex終了コード: 未記録'
        Write-Output '子Codexタイムアウト: 未記録'
        Write-Output '標準エラー読取状態: 未記録'
        Write-Output '標準エラー分類: 未記録'
        Write-Output '標準エラー非空: 未記録'
        Write-Output '標準エラー行数: 未記録'
        Write-Output '標準エラーサイズ: 未記録'
    }
    else {
        Write-Output ('子Codex終了コード: {0}' -f (Format-OptionalValue `
            (Get-OptionalValue $child 'child_codex_exit_code')))
        Write-Output ('子Codexタイムアウト: {0}' -f (Format-OptionalBoolean `
            (Get-OptionalValue $child 'child_codex_timed_out')))
        Write-Output ('標準エラー読取状態: {0}' -f (Format-OptionalValue `
            (Get-OptionalValue $child 'stderr_read_status')))
        Write-Output ('標準エラー分類: {0}' -f (Format-OptionalValue `
            (Get-OptionalValue $child 'stderr_classification')))
        Write-Output ('標準エラー非空: {0}' -f (Format-OptionalBoolean `
            (Get-OptionalValue $child 'stderr_nonempty')))
        Write-Output ('標準エラー行数: {0}' -f (Format-OptionalValue `
            (Get-OptionalValue $child 'stderr_line_count')))
        $stderrSize = Format-OptionalValue `
            (Get-OptionalValue $child 'stderr_utf8_reencoded_byte_count')
        $measurement = Format-OptionalValue `
            (Get-OptionalValue $child 'stderr_size_measurement')
        Write-Output ('標準エラーサイズ: {0} bytes（計測方法: {1}）' -f `
            $stderrSize, $measurement)
    }

    $event400 = Get-OptionalValue -Object $diagnostics -Name 'event400_hook_classification'
    if ($null -eq $event400) {
        Write-Output 'Event 400取得状態: 未記録'
        Write-Output 'Event 400分類状態: 未記録'
        Write-Output '補助分類されたフック関連候補: 未記録'
        Write-Output '補助分類後の残候補数: 未記録'
    }
    else {
        Write-Output ('Event 400取得状態: {0}' -f (Format-OptionalValue `
            (Get-OptionalValue $event400 'collection_status')))
        Write-Output ('Event 400分類状態: {0}' -f (Format-OptionalValue `
            (Get-OptionalValue $event400 'classification_status')))
        $classifiedValue = Get-OptionalValue $event400 'classified_hook_candidates'
        $classified = @()
        if ($null -ne $classifiedValue) { $classified = @($classifiedValue) }
        if ($classified.Count -eq 0) {
            Write-Output '補助分類されたフック関連候補: なし'
        }
        else {
            foreach ($candidate in $classified) {
                Write-Output ('補助分類されたフック関連候補: PID {0}, 分類元 {1}' -f `
                    (Format-OptionalValue (Get-OptionalValue $candidate 'process_id')), `
                    (Format-OptionalValue (Get-OptionalValue $candidate 'classification_source')))
            }
        }
        Write-Output ('補助分類後の残候補数: {0}' -f (Format-OptionalValue `
            (Get-OptionalValue $event400 'remaining_candidate_count')))
    }
    Write-Output '注意: 参考診断は正式なDIRECT_MATCH / INFERRED_MATCH / UNMATCHEDを変更しません。'
    Write-Output '残候補が1件でも、対象コマンドとは断定しません。'
    Write-Output '生標準エラーとEvent Message本文は表示していません。'
}

function Invoke-ReadOnlyCli {
    param([string]$Action, [string]$ExecutionId = '')

    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $cliPath,
        '-Action', $Action,
        '-ExecutionStorePath', $executionStore,
        '-LocalStorePath', $localStore
    )
    if ($Action -ceq 'List' -or $Action -ceq 'Detail') {
        $arguments += @('-OsObservationPath', $observationPath)
    }
    if (-not [string]::IsNullOrWhiteSpace($ExecutionId)) {
        $arguments += @('-ExecutionId', $ExecutionId)
    }
    & $powerShell @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Read-only CLI failed.' }
}

try {
    $expectedRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot '.demo-data'))
    $actualRoot = [IO.Path]::GetFullPath($demoRoot)
    if ($actualRoot -cne $expectedRoot -or
        -not (Test-Path -LiteralPath $actualRoot -PathType Container) -or
        (Test-ReparsePoint $actualRoot)) {
        throw 'Demo store unavailable.'
    }
    $rootMarker = Read-DemoJson -Path $rootMarkerPath
    $manifest = Read-DemoJson -Path $manifestPath
    if ([int]$rootMarker.schema_version -ne 1 -or
        [string]$rootMarker.purpose -cne 'SUMI_GUARD_MANUAL_DEMO' -or
        [int]$manifest.schema_version -ne 1 -or
        [string]$manifest.purpose -cne 'SUMI_GUARD_MANUAL_DEMO' -or
        [string]$manifest.execution_id -cnotmatch '^[0-9a-f]{32}$' -or
        -not (Test-Path -LiteralPath $observationPath -PathType Leaf)) {
        throw 'Demo metadata invalid.'
    }

    Write-Output '=== 1. 一覧 ==='
    Invoke-ReadOnlyCli -Action List
    Write-Output ''
    Write-Output '=== 2. 詳細 ==='
    Invoke-ReadOnlyCli -Action Detail -ExecutionId ([string]$manifest.execution_id)
    Write-Output ''
    Write-Output '=== 3. 保存状態 ==='
    Invoke-ReadOnlyCli -Action StoreStatus
    Write-Output ''
    Write-DemoDiagnostics -Manifest $manifest
}
catch {
    Write-Output 'デモ確認: 失敗'
    Write-Output '本文や例外詳細は表示していません。開始または清掃状態を確認してください。'
    exit 1
}
