Describe "Resolve-Dependencies" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        
        # Get the module
        $script:module = Get-Module PS-TaskFile
    }

    Context "When resolving simple dependencies" {
        It "Should resolve single task without dependencies" {
            $tasks = @{
                'build' = @{
                    Cmds = @('echo Building...')
                    DependsOn = $null
                }
            }
            
            $result = & $module { Resolve-Dependencies -TaskName 'build' -Tasks $args[0] } $tasks
            
            $result | Should -HaveCount 1
            $result[0] | Should -Be 'build'
        }

        It "Should resolve task with single dependency" {
            $tasks = @{
                'clean' = @{
                    Cmds = @('echo Cleaning...')
                    DependsOn = $null
                }
                'build' = @{
                    Cmds = @('echo Building...')
                    DependsOn = @('clean')
                }
            }
            
            $result = & $module { Resolve-Dependencies -TaskName 'build' -Tasks $args[0] } $tasks
            
            $result | Should -HaveCount 2
            $result[0] | Should -Be 'clean'
            $result[1] | Should -Be 'build'
        }

        It "Should resolve task with multiple dependencies" {
            $tasks = @{
                'clean' = @{
                    Cmds = @('echo Cleaning...')
                    DependsOn = $null
                }
                'restore' = @{
                    Cmds = @('echo Restoring...')
                    DependsOn = $null
                }
                'build' = @{
                    Cmds = @('echo Building...')
                    DependsOn = @('clean', 'restore')
                }
            }
            
            $result = & $module { Resolve-Dependencies -TaskName 'build' -Tasks $args[0] } $tasks
            
            $result | Should -HaveCount 3
            $result | Should -Contain 'clean'
            $result | Should -Contain 'restore'
            $result[2] | Should -Be 'build'
        }

        It "Should handle nested dependencies" {
            $tasks = @{
                'clean' = @{
                    Cmds = @('echo Cleaning...')
                    DependsOn = $null
                }
                'restore' = @{
                    Cmds = @('echo Restoring...')
                    DependsOn = @('clean')
                }
                'build' = @{
                    Cmds = @('echo Building...')
                    DependsOn = @('restore')
                }
            }
            
            $result = & $module { Resolve-Dependencies -TaskName 'build' -Tasks $args[0] } $tasks
            
            $result | Should -HaveCount 3
            $result[0] | Should -Be 'clean'
            $result[1] | Should -Be 'restore'
            $result[2] | Should -Be 'build'
        }

        It "Should handle task references in commands" {
            $tasks = @{
                'subtask' = @{
                    Cmds = @('echo Subtask...')
                    DependsOn = $null
                }
                'main' = @{
                    Cmds = @(
                        'echo Start',
                        @{ task = 'subtask' },
                        'echo End'
                    )
                    DependsOn = $null
                }
            }
            
            $result = & $module { Resolve-Dependencies -TaskName 'main' -Tasks $args[0] } $tasks
            
            $result | Should -Contain 'subtask'
            $result | Should -Contain 'main'
        }

        It "Should not duplicate tasks in execution order" {
            $tasks = @{
                'common' = @{
                    Cmds = @('echo Common...')
                    DependsOn = $null
                }
                'task1' = @{
                    Cmds = @('echo Task1...')
                    DependsOn = @('common')
                }
                'task2' = @{
                    Cmds = @('echo Task2...')
                    DependsOn = @('common')
                }
                'final' = @{
                    Cmds = @('echo Final...')
                    DependsOn = @('task1', 'task2')
                }
            }
            
            $result = & $module { Resolve-Dependencies -TaskName 'final' -Tasks $args[0] } $tasks
            
            # 'common' should appear only once
            ($result | Where-Object { $_ -eq 'common' }).Count | Should -Be 1
        }
    }

    Context "When handling error cases" {
        It "Should handle non-existent task" {
            $tasks = @{
                'build' = @{
                    Cmds = @('echo Building...')
                    DependsOn = $null
                }
            }
            
            $result = & $module { Resolve-Dependencies -TaskName 'nonexistent' -Tasks $args[0] -ErrorAction SilentlyContinue } $tasks
            
            $result | Should -HaveCount 0
        }
    }
}