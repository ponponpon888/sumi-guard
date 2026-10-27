@{
    RootModule = 'SumiGuard.EnforcementControl.psm1'
    ModuleVersion = '0.1.0'
    GUID = '443da9c0-1e52-4ebe-b5b7-bb85c1db1923'
    Author = 'SUMI Guard'
    Description = 'Operator-owned ENFORCE_RECORDING setting, kill switch and notice file. No hook, command, or recording store side effects.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Initialize-SumiGuardEnforcementControlDirectory',
        'Get-SumiGuardEnforcementSetting',
        'Write-SumiGuardEnforcementNotice'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
