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
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet,
        [Parameter(Mandatory)][hashtable]$Request
    )
    # Assigned in a statement: an `if` expression would enumerate the (empty) collection.
    $sink = $null
    if ($Request.PassThru) { $sink = [System.Collections.Concurrent.BlockingCollection[object]]::new() }
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
