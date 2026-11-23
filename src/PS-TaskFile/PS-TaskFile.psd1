@{
    RootModule           = 'PS-TaskFile.psm1'
    ModuleVersion        = '0.2.0'
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
            ReleaseNotes = @'
0.2.0
- output: prefixed writes "[name] | text". The prefixes are aligned, a line that is wider
  than the terminal continues below its own text, and on a terminal every task has its
  own color. Scripts that read these lines have to expect the bar.
- The mapping form of an output style other than group is rejected, as task does.
'@
        }
    }
}
