function Get-TaskSummary {
    <#
    .SYNOPSIS
        Shows the summary of tasks: description, variables, dependencies and commands.
    .DESCRIPTION
        Get-TaskSummary is the `task --summary` mode. It returns the summary as lines of text
        and runs nothing: dynamic variables are shown by their definition (`sh: ...`).
    .PARAMETER Name
        The tasks to summarize.
    .PARAMETER Taskfile
        The Taskfile to read, or a directory that contains one.
    .PARAMETER Directory
        The directory to search for the Taskfile (searching goes up to the root).
    .PARAMETER Global
        Reads the Taskfile of the home directory.
    .EXAMPLE
        Get-TaskSummary build
    .EXAMPLE
        Get-Task -All | Get-TaskSummary
    .LINK
        Get-Task
    #>
    [CmdletBinding()]
    [OutputType([string])]
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
        $request = New-TaskEngineRequest -Action Summary -Name $names -Taskfile $Taskfile -Directory $Directory -Global:$Global
        $result = Invoke-TaskEngine -Cmdlet $PSCmdlet -Request $request
        Complete-TaskResult -Cmdlet $PSCmdlet -Result $result
        foreach ($line in $result.Data) { [string]$line }
    }
}
