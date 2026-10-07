@{
    RootModule = 'SumiGuard.AssessmentStore.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'ad48d869-385e-4e77-9ec6-e9b78d133444'
    Author = 'SUMI Guard'
    Description = 'Dedicated metadata-only storage for SUMI Guard command assessments.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'New-SumiGuardAssessmentStore',
        'Save-SumiGuardAssessment',
        'Get-SumiGuardAssessmentRecord')
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
