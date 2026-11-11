#Requires -Version 7.4
Set-StrictMode -Version 3.0

# Path of this file. Engine runspaces import the .psm1 directly (see Private/Host.ps1).
$script:ModuleFile = $PSCommandPath
$script:ModuleVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'PSTaskFile.psd1')).ModuleVersion

# Private files are loaded in dependency order: PowerShell classes must be defined before
# another file's classes reference them.
$privateOrder = @(
    'Yaml'
    'Template'
    'Model'
)
$public = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction Ignore | Sort-Object Name)

foreach ($name in $privateOrder) {
    . (Join-Path $PSScriptRoot 'Private' "$name.ps1")
}
foreach ($file in $public) {
    . $file.FullName
}

Export-ModuleMember -Function @($public | ForEach-Object BaseName)
