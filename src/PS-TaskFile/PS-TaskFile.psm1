# PS-TaskFile.psm1

function Import-TasksFromYaml {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
        Install-Module -Name powershell-yaml -Force -Scope CurrentUser
    }
    Import-Module powershell-yaml

    if (-not (Test-Path $Path)) {
        Write-Error "Task file not found: $Path"
        return $null
    }

    $yamlContent = Get-Content -Path $Path -Raw
    $yamlObject = ConvertFrom-Yaml $yamlContent

    $variables = @{}
    if ($yamlObject.ContainsKey("vars")) {
        foreach ($key in $yamlObject.vars.Keys) {
            $value = $yamlObject.vars[$key]
            if ($value -is [hashtable] -and $value.ContainsKey("cmd")) {
                # 動的な値（コマンドの実行）
                $variables[$key] = Invoke-Expression $value.cmd
            } else {
                # 静的な値
                $variables[$key] = $value
            }
        }
    }

    if (-not $yamlObject.ContainsKey("tasks")) {
        Write-Error "No 'tasks' key found in YAML file."
        return $null
    }

    $tasks = @{}
    foreach ($taskName in $yamlObject.tasks.Keys) {
        $taskDef = $yamlObject.tasks[$taskName]
        $tasks[$taskName] = @{
            Cmds = $taskDef.cmds
            DependsOn = $taskDef.depends_on
            Desc = $taskDef.desc
            Dir = $taskDef.dir
        }
    }
    return @{
        Tasks = $tasks
        Variables = $variables
    }
}

function Resolve-Dependencies {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TaskName,
        [hashtable]$Tasks,
        [System.Collections.Generic.HashSet[string]]$Visited = (New-Object System.Collections.Generic.HashSet[string]),
        [System.Collections.Generic.List[string]]$Sorted = (New-Object System.Collections.Generic.List[string])
    )

    if (-not $Visited.Add($TaskName)) {
        return $Sorted
    }

    if (-not $Tasks.ContainsKey($TaskName)) {
        Write-Error "Task '$TaskName' not found."
        return $Sorted
    }

    $task = $Tasks[$TaskName]
    if ($task.DependsOn) {
        foreach ($dep in $task.DependsOn) {
            Resolve-Dependencies -TaskName $dep -Tasks $Tasks -Visited $Visited -Sorted $Sorted
        }
    }

    foreach ($cmd in $task.Cmds) {
        if ($cmd -is [hashtable] -and $cmd.ContainsKey("task")) {
            Resolve-Dependencies -TaskName $cmd.task -Tasks $Tasks -Visited $Visited -Sorted $Sorted
        }
    }

    if (-not $Sorted.Contains($TaskName)) {
        $Sorted.Add($TaskName)
    }
    return $Sorted
}

function Replace-Variables {
    param(
        [string]$Command,
        [hashtable]$Variables
    )
    foreach ($key in $Variables.Keys) {
        $Command = $Command -replace "\`$$key", $Variables[$key]
    }
    return $Command
}

function Show-TaskList {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TaskFile,
        [hashtable]$Tasks,
        [hashtable]$Variables
    )

    Write-Host "task: Available tasks for this script: $TaskFile" -ForegroundColor Cyan

    Write-Host "Variables:" -ForegroundColor Yellow
    foreach ($key in $Variables.Keys) {
        $value = $Variables[$key]
        if ($value -is [string] -and $value.Length -gt 50) {
            $value = $value.Substring(0, 47) + "..."
        }
        Write-Host "  $key = $value" -ForegroundColor DarkGray
    }
    Write-Host ""

    $maxLength = ($Tasks.Keys | Measure-Object -Maximum -Property Length).Maximum

    foreach ($taskName in $Tasks.Keys | Sort-Object) {
        $task = $Tasks[$taskName]
        $desc = if ($task.Desc) { $task.Desc } else { "" }
        $padding = " " * ($maxLength - $taskName.Length + 1)

        Write-Host "* " -ForegroundColor Yellow -NoNewline
        Write-Host "${taskName}:" -ForegroundColor Green -NoNewline
        Write-Host $padding -NoNewline
        Write-Host $desc -ForegroundColor White

        if ($task.Dir) {
            Write-Host "  Directory: $($task.Dir)" -ForegroundColor DarkGray
        }
    }
}

function Prompt-ForExecution {
    param(
        [string]$Command
    )

    Write-Host "Execute command? [Enter] to execute, [S] to skip, [Q] to quit: " -NoNewline -ForegroundColor Yellow
    Write-Host $Command -ForegroundColor Cyan

    while ($true) {
        $key = $host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.VirtualKeyCode) {
            13 { return $true }  # Enter key
            83 { return $false }  # 'S' key
            81 { exit }  # 'Q' key
        }
    }
}

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
                Invoke-Task -Name $taskName -Tasks $tasks -Variables $variables -ExecutedTasks $executedTasks -DryRun:$DryRun -Interactive:$Interactive
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
            Invoke-Task -Name "default" -Tasks $tasks -Variables $variables -ExecutedTasks $executedTasks -DryRun:$DryRun -Interactive:$Interactive
        } else {
            Write-Host "No task specified and no 'default' task found." -ForegroundColor Red
            Show-TaskList -TaskFile $File -Tasks $tasks -Variables $variables
        }
    }
}

Export-ModuleMember -Function Invoke-TaskFile
