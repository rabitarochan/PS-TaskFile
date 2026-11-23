#Requires -Version 7.4
<#
.SYNOPSIS
    Checks a release and publishes the module to the PowerShell Gallery.
.DESCRIPTION
    Without -Publish only the checks run:

    - the tag is "v" followed by the ModuleVersion of the manifest,
    - the checked-out commit is on origin/main,
    - that version is not on the PowerShell Gallery yet.

    With -Publish the module is published afterwards. A published version cannot be removed
    or replaced. The release workflow (.github/workflows/release.yml) calls this script.
.EXAMPLE
    ./tools/Publish-Module.ps1 -Tag v1.2.3
.EXAMPLE
    $env:PSGALLERY_API_KEY = '<key>'; ./tools/Publish-Module.ps1 -Tag v1.2.3 -Publish
#>
[CmdletBinding()]
param(
    # The name of the release tag, e.g. v1.2.3.
    [Parameter(Mandatory)]
    [string]$Tag,

    # Publish after the checks passed.
    [switch]$Publish,

    # The API key of the PowerShell Gallery. Defaults to the environment variable PSGALLERY_API_KEY.
    [string]$ApiKey = $env:PSGALLERY_API_KEY
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$module = Join-Path $root 'src' 'PS-TaskFile'
$version = [string](Import-PowerShellDataFile -LiteralPath (Join-Path $module 'PS-TaskFile.psd1')).ModuleVersion

if ($Tag -cne "v$version") {
    throw "The tag '$Tag' does not belong to the module version ${version}: expected 'v$version'."
}

$null = git -C $root merge-base --is-ancestor HEAD origin/main
if ($LASTEXITCODE -ne 0) {
    throw 'The checked-out commit is not on origin/main: releases are made from main.'
}

# A version that does not exist is reported as an error, which is the expected case here.
$published = Find-PSResource -Name PS-TaskFile -Version $version -Repository PSGallery -ErrorAction SilentlyContinue
if ($null -ne $published) {
    throw "PS-TaskFile $version is already on the PowerShell Gallery. Raise ModuleVersion."
}

if (-not $Publish) {
    Write-Host "PS-TaskFile $version can be published."
    return
}

if ([string]::IsNullOrEmpty($ApiKey)) {
    throw 'No API key: pass -ApiKey or set the environment variable PSGALLERY_API_KEY.'
}

Publish-PSResource -Path $module -Repository PSGallery -ApiKey $ApiKey
Write-Host "Published PS-TaskFile $version to the PowerShell Gallery."
