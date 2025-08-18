Describe "Import-TasksFromYaml" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        Import-Module powershell-yaml -Force
        
        # Get the module
        $script:module = Get-Module PS-TaskFile
        
        # Create temp directory for test files
        $script:tempDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive "taskfiles")
    }

    Context "When importing valid YAML file" {
        It "Should import tasks without variables" {
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
            $testFile = Join-Path $tempDir "simple.yaml"
            Set-Content -Path $testFile -Value $yamlContent
            
            $result = & $module { Import-TasksFromYaml -Path $args[0] } $testFile
            
            $result | Should -Not -BeNullOrEmpty
            $result.Tasks | Should -Not -BeNullOrEmpty
            $result.Tasks.Count | Should -Be 2
            $result.Tasks['build'].Desc | Should -Be 'Build the project'
            $result.Tasks['test'].Desc | Should -Be 'Run tests'
        }

        It "Should import tasks with static variables" {
            $yamlContent = @"
vars:
  name: TestProject
  version: 1.0.0
tasks:
  info:
    desc: Show project info
    cmds:
      - echo Project `$name version `$version
"@
            $testFile = Join-Path $tempDir "with-vars.yaml"
            Set-Content -Path $testFile -Value $yamlContent
            
            $result = & $module { Import-TasksFromYaml -Path $args[0] } $testFile
            
            $result.Variables['name'] | Should -Be 'TestProject'
            $result.Variables['version'] | Should -Be '1.0.0'
        }

        It "Should import tasks with dependencies" {
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
            $testFile = Join-Path $tempDir "with-deps.yaml"
            Set-Content -Path $testFile -Value $yamlContent
            
            $result = & $module { Import-TasksFromYaml -Path $args[0] } $testFile
            
            $result.Tasks['build'].DependsOn | Should -Contain 'clean'
        }

        It "Should import tasks with directory" {
            $yamlContent = @"
tasks:
  build:
    desc: Build in specific directory
    dir: ./src
    cmds:
      - echo Building...
"@
            $testFile = Join-Path $tempDir "with-dir.yaml"
            Set-Content -Path $testFile -Value $yamlContent
            
            $result = & $module { Import-TasksFromYaml -Path $args[0] } $testFile
            
            $result.Tasks['build'].Dir | Should -Be './src'
        }
    }

    Context "When importing invalid YAML file" {
        It "Should return null for non-existent file" {
            $testFile = Join-Path $tempDir "nonexistent.yaml"
            
            $result = & $module { Import-TasksFromYaml -Path $args[0] -ErrorAction SilentlyContinue } $testFile
            
            $result | Should -BeNullOrEmpty
        }

        It "Should return null for YAML without tasks section" {
            $yamlContent = @"
vars:
  name: TestProject
"@
            $testFile = Join-Path $tempDir "no-tasks.yaml"
            Set-Content -Path $testFile -Value $yamlContent
            
            $result = & $module { Import-TasksFromYaml -Path $args[0] -ErrorAction SilentlyContinue } $testFile
            
            $result | Should -BeNullOrEmpty
        }
    }
}