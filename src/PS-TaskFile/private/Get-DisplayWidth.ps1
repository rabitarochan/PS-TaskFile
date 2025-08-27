function Get-DisplayWidth {
    param(
        [string]$InputString
    )

    $width = 0

    foreach ($char in $InputString.ToCharArray()) {
        $charCode = [int][char]$char

        # full-width character detection
        if (($charCode -ge 0x1100 -and $charCode -le 0x115F) -or    # Hangul Jamo (ハングル字母)
            ($charCode -ge 0x2329 -and $charCode -le 0x232A) -or    # Angle Brackets (角括弧)
            ($charCode -ge 0x2E80 -and $charCode -le 0x2EFF) -or    # CJK Radicals Supplement (CJK部首補助)
            ($charCode -ge 0x2F00 -and $charCode -le 0x2FDF) -or    # Kangxi Radicals (康熙部首)
            ($charCode -ge 0x2FF0 -and $charCode -le 0x2FFF) -or    # Ideographic Description Characters (表意文字記述文字)
            ($charCode -ge 0x3000 -and $charCode -le 0x303E) -or    # CJK Symbols (CJK記号)
            ($charCode -ge 0x3040 -and $charCode -le 0x309F) -or    # Hiragana (ひらがな)
            ($charCode -ge 0x30A0 -and $charCode -le 0x30FF) -or    # Katakana (カタカナ)
            ($charCode -ge 0x3100 -and $charCode -le 0x312F) -or    # Bopomofo (注音字母)
            ($charCode -ge 0x3130 -and $charCode -le 0x318F) -or    # Hangul Compatibility Jamo (ハングル互換字母)
            ($charCode -ge 0x3190 -and $charCode -le 0x319F) -or    # Kanbun (漢文記号)
            ($charCode -ge 0x31A0 -and $charCode -le 0x31BF) -or    # Bopomofo Extended (注音字母拡張)
            ($charCode -ge 0x31C0 -and $charCode -le 0x31EF) -or    # CJK Strokes (CJK記号)
            ($charCode -ge 0x31F0 -and $charCode -le 0x31FF) -or    # Katakana Phonetic Extensions (カタカナ音韻拡張)
            ($charCode -ge 0x3200 -and $charCode -le 0x32FF) -or    # Enclosed CJK Letters and Months (囲み文字)
            ($charCode -ge 0x3300 -and $charCode -le 0x33FF) -or    # CJK Compatibility (CJK互換)
            ($charCode -ge 0x3400 -and $charCode -le 0x4DBF) -or    # CJK Unified Ideographs Extension A (CJK統合漢字拡張A)
            ($charCode -ge 0x4E00 -and $charCode -le 0x9FFF) -or    # CJK Unified Ideographs (CJK統合漢字)
            ($charCode -ge 0xA960 -and $charCode -le 0xA97F) -or    # Hangul Jamo Extended-A (ハングル字母拡張A)
            ($charCode -ge 0xAC00 -and $charCode -le 0xD7A3) -or    # Hangul Syllables (ハングル音節)
            ($charCode -ge 0xF900 -and $charCode -le 0xFAFF) -or    # CJK Compatibility Ideographs (CJK互換漢字)
            ($charCode -ge 0xFE10 -and $charCode -le 0xFE19) -or    # Vertical Forms (縦書き記号)
            ($charCode -ge 0xFE30 -and $charCode -le 0xFE6F) -or    # CJK Compatibility Forms (CJK互換形)
            ($charCode -ge 0xFF00 -and $charCode -le 0xFF60) -or    # Fullwidth ASCII (全角ASCII)
            ($charCode -ge 0xFFE0 -and $charCode -le 0xFFE6)) {     # Fullwidth Symbols (全角記号)
            $width += 2  # Full-width characters have width 2
        }
        else {
            $width += 1  # Half-width characters have width 1
        }
    }

    return $width
}
