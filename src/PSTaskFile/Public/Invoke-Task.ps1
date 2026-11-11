function Invoke-Task {
    <#
    .SYNOPSIS
        Runs tasks from a Taskfile (https://taskfile.dev) with PowerShell as the shell.
    .DESCRIPTION
        Invoke-Task is the PowerShell counterpart of the `task` command. The Taskfile format is
        the same, but every command (cmds, dynamic `sh:` variables, status, preconditions, if)
        is executed as PowerShell instead of POSIX shell.

        Each task run has its own PowerShell scope: a variable or function defined by one
        command is visible to the following commands of the same task and to nothing else.

        Without -PassThru the output of the commands goes straight to the host, like a console
        program (native commands keep colors and interactivity). With -PassThru everything is
        emitted on the streams of Invoke-Task so that it can be captured or piped.

        On failure a terminating error is thrown and $LASTEXITCODE is set to the exit code that
        `task` would have returned (for example 201 when a command failed).
    .PARAMETER Name
        The tasks to run, in order. Defaults to the task named "default".
    .PARAMETER ArgumentList
        Extra arguments made available to the Taskfile as {{.CLI_ARGS}} and {{.CLI_ARGS_LIST}}.
        Everything after `--` is collected here: Invoke-Task test -- -Tag Unit
    .PARAMETER Variable
        Variables for the Taskfile (the `task NAME=value` syntax): -Variable @{ CONFIG = 'Release' }
    .PARAMETER Taskfile
        The Taskfile to run, or a directory that contains one.
    .PARAMETER Directory
        The directory to run in and to search for the Taskfile (searching goes up to the root).
    .PARAMETER Global
        Runs the Taskfile of the home directory.
    .PARAMETER Force
        Runs the tasks even when they are up to date.
    .PARAMETER Silent
        Does not echo the commands.
    .PARAMETER Parallel
        Runs the given tasks in parallel.
    .PARAMETER Concurrency
        Limits the number of tasks that run at the same time (0 = unlimited).
    .PARAMETER Output
        Output style: interleaved (default), group or prefixed.
    .PARAMETER OutputGroupBegin
        Message template printed before the grouped output of a command.
    .PARAMETER OutputGroupEnd
        Message template printed after the grouped output of a command.
    .PARAMETER OutputGroupErrorOnly
        Drops the grouped output of commands that succeed.
    .PARAMETER AssumeYes
        Answers "yes" to every `prompt` of the tasks.
    .PARAMETER ExitCode
        Sets $LASTEXITCODE to the exit code of the failing command instead of 201.
    .PARAMETER FailFast
        Stops the other tasks when one of the tasks running in parallel fails.
    .PARAMETER Watch
        Runs the tasks again whenever one of their sources changes (see Watch-Task).
    .PARAMETER Interval
        The polling interval for -Watch as a duration such as 500ms or 2s.
    .PARAMETER NoColor
        Disables colored engine messages (also disabled by the NO_COLOR environment variable).
    .PARAMETER PassThru
        Emits the output of the tasks on the pipeline and streams instead of the host.
    .EXAMPLE
        Invoke-Task
        Runs the "default" task of the Taskfile in the current directory (or a parent of it).
    .EXAMPLE
        Invoke-Task build, test -Variable @{ CONFIGURATION = 'Release' }
    .EXAMPLE
        Invoke-Task deploy -WhatIf
        Prints the commands that would run without running them (the `--dry` flag).
    .EXAMPLE
        $version = Invoke-Task version -Silent -PassThru
    .LINK
        https://taskfile.dev
    #>
    # -WhatIf is the dry run of the engine (`task --dry`): the commands are printed, not run.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'WhatIf is forwarded to the engine as a dry run.')]
    [CmdletBinding(SupportsShouldProcess)]
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

        [Alias('f')]
        [switch]$Force,

        [Alias('s')]
        [switch]$Silent,

        [Alias('p')]
        [switch]$Parallel,

        [Alias('C')]
        [ValidateRange(0, [int]::MaxValue)]
        [int]$Concurrency,

        [Alias('o')]
        [ValidateSet('interleaved', 'group', 'prefixed')]
        [string]$Output,

        [string]$OutputGroupBegin,

        [string]$OutputGroupEnd,

        [switch]$OutputGroupErrorOnly,

        [Alias('y', 'Yes')]
        [switch]$AssumeYes,

        [Alias('x')]
        [switch]$ExitCode,

        [switch]$FailFast,

        [Alias('w')]
        [switch]$Watch,

        [Alias('I')]
        [string]$Interval,

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
            Force                = $Force.IsPresent
            Silent               = $Silent.IsPresent
            Verbose              = $VerbosePreference -eq 'Continue'
            Dry                  = [bool]$WhatIfPreference
            Parallel             = $Parallel.IsPresent
            Concurrency          = $Concurrency
            Output               = $Output
            OutputGroupBegin     = $OutputGroupBegin
            OutputGroupEnd       = $OutputGroupEnd
            OutputGroupErrorOnly = $OutputGroupErrorOnly.IsPresent
            AssumeYes            = $AssumeYes.IsPresent
            Failfast             = $FailFast.IsPresent
            Color                = -not $NoColor -and [string]::IsNullOrEmpty($env:NO_COLOR)
            Watch                = $Watch.IsPresent
            Interval             = $Interval
        }
        $extra = @{ ArgumentList = $ArgumentList; Variables = $Variable; PassThru = $PassThru.IsPresent }
        $request = New-TaskEngineRequest -Action Run -Name $names -Taskfile $Taskfile -Directory $Directory -Global:$Global -Options $options -Extra $extra
        $result = Invoke-TaskEngine -Cmdlet $PSCmdlet -Request $request
        Complete-TaskResult -Cmdlet $PSCmdlet -Result $result -PassExitCode:$ExitCode
    }
}
