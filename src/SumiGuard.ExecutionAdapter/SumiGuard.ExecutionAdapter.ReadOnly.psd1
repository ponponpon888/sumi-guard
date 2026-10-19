@{
    RootModule = 'SumiGuard.ExecutionAdapter.ReadOnly.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'd0a9f3e4-8a8c-4b6f-9f8d-61c3e9c0d2a1'
    Author = 'SUMI Guard'
    Description = 'Read-only metadata and collection-failure notice surface for SUMI Guard.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-SumiGuardExecutionRecord',
        'Get-SumiGuardCollectionFailureNotice'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
