Describe "Invoke-Task" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        
        # Get the module
        $script:module = Get-Module PS-TaskFile
        
        # Mock Invoke-Expression for testing
        Mock Invoke-Expression -ModuleName PS-TaskFile
    }

    Context "When executing simple tasks" {
        It "Should execute a task with single command" {
            $tasks = @{
                'simple' = @{
                    Cmds = @('echo Test')
                    DependsOn = $null
                }
            }
            $variables = @{}
            $executedTasks = @{}
            
            & $module { Invoke-Task -Name 'simple' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] } $tasks $variables $executedTasks
            
            $executedTasks['simple'] | Should -BeTrue
            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 1
        }

        It "Should execute a task with multiple commands" {
            $tasks = @{
                'multi' = @{
                    Cmds = @('echo First', 'echo Second', 'echo Third')
                    DependsOn = $null
                }
            }
            $variables = @{}
            $executedTasks = @{}
            
            & $module { Invoke-Task -Name 'multi' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] } $tasks $variables $executedTasks
            
            $executedTasks['multi'] | Should -BeTrue
            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 3
        }

        It "Should not execute already executed tasks" {
            $tasks = @{
                'once' = @{
                    Cmds = @('echo Once')
                    DependsOn = $null
                }
            }
            $variables = @{}
            $executedTasks = @{ 'once' = $true }
            
            & $module { Invoke-Task -Name 'once' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] } $tasks $variables $executedTasks
            
            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 0
        }

        It "Should handle task with directory change" {
            $tasks = @{
                'withDir' = @{
                    Cmds = @('echo InDir')
                    Dir = './test'
                    DependsOn = $null
                }
            }
            $variables = @{}
            $executedTasks = @{}
            
            Mock Set-Location -ModuleName PS-TaskFile
            Mock Get-Location -ModuleName PS-TaskFile -MockWith { [PSCustomObject]@{ Path = 'C:\original' } }
            
            & $module { Invoke-Task -Name 'withDir' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] } $tasks $variables $executedTasks
            
            Should -Invoke Set-Location -ModuleName PS-TaskFile -Times 2
        }

        It "Should execute nested task references" {
            $tasks = @{
                'subtask' = @{
                    Cmds = @('echo Subtask')
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
            $variables = @{}
            $executedTasks = @{}
            
            & $module { Invoke-Task -Name 'main' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] } $tasks $variables $executedTasks
            
            $executedTasks['main'] | Should -BeTrue
            $executedTasks['subtask'] | Should -BeTrue
            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 3
        }
    }

    Context "When using DryRun mode" {
        It "Should not execute commands in DryRun mode" {
            $tasks = @{
                'dryrun' = @{
                    Cmds = @('echo DryRun')
                    DependsOn = $null
                }
            }
            $variables = @{}
            $executedTasks = @{}
            
            & $module { Invoke-Task -Name 'dryrun' -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -DryRun } $tasks $variables $executedTasks
            
            $executedTasks['dryrun'] | Should -BeTrue
            Should -Invoke Invoke-Expression -ModuleName PS-TaskFile -Times 0
        }
    }
}