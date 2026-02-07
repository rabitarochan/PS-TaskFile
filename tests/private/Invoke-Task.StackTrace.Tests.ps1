BeforeAll {
    $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
    Import-Module $modulePath -Force

    $script:module = Get-Module PS-TaskFile

    Mock Write-Host {} -ModuleName PS-TaskFile
}

Describe "Invoke-Task with Write-TaskFileStackTrace" {
    Context "When a command fails" {

        It "Should call Write-TaskFileStackTrace when command fails" {
            $tasks = @{
                "fail-task" = @{
                    Cmds = @(
                        "Write-Output 'Starting task'"
                        "cmd /c 'exit 1'"
                    )
                    TaskFile = "TestTaskFile.yaml"
                    CmdLineNumbers = @(10, 11)
                }
            }

            $variables = @{}
            $executedTasks = @{}

            Mock Write-TaskFileStackTrace {} -ModuleName PS-TaskFile

            $result = & $module {
                Invoke-Task -Name "fail-task" -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -TaskFile $args[3]
            } $tasks $variables $executedTasks "TestTaskFile.yaml"

            $result | Should -Be $false

            Should -Invoke Write-TaskFileStackTrace -ModuleName PS-TaskFile -Times 1 -ParameterFilter {
                $TaskFile -eq "TestTaskFile.yaml" -and
                $Line -eq 11 -and
                $Command -eq "cmd /c 'exit 1'" -and
                $ErrorMessage -like "*exit code 1*"
            }
        }

        It "Should provide correct stack trace for nested tasks" {
            $tasks = @{
                "parent-task" = @{
                    Cmds = @(
                        @{ task = "child-task" }
                    )
                    TaskFile = "TestTaskFile.yaml"
                    CmdLineNumbers = @(5)
                }
                "child-task" = @{
                    Cmds = @(
                        "Write-Output 'Child task'"
                        "throw 'Child task error'"
                    )
                    TaskFile = "TestTaskFile.yaml"
                    CmdLineNumbers = @(20, 21)
                }
            }

            Mock Write-TaskFileStackTrace {} -ModuleName PS-TaskFile

            $variables = @{}
            $executedTasks = @{}

            $result = & $module {
                Invoke-Task -Name "parent-task" -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -TaskFile $args[3]
            } $tasks $variables $executedTasks "TestTaskFile.yaml"

            $result | Should -Be $false

            Should -Invoke Write-TaskFileStackTrace -ModuleName PS-TaskFile -Times 1 -ParameterFilter {
                $TaskFile -eq "TestTaskFile.yaml" -and
                $Line -eq 21 -and
                $Command -eq "throw 'Child task error'" -and
                $ErrorMessage -like "*Child task error*"
            }
        }

        It "Should handle PowerShell exceptions with stack trace" {
            $tasks = @{
                "ps-error-task" = @{
                    Cmds = @(
                        'throw "null value encountered"'
                    )
                    TaskFile = "TestTaskFile.yaml"
                    CmdLineNumbers = @(30)
                }
            }

            Mock Write-TaskFileStackTrace {} -ModuleName PS-TaskFile

            $variables = @{}
            $executedTasks = @{}

            $result = & $module {
                Invoke-Task -Name "ps-error-task" -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -TaskFile $args[3]
            } $tasks $variables $executedTasks "TestTaskFile.yaml"

            $result | Should -Be $false

            Should -Invoke Write-TaskFileStackTrace -ModuleName PS-TaskFile -Times 1 -ParameterFilter {
                $TaskFile -eq "TestTaskFile.yaml" -and
                $Line -eq 30 -and
                $Command -eq 'throw "null value encountered"' -and
                $ErrorMessage -match "null"
            }
        }
    }

    Context "When DryRun is enabled" {
        It "Should not call Write-TaskFileStackTrace in dry run mode" {
            $tasks = @{
                "test-task" = @{
                    Cmds = @("throw 'should not run'")
                    TaskFile = "TestTaskFile.yaml"
                    CmdLineNumbers = @(40)
                }
            }

            Mock Write-TaskFileStackTrace {} -ModuleName PS-TaskFile

            & $module {
                Invoke-Task -Name "test-task" -Tasks $args[0] -Variables $args[1] -ExecutedTasks $args[2] -DryRun -TaskFile $args[3]
            } $tasks @{} @{} "TestTaskFile.yaml"

            Should -Not -Invoke Write-TaskFileStackTrace -ModuleName PS-TaskFile
        }
    }
}
