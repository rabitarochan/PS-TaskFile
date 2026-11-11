#Requires -Version 7.4
Set-StrictMode -Version 3.0

# Path of this file. Engine runspaces import the .psm1 directly (see Private/Host.ps1).
$script:ModuleFile = $PSCommandPath
$script:ModuleVersion = (Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'PSTaskFile.psd1')).ModuleVersion

$private = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -ErrorAction Ignore | Sort-Object Name)
$public = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction Ignore | Sort-Object Name)

foreach ($file in $private + $public) {
    . $file.FullName
}

Export-ModuleMember -Function @($public | ForEach-Object BaseName)
