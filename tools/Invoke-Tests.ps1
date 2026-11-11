#Requires -Version 7.4
<#
.SYNOPSIS
    Runs the Pester test suite.
.DESCRIPTION
    Always run this in a fresh process (pwsh -NoProfile -File tools/Invoke-Tests.ps1) so that
    PowerShell classes defined by the module are loaded from the current sources.
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-Tests.ps1
.EXAMPLE
    pwsh -NoProfile -File tools/Invoke-Tests.ps1 -Path tests/Template.Tests.ps1 -Output Detailed
#>
[CmdletBinding()]
param(
    # Test files or directories. Defaults to the whole tests directory.
    [string[]]$Path = @((Join-Path $PSScriptRoot '..' 'tests')),

    # Only run tests whose full name matches one of these wildcard patterns.
    [string[]]$FullName,

    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Normal'
)

$ErrorActionPreference = 'Stop'

Import-Module Pester -MinimumVersion 5.5.0
Import-Module powershell-yaml

$configuration = New-PesterConfiguration
$configuration.Run.Path = $Path
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = $Output
if ($FullName) { $configuration.Filter.FullName = $FullName }

$result = Invoke-Pester -Configuration $configuration
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
exit 0
