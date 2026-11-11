BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"

    function ConvertFrom-TestYaml {
        param([string]$Yaml)
        , (Invoke-InModule { param($text) , [TaskYaml]::Parse($text) } -ArgumentList $Yaml)
    }
}

Describe 'TaskYaml' {
    It 'resolves the plain scalar <Text> as <Type>' -ForEach @(
        @{ Text = '42'; Type = 'Int32'; Expected = 42 }
        @{ Text = '-7'; Type = 'Int32'; Expected = -7 }
        @{ Text = '12345678901'; Type = 'Int64'; Expected = 12345678901 }
        @{ Text = '0x10'; Type = 'Int32'; Expected = 16 }
        @{ Text = '0o17'; Type = 'Int32'; Expected = 15 }
        @{ Text = '010'; Type = 'Int32'; Expected = 8 }
        @{ Text = '1_000'; Type = 'Int32'; Expected = 1000 }
        @{ Text = '1.5'; Type = 'Double'; Expected = 1.5 }
        @{ Text = '1e3'; Type = 'Double'; Expected = 1000 }
        @{ Text = 'true'; Type = 'Boolean'; Expected = $true }
        @{ Text = 'False'; Type = 'Boolean'; Expected = $false }
        @{ Text = 'yes'; Type = 'String'; Expected = 'yes' }
        @{ Text = 'hello'; Type = 'String'; Expected = 'hello' }
        @{ Text = '1.2.3'; Type = 'String'; Expected = '1.2.3' }
        @{ Text = '2024-01-02'; Type = 'String'; Expected = '2024-01-02' }
        @{ Text = "'42'"; Type = 'String'; Expected = '42' }
        @{ Text = '"true"'; Type = 'String'; Expected = 'true' }
    ) {
        $value = (ConvertFrom-TestYaml "v: $Text")['v']
        $value.GetType().Name | Should -Be $Type
        $value | Should -Be $Expected
    }

    It 'resolves <Text> as null' -ForEach @(@{ Text = '' }, @{ Text = '~' }, @{ Text = 'null' }) {
        $map = ConvertFrom-TestYaml "v: $Text"
        $map.Contains('v') | Should -BeTrue
        $map['v'] | Should -BeNullOrEmpty
    }

    It 'keeps keys case-sensitive and in document order' {
        $map = ConvertFrom-TestYaml "b: 1`nB: 2`na: 3"
        @($map.Keys) | Should -BeExactly @('b', 'B', 'a')
        $map['b'] | Should -Be 1
        $map['B'] | Should -Be 2
    }

    It 'converts nested maps and lists' {
        $map = ConvertFrom-TestYaml "m:`n  l: [1, two, [3]]`n  s: |`n    line1`n    line2`n"
        $map['m']['l'].Count | Should -Be 3
        $map['m']['l'][1] | Should -BeExactly 'two'
        $map['m']['l'][2][0] | Should -Be 3
        $map['m']['s'] | Should -BeExactly "line1`nline2`n"
    }

    It 'resolves anchors, aliases and merge keys' {
        $map = ConvertFrom-TestYaml "base: &base`n  x: 1`n  y: 2`nchild:`n  <<: *base`n  y: 9`nref: *base"
        $map['child']['x'] | Should -Be 1
        $map['child']['y'] | Should -Be 9
        $map['ref']['y'] | Should -Be 2
    }

    It 'returns null for an empty document' {
        ConvertFrom-TestYaml '' | Should -BeNullOrEmpty
    }

    It 'throws on invalid YAML' {
        { ConvertFrom-TestYaml "a: [1, 2" } | Should -Throw
    }
}
