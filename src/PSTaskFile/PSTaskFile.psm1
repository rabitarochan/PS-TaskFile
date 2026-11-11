#Requires -Version 7.4
Set-StrictMode -Version 3.0

# Path of this file. Engine runspaces import the .psm1 directly (see Private/Host.ps1).
$script:ModuleFile = $PSCommandPath
$script:ModuleVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'PSTaskFile.psd1')).ModuleVersion

# PowerShell cannot replace the classes of a module that a process has already loaded: when
# the files change (an update, a checkout), newly loaded classes end up calling old ones and
# fail in obscure ways - Import-Module -Force does not help. The first load in a process
# records what the files looked like; every later load and every run compares
# (Invoke-TaskEngine) and asks for a new session instead.
$script:ModuleChanged = 'the files of the PSTaskFile module changed after it was loaded into this PowerShell process. ' +
    'PowerShell cannot replace the classes of a loaded module: start a new PowerShell session.'

function Get-TaskModuleStamp {
    <#
    .SYNOPSIS
        Identifies the script files of the module as they are on disk: path, size and write time.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $root = Split-Path -Parent $script:ModuleFile
    $files = [System.IO.Directory]::GetFiles($root, '*.ps*1', [System.IO.SearchOption]::AllDirectories)
    [array]::Sort($files, [StringComparer]::Ordinal)
    $parts = foreach ($path in $files) {
        $info = [System.IO.FileInfo]::new($path)
        '{0}|{1}|{2}' -f $path, $info.Length, $info.LastWriteTimeUtc.Ticks
    }
    $parts -join "`n"
}

function Test-TaskModuleChanged {
    <#
    .SYNOPSIS
        Tells whether the module files differ from the ones this process loaded first.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $stamp = Get-TaskModuleStamp
    $loaded = [AppDomain]::CurrentDomain.GetData('PSTaskFile.ModuleStamp')
    if ($null -eq $loaded) {
        [AppDomain]::CurrentDomain.SetData('PSTaskFile.ModuleStamp', $stamp)
        return $false
    }
    return [string]$loaded -cne $stamp
}

if (Test-TaskModuleChanged) { throw "PSTaskFile: $script:ModuleChanged" }

# Private files are loaded in dependency order: PowerShell classes must be defined before
# another file's classes reference them.
$privateOrder = @(
    'Yaml'
    'Template'
    'Model'
    'Dotenv'
    'Fingerprint'
    'Runner'
    'Output'
    'Compiler'
    'Executor'
    'Host'
)
$public = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction Ignore | Sort-Object Name)

foreach ($name in $privateOrder) {
    . (Join-Path $PSScriptRoot 'Private' "$name.ps1")
}
foreach ($file in $public) {
    . $file.FullName
}

# Get-Task objects are shown as a compact table by default.
Update-TypeData -TypeName 'PSTaskFile.TaskInfo' -DefaultDisplayPropertySet Name, Description, Aliases -Force

# Tab completion of task names.
Register-ArgumentCompleter -CommandName Invoke-Task, Watch-Task, Get-Task, Get-TaskSummary, Test-Task -ParameterName Name -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    Get-TaskCompletion -WordToComplete $wordToComplete -BoundParameters $fakeBoundParameters
}

Export-ModuleMember -Function @($public | ForEach-Object BaseName)
