BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"

    $script:Esc = [string][char]27
    # Seven Japanese characters: each one is two cells wide.
    $script:Wide = -join ([char[]]@(0x65E5, 0x672C, 0x8A9E, 0x30C6, 0x30AD, 0x30B9, 0x30C8))

    function Measure-TestCells {
        param([AllowEmptyString()][string]$Text)
        Invoke-InModule { param($t) [TaskPrefix]::Cells($t) } -ArgumentList $Text
    }

    function Split-TestLine {
        param([AllowEmptyString()][string]$Text, [int]$Cells)
        Invoke-InModule { param($t, $c) [TaskPrefix]::Wrap($t, $c) } -ArgumentList $Text, $Cells
    }

    # The lines `output: prefixed` writes for one line of $Prefix, after the given prefixes were seen.
    function Format-TestLine {
        param([string[]]$Register = @(), [string[]]$Reserve = @(), [string]$Prefix, [AllowEmptyString()][string]$Line, [int]$Columns = 0)
        Invoke-InModule {
            param($register, $reserve, $prefix, $line, $columns)
            $state = [TaskPrefix]::NewState()
            foreach ($name in $reserve) { [TaskPrefix]::Reserve($state, $name) }
            foreach ($name in $register) { $null = [TaskPrefix]::Register($state, $name) }
            [TaskPrefix]::Format($state, $prefix, $line, $columns)
        } -ArgumentList $Register, $Reserve, $Prefix, $Line, $Columns
    }

    # The position of the separator in a line that Format returned.
    function Find-TestSeparator {
        param([string]$Row, [string]$Prefix, [switch]$First)
        Invoke-InModule { param($r, $p, $f) [TaskPrefix]::Separator($r, $p, $f) } -ArgumentList $Row, $Prefix, $First.IsPresent
    }

    # The colour of $Prefix after the given prefixes were seen.
    function Get-TestColor {
        param([string[]]$Register = @(), [string[]]$Reserve = @(), [string]$Prefix)
        Invoke-InModule {
            param($register, $reserve, $prefix)
            $state = [TaskPrefix]::NewState()
            foreach ($name in $reserve) { [TaskPrefix]::Reserve($state, $name) }
            foreach ($name in $register) { $null = [TaskPrefix]::Register($state, $name) }
            [string][TaskPrefix]::Color($state, $prefix)
        } -ArgumentList $Register, $Reserve, $Prefix
    }
}

Describe 'TaskPrefix: display width' {
    It 'counts one cell per ASCII character' {
        Measure-TestCells 'abc' | Should -Be 3
        Measure-TestCells '' | Should -Be 0
    }

    It 'counts two cells per East Asian wide character' {
        Measure-TestCells $script:Wide | Should -Be 14
        Measure-TestCells ('a' + $script:Wide.Substring(0, 2) + 'b') | Should -Be 6
    }

    It 'counts two cells for a character outside the basic plane' {
        Measure-TestCells ([char]::ConvertFromUtf32(0x1F600)) | Should -Be 2
        Measure-TestCells ([char]::ConvertFromUtf32(0x20000)) | Should -Be 2
    }

    It 'does not count escape sequences' {
        Measure-TestCells "$($script:Esc)[31mred$($script:Esc)[0m" | Should -Be 3
        Measure-TestCells "$($script:Esc)]8;;https://example.com$($script:Esc)\link$($script:Esc)]8;;$($script:Esc)\" | Should -Be 4
    }
}

Describe 'TaskPrefix: wrapping' {
    It 'keeps a line that fits' {
        Split-TestLine 'abc' 3 | Should -Be @('abc')
        Split-TestLine '' 3 | Should -Be @('')
    }

    It 'breaks a long line at the cell limit' {
        Split-TestLine 'abcdefghij' 4 | Should -Be @('abcd', 'efgh', 'ij')
    }

    It 'never splits a wide character' {
        $pieces = Split-TestLine $script:Wide 5
        $pieces | Should -Be @($script:Wide.Substring(0, 2), $script:Wide.Substring(2, 2), $script:Wide.Substring(4, 2), $script:Wide.Substring(6))
    }

    It 'carries the colour of the text over to the next piece' {
        $e = $script:Esc
        Split-TestLine "$e[31mabcdef$e[0m" 4 | Should -Be @("$e[31mabcd$e[0m", "$e[31mef$e[0m")
    }

    It 'does not carry a colour that was reset' {
        $e = $script:Esc
        Split-TestLine "$e[31mab$e[0mcdef" 4 | Should -Be @("$e[31mab$e[0mcd", 'ef')
    }

    It 'expands tabs to the next multiple of eight' {
        Split-TestLine "a`tb" 20 | Should -Be @('a       b')
    }

    It 'leaves a line with a carriage return alone' {
        Split-TestLine "50%`r100%" 4 | Should -Be @("50%`r100%")
    }

    It 'does not wrap without a limit' {
        Split-TestLine 'abcdefghij' 0 | Should -Be @('abcdefghij')
    }
}

Describe 'TaskPrefix: layout' {
    It 'pads the header to the widest prefix seen so far' {
        Format-TestLine -Register app, worker -Prefix app -Line hello | Should -Be @('[app]    | hello')
        Format-TestLine -Register app, worker -Prefix worker -Line hello | Should -Be @('[worker] | hello')
    }

    It 'registers a prefix that was not seen before' {
        Format-TestLine -Register worker -Prefix app -Line hello | Should -Be @('[app]    | hello')
    }

    It 'measures the prefix in cells' {
        $wide = $script:Wide.Substring(0, 2)
        Format-TestLine -Register $wide, 'ab' -Prefix ab -Line x | Should -Be @('[ab]   | x')
        Format-TestLine -Register $wide, 'ab' -Prefix $wide -Line x | Should -Be @("[$wide] | x")
    }

    It 'writes an empty line without trailing blanks' {
        Format-TestLine -Register app, worker -Prefix app -Line '' | Should -Be @('[app]    |')
    }

    It 'reserves room for a prefix that has not written yet' {
        Format-TestLine -Reserve 'long-name' -Prefix app -Line x | Should -Be @('[app]       | x')
    }

    It 'continues a line that is wider than the terminal below its own text' {
        # 40 columns: 8 for the header, 3 for the separator, the last column stays free.
        $lines = Format-TestLine -Register app, worker -Prefix app -Line ('x' * 30) -Columns 40
        $lines | Should -Be @(('[app]    | ' + ('x' * 28)), '         | xx')
    }

    It 'does not wrap when hardly any room is left for the text' {
        Format-TestLine -Register app, worker -Prefix app -Line ('x' * 30) -Columns 25 | Should -Be @('[app]    | ' + ('x' * 30))
    }

    It 'starts every first line with the prefix in brackets' {
        # TaskLineWriter relies on it to write the prefix in its colour.
        Format-TestLine -Register app, worker -Prefix app -Line ('x' * 60) -Columns 40 | Select-Object -First 1 | Should -BeLike '`[app`]*'
    }

    # TaskLineWriter writes the separator in the colour of the prefix.
    It 'finds the separator of a first line' {
        Find-TestSeparator -Row '[app]    | a | b' -Prefix app -First | Should -Be 9
        Find-TestSeparator -Row '[app]    |' -Prefix app -First | Should -Be 9
    }

    It 'finds the separator behind a prefix that contains one' {
        Find-TestSeparator -Row '[a|b] | x' -Prefix 'a|b' -First | Should -Be 6
    }

    It 'finds the separator of a continued line' {
        Find-TestSeparator -Row '         | x | y' -Prefix app | Should -Be 9
    }

    It 'finds the separator in the lines it formats' {
        $lines = Format-TestLine -Register 'a|b', worker -Prefix 'a|b' -Line ('x|' * 30) -Columns 40
        $lines.Count | Should -BeGreaterThan 1
        Find-TestSeparator -Row $lines[0] -Prefix 'a|b' -First | Should -Be 9
        foreach ($line in $lines | Select-Object -Skip 1) { Find-TestSeparator -Row $line -Prefix 'a|b' | Should -Be 9 }
    }
}

Describe 'TaskPrefix: colours' {
    It 'hands out the colours in the order the prefixes appeared' {
        Get-TestColor -Register app, worker -Prefix app | Should -Be 'DarkCyan'
        Get-TestColor -Register app, worker -Prefix worker | Should -Be 'DarkYellow'
    }

    It 'gives a colour to a prefix that was not seen before' {
        Get-TestColor -Register app -Prefix worker | Should -Be 'DarkYellow'
    }

    It 'does not spend a colour on a reservation' {
        Get-TestColor -Reserve other -Prefix app | Should -Be 'DarkCyan'
    }

    It 'starts over with the first colour after twelve prefixes' {
        $names = 1..13 | ForEach-Object { "t$_" }
        Get-TestColor -Register $names -Prefix t12 | Should -Be 'Red'
        Get-TestColor -Register $names -Prefix t13 | Should -Be 'DarkCyan'
    }
}
