using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Collections.Specialized
using namespace System.Management.Automation

# Task execution. The flow of RunTask mirrors go-task's Executor.RunTask.
#
# $ctx is the run context shared by every branch (see TaskEngine.NewContext). A "branch" is
# one thread of execution: the root, or one of the tasks started in parallel (deps and
# -Parallel). Each branch has its own runspace with this module imported.

[NoRunspaceAffinity()]
class TaskExecutor {
    static [int] $MaximumTaskCall = 1000
    static [int] $MaximumDepth = 100

    # Nested task calls continue on a fresh thread every few levels. An exception that
    # travels up through many catch/rethrow layers needs a lot of stack on each layer, so an
    # unbounded chain on one thread could overflow the stack instead of failing cleanly.
    static [int] $HopInterval = 8

    static [object] NewCall([string] $task, [OrderedDictionary] $vars, [bool] $silent, [bool] $indirect, [int] $depth) {
        $callVars = [OrderedDictionary]::new()
        if ($null -ne $vars) { foreach ($key in $vars.get_Keys()) { $callVars[[string]$key] = $vars[$key] } }
        return [pscustomobject]@{ Task = $task; Vars = $callVars; Silent = $silent; Indirect = $indirect; Depth = $depth }
    }

    static [string] TaskName([object] $task) {
        if ([string]::IsNullOrEmpty($task.Label)) { return $task.Task }
        return $task.Label
    }

    hidden static [Exception] CommandError([string] $message, [int] $exitStatus) {
        $exception = [TaskError]::Create($message, [TaskError]::TaskRun)
        $exception.Data['TaskExitStatus'] = $exitStatus
        return $exception
    }

    # ---- task lookup -------------------------------------------------------------------------

    hidden static [int] Distance([string] $a, [string] $b) {
        $previous = [int[]]::new($b.Length + 1)
        for ($j = 0; $j -le $b.Length; $j++) { $previous[$j] = $j }
        for ($i = 1; $i -le $a.Length; $i++) {
            $current = [int[]]::new($b.Length + 1)
            $current[0] = $i
            for ($j = 1; $j -le $b.Length; $j++) {
                $cost = if ($a[$i - 1] -ceq $b[$j - 1]) { 0 } else { 1 }
                $current[$j] = [Math]::Min([Math]::Min($current[$j - 1] + 1, $previous[$j] + 1), $previous[$j - 1] + $cost)
            }
            $previous = $current
        }
        return $previous[$b.Length]
    }

    hidden static [string] Suggest([hashtable] $ctx, [string] $name) {
        $best = ''
        $bestDistance = [int]::MaxValue
        foreach ($task in $ctx.Taskfile.Tasks.get_Values()) {
            if ($task.Internal) { continue }
            foreach ($candidate in @($task.Task) + @($task.Aliases)) {
                $distance = [TaskExecutor]::Distance($name, $candidate)
                if ($distance -lt $bestDistance) { $bestDistance = $distance; $best = $candidate }
            }
        }
        if ($bestDistance -le [Math]::Max(2, [int]($name.Length / 2))) { return $best }
        return ''
    }

    # Captured wildcards when $name matches the task name (or an alias) pattern, else $null.
    hidden static [List[object]] WildcardMatch([object] $task, [string] $name) {
        foreach ($pattern in @($task.Task) + @($task.Aliases)) {
            $regex = '^' + [regex]::Escape($pattern).Replace('\*', '(.*)') + '$'
            $match = [regex]::Match($name, $regex)
            if (-not $match.Success) { continue }
            $wildcards = [List[object]]::new()
            for ($i = 1; $i -lt $match.Groups.Count; $i++) { $wildcards.Add($match.Groups[$i].Value) }
            return $wildcards
        }
        return $null
    }

    # Finds the task for a call: exact name, then wildcard patterns and aliases.
    static [object] FindTask([hashtable] $ctx, [object] $call) {
        $tasks = $ctx.Taskfile.Tasks
        if ($tasks.Contains($call.Task)) { return $tasks[$call.Task] }

        $found = [List[object]]::new()
        $wildcards = $null
        foreach ($task in $tasks.get_Values()) {
            $captured = [TaskExecutor]::WildcardMatch($task, $call.Task)
            if ($null -ne $captured) { $found.Add($task); $wildcards = $captured }
        }
        if ($found.Count -eq 1) {
            $call.Vars['MATCH'] = [TaskfileReader]::NewVar('static', $wildcards)
            return $found[0]
        }
        if ($found.Count -gt 1) {
            $names = [List[string]]::new()
            foreach ($task in $found) { $names.Add($task.Task) }
            throw [TaskError]::Create("task: Found multiple tasks ($([string]::Join(', ', $names))) that match `"$($call.Task)`"", [TaskError]::TaskNameConflict)
        }
        $message = "task: Task `"$($call.Task)`" does not exist"
        $suggestion = [TaskExecutor]::Suggest($ctx, $call.Task)
        if ($suggestion.Length -gt 0) { $message += ". Did you mean `"$suggestion`"?" }
        throw [TaskError]::Create($message, [TaskError]::TaskNotFound)
    }

    static [bool] PlatformMatches([object] $platforms) {
        if ($null -eq $platforms -or $platforms.Count -eq 0) { return $true }
        $os = [TplFn]::OS()
        $arch = [TplFn]::Arch()
        foreach ($platform in $platforms) {
            if (($platform.OS -eq '' -or $platform.OS -ceq $os) -and ($platform.Arch -eq '' -or $platform.Arch -ceq $arch)) { return $true }
        }
        return $false
    }

    # ---- concurrency ---------------------------------------------------------------------------

    hidden static [void] Acquire([hashtable] $ctx) {
        if ($null -eq $ctx.Semaphore) { return }
        while (-not $ctx.Semaphore.Wait(50)) { $ctx.Cancel.Token.ThrowIfCancellationRequested() }
    }

    hidden static [void] Release([hashtable] $ctx) {
        if ($null -ne $ctx.Semaphore) { [void]$ctx.Semaphore.Release() }
    }

    static [hashtable] RunBranch([hashtable] $ctx, [object] $call) {
        try {
            [TaskExecutor]::RunTask($ctx, $call)
            return @{ Ok = $true }
        }
        catch {
            if ([TaskScript]::IsStop($_.Exception)) { throw }
            $exception = [TaskError]::Unwrap($_.Exception)
            return @{
                Ok         = $false
                Message    = $exception.Message
                Code       = [TaskError]::CodeOf($exception)
                ExitStatus = $exception.Data['TaskExitStatus']
            }
        }
    }

    hidden static [hashtable] StartBranch([hashtable] $ctx, [object] $call) {
        $runspace = $null
        if (-not $ctx.IdleRunspaces.TryTake([ref] $runspace)) {
            $initialState = [initialsessionstate]::CreateDefault2()
            $initialState.ImportPSModule([string[]]@([string]$ctx.ModuleFile))
            $runspace = [runspacefactory]::CreateRunspace($ctx.Host, $initialState)
            $runspace.Open()
        }
        $shell = [powershell]::Create()
        $shell.Runspace = $runspace
        $entry = 'param($ctx, $call) & (Get-Module PS-TaskFile) { param($c, $k) [TaskExecutor]::RunBranch($c, $k) } $ctx $call'
        [void]$shell.AddScript($entry).AddArgument($ctx).AddArgument($call)
        return @{ Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke(); Done = $false }
    }

    # Runs the calls concurrently, each in its own branch. Throws the first failure.
    static [void] RunParallel([hashtable] $ctx, [List[object]] $calls, [bool] $failfast) {
        if ($calls.Count -eq 0) { return }
        if ($calls.Count -eq 1) {
            $only = $calls[0]
            if ($only.Depth -eq 0 -or ($only.Depth % [TaskExecutor]::HopInterval) -ne 0) {
                [TaskExecutor]::RunTask($ctx, $only)
                return
            }
        }

        $branches = [List[hashtable]]::new()
        $failure = $null
        try {
            foreach ($call in $calls) { $branches.Add([TaskExecutor]::StartBranch($ctx, $call)) }
            $pending = $branches.Count
            while ($pending -gt 0) {
                $progressed = $false
                foreach ($branch in $branches) {
                    if ($branch.Done -or -not $branch.Handle.IsCompleted) { continue }
                    $branch.Done = $true
                    $pending--
                    $progressed = $true
                    $result = $null
                    try {
                        $output = $branch.Shell.EndInvoke($branch.Handle)
                        if ($output.Count -gt 0) { $result = $output[0] }
                        if ($null -eq $result -and $branch.Shell.Streams.Error.Count -gt 0) {
                            $result = @{ Ok = $false; Message = $branch.Shell.Streams.Error[0].ToString(); Code = [TaskError]::Unknown; ExitStatus = $null }
                        }
                    }
                    catch {
                        if ($null -eq $failure) { $result = @{ Ok = $false; Message = 'task: cancelled'; Code = [TaskError]::TaskCancelled; ExitStatus = $null } }
                    }
                    if ($null -ne $result -and -not $result.Ok -and $null -eq $failure) {
                        $failure = $result
                        if ($failfast) {
                            foreach ($other in $branches) { if (-not $other.Done) { [void]$other.Shell.BeginStop($null, $null) } }
                        }
                    }
                }
                if (-not $progressed) {
                    $ctx.Cancel.Token.ThrowIfCancellationRequested()
                    Start-Sleep -Milliseconds 10
                }
            }
        }
        finally {
            foreach ($branch in $branches) {
                $reusable = $branch.Done
                if (-not $branch.Done) { try { $branch.Shell.Stop() } catch { } }
                $branch.Shell.Dispose()
                if ($reusable -and $branch.Runspace.RunspaceAvailability -eq [System.Management.Automation.Runspaces.RunspaceAvailability]::Available) {
                    $ctx.IdleRunspaces.Add($branch.Runspace)
                }
                else { $branch.Runspace.Dispose() }
            }
        }
        if ($null -ne $failure) {
            $exception = [TaskError]::Create([string]$failure.Message, [int]$failure.Code)
            if ($null -ne $failure.ExitStatus) { $exception.Data['TaskExitStatus'] = $failure.ExitStatus }
            throw $exception
        }
    }

    # ---- checks ----------------------------------------------------------------------------------

    hidden static [void] CheckRequiredVars([object] $task) {
        $missing = [List[string]]::new()
        foreach ($required in $task.Requires) {
            if ($task.Vars.Contains($required.Name)) { continue }
            $text = $required.Name
            if ($null -ne $required.Enum -and $required.Enum.Count -gt 0) { $text += " (allowed values: [$([string]::Join(' ', $required.Enum))])" }
            $missing.Add($text)
        }
        if ($missing.Count -gt 0) {
            $message = "task: Task `"$([TaskExecutor]::TaskName($task))`" cancelled because it is missing required variables: $([string]::Join(', ', $missing))"
            throw [TaskError]::Create($message, [TaskError]::TaskMissingRequiredVars)
        }
    }

    hidden static [void] CheckAllowedValues([object] $task) {
        $invalid = [List[string]]::new()
        foreach ($required in $task.Requires) {
            if ($null -eq $required.Enum -or $required.Enum.Count -eq 0 -or -not $task.Vars.Contains($required.Name)) { continue }
            $value = [TplFn]::Unwrap($task.Vars[$required.Name])
            if ($value -is [string] -and $required.Enum -cnotcontains $value) {
                $invalid.Add("  - $($required.Name) has an invalid value : '$value' (allowed values : [$([string]::Join(' ', $required.Enum))])")
            }
        }
        if ($invalid.Count -gt 0) {
            $message = "task: Task `"$([TaskExecutor]::TaskName($task))`" cancelled because it is missing required variables:`n$([string]::Join("`n", $invalid))`n"
            throw [TaskError]::Create($message, [TaskError]::TaskNotAllowedVars)
        }
    }

    hidden static [bool] IsSilent([hashtable] $ctx, [object] $task, [object] $call, [bool] $cmdSilent) {
        $taskSilent = if ($null -ne $task.Silent) { [bool]$task.Silent } else { [bool]$ctx.Taskfile.Silent }
        return $call.Silent -or $cmdSilent -or $taskSilent -or $ctx.Options.Silent
    }

    hidden static [bool] Condition([hashtable] $ctx, [object] $task, [string] $text) {
        return [TaskExecutor]::Condition($ctx, $task, $text, $null)
    }

    # Runs a condition script (status / precondition / if) with the environment and the
    # variables of the task; $extra are the variables of one command (loop variables).
    hidden static [bool] Condition([hashtable] $ctx, [object] $task, [string] $text, [IDictionary] $extra) {
        $variables = $task.ScriptVars
        if ($null -ne $extra -and $extra.get_Count() -gt 0) {
            $variables = [OrderedDictionary]::new()
            foreach ($key in $task.ScriptVars.get_Keys()) { $variables[[string]$key] = $task.ScriptVars[$key] }
            foreach ($key in $extra.get_Keys()) { $variables[[string]$key] = $extra[$key] }
        }
        [TaskEnv]::Enter($ctx.EnvGate, [TaskCompiler]::EnvOverrides($ctx, $task.Env), $ctx.Cancel.Token)
        try { return [TaskScript]::Test($text, $task.Dir, $variables) }
        finally { [TaskEnv]::Leave($ctx.EnvGate) }
    }

    static [string] Method([hashtable] $ctx, [object] $task) {
        if (-not [string]::IsNullOrEmpty($task.Method)) { return $task.Method }
        if (-not [string]::IsNullOrEmpty($ctx.Taskfile.Method)) { return $ctx.Taskfile.Method }
        return 'checksum'
    }

    # A task is up to date when its status commands succeed and/or its sources are unchanged.
    static [bool] IsUpToDate([hashtable] $ctx, [object] $task) {
        $statusSet = $task.Status.Count -gt 0
        $sourcesSet = $task.Sources.Count -gt 0
        $statusUpToDate = $true
        $sourcesUpToDate = $true
        if ($statusSet) {
            foreach ($status in $task.Status) {
                if ([TaskExecutor]::Condition($ctx, $task, $status)) {
                    [TaskLog]::Verbose($ctx, "task: status command $status exited zero")
                }
                else {
                    [TaskLog]::Verbose($ctx, "task: status command $status exited non-zero")
                    $statusUpToDate = $false
                    break
                }
            }
        }
        if ($sourcesSet) {
            $sourcesUpToDate = [TaskFingerprint]::IsUpToDate($task, [TaskExecutor]::Method($ctx, $task), [string]$ctx.TempDir, [bool]$ctx.Options.Dry)
        }
        if ($statusSet -and $sourcesSet) { return $statusUpToDate -and $sourcesUpToDate }
        if ($statusSet) { return $statusUpToDate }
        if ($sourcesSet) { return $sourcesUpToDate }
        return $false
    }

    hidden static [void] Prompt([hashtable] $ctx, [object] $task) {
        foreach ($prompt in $task.Prompt) {
            if ([string]::IsNullOrEmpty($prompt) -or $ctx.Options.Dry) { continue }
            if ($ctx.Options.AssumeYes) {
                [TaskLog]::Info($ctx, "$prompt [assuming yes]", 'Yellow')
                continue
            }
            if ([Console]::IsInputRedirected -or -not [Environment]::UserInteractive) {
                $message = "task: Task `"$($task.Task)`" cancelled because it has a prompt and the environment is not a terminal. Use -AssumeYes to run anyway."
                throw [TaskError]::Create($message, [TaskError]::TaskCancelled)
            }
            if ($ctx.Options.Color) { Write-Host "$prompt [y/N]: " -NoNewline -ForegroundColor Yellow } else { Write-Host "$prompt [y/N]: " -NoNewline }
            $answer = [string]$global:Host.UI.ReadLine()
            if ($answer.Trim().ToLowerInvariant() -notin @('y', 'yes')) {
                throw [TaskError]::Create("task: Task `"$($task.Task)`" cancelled by user", [TaskError]::TaskCancelled)
            }
        }
    }

    # ---- commands ----------------------------------------------------------------------------------

    hidden static [string] OutputStyle([hashtable] $ctx, [object] $task) {
        if ($task.Interactive) { return 'interleaved' }
        return [string]$ctx.Output.Name
    }

    # Runs the PowerShell of one command with the output style of the run.
    hidden static [object] RunScript([hashtable] $ctx, [object] $task, [object] $cmd, [object] $scope) {
        $style = [TaskExecutor]::OutputStyle($ctx, $task)
        $mode = 'host'
        $target = $null
        $buffer = $null
        if ($style -eq 'group') {
            $buffer = [List[string]]::new()
            $mode = 'lines'
            $target = @{ Buffer = $buffer; Sink = $null; UI = $null; Prefix = '' }
        }
        elseif ($style -eq 'prefixed') {
            $mode = 'lines'
            $target = @{ Buffer = $null; Sink = $ctx.Sink; UI = $global:Host.UI; Prefix = "[$($task.Prefix)] " }
        }
        elseif ($null -ne $ctx.Sink) {
            $mode = 'stream'
            $target = $ctx.Sink
        }

        # `set:` options are mapped onto their PowerShell counterparts.
        $options = @($ctx.Taskfile.Set) + @($task.Set) + @($cmd.Set)
        $strictNative = $options -contains 'errexit' -or $options -contains 'e' -or $options -contains 'pipefail'
        $trace = $options -contains 'xtrace' -or $options -contains 'x'
        $text = [string]$cmd.Cmd
        if ($options -contains 'nounset' -or $options -contains 'u') { $text = "Set-StrictMode -Version Latest`n$text" }
        if ($strictNative) { $scope.SessionState.PSVariable.Set('PSNativeCommandUseErrorActionPreference', $true) }
        if ($trace) { Set-PSDebug -Trace 1 }

        $result = $null
        [TaskEnv]::Enter($ctx.EnvGate, [TaskCompiler]::EnvOverrides($ctx, $task.Env), $ctx.Cancel.Token)
        try { $result = [TaskScript]::Invoke($text, $scope, $task.Dir, $mode, $target) }
        finally {
            [TaskEnv]::Leave($ctx.EnvGate)
            if ($trace) { Set-PSDebug -Off }
            if ($strictNative) { $scope.SessionState.PSVariable.Set('PSNativeCommandUseErrorActionPreference', $false) }
        }

        if ($null -ne $result.Error) {
            $native = $result.Error.Exception -as [System.Management.Automation.NativeCommandExitException]
            if ($null -ne $native) {
                $result.ExitCode = $native.ExitCode
                $result.Message = "exit status $($native.ExitCode)"
            }
            # Show the error like the failing command would have shown it.
            if ($mode -eq 'lines') {
                $lines = @($result.Error | Out-String -Stream | Where-Object { $_ -ne '' })
                if ($null -ne $buffer) { $buffer.AddRange([string[]]$lines) }
                else { [TaskLog]::Lines($ctx, @($lines | ForEach-Object { $target.Prefix + $_ })) }
            }
            else { [TaskLog]::Error($ctx, $result.Error) }
        }

        if ($null -ne $buffer -and -not ($ctx.Output.ErrorOnly -and $result.ExitCode -eq 0)) {
            $cache = [TaskCompiler]::NewCache($task.Vars)
            $lines = [List[string]]::new()
            if (-not [string]::IsNullOrEmpty($ctx.Output.Begin)) { $lines.Add([TaskCompiler]::Replace($cache, $ctx.Output.Begin, $null)) }
            $lines.AddRange($buffer)
            if (-not [string]::IsNullOrEmpty($ctx.Output.End)) { $lines.Add([TaskCompiler]::Replace($cache, $ctx.Output.End, $null)) }
            [System.Threading.Monitor]::Enter($ctx.OutputLock)
            try { [TaskLog]::Lines($ctx, $lines) }
            finally { [System.Threading.Monitor]::Exit($ctx.OutputLock) }
        }
        return $result
    }

    hidden static [void] RunCommand([hashtable] $ctx, [object] $task, [object] $call, [object] $cmd, [object] $scope) {
        $name = [TaskExecutor]::TaskName($task)
        if (-not [string]::IsNullOrEmpty($cmd.Task)) {
            [TaskExecutor]::Release($ctx)
            try {
                $calls = [List[object]]::new()
                $calls.Add([TaskExecutor]::NewCall($cmd.Task, $cmd.Vars, $cmd.Silent, $true, $call.Depth + 1))
                [TaskExecutor]::RunParallel($ctx, $calls, $false)
            }
            catch {
                if ([TaskScript]::IsStop($_.Exception) -or -not $cmd.IgnoreError) { throw }
                [TaskLog]::Verbose($ctx, "task: [$name] command error ignored: $([TaskError]::Unwrap($_.Exception).Message)")
            }
            finally { [TaskExecutor]::Acquire($ctx) }
            return
        }
        if ([string]::IsNullOrEmpty($cmd.Cmd)) { return }
        if (-not [TaskExecutor]::PlatformMatches($cmd.Platforms)) {
            [TaskLog]::Verbose($ctx, "task: [$name] $($cmd.Cmd) not for current platform - ignored")
            return
        }
        if (-not [string]::IsNullOrEmpty($cmd.If) -and -not $ctx.Options.Dry -and -not [TaskExecutor]::Condition($ctx, $task, $cmd.If, $cmd.ScriptVars)) {
            [TaskLog]::Verbose($ctx, "task: [$name] if condition not met - skipped")
            return
        }
        if ($ctx.Options.Verbose -or -not [TaskExecutor]::IsSilent($ctx, $task, $call, $cmd.Silent)) {
            [TaskLog]::Info($ctx, "task: [$name] $($cmd.Cmd)", 'Green')
        }
        if ($ctx.Options.Dry) { return }

        # The loop variables of this iteration (or EXIT_CODE of a deferred command).
        $null = [TaskScript]::SetVariables($scope, $cmd.ScriptVars)
        $result = [TaskExecutor]::RunScript($ctx, $task, $cmd, $scope)
        if ($result.ExitCode -eq 0) { return }
        if ($cmd.IgnoreError) {
            [TaskLog]::Verbose($ctx, "task: [$name] command error ignored: $($result.Message)")
            return
        }
        throw [TaskExecutor]::CommandError($result.Message, $result.ExitCode)
    }

    hidden static [void] RunDeps([hashtable] $ctx, [object] $task, [object] $call) {
        if ($task.Deps.Count -eq 0) { return }
        $calls = [List[object]]::new()
        foreach ($dep in $task.Deps) { $calls.Add([TaskExecutor]::NewCall($dep.Task, $dep.Vars, $dep.Silent, $true, $call.Depth + 1)) }
        [TaskExecutor]::Release($ctx)
        try { [TaskExecutor]::RunParallel($ctx, $calls, $ctx.Options.Failfast -or $task.Failfast) }
        finally { [TaskExecutor]::Acquire($ctx) }
    }

    # ---- task -----------------------------------------------------------------------------------

    hidden static [void] ExecuteCore([hashtable] $ctx, [object] $task, [object] $call) {
        $name = [TaskExecutor]::TaskName($task)
        [TaskLog]::Verbose($ctx, "task: `"$($call.Task)`" started")
        [TaskExecutor]::RunDeps($ctx, $task, $call)

        $skipFingerprinting = $ctx.Options.ForceAll -or (-not $call.Indirect -and $ctx.Options.Force)
        if (-not $skipFingerprinting) {
            $ctx.Cancel.Token.ThrowIfCancellationRequested()
            foreach ($precondition in $task.Preconditions) {
                if (-not [TaskExecutor]::Condition($ctx, $task, $precondition.Sh)) {
                    [TaskLog]::Info($ctx, "task: $($precondition.Msg)", 'Magenta')
                    throw [TaskError]::Create('task: precondition not met', [TaskError]::Unknown)
                }
            }
            if ([TaskExecutor]::IsUpToDate($ctx, $task)) {
                if ($ctx.Options.Verbose -or -not [TaskExecutor]::IsSilent($ctx, $task, $call, $false)) {
                    [TaskLog]::Info($ctx, "task: Task `"$name`" is up to date", 'Magenta')
                }
                return
            }
        }

        [TaskExecutor]::Prompt($ctx, $task)
        if (-not $ctx.Options.Dry -and -not [System.IO.Directory]::Exists($task.Dir)) {
            try { $null = [System.IO.Directory]::CreateDirectory($task.Dir) }
            catch { [TaskLog]::Info($ctx, "task: cannot make directory `"$($task.Dir)`": $($_.Exception.Message)", 'Red') }
        }

        # The variables become PowerShell variables once, when the scope is created: a command
        # may reassign them for the commands that follow.
        $scope = [TaskScript]::NewScope()
        foreach ($skipped in [TaskScript]::SetVariables($scope, $task.ScriptVars)) {
            [TaskLog]::Verbose($ctx, "task: [$name] variable `"$skipped`" is reserved by PowerShell and is not available as `$$skipped")
        }
        $deferred = [List[object]]::new()
        $exitCode = 0
        try {
            foreach ($cmd in $task.Cmds) {
                if ($cmd.Defer) { $deferred.Add($cmd); continue }
                $ctx.Cancel.Token.ThrowIfCancellationRequested()
                try { [TaskExecutor]::RunCommand($ctx, $task, $call, $cmd, $scope) }
                catch {
                    if ([TaskScript]::IsStop($_.Exception)) { throw }
                    $failure = [TaskError]::Unwrap($_.Exception)
                    try { [TaskFingerprint]::OnError($task, [TaskExecutor]::Method($ctx, $task), [string]$ctx.TempDir) } catch { }
                    if ($task.IgnoreError -and $null -ne $failure.Data['TaskExitStatus']) {
                        [TaskLog]::Verbose($ctx, "task: task error ignored: $($failure.Message)")
                        continue
                    }
                    if ($null -ne $failure.Data['TaskExitStatus']) { $exitCode = [int]$failure.Data['TaskExitStatus'] }
                    throw $failure
                }
            }
        }
        finally {
            for ($i = $deferred.Count - 1; $i -ge 0; $i--) {
                $extra = [OrderedDictionary]::new()
                if ($exitCode -gt 0) { $extra['EXIT_CODE'] = [string]$exitCode }
                $cache = [TaskCompiler]::NewCache($task.Vars)
                $cmd = [TaskCompiler]::ReplaceCmd($cache, $deferred[$i], $extra)
                try { [TaskExecutor]::RunCommand($ctx, $task, $call, $cmd, $scope) }
                catch {
                    if (-not [TaskScript]::IsStop($_.Exception)) {
                        [TaskLog]::Verbose($ctx, "task: ignored error in deferred cmd: $([TaskError]::Unwrap($_.Exception).Message)")
                    }
                }
            }
        }
        [TaskLog]::Verbose($ctx, "task: `"$($call.Task)`" finished")
    }

    hidden static [void] Execute([hashtable] $ctx, [object] $task, [object] $call) {
        try { [TaskExecutor]::ExecuteCore($ctx, $task, $call) }
        catch {
            if ([TaskScript]::IsStop($_.Exception)) { throw }
            $inner = [TaskError]::Unwrap($_.Exception)
            # Not wrapped: the message would repeat for every level of a runaway recursion.
            if ([TaskError]::CodeOf($inner) -eq [TaskError]::TaskCalledTooManyTimes) { throw $inner }
            $wrapped = [TaskError]::Create("task: Failed to run task `"$($task.Task)`": $($inner.Message)", [TaskError]::TaskRun, $inner)
            if ($null -ne $inner.Data['TaskExitStatus']) { $wrapped.Data['TaskExitStatus'] = $inner.Data['TaskExitStatus'] }
            throw $wrapped
        }
    }

    # Applies `run: once / when_changed`: identical executions run once, the others wait.
    hidden static [void] StartExecution([hashtable] $ctx, [object] $task, [object] $call) {
        $run = if (-not [string]::IsNullOrEmpty($task.Run)) { $task.Run } elseif (-not [string]::IsNullOrEmpty($ctx.Taskfile.Run)) { $ctx.Taskfile.Run } else { 'always' }
        $hash = ''
        if ($run -eq 'once') { $hash = "once:$($task.Task)" }
        elseif ($run -eq 'when_changed') { $hash = "when_changed:$($task.Task):" + [TplFn]::ToJson($task.Vars, $false, '', '') }
        elseif ($run -ne 'always') { throw [TaskError]::Create("task: invalid run `"$run`"", [TaskError]::TaskfileInvalid) }
        if ($hash.Length -eq 0) { [TaskExecutor]::Execute($ctx, $task, $call); return }

        $signal = [System.Threading.ManualResetEventSlim]::new($false)
        $existing = $ctx.ExecutionHashes.GetOrAdd($hash, $signal)
        if (-not [object]::ReferenceEquals($existing, $signal)) {
            $signal.Dispose()
            [TaskLog]::Verbose($ctx, "task: skipping execution of task: $($task.Task)")
            [TaskExecutor]::Release($ctx)
            try { while (-not $existing.Wait(50)) { $ctx.Cancel.Token.ThrowIfCancellationRequested() } }
            finally { [TaskExecutor]::Acquire($ctx) }
            return
        }
        try { [TaskExecutor]::Execute($ctx, $task, $call) }
        finally { $signal.Set() }
    }

    static [void] RunTask([hashtable] $ctx, [object] $call) {
        $ctx.Cancel.Token.ThrowIfCancellationRequested()
        $original = [TaskExecutor]::FindTask($ctx, $call)
        $fast = [TaskCompiler]::Compile($ctx, $original, $call, $false)
        if (-not [TaskExecutor]::PlatformMatches($fast.Platforms)) {
            [TaskLog]::Verbose($ctx, "task: `"$($call.Task)`" not for current platform - ignored")
            return
        }
        [TaskExecutor]::CheckRequiredVars($fast)

        $task = [TaskCompiler]::Compile($ctx, $original, $call, $true)
        [TaskExecutor]::CheckAllowedValues($task)

        $count = 0
        [System.Threading.Monitor]::Enter($ctx.Lock)
        try {
            $count = [int]$ctx.CallCounts[$task.Task] + 1
            $ctx.CallCounts[$task.Task] = $count
        }
        finally { [System.Threading.Monitor]::Exit($ctx.Lock) }
        if (-not $ctx.Options.Watch -and ($count -ge [TaskExecutor]::MaximumTaskCall -or $call.Depth -ge [TaskExecutor]::MaximumDepth)) {
            $message = "task: Maximum task call exceeded ($([TaskExecutor]::MaximumTaskCall)) for task `"$($task.Task)`": probably an cyclic dep or infinite loop"
            throw [TaskError]::Create($message, [TaskError]::TaskCalledTooManyTimes)
        }

        if (-not [string]::IsNullOrEmpty($task.If) -and -not $ctx.Options.Dry -and -not [TaskExecutor]::Condition($ctx, $task, $task.If)) {
            [TaskLog]::Verbose($ctx, "task: if condition not met - skipped: `"$($call.Task)`"")
            return
        }

        [TaskExecutor]::Acquire($ctx)
        try { [TaskExecutor]::StartExecution($ctx, $task, $call) }
        finally { [TaskExecutor]::Release($ctx) }
    }
}

[NoRunspaceAffinity()]
class TaskEngine {
    # Converts values passed from PowerShell (-Variable) to the engine's collection types.
    static [object] Normalize([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($v -is [IDictionary]) {
            $dict = [OrderedDictionary]::new()
            foreach ($key in @($v.get_Keys())) { $dict[[string]$key] = [TaskEngine]::Normalize($v[$key]) }
            return $dict
        }
        if ([TplFn]::IsList($v)) {
            $list = [List[object]]::new()
            foreach ($item in $v) { $list.Add([TaskEngine]::Normalize($item)) }
            return $list
        }
        return $v
    }

    hidden static [string] QuoteArgument([string] $argument) {
        if ($argument.Length -gt 0 -and $argument -notmatch '[\s''"`$;|&(){}<>@#,]') { return $argument }
        return [TplFn]::ShellQuote($argument)
    }

    # Builds the shared run context from the request of the calling cmdlet.
    static [hashtable] NewContext([hashtable] $request) {
        $found = [TaskfileReader]::Find([string]$request.Taskfile, [string]$request.Directory, [bool]$request.Global, [string]$request.WorkingDirectory)
        $taskfile = [TaskfileReader]::Load($found.Entrypoint, $found.Dir)
        $options = $request.Options

        $tempDir = [Environment]::GetEnvironmentVariable('TASK_TEMP_DIR')
        if ([string]::IsNullOrEmpty($tempDir)) { $tempDir = '.task' }
        $tempDir = [TaskPath]::Full($found.Dir, $tempDir)

        $output = @{
            Name      = if (-not [string]::IsNullOrEmpty($options.Output)) { $options.Output } elseif ($taskfile.Output.Name.Length -gt 0) { $taskfile.Output.Name } else { 'interleaved' }
            Begin     = if (-not [string]::IsNullOrEmpty($options.OutputGroupBegin)) { $options.OutputGroupBegin } else { $taskfile.Output.Group.Begin }
            End       = if (-not [string]::IsNullOrEmpty($options.OutputGroupEnd)) { $options.OutputGroupEnd } else { $taskfile.Output.Group.End }
            ErrorOnly = $options.OutputGroupErrorOnly -or $taskfile.Output.Group.ErrorOnly
        }

        $ctx = @{
            Taskfile        = $taskfile
            Dir             = $found.Dir
            Entrypoint      = $found.Entrypoint
            UserWorkingDir  = [string]$request.WorkingDirectory
            Version         = [string]$request.Version
            TempDir         = $tempDir
            Options         = $options
            Output          = $output
            BaseEnv         = [TaskEnv]::Snapshot()
            EnvPrecedence   = [Environment]::GetEnvironmentVariable('TASK_X_ENV_PRECEDENCE') -eq '1'
            DynamicCache    = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
            ExecutionHashes = [System.Collections.Concurrent.ConcurrentDictionary[string, System.Threading.ManualResetEventSlim]]::new()
            CallCounts      = [hashtable]::new([StringComparer]::Ordinal)
            Lock            = [object]::new()
            OutputLock      = [object]::new()
            EnvGate         = [TaskEnv]::NewGate()
            Semaphore       = if ([int]$options.Concurrency -gt 0) { [System.Threading.SemaphoreSlim]::new([int]$options.Concurrency) } else { $null }
            Cancel          = [System.Threading.CancellationTokenSource]::new()
            Sink            = $request.Sink
            ModuleFile      = [string]$request.ModuleFile
            Host            = $global:Host
            IdleRunspaces   = [System.Collections.Concurrent.ConcurrentBag[object]]::new()
        }

        # Variables given on the command line override the global vars of the Taskfile.
        if ($null -ne $request.Variables) {
            foreach ($key in $request.Variables.get_Keys()) {
                $taskfile.Vars[[string]$key] = [TaskfileReader]::NewVar('static', [TaskEngine]::Normalize($request.Variables[$key]))
            }
        }
        $arguments = [List[object]]::new()
        $quoted = [List[string]]::new()
        foreach ($argument in @($request.ArgumentList)) {
            if ($null -eq $argument) { continue }
            $arguments.Add([string]$argument)
            $quoted.Add([TaskEngine]::QuoteArgument([string]$argument))
        }
        $taskfile.Vars['CLI_ARGS'] = [TaskfileReader]::NewVar('static', [string]::Join(' ', $quoted))
        $taskfile.Vars['CLI_ARGS_LIST'] = [TaskfileReader]::NewVar('static', $arguments)
        $taskfile.Vars['CLI_FORCE'] = [TaskfileReader]::NewVar('static', [bool]$options.Force)
        $taskfile.Vars['CLI_SILENT'] = [TaskfileReader]::NewVar('static', [bool]$options.Silent)
        $taskfile.Vars['CLI_VERBOSE'] = [TaskfileReader]::NewVar('static', [bool]$options.Verbose)
        $taskfile.Vars['CLI_OFFLINE'] = [TaskfileReader]::NewVar('static', $false)
        $taskfile.Vars['CLI_ASSUME_YES'] = [TaskfileReader]::NewVar('static', [bool]$options.AssumeYes)

        # dotenv files of the root Taskfile never override its env entries.
        if ($taskfile.Dotenv.Count -gt 0) {
            $cache = [TaskCompiler]::NewCache([TaskCompiler]::GetVariables($ctx, $null, $null, $true))
            foreach ($path in $taskfile.Dotenv) {
                $file = [TaskPath]::SmartJoin($found.Dir, [TaskPath]::ExpandHome([TaskCompiler]::Replace($cache, $path, $null)))
                if (-not [System.IO.File]::Exists($file)) { continue }
                $values = [TaskDotenv]::Read($file)
                foreach ($key in $values.get_Keys()) {
                    if (-not $taskfile.Env.Contains($key)) { $taskfile.Env[[string]$key] = [TaskfileReader]::NewVar('static', [string]$values[$key]) }
                }
            }
        }
        return $ctx
    }

    hidden static [void] Cleanup([hashtable] $ctx) {
        try { [TaskEnv]::Restore($ctx.BaseEnv) } catch { }
        $runspace = $null
        while ($ctx.IdleRunspaces.TryTake([ref] $runspace)) { try { $runspace.Dispose() } catch { } }
        foreach ($signal in $ctx.ExecutionHashes.get_Values()) { try { $signal.Dispose() } catch { } }
        if ($null -ne $ctx.Semaphore) { $ctx.Semaphore.Dispose() }
        $ctx.Cancel.Dispose()
    }

    hidden static [List[object]] NewCalls([hashtable] $ctx, [object] $names) {
        $calls = [List[object]]::new()
        foreach ($name in @($names)) { $calls.Add([TaskExecutor]::NewCall([string]$name, $null, $false, $false, 0)) }
        if ($calls.Count -eq 0) { $calls.Add([TaskExecutor]::NewCall('default', $null, $false, $false, 0)) }
        # Every requested task must exist and be callable before anything runs.
        foreach ($call in $calls) {
            $task = [TaskExecutor]::FindTask($ctx, $call)
            if ($task.Internal) { throw [TaskError]::Create("task: Task `"$($call.Task)`" is internal", [TaskError]::TaskInternal) }
        }
        return $calls
    }

    # Prints the tasks with a description in the layout of `task --list`.
    hidden static [void] PrintTaskList([hashtable] $ctx) {
        $tasks = [TaskEngine]::ListTasks($ctx, @{ Names = @(); All = $false; Sort = 'default'; IncludeStatus = $false })
        if ($tasks.Count -eq 0) {
            [TaskLog]::Info($ctx, 'task: No tasks with description available. Try Get-Task -All to list all tasks', 'Yellow')
            return
        }
        [TaskLog]::Info($ctx, 'task: Available tasks for this project:', '')
        $nameWidth = 0
        foreach ($task in $tasks) { $nameWidth = [Math]::Max($nameWidth, "* $($task.Name): ".Length) }
        # The description column is aligned among consecutive tasks that have aliases.
        $descriptionWidth = [int[]]::new($tasks.Count)
        $i = 0
        while ($i -lt $tasks.Count) {
            if ($tasks[$i].Aliases.Count -eq 0) { $i++; continue }
            $end = $i
            $width = 0
            while ($end -lt $tasks.Count -and $tasks[$end].Aliases.Count -gt 0) { $width = [Math]::Max($width, $tasks[$end].Description.Length); $end++ }
            for ($k = $i; $k -lt $end; $k++) { $descriptionWidth[$k] = $width + 6 }
            $i = $end
        }
        for ($i = 0; $i -lt $tasks.Count; $i++) {
            $task = $tasks[$i]
            $line = "* $($task.Name): ".PadRight($nameWidth + 6)
            if ($task.Aliases.Count -gt 0) { $line += $task.Description.PadRight($descriptionWidth[$i]) + "(aliases: $([string]::Join(', ', $task.Aliases)))" }
            else { $line += $task.Description }
            [TaskLog]::Info($ctx, $line, '')
        }
    }

    hidden static [object] RunTasks([hashtable] $ctx, [hashtable] $request) {
        $calls = $null
        try { $calls = [TaskEngine]::NewCalls($ctx, $request.Names) }
        catch {
            # Like `task`, show what is available when the name is unknown.
            $failure = [TaskError]::Unwrap($_.Exception)
            if ([TaskError]::CodeOf($failure) -eq [TaskError]::TaskNotFound) { try { [TaskEngine]::PrintTaskList($ctx) } catch { } }
            throw $failure
        }
        # Tasks marked `watch: true` (or everything with -Watch) are watched after the others ran.
        $regular = [List[object]]::new()
        $watched = [List[object]]::new()
        foreach ($call in $calls) {
            if ($ctx.Options.Watch -or [TaskExecutor]::FindTask($ctx, $call).Watch) { $watched.Add($call) } else { $regular.Add($call) }
        }
        if ($ctx.Options.Parallel) { [TaskExecutor]::RunParallel($ctx, $regular, [bool]$ctx.Options.Failfast) }
        else { foreach ($call in $regular) { [TaskExecutor]::RunTask($ctx, $call) } }
        if ($watched.Count -gt 0) {
            $ctx.Options.Watch = $true
            [TaskEngine]::WatchTasks($ctx, $watched)
        }
        return $null
    }

    # ---- watch ---------------------------------------------------------------------------------

    hidden static [void] CollectSources([hashtable] $ctx, [string] $name, [HashSet[string]] $visited, [SortedSet[string]] $files) {
        if (-not $visited.Add($name)) { return }
        $task = $null
        try {
            $call = [TaskExecutor]::NewCall($name, $null, $false, $true, 0)
            $task = [TaskCompiler]::Compile($ctx, [TaskExecutor]::FindTask($ctx, $call), $call, $false)
        }
        catch { return }
        foreach ($file in [TaskGlob]::Expand($task.Dir, $task.Sources)) { [void]$files.Add($file) }
        foreach ($dep in $task.Deps) { [TaskEngine]::CollectSources($ctx, $dep.Task, $visited, $files) }
        foreach ($cmd in $task.Cmds) {
            if (-not [string]::IsNullOrEmpty($cmd.Task)) { [TaskEngine]::CollectSources($ctx, $cmd.Task, $visited, $files) }
        }
    }

    # A fingerprint of every source file of the watched tasks (and of the tasks they use).
    hidden static [string] WatchSignature([hashtable] $ctx, [List[object]] $calls) {
        $files = [SortedSet[string]]::new([StringComparer]::Ordinal)
        $visited = [HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($call in $calls) { [TaskEngine]::CollectSources($ctx, $call.Task, $visited, $files) }
        $sb = [System.Text.StringBuilder]::new()
        foreach ($file in $files) {
            $info = [System.IO.FileInfo]::new($file)
            if ($info.Exists) { [void]$sb.Append($file).Append('|').Append($info.LastWriteTimeUtc.Ticks).Append('|').Append($info.Length).Append("`n") }
        }
        return $sb.ToString()
    }

    hidden static [int] WatchInterval([hashtable] $ctx) {
        $text = [string]$ctx.Options.Interval
        if ([string]::IsNullOrEmpty($text)) { $text = [string]$ctx.Taskfile.Interval }
        if ([string]::IsNullOrEmpty($text)) { return 500 }
        $milliseconds = 0
        try { $milliseconds = [int][TplFn]::ParseDuration($text).TotalMilliseconds }
        catch { throw [TaskError]::Create("task: invalid interval `"$text`" (use a duration such as 500ms or 2s)", [TaskError]::TaskfileInvalid) }
        return [Math]::Max($milliseconds, 20)
    }

    # Runs the calls and returns $true when a source changed before they finished.
    hidden static [bool] RunWatched([hashtable] $ctx, [List[object]] $calls, [string] $signature, [int] $interval) {
        foreach ($call in $calls) {
            $branch = [TaskExecutor]::StartBranch($ctx, [TaskExecutor]::NewCall($call.Task, $call.Vars, $call.Silent, $false, 0))
            $finished = $false
            try {
                while (-not $branch.Handle.IsCompleted) {
                    Start-Sleep -Milliseconds ([Math]::Min($interval, 100))
                    if ([TaskEngine]::WatchSignature($ctx, $calls) -cne $signature) { return $true }
                }
                $finished = $true
                $output = $branch.Shell.EndInvoke($branch.Handle)
                if ($output.Count -gt 0 -and -not $output[0].Ok) { [TaskLog]::Info($ctx, [string]$output[0].Message, 'Red') }
            }
            finally {
                if (-not $finished) { try { $branch.Shell.Stop() } catch { } }
                $branch.Shell.Dispose()
                $branch.Runspace.Dispose()
            }
        }
        return $false
    }

    # Runs the tasks, then again whenever one of their sources changes. Only stops when the
    # caller is stopped (Ctrl+C).
    hidden static [void] WatchTasks([hashtable] $ctx, [List[object]] $calls) {
        $names = [List[string]]::new()
        foreach ($call in $calls) { $names.Add($call.Task) }
        $interval = [TaskEngine]::WatchInterval($ctx)
        [TaskLog]::Info($ctx, "task: Started watching for tasks: $([string]::Join(', ', $names))", 'Green')
        while ($true) {
            $signature = [TaskEngine]::WatchSignature($ctx, $calls)
            foreach ($signal in $ctx.ExecutionHashes.get_Values()) { try { $signal.Dispose() } catch { } }
            $ctx.ExecutionHashes.Clear()
            $ctx.CallCounts.Clear()
            $ctx.DynamicCache.Clear()
            if ([TaskEngine]::RunWatched($ctx, $calls, $signature, $interval)) { continue }
            while ([TaskEngine]::WatchSignature($ctx, $calls) -ceq $signature) { Start-Sleep -Milliseconds $interval }
        }
    }

    # ---- listing, summary and status -------------------------------------------------------------

    hidden static [bool] IsNamespaced([string] $name) { return $name.Contains(':') }

    # Tasks for Get-Task: never internal ones; without -All only tasks with a description
    # (unless they were asked for by name).
    hidden static [object] ListTasks([hashtable] $ctx, [hashtable] $request) {
        $patterns = [List[System.Management.Automation.WildcardPattern]]::new()
        foreach ($name in @($request.Names)) {
            if (-not [string]::IsNullOrEmpty($name)) { $patterns.Add([System.Management.Automation.WildcardPattern]::new([string]$name, 'IgnoreCase')) }
        }
        $selected = [List[object]]::new()
        foreach ($task in $ctx.Taskfile.Tasks.get_Values()) {
            if ($task.Internal) { continue }
            if ($patterns.Count -gt 0) {
                $matched = $false
                foreach ($pattern in $patterns) {
                    foreach ($candidate in @($task.Task) + @($task.Aliases)) { if ($pattern.IsMatch($candidate)) { $matched = $true } }
                }
                if (-not $matched) { continue }
            }
            elseif (-not $request.All -and [string]::IsNullOrEmpty($task.Desc)) { continue }
            $selected.Add($task)
        }

        $sort = [string]$request.Sort
        if ($sort -ne 'none') {
            $names = [List[string]]::new()
            foreach ($task in $selected) { $names.Add($task.Task) }
            $array = $names.ToArray()
            [Array]::Sort($array, [StringComparer]::Ordinal)
            $ordered = [List[object]]::new()
            if ($sort -ne 'alphanumeric') {
                # default: tasks of the root Taskfile first, then the namespaced ones
                foreach ($name in $array) { if (-not [TaskEngine]::IsNamespaced($name)) { $ordered.Add($ctx.Taskfile.Tasks[$name]) } }
                foreach ($name in $array) { if ([TaskEngine]::IsNamespaced($name)) { $ordered.Add($ctx.Taskfile.Tasks[$name]) } }
            }
            else { foreach ($name in $array) { $ordered.Add($ctx.Taskfile.Tasks[$name]) } }
            $selected = $ordered
        }

        # Status checks for a listing never update the stored fingerprints.
        if ($request.IncludeStatus) { $ctx.Options.Dry = $true }
        $result = [List[object]]::new()
        foreach ($task in $selected) {
            $call = [TaskExecutor]::NewCall($task.Task, $null, $false, $false, 0)
            $compiled = [TaskCompiler]::Compile($ctx, $task, $call, $false)
            $upToDate = $null
            if ($request.IncludeStatus) {
                try { $upToDate = [TaskExecutor]::IsUpToDate($ctx, $compiled) } catch { $upToDate = $false }
            }
            $result.Add([pscustomobject]@{
                    Name        = $task.Task
                    Label       = $compiled.Label
                    Description = $compiled.Desc
                    Summary     = $compiled.Summary
                    Aliases     = $task.Aliases
                    UpToDate    = $upToDate
                    Location    = [pscustomobject]@{ Taskfile = $task.Location.Taskfile; Line = $task.Location.Line; Column = $task.Location.Column }
                })
        }
        return $result
    }

    # Value of a variable as `task --summary` prints it.
    hidden static [string] FormatVar([hashtable] $cache, [object] $var) {
        if ($var.Kind -eq 'sh' -and -not [string]::IsNullOrEmpty($var.Sh)) { return "sh: $([TaskCompiler]::Replace($cache, $var.Sh, $null))" }
        $value = $null
        if ($var.Kind -eq 'ref') { $value = [TaskCompiler]::ResolveRef($cache, $var.Ref, $null) }
        else { $value = [TaskCompiler]::ReplaceValue($cache, $var.Value, $null) }
        $value = [TplFn]::Unwrap($value)
        if ($null -eq $value) { return '""' }
        if ($value -is [IDictionary]) {
            $text = [System.Text.StringBuilder]::new()
            foreach ($key in $value.get_Keys()) { [void]$text.Append("`n    ${key}: $([TplFn]::Format($value[$key], $false))") }
            return $text.Append("`n").ToString()
        }
        return '"' + [TplFn]::Format($value, $false) + '"'
    }

    hidden static [void] AddVarLines([hashtable] $ctx, [List[string]] $lines, [string] $title, [OrderedDictionary] $vars, [hashtable] $cache, [string[]] $skip) {
        $entries = [List[string]]::new()
        foreach ($key in $vars.get_Keys()) {
            $name = [string]$key
            if ($ctx.BaseEnv.ContainsKey($name) -or $skip -ccontains $name) { continue }
            $entries.Add("  ${name}: $([TaskEngine]::FormatVar($cache, $vars[$key]))")
        }
        if ($entries.Count -eq 0) { return }
        $lines.Add('')
        $lines.Add("${title}:")
        foreach ($entry in $entries) { foreach ($line in $entry.Split("`n")) { $lines.Add($line) } }
    }

    # The text of `task --summary` for each task.
    hidden static [object] Summarize([hashtable] $ctx, [hashtable] $request) {
        $lines = [List[string]]::new()
        $calls = [TaskEngine]::NewCalls($ctx, $request.Names)
        $cliVars = @('CLI_ARGS', 'CLI_ARGS_LIST', 'CLI_FORCE', 'CLI_SILENT', 'CLI_VERBOSE', 'CLI_OFFLINE', 'CLI_ASSUME_YES')
        for ($i = 0; $i -lt $calls.Count; $i++) {
            if ($i -gt 0) { $lines.Add(''); $lines.Add('') }
            $call = $calls[$i]
            $original = [TaskExecutor]::FindTask($ctx, $call)
            $task = [TaskCompiler]::Compile($ctx, $original, $call, $false)
            $cache = [TaskCompiler]::NewCache($task.Vars)

            $lines.Add("task: $([TaskExecutor]::TaskName($task))")
            $lines.Add('')
            if (-not [string]::IsNullOrEmpty($task.Summary)) {
                $summary = $task.Summary.Replace("`r`n", "`n").Split("`n")
                for ($k = 0; $k -lt $summary.Count; $k++) {
                    if ($k + 1 -lt $summary.Count -or $summary[$k].Length -gt 0) { $lines.Add($summary[$k]) }
                }
            }
            elseif (-not [string]::IsNullOrEmpty($task.Desc)) { $lines.Add($task.Desc) }
            else { $lines.Add('(task does not have description or summary)') }

            $vars = [OrderedDictionary]::new()
            foreach ($key in $ctx.Taskfile.Vars.get_Keys()) { $vars[[string]$key] = $ctx.Taskfile.Vars[$key] }
            foreach ($key in $original.Vars.get_Keys()) { $vars[[string]$key] = $original.Vars[$key] }
            $environment = [OrderedDictionary]::new()
            foreach ($key in $ctx.Taskfile.Env.get_Keys()) { $environment[[string]$key] = $ctx.Taskfile.Env[$key] }
            foreach ($key in $original.Env.get_Keys()) { $environment[[string]$key] = $original.Env[$key] }
            $environmentNames = [List[string]]::new()
            foreach ($key in $environment.get_Keys()) { $environmentNames.Add([string]$key) }
            [TaskEngine]::AddVarLines($ctx, $lines, 'vars', $vars, $cache, [string[]]($cliVars + $environmentNames.ToArray()))
            [TaskEngine]::AddVarLines($ctx, $lines, 'env', $environment, $cache, [string[]]@())

            if ($task.Requires.Count -gt 0) {
                $lines.Add('')
                $lines.Add('requires:')
                $lines.Add('  vars:')
                foreach ($required in $task.Requires) {
                    if ($null -ne $required.Enum -and $required.Enum.Count -gt 0) {
                        $lines.Add("    - $($required.Name):")
                        $lines.Add('        enum:')
                        foreach ($value in $required.Enum) { $lines.Add("          - $value") }
                    }
                    else { $lines.Add("    - $($required.Name)") }
                }
            }
            if ($task.Deps.Count -gt 0) {
                $lines.Add('')
                $lines.Add('dependencies:')
                foreach ($dep in $task.Deps) { $lines.Add(" - $($dep.Task)") }
            }
            if ($task.Aliases.Count -gt 0) {
                $lines.Add('')
                $lines.Add('aliases:')
                foreach ($alias in $task.Aliases) { $lines.Add(" - $alias") }
            }
            if ($task.Cmds.Count -gt 0) {
                $lines.Add('')
                $lines.Add('commands:')
                foreach ($cmd in $task.Cmds) {
                    if (-not [string]::IsNullOrEmpty($cmd.Cmd)) { $lines.Add(" - $($cmd.Cmd)") } else { $lines.Add(" - Task: $($cmd.Task)") }
                }
            }
        }
        return $lines
    }

    # Whether each named task is up to date (Test-Task). Never updates the stored state.
    hidden static [object] Status([hashtable] $ctx, [hashtable] $request) {
        $ctx.Options.Dry = $true
        $result = [List[object]]::new()
        foreach ($call in [TaskEngine]::NewCalls($ctx, $request.Names)) {
            $task = [TaskCompiler]::Compile($ctx, [TaskExecutor]::FindTask($ctx, $call), $call, $true)
            $result.Add([TaskExecutor]::IsUpToDate($ctx, $task))
        }
        return $result
    }

    # Entry point of the engine runspace. Never throws for task failures: the outcome is
    # returned as data (Ok / Message / Code / ExitStatus) for the calling cmdlet to report.
    static [hashtable] Run([hashtable] $request) {
        $ctx = $null
        try {
            $ctx = [TaskEngine]::NewContext($request)
            $data = $null
            switch ([string]$request.Action) {
                'Run' { $data = [TaskEngine]::RunTasks($ctx, $request) }
                'List' { $data = [TaskEngine]::ListTasks($ctx, $request) }
                'Summary' { $data = [TaskEngine]::Summarize($ctx, $request) }
                'Status' { $data = [TaskEngine]::Status($ctx, $request) }
                default { throw [TaskError]::Create("task: unknown action `"$($request.Action)`"", [TaskError]::Unknown) }
            }
            return @{ Ok = $true; Data = $data }
        }
        catch {
            if ([TaskScript]::IsStop($_.Exception)) { throw }
            $exception = [TaskError]::Unwrap($_.Exception)
            return @{
                Ok         = $false
                Message    = $exception.Message
                Code       = [TaskError]::CodeOf($exception)
                ExitStatus = $exception.Data['TaskExitStatus']
                Exception  = $exception
            }
        }
        finally {
            if ($null -ne $ctx) { [TaskEngine]::Cleanup($ctx) }
        }
    }
}
