# PSTaskFile

A PowerShell implementation of the [Task](https://taskfile.dev) runner.

`task` runs the commands of a `Taskfile.yml` with a POSIX shell interpreter, so PowerShell
has to be wrapped in `pwsh -c '...'` strings. PSTaskFile reads the same Taskfile format but
runs everything as PowerShell:

- `cmds`, `status`, `preconditions` and `if` are PowerShell code. Assignments, pipelines,
  cmdlets and native programs all work as written.
- Dynamic variables (`sh:`) in `vars` and `env` are PowerShell commands; their output
  becomes the value.
- The variables of the Taskfile are PowerShell variables as well: `$VERSION` works next to
  `{{.VERSION}}`.
- The command is `Invoke-Task`, and the modes of the `task` CLI are separate cmdlets with
  PowerShell naming (`Get-Task`, `Test-Task`, `Watch-Task`, ...).

```yaml
version: '3'

vars:
  CONFIGURATION: Release
  VERSION:
    sh: (Get-Content version.txt -Raw).Trim()   # the output of PowerShell becomes the value

env:
  BUILD_CONFIGURATION: '{{.CONFIGURATION}}'

tasks:
  default:
    desc: Build and package
    cmds:
      - task: package

  build:
    desc: Compile the sources
    sources: ['src/**/*']
    generates: ['artifacts/app.txt']
    cmds:
      - New-Item -ItemType Directory -Path artifacts -Force | Out-Null
      - Copy-Item src/app.txt artifacts/app.txt
      - Write-Host "Built {{.VERSION}} ($env:BUILD_CONFIGURATION)"

  package:
    desc: Create the release archive
    deps: [build]
    cmds:
      - $name = "app-{{.VERSION}}.zip"          # variables live for the whole task
      - New-Item -ItemType Directory -Path dist -Force | Out-Null
      - Compress-Archive -Path artifacts/* -DestinationPath "dist/$name" -Force
      - Write-Host "Created dist/$name" -ForegroundColor Green

  clean:
    desc: Remove the build output
    status:
      - '-not (Test-Path artifacts) -and -not (Test-Path dist)'   # a boolean decides
    cmds:
      - Remove-Item artifacts, dist -Recurse -Force -ErrorAction Ignore
```

```powershell
PS> Invoke-Task
task: [build] New-Item -ItemType Directory -Path artifacts -Force | Out-Null
task: [build] Copy-Item src/app.txt artifacts/app.txt
task: [build] Write-Host "Built 1.2.3 ($env:BUILD_CONFIGURATION)"
Built 1.2.3 (Release)
task: [package] $name = "app-1.2.3.zip"
...
Created dist/app-1.2.3.zip
```

## Requirements and installation

- PowerShell 7.4 or later
- The [powershell-yaml](https://www.powershellgallery.com/packages/powershell-yaml) module
  (`Install-Module powershell-yaml -Scope CurrentUser`)

The module is not published to the PowerShell Gallery. Import it from a clone, or copy
`src/PSTaskFile` into a directory of `$env:PSModulePath`:

```powershell
Import-Module ./src/PSTaskFile/PSTaskFile.psd1
```

Developed and tested on Windows. Nothing in the module is Windows-specific, but it has not
been run on Linux or macOS yet.

## Commands

| `task` | PSTaskFile |
| --- | --- |
| `task build test` | `Invoke-Task build, test` |
| `task build CONFIG=Release` | `Invoke-Task build -Variable @{ CONFIG = 'Release' }` |
| `task test -- -v --tag unit` | `Invoke-Task test -- -v --tag unit` (also `-ArgumentList`) |
| `task --list` | `Get-Task` |
| `task --list-all` | `Get-Task -All` |
| `task --list --json` | `Get-Task -IncludeStatus \| ConvertTo-Json -Depth 3` |
| `task --summary build` | `Get-TaskSummary build` |
| `task --status build` | `Test-Task build` (returns `$true` / `$false`) |
| `task --watch build` | `Watch-Task build` or `Invoke-Task build -Watch` |
| `task --init` | `New-Taskfile` |
| `--dry` | `-WhatIf` |
| `--force` | `-Force` |
| `--silent` | `-Silent` |
| `--verbose` | `-Verbose` |
| `--parallel`, `--concurrency N`, `--failfast` | `-Parallel`, `-Concurrency N`, `-FailFast` |
| `--output`, `--output-group-begin/-end/-error-only` | `-Output`, `-OutputGroupBegin`, `-OutputGroupEnd`, `-OutputGroupErrorOnly` |
| `--yes` | `-AssumeYes` |
| `--exit-code` | `-ExitCode` |
| `--taskfile`, `--dir`, `--global` | `-Taskfile`, `-Directory`, `-Global` |
| `--interval` | `-Interval` |
| `--sort` | `Get-Task -Sort` |
| `--color=false` | `-NoColor` (or `NO_COLOR=1`) |
| `--completion` | built in: task names complete with <kbd>Tab</kbd> |
| `--version` | `(Get-Module PSTaskFile).Version` |

`Get-Help Invoke-Task -Full` (and the same for the other commands) describes every
parameter. The short flags of `task` exist as aliases (`-t`, `-d`, `-f`, `-s`, `-p`, ...).

`Get-Task` returns objects, so the usual tools apply:

```powershell
Get-Task -All | Where-Object Name -Like 'docs:*' | Format-Table Name, Description
Get-Task -Name lint | Invoke-Task
```

## How commands run

**PowerShell, in process.** Each `Invoke-Task` call runs in its own runspace of the current
process. That runspace starts clean: your profile, and the variables and functions of your
session, are not visible to tasks, so a Taskfile behaves the same for everyone.

**One scope per task.** The commands of a task share a scope. A variable or function that
one command defines is available to the following commands of that task, to its deferred
commands, and to nothing else:

```yaml
tasks:
  release:
    cmds:
      - $tag = "v$(Get-Content version.txt)"
      - git tag $tag
      - defer: Write-Host "finished $tag"
```

**Variables are PowerShell variables.** The variables of the Taskfile are defined in the
scope of the task, so code can use `$NAME` wherever it could use `{{.NAME}}`:

```yaml
vars:
  VERSION: 1.2.3
  FILES: [src/app.txt, docs/read me.md]

tasks:
  package:
    cmds:
      - Compress-Archive -Path $FILES -DestinationPath "dist/app-$VERSION.zip" -Force
      - for: { var: FILES }
        cmd: Get-Item $ITEM
```

```powershell
Invoke-Task package -Variable @{ VERSION = '2.0.0' }
```

A template is pasted into the text of the command before PowerShell reads it; a variable
is passed as a value. `$FILES` is an array, and `$ITEM` stays one argument even with a
space in it - there is no quoting to get right.

- *Which variables:* global `vars`, the `vars` of includes, of the task and of the call
  (`task:` with `vars:`), the values given with `-Variable`, the special variables
  (`$TASK`, `$ROOT_DIR`, `$CLI_ARGS_LIST`, ...), the loop variables (`$ITEM`, `$KEY`, or the
  name given with `as:`) and `$EXIT_CODE` in deferred commands.
- *Not environment variables:* what comes from the OS environment, `env:` or `dotenv` is
  `$env:NAME`, as everywhere in PowerShell.
- *Where:* in `cmds`, `status`, `preconditions`, `if`, and in `sh:` of `vars` and `env`
  (there: the variables resolved so far).
- *Types:* strings, numbers and booleans keep their type, lists are arrays, maps are
  ordered dictionaries. Every task gets its own copy.
- *When:* once, when the task starts. A command may assign a new value for the commands
  that follow; `{{.NAME}}` keeps the value of the Taskfile.
- *Names:* PowerShell's own variables are left alone. A Taskfile variable named `HOME`,
  `HOST`, `PWD`, `ERROR`, `ErrorActionPreference`, ... is `{{.HOME}}` only (`-Verbose` tells
  you), and so is one whose name is not made of letters, digits and `_`. PowerShell does
  not distinguish `$Name` from `$NAME`: do not rely on variables that differ only in case.
- *Undefined variables* are `$null`, as usual. List the ones a task cannot do without
  under `requires:` to fail early instead of running with an empty value.

**The location is reset.** Every command starts in the `dir` of its task (the directory of
the Taskfile by default), whatever the previous command did.

**When a command fails.** `$ErrorActionPreference` is `Stop` in every task, like the `pwsh`
steps of CI systems. A command fails when

- it throws or writes an error (`throw`, `Write-Error`, a failing cmdlet), or
- it calls `exit N` with a non-zero code, or
- `$LASTEXITCODE` is non-zero when it ends, i.e. a native program failed and the command
  did not deal with it.

A failed native program does not stop a multi-line command by itself; add
`set: [errexit]` to the task (or the Taskfile) to stop at the first one. To accept a
failure, handle it and reset the code (`$global:LASTEXITCODE = 0`) or use
`ignore_error: true`. `exit` only ends the command, never your session.

`set: [nounset]` maps to `Set-StrictMode -Version Latest` and `set: [xtrace]` to
`Set-PSDebug -Trace 1`. `shopt` is accepted and ignored.

**Conditions.** A `status`, `preconditions` or `if` entry holds when its script succeeds
*and* does not return `$false`. Both styles work:

```yaml
status:
  - Test-Path dist/app.zip            # boolean
  - git diff --quiet -- src           # exit code
```

The literals `true` and `false` are accepted as well, so templates such as
`if: '{{eq .ENV "prod"}}'` keep working.

**Dynamic variables.** The output of a `sh:` command is converted to text, one line per
output object, without the trailing newline - the same shape `task` produces. Variables
resolved so far are available to the command as PowerShell variables and, like in `task`,
as environment variables. Each distinct command is evaluated once per run and directory;
a command that uses PowerShell variables once per set of their values.

**Environment.** `env` and `dotenv` values are set while a command of the task runs. As in
`task` v3, a variable that already exists in the environment wins over the Taskfile; set
`TASK_X_ENV_PRECEDENCE=1` to reverse that. Changes a command makes with `$env:NAME = ...`
stay for the rest of the run and are undone when `Invoke-Task` returns.

Tasks that run in parallel (`deps`, `-Parallel`) each run in their own runspace, but the
environment belongs to the process. Commands that need *different* `env` values are
therefore not run at the same moment; everything else stays parallel.

**Output.** By default tasks write to the host like a console program: native programs keep
colors, progress bars and prompts, and nothing lands in the pipeline. With `-PassThru` the
output of the tasks is emitted on the streams of `Invoke-Task` instead - objects on the
pipeline, errors, warnings and the engine messages (`task: [build] ...`) on their streams:

```powershell
$version = Invoke-Task version -Silent -PassThru
Invoke-Task build -PassThru *> build.log
```

The `prefixed` and `group` output styles capture the output as text lines in both modes.

**Failures and exit codes.** A failed run throws a terminating error and sets
`$LASTEXITCODE` to the code `task` would exit with:

| Code | Meaning |
| --- | --- |
| 0 | success |
| 1 | other errors (template errors, failed dynamic variables) |
| 100 | no Taskfile found |
| 101 | the Taskfile already exists (`New-Taskfile`) |
| 102, 109 | the Taskfile is invalid |
| 107 | unsupported schema version |
| 110 | include cycle |
| 200 | task not found |
| 201 | a task failed (with `-ExitCode`: the exit code of the failing command) |
| 202 | the task is internal |
| 203 | several tasks match the name |
| 204 | maximum task call exceeded |
| 206, 207 | required variable missing / value not allowed |

In scripts and CI:

```powershell
pwsh -NoProfile -Command "Import-Module PSTaskFile; Invoke-Task build; exit `$LASTEXITCODE"
```

## Templates

Templating is Go's `text/template` syntax with the same functions as `task` (the
slim-sprig set plus `OS`, `ARCH`, `joinPath`, `splitLines`, `catLines`, ...), implemented in
PowerShell and checked against the output of `task`.

Two functions are adapted to PowerShell:

- `shellQuote` (alias `q`) produces a PowerShell single-quoted literal:
  `{{shellQuote .MESSAGE}}` -> `'it''s done'`.
- `CLI_ARGS` joins the arguments with PowerShell quoting where needed, so
  `dotnet test {{.CLI_ARGS}}` passes them on unchanged.

`{{` always starts a template action. Where PowerShell needs a literal `{{` (format
strings, nested script blocks) write ``{{`{{`}}``.

## What is supported

Everything in the version 3 schema that does not depend on a POSIX shell: tasks in all
their forms, `cmds` / `cmd`, `deps`, task calls with `vars`, `defer`, `for` loops (lists,
variables, `sources` / `generates`, matrices), `vars` with `sh` / `ref` / `map`, `env`,
`dotenv`, `includes` (namespaces, `dir`, `vars`, `aliases`, `internal`, `flatten`,
`excludes`, `optional`), `sources` / `generates` with the `checksum`, `timestamp` and `none`
methods, `status`, `preconditions`, `requires`, `if`, `platforms`, `prompt`, `run`,
`silent`, `label`, `prefix`, `aliases`, wildcard task names, `ignore_error`, `interactive`,
`watch`, the output styles, and the special variables.

Not supported:

- Remote Taskfiles and the related flags (an experiment in `task`), `.taskrc.yml`, and the
  experiments switches other than `TASK_X_ENV_PRECEDENCE`.
- `--interactive` (prompting for missing required variables).
- `shopt`, and `set` options other than `errexit`, `pipefail`, `nounset` and `xtrace`.
- YAML timestamps stay strings (`2024-01-02` is not converted to a date).

Things to know when coming from `task`:

- A Taskfile written for PSTaskFile is not runnable by `task`, and vice versa, unless its
  commands mean the same in both shells.
- `$NAME` in a command is a PowerShell variable - a variable of the Taskfile or one the
  task assigned - not an environment variable as in `sh`. Environment variables are
  `$env:NAME`.
- Because tasks run inside your PowerShell process, an assembly or binary module that a
  task loads stays loaded (and its files stay locked) until the session ends. Run such
  steps in a child process: `pwsh -NoProfile -Command ...`.
- Watching polls the source files (every 500 ms unless `interval` or `-Interval` says
  otherwise) instead of using file system notifications.
- The fingerprints under `.task/` are not interchangeable with those written by `task`.

## Development

```powershell
pwsh -NoProfile -File tools/Invoke-Tests.ps1                      # all tests
pwsh -NoProfile -File tools/Invoke-Tests.ps1 -Path tests/Template.Tests.ps1 -Output Detailed
```

or, with the module itself (see `Taskfile.yml`):

```powershell
Import-Module ./src/PSTaskFile/PSTaskFile.psd1 -Force
Invoke-Task test
Invoke-Task test:Template
```

The tests need Pester 5.5 or later. When the `task` binary is on the `PATH`,
`tests/Compatibility.Tests.ps1` also runs the same Taskfile through it and compares output,
messages and exit codes; without it those tests are skipped.

`AGENTS.md` describes the architecture and the conventions of the code base.
