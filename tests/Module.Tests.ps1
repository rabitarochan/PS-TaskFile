BeforeAll {
    $script:ManifestPath = Join-Path $PSScriptRoot '..' 'src' 'PSTaskFile' 'PSTaskFile.psd1'
    Import-Module $script:ManifestPath -Force
}

Describe 'PSTaskFile module' {
    It 'has a valid manifest' {
        $manifest = Test-ModuleManifest -Path $script:ManifestPath
        $manifest.Name | Should -Be 'PSTaskFile'
        $manifest.PowerShellVersion | Should -Be ([version]'7.4')
    }

    It 'imports without errors' {
        Get-Module PSTaskFile | Should -Not -BeNullOrEmpty
    }
}
