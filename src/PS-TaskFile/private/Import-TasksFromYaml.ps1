function Import-TasksFromYaml {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    # Ensure the required module is imported
    Import-Module powershell-yaml -ErrorAction Stop

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