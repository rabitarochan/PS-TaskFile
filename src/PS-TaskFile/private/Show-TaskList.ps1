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

    $maxLength = if ($Tasks.Keys.Count -gt 0) {
        ($Tasks.Keys | Measure-Object -Maximum -Property Length).Maximum
    } else {
        0
    }

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