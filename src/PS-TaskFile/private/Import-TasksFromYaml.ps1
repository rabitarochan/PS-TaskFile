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
    $yamlLines = Get-Content -Path $Path
    $yamlObject = ConvertFrom-Yaml $yamlContent

    $variables = @{}
    if ($yamlObject.ContainsKey("vars")) {
        foreach ($key in $yamlObject.vars.Keys) {
            $value = $yamlObject.vars[$key]
            if ($value -is [hashtable] -and $value.ContainsKey("cmd")) {
                # Dynamic value (command execution)
                $variables[$key] = Invoke-Expression $value.cmd
            } else {
                # Static value
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
        
        # Try to find line numbers for commands
        $cmdLineNumbers = @()
        if ($taskDef.cmds) {
            $cmdSearchIndex = 0
            foreach ($cmd in $taskDef.cmds) {
                $lineNum = $null
                # Find the line number for this command in the YAML file
                if ($cmd -is [hashtable] -and $cmd.ContainsKey("task")) {
                    # This is a task reference, find "task: taskname" pattern
                    for ($i = $cmdSearchIndex; $i -lt $yamlLines.Count; $i++) {
                        $line = $yamlLines[$i]
                        if ($line -match "^\s*-\s+task:\s+$($cmd.task)") {
                            $lineNum = $i + 1
                            $cmdSearchIndex = $i + 1
                            break
                        }
                    }
                }
                elseif ($cmd -is [string]) {
                    # Start searching from the last found position to handle duplicate commands
                    for ($i = $cmdSearchIndex; $i -lt $yamlLines.Count; $i++) {
                        $line = $yamlLines[$i]
                        # Simple pattern matching for YAML command lines
                        # Look for lines that start with dash and contain at least part of the command
                        if ($line -match '^\s*-\s+') {
                            # Extract command text after the dash
                            $lineCmd = $line -replace '^\s*-\s+', ''
                            # Remove inline comments if present
                            $lineCmd = $lineCmd -replace '\s*#.*$', ''
                            # Compare trimmed commands
                            if ($lineCmd.Trim() -eq $cmd.Trim()) {
                                $lineNum = $i + 1
                                $cmdSearchIndex = $i + 1
                                break
                            }
                        }
                    }
                }
                $cmdLineNumbers += $lineNum
            }
        }
        
        $tasks[$taskName] = @{
            Cmds = $taskDef.cmds
            DependsOn = $taskDef.depends_on
            Desc = $taskDef.desc
            Dir = $taskDef.dir
            CmdLineNumbers = $cmdLineNumbers
            TaskFile = $Path
        }
    }

    return @{
        Tasks = $tasks
        Variables = $variables
    }
}
