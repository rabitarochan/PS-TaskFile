BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"
}

Describe 'Module surface' {
    It 'exports exactly the public commands' {
        (Get-Command -Module PSTaskFile).Name | Sort-Object | Should -Be @(
            'Get-Task', 'Get-TaskSummary', 'Invoke-Task', 'New-Taskfile', 'Test-Task', 'Watch-Task'
        )
    }

    It 'uses approved verbs' {
        $approved = (Get-Verb).Verb
        (Get-Command -Module PSTaskFile).Verb | ForEach-Object { $_ | Should -BeIn $approved }
    }

    It 'has help for <_>' -ForEach @('Get-Task', 'Get-TaskSummary', 'Invoke-Task', 'New-Taskfile', 'Test-Task', 'Watch-Task') {
        $help = Get-Help $_
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $help.Synopsis | Should -Not -Match "^\s*$_\s"
        $help.examples.example.Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-Task' {
    BeforeAll {
        $script:Root = New-TestDirectory
        $null = Set-TestFile -Path (Join-Path $script:Root 'Taskfile.yml') -Content @'
version: '3'
vars:
  PRODUCT: Widget
includes:
  docs: ./docs.yml
tasks:
  test:
    desc: Run the tests
    cmds: [Write-Output test]
  build:
    desc: 'Build {{.PRODUCT}}'
    summary: |
      Builds the product.
      Second line.
    aliases: [b, compile]
    sources: ['src/*.txt']
    cmds: [Write-Output build]
  helper:
    cmds: [Write-Output helper]
  secret:
    desc: Never listed
    internal: true
    cmds: [Write-Output secret]
  done:
    desc: Already done
    status: ['$true']
    cmds: [Write-Output done]
  'run:*':
    desc: Run something
    cmds: [Write-Output run]
'@
        $null = Set-TestFile -Path (Join-Path $script:Root 'docs.yml') -Content @'
version: '3'
tasks:
  serve:
    desc: Serve the docs
    cmds: [Write-Output serve]
'@
        $null = Set-TestFile -Path (Join-Path $script:Root 'src' 'a.txt') -Content 'a'
    }

    It 'lists the tasks that have a description' {
        $tasks = @(Get-Task -Directory $script:Root)
        $tasks.Name | Should -Be @('build', 'done', 'test', 'docs:serve', 'run:*')
        $tasks[0].PSObject.TypeNames[0] | Should -Be 'PSTaskFile.TaskInfo'
    }

    It 'returns the details of each task' {
        $build = Get-Task -Directory $script:Root | Where-Object Name -EQ 'build'
        $build.Description | Should -Be 'Build Widget'
        $build.Summary | Should -Be "Builds the product.`nSecond line.`n"
        $build.Aliases | Should -Be @('b', 'compile')
        $build.Location.Taskfile | Should -Be (Join-Path $script:Root 'Taskfile.yml')
        $build.Location.Line | Should -Be 10
        $build.Location.Column | Should -Be 3
        $build.UpToDate | Should -BeNullOrEmpty
        (Get-Task -Directory $script:Root | Where-Object Name -EQ 'docs:serve').Location.Taskfile | Should -Be (Join-Path $script:Root 'docs.yml')
    }

    It 'includes tasks without a description with -All but never internal ones' {
        (Get-Task -Directory $script:Root -All).Name | Should -Be @('build', 'done', 'helper', 'test', 'docs:serve', 'run:*')
    }

    It 'sorts with -Sort <Sort>' -ForEach @(
        @{ Sort = 'alphanumeric'; Expected = @('build', 'docs:serve', 'done', 'helper', 'run:*', 'test') }
        @{ Sort = 'none'; Expected = @('test', 'build', 'helper', 'done', 'run:*', 'docs:serve') }
    ) {
        (Get-Task -Directory $script:Root -All -Sort $Sort).Name | Should -Be $Expected
    }

    It 'filters by name or alias with wildcards' {
        (Get-Task -Directory $script:Root -Name 'b*').Name | Should -Be @('build')
        (Get-Task -Directory $script:Root -Name compile).Name | Should -Be @('build')
        (Get-Task -Directory $script:Root -Name helper, 'docs:*').Name | Should -Be @('helper', 'docs:serve')
        Get-Task -Directory $script:Root -Name secret | Should -BeNullOrEmpty
    }

    It 'reports whether tasks are up to date with -IncludeStatus' {
        $tasks = Get-Task -Directory $script:Root -IncludeStatus
        ($tasks | Where-Object Name -EQ 'done').UpToDate | Should -BeTrue
        ($tasks | Where-Object Name -EQ 'test').UpToDate | Should -BeFalse
        ($tasks | Where-Object Name -EQ 'build').UpToDate | Should -BeFalse
        Test-Path (Join-Path $script:Root '.task') | Should -BeFalse
    }

    It 'warns when no task has a description' {
        $dir = New-TestTaskfile "version: '3'`ntasks:`n  a: [Write-Output a]"
        $warnings = @()
        Get-Task -Directory $dir -WarningVariable warnings -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -Be 'task: No tasks with description available. Try -All to list all tasks'
    }

    It 'can be piped into Invoke-Task' {
        $lines = @(Get-Task -Directory $script:Root -Name test | Invoke-Task -Directory $script:Root -Silent -PassThru)
        $lines | Should -Be @('test')
    }

    It 'fails like Invoke-Task when there is no Taskfile' {
        { Get-Task -Directory (New-TestDirectory) -Taskfile missing.yml } | Should -Throw -ExpectedMessage '*No Taskfile found*'
        $global:LASTEXITCODE | Should -Be 100
    }
}

Describe 'Get-TaskSummary' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
vars:
  G: global
  DYN:
    sh: Get-Date
env:
  GENV: genv
tasks:
  full:
    desc: Short description
    summary: |
      Line one of the summary.

      Line three.
    aliases: [f]
    deps: [dep-a, dep-b]
    requires:
      vars:
        - NAME
        - name: MODE
          enum: [dev, prod]
    vars:
      LOCAL: 'local-{{.G}}'
      COUNT: 3
    env:
      TENV: tenv
    cmds:
      - Write-Output "{{.LOCAL}}"
      - task: dep-a
      - for: [x, y]
        cmd: Write-Output {{.ITEM}}
  described:
    desc: Only a description
    cmds: [Write-Output described]
  bare:
    cmds: [Write-Output bare]
  dep-a: [Write-Output a]
  dep-b: [Write-Output b]
'@
    }

    It 'prints the summary of a task like task --summary' {
        Get-TaskSummary -Directory $script:Dir -Name full | Should -Be @(
            'task: full'
            ''
            'Line one of the summary.'
            ''
            'Line three.'
            ''
            'vars:'
            '  G: "global"'
            '  DYN: sh: Get-Date'
            '  LOCAL: "local-global"'
            '  COUNT: 3'
            ''
            'env:'
            '  GENV: "genv"'
            '  TENV: "tenv"'
            ''
            'requires:'
            '  vars:'
            '    - NAME'
            '    - MODE:'
            '        enum:'
            '          - dev'
            '          - prod'
            ''
            'dependencies:'
            ' - dep-a'
            ' - dep-b'
            ''
            'aliases:'
            ' - f'
            ''
            'commands:'
            ' - Write-Output "local-global"'
            ' - Task: dep-a'
            ' - Write-Output x'
            ' - Write-Output y'
        )
    }

    It 'falls back to the description and to a placeholder' {
        (Get-TaskSummary -Directory $script:Dir -Name described)[0..2] | Should -Be @('task: described', '', 'Only a description')
        (Get-TaskSummary -Directory $script:Dir -Name bare)[0..2] | Should -Be @('task: bare', '', '(task does not have description or summary)')
    }

    It 'separates several summaries with blank lines' {
        $lines = Get-TaskSummary -Directory $script:Dir -Name dep-a, dep-b
        $lines | Should -Be @(
            'task: dep-a', '', '(task does not have description or summary)', '', 'vars:', '  G: "global"', '  DYN: sh: Get-Date', '', 'env:', '  GENV: "genv"', '', 'commands:', ' - Write-Output a'
            '', ''
            'task: dep-b', '', '(task does not have description or summary)', '', 'vars:', '  G: "global"', '  DYN: sh: Get-Date', '', 'env:', '  GENV: "genv"', '', 'commands:', ' - Write-Output b'
        )
    }

    It 'does not run dynamic variables or commands' {
        $dir = New-TestTaskfile "version: '3'`nvars:`n  V:`n    sh: Set-Content -Path ran.txt -Value x`ntasks:`n  t:`n    cmds: [Set-Content -Path ran.txt -Value y]"
        $null = Get-TaskSummary -Directory $dir -Name t
        Test-Path (Join-Path $dir 'ran.txt') | Should -BeFalse
    }

    It 'fails for an unknown task' {
        { Get-TaskSummary -Directory $script:Dir -Name nope } | Should -Throw -ExpectedMessage 'task: Task "nope" does not exist*'
    }
}

Describe 'Test-Task' {
    BeforeEach {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  done:
    status: ['$true']
    cmds: [Write-Output done]
  pending:
    status: ['$false']
    cmds: [Write-Output pending]
  build:
    sources: ['src/*.txt']
    cmds: [Write-Output build]
  plain:
    cmds: [Write-Output plain]
'@
        $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'a.txt') -Content 'a'
    }

    It 'returns whether each task is up to date' {
        Test-Task -Directory $script:Dir -Name done | Should -BeTrue
        Test-Task -Directory $script:Dir -Name pending | Should -BeFalse
        Test-Task -Directory $script:Dir -Name plain | Should -BeFalse
        Test-Task -Directory $script:Dir -Name done, pending, done | Should -Be @($true, $false, $true)
    }

    It 'follows the fingerprint of the sources without updating it' {
        Test-Task -Directory $script:Dir -Name build | Should -BeFalse
        Test-Path (Join-Path $script:Dir '.task') | Should -BeFalse
        $null = Invoke-Task -Directory $script:Dir -Name build -Silent -PassThru
        Test-Task -Directory $script:Dir -Name build | Should -BeTrue
        $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'a.txt') -Content 'changed'
        Test-Task -Directory $script:Dir -Name build | Should -BeFalse
        Test-Task -Directory $script:Dir -Name build | Should -BeFalse
    }

    It 'does not run the commands of the task' {
        $lines = @(Test-Task -Directory $script:Dir -Name pending 6>&1)
        $lines | Should -Be @($false)
    }

    It 'fails for an unknown task' {
        { Test-Task -Directory $script:Dir -Name nope } | Should -Throw -ExpectedMessage 'task: Task "nope" does not exist*'
    }
}

Describe 'New-Taskfile' {
    It 'creates a runnable Taskfile.yml in the given directory' {
        $dir = New-TestDirectory
        $file = New-Taskfile -Path $dir
        $file | Should -BeOfType [System.IO.FileInfo]
        $file.FullName | Should -Be (Join-Path $dir 'Taskfile.yml')
        (Get-Content $file.FullName -Raw) | Should -Match "version: '3'"
        (Invoke-TestTask $dir).Lines | Should -Be @('Hello, World!')
    }

    It 'creates the file in the current location by default' {
        $dir = New-TestDirectory
        Push-Location $dir
        try { $file = New-Taskfile }
        finally { Pop-Location }
        $file.FullName | Should -Be (Join-Path $dir 'Taskfile.yml')
    }

    It 'accepts a file name' {
        $dir = New-TestDirectory
        (New-Taskfile -Path (Join-Path $dir 'Custom.yaml')).Name | Should -Be 'Custom.yaml'
    }

    It 'refuses to overwrite an existing Taskfile unless -Force is given' {
        $dir = New-TestTaskfile "version: '3'`ntasks: {}"
        { New-Taskfile -Path $dir } | Should -Throw -ExpectedMessage 'task: A Taskfile already exists*'
        $global:LASTEXITCODE | Should -Be 101
        (Get-Content (Join-Path $dir 'Taskfile.yml') -Raw) | Should -Match 'tasks: \{\}'
        $null = New-Taskfile -Path $dir -Force
        (Get-Content (Join-Path $dir 'Taskfile.yml') -Raw) | Should -Match 'GREETING'
    }

    It 'does nothing with -WhatIf' {
        $dir = New-TestDirectory
        New-Taskfile -Path $dir -WhatIf | Should -BeNullOrEmpty
        Test-Path (Join-Path $dir 'Taskfile.yml') | Should -BeFalse
    }
}

Describe 'Watch-Task' {
    BeforeEach {
        $script:Dir = New-TestTaskfile @'
version: '3'
interval: 100ms
tasks:
  build:
    sources: ['src/*.txt']
    cmds:
      - Add-Content -Path runs.log -Value ((Get-Content src/a.txt -Raw).Trim())
  auto:
    watch: true
    sources: ['src/*.txt']
    cmds:
      - Add-Content -Path auto.log -Value ((Get-Content src/a.txt -Raw).Trim())
'@
        $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'a.txt') -Content 'one'

        function Wait-ForLines {
            param([string]$Path, [int]$Count, [int]$TimeoutSeconds = 30)
            $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
            while ([datetime]::UtcNow -lt $deadline) {
                if ((Test-Path $Path) -and @(Get-Content $Path).Count -ge $Count) { return $true }
                Start-Sleep -Milliseconds 50
            }
            return $false
        }
    }

    It 'runs the task again whenever a source changes, until it is stopped' {
        $log = Join-Path $script:Dir 'runs.log'
        $job = Start-ThreadJob -ScriptBlock {
            param($manifest, $dir)
            Import-Module $manifest
            Watch-Task -Directory $dir -Name build -PassThru *>&1
        } -ArgumentList $script:ModuleManifest, $script:Dir
        try {
            Wait-ForLines $log 1 | Should -BeTrue
            $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'a.txt') -Content 'two'
            Wait-ForLines $log 2 | Should -BeTrue
            $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'b.txt') -Content 'new file'
            Wait-ForLines $log 3 | Should -BeTrue
        }
        finally {
            $job | Stop-Job
            $output = @($job | Receive-Job -ErrorAction SilentlyContinue | ForEach-Object { "$_" })
            $job | Remove-Job -Force
        }
        Get-Content $log | Should -Be @('one', 'two', 'two')
        $output[0] | Should -Be 'task: Started watching for tasks: build'
    }

    It 'watches tasks marked with watch: true when they are invoked' {
        $log = Join-Path $script:Dir 'auto.log'
        $job = Start-ThreadJob -ScriptBlock {
            param($manifest, $dir)
            Import-Module $manifest
            Invoke-Task -Directory $dir -Name auto -PassThru *>&1
        } -ArgumentList $script:ModuleManifest, $script:Dir
        try {
            Wait-ForLines $log 1 | Should -BeTrue
            $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'a.txt') -Content 'again'
            Wait-ForLines $log 2 | Should -BeTrue
        }
        finally {
            $job | Stop-Job
            $job | Remove-Job -Force
        }
        Get-Content $log | Should -Be @('one', 'again')
    }
}

Describe 'Task name completion' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  build:
    desc: Build it
    aliases: [b]
    cmds: [Write-Output build]
  bundle:
    cmds: [Write-Output bundle]
  test:
    cmds: [Write-Output test]
  hidden:
    internal: true
    cmds: [Write-Output hidden]
'@
    }

    It 'completes task names for <Command>' -ForEach @(
        @{ Command = 'Invoke-Task' }, @{ Command = 'Get-Task' }, @{ Command = 'Get-TaskSummary' }, @{ Command = 'Test-Task' }, @{ Command = 'Watch-Task' }
    ) {
        $line = "$Command -Directory '$script:Dir' -Name bu"
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Be @('build', 'bundle')
        $result.CompletionMatches[0].ToolTip | Should -Be 'Build it'
    }

    It 'completes names in the current location and quotes when needed' {
        $dir = New-TestTaskfile "version: '3'`ntasks:`n  'has space': [Write-Output a]`n  'ns:plain': [Write-Output b]"
        Push-Location $dir
        try {
            $result = TabExpansion2 -inputScript 'Invoke-Task ' -cursorColumn 12
            $result.CompletionMatches.CompletionText | Should -Be @("'has space'", 'ns:plain')
        }
        finally { Pop-Location }
    }

    It 'offers no task names (and does not fail) when there is no Taskfile' {
        $line = "Invoke-Task -Taskfile '$(Join-Path (New-TestDirectory) 'missing.yml')' -Name bu"
        $result = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $result.CompletionMatches.CompletionText | Should -Not -Contain 'build'
    }
}
