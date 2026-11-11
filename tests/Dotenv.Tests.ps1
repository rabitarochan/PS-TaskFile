BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"

    function Read-TestDotenv {
        param([string]$Content)
        $dir = New-TestDirectory
        $file = Set-TestFile -Path (Join-Path $dir '.env') -Content $Content
        Invoke-InModule { param($path) [TaskDotenv]::Read($path) } -ArgumentList $file
    }
}

Describe 'TaskDotenv' {
    It 'reads simple assignments in file order' {
        $vars = Read-TestDotenv "A=1`nB=two`nC = three "
        @($vars.Keys) | Should -Be @('A', 'B', 'C')
        $vars['A'] | Should -BeExactly '1'
        $vars['B'] | Should -BeExactly 'two'
        $vars['C'] | Should -BeExactly 'three'
    }

    It 'ignores comments, blank lines and the export prefix' {
        $vars = Read-TestDotenv "# comment`n`nexport A=1`n  # indented comment`nB=2 # trailing comment`nC=a#b"
        @($vars.Keys) | Should -Be @('A', 'B', 'C')
        $vars['A'] | Should -BeExactly '1'
        $vars['B'] | Should -BeExactly '2'
        $vars['C'] | Should -BeExactly 'a#b'
    }

    It 'supports the YAML-like "KEY: value" form' {
        (Read-TestDotenv "A: 1")['A'] | Should -BeExactly '1'
    }

    It 'keeps single-quoted values literal' {
        $vars = Read-TestDotenv "A='a `$B \n # not a comment'"
        $vars['A'] | Should -BeExactly 'a $B \n # not a comment'
    }

    It 'expands escapes in double-quoted values' {
        $vars = Read-TestDotenv 'A="line1\nline2\t\"q\""'
        $vars['A'] | Should -BeExactly "line1`nline2`t`"q`""
    }

    It 'supports multi-line quoted values' {
        $vars = Read-TestDotenv "A=`"first`nsecond`"`nB=after"
        $vars['A'] | Should -BeExactly "first`nsecond"
        $vars['B'] | Should -BeExactly 'after'
    }

    It 'expands variables from earlier keys and the environment' {
        $env:PSTF_DOTENV_TEST = 'from-env'
        try {
            $vars = Read-TestDotenv "A=one`nB=`${A}-two`nC=`"`$A and `$PSTF_DOTENV_TEST`"`nD='`$A'`nE=\`$A"
            $vars['B'] | Should -BeExactly 'one-two'
            $vars['C'] | Should -BeExactly 'one and from-env'
            $vars['D'] | Should -BeExactly '$A'
            $vars['E'] | Should -BeExactly '$A'
        }
        finally { Remove-Item Env:PSTF_DOTENV_TEST }
    }

    It 'allows empty values' {
        $vars = Read-TestDotenv "A=`nB=''"
        $vars.Contains('A') | Should -BeTrue
        $vars['A'] | Should -BeExactly ''
        $vars['B'] | Should -BeExactly ''
    }

    It 'rejects lines without a separator' {
        { Read-TestDotenv "JUSTAWORD" } | Should -Throw -ExpectedMessage '*JUSTAWORD*'
    }
}
