@{
    RootModule = 'SumiGuard.CimProcessObserver.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'd77e9f97-70ab-47d8-a675-e352c7de9c34'
    Author = 'SUMI GUARD'
    Description = 'Read-only, explicit self-PID CIM snapshot adapter. CIM start-time precision remains unverified and cannot satisfy the Phase 4A TICKS_100NS gate.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-SumiGuardSelfProcessCimObserver')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
