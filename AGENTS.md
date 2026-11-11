# AGENTS.md

Guidance for AI coding agents (and humans) working on this repository.

## What this is

PSTaskFile is a PowerShell module that implements the [Task](https://taskfile.dev) runner
(`task`, go-task) for Taskfiles whose commands are PowerShell. User-facing behaviour is
documented in `README.md`; keep it in sync with the code (command table, "How commands
run", "What is supported").

The reference for behaviour is go-task itself. Where PowerShell forces a difference, the
difference is deliberate and written down in `README.md`.

## Commands

```powershell
# All tests. Always a fresh process: PowerShell classes cannot be reloaded in a session.
pwsh -NoProfile -File tools/Invoke-Tests.ps1

# One file, verbose
pwsh -NoProfile -File tools/Invoke-Tests.ps1 -Path tests/Template.Tests.ps1 -Output Detailed

# Tests by name
pwsh -NoProfile -File tools/Invoke-Tests.ps1 -FullName '*wildcard*'

# The repository's own Taskfile (dogfooding)
pwsh -NoProfile -Command "Import-Module ./src/PSTaskFile/PSTaskFile.psd1; Invoke-Task test:Loader"
```

A session that imported the module keeps the classes it loaded first. When the files change
afterwards, a class in one file resolves the classes of *other* files to the old ones, so new
and old code get mixed - `Import-Module -Force` does not help. `Test-TaskModuleChanged`
(`PSTaskFile.psm1`, called on import and by `Invoke-TaskEngine`) detects this and tells the
user to start a new session. So: never verify a change in a session that has already used
the module, and do not edit `src/` while the test suite runs.

Requirements: PowerShell 7.4+, Pester 5.5+, the `powershell-yaml` module. If the `task`
binary is installed, `tests/Compatibility.Tests.ps1` compares against it; otherwise it is
skipped. PSScriptAnalyzer is optional (`Invoke-Task lint`).

## Layout

```
src/PSTaskFile/
  PSTaskFile.psd1      manifest (exports, RequiredModules)
  PSTaskFile.psm1      loads Private/*.ps1 in a fixed order, then Public/*.ps1
  Public/              one file per exported command
  Private/
    Yaml.ps1           TaskYaml: YAML via the YamlDotNet node model (case-sensitive keys, positions)
    Template.ps1       Tpl*: Go text/template engine + slim-sprig / Task functions
    Model.ps1          TaskError, TaskPath, TaskfileReader (YAML -> model, includes merged)
    Dotenv.ps1         TaskDotenv
    Fingerprint.ps1    TaskGlob, TaskFingerprint (checksum / timestamp state under .task/)
    Runner.ps1         TaskEnv (environment gate), TaskScript (runs PowerShell source)
    Output.ps1         TaskLog (engine messages, host vs. sink)
    Compiler.ps1       TaskCompiler (variable resolution, templating a task for one call)
    Executor.ps1       TaskExecutor (RunTask and friends), TaskEngine (entry point, list/summary/status/watch)
    Host.ps1           functions used by the public commands (engine runspace, result reporting, completion)
tests/                 Pester tests; Helpers.ps1 is dot-sourced by every file
tools/Invoke-Tests.ps1 test runner
Taskfile.yml           development tasks, run by the module itself
```

A new private file must be added to `$privateOrder` in `PSTaskFile.psm1`; classes have to be
defined before a later file references them. A new public command needs its file in
`Public/`, an entry in `FunctionsToExport`, comment-based help with an example, and a row in
the README table.

## Architecture

1. **Public command** (caller's runspace) builds a request hashtable (`New-TaskEngineRequest`)
   and calls `Invoke-TaskEngine`.
2. **`Invoke-TaskEngine`** creates a *dedicated engine runspace* with this module imported,
   runs `[TaskEngine]::Run($request)` there and waits. The engine returns a result table
   (`Ok`, `Data`, `Message`, `Code`, `ExitStatus`); `Complete-TaskResult` turns a failure
   into a terminating error and sets `$LASTEXITCODE`.
3. **`TaskEngine.NewContext`** finds and loads the Taskfile and creates `$ctx`, the context
   shared by the whole run.
4. **`TaskExecutor.RunTask`** follows go-task's `Executor.RunTask`: find task -> fast compile
   -> platform / required vars -> full compile (dynamic vars run) -> `run:` handling -> deps
   (parallel) -> preconditions / up-to-date -> prompt -> cmds -> deferred cmds.
5. **`TaskScript.Invoke`** runs the PowerShell of a command, dynamic variable or condition
   in a *nested pipeline* of the engine runspace, dot-sourced into the scope of the task run
   (a dynamic module created by `[psmoduleinfo]::new($true)`).

Parallel work (deps, `-Parallel`, watch) runs in *branches*: additional runspaces started by
`TaskExecutor.StartBranch`, each importing the module and receiving the same `$ctx`.

### Invariants - do not break these

- **User code runs only through `TaskScript.Invoke`, in a nested pipeline.** `exit` inside a
  nested pipeline ends that pipeline and sets `$LASTEXITCODE`; at the top level of a
  runspace it would ask the host to close the session.
- **Host mode ends the pipeline in `Out-Default` with errors merged** (`2>&1 | Out-Default`).
  That is what keeps native commands attached to the real console. Do not collect the
  output of commands in host mode.
- **`$ctx` holds only plain data and thread-safe .NET objects.** No script blocks and no
  instances of PowerShell classes: both are bound to a runspace. The Taskfile model is
  PSCustomObjects / dictionaries / lists for the same reason. Results cross runspaces as
  hashtables (see `RunBranch`), never as exception objects of our own types.
- **Taskfile variables reach user code as PowerShell variables through `ScriptVars`.**
  `TaskCompiler.Compile` collects them (everything `GetVariables` resolves except what comes
  from the environment; a command adds its loop variables), `TaskScript.SetVariables`
  defines deep copies in the scope and skips the names PowerShell reserves. Whatever runs
  user code - commands, conditions, dynamic variables - must pass them on. The cache key of
  a dynamic variable includes the values of the variables its script refers to.
- **The environment is process-wide.** Commands set their `env` through `TaskEnv.Enter/Leave`
  (the gate serializes commands that need different values). Never set task environment
  variables any other way. `TaskEngine.Cleanup` restores the snapshot taken at the start.
- **All classes are `[NoRunspaceAffinity()]`** and must stay self-contained: class methods
  may call other classes and cmdlets, not module-private functions.
- **Deep call chains hop to a new branch** every `HopInterval` levels (`RunParallel`). A long
  catch/rethrow chain on one thread overflows the stack and kills the process.
- Variable and task names are **case-sensitive** (`OrderedDictionary::new()`, never
  `[ordered]@{}` or `@{}` for them).

## PowerShell pitfalls that have already bitten this code

- `$x = if (...) { $list } else { ... }` **enumerates** the result: a one-element list becomes
  its element, an empty one `$null`. Assign collections with statements. The same goes for
  returning collections from *functions* (use `, $value`); class methods are safe.
- A `[string]` variable, parameter or return value is never `$null`, it is `''`. Test with
  `[string]::IsNullOrEmpty()`.
- `$null` passed to a .NET `string` parameter becomes `''`. To really pass null use
  `[NullString]::Value` (see `TaskEnv.Set`: an empty string would create an empty
  environment variable instead of removing it).
- Inside a class, a local variable must not have the name of a property of that class
  (`$text` vs. `$this.Text` is a parse error), and automatic variables (`$input`, `$matches`,
  `$args`, `$host`, `$home`) must not be used as names.
- Dictionary member access looks up keys first: use `.get_Count()`, `.get_Keys()`,
  `.Contains()` and the indexer on dictionaries that hold user data.
- An integer index on an `OrderedDictionary` is positional. Cast keys to `[string]`.
- `ConvertFrom-Yaml` returns case-insensitive dictionaries; use `TaskYaml` instead.
- In YAML, `{{ ... }}` inside a flow collection (`[a, {{.B}}]`) is invalid. Use block
  sequences or quote the scalar - also in test Taskfiles.
- Literal `\uXXXX` sequences written through tooling may be decoded; build such strings from
  parts in tests.

## Tests

Work test-first: add or change a test, watch it fail, then change the code.

- Unit-level tests reach private classes with `Invoke-InModule { [TaskGlob]::Expand(...) }`.
- Behaviour is tested through the public commands. `Invoke-TestTask` (Helpers.ps1) runs
  `Invoke-Task -PassThru` and returns `Lines`, `Output`, `Records`, `Error` and `ExitCode`.
- Host mode (no `-PassThru`) can only be observed from a child process; see
  `Invoke-InChildProcess` in `tests/Invoke-Task.Features.Tests.ps1`. Keep those few: they are slow.
- When behaviour is supposed to match go-task, add a case to `tests/Compatibility.Tests.ps1`
  (only commands that mean the same in sh and PowerShell: `echo "one argument"`, `exit N`).
- Avoid timing assertions. For concurrency, make tasks wait for each other through files
  (see "runs dependencies in parallel").
- Tests create their Taskfiles under `$TestDrive` with `New-TestTaskfile`.

## Conventions

- Code, comments, help and commit messages are in English.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
  (`feat:`, `fix:`, `test:`, `docs:`, `refactor:`, `chore:`, optional scope). Do not add
  tool or AI attribution, session links or `Co-Authored-By` trailers.
- Work happens on `main`; commit in small steps with the tests passing.
- Error messages mirror go-task (`task: ...`), and exit codes come from `TaskError`.
- Public parameters use PowerShell names; the short flags of `task` are aliases.
