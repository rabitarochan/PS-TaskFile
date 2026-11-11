function Watch-Task {
    <#
    .SYNOPSIS
        Runs tasks and runs them again whenever one of their source files changes.
    .DESCRIPTION
        Watch-Task is the `task --watch` mode. The tasks run once; after that the `sources` of
        the tasks (and of the tasks they depend on or call) are polled, and every change starts
        a new run. A run that is still in progress when a change arrives is cancelled first.

        The command keeps running until it is stopped with Ctrl+C. Failures are reported but
        do not end the watch.
    .PARAMETER Name
        The tasks to watch. Defaults to the task named "default".
    .PARAMETER ArgumentList
        Extra arguments made available to the Taskfile as {{.CLI_ARGS}} and {{.CLI_ARGS_LIST}}.
    .PARAMETER Variable
        Variables for the Taskfile: -Variable @{ CONFIG = 'Release' }
    .PARAMETER Taskfile
        The Taskfile to run, or a directory that contains one.
    .PARAMETER Directory
        The directory to run in and to search for the Taskfile.
    .PARAMETER Global
        Runs the Taskfile of the home directory.
    .PARAMETER Interval
        The polling interval as a duration such as 500ms or 2s. Defaults to the `interval` of
        the Taskfile, or 500ms.
    .PARAMETER Force
        Runs the tasks even when they are up to date.
    .PARAMETER Silent
        Does not echo the commands.
    .PARAMETER Output
        Output style: interleaved (default), group or prefixed.
    .PARAMETER NoColor
        Disables colored engine messages.
    .PARAMETER PassThru
        Emits the output of the tasks on the pipeline and streams instead of the host.
    .EXAMPLE
        Watch-Task build
        Builds, then builds again each time a source file of the "build" task changes.
    .EXAMPLE
        Watch-Task test -Interval 2s
    .LINK
        Invoke-Task
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$Name,

        [Parameter(ValueFromRemainingArguments)]
        [Alias('CliArgs')]
        [string[]]$ArgumentList,

        [Alias('Var', 'Vars')]
        [System.Collections.IDictionary]$Variable,

        [Alias('t')]
        [string]$Taskfile,

        [Alias('d', 'Dir')]
        [string]$Directory,

        [Alias('g')]
        [switch]$Global,

        [Alias('I')]
        [string]$Interval,

        [Alias('f')]
        [switch]$Force,

        [Alias('s')]
        [switch]$Silent,

        [Alias('o')]
        [ValidateSet('interleaved', 'group', 'prefixed')]
        [string]$Output,

        [switch]$NoColor,

        [switch]$PassThru
    )

    begin {
        $names = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($item in $Name) { if (-not [string]::IsNullOrEmpty($item)) { $names.Add($item) } }
    }

    end {
        $options = @{
            Force    = $Force.IsPresent
            Silent   = $Silent.IsPresent
            Verbose  = $VerbosePreference -eq 'Continue'
            Output   = $Output
            Color    = -not $NoColor -and [string]::IsNullOrEmpty($env:NO_COLOR)
            Watch    = $true
            Interval = $Interval
        }
        $extra = @{ ArgumentList = $ArgumentList; Variables = $Variable; PassThru = $PassThru.IsPresent }
        $request = New-TaskEngineRequest -Action Run -Name $names -Taskfile $Taskfile -Directory $Directory -Global:$Global -Options $options -Extra $extra
        $result = Invoke-TaskEngine -Cmdlet $PSCmdlet -Request $request
        Complete-TaskResult -Cmdlet $PSCmdlet -Result $result
    }
}
