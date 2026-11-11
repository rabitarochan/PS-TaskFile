using namespace System.Collections.Generic
using namespace System.Text
using namespace System.Text.RegularExpressions

# Glob expansion for sources/generates and the "is this task up to date" checks.

[NoRunspaceAffinity()]
class TaskGlob {
    hidden static [bool] HasMeta([string] $text) { return $text.IndexOfAny([char[]]'*?[{') -ge 0 }

    # Converts one path segment of a glob into an anchored regular expression.
    hidden static [string] SegmentPattern([string] $segment) {
        $sb = [StringBuilder]::new()
        $i = 0
        $n = $segment.Length
        while ($i -lt $n) {
            $c = $segment[$i]
            if ($c -eq '*') { [void]$sb.Append('[^/\\]*') }
            elseif ($c -eq '?') { [void]$sb.Append('[^/\\]') }
            elseif ($c -eq '[') {
                $close = $segment.IndexOf(']', $i + 2)
                if ($close -lt 0) { [void]$sb.Append('\[') }
                else {
                    $body = $segment.Substring($i + 1, $close - $i - 1)
                    $negate = $body.StartsWith('!') -or $body.StartsWith('^')
                    if ($negate) { $body = $body.Substring(1) }
                    [void]$sb.Append('[').Append($(if ($negate) { '^' } else { '' })).Append($body.Replace('\', '\\').Replace('[', '\[')).Append(']')
                    $i = $close
                }
            }
            elseif ($c -eq '{') {
                $close = $segment.IndexOf('}', $i + 1)
                if ($close -lt 0) { [void]$sb.Append('\{') }
                else {
                    $alternatives = [List[string]]::new()
                    foreach ($alternative in $segment.Substring($i + 1, $close - $i - 1).Split(',')) {
                        $inner = [TaskGlob]::SegmentPattern($alternative)
                        $alternatives.Add($inner.Substring(1, $inner.Length - 2))
                    }
                    [void]$sb.Append('(?:').Append([string]::Join('|', $alternatives)).Append(')')
                    $i = $close
                }
            }
            else { [void]$sb.Append([regex]::Escape([string]$c)) }
            $i++
        }
        return '^' + $sb.ToString() + '$'
    }

    hidden static [void] AddAllFiles([string] $directory, [List[string]] $results) {
        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($directory)) { $results.Add($file) }
            foreach ($child in [System.IO.Directory]::EnumerateDirectories($directory)) { [TaskGlob]::AddAllFiles($child, $results) }
        }
        catch [System.UnauthorizedAccessException] { }
        catch [System.IO.IOException] { }
    }

    hidden static [void] Walk([string] $directory, [string[]] $segments, [int] $index, [List[string]] $results) {
        if ($index -ge $segments.Count) { return }
        $segment = $segments[$index]
        $last = $index -eq $segments.Count - 1
        try {
            if ($segment -eq '**') {
                if ($last) { [TaskGlob]::AddAllFiles($directory, $results); return }
                [TaskGlob]::Walk($directory, $segments, $index + 1, $results)
                foreach ($child in [System.IO.Directory]::EnumerateDirectories($directory)) { [TaskGlob]::Walk($child, $segments, $index, $results) }
                return
            }
            if (-not [TaskGlob]::HasMeta($segment)) {
                $next = [System.IO.Path]::Combine($directory, $segment)
                if ($last) { if ([System.IO.File]::Exists($next)) { $results.Add($next) } }
                elseif ([System.IO.Directory]::Exists($next)) { [TaskGlob]::Walk($next, $segments, $index + 1, $results) }
                return
            }
            $options = if ($global:IsWindows) { [RegexOptions]::IgnoreCase } else { [RegexOptions]::None }
            $regex = [regex]::new([TaskGlob]::SegmentPattern($segment), $options)
            if ($last) {
                foreach ($file in [System.IO.Directory]::EnumerateFiles($directory)) {
                    if ($regex.IsMatch([System.IO.Path]::GetFileName($file))) { $results.Add($file) }
                }
            }
            else {
                foreach ($child in [System.IO.Directory]::EnumerateDirectories($directory)) {
                    if ($regex.IsMatch([System.IO.Path]::GetFileName($child))) { [TaskGlob]::Walk($child, $segments, $index + 1, $results) }
                }
            }
        }
        catch [System.UnauthorizedAccessException] { }
        catch [System.IO.IOException] { }
    }

    # Files (never directories) matching one glob. Relative globs are resolved against $directory.
    static [List[string]] ExpandOne([string] $directory, [string] $pattern) {
        $results = [List[string]]::new()
        if ([string]::IsNullOrEmpty($pattern)) { return $results }
        $full = [TaskPath]::ExpandHome($pattern)
        if (-not [System.IO.Path]::IsPathFullyQualified($full)) { $full = [System.IO.Path]::Combine($directory, $full) }
        $root = [System.IO.Path]::GetPathRoot($full)
        $rest = $full.Substring($root.Length)
        $segments = [List[string]]::new()
        foreach ($part in $rest.Split([char[]]@('/', '\'), [StringSplitOptions]::RemoveEmptyEntries)) {
            if ($part -eq '.') { continue }
            if ($part -eq '..' -and $segments.Count -gt 0 -and -not [TaskGlob]::HasMeta($segments[$segments.Count - 1])) {
                $segments.RemoveAt($segments.Count - 1)
                continue
            }
            $segments.Add($part)
        }
        if ($segments.Count -eq 0 -or -not [System.IO.Directory]::Exists($root)) { return $results }
        [TaskGlob]::Walk($root, $segments.ToArray(), 0, $results)
        return $results
    }

    # Applies the globs in order (exclusions remove earlier matches) and returns sorted paths.
    static [string[]] Expand([string] $directory, [object] $globs) {
        $comparer = if ($global:IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
        $state = [Dictionary[string, bool]]::new($comparer)
        foreach ($glob in $globs) {
            foreach ($match in [TaskGlob]::ExpandOne($directory, [string]$glob.Glob)) { $state[$match] = -not $glob.Negate }
        }
        $files = [List[string]]::new()
        foreach ($pair in $state.GetEnumerator()) { if ($pair.Value) { $files.Add($pair.Key) } }
        $array = $files.ToArray()
        [Array]::Sort($array, [StringComparer]::Ordinal)
        return $array
    }
}

[NoRunspaceAffinity()]
class TaskFingerprint {
    static [string] NormalizeName([string] $name) { return [regex]::Replace($name, '[^A-z0-9]', '-') }

    static [string] StateFile([string] $tempDir, [string] $kind, [object] $task) {
        $name = if ([string]::IsNullOrEmpty($task.Label)) { $task.Task } else { $task.Label }
        return [System.IO.Path]::Combine($tempDir, $kind, [TaskFingerprint]::NormalizeName($name))
    }

    # Hash over the names and contents of the source files (the {{.CHECKSUM}} value).
    static [string] Checksum([object] $task) {
        $hash = [System.Security.Cryptography.IncrementalHash]::CreateHash([System.Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $buffer = [byte[]]::new(81920)
            foreach ($file in [TaskGlob]::Expand($task.Dir, $task.Sources)) {
                $hash.AppendData([Encoding]::UTF8.GetBytes([System.IO.Path]::GetFileName($file)))
                $stream = [System.IO.File]::Open($file, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) { $hash.AppendData($buffer, 0, $read) }
                }
                finally { $stream.Dispose() }
            }
            return [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant().Substring(0, 32)
        }
        finally { $hash.Dispose() }
    }

    # Modification time of the newest source file (the {{.TIMESTAMP}} value).
    static [DateTimeOffset] Timestamp([object] $task) {
        $newest = [datetime]::MinValue
        foreach ($file in [TaskGlob]::Expand($task.Dir, $task.Sources)) {
            $time = [System.IO.File]::GetLastWriteTimeUtc($file)
            if ($time -gt $newest) { $newest = $time }
        }
        if ($newest -eq [datetime]::MinValue) { return [DateTimeOffset]::MinValue }
        return [DateTimeOffset]::new($newest).ToLocalTime()
    }

    hidden static [bool] ChecksumUpToDate([object] $task, [string] $tempDir, [bool] $dry) {
        $stateFile = [TaskFingerprint]::StateFile($tempDir, 'checksum', $task)
        $old = if ([System.IO.File]::Exists($stateFile)) { [System.IO.File]::ReadAllText($stateFile).Trim() } else { '' }
        $new = ''
        try { $new = [TaskFingerprint]::Checksum($task) } catch { return $false }
        if (-not $dry -and $old -cne $new) {
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($stateFile))
            [System.IO.File]::WriteAllText($stateFile, $new + "`n")
        }
        foreach ($glob in $task.Generates) {
            if ($glob.Negate) { continue }
            if ([TaskGlob]::ExpandOne($task.Dir, [string]$glob.Glob).Count -eq 0) { return $false }
        }
        return $old -ceq $new
    }

    hidden static [bool] TimestampUpToDate([object] $task, [string] $tempDir, [bool] $dry) {
        $sources = [TaskGlob]::Expand($task.Dir, $task.Sources)
        $generates = [List[string]]::new([string[]][TaskGlob]::Expand($task.Dir, $task.Generates))
        $stateFile = [TaskFingerprint]::StateFile($tempDir, 'timestamp', $task)
        if ([System.IO.File]::Exists($stateFile)) { $generates.Add($stateFile) }
        elseif (-not $dry) {
            $null = [System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($stateFile))
            [System.IO.File]::WriteAllBytes($stateFile, [byte[]]::new(0))
        }
        $now = [datetime]::UtcNow
        $newestGenerated = [datetime]::MinValue
        foreach ($file in $generates) {
            $time = [System.IO.File]::GetLastWriteTimeUtc($file)
            if ($time -gt $newestGenerated) { $newestGenerated = $time }
        }
        $upToDate = $newestGenerated -ne [datetime]::MinValue
        if ($upToDate) {
            foreach ($file in $sources) {
                if ([System.IO.File]::GetLastWriteTimeUtc($file) -gt $newestGenerated) { $upToDate = $false; break }
            }
        }
        if (-not $dry -and [System.IO.File]::Exists($stateFile)) { [System.IO.File]::SetLastWriteTimeUtc($stateFile, $now) }
        return $upToDate
    }

    # Whether the sources of the task are unchanged. $method is checksum (default), timestamp or none.
    static [bool] IsUpToDate([object] $task, [string] $method, [string] $tempDir, [bool] $dry) {
        if (@($task.Sources).Count -eq 0) { return $false }
        if ($method -eq 'none') { return $false }
        if ($method -eq 'timestamp') { return [TaskFingerprint]::TimestampUpToDate($task, $tempDir, $dry) }
        return [TaskFingerprint]::ChecksumUpToDate($task, $tempDir, $dry)
    }

    # Drops the stored state so that a failed task runs again next time.
    static [void] OnError([object] $task, [string] $method, [string] $tempDir) {
        if (@($task.Sources).Count -eq 0 -or $method -eq 'none') { return }
        $kind = if ($method -eq 'timestamp') { 'timestamp' } else { 'checksum' }
        $stateFile = [TaskFingerprint]::StateFile($tempDir, $kind, $task)
        if ([System.IO.File]::Exists($stateFile)) { [System.IO.File]::Delete($stateFile) }
    }
}
