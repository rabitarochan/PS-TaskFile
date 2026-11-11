function Test-Task {
    <#
    .SYNOPSIS
        Tests whether tasks are up to date.
    .DESCRIPTION
        Test-Task is the `task --status` mode. For each task it returns $true when the task
        would be skipped by Invoke-Task: its `status` commands succeed and/or its `sources`
        are unchanged. A task without `status` and `sources` is never up to date.

        The commands of the task are not run and the stored fingerprints are not updated.
        Dynamic variables and status commands are evaluated.
    .PARAMETER Name
        The tasks to test. One boolean is returned per name, in the same order.
    .PARAMETER Taskfile
        The Taskfile to read, or a directory that contains one.
    .PARAMETER Directory
        The directory to search for the Taskfile (searching goes up to the root).
    .PARAMETER Global
        Reads the Taskfile of the home directory.
    .EXAMPLE
        Test-Task build
    .EXAMPLE
        if (-not (Test-Task generate)) { Invoke-Task generate }
    .LINK
        Invoke-Task
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$Name,

        [Alias('t')]
        [string]$Taskfile,

        [Alias('d', 'Dir')]
        [string]$Directory,

        [Alias('g')]
        [switch]$Global
    )

    begin {
        $names = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($item in $Name) { if (-not [string]::IsNullOrEmpty($item)) { $names.Add($item) } }
    }

    end {
        $options = @{ Verbose = $VerbosePreference -eq 'Continue' }
        $request = New-TaskEngineRequest -Action Status -Name $names -Taskfile $Taskfile -Directory $Directory -Global:$Global -Options $options
        $result = Invoke-TaskEngine -Cmdlet $PSCmdlet -Request $request
        Complete-TaskResult -Cmdlet $PSCmdlet -Result $result
        foreach ($upToDate in $result.Data) { [bool]$upToDate }
    }
}
