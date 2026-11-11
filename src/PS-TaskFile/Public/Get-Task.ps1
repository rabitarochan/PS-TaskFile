function Get-Task {
    <#
    .SYNOPSIS
        Lists the tasks of a Taskfile.
    .DESCRIPTION
        Get-Task is the `task --list` / `task --list-all` mode. It returns one object per task
        with its Name, Label, Description, Summary, Aliases and Location, so the result can be
        filtered, formatted or converted (for example with ConvertTo-Json).

        Like `task --list`, only tasks that have a description are returned unless -All or
        -Name is used. Internal tasks are never returned.
    .PARAMETER Name
        Only return the tasks whose name or alias matches one of these wildcard patterns.
    .PARAMETER All
        Also return the tasks that have no description (`task --list-all`).
    .PARAMETER IncludeStatus
        Fills the UpToDate property by evaluating the status commands and the sources of each
        task. Nothing is run and no state is written.
    .PARAMETER Sort
        default: alphabetical with the tasks of included Taskfiles last; alphanumeric: plain
        alphabetical; none: the order of the Taskfile.
    .PARAMETER Taskfile
        The Taskfile to read, or a directory that contains one.
    .PARAMETER Directory
        The directory to search for the Taskfile (searching goes up to the root).
    .PARAMETER Global
        Reads the Taskfile of the home directory.
    .EXAMPLE
        Get-Task
    .EXAMPLE
        Get-Task -All | Where-Object Name -Like 'docs:*'
    .EXAMPLE
        Get-Task -IncludeStatus | ConvertTo-Json -Depth 3
    .EXAMPLE
        Get-Task -Name lint | Invoke-Task
    .LINK
        Invoke-Task
    #>
    [CmdletBinding()]
    [OutputType('PS-TaskFile.TaskInfo')]
    param(
        [Parameter(Position = 0)]
        [SupportsWildcards()]
        [string[]]$Name,

        [Alias('a')]
        [switch]$All,

        [switch]$IncludeStatus,

        [ValidateSet('default', 'alphanumeric', 'none')]
        [string]$Sort = 'default',

        [Alias('t')]
        [string]$Taskfile,

        [Alias('d', 'Dir')]
        [string]$Directory,

        [Alias('g')]
        [switch]$Global
    )

    $extra = @{ All = $All.IsPresent; IncludeStatus = $IncludeStatus.IsPresent; Sort = $Sort }
    $request = New-TaskEngineRequest -Action List -Name $Name -Taskfile $Taskfile -Directory $Directory -Global:$Global -Extra $extra
    $result = Invoke-TaskEngine -Cmdlet $PSCmdlet -Request $request
    Complete-TaskResult -Cmdlet $PSCmdlet -Result $result

    $tasks = @($result.Data)
    if ($tasks.Count -eq 0 -and -not $All -and -not $Name) {
        Write-Warning 'task: No tasks with description available. Try -All to list all tasks'
        return
    }
    foreach ($task in $tasks) {
        $task.PSObject.TypeNames.Insert(0, 'PS-TaskFile.TaskInfo')
        $task
    }
}
