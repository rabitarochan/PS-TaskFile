function Write-TaskFileStackTrace {
    param(
        [string]$TaskFile,
        [int]$Line,
        [string]$Command,
        [string]$ErrorMessage
    )

    # Line 1
    Write-Host "[ERROR] Task execution failed: " -ForegroundColor Red -NoNewline
    Write-Host $TaskFile

    # Line 2
    Write-Host "  Line |" -ForegroundColor Cyan

    # Line 3
    Write-Host "  $($Line.ToString().PadLeft(4)) |   $Command" -ForegroundColor Cyan

    # Line 4
    Write-Host "       |   " -ForegroundColor Cyan -NoNewline
    $CommandStringWidth = Get-DisplayWidth -InputString $Command
    Write-Host ("~" * $CommandStringWidth) -ForegroundColor Red

    # Line 5
    Write-Host "       | " -ForegroundColor Cyan -NoNewline
    Write-Host $ErrorMessage -ForegroundColor Red
}
