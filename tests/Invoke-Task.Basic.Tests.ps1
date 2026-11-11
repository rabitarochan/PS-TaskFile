BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"
}

Describe 'Invoke-Task: basics' {
    It 'is exported by the module' {
        (Get-Command Invoke-Task).Module.Name | Should -Be 'PS-TaskFile'
    }

    It 'runs the default task and echoes each command' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  default:
    cmds:
      - Write-Output hello
      - Write-Output world
'@
        $result = Invoke-TestTask $dir
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('task: [default] Write-Output hello', 'hello', 'task: [default] Write-Output world', 'world')
        $result.ExitCode | Should -Be 0
    }

    It 'runs the named tasks in order' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  one: Write-Output 1
  two: Write-Output 2
'@
        (Invoke-TestTask $dir two, one).Output | Should -Be @(2, 1)
    }

    It 'emits real objects with -PassThru' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  objects:
    silent: true
    cmds:
      - "[pscustomobject]@{ Name = 'a'; Value = 1 }"
      - Get-Item .
      - ", @(1, 2)"
'@
        $result = Invoke-TestTask $dir objects
        $result.Output.Count | Should -Be 3
        $result.Output[0].Name | Should -Be 'a'
        $result.Output[0].Value | Should -Be 1
        $result.Output[1] | Should -BeOfType [System.IO.DirectoryInfo]
        $result.Output[2].Count | Should -Be 2
    }

    It 'runs commands as PowerShell: assignments, pipelines and multi-line scripts' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  default:
    silent: true
    cmds:
      - $x = 20; $y = $x + 22; "sum=$y"
      - 1..3 | ForEach-Object { $_ * 2 } | Measure-Object -Sum | ForEach-Object Sum
      - |
        $items = @('a', 'b')
        foreach ($item in $items) {
            "item=$item"
        }
'@
        (Invoke-TestTask $dir).Lines | Should -Be @('sum=42', '12', 'item=a', 'item=b')
    }

    It 'keeps variables and functions between the commands of one task' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  default:
    silent: true
    cmds:
      - $greeting = 'hi'
      - function Get-Target { 'there' }
      - '"$greeting $(Get-Target)"'
'@
        (Invoke-TestTask $dir).Lines | Should -Be @('hi there')
    }

    It 'does not leak variables into other tasks or into the caller' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  first:
    silent: true
    cmds:
      - $leak = 'leaked'
      - '"first=$leak"'
  second:
    silent: true
    cmds:
      - '"second=[$leak]"'
  nested:
    silent: true
    cmds:
      - $leak = 'outer'
      - task: second
      - '"nested=$leak"'
'@
        (Invoke-TestTask $dir first, second).Lines | Should -Be @('first=leaked', 'second=[]')
        (Invoke-TestTask $dir nested).Lines | Should -Be @('second=[]', 'nested=outer')
        Get-Variable leak -ErrorAction Ignore | Should -BeNullOrEmpty
    }

    It 'echoes multi-line commands as they are written' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  default:
    cmds:
      - |
        Write-Output a
        Write-Output b
'@
        (Invoke-TestTask $dir).Lines | Should -Be @("task: [default] Write-Output a`nWrite-Output b", 'a', 'b')
    }

    It 'shows warnings, verbose and host output of commands' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  default:
    silent: true
    cmds:
      - Write-Host from-host
      - Write-Warning careful
      - Write-Verbose detail -Verbose
'@
        (Invoke-TestTask $dir).Lines | Should -Be @('from-host', 'WARNING: careful', 'VERBOSE: detail')
    }

    It 'runs native commands' {
        $dir = New-TestTaskfile @'
version: '3'
tasks:
  default:
    silent: true
    cmds:
      - pwsh -NoProfile -Command "'native ' + (1 + 1)"
'@
        (Invoke-TestTask $dir).Lines | Should -Be @('native 2')
    }
}

Describe 'Invoke-Task: failures' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  exit:
    cmds:
      - Write-Output before
      - exit 3
      - Write-Output after
  throw:
    cmds:
      - throw 'boom'
      - Write-Output after
  write-error:
    cmds:
      - Write-Error 'soft failure'
      - Write-Output after
  cmdlet-error:
    cmds:
      - Get-Item ./does-not-exist
      - Write-Output after
  native:
    cmds:
      - pwsh -NoProfile -Command "exit 4"
      - Write-Output after
  native-handled:
    silent: true
    cmds:
      - |
        pwsh -NoProfile -Command "exit 4"
        if ($LASTEXITCODE -eq 4) { $global:LASTEXITCODE = 0; 'handled' }
  exit-zero:
    silent: true
    cmds:
      - "'one'; exit 0; 'unreachable'"
      - "'two'"
  secret:
    internal: true
    cmds: [Write-Output secret]
  hello:
    cmds: [Write-Output hello]
'@
    }

    It 'fails when a command calls exit with a non-zero code' {
        $result = Invoke-TestTask $script:Dir exit
        $result.Lines | Should -Be @('task: [exit] Write-Output before', 'before', 'task: [exit] exit 3')
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "exit": exit status 3'
        $result.Error.FullyQualifiedErrorId | Should -Be 'TaskRunFailed,Invoke-Task'
        $result.ExitCode | Should -Be 201
    }

    It 'passes the exit code of the command through with -ExitCode' {
        (Invoke-TestTask $script:Dir exit -With @{ ExitCode = $true }).ExitCode | Should -Be 3
    }

    It 'fails when a command throws' {
        $result = Invoke-TestTask $script:Dir throw
        $result.Lines | Should -Be @("task: [throw] throw 'boom'", 'ERROR: boom')
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "throw": boom'
        $result.ExitCode | Should -Be 201
    }

    It 'treats non-terminating errors as failures' {
        $result = Invoke-TestTask $script:Dir write-error
        $result.Lines | Should -Not -Contain 'after'
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "write-error": soft failure'

        $result = Invoke-TestTask $script:Dir cmdlet-error
        $result.Lines | Should -Not -Contain 'after'
        $result.Error.Exception.Message | Should -BeLike 'task: Failed to run task "cmdlet-error": *does-not-exist*'
    }

    It 'fails when a native command exits with a non-zero code' {
        $result = Invoke-TestTask $script:Dir native
        $result.Lines | Should -Not -Contain 'after'
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "native": exit status 4'
        (Invoke-TestTask $script:Dir native -With @{ ExitCode = $true }).ExitCode | Should -Be 4
    }

    It 'lets a command handle a native failure itself' {
        $result = Invoke-TestTask $script:Dir native-handled
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('handled')
    }

    It 'treats exit 0 as success and stops only that command' {
        $result = Invoke-TestTask $script:Dir exit-zero
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @('one', 'two')
    }

    It 'fails for an unknown task and suggests a similar name' {
        $result = Invoke-TestTask $script:Dir helo
        $result.Error.Exception.Message | Should -Be 'task: Task "helo" does not exist. Did you mean "hello"?'
        $result.Error.FullyQualifiedErrorId | Should -Be 'TaskNotFound,Invoke-Task'
        $result.ExitCode | Should -Be 200
    }

    It 'does not run anything when one of the requested tasks is unknown' {
        $result = Invoke-TestTask $script:Dir hello, nope
        $result.Lines | Should -Not -Contain 'hello'
        $result.ExitCode | Should -Be 200
    }

    It 'refuses to run internal tasks directly' {
        $result = Invoke-TestTask $script:Dir secret
        $result.Error.Exception.Message | Should -Be 'task: Task "secret" is internal'
        $result.ExitCode | Should -Be 202
    }

    It 'fails with code 100 when there is no Taskfile' {
        $result = Invoke-TestTask (New-TestDirectory) -With @{ Taskfile = 'missing.yml' }
        $result.Error.Exception.Message | Should -BeLike 'task: No Taskfile found at "missing.yml"*'
        $result.ExitCode | Should -Be 100
    }

    It 'resets LASTEXITCODE to 0 after a successful run' {
        $global:LASTEXITCODE = 5
        $null = Invoke-Task -Directory $script:Dir -Name hello -PassThru 6>&1
        $global:LASTEXITCODE | Should -Be 0
    }
}
