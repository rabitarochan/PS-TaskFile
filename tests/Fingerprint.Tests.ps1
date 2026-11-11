BeforeAll {
    . "$PSScriptRoot/Helpers.ps1"

    function New-TestTree {
        $root = New-TestDirectory
        foreach ($file in 'a.txt', 'b.md', 'src/main.ps1', 'src/main.Tests.ps1', 'src/lib/util.ps1', 'src/lib/deep/more.ps1', 'docs/readme.md', 'docs/[special].md') {
            $null = Set-TestFile -Path (Join-Path $root $file) -Content "content of $file"
        }
        $root
    }

    function Get-TestGlob {
        param([string]$Directory, [object[]]$Patterns)
        $globs = foreach ($pattern in $Patterns) {
            if ($pattern -is [string]) { [pscustomobject]@{ Glob = $pattern; Negate = $false } }
            else { [pscustomobject]@{ Glob = $pattern.exclude; Negate = $true } }
        }
        $files = Invoke-InModule { param($dir, $list) , [TaskGlob]::Expand($dir, $list) } -ArgumentList $Directory, @($globs)
        @($files | ForEach-Object { [System.IO.Path]::GetRelativePath($Directory, $_).Replace('\', '/') })
    }

    function New-FingerprintTask {
        param([string]$Directory, [string[]]$Sources = @(), [string[]]$Generates = @(), [string]$Name = 'build')
        [pscustomobject]@{
            Task      = $Name
            Label     = ''
            Dir       = $Directory
            Sources   = @($Sources | ForEach-Object { [pscustomobject]@{ Glob = $_; Negate = $false } })
            Generates = @($Generates | ForEach-Object { [pscustomobject]@{ Glob = $_; Negate = $false } })
        }
    }

    function Test-Fingerprint {
        param($Task, [string]$Method, [string]$TempDir, [switch]$Dry)
        Invoke-InModule { param($t, $m, $d, $dry) [TaskFingerprint]::IsUpToDate($t, $m, $d, $dry) } -ArgumentList $Task, $Method, $TempDir, $Dry.IsPresent
    }
}

Describe 'TaskGlob' {
    BeforeAll { $script:Tree = New-TestTree }

    It 'expands <Pattern>' -ForEach @(
        @{ Pattern = 'a.txt'; Expected = @('a.txt') }
        @{ Pattern = '*.txt'; Expected = @('a.txt') }
        @{ Pattern = '*'; Expected = @('a.txt', 'b.md') }
        @{ Pattern = 'src/*.ps1'; Expected = @('src/main.ps1', 'src/main.Tests.ps1') }
        @{ Pattern = 'src/**/*.ps1'; Expected = @('src/lib/deep/more.ps1', 'src/lib/util.ps1', 'src/main.ps1', 'src/main.Tests.ps1') }
        @{ Pattern = '**/*.md'; Expected = @('b.md', 'docs/[special].md', 'docs/readme.md') }
        @{ Pattern = 'src/**'; Expected = @('src/lib/deep/more.ps1', 'src/lib/util.ps1', 'src/main.ps1', 'src/main.Tests.ps1') }
        @{ Pattern = 'src/lib/**/more.ps1'; Expected = @('src/lib/deep/more.ps1') }
        @{ Pattern = '?.txt'; Expected = @('a.txt') }
        @{ Pattern = '[ab].*'; Expected = @('a.txt', 'b.md') }
        @{ Pattern = '*.{txt,md}'; Expected = @('a.txt', 'b.md') }
        @{ Pattern = 'docs/r*.md'; Expected = @('docs/readme.md') }
        @{ Pattern = 'missing/*.txt'; Expected = @() }
        @{ Pattern = 'nope.txt'; Expected = @() }
        @{ Pattern = 'src'; Expected = @() }
    ) {
        $actual = Get-TestGlob $script:Tree @($Pattern)
        @($actual | Sort-Object) | Should -Be @($Expected | Sort-Object)
    }

    It 'returns sorted absolute paths without duplicates' {
        $files = Invoke-InModule { param($dir, $list) , [TaskGlob]::Expand($dir, $list) } -ArgumentList $script:Tree, @(
            [pscustomobject]@{ Glob = '*.txt'; Negate = $false }, [pscustomobject]@{ Glob = 'a.*'; Negate = $false }, [pscustomobject]@{ Glob = '*.md'; Negate = $false }
        )
        @($files).Count | Should -Be 2
        [System.IO.Path]::IsPathFullyQualified($files[0]) | Should -BeTrue
        @($files) | Should -Be @(@($files) | Sort-Object)
    }

    It 'applies exclusions' {
        $actual = Get-TestGlob $script:Tree @('src/**/*.ps1', @{ exclude = 'src/**/*.Tests.ps1' }, @{ exclude = 'src/lib/deep/*' })
        @($actual | Sort-Object) | Should -Be @('src/lib/util.ps1', 'src/main.ps1')
    }

    It 'accepts absolute patterns' {
        $actual = Get-TestGlob $script:Tree @((Join-Path $script:Tree 'docs' '*.md'))
        @($actual | Sort-Object) | Should -Be @('docs/[special].md', 'docs/readme.md')
    }
}

Describe 'TaskFingerprint' {
    Context 'checksum method' {
        BeforeEach {
            $script:Dir = New-TestTree
            $script:Temp = Join-Path $script:Dir '.task'
        }

        It 'is never up to date without sources' {
            Test-Fingerprint (New-FingerprintTask $script:Dir) 'checksum' $script:Temp | Should -BeFalse
        }

        It 'is not up to date on the first run and up to date on the second' {
            $task = New-FingerprintTask $script:Dir -Sources 'src/**/*.ps1'
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeFalse
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeTrue
            Test-Path (Join-Path $script:Temp 'checksum' 'build') | Should -BeTrue
        }

        It 'detects content changes' {
            $task = New-FingerprintTask $script:Dir -Sources 'src/**/*.ps1'
            $null = Test-Fingerprint $task 'checksum' $script:Temp
            $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'main.ps1') -Content 'changed'
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeFalse
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeTrue
        }

        It 'detects added and renamed files' {
            $task = New-FingerprintTask $script:Dir -Sources 'src/*.ps1'
            $null = Test-Fingerprint $task 'checksum' $script:Temp
            $null = Set-TestFile -Path (Join-Path $script:Dir 'src' 'new.ps1') -Content 'new'
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeFalse
            Rename-Item (Join-Path $script:Dir 'src' 'new.ps1') 'renamed.ps1'
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeFalse
        }

        It 'is not up to date while a generated file is missing' {
            $task = New-FingerprintTask $script:Dir -Sources 'src/*.ps1' -Generates 'out/result.zip'
            $null = Test-Fingerprint $task 'checksum' $script:Temp
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeFalse
            $null = Set-TestFile -Path (Join-Path $script:Dir 'out' 'result.zip') -Content 'zip'
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeTrue
        }

        It 'does not write state in dry mode' {
            $task = New-FingerprintTask $script:Dir -Sources 'src/*.ps1'
            Test-Fingerprint $task 'checksum' $script:Temp -Dry | Should -BeFalse
            Test-Path (Join-Path $script:Temp 'checksum' 'build') | Should -BeFalse
        }

        It 'normalizes the task name for the state file' {
            $task = New-FingerprintTask $script:Dir -Sources 'a.txt' -Name 'ns:build task'
            $null = Test-Fingerprint $task 'checksum' $script:Temp
            Test-Path (Join-Path $script:Temp 'checksum' 'ns-build-task') | Should -BeTrue
        }

        It 'forgets the state after a failure' {
            $task = New-FingerprintTask $script:Dir -Sources 'a.txt'
            $null = Test-Fingerprint $task 'checksum' $script:Temp
            Invoke-InModule { param($t, $d) [TaskFingerprint]::OnError($t, 'checksum', $d) } -ArgumentList $task, $script:Temp
            Test-Fingerprint $task 'checksum' $script:Temp | Should -BeFalse
        }

        It 'exposes the checksum value' {
            $task = New-FingerprintTask $script:Dir -Sources 'a.txt'
            $value = Invoke-InModule { param($t) [TaskFingerprint]::Checksum($t) } -ArgumentList $task
            $value | Should -Match '^[0-9a-f]{32}$'
        }
    }

    Context 'timestamp method' {
        BeforeEach {
            $script:Dir = New-TestTree
            $script:Temp = Join-Path $script:Dir '.task'
        }

        It 'is not up to date on the first run and up to date on the second' {
            $task = New-FingerprintTask $script:Dir -Sources 'src/*.ps1'
            Test-Fingerprint $task 'timestamp' $script:Temp | Should -BeFalse
            Test-Fingerprint $task 'timestamp' $script:Temp | Should -BeTrue
        }

        It 'detects a source newer than the generated files' {
            $task = New-FingerprintTask $script:Dir -Sources 'src/*.ps1' -Generates 'out/result.zip'
            $output = Set-TestFile -Path (Join-Path $script:Dir 'out' 'result.zip') -Content 'zip'
            (Get-Item $output).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
            $null = Test-Fingerprint $task 'timestamp' $script:Temp
            (Get-Item (Join-Path $script:Temp 'timestamp' 'build')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-10)
            (Get-Item (Join-Path $script:Dir 'src' 'main.ps1')).LastWriteTimeUtc = [datetime]::UtcNow.AddMinutes(-5)
            Test-Fingerprint $task 'timestamp' $script:Temp | Should -BeFalse
        }

        It 'exposes the newest source time' {
            $task = New-FingerprintTask $script:Dir -Sources 'a.txt'
            $stamp = [datetime]::new(2024, 3, 5, 1, 2, 3, [DateTimeKind]::Utc)
            (Get-Item (Join-Path $script:Dir 'a.txt')).LastWriteTimeUtc = $stamp
            $value = Invoke-InModule { param($t) [TaskFingerprint]::Timestamp($t) } -ArgumentList $task
            $value.UtcDateTime | Should -Be $stamp
        }
    }

    Context 'none method' {
        It 'is never up to date' {
            $dir = New-TestTree
            $task = New-FingerprintTask $dir -Sources 'a.txt'
            Test-Fingerprint $task 'none' (Join-Path $dir '.task') | Should -BeFalse
            Test-Fingerprint $task 'none' (Join-Path $dir '.task') | Should -BeFalse
        }
    }
}
