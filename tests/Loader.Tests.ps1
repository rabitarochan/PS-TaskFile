BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"

    function Find-TestTaskfile {
        param([string]$Taskfile = '', [string]$Directory = '', [switch]$Global, [string]$WorkingDirectory)
        Invoke-InModule { param($t, $d, $g, $w) [TaskfileReader]::Find($t, $d, $g, $w) } -ArgumentList $Taskfile, $Directory, $Global.IsPresent, $WorkingDirectory
    }

    function Get-TaskErrorCode {
        param([scriptblock]$ScriptBlock)
        try { $null = & $ScriptBlock; return 0 }
        catch { return Invoke-InModule { param($e) [TaskError]::CodeOf($e) } -ArgumentList $_.Exception }
    }
}

Describe 'TaskfileReader.Find' {
    It 'finds <FileName> in the working directory' -ForEach @(
        @{ FileName = 'Taskfile.yml' }
        @{ FileName = 'Taskfile.yaml' }
        @{ FileName = 'Taskfile.dist.yml' }
        @{ FileName = 'Taskfile.dist.yaml' }
    ) {
        $dir = New-TestTaskfile -Content "version: '3'" -FileName $FileName
        $found = Find-TestTaskfile -WorkingDirectory $dir
        Split-Path -Leaf $found.Entrypoint | Should -Be $FileName
        $found.Dir | Should -Be $dir
    }

    It 'prefers Taskfile.yml over Taskfile.dist.yml' {
        $dir = New-TestTaskfile -Content "version: '3'"
        $null = Set-TestFile -Path (Join-Path $dir 'Taskfile.dist.yml') -Content "version: '3'"
        Split-Path -Leaf (Find-TestTaskfile -WorkingDirectory $dir).Entrypoint | Should -Be 'Taskfile.yml'
    }

    It 'walks up to parent directories' {
        $dir = New-TestTaskfile -Content "version: '3'"
        $nested = Join-Path $dir 'a' 'b'
        $null = New-Item -ItemType Directory -Path $nested -Force
        $found = Find-TestTaskfile -WorkingDirectory $nested
        $found.Entrypoint | Should -Be (Join-Path $dir 'Taskfile.yml')
        $found.Dir | Should -Be $dir
    }

    It 'uses an explicit Taskfile path' {
        $dir = New-TestTaskfile -Content "version: '3'" -FileName 'custom.yml'
        $other = New-TestDirectory
        $found = Find-TestTaskfile -Taskfile (Join-Path $dir 'custom.yml') -WorkingDirectory $other
        $found.Entrypoint | Should -Be (Join-Path $dir 'custom.yml')
        $found.Dir | Should -Be $dir
    }

    It 'resolves a relative Taskfile path against the working directory' {
        $dir = New-TestTaskfile -Content "version: '3'" -FileName 'custom.yml'
        (Find-TestTaskfile -Taskfile 'custom.yml' -WorkingDirectory $dir).Entrypoint | Should -Be (Join-Path $dir 'custom.yml')
    }

    It 'accepts a directory as the Taskfile path' {
        $dir = New-TestTaskfile -Content "version: '3'"
        $other = New-TestDirectory
        (Find-TestTaskfile -Taskfile $dir -WorkingDirectory $other).Entrypoint | Should -Be (Join-Path $dir 'Taskfile.yml')
    }

    It 'keeps the given directory as the execution directory when both are specified' {
        $dir = New-TestTaskfile -Content "version: '3'"
        $other = New-TestDirectory
        $found = Find-TestTaskfile -Taskfile (Join-Path $dir 'Taskfile.yml') -Directory $other -WorkingDirectory $dir
        $found.Dir | Should -Be $other
    }

    It 'searches from the given directory' {
        $dir = New-TestTaskfile -Content "version: '3'"
        $other = New-TestDirectory
        (Find-TestTaskfile -Directory $dir -WorkingDirectory $other).Entrypoint | Should -Be (Join-Path $dir 'Taskfile.yml')
    }

    It 'fails with code 100 when no Taskfile exists' {
        $dir = New-TestDirectory
        { Find-TestTaskfile -Taskfile (Join-Path $dir 'missing.yml') -WorkingDirectory $dir } | Should -Throw -ExpectedMessage '*No Taskfile found at*'
        Get-TaskErrorCode { Find-TestTaskfile -Taskfile (Join-Path $dir 'missing.yml') -WorkingDirectory $dir } | Should -Be 100
    }
}

Describe 'TaskfileReader.Load' {
    Context 'document level' {
        It 'requires a version' {
            $dir = New-TestTaskfile -Content "tasks: {}"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*version*'
        }

        It 'rejects schema versions before 3' {
            $dir = New-TestTaskfile -Content "version: '2'`ntasks: {}"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*prior to v3*'
        }

        It 'accepts version <Version>' -ForEach @(
            @{ Version = "'3'" }, @{ Version = '3' }, @{ Version = '3.0' }, @{ Version = "'3.44'" }, @{ Version = "'3.44.1'" }
        ) {
            $dir = New-TestTaskfile -Content "version: $Version`ntasks: {}"
            (Import-TestTaskfile $dir).Tasks.Count | Should -Be 0
        }

        It 'reports YAML syntax errors with code 102' {
            $dir = New-TestTaskfile -Content "version: '3'`ntasks:`n  a: [unclosed"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*Failed to parse*'
            Get-TaskErrorCode { Import-TestTaskfile $dir } | Should -Be 102
        }

        It 'reads top level settings' {
            $dir = New-TestTaskfile -Content @'
version: '3'
output: prefixed
method: timestamp
run: once
silent: true
interval: 500ms
dotenv: ['.env', '.env.local']
set: [errexit]
shopt: [globstar]
vars:
  A: text
  B: 5
  C: true
  D: [x, y]
  E:
    sh: Get-Date
  F:
    ref: .D
  G:
    map: {k: v}
env:
  X: one
  Y:
    sh: hostname
tasks: {}
'@
            $tf = Import-TestTaskfile $dir
            $tf.Output.Name | Should -Be 'prefixed'
            $tf.Method | Should -Be 'timestamp'
            $tf.Run | Should -Be 'once'
            $tf.Silent | Should -BeTrue
            $tf.Interval | Should -Be '500ms'
            $tf.Dotenv | Should -Be @('.env', '.env.local')
            $tf.Set | Should -Be @('errexit')
            $tf.Shopt | Should -Be @('globstar')
            @($tf.Vars.Keys) | Should -Be @('A', 'B', 'C', 'D', 'E', 'F', 'G')
            $tf.Vars['A'].Kind | Should -Be 'static'
            $tf.Vars['A'].Value | Should -BeExactly 'text'
            $tf.Vars['B'].Value | Should -Be 5
            $tf.Vars['C'].Value | Should -BeTrue
            $tf.Vars['D'].Value.Count | Should -Be 2
            $tf.Vars['E'].Kind | Should -Be 'sh'
            $tf.Vars['E'].Sh | Should -Be 'Get-Date'
            $tf.Vars['F'].Kind | Should -Be 'ref'
            $tf.Vars['F'].Ref | Should -Be '.D'
            $tf.Vars['G'].Value['k'] | Should -Be 'v'
            $tf.Env['X'].Value | Should -Be 'one'
            $tf.Env['Y'].Sh | Should -Be 'hostname'
        }

        It 'reads the grouped output form' {
            $dir = New-TestTaskfile -Content @'
version: '3'
output:
  group:
    begin: '::group::{{.TASK}}'
    end: '::endgroup::'
    error_only: true
tasks: {}
'@
            $tf = Import-TestTaskfile $dir
            $tf.Output.Name | Should -Be 'group'
            $tf.Output.Group.Begin | Should -Be '::group::{{.TASK}}'
            $tf.Output.Group.End | Should -Be '::endgroup::'
            $tf.Output.Group.ErrorOnly | Should -BeTrue
        }

        It 'rejects a plain map as a variable value' {
            $dir = New-TestTaskfile -Content "version: '3'`nvars:`n  BAD: {a: 1}`ntasks: {}"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*not a valid variable type*'
        }

        It 'keeps variable names case-sensitive' {
            $dir = New-TestTaskfile -Content "version: '3'`nvars:`n  foo: lower`n  FOO: upper`ntasks: {}"
            $tf = Import-TestTaskfile $dir
            $tf.Vars['foo'].Value | Should -BeExactly 'lower'
            $tf.Vars['FOO'].Value | Should -BeExactly 'upper'
        }
    }

    Context 'tasks' {
        BeforeAll {
            $script:Dir = New-TestTaskfile -Content @'
version: '3'
tasks:
  short: Write-Host short
  list:
    - Write-Host one
    - Write-Host two
  single:
    cmd: Write-Host single
  full:
    desc: Full task
    summary: |
      Line one
      Line two
    aliases: [f, complete]
    label: 'full-{{.X}}'
    prefix: pre
    dir: sub
    silent: true
    interactive: true
    internal: true
    ignore_error: true
    run: when_changed
    method: none
    watch: true
    failfast: true
    if: Test-Path .
    prompt: Continue?
    platforms: [windows, linux/amd64, arm64]
    dotenv: ['.env']
    set: [nounset]
    sources:
      - 'src/**/*.ps1'
      - exclude: 'src/**/*.Tests.ps1'
    generates: ['out/*.zip']
    status: ['Test-Path out']
    preconditions:
      - Test-Path src
      - sh: Test-Path lib
        msg: lib is missing
    requires:
      vars:
        - NAME
        - name: MODE
          enum: [dev, prod]
    vars:
      X: 1
    env:
      Y: 2
    deps:
      - short
      - task: list
        vars: {A: b}
        silent: true
      - for: [p, q]
        task: 'dep-{{.ITEM}}'
    cmds:
      - Write-Host plain
      - cmd: Write-Host opts
        silent: true
        ignore_error: true
        platforms: [windows]
        set: [errexit]
        if: $true
      - task: short
        vars: {K: v}
        silent: true
      - defer: Write-Host cleanup
      - defer:
          task: short
          vars: {D: 1}
      - for: [a, b]
        cmd: Write-Host {{.ITEM}}
      - for:
          var: LIST
          split: ','
          as: NAME
        cmd: Write-Host {{.NAME}}
      - for: sources
        cmd: Write-Host {{.ITEM}}
      - for:
          matrix:
            OS: [windows, linux]
            ARCH: [amd64, arm64]
        cmd: Write-Host {{.ITEM.OS}}/{{.ITEM.ARCH}}
  multi-prompt:
    prompt: [first, second]
    cmds: [Write-Host ok]
  no-silent:
    silent: false
    cmds: [Write-Host ok]
'@
            $script:Taskfile = Import-TestTaskfile $script:Dir
        }

        It 'reads the string shorthand' {
            $task = $script:Taskfile.Tasks['short']
            $task.Task | Should -Be 'short'
            $task.Cmds.Count | Should -Be 1
            $task.Cmds[0].Cmd | Should -Be 'Write-Host short'
        }

        It 'reads the list shorthand' {
            $script:Taskfile.Tasks['list'].Cmds.Cmd | Should -Be @('Write-Host one', 'Write-Host two')
        }

        It 'reads the singular cmd key' {
            $script:Taskfile.Tasks['single'].Cmds.Cmd | Should -Be @('Write-Host single')
        }

        It 'reads scalar task properties' {
            $task = $script:Taskfile.Tasks['full']
            $task.Desc | Should -Be 'Full task'
            $task.Summary | Should -Be "Line one`nLine two`n"
            $task.Aliases | Should -Be @('f', 'complete')
            $task.Label | Should -Be 'full-{{.X}}'
            $task.Prefix | Should -Be 'pre'
            $task.Dir | Should -Be 'sub'
            $task.Silent | Should -BeTrue
            $task.Interactive | Should -BeTrue
            $task.Internal | Should -BeTrue
            $task.IgnoreError | Should -BeTrue
            $task.Run | Should -Be 'when_changed'
            $task.Method | Should -Be 'none'
            $task.Watch | Should -BeTrue
            $task.Failfast | Should -BeTrue
            $task.If | Should -Be 'Test-Path .'
            $task.Prompt | Should -Be @('Continue?')
            $task.Dotenv | Should -Be @('.env')
            $task.Set | Should -Be @('nounset')
            $task.Status | Should -Be @('Test-Path out')
            $task.Vars['X'].Value | Should -Be 1
            $task.Env['Y'].Value | Should -Be 2
            $task.Location.Taskfile | Should -Be (Join-Path $script:Dir 'Taskfile.yml')
            $task.Location.Line | Should -Be 9
            $task.Location.Column | Should -Be 3
        }

        It 'distinguishes an unset silent flag from silent: false' {
            $script:Taskfile.Tasks['short'].Silent | Should -BeNullOrEmpty
            $script:Taskfile.Tasks['no-silent'].Silent | Should -BeFalse
            $script:Taskfile.Tasks['no-silent'].Silent | Should -Not -BeNullOrEmpty
        }

        It 'reads platforms' {
            $platforms = $script:Taskfile.Tasks['full'].Platforms
            $platforms.Count | Should -Be 3
            $platforms[0].OS | Should -Be 'windows'
            $platforms[0].Arch | Should -Be ''
            $platforms[1].OS | Should -Be 'linux'
            $platforms[1].Arch | Should -Be 'amd64'
            $platforms[2].OS | Should -Be ''
            $platforms[2].Arch | Should -Be 'arm64'
        }

        It 'reads sources and generates globs' {
            $task = $script:Taskfile.Tasks['full']
            $task.Sources[0].Glob | Should -Be 'src/**/*.ps1'
            $task.Sources[0].Negate | Should -BeFalse
            $task.Sources[1].Glob | Should -Be 'src/**/*.Tests.ps1'
            $task.Sources[1].Negate | Should -BeTrue
            $task.Generates[0].Glob | Should -Be 'out/*.zip'
        }

        It 'reads preconditions and requires' {
            $task = $script:Taskfile.Tasks['full']
            $task.Preconditions[0].Sh | Should -Be 'Test-Path src'
            $task.Preconditions[0].Msg | Should -Be '`Test-Path src` failed'
            $task.Preconditions[1].Sh | Should -Be 'Test-Path lib'
            $task.Preconditions[1].Msg | Should -Be 'lib is missing'
            $task.Requires[0].Name | Should -Be 'NAME'
            $task.Requires[0].Enum | Should -BeNullOrEmpty
            $task.Requires[1].Name | Should -Be 'MODE'
            $task.Requires[1].Enum | Should -Be @('dev', 'prod')
        }

        It 'reads dependencies' {
            $deps = $script:Taskfile.Tasks['full'].Deps
            $deps.Count | Should -Be 3
            $deps[0].Task | Should -Be 'short'
            $deps[1].Task | Should -Be 'list'
            $deps[1].Vars['A'].Value | Should -Be 'b'
            $deps[1].Silent | Should -BeTrue
            $deps[2].Task | Should -Be 'dep-{{.ITEM}}'
            $deps[2].For.List | Should -Be @('p', 'q')
        }

        It 'reads every command form' {
            $cmds = $script:Taskfile.Tasks['full'].Cmds
            $cmds.Count | Should -Be 9
            $cmds[0].Cmd | Should -Be 'Write-Host plain'
            $cmds[1].Cmd | Should -Be 'Write-Host opts'
            $cmds[1].Silent | Should -BeTrue
            $cmds[1].IgnoreError | Should -BeTrue
            $cmds[1].Platforms[0].OS | Should -Be 'windows'
            $cmds[1].Set | Should -Be @('errexit')
            $cmds[1].If | Should -Be '$true'
            $cmds[2].Task | Should -Be 'short'
            $cmds[2].Vars['K'].Value | Should -Be 'v'
            $cmds[2].Silent | Should -BeTrue
            $cmds[3].Defer | Should -BeTrue
            $cmds[3].Cmd | Should -Be 'Write-Host cleanup'
            $cmds[4].Defer | Should -BeTrue
            $cmds[4].Task | Should -Be 'short'
            $cmds[4].Vars['D'].Value | Should -Be 1
            $cmds[5].For.List | Should -Be @('a', 'b')
            $cmds[5].Cmd | Should -Be 'Write-Host {{.ITEM}}'
            $cmds[6].For.Var | Should -Be 'LIST'
            $cmds[6].For.Split | Should -Be ','
            $cmds[6].For.As | Should -Be 'NAME'
            $cmds[7].For.From | Should -Be 'sources'
            @($cmds[8].For.Matrix.Keys) | Should -Be @('OS', 'ARCH')
            $cmds[8].For.Matrix['OS'].Value | Should -Be @('windows', 'linux')
        }

        It 'reads a list of prompts' {
            $script:Taskfile.Tasks['multi-prompt'].Prompt | Should -Be @('first', 'second')
        }

        It 'converts non-string scalars in commands to strings' {
            $dir = New-TestTaskfile -Content "version: '3'`ntasks:`n  t:`n    cmds: [42, true]"
            (Import-TestTaskfile $dir).Tasks['t'].Cmds.Cmd | Should -BeExactly @('42', 'true')
        }

        It 'rejects an unknown platform' {
            $dir = New-TestTaskfile -Content "version: '3'`ntasks:`n  t:`n    platforms: [beos]`n    cmds: [x]"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*beos*'
        }

        It 'rejects a command without cmd, task or defer' {
            $dir = New-TestTaskfile -Content "version: '3'`ntasks:`n  t:`n    cmds:`n      - silent: true"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*invalid keys in command*'
        }
    }

    Context 'includes' {
        BeforeAll {
            $script:Root = New-TestDirectory
            $null = Set-TestFile -Path (Join-Path $script:Root 'Taskfile.yml') -Content @'
version: '3'
vars:
  ROOT_VAR: root
  SHARED: from-root
includes:
  lib: ./lib
  docs:
    taskfile: ./docs/Docs.yml
    dir: ./docs
    aliases: [d]
    vars: {DOCS_MODE: fast}
    internal: true
  flat:
    taskfile: ./flat.yml
    flatten: true
    excludes: [skipped]
  maybe:
    taskfile: ./does-not-exist.yml
    optional: true
tasks:
  default:
    cmds: [Write-Host root]
  root-task:
    cmds: [Write-Host root-task]
'@
            $null = Set-TestFile -Path (Join-Path $script:Root 'lib' 'Taskfile.yml') -Content @'
version: '3'
vars:
  LIB_VAR: lib
  SHARED: from-lib
includes:
  inner: ./inner.yml
tasks:
  default:
    cmds: [Write-Host lib-default]
  build:
    aliases: [b]
    deps: [prepare, ':root-task']
    cmds:
      - task: prepare
      - task: :root-task
      - Write-Host build
  prepare:
    dir: work
    cmds: [Write-Host prepare]
'@
            $null = Set-TestFile -Path (Join-Path $script:Root 'lib' 'inner.yml') -Content @'
version: '3'
tasks:
  deep:
    cmds: [Write-Host deep]
'@
            $null = Set-TestFile -Path (Join-Path $script:Root 'docs' 'Docs.yml') -Content @'
version: '3'
tasks:
  serve:
    aliases: [s]
    dir: site
    cmds: [Write-Host serve]
'@
            $null = Set-TestFile -Path (Join-Path $script:Root 'flat.yml') -Content @'
version: '3'
tasks:
  flat-task:
    deps: [flat-dep]
    cmds: [Write-Host flat]
  flat-dep:
    cmds: [Write-Host dep]
  skipped:
    cmds: [Write-Host skipped]
'@
            $script:Taskfile = Import-TestTaskfile $script:Root
        }

        It 'namespaces included tasks' {
            @($script:Taskfile.Tasks.Keys) | Should -Be @(
                'default', 'root-task', 'lib:default', 'lib:build', 'lib:prepare', 'lib:inner:deep', 'docs:serve', 'flat-task', 'flat-dep'
            )
        }

        It 'rewrites task references inside included tasks' {
            $build = $script:Taskfile.Tasks['lib:build']
            $build.Task | Should -Be 'lib:build'
            $build.Namespace | Should -Be 'lib'
            $build.Deps.Task | Should -Be @('lib:prepare', 'root-task')
            $build.Cmds[0].Task | Should -Be 'lib:prepare'
            $build.Cmds[1].Task | Should -Be 'root-task'
            $build.Aliases | Should -Be @('lib:b')
        }

        It 'exposes the default task of an include under the namespace name' {
            $script:Taskfile.Tasks['lib:default'].Aliases | Should -Contain 'lib'
        }

        It 'applies namespace aliases' {
            $script:Taskfile.Tasks['docs:serve'].Aliases | Should -Be @('docs:s', 'd:serve', 'd:s')
        }

        It 'marks tasks of an internal include as internal' {
            $script:Taskfile.Tasks['docs:serve'].Internal | Should -BeTrue
            $script:Taskfile.Tasks['lib:build'].Internal | Should -BeFalse
        }

        It 'joins the include dir with the task dir for map-style includes' {
            $script:Taskfile.Tasks['docs:serve'].Dir | Should -Be (Join-Path $script:Root 'docs' 'site')
        }

        It 'keeps the task dir untouched for string-style includes' {
            $script:Taskfile.Tasks['lib:prepare'].Dir | Should -Be 'work'
        }

        It 'records include vars on the task' {
            $script:Taskfile.Tasks['docs:serve'].IncludeVars['DOCS_MODE'].Value | Should -Be 'fast'
        }

        It 'merges global vars of included Taskfiles into the root' {
            $script:Taskfile.Vars['LIB_VAR'].Value | Should -Be 'lib'
            $script:Taskfile.Vars['SHARED'].Value | Should -Be 'from-lib'
            $script:Taskfile.Vars['ROOT_VAR'].Value | Should -Be 'root'
        }

        It 'flattens tasks and honours excludes' {
            $script:Taskfile.Tasks.Contains('flat-task') | Should -BeTrue
            $script:Taskfile.Tasks.Contains('skipped') | Should -BeFalse
            $script:Taskfile.Tasks['flat-task'].Deps.Task | Should -Be @('flat-dep')
        }

        It 'records the defining Taskfile of each task' {
            $script:Taskfile.Tasks['lib:inner:deep'].Location.Taskfile | Should -Be (Join-Path $script:Root 'lib' 'inner.yml')
            $script:Taskfile.Tasks['root-task'].Location.Taskfile | Should -Be (Join-Path $script:Root 'Taskfile.yml')
        }

        It 'fails when a required include is missing' {
            $dir = New-TestTaskfile -Content "version: '3'`nincludes:`n  x: ./missing.yml`ntasks: {}"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*No Taskfile found at*'
        }

        It 'detects include cycles' {
            $dir = New-TestDirectory
            $null = Set-TestFile -Path (Join-Path $dir 'Taskfile.yml') -Content "version: '3'`nincludes:`n  a: ./a.yml`ntasks: {}"
            $null = Set-TestFile -Path (Join-Path $dir 'a.yml') -Content "version: '3'`nincludes:`n  root: ./Taskfile.yml`ntasks: {}"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*include cycle*'
        }

        It 'fails when flattened tasks collide' {
            $dir = New-TestDirectory
            $null = Set-TestFile -Path (Join-Path $dir 'Taskfile.yml') -Content "version: '3'`nincludes:`n  a: {taskfile: ./a.yml, flatten: true}`ntasks:`n  dup: [x]"
            $null = Set-TestFile -Path (Join-Path $dir 'a.yml') -Content "version: '3'`ntasks:`n  dup: [y]"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage '*multiple tasks*'
        }

        It 'rejects dotenv in included Taskfiles' {
            $dir = New-TestDirectory
            $null = Set-TestFile -Path (Join-Path $dir 'Taskfile.yml') -Content "version: '3'`nincludes:`n  a: ./a.yml`ntasks: {}"
            $null = Set-TestFile -Path (Join-Path $dir 'a.yml') -Content "version: '3'`ndotenv: ['.env']`ntasks: {}"
            { Import-TestTaskfile $dir } | Should -Throw -ExpectedMessage "*can't have dotenv*"
        }

        It 'expands templates in include paths' {
            $dir = New-TestDirectory
            $null = Set-TestFile -Path (Join-Path $dir 'Taskfile.yml') -Content "version: '3'`nvars:`n  NAME: part`nincludes:`n  p: ./{{.NAME}}_{{OS}}.yml`ntasks: {}"
            $os = if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }
            $null = Set-TestFile -Path (Join-Path $dir "part_$os.yml") -Content "version: '3'`ntasks:`n  t: [x]"
            (Import-TestTaskfile $dir).Tasks.Contains('p:t') | Should -BeTrue
        }
    }
}
