using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Management.Automation

# Runs the PowerShell source of commands, dynamic variables and conditions.
#
# Execution model
# ---------------
# * Every task run owns a scope (a dynamic module). Its commands are dot-sourced into that
#   scope, so variables and functions defined by one command are visible to the next one,
#   but never to other tasks.
# * User code always runs in a *nested* pipeline of the engine runspace. `exit N` inside a
#   nested pipeline only ends that pipeline and sets $LASTEXITCODE - it cannot close the
#   session of the caller.
# * In 'host' mode the pipeline ends in Out-Default with errors merged, exactly like a
#   command typed at the prompt. Native commands therefore keep the real console handles
#   (colors, progress bars and interactive prompts work).
# * The variables of the Taskfile are defined as PowerShell variables of the scope, so user
#   code can write `$NAME` as well as `{{.NAME}}`. Environment variables are not: they are
#   `$env:NAME` already.

[NoRunspaceAffinity()]
class TaskEnv {
    # A snapshot of the process environment (name -> value).
    static [hashtable] Snapshot() {
        $comparer = if ($global:IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
        $snapshot = [hashtable]::new($comparer)
        $current = [Environment]::GetEnvironmentVariables()
        foreach ($key in $current.get_Keys()) { $snapshot[[string]$key] = [string]$current[$key] }
        return $snapshot
    }

    # Sets or removes ($null) a process environment variable. PowerShell turns $null into an
    # empty string for [string] parameters, which would create an empty variable instead of
    # removing it - hence [NullString].
    static [void] Set([string] $name, [object] $value) {
        if ($null -eq $value) { [Environment]::SetEnvironmentVariable($name, [NullString]::Value) }
        else { [Environment]::SetEnvironmentVariable($name, [string]$value) }
    }

    # Makes the process environment equal to the snapshot again.
    static [void] Restore([hashtable] $snapshot) {
        $current = [TaskEnv]::Snapshot()
        foreach ($key in $current.get_Keys()) {
            if (-not $snapshot.ContainsKey($key)) { [TaskEnv]::Set($key, $null) }
        }
        foreach ($key in $snapshot.get_Keys()) {
            if (-not $current.ContainsKey($key) -or [string]$current[$key] -cne [string]$snapshot[$key]) {
                [TaskEnv]::Set($key, $snapshot[$key])
            }
        }
    }

    # The gate serializes commands whose declared environments differ. The environment is
    # process-wide, so two commands may only overlap when they need exactly the same overrides.
    static [hashtable] NewGate() {
        return @{ Lock = [object]::new(); Active = 0; Signature = ''; Saved = $null }
    }

    hidden static [string] Signature([IDictionary] $overrides) {
        if ($null -eq $overrides -or $overrides.get_Count() -eq 0) { return '' }
        $keys = [List[string]]::new()
        foreach ($key in $overrides.get_Keys()) { $keys.Add([string]$key) }
        $keys.Sort([StringComparer]::Ordinal)
        $sb = [System.Text.StringBuilder]::new()
        foreach ($key in $keys) { [void]$sb.Append($key).Append('=').Append([string]$overrides[$key]).Append([char]0) }
        return $sb.ToString()
    }

    static [void] Enter([hashtable] $gate, [IDictionary] $overrides, [System.Threading.CancellationToken] $cancel) {
        $signature = [TaskEnv]::Signature($overrides)
        [System.Threading.Monitor]::Enter($gate.Lock)
        try {
            while ($gate.Active -gt 0 -and $gate.Signature -cne $signature) {
                $null = [System.Threading.Monitor]::Wait($gate.Lock, 50)
                $cancel.ThrowIfCancellationRequested()
            }
            if ($gate.Active -eq 0) {
                $saved = [ordered]@{}
                if ($null -ne $overrides) {
                    foreach ($key in $overrides.get_Keys()) {
                        $saved[[string]$key] = [Environment]::GetEnvironmentVariable([string]$key)
                        [TaskEnv]::Set([string]$key, [string]$overrides[$key])
                    }
                }
                $gate.Saved = $saved
                $gate.Signature = $signature
            }
            $gate.Active++
        }
        finally { [System.Threading.Monitor]::Exit($gate.Lock) }
    }

    static [void] Leave([hashtable] $gate) {
        [System.Threading.Monitor]::Enter($gate.Lock)
        try {
            $gate.Active--
            if ($gate.Active -le 0) {
                $gate.Active = 0
                if ($null -ne $gate.Saved) {
                    foreach ($key in $gate.Saved.get_Keys()) { [TaskEnv]::Set([string]$key, $gate.Saved[$key]) }
                }
                $gate.Saved = $null
                $gate.Signature = ''
                [System.Threading.Monitor]::PulseAll($gate.Lock)
            }
        }
        finally { [System.Threading.Monitor]::Exit($gate.Lock) }
    }
}

[NoRunspaceAffinity()]
class TaskScript {
    hidden static [string] $HostScript = 'param($scope, $code) . $scope $code 2>&1 | Out-Default'

    hidden static [string] $CaptureScript = 'param($scope, $code) . $scope $code'

    hidden static [string] $StreamScript = @'
param($scope, $code, $sink)
. $scope $code *>&1 | ForEach-Object { $sink.Add([System.Collections.DictionaryEntry]::new('x', $_)) }
'@

    hidden static [string] $LineScript = @'
param($scope, $code, $emit)
. $scope $code *>&1 | Out-String -Stream | ForEach-Object {
    if ($null -ne $emit.Buffer) { $emit.Buffer.Add($_) }
    elseif ($null -ne $emit.Sink) { $emit.Sink.Add([System.Collections.DictionaryEntry]::new('o', $emit.Prefix + $_)) }
    else { $emit.UI.WriteLine($emit.Prefix + $_) }
}
'@

    # Names that belong to PowerShell (automatic and preference variables). A Taskfile variable
    # with one of these names is not defined as a PowerShell variable; `{{.NAME}}` still works.
    hidden static [HashSet[string]] $Reserved = [HashSet[string]]::new([string[]]@(
            '_', 'args', 'ConfirmPreference', 'ConsoleFileName', 'DebugPreference', 'EnabledExperimentalFeatures',
            'Error', 'ErrorActionPreference', 'ErrorView', 'Event', 'EventArgs', 'EventSubscriber', 'ExecutionContext',
            'false', 'foreach', 'FormatEnumerationLimit', 'HOME', 'Host', 'InformationPreference', 'input',
            'IsCoreCLR', 'IsLinux', 'IsMacOS', 'IsWindows', 'LASTEXITCODE', 'Matches', 'MaximumHistoryCount',
            'MyInvocation', 'NestedPromptLevel', 'null', 'OFS', 'OutputEncoding', 'PID', 'PROFILE', 'ProgressPreference',
            'PSBoundParameters', 'PSCmdlet', 'PSCommandPath', 'PSCulture', 'PSDebugContext', 'PSDefaultParameterValues',
            'PSEdition', 'PSEmailServer', 'PSHOME', 'PSItem', 'PSModuleAutoLoadingPreference',
            'PSNativeCommandArgumentPassing', 'PSNativeCommandUseErrorActionPreference', 'PSScriptRoot', 'PSSenderInfo',
            'PSSessionApplicationName', 'PSSessionConfigurationName', 'PSSessionOption', 'PSStyle', 'PSUICulture',
            'PSVersionTable', 'PWD', 'Sender', 'ShellId', 'StackTrace', 'switch', 'this', 'Transcript', 'true',
            'VerbosePreference', 'WarningPreference', 'WhatIfPreference'
        ), [StringComparer]::OrdinalIgnoreCase)

    hidden static [regex] $SimpleName = [regex]::new('^[\p{L}\p{Nd}_]+$')

    # A fresh scope for one task run (or one dynamic variable / condition).
    static [object] NewScope() {
        $scope = [psmoduleinfo]::new($true)
        $scope.SessionState.PSVariable.Set('ErrorActionPreference', [ActionPreference]::Stop)
        return $scope
    }

    static [object] NewScope([IDictionary] $variables) {
        $scope = [TaskScript]::NewScope()
        $null = [TaskScript]::SetVariables($scope, $variables)
        return $scope
    }

    # A deep copy for user code: lists become arrays, maps (case-sensitive) ordered dictionaries.
    # The originals are shared by the whole run and must not be changed by a command.
    hidden static [object] ToScriptValue([object] $value) {
        $v = $value
        if ($v -is [psobject] -and $v -isnot [System.Management.Automation.PSCustomObject]) { $v = $v.psobject.BaseObject }
        if ($v -is [IDictionary]) {
            $map = [System.Collections.Specialized.OrderedDictionary]::new()
            foreach ($key in @($v.get_Keys())) { $map[[string]$key] = [TaskScript]::ToScriptValue($v[$key]) }
            return $map
        }
        if ($null -ne $v -and $v -isnot [string] -and $v -is [IEnumerable]) {
            $items = [List[object]]::new()
            foreach ($item in $v) { $items.Add([TaskScript]::ToScriptValue($item)) }
            return $items.ToArray()
        }
        return $v
    }

    # Defines Taskfile variables as PowerShell variables of $scope, so that commands can use
    # `$NAME` next to `{{.NAME}}`. Returns the names left out because PowerShell reserves them.
    static [string[]] SetVariables([object] $scope, [IDictionary] $variables) {
        $skipped = [List[string]]::new()
        if ($null -eq $variables) { return $skipped.ToArray() }
        foreach ($key in $variables.get_Keys()) {
            $name = [string]$key
            if (-not [TaskScript]::SimpleName.IsMatch($name)) { continue }
            if ([TaskScript]::Reserved.Contains($name)) { $skipped.Add($name); continue }
            try { $scope.SessionState.PSVariable.Set($name, [TaskScript]::ToScriptValue($variables[$key])) }
            catch { $skipped.Add($name) }
        }
        return $skipped.ToArray()
    }

    # The names of the PowerShell variables a script refers to (`$name`, `@name`, `$script:name`;
    # not `$env:NAME`). Empty when the script does not parse.
    static [string[]] VariableNames([string] $text) {
        $names = [List[string]]::new()
        if ([string]::IsNullOrEmpty($text) -or -not ($text.Contains('$') -or $text.Contains('@'))) { return $names.ToArray() }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $tokens, [ref] $errors)
        $seen = [HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)) {
            if (-not $node.VariablePath.IsVariable) { continue }
            # UserPath keeps a scope qualifier: script:name -> name
            $name = $node.VariablePath.UserPath
            $name = $name.Substring($name.LastIndexOf(':') + 1)
            if ($seen.Add($name)) { $names.Add($name) }
        }
        return $names.ToArray()
    }

    hidden static [bool] IsStop([Exception] $exception) {
        $current = $exception
        while ($null -ne $current) {
            if ($current -is [PipelineStoppedException] -or $current -is [OperationCanceledException]) { return $true }
            $current = $current.InnerException
        }
        return $false
    }

    hidden static [ErrorRecord] ToErrorRecord([ErrorRecord] $caught) {
        $exception = $caught.Exception
        while ($null -ne $exception.InnerException -and
            ($exception -is [MethodInvocationException] -or $exception -is [System.Reflection.TargetInvocationException])) {
            $exception = $exception.InnerException
        }
        if ($exception -is [IContainsErrorRecord] -and $null -ne $exception.ErrorRecord) { return $exception.ErrorRecord }
        return [ErrorRecord]::new($exception, 'TaskCommandFailed', [ErrorCategory]::NotSpecified, $null)
    }

    # Runs PowerShell source text inside $scope with $directory as the current location.
    #
    # $mode   host    - render everything on the host (Out-Default)
    #         capture - return the success output in Output
    #         stream  - send every record (all streams) to $target, a sink collection
    #         lines   - send formatted text lines to $target (@{ Buffer; Sink; UI; Prefix })
    #
    # Returns ExitCode (0 = success), Message (failure reason), Error (ErrorRecord) and Output.
    # A command fails when it throws a terminating error, calls `exit N` with N != 0, or
    # leaves $LASTEXITCODE non-zero (an unhandled native command failure).
    static [object] Invoke([string] $text, [object] $scope, [string] $directory, [string] $mode, [object] $target) {
        $result = [pscustomobject]@{ ExitCode = 0; Message = ''; Error = $null; Output = $null }
        $code = $null
        try { $code = [scriptblock]::Create($text) }
        catch {
            $result.Error = [TaskScript]::ToErrorRecord($_)
            $result.ExitCode = 1
            $result.Message = $result.Error.Exception.Message
            return $result
        }
        if (-not [string]::IsNullOrEmpty($directory) -and [System.IO.Directory]::Exists($directory)) {
            Set-Location -LiteralPath $directory
        }
        $global:LASTEXITCODE = 0
        $wrapper = switch ($mode) {
            'host' { [TaskScript]::HostScript }
            'stream' { [TaskScript]::StreamScript }
            'lines' { [TaskScript]::LineScript }
            default { [TaskScript]::CaptureScript }
        }
        $shell = [powershell]::Create([RunspaceMode]::CurrentRunspace)
        try {
            [void]$shell.AddScript($wrapper, $true).AddArgument($scope).AddArgument($code)
            if ($mode -eq 'stream' -or $mode -eq 'lines') { [void]$shell.AddArgument($target) }
            try {
                $output = $shell.Invoke()
                if ($mode -eq 'capture') { $result.Output = $output }
            }
            catch {
                if ([TaskScript]::IsStop($_.Exception)) { throw }
                $result.Error = [TaskScript]::ToErrorRecord($_)
                $result.ExitCode = 1
                $result.Message = $result.Error.Exception.Message
            }
        }
        finally { $shell.Dispose() }

        if ($null -eq $result.Error) {
            $last = $global:LASTEXITCODE
            if ($last -is [int] -and $last -ne 0) {
                $result.ExitCode = $last
                $result.Message = "exit status $last"
            }
        }
        return $result
    }

    # Converts captured output to the string value of a dynamic variable.
    static [string] OutputToString([object] $output) {
        $parts = [List[string]]::new()
        if ($null -ne $output) {
            foreach ($item in $output) {
                if ($null -eq $item) { $parts.Add(''); continue }
                $parts.Add([LanguagePrimitives]::ConvertTo($item, [string], [cultureinfo]::InvariantCulture))
            }
        }
        $text = [string]::Join("`n", $parts)
        if ($text.EndsWith("`r`n")) { return $text.Substring(0, $text.Length - 2) }
        if ($text.EndsWith("`n")) { return $text.Substring(0, $text.Length - 1) }
        return $text
    }

    # Evaluates a condition (status / precondition / if). It holds when the script succeeds
    # and its last output is not the boolean $false - so both `Test-Path x` and exit codes work.
    # The literals true / false are accepted too: Taskfiles commonly use a template that
    # renders to one of them (`if: '{{eq .ENV "prod"}}'`) and rely on the shell builtins.
    static [bool] Test([string] $text, [string] $directory, [IDictionary] $variables) {
        $literal = $text.Trim()
        if ($literal -ceq 'true') { return $true }
        if ($literal -ceq 'false') { return $false }
        $result = [TaskScript]::Invoke($text, [TaskScript]::NewScope($variables), $directory, 'capture', $null)
        if ($result.ExitCode -ne 0) { return $false }
        $last = $null
        if ($null -ne $result.Output) { foreach ($item in $result.Output) { $last = $item } }
        if ($last -is [psobject]) { $last = $last.psobject.BaseObject }
        if ($last -is [bool] -and -not $last) { return $false }
        return $true
    }
}
