@{
    RootModule = 'SumiGuard.ExecutionAdapter.psm1'
    ModuleVersion = '0.1.0'
    GUID = '23fa52e0-cfaf-41fb-8521-7890d67d4692'
    Author = 'SUMI Guard'
    Description = 'Execution metadata adapter for SUMI Guard LocalStore.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Initialize-SumiGuardExecutionStore',
        'Save-SumiGuardExecutionIntent',
        'Get-SumiGuardExecutionRecord',
        'Get-SumiGuardCollectionFailureNotice',
        'Read-SumiGuardExecutionBody',
        'Invoke-SumiGuardExecutionRetentionCleanup'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
