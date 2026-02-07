Describe "Invoke-Task Error Tracing" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        
        # Get the module
        $script:module = Get-Module PS-TaskFile
        
        # Create test taskfile with specific line numbers
        $script:tempDir = New-Item -ItemType Directory -Path (Join-Path $TestDrive "error-trace-test")
    }
    
    Context "When command errors occur" {
        It "Should report taskfile location in error message" {
            # Create a test taskfile with specific line numbers
            $yamlContent = @"
# Line 1
tasks:
  test-task:
    desc: Test task with error
    cmds:
      - echo "Starting task"       # Line 6
      - Remove-Item C:\NonExistent\File.txt -Force  # Line 7 - This will error
      - echo "This should not run" # Line 8
"@
            $testFile = Join-Path $tempDir "error-location.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            # Import tasks
            $importedData = & $module { Import-TasksFromYaml -Path $args[0] } $testFile
            $tasks = $importedData.Tasks
            $variables = $importedData.Variables
            $executedTasks = @{}

            # Mock Write-TaskFileStackTrace to verify it's called correctly
            Mock Write-TaskFileStackTrace {} -ModuleName PS-TaskFile

            # Invoke-Task catches errors internally and returns $false
            $result = & $module {
                Invoke-Task -Name 'test-task' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -TaskFile $args[3]
            } $tasks $variables $executedTasks $testFile

            $result | Should -Be $false

            Should -Invoke Write-TaskFileStackTrace -ModuleName PS-TaskFile -Times 1 -ParameterFilter {
                $ErrorMessage -match "Cannot find path"
            }
        }
        
        It "Should show custom stack trace for nested task calls" {
            $yamlContent = @"
tasks:
  main-task:
    desc: Main task
    cmds:
      - echo "Main task start"     # Line 5
      - task: sub-task              # Line 6
      - echo "Main task end"        # Line 7

  sub-task:
    desc: Sub task with error
    cmds:
      - echo "Sub task start"       # Line 12
      - Get-Item C:\Fake\Path.txt   # Line 13 - This will error
      - echo "Sub task end"         # Line 14
"@
            $testFile = Join-Path $tempDir "nested-error.yaml"
            Set-Content -Path $testFile -Value $yamlContent

            $importedData = & $module { Import-TasksFromYaml -Path $args[0] } $testFile
            $tasks = $importedData.Tasks
            $variables = $importedData.Variables
            $executedTasks = @{}

            # Mock Write-TaskFileStackTrace to verify it's called correctly
            Mock Write-TaskFileStackTrace {} -ModuleName PS-TaskFile

            # Sub-task fails, parent detects and returns $false
            $result = & $module {
                Invoke-Task -Name 'main-task' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -TaskFile $args[3]
            } $tasks $variables $executedTasks $testFile

            $result | Should -Be $false

            Should -Invoke Write-TaskFileStackTrace -ModuleName PS-TaskFile -Times 1 -ParameterFilter {
                $ErrorMessage -match "Cannot find path"
            }
        }
        
        It "Should show command index when line numbers are not available" {
            # When tasks are created programmatically without file info
            $tasks = @{
                'dynamic-task' = @{
                    Cmds = @(
                        'echo First command',
                        'Remove-Item C:\Fake\Item.txt',  # This will error
                        'echo Third command'
                    )
                    DependsOn = $null
                    Desc = 'Dynamic task'
                }
            }
            $variables = @{}
            $executedTasks = @{}

            # Mock Write-Host to verify fallback error output
            Mock Write-Host {} -ModuleName PS-TaskFile

            # No TaskFile parameter, so fallback error handling uses Write-Host
            $result = & $module {
                Invoke-Task -Name 'dynamic-task' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2]
            } $tasks $variables $executedTasks

            $result | Should -Be $false

            Should -Invoke Write-Host -ModuleName PS-TaskFile -Times 1 -ParameterFilter {
                $Object -match "Command #2" -and $Object -match "Remove-Item"
            }
        }
    }
}