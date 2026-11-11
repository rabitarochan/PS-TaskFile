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
        $entry = 'param($ctx, $call) & (Get-Module PSTaskFile) { param($c, $k) [TaskExecutor]::RunBranch($c, $k) } $ctx $call'
        [void]$shell.AddScript($entry).AddArgument($ctx).AddArgument($call)
        return @{ Shell = $shell; Runspace = $runspace; Handle = $shell.BeginInvoke(); Done = $false }
    }

    # Runs the calls concurrently, each in its own branch. Throws the first failure.
    static [void] RunParallel([hashtable] $ctx, [List[object]] $calls, [bool] $failfast) {
        if ($calls.Count -eq 0) { return }
        if ($calls.Count -eq 1) { [TaskExecutor]::RunTask($ctx, $calls[0]); return }

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

    # Runs a condition script (status / precondition / if) with the environment of the task.
    hidden static [bool] Condition([hashtable] $ctx, [object] $task, [string] $text) {
        [TaskEnv]::Enter($ctx.EnvGate, [TaskCompiler]::EnvOverrides($ctx, $task.Env), $ctx.Cancel.Token)
        try { return [TaskScript]::Test($text, $task.Dir) }
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
                [TaskExecutor]::RunTask($ctx, [TaskExecutor]::NewCall($cmd.Task, $cmd.Vars, $cmd.Silent, $true, $call.Depth + 1))
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
        if (-not [string]::IsNullOrEmpty($cmd.If) -and -not $ctx.Options.Dry -and -not [TaskExecutor]::Condition($ctx, $task, $cmd.If)) {
            [TaskLog]::Verbose($ctx, "task: [$name] if condition not met - skipped: $($cmd.Cmd)")
            return
        }
        if ($ctx.Options.Verbose -or -not [TaskExecutor]::IsSilent($ctx, $task, $call, $cmd.Silent)) {
            [TaskLog]::Info($ctx, "task: [$name] $($cmd.Cmd)", 'Green')
        }
        if ($ctx.Options.Dry) { return }

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
            [TaskExecutor]::CheckAllowedValues($task)
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

        $scope = [TaskScript]::NewScope()
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

    hidden static [object] RunTasks([hashtable] $ctx, [hashtable] $request) {
        $calls = [TaskEngine]::NewCalls($ctx, $request.Names)
        if ($ctx.Options.Parallel) { [TaskExecutor]::RunParallel($ctx, $calls, [bool]$ctx.Options.Failfast) }
        else { foreach ($call in $calls) { [TaskExecutor]::RunTask($ctx, $call) } }
        return $null
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
