Describe "Invoke-TaskFile" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        Import-Module powershell-yaml -Force

        # Create temp directory for test files
        $script:tempDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive "taskfiles")
    }

    Context "When executing tasks from YAML file" {
        It "Should list available tasks with -List switch" {
            $yamlContent = @"
tasks:
  build:
    desc: Build the project
    cmds:
      - echo Building...
  test:
    desc: Run tests
    cmds:
      - echo Testing...
"@
            $testFile = Join-Path $tempDir "list-test.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            $output = Invoke-TaskFile -File $testFile -List 6>&1

            $output | Should -Not -BeNullOrEmpty
        }

        It "Should execute a single task" {
            $yamlContent = @"
tasks:
  hello:
    desc: Say hello
    cmds:
      - echo Hello World
"@
            $testFile = Join-Path $tempDir "single-task.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            Mock Invoke-Expression -ModuleName PS-TaskFile -MockWith { Write-Output "Hello World" }

            Invoke-TaskFile -File $testFile -TaskNames @('hello')

            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 1
        }

        It "Should execute tasks with dependencies in correct order" {
            $yamlContent = @"
tasks:
  clean:
    desc: Clean build artifacts
    cmds:
      - echo Cleaning...
  build:
    desc: Build the project
    depends_on:
      - clean
    cmds:
      - echo Building...
"@
            $testFile = Join-Path $tempDir "dependency-test.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            Mock Invoke-Expression -ModuleName PS-TaskFile

            Invoke-TaskFile -File $testFile -TaskNames @('build')

            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 2
        }

        It "Should show error for non-existent task" {
            $yamlContent = @"
tasks:
  build:
    desc: Build the project
    cmds:
      - echo Building...
"@
            $testFile = Join-Path $tempDir "error-test.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            $output = Invoke-TaskFile -File $testFile -TaskNames @('nonexistent') 2>&1 6>&1

            $outputString = $output -join "`n"
            $outputString | Should -Match "does not exist"
        }

        It "Should execute default task when no task specified" {
            $yamlContent = @"
tasks:
  default:
    desc: Default task
    cmds:
      - echo Default task
"@
            $testFile = Join-Path $tempDir "default-test.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            Mock Invoke-Expression -ModuleName PS-TaskFile

            Invoke-TaskFile -File $testFile

            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 1
        }

        It "Should perform dry run with -DryRun switch" {
            $yamlContent = @"
tasks:
  test:
    desc: Test task
    cmds:
      - echo Testing
"@
            $testFile = Join-Path $tempDir "dryrun-test.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            # Mock should not be invoked in dry run mode
            Mock Invoke-Expression -ModuleName PS-TaskFile

            $output = Invoke-TaskFile -File $testFile -TaskNames @('test') -DryRun 2>&1 6>&1

            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 0
            $outputString = $output -join "`n"
            $outputString | Should -Match "Would execute"
        }

        It "Should handle custom variables" {
            $yamlContent = @"
vars:
  project_name: TestProject
tasks:
  info:
    desc: Show project info
    cmds:
      - echo Project `$project_name
"@
            $testFile = Join-Path $tempDir "vars-test.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            Mock Invoke-Expression -ModuleName PS-TaskFile

            Invoke-TaskFile -File $testFile -TaskNames @('info') -Var @('custom_var=CustomValue')

            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 1
        }

        It "Should handle missing task file gracefully" {
            $output = Invoke-TaskFile -File "nonexistent.yaml" 2>&1 6>&1

            $outputString = $output -join "`n"
            $outputString | Should -Match "Failed to import tasks"
        }

        It "Should output detailed error information and stop execution when command fails" {
            $yamlContent = @"
tasks:
  failing-task:
    desc: Task that fails
    cmds:
      - echo Starting...
      - cmd /c 'exit 1'
      - echo This should not run
"@
            $testFile = Join-Path $tempDir "error-details-test.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            # Execute and capture all output including error details
            { Invoke-TaskFile -File $testFile -TaskNames @('failing-task') } | Should -Throw -ErrorId "*Task execution failed*"
        }

        It "Should not execute subsequent commands when a command fails" {
            $yamlContent = @"
tasks:
  multi-cmd-task:
    desc: Task with multiple commands where one fails
    cmds:
      - echo Command 1
      - cmd /c 'exit 2'
      - echo Command 3 - should not execute
"@
            $testFile = Join-Path $tempDir "stop-on-error-test.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            # Mock to track which commands are executed and simulate failure
            $script:executedCommands = @()
            Mock Invoke-Expression -ModuleName PS-TaskFile -MockWith {
                param($Command)
                $script:executedCommands += $Command
                if ($Command -match "exit 2") {
                    $global:LASTEXITCODE = 2
                    # Simulate a command failure like the real implementation does
                    return
                }
                $global:LASTEXITCODE = 0
            }

            { Invoke-TaskFile -File $testFile -TaskNames @('multi-cmd-task') } | Should -Throw

            # Only the first two commands should have been executed (not the third)
            $script:executedCommands.Count | Should -Be 2
            $script:executedCommands[0] | Should -Match "Command 1"
            $script:executedCommands[1] | Should -Match "exit 2"
        }
    }
}
