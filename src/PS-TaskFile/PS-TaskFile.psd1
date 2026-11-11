@{
    RootModule           = 'PS-TaskFile.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6f0a3f0e-5c0b-4c58-9a51-2f6a7d3c9b14'
    Author               = 'Kengo Asamizu'
    Copyright            = 'Copyright (c) 2026 Kengo Asamizu. Licensed under the MIT License.'
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
            ProjectUri = 'https://github.com/rabitarochan/PS-TaskFile'
            LicenseUri = 'https://github.com/rabitarochan/PS-TaskFile/blob/main/LICENSE.txt'
        }
    }
}
