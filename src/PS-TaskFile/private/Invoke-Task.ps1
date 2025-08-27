function Invoke-Task {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [hashtable]$Tasks,
        [hashtable]$Variables,
        [hashtable]$ExecutedTasks,
        [switch]$DryRun,
        [switch]$Interactive,
        [string]$TaskFile,
        [System.Collections.ArrayList]$CallStack = $null
    )

    if ($ExecutedTasks.ContainsKey($Name)) {
        return
    }

    $task = $Tasks[$Name]
    $originalLocation = Get-Location
    
    # Initialize call stack if not provided
    if ($null -eq $CallStack) {
        $CallStack = New-Object System.Collections.ArrayList
    }
    
    # Add current task to call stack
    [void]$CallStack.Add($Name)

    if ($DryRun) {
        Write-Host "Would execute task: [$Name]" -ForegroundColor Cyan
        if ($task.Dir) {
            Write-Host "  Would change directory to: $($task.Dir)" -ForegroundColor DarkGray
        }
    } else {
        Write-Verbose "task: [$Name] Starting execution"
        if ($task.Dir) {
            Write-Verbose "task: [$Name] Changing directory to $($task.Dir)"
            Set-Location $task.Dir
        }
    }

    try {
        $cmdIndex = 0
        foreach ($cmd in $task.Cmds) {
            $cmdIndex++
            if ($cmd -is [hashtable] -and $cmd.ContainsKey("task")) {
                if ($DryRun) {
                    Write-Host "  Would execute task: $($cmd.task)" -ForegroundColor DarkCyan
                } else {
                    Write-Host "task: [$Name] Executing task: $($cmd.task)" -ForegroundColor Green
                }
                Invoke-Task -Name $cmd.task -Tasks $Tasks -Variables $Variables -ExecutedTasks $ExecutedTasks -DryRun:$DryRun -Interactive:$Interactive -TaskFile:$TaskFile -CallStack:$CallStack
            } else {
                $resolvedCmd = Replace-Variables -Command $cmd -Variables $Variables
                if ($DryRun) {
                    Write-Host "  Would execute command: $resolvedCmd" -ForegroundColor DarkGray
                } else {
                    if ($Interactive) {
                        $execute = Prompt-ForExecution -Command $resolvedCmd
                        if (-not $execute) {
                            Write-Host "Skipped command: $resolvedCmd" -ForegroundColor Yellow
                            continue
                        }
                    }
                    Write-Host "task: [$Name] $resolvedCmd" -ForegroundColor Green

                    # Execute command and check for errors
                    $eap = $ErrorActionPreference
                    $ErrorActionPreference = "Stop"
                    try {
                        $global:LASTEXITCODE = 0
                        Invoke-Expression $resolvedCmd

                        # Check if command failed based on exit code
                        if ($global:LASTEXITCODE -ne 0) {
                            $errorMessage = "Command failed with exit code $($global:LASTEXITCODE): $resolvedCmd"
                            Write-Error $errorMessage
                            throw $errorMessage
                        }
                    }
                    catch {
                        # Build custom error message with taskfile location
                        $errorLocation = ""
                        if ($task.TaskFile) {
                            $errorLocation = "File: $($task.TaskFile)"
                            if ($task.CmdLineNumbers -and $task.CmdLineNumbers.Count -ge $cmdIndex) {
                                $lineNum = $task.CmdLineNumbers[$cmdIndex - 1]
                                if ($lineNum) {
                                    $errorLocation += ", line $lineNum"
                                }
                            } else {
                                $errorLocation += ", Command #$cmdIndex"
                            }
                        } else {
                            $errorLocation = "Task: $Name, Command #$cmdIndex"
                        }
                        
                        # Build call stack for nested tasks
                        $stackTrace = ""
                        if ($CallStack -and $CallStack.Count -gt 1) {
                            $stackTrace = "`nCall Stack:"
                            for ($i = $CallStack.Count - 1; $i -ge 0; $i--) {
                                $stackTrace += "`n  [$i] $($CallStack[$i])"
                                if ($i -gt 0) {
                                    $stackTrace += " (called from $($CallStack[$i - 1]))"
                                }
                            }
                        }
                        
                        $errorMessage = @"
Task execution failed!

Location: $errorLocation
Command: $resolvedCmd
Error: $($_.Exception.Message)
"@
                        if ($global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) {
                            $errorMessage += "`nExit code: $($global:LASTEXITCODE)"
                        }
                        
                        if ($stackTrace) {
                            $errorMessage += $stackTrace
                        }
                        
                        Write-Error $errorMessage
                        throw $errorMessage
                    }
                    finally {
                        $ErrorActionPreference = $eap
                    }
                }
            }
        }
    }
    finally {
        if (-not $DryRun -and $task.Dir) {
            Write-Verbose "task: [$Name] Returning to original directory"
            Set-Location $originalLocation
        }
    }

    if (-not $DryRun) {
        Write-Verbose "task: [$Name] Completed execution"
    }
    
    # Remove from call stack on successful completion
    if ($CallStack -and $CallStack.Count -gt 0) {
        $CallStack.RemoveAt($CallStack.Count - 1)
    }
    
    $ExecutedTasks[$Name] = $true
}
