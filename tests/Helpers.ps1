# Shared helpers for the test suite. Dot-source from BeforeAll:  . "$PSScriptRoot/Helpers.ps1"

$script:ModuleManifest = Join-Path $PSScriptRoot '..' 'src' 'PSTaskFile' 'PSTaskFile.psd1'
Import-Module $script:ModuleManifest -Force

function Invoke-InModule {
    <# Runs a script block inside the module scope so that private classes and functions are reachable. #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    & (Get-Module PSTaskFile) $ScriptBlock @ArgumentList
}

function New-TestDirectory {
    <# Creates a unique directory below TestDrive and returns its full path. #>
    param([string]$Name = [guid]::NewGuid().ToString('N').Substring(0, 8))
    $path = Join-Path $TestDrive $Name
    $null = New-Item -ItemType Directory -Path $path -Force
    (Get-Item -LiteralPath $path).FullName
}

function Set-TestFile {
    <# Writes a UTF-8 file (creating parent directories) and returns its full path. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [System.IO.File]::WriteAllText($Path, $Content.Replace("`r`n", "`n"))
    (Get-Item -LiteralPath $Path).FullName
}

function New-TestTaskfile {
    <# Creates a directory containing a Taskfile.yml with the given content. Returns the directory. #>
    param([Parameter(Mandatory)][string]$Content, [string]$FileName = 'Taskfile.yml')
    $directory = New-TestDirectory
    $null = Set-TestFile -Path (Join-Path $directory $FileName) -Content $Content
    $directory
}

function Import-TestTaskfile {
    <# Loads a Taskfile (with includes) through the private reader and returns the model. #>
    param([Parameter(Mandatory)][string]$Path)
    $entrypoint = if (Test-Path -LiteralPath $Path -PathType Container) { Join-Path $Path 'Taskfile.yml' } else { $Path }
    Invoke-InModule { param($file) [TaskfileReader]::Load($file, (Split-Path -Parent $file)) } -ArgumentList $entrypoint
}
