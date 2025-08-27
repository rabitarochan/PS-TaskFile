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
