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
            
            # Execute and expect detailed error with line info
            try {
                & $module { 
                    Invoke-Task -Name 'test-task' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -TaskFile $args[3]
                } $tasks $variables $executedTasks $testFile
                
                # Should not reach here
                $false | Should -BeTrue -Because "An error should have been thrown"
            }
            catch {
                # Error message should contain taskfile location info
                $_.Exception.Message | Should -Match "error-location.yaml"
                $_.Exception.Message | Should -Match "line 7"
                $_.Exception.Message | Should -Match "Remove-Item"
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
            
            try {
                & $module { 
                    Invoke-Task -Name 'main-task' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -TaskFile $args[3]
                } $tasks $variables $executedTasks $testFile
                
                $false | Should -BeTrue -Because "An error should have been thrown"
            }
            catch {
                # Should show task call hierarchy
                $_.Exception.Message | Should -Match "sub-task"
                $_.Exception.Message | Should -Match "line 13"
                $_.Exception.Message | Should -Match "called from main-task"
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
            
            try {
                & $module { 
                    Invoke-Task -Name 'dynamic-task' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2]
                } $tasks $variables $executedTasks
                
                $false | Should -BeTrue -Because "An error should have been thrown"
            }
            catch {
                # Should show command index when no file info
                $_.Exception.Message | Should -Match "Command #2"
                $_.Exception.Message | Should -Match "Remove-Item"
            }
        }
    }
}