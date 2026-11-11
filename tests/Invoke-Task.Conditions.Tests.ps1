BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"
}

Describe 'Invoke-Task: up-to-date checks' {
    BeforeEach {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  status-true:
    status:
      - Test-Path marker.txt
    cmds:
      - Set-Content -Path marker.txt -Value done
      - Write-Output created
  status-exit:
    status:
      - if (-not (Test-Path marker.txt)) { exit 1 }
    cmds:
      - Set-Content -Path marker.txt -Value done
      - Write-Output created
  status-vars:
    silent: true
    sources: ['src/*.txt']
    status:
      - Set-Content -Path seen.txt -Value '{{.CHECKSUM}}|{{.TIMESTAMP.Unix}}'; $false
    cmds:
      - Write-Output ran
  build:
    sources: ['src/**/*.txt']
    generates: ['out/result.txt']
    cmds:
      - New-Item -ItemType Directory -Path out -Force | Out-Null
      - Set-Content -Path out/result.txt -Value built
      - Write-Output built
  with-dep:
    deps: [dep]
    sources: ['src/*.txt']
    cmds:
      - Write-Output main
  dep:
    cmds:
      - Write-Output dep
  timestamp:
    method: timestamp
    sources: ['src/*.txt']
    generates: ['out/stamp.txt']
    cmds:
      - New-Item -ItemType Directory -Path out -Force | Out-Null
      - Set-Content -Path out/stamp.txt -Value stamped
      - Write-Output stamped
  none:
    method: none
    sources: ['src/*.txt']
    cmds:
      - Write-Output always
  failing:
    sources: ['src/*.txt']
    cmds:
      - exit 1
  both:
    sources: ['src/*.txt']
    status:
      - Test-Path marker.txt
    cmds:
      - Write-Output both-ran
'@
        $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'a.txt') -Content 'a'
        $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'deep' 'b.txt') -Content 'b'
    }

    It 'skips a task whose status commands succeed' {
        (Invoke-TestTask $script:Dir status-true).Lines | Should -Contain 'created'
        $second = Invoke-TestTask $script:Dir status-true
        $second.Lines | Should -Be @('task: Task "status-true" is up to date')
        $second.Error | Should -BeNullOrEmpty
    }

    It 'accepts exit codes as well as booleans in status commands' {
        (Invoke-TestTask $script:Dir status-exit).Lines | Should -Contain 'created'
        (Invoke-TestTask $script:Dir status-exit).Lines | Should -Be @('task: Task "status-exit" is up to date')
    }

    It 'provides CHECKSUM and TIMESTAMP to status commands' {
        (Invoke-TestTask $script:Dir status-vars).Lines | Should -Be @('ran')
        Get-Content (Join-Path $script:Dir 'seen.txt') | Should -Match '^[0-9a-f]{32}\|\d{9,}$'
    }

    It 'skips a task whose sources did not change' {
        (Invoke-TestTask $script:Dir build).Lines | Should -Contain 'built'
        (Invoke-TestTask $script:Dir build).Lines | Should -Be @('task: Task "build" is up to date')
        Test-Path (Join-Path $script:Dir '.task' 'checksum' 'build') | Should -BeTrue
    }

    It 'runs again when a source changes' {
        $null = Invoke-TestTask $script:Dir build
        $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'deep' 'b.txt') -Content 'changed'
        (Invoke-TestTask $script:Dir build).Lines | Should -Contain 'built'
    }

    It 'runs again when a generated file is missing' {
        $null = Invoke-TestTask $script:Dir build
        Remove-Item (Join-Path $script:Dir 'out' 'result.txt')
        (Invoke-TestTask $script:Dir build).Lines | Should -Contain 'built'
    }

    It 'runs an up-to-date task with -Force' {
        $null = Invoke-TestTask $script:Dir build
        (Invoke-TestTask $script:Dir build -With @{ Force = $true }).Lines | Should -Contain 'built'
    }

    It 'does not print the up-to-date message for silent runs' {
        $null = Invoke-TestTask $script:Dir build
        (Invoke-TestTask $script:Dir build -With @{ Silent = $true }).Lines | Should -BeNullOrEmpty
    }

    It 'still runs the dependencies of an up-to-date task' {
        $null = Invoke-TestTask $script:Dir with-dep
        (Invoke-TestTask $script:Dir with-dep).Lines | Should -Be @('task: [dep] Write-Output dep', 'dep', 'task: Task "with-dep" is up to date')
    }

    It 'supports the timestamp method' {
        (Invoke-TestTask $script:Dir timestamp).Lines | Should -Contain 'stamped'
        (Invoke-TestTask $script:Dir timestamp).Lines | Should -Be @('task: Task "timestamp" is up to date')
        (Get-Item (Join-Path $script:Dir 'src' 'a.txt')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(5)
        (Invoke-TestTask $script:Dir timestamp).Lines | Should -Contain 'stamped'
    }

    It 'always runs with method: none' {
        (Invoke-TestTask $script:Dir none).Lines | Should -Contain 'always'
        (Invoke-TestTask $script:Dir none).Lines | Should -Contain 'always'
    }

    It 'runs a failed task again' {
        (Invoke-TestTask $script:Dir failing).ExitCode | Should -Be 201
        (Invoke-TestTask $script:Dir failing).ExitCode | Should -Be 201
    }

    It 'requires both status and sources to be up to date' {
        (Invoke-TestTask $script:Dir both).Lines | Should -Contain 'both-ran'
        (Invoke-TestTask $script:Dir both).Lines | Should -Contain 'both-ran'
        $null = Set-TestFile -Path (Join-Path $script:Dir 'marker.txt') -Content 'x'
        (Invoke-TestTask $script:Dir both).Lines | Should -Be @('task: Task "both" is up to date')
    }

    It 'honours TASK_TEMP_DIR' {
        $env:TASK_TEMP_DIR = 'custom-state'
        try { $null = Invoke-TestTask $script:Dir build }
        finally { Remove-Item Env:TASK_TEMP_DIR }
        Test-Path (Join-Path $script:Dir 'custom-state' 'checksum' 'build') | Should -BeTrue
    }
}

Describe 'Invoke-Task: preconditions, platforms and if' {
    BeforeAll {
        $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
        $arch = switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) { 'X64' { 'amd64' } 'Arm64' { 'arm64' } 'X86' { '386' } default { 'arm' } }
        $script:Dir = New-TestTaskfile (@'
version: '3'
tasks:
  pre-ok:
    silent: true
    preconditions:
      - Test-Path Taskfile.yml
      - sh: $true
        msg: never shown
    cmds:
      - Write-Output ok
  pre-msg:
    preconditions:
      - sh: Test-Path missing.txt
        msg: 'missing.txt is required by {{.TASK}}'
    cmds:
      - Write-Output unreachable
  pre-default:
    preconditions:
      - exit 1
    cmds:
      - Write-Output unreachable
  pre-caller:
    cmds:
      - task: pre-msg
  not-here:
    platforms: [plan9]
    cmds:
      - Write-Output unreachable
  here:
    silent: true
    platforms: [__OS__, plan9]
    cmds:
      - Write-Output here
  cmd-platform:
    silent: true
    cmds:
      - cmd: Write-Output skipped
        platforms: [plan9/386]
      - cmd: Write-Output current
        platforms: [__OS__/__ARCH__]
  if-false:
    if: Test-Path missing.txt
    cmds:
      - Write-Output unreachable
  if-true:
    silent: true
    if: '{{eq .MODE "run"}}'
    vars:
      MODE: run
    cmds:
      - Write-Output conditional
  cmd-if:
    silent: true
    cmds:
      - cmd: Write-Output skipped
        if: $false
      - cmd: Write-Output kept
        if: Test-Path Taskfile.yml
'@).Replace('__OS__', $os).Replace('__ARCH__', $arch)
    }

    It 'runs when every precondition holds' {
        (Invoke-TestTask $script:Dir pre-ok).Lines | Should -Be @('ok')
    }

    It 'fails with the message of the precondition' {
        $result = Invoke-TestTask $script:Dir pre-msg
        $result.Lines | Should -Be @('task: missing.txt is required by pre-msg')
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "pre-msg": task: precondition not met'
        $result.ExitCode | Should -Be 201
    }

    It 'uses a default message' {
        (Invoke-TestTask $script:Dir pre-default).Lines | Should -Be @('task: `exit 1` failed')
    }

    It 'fails the calling task as well' {
        $result = Invoke-TestTask $script:Dir pre-caller
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "pre-caller": task: Failed to run task "pre-msg": task: precondition not met'
    }

    It 'skips tasks and commands for other platforms' {
        $skipped = Invoke-TestTask $script:Dir not-here
        $skipped.Lines | Should -BeNullOrEmpty
        $skipped.Error | Should -BeNullOrEmpty
        (Invoke-TestTask $script:Dir here).Lines | Should -Be @('here')
        (Invoke-TestTask $script:Dir cmd-platform).Lines | Should -Be @('current')
    }

    It 'skips tasks and commands whose if condition does not hold' {
        (Invoke-TestTask $script:Dir if-false).Lines | Should -BeNullOrEmpty
        (Invoke-TestTask $script:Dir if-true).Lines | Should -Be @('conditional')
        (Invoke-TestTask $script:Dir cmd-if).Lines | Should -Be @('kept')
    }
}

Describe 'Invoke-Task: run, prompt and dry run' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  twice:
    silent: true
    deps: [once, once]
    cmds:
      - task: once
      - task: always
      - task: always
      - Write-Output finished
  once:
    silent: true
    run: once
    cmds:
      - Write-Output once
  always:
    silent: true
    cmds:
      - Write-Output always
  changed:
    silent: true
    cmds:
      - task: when-changed
        vars: {V: a}
      - task: when-changed
        vars: {V: a}
      - task: when-changed
        vars: {V: b}
  when-changed:
    silent: true
    run: when_changed
    cmds:
      - Write-Output 'value {{.V}}'
  bad-run:
    run: sometimes
    cmds:
      - Write-Output unreachable
  ask:
    silent: true
    prompt: Deploy to production?
    cmds:
      - Write-Output deployed
  ask-many:
    silent: true
    prompt: [First?, Second?]
    cmds:
      - Write-Output confirmed
  dry:
    deps: [dry-dep]
    cmds:
      - Set-Content -Path created.txt -Value x
      - defer: Write-Output cleanup
      - task: dry-dep
      - exit 1
  dry-dep:
    cmds:
      - Write-Output dep
'@
    }

    It 'runs a "run: once" task a single time' {
        (Invoke-TestTask $script:Dir twice).Lines | Should -Be @('once', 'always', 'always', 'finished')
    }

    It 'runs a "run: when_changed" task once per set of variables' {
        (Invoke-TestTask $script:Dir changed).Lines | Should -Be @('value a', 'value b')
    }

    It 'rejects an unknown run mode' {
        (Invoke-TestTask $script:Dir bad-run).Error.Exception.Message | Should -BeLike '*invalid run "sometimes"*'
    }

    It 'confirms prompts with -AssumeYes' {
        (Invoke-TestTask $script:Dir ask -With @{ AssumeYes = $true }).Lines | Should -Be @('Deploy to production? [assuming yes]', 'deployed')
        (Invoke-TestTask $script:Dir ask-many -With @{ AssumeYes = $true }).Lines | Should -Be @('First? [assuming yes]', 'Second? [assuming yes]', 'confirmed')
    }

    It 'cancels a task with a prompt when there is no terminal' -Skip:(-not [Console]::IsInputRedirected) {
        $result = Invoke-TestTask $script:Dir ask
        $result.Lines | Should -Not -Contain 'deployed'
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "ask": task: Task "ask" cancelled because it has a prompt and the environment is not a terminal. Use -AssumeYes to run anyway.'
        $result.ExitCode | Should -Be 201
    }

    It 'only prints the commands with -WhatIf' {
        $result = Invoke-TestTask $script:Dir dry -With @{ WhatIf = $true }
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Should -Be @(
            'task: [dry-dep] Write-Output dep'
            'task: [dry] Set-Content -Path created.txt -Value x'
            'task: [dry-dep] Write-Output dep'
            'task: [dry] exit 1'
            'task: [dry] Write-Output cleanup'
        )
        Test-Path (Join-Path $script:Dir 'created.txt') | Should -BeFalse
    }
}
