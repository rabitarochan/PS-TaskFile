using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Collections.Specialized

# Variable resolution and task compilation (templating of every field of a task for one call).
#
# Resolution order (later wins), same as go-task:
#   OS environment -> special variables -> Taskfile env -> Taskfile vars -> include vars ->
#   vars of the included Taskfile -> call vars -> task vars

[NoRunspaceAffinity()]
class TaskCompiler {
    # ---- templating with go-task's error latch ---------------------------------------------
    # After the first template error nothing else is replaced; the error is raised only when
    # dynamic variables are being evaluated (a real run), not while listing tasks.

    static [hashtable] NewCache([OrderedDictionary] $vars) { return @{ Vars = $vars; Error = $null } }

    hidden static [object] Data([hashtable] $cache, [IDictionary] $extra) {
        if ($null -eq $extra -or $extra.get_Count() -eq 0) { return $cache.Vars }
        $data = [OrderedDictionary]::new()
        foreach ($key in $cache.Vars.get_Keys()) { $data[[string]$key] = $cache.Vars[$key] }
        foreach ($key in $extra.get_Keys()) { $data[[string]$key] = $extra[$key] }
        return $data
    }

    static [string] Replace([hashtable] $cache, [string] $text, [IDictionary] $extra) {
        if ($null -ne $cache.Error -or [string]::IsNullOrEmpty($text)) { return $text }
        try { return [TplEngine]::Expand($text, [TaskCompiler]::Data($cache, $extra)) }
        catch { $cache.Error = [TaskError]::Unwrap($_.Exception); return $text }
    }

    static [object] ReplaceValue([hashtable] $cache, [object] $value, [IDictionary] $extra) {
        if ($null -ne $cache.Error -or $null -eq $value) { return $value }
        try { return [TplEngine]::ExpandValue($value, [TaskCompiler]::Data($cache, $extra)) }
        catch { $cache.Error = [TaskError]::Unwrap($_.Exception); return $value }
    }

    static [string[]] ReplaceStrings([hashtable] $cache, [string[]] $items) {
        $result = [List[string]]::new()
        foreach ($item in $items) { $result.Add([TaskCompiler]::Replace($cache, $item, $null)) }
        return $result.ToArray()
    }

    static [List[object]] ReplaceGlobs([hashtable] $cache, [object] $globs) {
        $result = [List[object]]::new()
        foreach ($glob in $globs) {
            $result.Add([pscustomobject]@{ Glob = [TaskCompiler]::Replace($cache, $glob.Glob, $null); Negate = $glob.Negate })
        }
        return $result
    }

    static [object] ResolveRef([hashtable] $cache, [string] $ref, [IDictionary] $extra) {
        if ($null -ne $cache.Error) { return $null }
        try { return [TplEngine]::Resolve($ref, [TaskCompiler]::Data($cache, $extra)) }
        catch { $cache.Error = [TaskError]::Unwrap($_.Exception); return $null }
    }

    # Templated copy of a set of variables (refs become static values, sh stays dynamic).
    static [OrderedDictionary] ReplaceVars([hashtable] $cache, [OrderedDictionary] $vars, [IDictionary] $extra) {
        $result = [OrderedDictionary]::new()
        if ($null -eq $vars) { return $result }
        foreach ($key in $vars.get_Keys()) {
            $var = $vars[$key]
            $new = $null
            if ($var.Kind -eq 'ref') { $new = [TaskfileReader]::NewVar('static', [TaskCompiler]::ResolveRef($cache, $var.Ref, $extra)) }
            elseif ($var.Kind -eq 'sh') { $new = [TaskfileReader]::NewVar('sh', [TaskCompiler]::Replace($cache, $var.Sh, $extra)) }
            else { $new = [TaskfileReader]::NewVar('static', [TaskCompiler]::ReplaceValue($cache, $var.Value, $extra)) }
            $new.Dir = $var.Dir
            $result[[string]$key] = $new
        }
        return $result
    }

    hidden static [void] ThrowIfError([hashtable] $cache) {
        if ($null -ne $cache.Error) { throw [TaskError]::Create($cache.Error.Message, [TaskError]::Unknown, $cache.Error) }
    }

    # ---- variables -------------------------------------------------------------------------

    hidden static [OrderedDictionary] SpecialVars([hashtable] $ctx, [object] $task, [object] $call, [string] $taskDir) {
        $vars = [OrderedDictionary]::new()
        $vars['TASK_EXE'] = 'Invoke-Task'
        $vars['ROOT_TASKFILE'] = $ctx.Entrypoint
        $vars['ROOT_DIR'] = $ctx.Dir
        $vars['USER_WORKING_DIR'] = $ctx.UserWorkingDir
        $vars['TASK_VERSION'] = $ctx.Version
        if ($null -ne $task) {
            $vars['TASK'] = $task.Task
            $vars['TASK_DIR'] = $taskDir
            $vars['TASKFILE'] = $task.Location.Taskfile
            $vars['TASKFILE_DIR'] = [System.IO.Path]::GetDirectoryName($task.Location.Taskfile)
        }
        else {
            $vars['TASK'] = ''
            $vars['TASK_DIR'] = ''
            $vars['TASKFILE'] = ''
            $vars['TASKFILE_DIR'] = ''
        }
        $vars['ALIAS'] = if ($null -ne $call) { $call.Task } else { '' }
        return $vars
    }

    hidden static [bool] IsScalar([object] $value) {
        return $value -is [string] -or $value -is [bool] -or [TplFn]::IsNumber($value)
    }

    # Environment overrides for a set of name/value pairs. By default a variable that is
    # already set in the OS environment wins (go-task v3). TASK_X_ENV_PRECEDENCE=1 flips that.
    static [OrderedDictionary] EnvOverrides([hashtable] $ctx, [IDictionary] $values) {
        $overrides = [OrderedDictionary]::new()
        if ($null -eq $values) { return $overrides }
        foreach ($key in $values.get_Keys()) {
            $name = [string]$key
            $value = $values[$key]
            if ($name.Length -eq 0 -or $name.Contains('=') -or -not [TaskCompiler]::IsScalar($value)) { continue }
            if (-not $ctx.EnvPrecedence -and $ctx.BaseEnv.ContainsKey($name)) { continue }
            $overrides[$name] = [TplFn]::Format($value, $false)
        }
        return $overrides
    }

    # Runs a dynamic variable (`sh:`) as PowerShell and returns its output as a string.
    static [string] HandleDynamicVar([hashtable] $ctx, [string] $text, [string] $directory, [IDictionary] $vars) {
        $key = $directory + [char]0 + $text
        $cached = $null
        if ($ctx.DynamicCache.TryGetValue($key, [ref] $cached)) { return [string]$cached }
        $result = $null
        [TaskEnv]::Enter($ctx.EnvGate, [TaskCompiler]::EnvOverrides($ctx, $vars), $ctx.Cancel.Token)
        try { $result = [TaskScript]::Invoke($text, [TaskScript]::NewScope(), $directory, 'capture', $null) }
        finally { [TaskEnv]::Leave($ctx.EnvGate) }
        if ($result.ExitCode -ne 0) {
            throw [TaskError]::Create("task: Command `"$text`" failed: $($result.Message)", [TaskError]::Unknown)
        }
        $value = [TaskScript]::OutputToString($result.Output)
        $ctx.DynamicCache[$key] = $value
        [TaskLog]::Verbose($ctx, "task: dynamic variable: `"$text`" result: `"$value`"")
        return $value
    }

    hidden static [void] Range([hashtable] $ctx, [OrderedDictionary] $result, [OrderedDictionary] $vars, [string] $directory, [bool] $evaluateSh) {
        if ($null -eq $vars) { return }
        foreach ($key in @($vars.get_Keys())) {
            $name = [string]$key
            $var = $vars[$key]
            $cache = [TaskCompiler]::NewCache($result)
            $value = $null
            $sh = ''
            if ($var.Kind -eq 'ref') { $value = [TaskCompiler]::ResolveRef($cache, $var.Ref, $null) }
            elseif ($var.Kind -eq 'sh') { $sh = [TaskCompiler]::Replace($cache, $var.Sh, $null) }
            else { $value = [TaskCompiler]::ReplaceValue($cache, $var.Value, $null) }

            if (-not $evaluateSh) {
                if ($null -eq $value) { $result[$name] = '' } else { $result[$name] = $value }
                continue
            }
            [TaskCompiler]::ThrowIfError($cache)
            if ($var.Kind -ne 'sh') { $result[$name] = $value; continue }
            $varDirectory = if ([string]::IsNullOrEmpty($var.Dir)) { $directory } else { $var.Dir }
            $result[$name] = [TaskCompiler]::HandleDynamicVar($ctx, $sh, $varDirectory, $result)
        }
    }

    # All variables visible to $task for $call ($task and $call may be $null for global scope).
    static [OrderedDictionary] GetVariables([hashtable] $ctx, [object] $task, [object] $call, [bool] $evaluateSh) {
        $result = [OrderedDictionary]::new()
        $environment = [Environment]::GetEnvironmentVariables()
        foreach ($key in $environment.get_Keys()) { $result[[string]$key] = [string]$environment[$key] }

        $rootDir = [string]$ctx.Dir
        $taskDir = $rootDir
        $special = [TaskCompiler]::SpecialVars($ctx, $task, $call, '')
        foreach ($key in $special.get_Keys()) { $result[[string]$key] = $special[$key] }
        if ($null -ne $task) {
            $cache = [TaskCompiler]::NewCache($result)
            $dir = [TaskCompiler]::Replace($cache, $task.Dir, $null)
            if ($evaluateSh) { [TaskCompiler]::ThrowIfError($cache) }
            $taskDir = [TaskPath]::SmartJoin($rootDir, [TaskPath]::ExpandHome($dir))
            $result['TASK_DIR'] = $taskDir
        }

        [TaskCompiler]::Range($ctx, $result, $ctx.Taskfile.Env, $rootDir, $evaluateSh)
        [TaskCompiler]::Range($ctx, $result, $ctx.Taskfile.Vars, $rootDir, $evaluateSh)
        if ($null -ne $task) {
            [TaskCompiler]::Range($ctx, $result, $task.IncludeVars, $rootDir, $evaluateSh)
            [TaskCompiler]::Range($ctx, $result, $task.IncludedTaskfileVars, $taskDir, $evaluateSh)
        }
        if ($null -eq $task -or $null -eq $call) { return $result }
        [TaskCompiler]::Range($ctx, $result, $call.Vars, $rootDir, $evaluateSh)
        [TaskCompiler]::Range($ctx, $result, $task.Vars, $taskDir, $evaluateSh)
        return $result
    }

    # ---- for loops -----------------------------------------------------------------------

    hidden static [List[object]] MatrixProduct([OrderedDictionary] $rows) {
        $result = [List[object]]::new()
        $result.Add([OrderedDictionary]::new())
        foreach ($key in $rows.get_Keys()) {
            $next = [List[object]]::new()
            foreach ($partial in $result) {
                foreach ($value in $rows[$key]) {
                    $item = [OrderedDictionary]::new()
                    foreach ($existing in $partial.get_Keys()) { $item[[string]$existing] = $partial[$existing] }
                    $item[[string]$key] = $value
                    $next.Add($item)
                }
            }
            $result = $next
        }
        return $result
    }

    # Returns @{ Values = <List>; Keys = <List or $null> } for a `for:` definition.
    hidden static [hashtable] ForItems([object] $for, [object] $task, [hashtable] $cache) {
        $values = [List[object]]::new()
        $keys = $null
        if ($null -ne $for.Matrix) {
            $rows = [OrderedDictionary]::new()
            foreach ($key in $for.Matrix.get_Keys()) {
                $row = $for.Matrix[$key]
                if (-not [string]::IsNullOrEmpty($row.Ref)) {
                    $resolved = [TaskCompiler]::ResolveRef($cache, $row.Ref, $null)
                    if (-not [TplFn]::IsList($resolved)) {
                        throw [TaskError]::Create("task: matrix reference ($($row.Ref)) must resolve to a list", [TaskError]::TaskfileInvalid)
                    }
                    $rows[[string]$key] = [TplFn]::ToList($resolved)
                }
                else { $rows[[string]$key] = [TplFn]::ToList([TaskCompiler]::ReplaceValue($cache, $row.Value, $null)) }
            }
            return @{ Values = [TaskCompiler]::MatrixProduct($rows); Keys = $null }
        }
        if ($null -ne $for.List) {
            foreach ($item in $for.List) { $values.Add([TaskCompiler]::ReplaceValue($cache, $item, $null)) }
            return @{ Values = $values; Keys = $null }
        }
        if ($for.From -eq 'sources' -or $for.From -eq 'generates') {
            $globs = $task.Generates
            if ($for.From -eq 'sources') { $globs = $task.Sources }
            foreach ($file in [TaskGlob]::Expand($task.Dir, $globs)) { $values.Add([System.IO.Path]::GetRelativePath($task.Dir, $file)) }
            return @{ Values = $values; Keys = $null }
        }
        if (-not [string]::IsNullOrEmpty($for.Var) -and $cache.Vars.Contains($for.Var)) {
            $value = [TplFn]::Unwrap($cache.Vars[$for.Var])
            if ($value -is [string]) {
                $parts = if ([string]::IsNullOrEmpty($for.Split)) { $value.Split([char[]]$null, [StringSplitOptions]::RemoveEmptyEntries) }
                else { $value.Split([string[]]@($for.Split), [StringSplitOptions]::None) }
                foreach ($part in $parts) { $values.Add($part) }
            }
            elseif ($value -is [IDictionary]) {
                $keys = [List[object]]::new()
                foreach ($key in $value.get_Keys()) { $keys.Add([string]$key); $values.Add($value[$key]) }
            }
            elseif ([TplFn]::IsList($value)) { foreach ($item in $value) { $values.Add($item) } }
            elseif ($null -ne $value) {
                throw [TaskError]::Create('task: loop var must be a delimiter-separated string, list or a map', [TaskError]::TaskfileInvalid)
            }
        }
        return @{ Values = $values; Keys = $keys }
    }

    hidden static [object] CopyCmd([object] $cmd) {
        return [pscustomobject]@{
            Cmd = $cmd.Cmd; Task = $cmd.Task; Vars = $cmd.Vars; Silent = $cmd.Silent; IgnoreError = $cmd.IgnoreError; Defer = $cmd.Defer
            Platforms = $cmd.Platforms; Set = $cmd.Set; Shopt = $cmd.Shopt; For = $null; If = $cmd.If
        }
    }

    # Templates one command. $extra carries loop variables (ITEM, KEY) or EXIT_CODE.
    static [object] ReplaceCmd([hashtable] $cache, [object] $cmd, [IDictionary] $extra) {
        $new = [TaskCompiler]::CopyCmd($cmd)
        $new.Cmd = [TaskCompiler]::Replace($cache, $cmd.Cmd, $extra)
        $new.Task = [TaskCompiler]::Replace($cache, $cmd.Task, $extra)
        $new.If = [TaskCompiler]::Replace($cache, $cmd.If, $extra)
        $new.Vars = [TaskCompiler]::ReplaceVars($cache, $cmd.Vars, $extra)
        return $new
    }

    hidden static [List[object]] LoopExtras([object] $for, [object] $task, [hashtable] $cache) {
        $items = [TaskCompiler]::ForItems($for, $task, $cache)
        $name = if ([string]::IsNullOrEmpty($for.As)) { 'ITEM' } else { $for.As }
        $extras = [List[object]]::new()
        for ($i = 0; $i -lt $items.Values.Count; $i++) {
            $extra = [OrderedDictionary]::new()
            $extra[$name] = $items.Values[$i]
            if ($null -ne $items.Keys) { $extra['KEY'] = $items.Keys[$i] }
            $extras.Add($extra)
        }
        return $extras
    }

    # ---- task compilation ------------------------------------------------------------------

    # Returns a copy of $task with every field templated for $call. With $evaluateSh = $false
    # dynamic variables are not executed (used for listing and for the pre-run checks).
    static [object] Compile([hashtable] $ctx, [object] $task, [object] $call, [bool] $evaluateSh) {
        $vars = [TaskCompiler]::GetVariables($ctx, $task, $call, $evaluateSh)
        $cache = [TaskCompiler]::NewCache($vars)
        $dir = [TaskPath]::SmartJoin([string]$ctx.Dir, [TaskPath]::ExpandHome([TaskCompiler]::Replace($cache, $task.Dir, $null)))
        $prefix = [TaskCompiler]::Replace($cache, $task.Prefix, $null)
        if ([string]::IsNullOrEmpty($prefix)) { $prefix = $task.Task }

        $new = [pscustomobject]@{
            Task          = $task.Task
            Label         = [TaskCompiler]::Replace($cache, $task.Label, $null)
            Desc          = [TaskCompiler]::Replace($cache, $task.Desc, $null)
            Prompt        = [TaskCompiler]::ReplaceStrings($cache, $task.Prompt)
            Summary       = [TaskCompiler]::Replace($cache, $task.Summary, $null)
            Aliases       = $task.Aliases
            Sources       = [TaskCompiler]::ReplaceGlobs($cache, $task.Sources)
            Generates     = [TaskCompiler]::ReplaceGlobs($cache, $task.Generates)
            Dir           = $dir
            Set           = $task.Set
            Shopt         = $task.Shopt
            Vars          = $vars
            Env           = [OrderedDictionary]::new()
            Dotenv        = [TaskCompiler]::ReplaceStrings($cache, $task.Dotenv)
            Silent        = $task.Silent
            Interactive   = $task.Interactive
            Internal      = $task.Internal
            Method        = [TaskCompiler]::Replace($cache, $task.Method, $null)
            Prefix        = $prefix
            IgnoreError   = $task.IgnoreError
            Run           = [TaskCompiler]::Replace($cache, $task.Run, $null)
            Platforms     = $task.Platforms
            If            = [TaskCompiler]::Replace($cache, $task.If, $null)
            Watch         = $task.Watch
            Failfast      = $task.Failfast
            Namespace     = $task.Namespace
            Requires      = $task.Requires
            Location      = $task.Location
            Cmds          = [List[object]]::new()
            Deps          = [List[object]]::new()
            Preconditions = [List[object]]::new()
            Status        = [string[]]@()
        }

        # Environment: Taskfile env, then dotenv files of the task, then task env.
        $envVars = [OrderedDictionary]::new()
        $taskfileEnv = [TaskCompiler]::ReplaceVars($cache, $ctx.Taskfile.Env, $null)
        foreach ($key in $taskfileEnv.get_Keys()) { $envVars[[string]$key] = $taskfileEnv[$key] }
        $dotenv = [OrderedDictionary]::new()
        foreach ($path in $new.Dotenv) {
            $file = [TaskPath]::SmartJoin($dir, $path)
            if (-not [System.IO.File]::Exists($file)) { continue }
            $values = [TaskDotenv]::Read($file)
            foreach ($key in $values.get_Keys()) { if (-not $dotenv.Contains($key)) { $dotenv[[string]$key] = $values[$key] } }
        }
        foreach ($key in $dotenv.get_Keys()) {
            $envVars[[string]$key] = [TaskfileReader]::NewVar('static', [TaskCompiler]::Replace($cache, [string]$dotenv[$key], $null))
        }
        $taskEnv = [TaskCompiler]::ReplaceVars($cache, $task.Env, $null)
        foreach ($key in $taskEnv.get_Keys()) { $envVars[[string]$key] = $taskEnv[$key] }
        foreach ($key in $envVars.get_Keys()) {
            $var = $envVars[$key]
            if ($var.Kind -eq 'sh') {
                if ($evaluateSh) {
                    [TaskCompiler]::ThrowIfError($cache)
                    $varDirectory = if ([string]::IsNullOrEmpty($var.Dir)) { $dir } else { $var.Dir }
                    $new.Env[[string]$key] = [TaskCompiler]::HandleDynamicVar($ctx, $var.Sh, $varDirectory, $new.Env)
                }
                else { $new.Env[[string]$key] = '' }
            }
            elseif ([TaskCompiler]::IsScalar($var.Value)) { $new.Env[[string]$key] = [TplFn]::Format($var.Value, $false) }
        }

        foreach ($cmd in $task.Cmds) {
            if ($null -ne $cmd.For) {
                foreach ($extra in [TaskCompiler]::LoopExtras($cmd.For, $new, $cache)) { $new.Cmds.Add([TaskCompiler]::ReplaceCmd($cache, $cmd, $extra)) }
                continue
            }
            # Deferred commands are templated when they run: EXIT_CODE is only known then.
            if ($cmd.Defer) { $new.Cmds.Add([TaskCompiler]::CopyCmd($cmd)); continue }
            $new.Cmds.Add([TaskCompiler]::ReplaceCmd($cache, $cmd, $null))
        }

        foreach ($dep in $task.Deps) {
            $extras = [List[object]]::new()
            if ($null -ne $dep.For) { $extras = [TaskCompiler]::LoopExtras($dep.For, $new, $cache) } else { $extras.Add($null) }
            foreach ($extra in $extras) {
                $new.Deps.Add([pscustomobject]@{
                        Task   = [TaskCompiler]::Replace($cache, $dep.Task, $extra)
                        Vars   = [TaskCompiler]::ReplaceVars($cache, $dep.Vars, $extra)
                        Silent = $dep.Silent
                        For    = $null
                    })
            }
        }

        foreach ($precondition in $task.Preconditions) {
            $new.Preconditions.Add([pscustomobject]@{
                    Sh  = [TaskCompiler]::Replace($cache, $precondition.Sh, $null)
                    Msg = [TaskCompiler]::Replace($cache, $precondition.Msg, $null)
                })
        }

        if ($task.Status.Count -gt 0) {
            # CHECKSUM and TIMESTAMP are available to status commands.
            if ($new.Sources.Count -gt 0) {
                try {
                    $vars['CHECKSUM'] = [TaskFingerprint]::Checksum($new)
                    $vars['TIMESTAMP'] = [TaskFingerprint]::Timestamp($new)
                }
                catch { $vars['CHECKSUM'] = '' }
            }
            $new.Status = [TaskCompiler]::ReplaceStrings($cache, $task.Status)
        }

        if ($evaluateSh) { [TaskCompiler]::ThrowIfError($cache) }
        return $new
    }
}
