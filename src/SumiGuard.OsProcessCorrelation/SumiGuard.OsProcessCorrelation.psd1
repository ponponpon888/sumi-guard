@{
    RootModule = 'SumiGuard.OsProcessCorrelation.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'd4175a80-69ae-434c-a0d3-88e684ad98c1'
    Author = 'SUMI Guard'
    CompanyName = 'SUMI Guard'
    Description = 'Pure, fail-closed correlation of process evidence and Windows OS observations. It performs no collection or process operations.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-SumiGuardOsProcessCorrelation')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
