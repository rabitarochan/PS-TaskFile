using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Collections.Specialized
using namespace System.Globalization

# Errors, path helpers and the Taskfile reader (YAML -> model, includes merged).
#
# The model is made of plain PSCustomObjects / dictionaries / lists on purpose: it is shared
# between the runspaces of parallel tasks, so it must not contain script blocks or class
# instances that are bound to a runspace.
#
# NOTE: a [string] typed value can never be $null in PowerShell (it becomes ''), so "not
# found" is always tested with [string]::IsNullOrEmpty().

[NoRunspaceAffinity()]
class TaskError {
    # Exit codes follow go-task (https://taskfile.dev/docs/reference/cli#exit-codes).
    static [int] $Unknown = 1
    static [int] $TaskfileNotFound = 100
    static [int] $TaskfileAlreadyExists = 101
    static [int] $TaskfileDecode = 102
    static [int] $TaskfileVersionCheck = 107
    static [int] $TaskfileInvalid = 109
    static [int] $TaskfileCycle = 110
    static [int] $TaskNotFound = 200
    static [int] $TaskRun = 201
    static [int] $TaskInternal = 202
    static [int] $TaskNameConflict = 203
    static [int] $TaskCalledTooManyTimes = 204
    static [int] $TaskCancelled = 205
    static [int] $TaskMissingRequiredVars = 206
    static [int] $TaskNotAllowedVars = 207

    static [Exception] Create([string] $message, [int] $code) {
        $exception = [System.InvalidOperationException]::new($message)
        $exception.Data['TaskCode'] = $code
        return $exception
    }

    static [Exception] Create([string] $message, [int] $code, [Exception] $inner) {
        $exception = [System.InvalidOperationException]::new($message, $inner)
        $exception.Data['TaskCode'] = $code
        return $exception
    }

    # Finds the exception created by Create() inside wrappers added by the PowerShell engine.
    static [Exception] Find([Exception] $exception) {
        $current = $exception
        while ($null -ne $current) {
            if ($current.Data.Contains('TaskCode')) { return $current }
            $current = $current.InnerException
        }
        return $null
    }

    static [int] CodeOf([Exception] $exception) {
        $found = [TaskError]::Find($exception)
        if ($null -ne $found) { return [int]$found.Data['TaskCode'] }
        return [TaskError]::Unknown
    }

    # The innermost meaningful exception (strips method-invocation wrappers).
    static [Exception] Unwrap([Exception] $exception) {
        $found = [TaskError]::Find($exception)
        if ($null -ne $found) { return $found }
        $current = $exception
        while ($null -ne $current.InnerException -and
            ($current -is [System.Management.Automation.MethodInvocationException] -or
            $current -is [System.Management.Automation.ActionPreferenceStopException] -or
            $current -is [System.Reflection.TargetInvocationException])) {
            $current = $current.InnerException
        }
        return $current
    }
}

[NoRunspaceAffinity()]
class TaskPath {
    hidden static [string[]] $KnownAbsoluteVars = @('.ROOT_DIR', '.TASKFILE_DIR', '.USER_WORKING_DIR')

    # The home directory, taken from the environment like Go's os.UserHomeDir().
    static [string] Home() {
        $variable = if ($global:IsWindows) { 'USERPROFILE' } else { 'HOME' }
        $value = [Environment]::GetEnvironmentVariable($variable)
        if ([string]::IsNullOrEmpty($value)) { return [Environment]::GetFolderPath('UserProfile') }
        return $value
    }

    static [string] ExpandHome([string] $path) {
        if ($path -eq '~') { return [TaskPath]::Home() }
        if ($path.StartsWith('~/') -or $path.StartsWith('~\')) {
            return [System.IO.Path]::Combine([TaskPath]::Home(), $path.Substring(2))
        }
        return $path
    }

    # Remote Taskfiles (an experiment of go-task) are not implemented.
    static [void] AssertLocal([string] $path) {
        if ($path -match '^(https?|git|ssh)://' -or $path -match '^git@') {
            throw [TaskError]::Create("task: Remote Taskfiles are not supported by PS-TaskFile: $path", [TaskError]::TaskfileInvalid)
        }
    }

    # True for absolute paths and for templates that will expand to an absolute path.
    static [bool] IsAbsolute([string] $path) {
        foreach ($name in [TaskPath]::KnownAbsoluteVars) { if ($path.Contains($name)) { return $true } }
        return [System.IO.Path]::IsPathFullyQualified($path)
    }

    # Joins $path onto $base unless $path is already absolute.
    static [string] SmartJoin([string] $base, [string] $path) {
        if ([string]::IsNullOrEmpty($path)) { return $base }
        if ([TaskPath]::IsAbsolute($path)) { return $path }
        if ([string]::IsNullOrEmpty($base)) { return $path }
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $path))
    }

    static [string] Full([string] $base, [string] $path) {
        $expanded = [TaskPath]::ExpandHome($path)
        if ([System.IO.Path]::IsPathFullyQualified($expanded)) { return [System.IO.Path]::GetFullPath($expanded) }
        return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($base, $expanded))
    }
}

[NoRunspaceAffinity()]
class TaskfileReader {
    static [string[]] $DefaultNames = @(
        'Taskfile.yml', 'taskfile.yml', 'Taskfile.yaml', 'taskfile.yaml',
        'Taskfile.dist.yml', 'taskfile.dist.yml', 'Taskfile.dist.yaml', 'taskfile.dist.yaml'
    )

    hidden static [string[]] $KnownOS = @('aix', 'android', 'darwin', 'dragonfly', 'freebsd', 'illumos', 'ios', 'js', 'linux',
        'netbsd', 'openbsd', 'plan9', 'solaris', 'wasip1', 'windows')

    hidden static [string[]] $KnownArch = @('386', 'amd64', 'arm', 'arm64', 'loong64', 'mips', 'mips64', 'mips64le', 'mipsle',
        'ppc64', 'ppc64le', 'riscv64', 's390x', 'wasm')

    # ---- locating the Taskfile --------------------------------------------------------------

    # Returns the path of the Taskfile inside $directory, or '' when there is none.
    static [string] FindInDirectory([string] $directory) {
        foreach ($name in [TaskfileReader]::DefaultNames) {
            $candidate = [System.IO.Path]::Combine($directory, $name)
            if ([System.IO.File]::Exists($candidate)) {
                # Report the name as it is stored on disk (case-insensitive file systems).
                $actual = [System.IO.Directory]::GetFiles($directory, $name)
                if ($actual.Length -gt 0) { return $actual[0] }
                return $candidate
            }
        }
        return ''
    }

    hidden static [Exception] NotFound([string] $path, [bool] $walk) {
        $suffix = if ($walk) { ' (or any of the parent directories).' } else { '' }
        $message = "task: No Taskfile found at `"$path`"$suffix Run ``New-Taskfile`` to create a new Taskfile."
        return [TaskError]::Create($message, [TaskError]::TaskfileNotFound)
    }

    # Resolves the entrypoint and the execution directory like `task --taskfile/--dir/--global`.
    static [object] Find([string] $taskfile, [string] $directory, [bool] $global, [string] $workingDirectory) {
        $cwd = if ([string]::IsNullOrEmpty($workingDirectory)) { [Environment]::CurrentDirectory } else { $workingDirectory }
        if ($global) {
            $userHome = [TaskPath]::Home()
            $entry = [TaskfileReader]::FindInDirectory($userHome)
            if ([string]::IsNullOrEmpty($entry)) { throw [TaskfileReader]::NotFound($userHome, $false) }
            return [pscustomobject]@{ Entrypoint = $entry; Dir = $userHome }
        }
        if (-not [string]::IsNullOrEmpty($taskfile)) {
            [TaskPath]::AssertLocal($taskfile)
            $path = [TaskPath]::Full($cwd, $taskfile)
            $entry = ''
            if ([System.IO.Directory]::Exists($path)) { $entry = [TaskfileReader]::FindInDirectory($path) }
            elseif ([System.IO.File]::Exists($path)) { $entry = $path }
            if ([string]::IsNullOrEmpty($entry)) { throw [TaskfileReader]::NotFound($taskfile, $false) }
            $dir = if ([string]::IsNullOrEmpty($directory)) { [System.IO.Path]::GetDirectoryName($entry) } else { [TaskPath]::Full($cwd, $directory) }
            return [pscustomobject]@{ Entrypoint = $entry; Dir = $dir }
        }
        $start = if ([string]::IsNullOrEmpty($directory)) { $cwd } else { [TaskPath]::Full($cwd, $directory) }
        $current = $start
        while (-not [string]::IsNullOrEmpty($current)) {
            if ([System.IO.Directory]::Exists($current)) {
                $entry = [TaskfileReader]::FindInDirectory($current)
                if (-not [string]::IsNullOrEmpty($entry)) { return [pscustomobject]@{ Entrypoint = $entry; Dir = $current } }
            }
            $current = [System.IO.Path]::GetDirectoryName($current)
        }
        throw [TaskfileReader]::NotFound($start, $true)
    }

    # ---- model helpers ----------------------------------------------------------------------

    hidden static [Exception] Invalid([string] $path, [object] $node, [string] $message) {
        $detail = if ($null -ne $node) { "line $([TaskYaml]::Line($node)): $message" } else { $message }
        return [TaskError]::Create("task: Failed to parse ${path}:`n$detail", [TaskError]::TaskfileDecode)
    }

    # Child node of a mapping ($null when missing). $map comes from [TaskYaml]::Map().
    hidden static [object] Get([OrderedDictionary] $map, [string] $key) {
        if ($map.Contains($key)) { return $map[$key] }
        return $null
    }

    static [OrderedDictionary] NewMap() { return [OrderedDictionary]::new() }

    # NOTE: never assign a value that may be a collection through an `if` expression
    # (`$x = if (...) { $list }`): PowerShell enumerates the result, so a one-element list
    # silently becomes its element and an empty list becomes $null.
    static [object] NewVar([string] $kind, [object] $value) {
        $var = [pscustomobject]@{ Kind = $kind; Value = $null; Sh = $null; Ref = $null; Dir = '' }
        if ($kind -eq 'sh') { $var.Sh = [string]$value }
        elseif ($kind -eq 'ref') { $var.Ref = [string]$value }
        else { $var.Value = $value }
        return $var
    }

    static [object] CopyVar([object] $var, [string] $dir) {
        return [pscustomobject]@{ Kind = $var.Kind; Value = $var.Value; Sh = $var.Sh; Ref = $var.Ref; Dir = $dir }
    }

    # ---- parsing (everything below works on YAML nodes) ----------------------------------------

    hidden static [object] ParseVar([object] $node, [string] $path) {
        if ([TaskYaml]::IsMap($node)) {
            $map = [TaskYaml]::Map($node)
            if ($map.Contains('sh')) { return [TaskfileReader]::NewVar('sh', [TaskYaml]::Str($map['sh'])) }
            if ($map.Contains('ref')) { return [TaskfileReader]::NewVar('ref', [TaskYaml]::Str($map['ref'])) }
            if ($map.Contains('map')) { return [TaskfileReader]::NewVar('static', [TaskYaml]::Value($map['map'])) }
            $first = '<none>'
            foreach ($key in $map.get_Keys()) { $first = [string]$key; break }
            throw [TaskfileReader]::Invalid($path, $node, "`"$first`" is not a valid variable type. Try `"sh`", `"ref`", `"map`" or using a scalar value")
        }
        return [TaskfileReader]::NewVar('static', [TaskYaml]::Value($node))
    }

    hidden static [OrderedDictionary] ParseVars([object] $node, [string] $path) {
        $vars = [TaskfileReader]::NewMap()
        $kind = [TaskYaml]::Kind($node)
        if ($kind -eq 'null') { return $vars }
        if ($kind -ne 'map') { throw [TaskfileReader]::Invalid($path, $node, 'vars and env must be maps') }
        $map = [TaskYaml]::Map($node)
        foreach ($key in $map.get_Keys()) { $vars[[string]$key] = [TaskfileReader]::ParseVar($map[$key], $path) }
        return $vars
    }

    hidden static [List[object]] ParsePlatforms([object] $node, [string] $path) {
        $result = [List[object]]::new()
        foreach ($item in [TaskYaml]::StrList($node)) {
            $parts = $item.Split('/')
            $os = ''
            $arch = ''
            if ($parts.Count -eq 1) {
                if ([TaskfileReader]::KnownOS -ccontains $parts[0]) { $os = $parts[0] }
                elseif ([TaskfileReader]::KnownArch -ccontains $parts[0]) { $arch = $parts[0] }
                else { throw [TaskfileReader]::Invalid($path, $node, "invalid platform `"$item`"") }
            }
            elseif ($parts.Count -eq 2 -and [TaskfileReader]::KnownOS -ccontains $parts[0] -and [TaskfileReader]::KnownArch -ccontains $parts[1]) {
                $os = $parts[0]
                $arch = $parts[1]
            }
            else { throw [TaskfileReader]::Invalid($path, $node, "invalid platform `"$item`"") }
            $result.Add([pscustomobject]@{ OS = $os; Arch = $arch })
        }
        return $result
    }

    hidden static [List[object]] ParseGlobs([object] $node) {
        $result = [List[object]]::new()
        foreach ($item in [TaskYaml]::Seq($node)) {
            if ([TaskYaml]::IsMap($item)) {
                $map = [TaskYaml]::Map($item)
                if ($map.Contains('exclude')) { $result.Add([pscustomobject]@{ Glob = [TaskYaml]::Str($map['exclude']); Negate = $true }) }
                continue
            }
            $result.Add([pscustomobject]@{ Glob = [TaskYaml]::Str($item); Negate = $false })
        }
        return $result
    }

    hidden static [object] ParseFor([object] $node, [string] $path) {
        $for = [pscustomobject]@{ List = $null; Matrix = $null; From = ''; Var = ''; Split = ''; As = '' }
        $kind = [TaskYaml]::Kind($node)
        if ($kind -eq 'map') {
            $map = [TaskYaml]::Map($node)
            $for.Var = [TaskYaml]::Str([TaskfileReader]::Get($map, 'var'))
            $for.Split = [TaskYaml]::Str([TaskfileReader]::Get($map, 'split'))
            $for.As = [TaskYaml]::Str([TaskfileReader]::Get($map, 'as'))
            $matrix = [TaskYaml]::Map([TaskfileReader]::Get($map, 'matrix'))
            if ($matrix.get_Count() -gt 0) {
                if ($for.Var.Length -gt 0) { throw [TaskfileReader]::Invalid($path, $node, 'cannot use both var and matrix in for') }
                $rows = [TaskfileReader]::NewMap()
                foreach ($key in $matrix.get_Keys()) {
                    $row = $matrix[$key]
                    if ([TaskYaml]::IsMap($row)) {
                        $rowMap = [TaskYaml]::Map($row)
                        if (-not $rowMap.Contains('ref')) { throw [TaskfileReader]::Invalid($path, $row, 'matrix values must be a list or a ref') }
                        $rows[[string]$key] = [pscustomobject]@{ Value = $null; Ref = [TaskYaml]::Str($rowMap['ref']) }
                    }
                    else {
                        $values = [List[object]]::new()
                        foreach ($item in [TaskYaml]::Seq($row)) { $values.Add([TaskYaml]::Value($item)) }
                        $rows[[string]$key] = [pscustomobject]@{ Value = $values; Ref = '' }
                    }
                }
                $for.Matrix = $rows
            }
            elseif ($for.Var.Length -eq 0) { throw [TaskfileReader]::Invalid($path, $node, 'invalid keys in for') }
            return $for
        }
        if ($kind -eq 'scalar') {
            $from = [TaskYaml]::Str($node)
            if ($from -cne 'sources' -and $from -cne 'generates') { throw [TaskfileReader]::Invalid($path, $node, "invalid for value `"$from`"") }
            $for.From = $from
            return $for
        }
        $list = [List[object]]::new()
        foreach ($item in [TaskYaml]::Seq($node)) { $list.Add([TaskYaml]::Value($item)) }
        $for.List = $list
        return $for
    }

    hidden static [object] NewCmd() {
        return [pscustomobject]@{
            Cmd = ''; Task = ''; Vars = $null; Silent = $false; IgnoreError = $false; Defer = $false
            Platforms = [List[object]]::new(); Set = [string[]]@(); Shopt = [string[]]@(); For = $null; If = ''
        }
    }

    hidden static [object] ParseCmd([object] $node, [string] $path) {
        $cmd = [TaskfileReader]::NewCmd()
        if (-not [TaskYaml]::IsMap($node)) {
            $cmd.Cmd = [TaskYaml]::Str($node)
            return $cmd
        }
        $map = [TaskYaml]::Map($node)
        $cmd.Silent = [TaskYaml]::Bool([TaskfileReader]::Get($map, 'silent'))
        if ($map.Contains('defer')) {
            $defer = $map['defer']
            $cmd.Defer = $true
            if ([TaskYaml]::IsMap($defer)) {
                $deferMap = [TaskYaml]::Map($defer)
                $cmd.Task = [TaskYaml]::Str([TaskfileReader]::Get($deferMap, 'task'))
                $cmd.Vars = [TaskfileReader]::ParseVars([TaskfileReader]::Get($deferMap, 'vars'), $path)
                $cmd.Silent = [TaskYaml]::Bool([TaskfileReader]::Get($deferMap, 'silent'))
                if ($cmd.Task.Length -eq 0) { throw [TaskfileReader]::Invalid($path, $defer, 'invalid keys in defer') }
            }
            else { $cmd.Cmd = [TaskYaml]::Str($defer) }
            return $cmd
        }
        if ($map.Contains('for')) { $cmd.For = [TaskfileReader]::ParseFor($map['for'], $path) }
        $cmd.IgnoreError = [TaskYaml]::Bool([TaskfileReader]::Get($map, 'ignore_error'))
        $cmd.If = [TaskYaml]::Str([TaskfileReader]::Get($map, 'if'))
        $task = [TaskYaml]::Str([TaskfileReader]::Get($map, 'task'))
        if ($task.Length -gt 0) {
            $cmd.Task = $task
            $cmd.Vars = [TaskfileReader]::ParseVars([TaskfileReader]::Get($map, 'vars'), $path)
            return $cmd
        }
        $text = [TaskYaml]::Str([TaskfileReader]::Get($map, 'cmd'))
        if ($text.Length -gt 0) {
            $cmd.Cmd = $text
            $cmd.Platforms = [TaskfileReader]::ParsePlatforms([TaskfileReader]::Get($map, 'platforms'), $path)
            $cmd.Set = [TaskYaml]::StrList([TaskfileReader]::Get($map, 'set'))
            $cmd.Shopt = [TaskYaml]::StrList([TaskfileReader]::Get($map, 'shopt'))
            return $cmd
        }
        throw [TaskfileReader]::Invalid($path, $node, 'invalid keys in command')
    }

    hidden static [object] ParseDep([object] $node, [string] $path) {
        $dep = [pscustomobject]@{ Task = ''; Vars = $null; Silent = $false; For = $null }
        if (-not [TaskYaml]::IsMap($node)) {
            $dep.Task = [TaskYaml]::Str($node)
            return $dep
        }
        $map = [TaskYaml]::Map($node)
        $dep.Task = [TaskYaml]::Str([TaskfileReader]::Get($map, 'task'))
        $dep.Vars = [TaskfileReader]::ParseVars([TaskfileReader]::Get($map, 'vars'), $path)
        $dep.Silent = [TaskYaml]::Bool([TaskfileReader]::Get($map, 'silent'))
        if ($map.Contains('for')) { $dep.For = [TaskfileReader]::ParseFor($map['for'], $path) }
        if ($dep.Task.Length -eq 0) { throw [TaskfileReader]::Invalid($path, $node, 'invalid keys in dependency') }
        return $dep
    }

    hidden static [object] NewTask([string] $name, [string] $path) {
        return [pscustomobject]@{
            Task                 = $name
            Cmds                 = [List[object]]::new()
            Deps                 = [List[object]]::new()
            Label                = ''
            Desc                 = ''
            Prompt               = [string[]]@()
            Summary              = ''
            Aliases              = [string[]]@()
            Sources              = [List[object]]::new()
            Generates            = [List[object]]::new()
            Status               = [string[]]@()
            Preconditions        = [List[object]]::new()
            Requires             = [List[object]]::new()
            Dir                  = ''
            Vars                 = [TaskfileReader]::NewMap()
            Env                  = [TaskfileReader]::NewMap()
            Dotenv               = [string[]]@()
            Silent               = $null
            Interactive          = $false
            Internal             = $false
            Method               = ''
            Prefix               = ''
            IgnoreError          = $false
            Run                  = ''
            Platforms            = [List[object]]::new()
            Set                  = [string[]]@()
            Shopt                = [string[]]@()
            Watch                = $false
            If                   = ''
            Failfast             = $false
            Namespace            = ''
            IncludeVars          = [TaskfileReader]::NewMap()
            IncludedTaskfileVars = [TaskfileReader]::NewMap()
            Location             = [pscustomobject]@{ Taskfile = $path; Line = 0; Column = 0 }
        }
    }

    hidden static [object] ParseTask([string] $name, [object] $node, [string] $path) {
        $task = [TaskfileReader]::NewTask($name, $path)
        $kind = [TaskYaml]::Kind($node)
        if ($kind -eq 'null') { return $task }
        if ($kind -ne 'map') {
            foreach ($item in [TaskYaml]::Seq($node)) { $task.Cmds.Add([TaskfileReader]::ParseCmd($item, $path)) }
            return $task
        }
        $map = [TaskYaml]::Map($node)
        if ($map.Contains('cmds')) {
            foreach ($item in [TaskYaml]::Seq($map['cmds'])) { $task.Cmds.Add([TaskfileReader]::ParseCmd($item, $path)) }
        }
        elseif ($map.Contains('cmd')) {
            $task.Cmds.Add([TaskfileReader]::ParseCmd($map['cmd'], $path))
        }
        foreach ($item in [TaskYaml]::Seq([TaskfileReader]::Get($map, 'deps'))) { $task.Deps.Add([TaskfileReader]::ParseDep($item, $path)) }
        $task.Label = [TaskYaml]::Str([TaskfileReader]::Get($map, 'label'))
        $task.Desc = [TaskYaml]::Str([TaskfileReader]::Get($map, 'desc'))
        $task.Prompt = [TaskYaml]::StrList([TaskfileReader]::Get($map, 'prompt'))
        $task.Summary = [TaskYaml]::Str([TaskfileReader]::Get($map, 'summary'))
        $task.Aliases = [TaskYaml]::StrList([TaskfileReader]::Get($map, 'aliases'))
        $task.Sources = [TaskfileReader]::ParseGlobs([TaskfileReader]::Get($map, 'sources'))
        $task.Generates = [TaskfileReader]::ParseGlobs([TaskfileReader]::Get($map, 'generates'))
        $task.Status = [TaskYaml]::StrList([TaskfileReader]::Get($map, 'status'))
        foreach ($item in [TaskYaml]::Seq([TaskfileReader]::Get($map, 'preconditions'))) {
            $sh = ''
            $msg = ''
            if ([TaskYaml]::IsMap($item)) {
                $precondition = [TaskYaml]::Map($item)
                $sh = [TaskYaml]::Str([TaskfileReader]::Get($precondition, 'sh'))
                $msg = [TaskYaml]::Str([TaskfileReader]::Get($precondition, 'msg'))
            }
            else { $sh = [TaskYaml]::Str($item) }
            if ($msg.Length -eq 0) { $msg = "``$sh`` failed" }
            $task.Preconditions.Add([pscustomobject]@{ Sh = $sh; Msg = $msg })
        }
        $requires = [TaskYaml]::Map([TaskfileReader]::Get($map, 'requires'))
        foreach ($item in [TaskYaml]::Seq([TaskfileReader]::Get($requires, 'vars'))) {
            if ([TaskYaml]::IsMap($item)) {
                $required = [TaskYaml]::Map($item)
                $entry = [pscustomobject]@{ Name = [TaskYaml]::Str([TaskfileReader]::Get($required, 'name')); Enum = $null }
                if ($required.Contains('enum')) { $entry.Enum = [TaskYaml]::StrList($required['enum']) }
                $task.Requires.Add($entry)
            }
            else { $task.Requires.Add([pscustomobject]@{ Name = [TaskYaml]::Str($item); Enum = $null }) }
        }
        $task.Dir = [TaskYaml]::Str([TaskfileReader]::Get($map, 'dir'))
        $task.Vars = [TaskfileReader]::ParseVars([TaskfileReader]::Get($map, 'vars'), $path)
        $task.Env = [TaskfileReader]::ParseVars([TaskfileReader]::Get($map, 'env'), $path)
        $task.Dotenv = [TaskYaml]::StrList([TaskfileReader]::Get($map, 'dotenv'))
        if ([TaskYaml]::Kind([TaskfileReader]::Get($map, 'silent')) -ne 'null') { $task.Silent = [TaskYaml]::Bool($map['silent']) }
        $task.Interactive = [TaskYaml]::Bool([TaskfileReader]::Get($map, 'interactive'))
        $task.Internal = [TaskYaml]::Bool([TaskfileReader]::Get($map, 'internal'))
        $task.Method = [TaskYaml]::Str([TaskfileReader]::Get($map, 'method'))
        $task.Prefix = [TaskYaml]::Str([TaskfileReader]::Get($map, 'prefix'))
        $task.IgnoreError = [TaskYaml]::Bool([TaskfileReader]::Get($map, 'ignore_error'))
        $task.Run = [TaskYaml]::Str([TaskfileReader]::Get($map, 'run'))
        $task.Platforms = [TaskfileReader]::ParsePlatforms([TaskfileReader]::Get($map, 'platforms'), $path)
        $task.Set = [TaskYaml]::StrList([TaskfileReader]::Get($map, 'set'))
        $task.Shopt = [TaskYaml]::StrList([TaskfileReader]::Get($map, 'shopt'))
        $task.Watch = [TaskYaml]::Bool([TaskfileReader]::Get($map, 'watch'))
        $task.If = [TaskYaml]::Str([TaskfileReader]::Get($map, 'if'))
        $task.Failfast = [TaskYaml]::Bool([TaskfileReader]::Get($map, 'failfast'))
        return $task
    }

    hidden static [object] ParseOutput([object] $node, [string] $path) {
        $output = [pscustomobject]@{
            Name     = ''
            Group    = [pscustomobject]@{ Begin = ''; End = ''; ErrorOnly = $false }
            Prefixed = [pscustomobject]@{ Color = $false }
        }
        $kind = [TaskYaml]::Kind($node)
        if ($kind -eq 'null') { return $output }
        if ($kind -eq 'map') {
            $map = [TaskYaml]::Map($node)
            if ($map.Contains('group')) {
                $group = [TaskYaml]::Map($map['group'])
                $output.Name = 'group'
                $output.Group.Begin = [TaskYaml]::Str([TaskfileReader]::Get($group, 'begin'))
                $output.Group.End = [TaskYaml]::Str([TaskfileReader]::Get($group, 'end'))
                $output.Group.ErrorOnly = [TaskYaml]::Bool([TaskfileReader]::Get($group, 'error_only'))
            }
            elseif ($map.Contains('prefixed')) {
                $output.Name = 'prefixed'
                $output.Prefixed.Color = [TaskYaml]::Bool([TaskfileReader]::Get([TaskYaml]::Map($map['prefixed']), 'color'))
            }
            else { throw [TaskfileReader]::Invalid($path, $node, 'output style must be one of interleaved, group or prefixed') }
            return $output
        }
        $name = [TaskYaml]::Str($node)
        if ($name -cnotin @('interleaved', 'group', 'prefixed')) {
            throw [TaskfileReader]::Invalid($path, $node, "output style `"$name`" not recognized")
        }
        $output.Name = $name
        return $output
    }

    hidden static [List[object]] ParseIncludes([object] $node, [string] $path) {
        $result = [List[object]]::new()
        $kind = [TaskYaml]::Kind($node)
        if ($kind -eq 'null') { return $result }
        if ($kind -ne 'map') { throw [TaskfileReader]::Invalid($path, $node, 'includes must be a map') }
        $map = [TaskYaml]::Map($node)
        foreach ($key in $map.get_Keys()) {
            $value = $map[$key]
            $include = [pscustomobject]@{
                Namespace = [string]$key; Taskfile = ''; Dir = ''; Optional = $false; Internal = $false; Flatten = $false
                Aliases = [string[]]@(); Vars = [TaskfileReader]::NewMap(); Excludes = [string[]]@(); AdvancedImport = $false
            }
            if ([TaskYaml]::IsMap($value)) {
                $options = [TaskYaml]::Map($value)
                $include.AdvancedImport = $true
                $include.Taskfile = [TaskYaml]::Str([TaskfileReader]::Get($options, 'taskfile'))
                $include.Dir = [TaskYaml]::Str([TaskfileReader]::Get($options, 'dir'))
                $include.Optional = [TaskYaml]::Bool([TaskfileReader]::Get($options, 'optional'))
                $include.Internal = [TaskYaml]::Bool([TaskfileReader]::Get($options, 'internal'))
                $include.Flatten = [TaskYaml]::Bool([TaskfileReader]::Get($options, 'flatten'))
                $include.Aliases = [TaskYaml]::StrList([TaskfileReader]::Get($options, 'aliases'))
                $include.Vars = [TaskfileReader]::ParseVars([TaskfileReader]::Get($options, 'vars'), $path)
                $include.Excludes = [TaskYaml]::StrList([TaskfileReader]::Get($options, 'excludes'))
            }
            else { $include.Taskfile = [TaskYaml]::Str($value) }
            if ($include.Taskfile.Length -eq 0) { throw [TaskfileReader]::Invalid($path, $value, "include `"$key`" has no taskfile") }
            $result.Add($include)
        }
        return $result
    }

    # Reads one Taskfile (no includes merged yet).
    static [object] ReadFile([string] $path) {
        $text = [System.IO.File]::ReadAllText($path)
        $root = $null
        try { $root = [TaskYaml]::Load($text) }
        catch {
            $cause = [TaskError]::Unwrap($_.Exception)
            # YamlDotNet throws a bare System.Exception for some malformed flow collections.
            $detail = if ($cause.GetType() -eq [System.Exception]) { "invalid YAML syntax (values containing '{{ }}' inside [ ] or { } must be quoted)" } else { $cause.Message }
            throw [TaskError]::Create("task: Failed to parse ${path}:`nyaml: $detail", [TaskError]::TaskfileInvalid)
        }
        if ([TaskYaml]::Kind($root) -ne 'map') { throw [TaskfileReader]::Invalid($path, $null, 'the Taskfile must be a YAML map') }
        $document = [TaskYaml]::Map($root)

        $version = [TaskYaml]::Str([TaskfileReader]::Get($document, 'version'))
        if ($version.Length -eq 0) {
            throw [TaskError]::Create("task: Failed to parse ${path}:`nversion: not specified (use version: '3')", [TaskError]::TaskfileVersionCheck)
        }
        $major = 0
        if (-not [int]::TryParse(($version -split '\.')[0], [ref] $major)) {
            throw [TaskError]::Create("task: Failed to parse ${path}:`ninvalid version `"$version`"", [TaskError]::TaskfileVersionCheck)
        }
        if ($major -lt 3) {
            throw [TaskError]::Create('task: Taskfile schemas prior to v3 are no longer supported', [TaskError]::TaskfileVersionCheck)
        }
        if ($major -gt 3) {
            throw [TaskError]::Create("task: Taskfile schema version `"$version`" is not supported (supported: 3)", [TaskError]::TaskfileVersionCheck)
        }

        $taskfile = [pscustomobject]@{
            Location = $path
            Dir      = [System.IO.Path]::GetDirectoryName($path)
            Version  = $version
            Output   = [TaskfileReader]::ParseOutput([TaskfileReader]::Get($document, 'output'), $path)
            Method   = [TaskYaml]::Str([TaskfileReader]::Get($document, 'method'))
            Run      = [TaskYaml]::Str([TaskfileReader]::Get($document, 'run'))
            Silent   = [TaskYaml]::Bool([TaskfileReader]::Get($document, 'silent'))
            Interval = [TaskYaml]::Str([TaskfileReader]::Get($document, 'interval'))
            Set      = [TaskYaml]::StrList([TaskfileReader]::Get($document, 'set'))
            Shopt    = [TaskYaml]::StrList([TaskfileReader]::Get($document, 'shopt'))
            Dotenv   = [TaskYaml]::StrList([TaskfileReader]::Get($document, 'dotenv'))
            Vars     = [TaskfileReader]::ParseVars([TaskfileReader]::Get($document, 'vars'), $path)
            Env      = [TaskfileReader]::ParseVars([TaskfileReader]::Get($document, 'env'), $path)
            Includes = [TaskfileReader]::ParseIncludes([TaskfileReader]::Get($document, 'includes'), $path)
            Tasks    = [TaskfileReader]::NewMap()
        }
        $tasksNode = [TaskfileReader]::Get($document, 'tasks')
        $tasksKind = [TaskYaml]::Kind($tasksNode)
        if ($tasksKind -ne 'null') {
            if ($tasksKind -ne 'map') { throw [TaskfileReader]::Invalid($path, $tasksNode, 'tasks must be a map') }
            $tasks = [TaskYaml]::Map($tasksNode)
            $keyNodes = [TaskYaml]::KeyNodes($tasksNode)
            foreach ($key in $tasks.get_Keys()) {
                $name = [string]$key
                $task = [TaskfileReader]::ParseTask($name, $tasks[$key], $path)
                if ($keyNodes.Contains($name)) {
                    $task.Location.Line = [TaskYaml]::Line($keyNodes[$name])
                    $task.Location.Column = [TaskYaml]::Column($keyNodes[$name])
                }
                $taskfile.Tasks[$name] = $task
            }
        }
        return $taskfile
    }

    # ---- includes ---------------------------------------------------------------------------------

    hidden static [string] WithNamespace([string] $taskName, [string] $namespace) {
        if ($taskName.StartsWith(':')) { return $taskName.Substring(1) }
        return "${namespace}:$taskName"
    }

    hidden static [void] Merge([object] $target, [object] $source, [object] $include) {
        foreach ($key in @($source.Vars.get_Keys())) {
            $var = $source.Vars[$key]
            if ($include.AdvancedImport) { $var = [TaskfileReader]::CopyVar($var, $include.Dir) }
            $target.Vars[[string]$key] = $var
        }
        foreach ($key in @($source.Env.get_Keys())) {
            $var = $source.Env[$key]
            if ($include.AdvancedImport) { $var = [TaskfileReader]::CopyVar($var, $include.Dir) }
            $target.Env[[string]$key] = $var
        }
        if ($source.Output.Name.Length -gt 0) { $target.Output = $source.Output }

        $namespace = $include.Namespace
        foreach ($name in @($source.Tasks.get_Keys())) {
            $task = $source.Tasks[$name]
            $task.Internal = $task.Internal -or $include.Internal
            if ($include.Excludes -ccontains $name) { continue }
            $taskName = [string]$name
            if (-not $include.Flatten) {
                foreach ($dep in $task.Deps) { if ($dep.Task.Length -gt 0) { $dep.Task = [TaskfileReader]::WithNamespace($dep.Task, $namespace) } }
                foreach ($cmd in $task.Cmds) { if ($cmd.Task.Length -gt 0) { $cmd.Task = [TaskfileReader]::WithNamespace($cmd.Task, $namespace) } }
                $originalAliases = $task.Aliases
                $aliases = [List[string]]::new()
                foreach ($alias in $originalAliases) { $aliases.Add([TaskfileReader]::WithNamespace($alias, $namespace)) }
                foreach ($namespaceAlias in $include.Aliases) {
                    $aliases.Add([TaskfileReader]::WithNamespace($task.Task, $namespaceAlias))
                    foreach ($alias in $originalAliases) { $aliases.Add([TaskfileReader]::WithNamespace($alias, $namespaceAlias)) }
                }
                $task.Aliases = $aliases.ToArray()
                $taskName = [TaskfileReader]::WithNamespace($taskName, $namespace)
                $task.Namespace = $namespace
                $task.Task = $taskName
            }
            if ($include.AdvancedImport) {
                $task.Dir = [TaskPath]::SmartJoin($include.Dir, $task.Dir)
                foreach ($key in @($include.Vars.get_Keys())) { $task.IncludeVars[[string]$key] = $include.Vars[$key] }
                $copy = [TaskfileReader]::NewMap()
                foreach ($key in @($target.Vars.get_Keys())) { $copy[[string]$key] = $target.Vars[$key] }
                $task.IncludedTaskfileVars = $copy
            }
            if ($target.Tasks.Contains($taskName) -and $include.Flatten) {
                throw [TaskError]::Create("task: Found multiple tasks ($taskName) included by `"$namespace`"", [TaskError]::TaskNameConflict)
            }
            $target.Tasks[$taskName] = $task
        }

        if ($source.Tasks.Contains('default') -and -not $include.Flatten -and -not $target.Tasks.Contains($namespace)) {
            $defaultName = "${namespace}:default"
            if ($target.Tasks.Contains($defaultName)) {
                $defaultTask = $target.Tasks[$defaultName]
                $defaultTask.Aliases = [string[]](@($defaultTask.Aliases) + @($namespace) + @($include.Aliases))
            }
        }
    }

    hidden static [object] LoadFile([string] $path, [List[string]] $stack) {
        foreach ($visited in $stack) {
            if ([string]::Equals($visited, $path, [StringComparison]::OrdinalIgnoreCase)) {
                $previous = $stack[$stack.Count - 1]
                throw [TaskError]::Create("task: include cycle detected between $previous <--> $path", [TaskError]::TaskfileCycle)
            }
        }
        $taskfile = [TaskfileReader]::ReadFile($path)
        if ($taskfile.Includes.Count -eq 0) { return $taskfile }

        $stack.Add($path)
        $baseDir = [System.IO.Path]::GetDirectoryName($path)
        foreach ($include in $taskfile.Includes) {
            # Include paths may use environment variables and the static vars of this Taskfile.
            $data = [TaskfileReader]::NewMap()
            $environment = [Environment]::GetEnvironmentVariables()
            foreach ($key in $environment.get_Keys()) { $data[[string]$key] = [string]$environment[$key] }
            foreach ($key in $taskfile.Vars.get_Keys()) { $data[[string]$key] = $taskfile.Vars[$key].Value }
            $include.Taskfile = [TplEngine]::Expand($include.Taskfile, $data)
            $include.Dir = [TplEngine]::Expand($include.Dir, $data)

            [TaskPath]::AssertLocal($include.Taskfile)
            $target = [TaskPath]::Full($baseDir, $include.Taskfile)
            $entry = ''
            if ([System.IO.Directory]::Exists($target)) { $entry = [TaskfileReader]::FindInDirectory($target) }
            elseif ([System.IO.File]::Exists($target)) { $entry = $target }
            if ([string]::IsNullOrEmpty($entry)) {
                if ($include.Optional) { continue }
                throw [TaskfileReader]::NotFound($target, $false)
            }
            $include.Dir = [TaskPath]::Full($baseDir, $include.Dir)

            $included = [TaskfileReader]::LoadFile($entry, $stack)
            if ($included.Dotenv.Count -gt 0) {
                throw [TaskError]::Create("task: Included Taskfiles can't have dotenv declarations. Please, move the dotenv declaration to the main Taskfile", [TaskError]::TaskfileInvalid)
            }
            [TaskfileReader]::Merge($taskfile, $included, $include)
        }
        $stack.RemoveAt($stack.Count - 1)
        return $taskfile
    }

    # Loads the entrypoint with all includes merged. $dir is the execution directory.
    static [object] Load([string] $entrypoint, [string] $dir) {
        $taskfile = [TaskfileReader]::LoadFile([System.IO.Path]::GetFullPath($entrypoint), [List[string]]::new())
        $taskfile.Dir = if ([string]::IsNullOrEmpty($dir)) { [System.IO.Path]::GetDirectoryName($taskfile.Location) } else { $dir }
        return $taskfile
    }
}
