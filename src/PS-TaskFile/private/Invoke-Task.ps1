function Invoke-Task {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Name,
        [hashtable]$Tasks,
        [hashtable]$Variables,
        [hashtable]$ExecutedTasks,
        [switch]$DryRun,
        [switch]$Interactive
    )

    if ($ExecutedTasks.ContainsKey($Name)) {
        return
    }

    $task = $Tasks[$Name]
    $originalLocation = Get-Location

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
        foreach ($cmd in $task.Cmds) {
            if ($cmd -is [hashtable] -and $cmd.ContainsKey("task")) {
                if ($DryRun) {
                    Write-Host "  Would execute task: $($cmd.task)" -ForegroundColor DarkCyan
                } else {
                    Write-Host "task: [$Name] Executing task: $($cmd.task)" -ForegroundColor Green
                }
                Invoke-Task -Name $cmd.task -Tasks $Tasks -Variables $Variables -ExecutedTasks $ExecutedTasks -DryRun:$DryRun -Interactive:$Interactive
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
                    Invoke-Expression $resolvedCmd
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
    $ExecutedTasks[$Name] = $true
}