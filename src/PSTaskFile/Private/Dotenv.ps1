using namespace System.Collections.Specialized
using namespace System.Text

# .env file parser (the format understood by godotenv, which go-task uses).

[NoRunspaceAffinity()]
class TaskDotenv {
    static [OrderedDictionary] Read([string] $path) {
        return [TaskDotenv]::Parse([System.IO.File]::ReadAllText($path))
    }

    hidden static [string] Expand([string] $value, [OrderedDictionary] $known) {
        return [regex]::Replace($value, '(\\)?\$(?:\{([A-Za-z0-9_]+)\}|([A-Za-z0-9_]+))', {
                param($match)
                if ($match.Groups[1].Success) { return $match.Value.Substring(1) }
                $name = if ($match.Groups[2].Success) { $match.Groups[2].Value } else { $match.Groups[3].Value }
                if ($known.Contains($name)) { return [string]$known[$name] }
                $fromEnvironment = [Environment]::GetEnvironmentVariable($name)
                if ($null -ne $fromEnvironment) { return $fromEnvironment }
                return ''
            }.GetNewClosure())
    }

    static [OrderedDictionary] Parse([string] $text) {
        $result = [OrderedDictionary]::new()
        $source = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        $length = $source.Length
        $i = 0
        while ($i -lt $length) {
            while ($i -lt $length -and [char]::IsWhiteSpace($source[$i])) { $i++ }
            if ($i -ge $length) { break }
            $lineEnd = $source.IndexOf("`n", $i)
            if ($lineEnd -lt 0) { $lineEnd = $length }
            if ($source[$i] -eq '#') { $i = $lineEnd; continue }

            $line = $source.Substring($i, $lineEnd - $i)
            $match = [regex]::Match($line, '^(?:export\s+)?([A-Za-z_][A-Za-z0-9_.\-]*)[ \t]*[=:][ \t]*')
            if (-not $match.Success) { throw "unexpected character in variable name near `"$line`"" }
            $key = $match.Groups[1].Value
            $position = $i + $match.Length
            $value = ''

            if ($position -ge $lineEnd) {
                $i = $lineEnd
            }
            elseif ($source[$position] -eq "'") {
                $close = $source.IndexOf("'", $position + 1)
                if ($close -lt 0) { throw "unterminated quoted value for `"$key`"" }
                $value = $source.Substring($position + 1, $close - $position - 1)
                $i = $source.IndexOf("`n", $close)
                if ($i -lt 0) { $i = $length }
            }
            elseif ($source[$position] -eq '"') {
                $builder = [StringBuilder]::new()
                $j = $position + 1
                $closed = $false
                while ($j -lt $length) {
                    $c = $source[$j]
                    if ($c -eq '"') { $closed = $true; break }
                    if ($c -eq '\' -and $j + 1 -lt $length) {
                        $next = $source[$j + 1]
                        if ($next -eq 'n') { [void]$builder.Append("`n") }
                        elseif ($next -eq 'r') { [void]$builder.Append("`r") }
                        elseif ($next -eq 't') { [void]$builder.Append("`t") }
                        elseif ($next -eq '$') { [void]$builder.Append('\$') }
                        else { [void]$builder.Append($next) }
                        $j += 2
                        continue
                    }
                    [void]$builder.Append($c)
                    $j++
                }
                if (-not $closed) { throw "unterminated quoted value for `"$key`"" }
                $value = [TaskDotenv]::Expand($builder.ToString(), $result)
                $i = $source.IndexOf("`n", $j)
                if ($i -lt 0) { $i = $length }
            }
            else {
                $raw = $source.Substring($position, $lineEnd - $position)
                $comment = [regex]::Match($raw, '\s#')
                if ($comment.Success) { $raw = $raw.Substring(0, $comment.Index) }
                $value = [TaskDotenv]::Expand($raw.Trim(), $result)
                $i = $lineEnd
            }
            $result[$key] = $value
        }
        return $result
    }
}
