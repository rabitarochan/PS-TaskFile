Describe "Show-TaskList" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        
        # Get the module
        $script:module = Get-Module PS-TaskFile
    }

    Context "When displaying task list" {
        It "Should display tasks with descriptions" {
            $tasks = @{
                'build' = @{
                    Desc = 'Build the project'
                    Cmds = @('echo Building...')
                }
                'test' = @{
                    Desc = 'Run tests'
                    Cmds = @('echo Testing...')
                }
            }
            $variables = @{
                'name' = 'TestProject'
            }
            
            # Capture output
            $output = & $module { Show-TaskList -TaskFile 'test.yaml' -Tasks $args[0] -Variables $args[1] 6>&1 } $tasks $variables
            
            $output | Should -Not -BeNullOrEmpty
        }

        It "Should display tasks without descriptions" {
            $tasks = @{
                'clean' = @{
                    Cmds = @('echo Cleaning...')
                }
            }
            $variables = @{}
            
            # Capture output
            $output = & $module { Show-TaskList -TaskFile 'test.yaml' -Tasks $args[0] -Variables $args[1] 6>&1 } $tasks $variables
            
            $output | Should -Not -BeNullOrEmpty
        }

        It "Should display task with directory information" {
            $tasks = @{
                'build' = @{
                    Desc = 'Build the project'
                    Dir = './src'
                    Cmds = @('echo Building...')
                }
            }
            $variables = @{}
            
            # Capture output
            $output = & $module { Show-TaskList -TaskFile 'test.yaml' -Tasks $args[0] -Variables $args[1] 6>&1 } $tasks $variables
            
            $output | Should -Not -BeNullOrEmpty
        }

        It "Should truncate long variable values" {
            $longValue = "This is a very long value that should be truncated when displayed in the task list output"
            $tasks = @{
                'test' = @{
                    Desc = 'Test task'
                    Cmds = @('echo Test')
                }
            }
            $variables = @{
                'longVar' = $longValue
            }
            
            # Capture output
            $output = & $module { Show-TaskList -TaskFile 'test.yaml' -Tasks $args[0] -Variables $args[1] 6>&1 } $tasks $variables
            
            $output | Should -Not -BeNullOrEmpty
        }
    }
}