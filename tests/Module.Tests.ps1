BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'src' 'PS-TaskFile' 'PS-TaskFile.psd1'
    Import-Module $script:ManifestPath -Force
}

Describe 'PS-TaskFile module' {
    It 'has a valid manifest' {
        $manifest = Test-ModuleManifest -Path $script:ManifestPath
        $manifest.Name | Should -Be 'PS-TaskFile'
        $manifest.PowerShellVersion | Should -Be ([version]'7.4')
    }

    It 'imports without errors' {
        Get-Module PS-TaskFile | Should -Not -BeNullOrEmpty
    }

    # PowerShell cannot replace the classes of a loaded module: after an update the new classes
    # call old ones. A child process, because the state belongs to the process.
    It 'refuses to run once its files changed after it was loaded into the session' {
        $copy = Join-Path $TestDrive 'module-copy'
        Copy-Item -LiteralPath (Split-Path -Parent $script:ManifestPath) -Destination $copy -Recurse
        $manifest = Join-Path $copy 'PS-TaskFile.psd1'
        $changedFile = Join-Path $copy 'Private' 'Output.ps1'
        $directory = Join-Path $TestDrive 'module-changed'
        $null = New-Item -ItemType Directory -Path $directory
        Set-Content -LiteralPath (Join-Path $directory 'Taskfile.yml') -Value @'
version: '3'
tasks:
  default:
    silent: true
    cmds:
      - Write-Output ran
'@
        $script = Join-Path $TestDrive 'module-changed.ps1'
        Set-Content -LiteralPath $script -Value @"
`$ErrorActionPreference = 'Continue'
Import-Module '$manifest'
Invoke-Task -Directory '$directory' -PassThru
(Get-Item -LiteralPath '$changedFile').LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(5)
try { Invoke-Task -Directory '$directory' -PassThru } catch { "run: `$(`$_.Exception.Message)" }
"exit code: `$LASTEXITCODE"
try { Import-Module '$manifest' -Force -ErrorAction Stop } catch { "import: `$(`$_.Exception.Message)" }
"@
        $lines = @(& pwsh -NoProfile -NonInteractive -File $script 2>&1 | ForEach-Object { "$_".TrimEnd() } | Where-Object { $_ -ne '' })
        $lines.Count | Should -Be 4 -Because ($lines -join ' / ')
        $lines[0] | Should -Be 'ran'
        $lines[1] | Should -BeLike 'run: task: the files of the PS-TaskFile module changed*start a new PowerShell session.'
        $lines[2] | Should -Be 'exit code: 1'
        $lines[3] | Should -BeLike 'import: *the files of the PS-TaskFile module changed*start a new PowerShell session.'
    }
}
