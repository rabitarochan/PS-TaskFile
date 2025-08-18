# PS-TaskFile Module

# Load all private functions
$privatePath = Join-Path $PSScriptRoot 'private'
if (Test-Path $privatePath) {
    Get-ChildItem -Path $privatePath -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }
}

# Load all public functions
$publicPath = Join-Path $PSScriptRoot 'public'
if (Test-Path $publicPath) {
    Get-ChildItem -Path $publicPath -Filter '*.ps1' | ForEach-Object {
        . $_.FullName
    }
}

# Export public functions
Export-ModuleMember -Function Invoke-TaskFile
