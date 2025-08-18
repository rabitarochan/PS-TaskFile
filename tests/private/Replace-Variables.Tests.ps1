Describe "Replace-Variables" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        
        # Get the module and access the private function
        $module = Get-Module PS-TaskFile
    }

    Context "When replacing simple variables" {
        It "Should replace a single variable" {
            $command = 'echo $name'
            $variables = @{ name = 'John' }
            
            $result = & $module { Replace-Variables -Command $args[0] -Variables $args[1] } $command $variables
            
            $result | Should -Be 'echo John'
        }

        It "Should replace multiple variables" {
            $command = 'echo $greeting $name'
            $variables = @{ 
                greeting = 'Hello'
                name = 'World'
            }
            
            $result = & $module { Replace-Variables -Command $args[0] -Variables $args[1] } $command $variables
            
            $result | Should -Be 'echo Hello World'
        }

        It "Should not replace undefined variables" {
            $command = 'echo $undefined'
            $variables = @{ name = 'John' }
            
            $result = & $module { Replace-Variables -Command $args[0] -Variables $args[1] } $command $variables
            
            $result | Should -Be 'echo $undefined'
        }

        It "Should handle empty variables hashtable" {
            $command = 'echo test'
            $variables = @{}
            
            $result = & $module { Replace-Variables -Command $args[0] -Variables $args[1] } $command $variables
            
            $result | Should -Be 'echo test'
        }
    }
}