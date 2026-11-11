# Runs the same Taskfile with the real `task` binary (go-task) and with Invoke-Task and
# compares the command output, the engine messages, the error and the exit code.
#
# Only commands that mean the same in POSIX shell and in PowerShell are used (echo with one
# quoted argument, exit). The tests are skipped when `task` is not installed.

BeforeDiscovery {
    $script:GoTask = Get-Command task -CommandType Application -ErrorAction Ignore | Select-Object -First 1
    $script:SkipCompat = $null -eq $script:GoTask
}

BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"

    $script:Root = New-TestDirectory
    $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
    $other = if ($IsWindows) { 'linux' } else { 'windows' }
    $null = Set-TestFile -Path (Join-Path $script:Root 'Taskfile.yml') -Content (@'
version: '3'
vars:
  G: global
  LIST: [a, b, c]
  DYN:
    sh: echo "dyn-{{.G}}"
  COMPOSED: '{{.G}}/{{.DYN}}'
includes:
  lib: ./lib
tasks:
  default:
    desc: The default task
    cmds:
      - echo "default {{.G}} {{.COMPOSED}}"
      - echo "{{.LIST | join "+"}} {{len .LIST}} {{.MISSING}}|{{.G | upper}}|{{OS}}"
  deps:
    deps: [leaf]
    cmds:
      - echo "after dep"
  leaf:
    cmds:
      - echo "leaf"
  calls:
    cmds:
      - echo "first"
      - task: show
        vars: {MSG: called}
      - task: show
      - echo "last"
  show:
    vars:
      MSG: '{{.MSG | default "nothing"}}'
    cmds:
      - echo "show {{.MSG}}"
  loops:
    vars:
      WORDS: one two
      CSV: p,q
    cmds:
      - for: [x, y]
        cmd: echo "item {{.ITEM}}"
      - for: {var: WORDS}
        cmd: echo "word {{.ITEM}}"
      - for: {var: CSV, split: ',', as: L}
        cmd: echo "csv {{.L}}"
      - for: {var: LIST}
        cmd: echo "list {{.ITEM}}"
      - for:
          matrix:
            OS: [win, lin]
            ARCH: [x64, arm]
        cmd: echo "{{.ITEM.OS}}-{{.ITEM.ARCH}}"
      - for: [1, 2]
        task: show
        vars: {MSG: 'loop-{{.ITEM}}'}
  defer-fail:
    cmds:
      - defer: echo "deferred one {{.EXIT_CODE}}"
      - defer: echo "deferred two"
      - echo "body"
      - exit 7
      - echo "unreachable"
  defer-ok:
    cmds:
      - defer: echo "cleanup"
      - echo "body"
  ignore-cmd:
    cmds:
      - cmd: exit 4
        ignore_error: true
      - echo "continued"
  ignore-task:
    ignore_error: true
    cmds:
      - exit 5
      - echo "continued"
  fail:
    cmds:
      - echo "before"
      - exit 3
  parent-cmd:
    cmds:
      - task: fail
  parent-dep:
    deps: [fail]
    cmds:
      - echo "unreachable"
  up-to-date:
    status:
      - exit 0
    cmds:
      - echo "unreachable"
  not-up-to-date:
    status:
      - exit 1
    cmds:
      - echo "ran"
  pre-fail:
    preconditions:
      - sh: exit 1
        msg: 'custom message for {{.TASK}}'
    cmds:
      - echo "unreachable"
  pre-default:
    preconditions:
      - exit 1
    cmds:
      - echo "unreachable"
  needs:
    requires:
      vars:
        - NAME
        - name: MODE
          enum: [dev, prod]
    cmds:
      - echo "{{.NAME}} {{.MODE}}"
  labelled:
    label: 'label-{{.G}}'
    cmds:
      - echo "labelled"
  aliased:
    aliases: [al]
    cmds:
      - echo "alias {{.ALIAS}} task {{.TASK}}"
  'wild:*:*':
    cmds:
      - echo "{{index .MATCH 0}} and {{index .MATCH 1}}"
  once:
    run: once
    cmds:
      - echo "once"
  twice:
    cmds:
      - task: once
      - task: once
      - echo "done"
  quiet:
    silent: true
    cmds:
      - echo "quiet"
  cmd-quiet:
    cmds:
      - cmd: echo "quiet cmd"
        silent: true
      - echo "loud cmd"
  here:
    platforms: [__OS__]
    cmds:
      - echo "here"
  elsewhere:
    platforms: [__OTHER__]
    cmds:
      - echo "unreachable"
  args:
    cmds:
      - echo "{{.CLI_ARGS}}"
  internal-task:
    internal: true
    cmds:
      - echo "internal"
  multi:
    cmds:
      - |
        echo "line one"
        echo "line two"
  summary:
    desc: Has a description
    summary: |
      Multi-line
      summary text.
    aliases: [sum]
    deps: [leaf]
    vars:
      LOCAL: 'local-{{.G}}'
    cmds:
      - echo "{{.LOCAL}}"
      - task: leaf
'@).Replace('__OS__', $os).Replace('__OTHER__', $other)
    $null = Set-TestFile -Path (Join-Path $script:Root 'lib' 'Taskfile.yml') -Content @'
version: '3'
vars:
  LIBVAR: from-lib
tasks:
  default:
    cmds:
      - echo "lib default"
  build:
    desc: Build the library
    deps: [prepare]
    cmds:
      - task: :leaf
      - echo "lib build {{.LIBVAR}} {{.TASK}}"
  prepare:
    cmds:
      - echo "lib prepare"
'@

    function Invoke-GoTask {
        param([string[]]$Arguments)
        $errorFile = Join-Path $TestDrive 'go-task-stderr.txt'
        $env:NO_COLOR = '1'
        try { $stdout = @(& task --dir $script:Root @Arguments 2> $errorFile) }
        finally { Remove-Item Env:NO_COLOR }
        $exitCode = $LASTEXITCODE
        $stderr = @(Get-Content $errorFile -ErrorAction Ignore)
        [pscustomobject]@{ Output = @($stdout | ForEach-Object { "$_" }); Messages = $stderr; ExitCode = $exitCode }
    }

    function Compare-WithGoTask {
        # -ListIsOutput: go-task prints the task list of an unknown task to stdout, Invoke-Task
        # writes it as messages (it must not end up in the pipeline).
        param([string[]]$Name, [string[]]$GoArguments = @(), [hashtable]$With = @{}, [switch]$ListIsOutput)
        $expected = Invoke-GoTask -Arguments ($GoArguments + $Name)
        $actual = Invoke-TestTask $script:Root $Name -With $With

        $actualOutput = @($actual.Records | Where-Object { $_ -is [string] })
        $actualMessages = @($actual.Records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" -split "`n" })
        $expectedMessages = $expected.Messages
        if ($ListIsOutput) {
            $expectedMessages = @($expected.Output) + @($expected.Messages)
            $expected.Output = @()
        }
        if ($null -ne $actual.Error) {
            # go-task prints the error as the last message; Invoke-Task throws it.
            $errorLines = @($actual.Error.Exception.Message.TrimEnd("`n") -split "`n")
            $actualMessages = @($actualMessages) + $errorLines
            $expectedMessages = @($expectedMessages | Where-Object { $_ -ne '' })
            $actualMessages = @($actualMessages | Where-Object { $_ -ne '' })
        }
        $actualOutput | Should -Be $expected.Output -Because 'the command output must match go-task'
        $actualMessages | Should -Be $expectedMessages -Because 'the engine messages must match go-task'
        $actual.ExitCode | Should -Be $expected.ExitCode -Because 'the exit code must match go-task'
    }
}

Describe 'Compatibility with go-task' -Skip:$script:SkipCompat {
    It 'runs <Name> like go-task' -ForEach @(
        @{ Name = @() }
        @{ Name = 'deps' }
        @{ Name = 'calls' }
        @{ Name = 'loops' }
        @{ Name = 'defer-fail' }
        @{ Name = 'defer-ok' }
        @{ Name = 'ignore-cmd' }
        @{ Name = 'ignore-task' }
        @{ Name = 'fail' }
        @{ Name = 'parent-cmd' }
        @{ Name = 'parent-dep' }
        @{ Name = 'up-to-date' }
        @{ Name = 'not-up-to-date' }
        @{ Name = 'pre-fail' }
        @{ Name = 'pre-default' }
        @{ Name = 'needs' }
        @{ Name = 'labelled' }
        @{ Name = 'aliased' }
        @{ Name = 'al' }
        @{ Name = 'wild:left:right' }
        @{ Name = 'twice' }
        @{ Name = 'quiet' }
        @{ Name = 'cmd-quiet' }
        @{ Name = 'here' }
        @{ Name = 'elsewhere' }
        @{ Name = 'internal-task' }
        @{ Name = 'multi' }
        @{ Name = 'lib:build' }
        @{ Name = 'lib' }
        @{ Name = 'leaf', 'quiet', 'labelled' }
    ) {
        Compare-WithGoTask -Name $Name
    }

    It 'lists the available tasks when the task is unknown, like go-task' {
        Compare-WithGoTask -Name 'zzz-no-such-task-zzz' -ListIsOutput
    }

    It 'handles variables given on the command line' {
        $expected = Invoke-GoTask -Arguments 'needs', 'NAME=n', 'MODE=prod'
        $actual = Invoke-TestTask $script:Root needs -With @{ Variable = @{ NAME = 'n'; MODE = 'prod' } }
        $actual.Output | Should -Be $expected.Output
        $actual.ExitCode | Should -Be $expected.ExitCode
    }

    It 'rejects values that are not allowed like go-task' {
        $expected = Invoke-GoTask -Arguments 'needs', 'NAME=n', 'MODE=nope'
        $actual = Invoke-TestTask $script:Root needs -With @{ Variable = @{ NAME = 'n'; MODE = 'nope' } }
        $actual.Error.Exception.Message.TrimEnd() | Should -Be (($expected.Messages -join "`n").TrimEnd())
        $actual.ExitCode | Should -Be $expected.ExitCode
    }

    It 'passes CLI arguments like go-task' {
        $expected = Invoke-GoTask -Arguments 'args', '--', 'plain', 'two words', '--flag'
        $actual = Invoke-TestTask $script:Root args -With @{ ArgumentList = @('plain', 'two words', '--flag') }
        ($actual.Records | Where-Object { $_ -is [System.Management.Automation.InformationRecord] } | ForEach-Object { "$_" }) | Should -Be $expected.Messages
    }

    It 'honours <Flag> like go-task' -ForEach @(
        @{ Flag = '--silent'; With = @{ Silent = $true }; Name = 'calls' }
        @{ Flag = '--dry'; With = @{ WhatIf = $true }; Name = 'defer-fail' }
        @{ Flag = '--dry'; With = @{ WhatIf = $true }; Name = 'loops' }
        @{ Flag = '--force'; With = @{ Force = $true }; Name = 'up-to-date' }
        @{ Flag = '--exit-code'; With = @{ ExitCode = $true }; Name = 'parent-cmd' }
        @{ Flag = '--exit-code'; With = @{ ExitCode = $true }; Name = 'pre-fail' }
    ) {
        Compare-WithGoTask -Name $Name -GoArguments $Flag -With $With
    }

    It 'prints the same summary as task --summary for <_>' -ForEach @('summary', 'loops', 'needs', 'lib:build') {
        $expected = Invoke-GoTask -Arguments '--summary', $_
        Get-TaskSummary -Directory $script:Root -Name $_ | Should -Be $expected.Output
    }

    It 'lists the same tasks as task --list-all --json' {
        $expected = ((Invoke-GoTask -Arguments '--list-all', '--json', '--no-status').Output -join "`n" | ConvertFrom-Json).tasks
        $actual = @(Get-Task -Directory $script:Root -All)
        $actual.Name | Should -Be $expected.task
        $actual.Description | Should -Be $expected.desc
        ($actual | ForEach-Object { $_.Aliases -join ',' }) | Should -Be ($expected | ForEach-Object { $_.aliases -join ',' })
        $actual.Location.Line | Should -Be $expected.location.line
        $actual.Location.Column | Should -Be $expected.location.column
        ($actual.Location.Taskfile | ForEach-Object { Split-Path -Leaf (Split-Path -Parent $_) }) | Should -Be ($expected.location.taskfile | ForEach-Object { Split-Path -Leaf (Split-Path -Parent $_) })
    }

    It 'lists the same tasks as task --list' {
        $expected = ((Invoke-GoTask -Arguments '--list', '--json', '--no-status').Output -join "`n" | ConvertFrom-Json).tasks
        (Get-Task -Directory $script:Root).Name | Should -Be $expected.task
    }

    It 'reports the same status as task --status for <_>' -ForEach @('up-to-date', 'not-up-to-date', 'leaf') {
        $expected = Invoke-GoTask -Arguments '--status', $_
        Test-Task -Directory $script:Root -Name $_ | Should -Be ($expected.ExitCode -eq 0)
    }
}
