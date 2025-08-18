function Resolve-Dependencies {
    param(
        [Parameter(Mandatory=$true)]
        [string]$TaskName,
        [hashtable]$Tasks,
        [System.Collections.Generic.HashSet[string]]$Visited = (New-Object System.Collections.Generic.HashSet[string]),
        [System.Collections.Generic.List[string]]$Sorted = (New-Object System.Collections.Generic.List[string])
    )

    if (-not $Visited.Add($TaskName)) {
        return ,$Sorted
    }

    if (-not $Tasks.ContainsKey($TaskName)) {
        Write-Error "Task '$TaskName' not found."
        return ,$Sorted
    }

    $task = $Tasks[$TaskName]
    if ($task.DependsOn) {
        foreach ($dep in $task.DependsOn) {
            Resolve-Dependencies -TaskName $dep -Tasks $Tasks -Visited $Visited -Sorted $Sorted | Out-Null
        }
    }

    foreach ($cmd in $task.Cmds) {
        if ($cmd -is [hashtable] -and $cmd.ContainsKey("task")) {
            Resolve-Dependencies -TaskName $cmd.task -Tasks $Tasks -Visited $Visited -Sorted $Sorted | Out-Null
        }
    }

    if (-not $Sorted.Contains($TaskName)) {
        $Sorted.Add($TaskName)
    }
    
    return ,$Sorted
}