Describe "Get-DisplayWidth" {
    BeforeAll {
        $modulePath = "$PSScriptRoot/../../src/PS-TaskFile"
        Import-Module $modulePath -Force
        
        # Get the module
        $script:module = Get-Module PS-TaskFile
    }

    Context "When calculating display width for ASCII characters" {
        It "Should return 1 for single ASCII character" {
            $result = & $module { Get-DisplayWidth -InputString "A" }
            $result | Should -Be 1
        }

        It "Should return correct width for ASCII string" {
            $result = & $module { Get-DisplayWidth -InputString "Hello" }
            $result | Should -Be 5
        }

        It "Should return correct width for ASCII with spaces" {
            $result = & $module { Get-DisplayWidth -InputString "Hello World" }
            $result | Should -Be 11
        }

        It "Should return 0 for empty string" {
            $result = & $module { Get-DisplayWidth -InputString "" }
            $result | Should -Be 0
        }
    }

    Context "When calculating display width for Japanese characters" {
        It "Should return 2 for single Hiragana character" {
            $result = & $module { Get-DisplayWidth -InputString "あ" }
            $result | Should -Be 2
        }

        It "Should return correct width for Hiragana string" {
            $result = & $module { Get-DisplayWidth -InputString "ひらがな" }
            $result | Should -Be 8
        }

        It "Should return 2 for single Katakana character" {
            $result = & $module { Get-DisplayWidth -InputString "ア" }
            $result | Should -Be 2
        }

        It "Should return correct width for Katakana string" {
            $result = & $module { Get-DisplayWidth -InputString "カタカナ" }
            $result | Should -Be 8
        }

        It "Should return 2 for single Kanji character" {
            $result = & $module { Get-DisplayWidth -InputString "漢" }
            $result | Should -Be 2
        }

        It "Should return correct width for Kanji string" {
            $result = & $module { Get-DisplayWidth -InputString "漢字文字" }
            $result | Should -Be 8
        }
    }

    Context "When calculating display width for full-width ASCII" {
        It "Should return 2 for full-width letter" {
            $result = & $module { Get-DisplayWidth -InputString "Ａ" }
            $result | Should -Be 2
        }

        It "Should return correct width for full-width string" {
            $result = & $module { Get-DisplayWidth -InputString "ＡＢＣ" }
            $result | Should -Be 6
        }

        It "Should return correct width for full-width numbers" {
            $result = & $module { Get-DisplayWidth -InputString "１２３" }
            $result | Should -Be 6
        }
    }

    Context "When calculating display width for Korean characters" {
        It "Should return 2 for single Hangul character" {
            $result = & $module { Get-DisplayWidth -InputString "한" }
            $result | Should -Be 2
        }

        It "Should return correct width for Hangul string" {
            $result = & $module { Get-DisplayWidth -InputString "한글" }
            $result | Should -Be 4
        }

        It "Should return correct width for Hangul Jamo" {
            $result = & $module { Get-DisplayWidth -InputString "ㄱㄴㄷ" }
            $result | Should -Be 6
        }
    }

    Context "When calculating display width for Chinese characters" {
        It "Should return 2 for single Chinese character" {
            $result = & $module { Get-DisplayWidth -InputString "中" }
            $result | Should -Be 2
        }

        It "Should return correct width for Chinese string" {
            $result = & $module { Get-DisplayWidth -InputString "中文字符" }
            $result | Should -Be 8
        }
    }

    Context "When calculating display width for CJK symbols" {
        It "Should return 2 for CJK punctuation" {
            $result = & $module { Get-DisplayWidth -InputString "。" }
            $result | Should -Be 2
        }

        It "Should return correct width for CJK brackets" {
            $result = & $module { Get-DisplayWidth -InputString "「」" }
            $result | Should -Be 4
        }

        It "Should return correct width for CJK symbols" {
            $result = & $module { Get-DisplayWidth -InputString "〇〒〓" }
            $result | Should -Be 6
        }
    }

    Context "When calculating display width for mixed characters" {
        It "Should return correct width for mixed ASCII and Japanese" {
            $result = & $module { Get-DisplayWidth -InputString "Hello世界" }
            $result | Should -Be 9  # 5 (Hello) + 4 (世界)
        }

        It "Should return correct width for mixed half-width and full-width" {
            $result = & $module { Get-DisplayWidth -InputString "ABC123ＡＢＣ１２３" }
            $result | Should -Be 18  # 6 (ABC123) + 12 (ＡＢＣ１２３)
        }

        It "Should return correct width for complex mixed string" {
            $result = & $module { Get-DisplayWidth -InputString "Test テスト 123" }
            $result | Should -Be 15  # 4 (Test) + 1 (space) + 6 (テスト) + 1 (space) + 3 (123)
        }
    }

    Context "When calculating display width for special Unicode ranges" {
        It "Should return correct width for enclosed characters" {
            # 囲み文字 (U+3200-32FF)
            $result = & $module { Get-DisplayWidth -InputString ([char]0x3200).ToString() }
            $result | Should -Be 2
        }

        It "Should return correct width for CJK compatibility characters" {
            # CJK互換 (U+3300-33FF)
            $result = & $module { Get-DisplayWidth -InputString ([char]0x3300).ToString() }
            $result | Should -Be 2
        }

        It "Should return correct width for CJK extension characters" {
            # CJK統合漢字拡張A (U+3400-4DBF)
            $result = & $module { Get-DisplayWidth -InputString ([char]0x3400).ToString() }
            $result | Should -Be 2
        }

        It "Should return correct width for vertical form characters" {
            # 縦書き記号 (U+FE10-FE19)
            $result = & $module { Get-DisplayWidth -InputString ([char]0xFE10).ToString() }
            $result | Should -Be 2
        }
    }

    Context "When handling edge cases" {
        It "Should handle null string" {
            $result = & $module { Get-DisplayWidth -InputString $null }
            $result | Should -Be 0
        }

        It "Should handle string with only spaces" {
            $result = & $module { Get-DisplayWidth -InputString "   " }
            $result | Should -Be 3
        }

        It "Should handle tab characters as single width" {
            $result = & $module { Get-DisplayWidth -InputString "`t" }
            $result | Should -Be 1
        }

        It "Should handle newline characters as single width" {
            $result = & $module { Get-DisplayWidth -InputString "`n" }
            $result | Should -Be 1
        }
    }
}