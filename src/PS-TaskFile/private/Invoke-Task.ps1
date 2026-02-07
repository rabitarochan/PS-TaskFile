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
        return $true
    }

    $task = $Tasks[$Name]
    $originalLocation = Get-Location
    $taskFailed = $false
    
    # Initialize call stack if not provided
    if ($null -eq $CallStack) {
        $CallStack = New-Object System.Collections.ArrayList
    }
    
    # Add current task to call stack (only if CallStack is ArrayList)
    if ($null -ne $CallStack -and $CallStack -is [System.Collections.ArrayList]) {
        $null = $CallStack.Add($Name)
    }

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
            if ($taskFailed) {
                break
            }
            
            $cmdIndex++
            if ($cmd -is [hashtable] -and $cmd.ContainsKey("task")) {
                if ($DryRun) {
                    Write-Host "  Would execute task: $($cmd.task)" -ForegroundColor DarkCyan
                } else {
                    Write-Host "task: [$Name] Executing task: $($cmd.task)" -ForegroundColor Green
                }
                
                # Recursively invoke task
                $subResult = Invoke-Task -Name $cmd.task -Tasks $Tasks -Variables $Variables -ExecutedTasks $ExecutedTasks -DryRun:$DryRun -Interactive:$Interactive -TaskFile:$TaskFile -CallStack:$CallStack
                
                # Check if sub-task failed
                if ($subResult -eq $false) {
                    $taskFailed = $true
                    break
                }
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
                        Invoke-Expression $resolvedCmd | Out-Host

                        # Check if command failed based on exit code
                        if ($global:LASTEXITCODE -ne 0) {
                            $errorMessage = "Command failed with exit code $($global:LASTEXITCODE): $resolvedCmd"
                            throw $errorMessage
                        }
                    }
                    catch {
                        # Get line number and error message
                        $lineNum = 0
                        if ($task.CmdLineNumbers -and $task.CmdLineNumbers.Count -ge $cmdIndex) {
                            $lineNum = $task.CmdLineNumbers[$cmdIndex - 1]
                        }
                        
                        # Prepare error message
                        $errorMsg = $_.Exception.Message
                        if ($global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) {
                            if ($errorMsg -notlike "*exit code*") {
                                $errorMsg = "Command failed with exit code $($global:LASTEXITCODE)"
                            }
                        }
                        
                        # Use Write-TaskFileStackTrace if TaskFile is provided
                        if ($TaskFile -and $lineNum -gt 0) {
                            Write-TaskFileStackTrace -TaskFile $TaskFile -Line $lineNum -Command $resolvedCmd -ErrorMessage $errorMsg
                        } else {
                            # Fallback error handling for backward compatibility
                            $errorLocation = ""
                            if ($task.TaskFile) {
                                $errorLocation = "File: $($task.TaskFile)"
                                if ($lineNum -gt 0) {
                                    $errorLocation += ", line $lineNum"
                                } else {
                                    $errorLocation += ", Command #$cmdIndex"
                                }
                            } else {
                                $errorLocation = "Task: $Name, Command #$cmdIndex"
                            }
                            
                            # Build call stack for nested tasks
                            $stackTrace = ""
                            if ($CallStack -and ($CallStack -is [System.Collections.ArrayList]) -and $CallStack.Count -gt 1) {
                                $stackTrace = "`nCall Stack:"
                                for ($i = $CallStack.Count - 1; $i -ge 0; $i--) {
                                    $stackTrace += "`n  [$i] $($CallStack[$i])"
                                    if ($i -gt 0) {
                                        $stackTrace += " (called from $($CallStack[$i - 1]))"
                                    }
                                }
                            }
                            
                            $fullErrorMessage = @"
Task execution failed!

Location: $errorLocation
Command: $resolvedCmd
Error: $errorMsg
"@
                            
                            if ($stackTrace) {
                                $fullErrorMessage += $stackTrace
                            }
                            
                            Write-Host $fullErrorMessage -ForegroundColor Red
                        }
                        
                        # Set exit code for PowerShell errors (external commands already set $LASTEXITCODE)
                        if ($global:LASTEXITCODE -eq 0) {
                            $global:LASTEXITCODE = 1
                        }

                        # Mark task as failed and stop processing
                        $taskFailed = $true
                        break
                    }
                    finally {
                        $ErrorActionPreference = $eap
                    }
                }
            }
        }
    }
    catch {
        # Handle internal PS-TaskFile errors as FATAL
        Write-Host "[FATAL] Internal PS-TaskFile error occurred" -ForegroundColor Magenta
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Magenta
        if ($_.Exception.StackTrace) {
            Write-Host "Stack Trace:" -ForegroundColor Magenta
            Write-Host $_.Exception.StackTrace -ForegroundColor DarkGray
        }
        $taskFailed = $true
    }
    finally {
        if (-not $DryRun -and $task.Dir) {
            Write-Verbose "task: [$Name] Returning to original directory"
            Set-Location $originalLocation
        }
    }

    if (-not $DryRun -and -not $taskFailed) {
        Write-Verbose "task: [$Name] Completed execution"
    }
    
    # Remove from call stack on completion
    if ($CallStack -and ($CallStack -is [System.Collections.ArrayList]) -and $CallStack.Count -gt 0) {
        $CallStack.RemoveAt($CallStack.Count - 1)
    }
    
    # Only mark as executed if task succeeded
    if (-not $taskFailed) {
        $ExecutedTasks[$Name] = $true
        return $true
    } else {
        return $false
    }
}