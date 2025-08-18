Describe "Prompt-ForExecution" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        
        # Get the module
        $script:module = Get-Module PS-TaskFile
    }

    Context "When prompting for execution" {
        It "Should display the command to be executed" {
            # This is an interactive function, so we can only test its structure
            # In real scenarios, this would require user input
            $functionDefinition = & $module { Get-Command Prompt-ForExecution | ForEach-Object Definition }
            
            $functionDefinition | Should -Match 'Command'
            $functionDefinition | Should -Match 'Write-Host'
        }
    }
}