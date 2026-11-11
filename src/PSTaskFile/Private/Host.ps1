# The calling side of the engine: public cmdlets build a request, the engine runs it in a
# dedicated runspace (see Private/Runner.ps1 for why) and the outcome is reported here on the
# streams of the calling cmdlet.

function Write-TaskSinkItem {
    <#
    .SYNOPSIS
        Re-emits one queued item of a -PassThru run on the streams of the calling cmdlet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][System.Collections.DictionaryEntry]$Item
    )
    $value = $Item.Value
    switch ([string]$Item.Key) {
        'x' {
            if ($value -is [System.Management.Automation.ErrorRecord]) { $Cmdlet.WriteError($value) }
            elseif ($value -is [System.Management.Automation.WarningRecord]) { $Cmdlet.WriteWarning($value.Message) }
            elseif ($value -is [System.Management.Automation.VerboseRecord]) { Write-Verbose -Message $value.Message -Verbose }
            elseif ($value -is [System.Management.Automation.DebugRecord]) { Write-Debug -Message $value.Message -Debug }
            elseif ($value -is [System.Management.Automation.InformationRecord]) { $Cmdlet.WriteInformation($value) }
            else { $Cmdlet.WriteObject($value, $false) }
        }
        'o' { $Cmdlet.WriteObject($value, $false) }
        'i' { $Cmdlet.WriteInformation($value) }
        'v' { Write-Verbose -Message ([string]$value) -Verbose }
        'e' { $Cmdlet.WriteError($value) }
    }
}

function Invoke-TaskEngine {
    <#
    .SYNOPSIS
        Runs an engine request in a dedicated runspace and returns its result table.
    .DESCRIPTION
        The request is a hashtable (Action, Names, Options, ...). The engine never throws for
        task failures; it returns @{ Ok; Data; Message; Code; ExitStatus; Exception }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The calling cmdlet; only needed for -PassThru runs (it re-emits the queued output).
        [System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][hashtable]$Request
    )
    # Assigned in a statement: an `if` expression would enumerate the (empty) collection.
    $sink = $null
    if ($Request.PassThru -and $null -ne $Cmdlet) { $sink = [System.Collections.Concurrent.BlockingCollection[object]]::new() }
    $Request.Sink = $sink
    $Request.ModuleFile = $script:ModuleFile
    $Request.Version = $script:ModuleVersion
    if (-not $Request.ContainsKey('WorkingDirectory')) { $Request.WorkingDirectory = $PWD.ProviderPath }

    $initialState = [initialsessionstate]::CreateDefault2()
    $initialState.ImportPSModule([string[]]@($script:ModuleFile))
    $runspace = [runspacefactory]::CreateRunspace($Host, $initialState)
    $shell = $null
    try {
        $runspace.Open()
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        $null = $shell.AddScript('param($request) & (Get-Module PSTaskFile) { param($r) [TaskEngine]::Run($r) } $request').AddArgument($Request)
        $async = $shell.BeginInvoke()
        $output = $null
        try {
            $item = $null
            while ($true) {
                if ($null -ne $sink) {
                    if ($sink.TryTake([ref] $item, 20)) {
                        Write-TaskSinkItem -Cmdlet $Cmdlet -Item $item
                        continue
                    }
                }
                else { $null = $async.AsyncWaitHandle.WaitOne(20) }
                if ($async.IsCompleted -and ($null -eq $sink -or $sink.Count -eq 0)) { break }
            }
            $output = $shell.EndInvoke($async)
        }
        finally {
            # Reached with a running engine when the caller is stopped (Ctrl+C).
            if (-not $async.IsCompleted) { $shell.Stop() }
        }
        if ($null -ne $output -and $output.Count -gt 0) { return $output[0].psobject.BaseObject }
        $reason = if ($shell.Streams.Error.Count -gt 0) { $shell.Streams.Error[0].ToString() } else { 'the engine returned no result' }
        return @{ Ok = $false; Message = "task: internal error: $reason"; Code = 1; ExitStatus = $null; Exception = $null }
    }
    finally {
        if ($null -ne $shell) { $shell.Dispose() }
        $runspace.Dispose()
        if ($null -ne $sink) { $sink.Dispose() }
    }
}

function Complete-TaskResult {
    <#
    .SYNOPSIS
        Sets $LASTEXITCODE and throws the terminating error for a failed engine result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][hashtable]$Result,
        [switch]$PassExitCode
    )
    if ($Result.Ok) {
        $global:LASTEXITCODE = 0
        return
    }
    $code = [int]$Result.Code
    $exitCode = if ($PassExitCode -and $null -ne $Result.ExitStatus) { [int]$Result.ExitStatus } else { $code }
    $global:LASTEXITCODE = $exitCode

    $errorId, $category = switch ($code) {
        100 { 'TaskfileNotFound', 'ObjectNotFound' }
        101 { 'TaskfileAlreadyExists', 'ResourceExists' }
        102 { 'TaskfileInvalid', 'InvalidData' }
        107 { 'TaskfileVersionNotSupported', 'InvalidData' }
        109 { 'TaskfileInvalid', 'InvalidData' }
        110 { 'TaskfileIncludeCycle', 'InvalidData' }
        200 { 'TaskNotFound', 'ObjectNotFound' }
        201 { 'TaskRunFailed', 'InvalidResult' }
        202 { 'TaskInternal', 'InvalidOperation' }
        203 { 'TaskNameConflict', 'InvalidArgument' }
        204 { 'TaskCalledTooManyTimes', 'InvalidOperation' }
        205 { 'TaskCancelled', 'OperationStopped' }
        206 { 'TaskMissingRequiredVariables', 'InvalidArgument' }
        207 { 'TaskVariableNotAllowed', 'InvalidArgument' }
        default { 'TaskError', 'NotSpecified' }
    }
    $exception = [System.InvalidOperationException]::new([string]$Result.Message, $Result.Exception)
    $exception.Data['TaskCode'] = $code
    $exception.Data['TaskExitCode'] = $exitCode
    $record = [System.Management.Automation.ErrorRecord]::new($exception, $errorId, [System.Management.Automation.ErrorCategory]$category, $null)
    $Cmdlet.ThrowTerminatingError($record)
}

function New-TaskEngineRequest {
    <#
    .SYNOPSIS
        Builds the request table for Invoke-TaskEngine with every option defaulted.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Action,
        [string[]]$Name,
        [string]$Taskfile,
        [string]$Directory,
        [switch]$Global,
        # Overrides for the engine options (Force, Silent, Dry, ...).
        [hashtable]$Options = @{},
        # Additional request entries (PassThru, Variables, All, ...).
        [hashtable]$Extra = @{}
    )
    $request = @{
        Action           = $Action
        Names            = @($Name | Where-Object { -not [string]::IsNullOrEmpty($_) })
        ArgumentList     = @()
        Variables        = $null
        Taskfile         = $Taskfile
        Directory        = $Directory
        Global           = $Global.IsPresent
        WorkingDirectory = $PWD.ProviderPath
        PassThru         = $false
        Options          = @{
            Force                = $false
            ForceAll             = $false
            Silent               = $false
            Verbose              = $false
            Dry                  = $false
            Parallel             = $false
            Concurrency          = 0
            Output               = ''
            OutputGroupBegin     = ''
            OutputGroupEnd       = ''
            OutputGroupErrorOnly = $false
            AssumeYes            = $false
            Failfast             = $false
            Color                = [string]::IsNullOrEmpty($env:NO_COLOR)
            Watch                = $false
            Interval             = ''
        }
    }
    foreach ($key in $Options.Keys) { $request.Options[$key] = $Options[$key] }
    foreach ($key in $Extra.Keys) { $request[$key] = $Extra[$key] }
    $request
}

function Get-TaskCompletion {
    <#
    .SYNOPSIS
        Argument completer for the -Name parameter: the runnable tasks of the Taskfile.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$WordToComplete,
        [System.Collections.IDictionary]$BoundParameters
    )
    $location = @{}
    foreach ($key in 'Taskfile', 'Directory', 'Global') {
        if ($null -ne $BoundParameters -and $BoundParameters.Contains($key)) { $location[$key] = $BoundParameters[$key] }
    }
    $prefix = $WordToComplete.Trim('"', "'")
    try {
        $request = New-TaskEngineRequest -Action List @location -Extra @{ All = $true; Sort = 'alphanumeric'; IncludeStatus = $false }
        $result = Invoke-TaskEngine -Request $request
    }
    catch { return }
    if (-not $result.Ok) { return }
    foreach ($task in $result.Data) {
        if ($task.Name -notlike "$prefix*") { continue }
        $text = if ($task.Name -match '[\s''"`$;|&(){}<>,#]') { "'" + $task.Name.Replace("'", "''") + "'" } else { $task.Name }
        $toolTip = if ([string]::IsNullOrEmpty($task.Description)) { $task.Name } else { $task.Description }
        [System.Management.Automation.CompletionResult]::new($text, $task.Name, 'ParameterValue', $toolTip)
    }
}
