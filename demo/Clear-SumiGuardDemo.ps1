[CmdletBinding()]
param(
    [switch]$ConfirmDemoRemoval
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptRoot
$demoRoot = Join-Path $projectRoot '.demo-data'
$markerPath = Join-Path $demoRoot '.sumi-guard-demo-root.json'

function Test-ReparsePoint {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

try {
    if (-not $ConfirmDemoRemoval) {
        Write-Output '清掃は未実行です。-ConfirmDemoRemoval を指定してください。'
        exit 1
    }
    if (-not (Test-Path -LiteralPath $demoRoot)) {
        Write-Output '清掃対象のデモ記録はありません。'
        exit 0
    }
    $expected = [IO.Path]::GetFullPath((Join-Path $projectRoot '.demo-data'))
    $resolved = [IO.Path]::GetFullPath($demoRoot)
    if ($resolved -cne $expected -or
        -not (Test-Path -LiteralPath $resolved -PathType Container) -or
        (Test-ReparsePoint $resolved) -or
        -not (Test-Path -LiteralPath $markerPath -PathType Leaf) -or
        (Test-ReparsePoint $markerPath)) {
        throw 'Cleanup target validation failed.'
    }
    $marker = [IO.File]::ReadAllText($markerPath) | ConvertFrom-Json -ErrorAction Stop
    if ([int]$marker.schema_version -ne 1 -or
        [string]$marker.purpose -cne 'SUMI_GUARD_MANUAL_DEMO' -or
        [string]$marker.demo_id -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Cleanup marker validation failed.'
    }
    $reparseItems = @(Get-ChildItem -LiteralPath $resolved -Force -Recurse | Where-Object {
        ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    })
    if ($reparseItems.Count -ne 0) { throw 'Cleanup target contains a reparse point.' }

    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $resolved) { throw 'Cleanup did not complete.' }
    Write-Output '清掃: 完了'
    Write-Output '削除対象: SUMI Guardのデモ専用記録のみ'
    Write-Output 'この清掃スクリプトによる復元機能はありません。'
}
catch {
    Write-Output '清掃: 失敗（対象の検証後、削除は完了していません）'
    Write-Output '任意パスやリンク先は削除していません。'
    exit 1
}
