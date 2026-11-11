# Shared helpers for the test suite. Dot-source from BeforeAll:  . "$PSScriptRoot/Helpers.ps1"

$script:ModuleManifest = Join-Path $PSScriptRoot '..' 'src' 'PS-TaskFile' 'PS-TaskFile.psd1'
Import-Module $script:ModuleManifest -Force

function Invoke-InModule {
    <# Runs a script block inside the module scope so that private classes and functions are reachable. #>
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$ArgumentList = @())
    & (Get-Module PS-TaskFile) $ScriptBlock @ArgumentList
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

function ConvertTo-TestLine {
    <# Renders one record emitted by Invoke-Task -PassThru as text. #>
    param([AllowNull()]$Record)
    if ($null -eq $Record) { return '' }
    if ($Record -is [System.Management.Automation.ErrorRecord]) { return "ERROR: $($Record.Exception.Message)" }
    if ($Record -is [System.Management.Automation.WarningRecord]) { return "WARNING: $($Record.Message)" }
    if ($Record -is [System.Management.Automation.VerboseRecord]) { return "VERBOSE: $($Record.Message)" }
    if ($Record -is [System.Management.Automation.DebugRecord]) { return "DEBUG: $($Record.Message)" }
    return "$Record"
}

function Invoke-TestTask {
    <#
        Runs Invoke-Task -PassThru and captures everything it emits (all streams, in order).
        Returns Lines (text), Text (joined), Records (raw), Output (objects that are not log
        records), Error (the terminating error, if any) and ExitCode ($LASTEXITCODE).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Directory,
        [Parameter(Position = 1)][string[]]$Name,
        [hashtable]$With = @{}
    )
    $records = [System.Collections.Generic.List[object]]::new()
    $failure = $null
    $parameters = @{ Directory = $Directory; PassThru = $true; ErrorAction = 'Continue' }
    foreach ($key in $With.Keys) { $parameters[$key] = $With[$key] }
    if ($Name) { $parameters['Name'] = $Name }
    $global:LASTEXITCODE = 0
    try { Invoke-Task @parameters *>&1 | ForEach-Object { $records.Add($_) } }
    catch { $failure = $_ }
    $lines = @(foreach ($record in $records) { ConvertTo-TestLine $record })
    $output = @($records | Where-Object {
            $_ -isnot [System.Management.Automation.InformationRecord] -and $_ -isnot [System.Management.Automation.ErrorRecord] -and
            $_ -isnot [System.Management.Automation.WarningRecord] -and $_ -isnot [System.Management.Automation.VerboseRecord]
        })
    [pscustomobject]@{
        Records  = $records
        Lines    = $lines
        Text     = $lines -join "`n"
        Output   = $output
        Error    = $failure
        ExitCode = $global:LASTEXITCODE
    }
}
