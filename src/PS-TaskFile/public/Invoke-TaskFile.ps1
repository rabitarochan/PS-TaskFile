function Invoke-TaskFile {
    [CmdletBinding()]
    param(
        [Parameter(Position=0)]
        [string[]]$TaskNames,

        [Parameter()]
        [switch]$List,

        [Parameter()]
        [string]$File = "tasks.yaml",

        [Parameter()]
        [switch]$DryRun,

        [Parameter()]
        [switch]$Interactive,

        [Parameter()]
        [string[]]$Var
    )

    $importedData = Import-TasksFromYaml -Path $File
    if ($null -eq $importedData) {
        Write-Error "Failed to import tasks from $File"
        return
    }

    $tasks = $importedData.Tasks
    $variables = $importedData.Variables

    # コマンドライン引数で指定された変数を処理
    foreach ($varArg in $Var) {
        if ($varArg -match '^(.+?)=(.*)$') {
            $key = $matches[1]
            $value = $matches[2]
            $variables[$key] = $value
        }
        else {
            Write-Warning "Invalid variable format: $varArg. Expected format: name=value"
        }
    }

    if ($List) {
        Show-TaskList -TaskFile $File -Tasks $tasks -Variables $variables
    }
    elseif ($TaskNames.Count -gt 0) {
        $allTasksExist = $true
        foreach ($taskName in $TaskNames) {
            if (-not $tasks.ContainsKey($taskName)) {
                $allTasksExist = $false
                Show-TaskList -TaskFile $File -Tasks $tasks -Variables $variables
                Write-Host "task: Task `"$taskName`" does not exist" -ForegroundColor Red
                break
            }
        }
        if ($allTasksExist) {
            $executedTasks = @{}
            foreach ($taskName in $TaskNames) {
                $executionOrder = Resolve-Dependencies -TaskName $taskName -Tasks $tasks
                if ($DryRun) {
                    Write-Host "Execution order for task '$taskName': $($executionOrder -join ' -> ')" -ForegroundColor Magenta
                } else {
                    Write-Verbose "Execution order: $($executionOrder -join ' -> ')"
                }
                foreach ($task in $executionOrder) {
                    Invoke-Task -Name $task -Tasks $tasks -Variables $variables -ExecutedTasks $executedTasks -DryRun:$DryRun -Interactive:$Interactive
                }
            }
        }
    } else {
        if ($tasks.ContainsKey("default")) {
            $executionOrder = Resolve-Dependencies -TaskName "default" -Tasks $tasks
            if ($DryRun) {
                Write-Host "Execution order for default task: $($executionOrder -join ' -> ')" -ForegroundColor Magenta
            } else {
                Write-Verbose "Execution order: $($executionOrder -join ' -> ')"
            }
            $executedTasks = @{}
            foreach ($task in $executionOrder) {
                Invoke-Task -Name $task -Tasks $tasks -Variables $variables -ExecutedTasks $executedTasks -DryRun:$DryRun -Interactive:$Interactive
            }
        } else {
            Write-Host "No task specified and no 'default' task found." -ForegroundColor Red
            Show-TaskList -TaskFile $File -Tasks $tasks -Variables $variables
        }
    }
}