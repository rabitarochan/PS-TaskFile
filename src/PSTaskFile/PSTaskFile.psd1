@{
    RootModule           = 'PSTaskFile.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6f0a3f0e-5c0b-4c58-9a51-2f6a7d3c9b14'
    Author               = 'PSTaskFile contributors'
    CompanyName          = 'Unknown'
    Copyright            = '(c) PSTaskFile contributors. All rights reserved.'
    Description          = 'A PowerShell-native implementation of the Task runner (https://taskfile.dev). Taskfile commands, dynamic variables and conditions are executed as PowerShell.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    RequiredModules      = @('powershell-yaml')
    FunctionsToExport    = @(
        'Get-Task'
        'Get-TaskSummary'
        'Invoke-Task'
        'New-Taskfile'
        'Test-Task'
        'Watch-Task'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('task', 'taskfile', 'task-runner', 'build', 'automation')
            ProjectUri = 'https://taskfile.dev'
        }
    }
}
