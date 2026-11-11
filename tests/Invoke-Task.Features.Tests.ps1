BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"
}

Describe 'Invoke-Task: echoing and names' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
vars:
  SUFFIX: x
tasks:
  task-silent:
    silent: true
    cmds: [Write-Output a]
  cmd-silent:
    cmds:
      - cmd: Write-Output quiet
        silent: true
      - Write-Output loud
  call-silent:
    cmds:
      - task: plain
        silent: true
      - task: plain
  plain:
    cmds: [Write-Output plain]
  labelled:
    label: 'custom-{{.SUFFIX}}'
    status: ['{{.DONE | default "false"}}']
    cmds: [Write-Output labelled]
  aliased:
    aliases: [al, other-name]
    silent: true
    cmds:
      - Write-Output 'aliased as {{.ALIAS}}'
  'start:*':
    silent: true
    cmds:
      - Write-Output 'starting {{index .MATCH 0}}'
  'deploy:*:*':
    silent: true
    vars:
      APP: '{{index .MATCH 0}}'
      STAGE: '{{index .MATCH 1}}'
    cmds:
      - Write-Output '{{.APP}} to {{.STAGE}}'
  'clash:*':
    cmds: [Write-Output a]
  'clash:x*':
    cmds: [Write-Output b]
'@
        $script:SilentDir = New-TestTaskfile @'
version: '3'
silent: true
tasks:
  quiet:
    cmds: [Write-Output quiet]
  loud:
    silent: false
    cmds: [Write-Output loud]
'@
    }

    It 'does not echo silent tasks, commands or calls' {
        (Invoke-TestTask $script:Dir task-silent).Lines | Should -Be @('a')
        (Invoke-TestTask $script:Dir cmd-silent).Lines | Should -Be @('quiet', 'task: [cmd-silent] Write-Output loud', 'loud')
        (Invoke-TestTask $script:Dir call-silent).Lines | Should -Be @('plain', 'task: [plain] Write-Output plain', 'plain')
    }

    It 'does not echo anything with -Silent' {
        (Invoke-TestTask $script:Dir cmd-silent -With @{ Silent = $true }).Lines | Should -Be @('quiet', 'loud')
    }

    It 'applies the global silent setting unless a task opts out' {
        (Invoke-TestTask $script:SilentDir quiet).Lines | Should -Be @('quiet')
        (Invoke-TestTask $script:SilentDir loud).Lines | Should -Be @('task: [loud] Write-Output loud', 'loud')
    }

    It 'uses the label in messages' {
        (Invoke-TestTask $script:Dir labelled).Lines | Should -Be @('task: [custom-x] Write-Output labelled', 'labelled')
        (Invoke-TestTask $script:Dir labelled -With @{ Variable = @{ DONE = 'true' } }).Lines | Should -Be @('task: Task "custom-x" is up to date')
    }

    It 'runs a task by alias' {
        (Invoke-TestTask $script:Dir al).Lines | Should -Be @('aliased as al')
        (Invoke-TestTask $script:Dir other-name).Lines | Should -Be @('aliased as other-name')
    }

    It 'matches wildcard task names' {
        (Invoke-TestTask $script:Dir start:web).Lines | Should -Be @('starting web')
        (Invoke-TestTask $script:Dir deploy:api:prod).Lines | Should -Be @('api to prod')
    }

    It 'fails when several wildcard tasks match' {
        $result = Invoke-TestTask $script:Dir clash:xy
        $result.Error.Exception.Message | Should -Be 'task: Found multiple tasks (clash:*, clash:x*) that match "clash:xy"'
        $result.ExitCode | Should -Be 203
    }

    It 'accepts task names from the pipeline' {
        $lines = @('task-silent', 'plain' | Invoke-Task -Directory $script:Dir -PassThru 6>&1 | ForEach-Object { "$_" })
        $lines | Should -Be @('a', 'task: [plain] Write-Output plain', 'plain')
    }

    It 'writes engine details to the verbose stream with -Verbose' {
        $result = Invoke-TestTask $script:Dir task-silent -With @{ Verbose = $true }
        $result.Lines | Should -Be @(
            'VERBOSE: task: "task-silent" started'
            'task: [task-silent] Write-Output a'
            'a'
            'VERBOSE: task: "task-silent" finished'
        )
    }
}

Describe 'Invoke-Task: includes' {
    BeforeAll {
        $script:Root = New-TestDirectory
        $null = Set-TestFile -Path (Join-Path $script:Root 'Taskfile.yml') -Content @'
version: '3'
vars:
  WHO: root
includes:
  lib: ./lib
  docs:
    taskfile: ./docs
    dir: ./docs
    vars: {MODE: fast}
  hidden:
    taskfile: ./hidden.yml
    internal: true
tasks:
  default:
    silent: true
    cmds:
      - task: lib:build
      - task: hidden:work
  root-task:
    silent: true
    cmds:
      - Write-Output 'root-task for {{.WHO}}'
'@
        $null = Set-TestFile -Path (Join-Path $script:Root 'lib' 'Taskfile.yml') -Content @'
version: '3'
vars:
  LIB: lib-var
tasks:
  default:
    silent: true
    cmds: [Write-Output lib-default]
  build:
    silent: true
    deps: [prepare]
    cmds:
      - task: :root-task
      - Write-Output 'build {{.LIB}} in {{osBase .TASKFILE_DIR}} at {{osBase .ROOT_DIR}}'
      - Split-Path -Leaf (Get-Location)
  prepare:
    silent: true
    cmds: [Write-Output prepare]
'@
        $null = Set-TestFile -Path (Join-Path $script:Root 'docs' 'Taskfile.yml') -Content @'
version: '3'
tasks:
  serve:
    silent: true
    cmds:
      - Write-Output 'serve {{.MODE}}'
      - Split-Path -Leaf (Get-Location)
'@
        $null = Set-TestFile -Path (Join-Path $script:Root 'hidden.yml') -Content @'
version: '3'
tasks:
  work:
    silent: true
    cmds: [Write-Output hidden-work]
'@
    }

    It 'runs namespaced tasks with their dependencies and root references' {
        (Invoke-TestTask $script:Root lib:build).Lines | Should -Be @(
            'prepare', 'root-task for root', "build lib-var in lib at $(Split-Path -Leaf $script:Root)", (Split-Path -Leaf $script:Root)
        )
    }

    It 'runs the default task of an include by its namespace' {
        (Invoke-TestTask $script:Root lib).Lines | Should -Be @('lib-default')
    }

    It 'applies the dir and vars of an include' {
        (Invoke-TestTask $script:Root docs:serve).Lines | Should -Be @('serve fast', 'docs')
    }

    It 'allows internal includes to be called but not run directly' {
        (Invoke-TestTask $script:Root).Lines[-1] | Should -Be 'hidden-work'
        (Invoke-TestTask $script:Root hidden:work).ExitCode | Should -Be 202
    }
}

Describe 'Invoke-Task: output styles' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  lines:
    cmds:
      - Write-Output one; Write-Host two
      - "[pscustomobject]@{ Name = 'obj' } | Format-List"
  custom-prefix:
    prefix: 'p-{{.TASK}}'
    silent: true
    cmds:
      - Write-Output line
  fails:
    silent: true
    cmds:
      - Write-Output before
      - throw 'broken'
  mixed:
    silent: true
    cmds:
      - Write-Output good
      - cmd: exit 2
        ignore_error: true
'@
        $script:GroupDir = New-TestTaskfile @'
version: '3'
output:
  group:
    begin: '::group::{{.TASK}}'
    end: '::endgroup::'
tasks:
  grouped:
    silent: true
    cmds:
      - Write-Output a; Write-Output b
'@
    }

    It 'prefixes every line with the task name' {
        $result = Invoke-TestTask $script:Dir lines -With @{ Output = 'prefixed' }
        $result.Lines | Should -Be @(
            'task: [lines] Write-Output one; Write-Host two'
            '[lines] one'
            '[lines] two'
            "task: [lines] [pscustomobject]@{ Name = 'obj' } | Format-List"
            '[lines] '
            '[lines] Name : obj'
            '[lines] '
        )
    }

    It 'uses the prefix of the task' {
        (Invoke-TestTask $script:Dir custom-prefix -With @{ Output = 'prefixed' }).Lines | Should -Be @('[p-custom-prefix] line')
    }

    It 'prefixes error output as well' {
        $result = Invoke-TestTask $script:Dir fails -With @{ Output = 'prefixed' }
        $result.Lines[0] | Should -Be '[fails] before'
        ($result.Lines | Select-Object -Skip 1) -join ' ' | Should -Match '^\[fails\] .*broken'
        $result.Error.Exception.Message | Should -Be 'task: Failed to run task "fails": broken'
    }

    It 'groups the output of each command' {
        $result = Invoke-TestTask $script:Dir lines -With @{ Output = 'group'; OutputGroupBegin = '>> {{.TASK}}'; OutputGroupEnd = '<<' }
        $result.Lines | Should -Be @(
            'task: [lines] Write-Output one; Write-Host two'
            '>> lines', 'one', 'two', '<<'
            "task: [lines] [pscustomobject]@{ Name = 'obj' } | Format-List"
            '>> lines', '', 'Name : obj', '', '<<'
        )
    }

    It 'reads the group settings of the Taskfile' {
        (Invoke-TestTask $script:GroupDir grouped).Lines | Should -Be @('::group::grouped', 'a', 'b', '::endgroup::')
    }

    It 'drops the output of successful commands with -OutputGroupErrorOnly' {
        $result = Invoke-TestTask $script:Dir mixed -With @{ Output = 'group'; OutputGroupErrorOnly = $true }
        $result.Lines | Should -BeNullOrEmpty
        $failed = Invoke-TestTask $script:Dir fails -With @{ Output = 'group'; OutputGroupErrorOnly = $true }
        $failed.Lines | Should -Not -Contain 'before'
        $failed.Lines -join ' ' | Should -Match 'broken'
    }

    It 'lets -Output override the Taskfile' {
        (Invoke-TestTask $script:GroupDir grouped -With @{ Output = 'interleaved' }).Lines | Should -Be @('a', 'b')
    }
}

Describe 'Invoke-Task: parallel execution' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  left:
    silent: true
    cmds:
      - |
        Set-Content -Path left.flag -Value x
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path right.flag)) {
            if ([datetime]::UtcNow -gt $deadline) { throw 'right never started' }
            Start-Sleep -Milliseconds 20
        }
        Write-Output left-done
  right:
    silent: true
    cmds:
      - |
        Set-Content -Path right.flag -Value x
        $deadline = [datetime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path left.flag)) {
            if ([datetime]::UtcNow -gt $deadline) { throw 'left never started' }
            Start-Sleep -Milliseconds 20
        }
        Write-Output right-done
  logged:
    silent: true
    deps:
      - task: log
        vars: {ID: a}
      - task: log
        vars: {ID: b}
      - task: log
        vars: {ID: c}
  log:
    silent: true
    cmds:
      - Add-Content -Path order.log -Value 'start {{.ID}}'
      - Start-Sleep -Milliseconds 150
      - Add-Content -Path order.log -Value 'end {{.ID}}'
  env-a:
    silent: true
    env: {SHARED: a}
    cmds:
      - Start-Sleep -Milliseconds 100
      - pwsh -NoProfile -Command "'a sees ' + `$env:SHARED"
  env-b:
    silent: true
    env: {SHARED: b}
    cmds:
      - Start-Sleep -Milliseconds 100
      - pwsh -NoProfile -Command "'b sees ' + `$env:SHARED"
'@
    }

    It 'runs the given tasks at the same time with -Parallel' {
        Remove-Item (Join-Path $script:Dir '*.flag') -ErrorAction Ignore
        $result = Invoke-TestTask $script:Dir left, right -With @{ Parallel = $true }
        $result.Error | Should -BeNullOrEmpty
        $result.Lines | Sort-Object | Should -Be @('left-done', 'right-done')
    }

    It 'limits the number of running tasks with -Concurrency' {
        $log = Join-Path $script:Dir 'order.log'
        Remove-Item $log -ErrorAction Ignore
        $result = Invoke-TestTask $script:Dir logged -With @{ Concurrency = 1 }
        $result.Error | Should -BeNullOrEmpty
        $entries = @(Get-Content $log)
        $entries.Count | Should -Be 6
        for ($i = 0; $i -lt 6; $i += 2) {
            $entries[$i] | Should -Match '^start '
            $entries[$i + 1] | Should -Be ($entries[$i] -replace '^start', 'end')
        }
    }

    It 'gives every task its own environment even when they run in parallel' {
        $result = Invoke-TestTask $script:Dir env-a, env-b -With @{ Parallel = $true }
        $result.Lines | Sort-Object | Should -Be @('a sees a', 'b sees b')
    }
}

Describe 'Invoke-Task: host output (without -PassThru)' {
    BeforeAll {
        $script:Dir = New-TestTaskfile @'
version: '3'
tasks:
  default:
    cmds:
      - Write-Output from-pipeline
      - Write-Host from-host
      - "[pscustomobject]@{ Name = 'row'; Value = 1 } | Format-Table -HideTableHeaders"
      - pwsh -NoProfile -Command "'from-native'"
  fail:
    cmds:
      - Write-Output before
      - exit 5
'@
        function Invoke-InChildProcess {
            param([string]$Command)
            $script = "`$ErrorActionPreference = 'Continue'; Import-Module '$script:ModuleManifest'; $Command"
            $output = & pwsh -NoProfile -NonInteractive -Command $script 2>&1
            [pscustomobject]@{ Lines = @($output | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ -ne '' }); ExitCode = $LASTEXITCODE }
        }
    }

    It 'writes engine messages and command output to the host in order' {
        $result = Invoke-InChildProcess "Invoke-Task -Directory '$script:Dir' -NoColor"
        $result.Lines | Should -Be @(
            'task: [default] Write-Output from-pipeline'
            'from-pipeline'
            'task: [default] Write-Host from-host'
            'from-host'
            "task: [default] [pscustomobject]@{ Name = 'row'; Value = 1 } | Format-Table -HideTableHeaders"
            'row      1'
            "task: [default] pwsh -NoProfile -Command `"'from-native'`""
            'from-native'
        )
        $result.ExitCode | Should -Be 0
    }

    It 'returns nothing on the pipeline' {
        $result = Invoke-InChildProcess "`$captured = Invoke-Task -Directory '$script:Dir' -Silent; 'captured=' + @(`$captured).Count"
        $result.Lines[-1] | Should -Be 'captured=0'
    }

    It 'supports the prefixed and group styles on the host' {
        $prefixed = Invoke-InChildProcess "Invoke-Task -Directory '$script:Dir' -Silent -Output prefixed"
        $prefixed.Lines | Should -Be @('[default] from-pipeline', '[default] from-host', '[default]', '[default] row      1', '[default]', '[default] from-native')
        $grouped = Invoke-InChildProcess "Invoke-Task -Directory '$script:Dir' -Silent -Output group -OutputGroupBegin '--begin'"
        $grouped.Lines | Should -Be @('--begin', 'from-pipeline', '--begin', 'from-host', '--begin', 'row      1', '--begin', 'from-native')
    }

    It 'lets a script exit with the code of the failed run' {
        $result = Invoke-InChildProcess "Invoke-Task -Directory '$script:Dir' fail -NoColor; exit `$LASTEXITCODE"
        $result.Lines[0..2] | Should -Be @('task: [fail] Write-Output before', 'before', 'task: [fail] exit 5')
        $result.Lines -join "`n" | Should -Match 'task: Failed to run task "fail": exit status 5'
        $result.ExitCode | Should -Be 201
    }

    It 'does not close the calling session when a command calls exit' {
        $result = Invoke-InChildProcess "try { Invoke-Task -Directory '$script:Dir' fail -Silent } catch { }; 'still-alive'"
        $result.Lines[-1] | Should -Be 'still-alive'
    }
}
