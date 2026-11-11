BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"
}

Describe 'Invoke-Task: variables' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
vars:
  GREETING: hello
  COMPOSED: '{{.GREETING}}, world'
  NUMBER: 42
  FLAG: true
  LIST: [a, b, c]
  ONE: [solo]
  NONE: []
  MAP:
    map: {k1: v1, k2: v2}
  DYNAMIC:
    sh: Write-Output ('dyn' + 'amic')
  DYN_MULTI:
    sh: 1..3
  DYN_NATIVE:
    sh: pwsh -NoProfile -Command "'from native'"
  DYN_TEMPLATE:
    sh: Write-Output "{{.GREETING}}-dyn"
  DYN_FROM_ENV:
    sh: $env:GREETING
  REF:
    ref: .LIST
  REF_INDEX:
    ref: index .LIST 1
tasks:
  static:
    silent: true
    cmds:
      - Write-Output '{{.GREETING}}|{{.COMPOSED}}|{{.NUMBER}}|{{.FLAG}}|{{.LIST}}|{{.MAP.k2}}|[{{.MISSING}}]|[{{.greeting}}]'
  dynamic:
    silent: true
    cmds:
      - Write-Output '{{.DYNAMIC}}|{{.DYN_TEMPLATE}}|{{.DYN_MULTI | splitLines | join ","}}|{{.DYN_NATIVE}}|{{.DYN_FROM_ENV}}'
  ref:
    silent: true
    cmds:
      - Write-Output '{{range .REF}}{{.}}{{end}}|{{.REF_INDEX}}|{{len .REF}}'
  small-lists:
    silent: true
    cmds:
      - Write-Output '{{len .ONE}}:{{index .ONE 0}}|{{len .NONE}}|{{kindOf .ONE}}|{{kindOf .NONE}}'
      - for: {var: ONE}
        cmd: Write-Output 'item {{.ITEM}}'
  task-vars:
    silent: true
    vars:
      GREETING: overridden
      LOCAL: 'local-{{.NUMBER}}'
      LOCAL_DYN:
        sh: Write-Output "{{.LOCAL}}!"
    cmds:
      - Write-Output '{{.GREETING}}|{{.LOCAL}}|{{.LOCAL_DYN}}|{{.COMPOSED}}'
  caller:
    silent: true
    cmds:
      - task: greet
        vars: {WHO: caller}
      - task: greet
      - task: fixed
        vars: {WHO: ignored}
  greet:
    silent: true
    vars:
      WHO: '{{.WHO | default "nobody"}}'
    cmds:
      - Write-Output 'hi {{.WHO}}'
  fixed:
    silent: true
    vars:
      WHO: always
    cmds:
      - Write-Output 'fixed {{.WHO}}'
  cli:
    silent: true
    cmds:
      - Write-Output '{{.GREETING}}|{{.EXTRA}}|{{range .ITEMS}}<{{.}}>{{end}}|{{.COUNT | add 1}}'
  args:
    silent: true
    cmds:
      - Write-Output "{{.CLI_ARGS}}|{{len .CLI_ARGS_LIST}}|{{index .CLI_ARGS_LIST 1}}"
      - Write-Output {{.CLI_ARGS}}
  special:
    aliases: [sp]
    silent: true
    dir: sub
    cmds:
      - Write-Output '{{.TASK}}|{{.ALIAS}}|{{.TASK_EXE}}'
      - Write-Output '{{.ROOT_DIR}}|{{.TASKFILE_DIR}}|{{.TASK_DIR}}|{{.USER_WORKING_DIR}}'
      - Write-Output '{{.ROOT_TASKFILE}}|{{.TASKFILE}}'
  os-env:
    silent: true
    cmds:
      - Write-Output '{{.PSTF_OS_VAR}}'
  functions:
    silent: true
    cmds:
      - Write-Output '{{OS}}|{{.LIST | join ","}}|{{.GREETING | upper}}|{{if .FLAG}}on{{else}}off{{end}}'
      - Write-Output {{shellQuote "it's quoted"}}
  bad-dynamic:
    vars:
      BROKEN:
        sh: throw 'cannot compute'
    cmds:
      - Write-Output unreachable
  bad-template:
    cmds:
      - Write-Output '{{.GREETING | nofunc}}'
  dir-vars:
    silent: true
    dir: sub
    vars:
      WHERE:
        sh: Split-Path -Leaf (Get-Location)
    cmds:
      - Write-Output '{{.WHERE}}'
  cached:
    silent: true
    vars:
      COUNTED:
        sh: Add-Content -Path counter.txt -Value x; 'counted'
    cmds:
      - task: cached-inner
      - Write-Output '{{.COUNTED}}'
  cached-inner:
    silent: true
    vars:
      COUNTED:
        sh: Add-Content -Path counter.txt -Value x; 'counted'
    cmds:
      - Write-Output '{{.COUNTED}}'
'@
        $null = New-Item -ItemType Directory -Path (Join-Path $script:Dir 'sub')
    }

    It 'expands static variables of every type' {
        (Invoke-TestTask $script:Dir static).Lines | Should -Be @('hello|hello, world|42|true|[a b c]|v2|[]|[]')
    }

    It 'sets dynamic variables from the output of PowerShell commands' {
        (Invoke-TestTask $script:Dir dynamic).Lines | Should -Be @('dynamic|hello-dyn|1,2,3|from native|hello')
    }

    It 'keeps the type of referenced variables' {
        (Invoke-TestTask $script:Dir ref).Lines | Should -Be @('abc|b|3')
    }

    It 'keeps one-element and empty lists as lists' {
        (Invoke-TestTask $script:Dir small-lists).Lines | Should -Be @('1:solo|0|slice|slice', 'item solo')
    }

    It 'lets task variables override global ones' {
        (Invoke-TestTask $script:Dir task-vars).Lines | Should -Be @('overridden|local-42|local-42!|hello, world')
    }

    It 'passes variables to called tasks' {
        (Invoke-TestTask $script:Dir caller).Lines | Should -Be @('hi caller', 'hi nobody', 'fixed always')
    }

    It 'accepts variables from -Variable, including typed values' {
        $result = Invoke-TestTask $script:Dir cli -With @{ Variable = @{ GREETING = 'from-cli'; EXTRA = 'extra'; ITEMS = @('x', 'y'); COUNT = 41 } }
        $result.Lines | Should -Be @('from-cli|extra|<x><y>|42')
    }

    It 'exposes the remaining arguments as CLI_ARGS and CLI_ARGS_LIST' {
        $result = Invoke-TestTask $script:Dir args -With @{ ArgumentList = @('one', 'two words', '-Flag') }
        $result.Lines | Should -Be @("one 'two words' -Flag|3|two words", 'one', 'two words', '-Flag')
    }

    It 'binds everything after -- to the argument list' {
        $lines = @(Invoke-Task args -Directory $script:Dir -PassThru -- first second 6>&1 | ForEach-Object { "$_" })
        $lines[0] | Should -Be 'first second|2|second'
    }

    It 'provides the special variables' {
        $root = $script:Dir
        $here = (Get-Location).ProviderPath
        $result = Invoke-TestTask $root sp
        $result.Lines | Should -Be @(
            'special|sp|Invoke-Task'
            "$root|$root|$(Join-Path $root 'sub')|$here"
            "$(Join-Path $root 'Taskfile.yml')|$(Join-Path $root 'Taskfile.yml')"
        )
    }

    It 'exposes OS environment variables as template variables' {
        $env:PSTF_OS_VAR = 'from-os'
        try { (Invoke-TestTask $script:Dir os-env).Lines | Should -Be @('from-os') }
        finally { Remove-Item Env:PSTF_OS_VAR }
    }

    It 'supports template functions and PowerShell quoting' {
        $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
        (Invoke-TestTask $script:Dir functions).Lines | Should -Be @("$os|a,b,c|HELLO|on", "it's quoted")
    }

    It 'fails when a dynamic variable cannot be computed' {
        $result = Invoke-TestTask $script:Dir bad-dynamic
        $result.Lines | Should -Not -Contain 'unreachable'
        $result.Error.Exception.Message | Should -Be "task: Command `"throw 'cannot compute'`" failed: cannot compute"
        $result.ExitCode | Should -Be 1
    }

    It 'fails on template errors' {
        $result = Invoke-TestTask $script:Dir bad-template
        $result.Error.Exception.Message | Should -BeLike 'template: *function "nofunc" not defined*'
    }

    It 'runs dynamic variables of a task in the task directory' {
        (Invoke-TestTask $script:Dir dir-vars).Lines | Should -Be @('sub')
    }

    It 'evaluates an identical dynamic variable only once per run' {
        $counter = Join-Path $script:Dir 'counter.txt'
        Remove-Item $counter -ErrorAction Ignore
        (Invoke-TestTask $script:Dir cached).Lines | Should -Be @('counted', 'counted')
        @(Get-Content $counter).Count | Should -Be 1
    }
}

Describe 'Invoke-Task: environment' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
dotenv: ['.env', '{{.ENV_NAME}}.env']
vars:
  ENV_NAME: extra
env:
  GLOBAL_ENV: global
  SHARED_ENV: from-taskfile
  TEMPLATED_ENV: 'env-{{.ENV_NAME}}'
  DYNAMIC_ENV:
    sh: Write-Output computed
  NUMBER_ENV: 7
tasks:
  show:
    silent: true
    env:
      TASK_ENV: task
      SHARED_ENV: from-task
    cmds:
      - Write-Output "$env:GLOBAL_ENV|$env:TASK_ENV|$env:SHARED_ENV|$env:TEMPLATED_ENV|$env:DYNAMIC_ENV|$env:NUMBER_ENV"
  native:
    silent: true
    env:
      TASK_ENV: for-child
    cmds:
      - pwsh -NoProfile -Command "`$env:TASK_ENV + '/' + `$env:GLOBAL_ENV"
  other:
    silent: true
    cmds:
      - Write-Output "[$env:TASK_ENV]"
  dotenv:
    silent: true
    dotenv: ['task.env']
    env:
      FROM_TASK_DOTENV_AND_ENV: env-wins
    cmds:
      - Write-Output "$env:FROM_DOTENV|$env:FROM_EXTRA|$env:SHARED_ENV|$env:FROM_TASK_DOTENV|$env:FROM_TASK_DOTENV_AND_ENV|$env:FIRST_WINS"
  mutate:
    silent: true
    cmds:
      - $env:PSTF_MUTATED = 'changed'
      - Write-Output "inside=$env:PSTF_MUTATED"
  precedence:
    silent: true
    cmds:
      - Write-Output "$env:GLOBAL_ENV"
'@
        $null = Set-TestFile -Path (Join-Path $script:Dir '.env') -Content "FROM_DOTENV=dotenv`nSHARED_ENV=from-dotenv`nFIRST_WINS=first"
        $null = Set-TestFile -Path (Join-Path $script:Dir 'extra.env') -Content "FROM_EXTRA=extra`nFIRST_WINS=second"
        $null = Set-TestFile -Path (Join-Path $script:Dir 'task.env') -Content "FROM_TASK_DOTENV=task-dotenv`nFROM_TASK_DOTENV_AND_ENV=dotenv-loses"
    }

    It 'sets Taskfile and task environment variables for commands' {
        (Invoke-TestTask $script:Dir show).Lines | Should -Be @('global|task|from-task|env-extra|computed|7')
    }

    It 'passes the environment to native commands' {
        (Invoke-TestTask $script:Dir native).Lines | Should -Be @('for-child/global')
    }

    It 'does not carry the environment of one task into another' {
        (Invoke-TestTask $script:Dir show, other).Lines[-1] | Should -Be '[]'
    }

    It 'loads dotenv files with the documented precedence' {
        (Invoke-TestTask $script:Dir dotenv).Lines | Should -Be @('dotenv|extra|from-taskfile|task-dotenv|env-wins|first')
    }

    It 'restores the environment of the caller after the run' {
        $before = [Environment]::GetEnvironmentVariables()
        (Invoke-TestTask $script:Dir show, mutate).Lines[-1] | Should -Be 'inside=changed'
        $env:GLOBAL_ENV | Should -BeNullOrEmpty
        $env:TASK_ENV | Should -BeNullOrEmpty
        $env:PSTF_MUTATED | Should -BeNullOrEmpty
        [Environment]::GetEnvironmentVariables().Count | Should -Be $before.Count
    }

    It 'lets the OS environment win over the Taskfile by default' {
        $env:GLOBAL_ENV = 'from-os'
        try { (Invoke-TestTask $script:Dir precedence).Lines | Should -Be @('from-os') }
        finally { Remove-Item Env:GLOBAL_ENV }
    }

    It 'lets the Taskfile win with TASK_X_ENV_PRECEDENCE=1' {
        $env:GLOBAL_ENV = 'from-os'
        $env:TASK_X_ENV_PRECEDENCE = '1'
        try {
            (Invoke-TestTask $script:Dir precedence).Lines | Should -Be @('global')
            $env:GLOBAL_ENV | Should -Be 'from-os'
        }
        finally { Remove-Item Env:GLOBAL_ENV, Env:TASK_X_ENV_PRECEDENCE }
    }
}

Describe 'Invoke-Task: required variables' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  needs:
    silent: true
    requires:
      vars:
        - NAME
        - name: MODE
          enum: [dev, prod]
    cmds:
      - Write-Output '{{.NAME}}/{{.MODE}}'
'@
    }

    It 'fails with code 206 when required variables are missing' {
        $result = Invoke-TestTask $script:Dir needs
        $result.Error.Exception.Message | Should -Be 'task: Task "needs" cancelled because it is missing required variables: NAME, MODE (allowed values: [dev prod])'
        $result.Error.FullyQualifiedErrorId | Should -Be 'TaskMissingRequiredVariables,Invoke-Task'
        $result.ExitCode | Should -Be 206
    }

    It 'fails with code 207 when a value is not allowed' {
        $result = Invoke-TestTask $script:Dir needs -With @{ Variable = @{ NAME = 'n'; MODE = 'test' } }
        $result.Error.Exception.Message | Should -BeLike "*MODE has an invalid value : 'test' (allowed values : ``[dev prod``])*"
        $result.ExitCode | Should -Be 207
    }

    It 'runs when the requirements are met' {
        (Invoke-TestTask $script:Dir needs -With @{ Variable = @{ NAME = 'n'; MODE = 'prod' } }).Lines | Should -Be @('n/prod')
    }
}
