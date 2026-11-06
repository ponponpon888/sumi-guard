@{
    RootModule = 'SumiGuard.HookSetup.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'c6e2a8d4-7f13-4b59-a0de-3e9b14f6c271'
    Author = 'SUMI Guard'
    Description = 'Plans adding or removing the SUMI Guard MONITOR hook entry in Claude Code settings text. Reads and writes no file.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-SumiGuardClaudeMonitorHookPlan')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
