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
    }
}