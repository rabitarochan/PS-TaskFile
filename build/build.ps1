param(
    [string]$OutputPath = './output'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$moduleSrcPath = Join-Path $projectRoot 'src' 'PS-TaskFile'

Write-Host '=== PS-TaskFile Build ===' -ForegroundColor Cyan
Write-Host ''

# Step 1: Install dependencies
Write-Host '[1/4] Checking dependencies...' -ForegroundColor Yellow
if (-not (Get-Module -ListAvailable -Name 'powershell-yaml')) {
    Write-Host '  Installing powershell-yaml...'
    Install-Module -Name 'powershell-yaml' -Scope CurrentUser -Force
}
Write-Host '  powershell-yaml: OK' -ForegroundColor Green

if (-not (Get-Module -ListAvailable -Name 'Pester')) {
    Write-Host '  Installing Pester...'
    Install-Module -Name 'Pester' -Scope CurrentUser -Force -SkipPublisherCheck
}
Write-Host '  Pester: OK' -ForegroundColor Green

# Step 2: Validate module manifest
Write-Host '[2/4] Validating module manifest...' -ForegroundColor Yellow
$manifestPath = Join-Path $moduleSrcPath 'PS-TaskFile.psd1'
$manifest = Test-ModuleManifest -Path $manifestPath
Write-Host "  Module: $($manifest.Name) v$($manifest.Version)" -ForegroundColor Green

# Step 3: Run tests
Write-Host '[3/4] Running tests...' -ForegroundColor Yellow
$testsPath = Join-Path $projectRoot 'tests'
$pesterConfig = New-PesterConfiguration
$pesterConfig.Run.Path = $testsPath
$pesterConfig.Run.Exit = $false
$pesterConfig.Run.PassThru = $true
$pesterConfig.Output.Verbosity = 'Detailed'
$testResult = Invoke-Pester -Configuration $pesterConfig

if ($testResult.FailedCount -gt 0) {
    Write-Host "  Tests failed: $($testResult.FailedCount) failure(s)" -ForegroundColor Red
    throw "Build aborted: $($testResult.FailedCount) test(s) failed."
}
Write-Host "  Tests passed: $($testResult.PassedCount)/$($testResult.TotalCount)" -ForegroundColor Green

# Step 4: Build module (merge functions into single .psm1)
Write-Host '[4/4] Building module...' -ForegroundColor Yellow
$outputModulePath = Join-Path $OutputPath 'PS-TaskFile'

if (Test-Path $OutputPath) {
    Remove-Item -Path $OutputPath -Recurse -Force
}
New-Item -Path $outputModulePath -ItemType Directory -Force | Out-Null

# Merge private and public .ps1 files into a single .psm1
$psm1Content = @()
$psm1Content += '# PS-TaskFile Module (built)'
$psm1Content += ''

$privatePath = Join-Path $moduleSrcPath 'private'
if (Test-Path $privatePath) {
    $privateFiles = Get-ChildItem -Path $privatePath -Filter '*.ps1' | Sort-Object Name
    $psm1Content += '#region Private Functions'
    foreach ($file in $privateFiles) {
        $psm1Content += ''
        $psm1Content += (Get-Content -Path $file.FullName -Raw).TrimEnd()
    }
    $psm1Content += ''
    $psm1Content += '#endregion'
}

$publicPath = Join-Path $moduleSrcPath 'public'
if (Test-Path $publicPath) {
    $publicFiles = Get-ChildItem -Path $publicPath -Filter '*.ps1' | Sort-Object Name
    $publicFunctionNames = $publicFiles | ForEach-Object { $_.BaseName }
    $psm1Content += ''
    $psm1Content += '#region Public Functions'
    foreach ($file in $publicFiles) {
        $psm1Content += ''
        $psm1Content += (Get-Content -Path $file.FullName -Raw).TrimEnd()
    }
    $psm1Content += ''
    $psm1Content += '#endregion'
}

$psm1Content += ''
$exportList = ($publicFunctionNames | ForEach-Object { "'$_'" }) -join ', '
$psm1Content += "Export-ModuleMember -Function $exportList"
$psm1Content += ''

$psm1OutputPath = Join-Path $outputModulePath 'PS-TaskFile.psm1'
$psm1Content -join "`n" | Set-Content -Path $psm1OutputPath -NoNewline -Encoding UTF8

# Copy manifest and other non-.ps1 resources
Copy-Item -Path $manifestPath -Destination $outputModulePath

$typesPath = Join-Path $moduleSrcPath 'types'
if (Test-Path $typesPath) {
    Copy-Item -Path $typesPath -Destination $outputModulePath -Recurse
}

Write-Host "  Merged: $($privateFiles.Count) private + $($publicFiles.Count) public -> PS-TaskFile.psm1" -ForegroundColor Green
Write-Host "  Output: $outputModulePath" -ForegroundColor Green

# Summary
Write-Host ''
Write-Host '=== Build Succeeded ===' -ForegroundColor Green
Write-Host "  Module:  $($manifest.Name) v$($manifest.Version)"
Write-Host "  Tests:   $($testResult.PassedCount) passed"
Write-Host "  Output:  $outputModulePath"
