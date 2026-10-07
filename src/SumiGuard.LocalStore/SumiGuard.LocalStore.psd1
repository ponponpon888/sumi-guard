@{
    RootModule = 'SumiGuard.LocalStore.psm1'
    ModuleVersion = '0.1.0'
    GUID = '5d24c91f-48e7-442e-8cba-f9b67ecbed89'
    Author = 'SUMI Guard'
    Description = 'DPAPI CurrentUser protected local body storage for SUMI Guard.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Initialize-SumiGuardLocalStore',
        'Save-SumiGuardBody',
        'Get-SumiGuardBody',
        'Remove-SumiGuardExpiredBody'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    PrivateData = @{
        PSData = @{
            Tags = @('Windows', 'DPAPI', 'LocalStorage')
        }
    }
}
