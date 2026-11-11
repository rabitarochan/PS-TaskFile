BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"
}

Describe 'Invoke-Task: dependencies and task calls' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  build:
    deps: [prepare]
    cmds:
      - Write-Output build
  prepare:
    cmds:
      - Write-Output prepare
  dep-vars:
    silent: true
    deps:
      - task: echo
        vars: {MSG: from-dep}
    cmds:
      - Write-Output done
  dep-silent:
    deps:
      - task: prepare
        silent: true
    cmds:
      - Write-Output main
  echo:
    cmds:
      - Write-Output '{{.MSG}}'
  parallel-deps:
    silent: true
    deps: [wait-a, wait-b]
    cmds:
      - Write-Output both-finished
  wait-a:
    silent: true
    cmds:
      - |
        Set-Content -Path a.flag -Value a
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path b.flag)) {
            if ([datetime]::UtcNow -gt $deadline) { throw 'wait-b never started' }
            Start-Sleep -Milliseconds 20
        }
  wait-b:
    silent: true
    cmds:
      - |
        Set-Content -Path b.flag -Value b
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path a.flag)) {
            if ([datetime]::UtcNow -gt $deadline) { throw 'wait-a never started' }
            Start-Sleep -Milliseconds 20
        }
  calls:
    silent: true
    cmds:
      - Write-Output first
      - task: echo
        vars: {MSG: called}
      - Write-Output last
  child-fail:
    cmds:
      - exit 3
  parent-cmd:
    cmds:
      - Write-Output before
      - task: child-fail
      - Write-Output after
  parent-dep:
    deps: [child-fail]
    cmds:
      - Write-Output parent
  dep-missing:
    deps: [does-not-exist]
    cmds:
      - Write-Output unreachable
  cycle-a:
    cmds:
      - task: cycle-b
  cycle-b:
    cmds:
      - task: cycle-a
  failing-deps:
    deps: [child-fail, slow-ok]
    cmds:
      - Write-Output unreachable
  slow-ok:
    silent: true
    cmds:
      - Start-Sleep -Milliseconds 300
      - Set-Content -Path slow.done -Value done
'@
    }

    It 'runs dependencies before the commands' {
        (Invoke-TestTask $script:Dir build).Lines | Should -Be @('task: [prepare] Write-Output prepare', 'prepare', 'task: [build] Write-Output build', 'build')
    }

    It 'passes variables to dependencies' {
        (Invoke-TestTask $script:Dir dep-vars).Lines | Should -Be @('task: [echo] Write-Output ''from-dep''', 'from-dep', 'done')
    }

    It 'silences a dependency called with silent: true' {
        (Invoke-TestTask $script:Dir dep-silent).Lines | Should -Be @('prepare', 'task: [dep-silent] Write-Output main', 'main')
    }

    It 'runs dependencies in parallel' {
        Remove-Item (Join-Path $script:Dir '*.flag') -ErrorAction Ignore
        $result = Invoke-TestTask $script:Dir parallel-deps
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('both-finished')
    }

    It 'calls other tasks in sequence' {
        (Invoke-TestTask $script:Dir calls).Lines | Should -Be @('first', 'task: [echo] Write-Output ''called''', 'called', 'last')
    }

    It 'reports the chain of failing tasks' {
        $result = Invoke-TestTask $script:Dir parent-cmd
        $result.Lines | Should -Contain 'before'
        $result.Lines | Should -Not -Contain 'after'
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "parent-cmd": task: Failed to run task "child-fail": exit status 3'
        $result.ExitCode | Should -Be 201
        (Invoke-TestTask $script:Dir parent-cmd -With @{ ExitCode = $true }).ExitCode | Should -Be 3
    }

    It 'does not run a task whose dependency failed' {
        $result = Invoke-TestTask $script:Dir parent-dep
        $result.Lines | Should -Not -Contain 'parent'
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "parent-dep": task: Failed to run task "child-fail": exit status 3'
    }

    It 'fails when a dependency does not exist' {
        $result = Invoke-TestTask $script:Dir dep-missing
        $result.Error.Exception.Message | Should -BeLike 'task: Failed to run task "dep-missing": task: Task "does-not-exist" does not exist*'
    }

    It 'detects runaway recursion' {
        $result = Invoke-TestTask $script:Dir cycle-a -With @{ Silent = $true }
        $result.Error.Exception.Message | Should -BeLike 'task: Maximum task call exceeded*probably an cyclic dep or infinite loop'
        $result.ExitCode | Should -Be 204
    }

    It 'lets the other dependencies finish when one fails' {
        Remove-Item (Join-Path $script:Dir 'slow.done') -ErrorAction Ignore
        $result = Invoke-TestTask $script:Dir failing-deps
        $result.Error.Exception.Message | Should -BeLike '*"child-fail": exit status 3'
        Test-Path (Join-Path $script:Dir 'slow.done') | Should -BeTrue
    }

    It 'stops the other dependencies with -FailFast' {
        Remove-Item (Join-Path $script:Dir 'slow.done') -ErrorAction Ignore
        $result = Invoke-TestTask $script:Dir failing-deps -With @{ FailFast = $true }
        $result.Error.Exception.Message | Should -BeLike '*"child-fail": exit status 3'
        Test-Path (Join-Path $script:Dir 'slow.done') | Should -BeFalse
    }
}

Describe 'Invoke-Task: error handling inside tasks' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  ignore-cmd:
    silent: true
    cmds:
      - cmd: exit 4
        ignore_error: true
      - cmd: throw 'ignored'
        ignore_error: true
      - Write-Output continued
  ignore-task:
    silent: true
    ignore_error: true
    cmds:
      - exit 5
      - Write-Output continued
  ignore-call:
    silent: true
    cmds:
      - task: boom
        ignore_error: true
      - Write-Output continued
  boom:
    silent: true
    cmds:
      - exit 9
  defer:
    silent: true
    cmds:
      - defer: Write-Output 'deferred 1 code={{.EXIT_CODE}}'
      - defer: Write-Output 'deferred 2'
      - Write-Output body
      - exit 7
      - Write-Output unreachable
  defer-ok:
    silent: true
    cmds:
      - defer: Write-Output 'cleanup [{{.EXIT_CODE}}]'
      - defer:
          task: say
          vars: {MSG: deferred-task}
      - Write-Output body
  defer-failing:
    silent: true
    cmds:
      - defer: exit 8
      - Write-Output body
  defer-scope:
    silent: true
    cmds:
      - defer: Write-Output "cleanup sees $resource"
      - $resource = 'handle-1'
  say:
    silent: true
    cmds:
      - Write-Output '{{.MSG}}'
  errexit:
    silent: true
    set: [errexit]
    cmds:
      - |
        pwsh -NoProfile -Command "exit 6"
        Write-Output unreachable
  no-errexit:
    silent: true
    cmds:
      - |
        pwsh -NoProfile -Command "exit 6"
        Write-Output reached
        $global:LASTEXITCODE = 0
'@
    }

    It 'ignores failures of commands marked with ignore_error' {
        $result = Invoke-TestTask $script:Dir ignore-cmd
        $result.Error | Should -BeNullOrEmpty
        $result.Lines[-1] | Should -Be 'continued'
    }

    It 'ignores failures of all commands of a task marked with ignore_error' {
        $result = Invoke-TestTask $script:Dir ignore-task
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('continued')
    }

    It 'ignores failures of a called task marked with ignore_error' {
        $result = Invoke-TestTask $script:Dir ignore-call
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('continued')
    }

    It 'runs deferred commands in reverse order even after a failure' {
        $result = Invoke-TestTask $script:Dir defer
        $result.Lines | Should -Be @('body', 'deferred 2', 'deferred 1 code=7')
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "defer": exit status 7'
    }

    It 'runs deferred commands and task calls after success' {
        $result = Invoke-TestTask $script:Dir defer-ok
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('body', 'deferred-task', 'cleanup []')
    }

    It 'ignores failures of deferred commands' {
        $result = Invoke-TestTask $script:Dir defer-failing
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('body')
    }

    It 'runs deferred commands in the scope of the task' {
        (Invoke-TestTask $script:Dir defer-scope).Lines | Should -Be @('cleanup sees handle-1')
    }

    It 'stops at the first failing native command with set: [errexit]' {
        $result = Invoke-TestTask $script:Dir errexit
        $result.Lines | Should -Not -Contain 'unreachable'
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "errexit": exit status 6'
        (Invoke-TestTask $script:Dir errexit -With @{ ExitCode = $true }).ExitCode | Should -Be 6
    }

    It 'continues after a failing native command by default' {
        $result = Invoke-TestTask $script:Dir no-errexit
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('reached')
    }
}

Describe 'Invoke-Task: loops' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
vars:
  WORDS: one two
  CSV: p,q
  ITEMS: [x, y]
  TABLE:
    map: {k1: v1, k2: v2}
  DYNAMIC_LIST:
    sh: "'d1'; 'd2'"
tasks:
  list:
    silent: true
    cmds:
      - for: [a, b]
        cmd: Write-Output 'item {{.ITEM}}'
  variable:
    silent: true
    cmds:
      - for: {var: WORDS}
        cmd: Write-Output 'word {{.ITEM}}'
      - for: {var: CSV, split: ',', as: LETTER}
        cmd: Write-Output 'csv {{.LETTER}}'
      - for: {var: ITEMS}
        cmd: Write-Output 'list {{.ITEM}}'
      - for: {var: TABLE}
        cmd: Write-Output 'map {{.KEY}}={{.ITEM}}'
      - for: {var: DYNAMIC_LIST}
        cmd: Write-Output 'dyn {{.ITEM}}'
      - for: {var: UNDEFINED}
        cmd: Write-Output 'never'
  matrix:
    silent: true
    cmds:
      - for:
          matrix:
            OS: [win, lin]
            ARCH: [x64, arm]
        cmd: Write-Output '{{.ITEM.OS}}-{{.ITEM.ARCH}}'
  matrix-ref:
    silent: true
    cmds:
      - for:
          matrix:
            LETTER:
              ref: .ITEMS
            N: [1, 2]
        cmd: Write-Output '{{.ITEM.LETTER}}{{.ITEM.N}}'
  sources:
    silent: true
    sources: ['data/*.txt']
    cmds:
      - for: sources
        cmd: Write-Output 'source {{.ITEM | toSlash}}'
  task-loop:
    silent: true
    cmds:
      - for: [1, 2]
        task: show
        vars: {VALUE: 'n{{.ITEM}}'}
  dep-loop:
    silent: true
    deps:
      - for: [a]
        task: show
        vars: {VALUE: 'dep-{{.ITEM}}'}
    cmds:
      - Write-Output done
  show:
    silent: true
    cmds:
      - Write-Output 'show {{.VALUE}}'
'@
        $null = Set-TestFile -Path (Join-Path $script:Dir 'data' 'b.txt') -Content 'b'
        $null = Set-TestFile -Path (Join-Path $script:Dir 'data' 'a.txt') -Content 'a'
    }

    It 'loops over a list' {
        (Invoke-TestTask $script:Dir list).Lines | Should -Be @('item a', 'item b')
    }

    It 'loops over variables (split strings, lists, maps and dynamic values)' {
        (Invoke-TestTask $script:Dir variable).Lines | Should -Be @(
            'word one', 'word two', 'csv p', 'csv q', 'list x', 'list y', 'map k1=v1', 'map k2=v2', 'dyn d1', 'dyn d2'
        )
    }

    It 'loops over a matrix' {
        (Invoke-TestTask $script:Dir matrix).Lines | Should -Be @('win-x64', 'win-arm', 'lin-x64', 'lin-arm')
        (Invoke-TestTask $script:Dir matrix-ref).Lines | Should -Be @('x1', 'x2', 'y1', 'y2')
    }

    It 'loops over the sources of the task' {
        (Invoke-TestTask $script:Dir sources -With @{ Force = $true }).Lines | Should -Be @('source data/a.txt', 'source data/b.txt')
    }

    It 'loops over task calls and dependencies' {
        (Invoke-TestTask $script:Dir task-loop).Lines | Should -Be @('show n1', 'show n2')
        (Invoke-TestTask $script:Dir dep-loop).Lines | Should -Be @('show dep-a', 'done')
    }
}

Describe 'Invoke-Task: working directory' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
vars:
  SUB: nested
tasks:
  root:
    silent: true
    cmds:
      - (Get-Location).ProviderPath
  relative:
    silent: true
    dir: sub/{{.SUB}}
    cmds:
      - (Get-Location).ProviderPath
      - Set-Location ..
      - (Get-Location).ProviderPath
  created:
    silent: true
    dir: not-yet/there
    cmds:
      - Test-Path .
  absolute:
    silent: true
    dir: '{{.USER_WORKING_DIR}}'
    cmds:
      - (Get-Location).ProviderPath
'@
    }

    It 'runs in the directory of the Taskfile by default' {
        (Invoke-TestTask $script:Dir root).Lines | Should -Be @($script:Dir)
    }

    It 'runs in dir and resets the location before every command' {
        $expected = Join-Path $script:Dir 'sub' 'nested'
        (Invoke-TestTask $script:Dir relative).Lines | Should -Be @($expected, $expected)
    }

    It 'creates a missing dir' {
        (Invoke-TestTask $script:Dir created).Output | Should -Be @($true)
        Test-Path (Join-Path $script:Dir 'not-yet' 'there') | Should -BeTrue
    }

    It 'accepts an absolute dir and leaves the location of the caller alone' {
        $here = (Get-Location).ProviderPath
        (Invoke-TestTask $script:Dir absolute).Lines | Should -Be @($here)
        (Get-Location).ProviderPath | Should -Be $here
    }
}
