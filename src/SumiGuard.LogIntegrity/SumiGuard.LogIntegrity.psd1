@{
    RootModule = 'SumiGuard.LogIntegrity.psm1'
    ModuleVersion = '0.1.0'
    GUID = '5b0c3f7e-2a61-4d8f-9c4e-7d1a6e2b9f30'
    Author = 'SUMI Guard'
    Description = 'Prefix checkpoints for the append-only NDJSON metadata logs. Read-only; stores nothing and returns no log content or paths.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Get-SumiGuardLogCheckpoint', 'Test-SumiGuardLogCheckpoint')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
