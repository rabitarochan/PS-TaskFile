using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Collections.Specialized
using namespace System.Globalization
using namespace System.Text

# A Go text/template compatible engine (the subset Task uses) plus the slim-sprig and
# Task template functions.
#
# The classes are marked [NoRunspaceAffinity()] because the engine runs in several
# runspaces at once (parallel tasks). They must stay self-contained: no calls to
# module-private functions from inside the classes.

[NoRunspaceAffinity()]
class TplToken {
    [string] $Kind
    [object] $Value
    [string[]] $Fields = @()
    [bool] $Adjacent
}

[NoRunspaceAffinity()]
class TplNode {
    [string] $Kind
    [object] $Value
    [string[]] $Fields = @()
    [List[TplNode]] $Items = [List[TplNode]]::new()
    [TplNode] $Pipe
    [TplNode] $List
    [TplNode] $ElseList
    [string[]] $Decl = @()
    [bool] $IsAssign

    TplNode([string] $kind) { $this.Kind = $kind }
    TplNode([string] $kind, [object] $value) { $this.Kind = $kind; $this.Value = $value }
}

[NoRunspaceAffinity()]
class TplParser {
    hidden static [System.Collections.Concurrent.ConcurrentDictionary[string, object]] $Cache = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()

    [TplNode] $Root
    [Dictionary[string, TplNode]] $Templates = [Dictionary[string, TplNode]]::new()

    hidden [string] $Source
    hidden [List[TplNode]] $Raw = [List[TplNode]]::new()
    hidden [int] $RawIndex
    hidden [List[TplToken]] $Tok
    hidden [int] $Ti
    hidden [string] $Terminator
    hidden [List[TplToken]] $TermTokens
    hidden [List[string]] $VarNames = [List[string]]::new()
    hidden [int] $RangeDepth

    static [TplParser] Parse([string] $text) {
        $cached = $null
        if ([TplParser]::Cache.TryGetValue($text, [ref] $cached)) { return $cached }
        $parser = [TplParser]::new()
        $parser.Source = $text
        $parser.Scan()
        $parser.VarNames.Add('$')
        $parser.Root = $parser.ParseList($true)
        if ([TplParser]::Cache.Count -gt 4096) { [TplParser]::Cache.Clear() }
        [TplParser]::Cache[$text] = $parser
        return $parser
    }

    hidden static [bool] IsSpace([char] $c) {
        return $c -eq ' ' -or $c -eq "`t" -or $c -eq "`r" -or $c -eq "`n"
    }

    hidden static [bool] IsIdentChar([char] $c) {
        return $c -eq '_' -or [char]::IsLetterOrDigit($c)
    }

    # Splits the template into text and raw action items, applying trim markers.
    hidden [void] Scan() {
        $t = $this.Source
        $n = $t.Length
        $pos = 0
        $trimNext = $false
        $ws = [char[]]@(' ', "`t", "`r", "`n")
        while ($true) {
            $open = $t.IndexOf('{{', $pos, [StringComparison]::Ordinal)
            if ($open -lt 0) {
                $chunk = $t.Substring($pos)
                if ($trimNext) { $chunk = $chunk.TrimStart($ws) }
                if ($chunk.Length -gt 0) { $this.Raw.Add([TplNode]::new('text', $chunk)) }
                break
            }
            $chunk = $t.Substring($pos, $open - $pos)
            if ($trimNext) { $chunk = $chunk.TrimStart($ws); $trimNext = $false }
            $start = $open + 2
            if ($start + 1 -lt $n -and $t[$start] -eq '-' -and [TplParser]::IsSpace($t[$start + 1])) {
                $chunk = $chunk.TrimEnd($ws)
                $start++
            }
            if ($chunk.Length -gt 0) { $this.Raw.Add([TplNode]::new('text', $chunk)) }
            $end = $this.FindActionEnd($start)
            $inner = $t.Substring($start, $end - $start)
            if ($inner.Length -ge 2 -and $inner[$inner.Length - 1] -eq '-' -and [TplParser]::IsSpace($inner[$inner.Length - 2])) {
                $inner = $inner.Substring(0, $inner.Length - 1)
                $trimNext = $true
            }
            $trimmed = $inner.Trim()
            if ($trimmed.StartsWith('/*', [StringComparison]::Ordinal)) {
                if (-not $trimmed.EndsWith('*/', [StringComparison]::Ordinal)) { throw 'comment ends before closing delimiter' }
            }
            else {
                $this.Raw.Add([TplNode]::new('action', $inner))
            }
            $pos = $end + 2
        }
    }

    hidden [int] FindActionEnd([int] $start) {
        $t = $this.Source
        $n = $t.Length
        $i = $start
        while ($i -lt $n) {
            $c = $t[$i]
            if ($c -eq '"' -or $c -eq "'") {
                $j = $i + 1
                while ($j -lt $n -and $t[$j] -ne $c) {
                    if ($t[$j] -eq '\') { $j++ }
                    elseif ($t[$j] -eq "`n") { break }
                    $j++
                }
                if ($j -ge $n -or $t[$j] -ne $c) { throw 'unterminated quoted string' }
                $i = $j
            }
            elseif ($c -eq '`') {
                $j = $t.IndexOf('`', $i + 1)
                if ($j -lt 0) { throw 'unterminated raw quoted string' }
                $i = $j
            }
            elseif ($c -eq '/' -and $i + 1 -lt $n -and $t[$i + 1] -eq '*') {
                $j = $t.IndexOf('*/', $i + 2, [StringComparison]::Ordinal)
                if ($j -lt 0) { throw 'unclosed comment' }
                $i = $j + 1
            }
            elseif ($c -eq '}' -and $i + 1 -lt $n -and $t[$i + 1] -eq '}') {
                return $i
            }
            $i++
        }
        throw 'unclosed action'
    }

    hidden static [string[]] ReadFields([string] $s, [ref] $index) {
        $fields = [List[string]]::new()
        $i = [int]$index.Value
        $n = $s.Length
        while ($i + 1 -lt $n -and $s[$i] -eq '.' -and [TplParser]::IsIdentChar($s[$i + 1])) {
            $j = $i + 1
            while ($j -lt $n -and [TplParser]::IsIdentChar($s[$j])) { $j++ }
            $fields.Add($s.Substring($i + 1, $j - $i - 1))
            $i = $j
        }
        $index.Value = $i
        return $fields.ToArray()
    }

    hidden static [object] ParseNumber([string] $text) {
        $s = $text.Replace('_', '')
        $negative = $false
        if ($s.StartsWith('+')) { $s = $s.Substring(1) }
        elseif ($s.StartsWith('-')) { $negative = $true; $s = $s.Substring(1) }
        $value = $null
        try {
            if ($s.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) { $value = [Convert]::ToInt64($s.Substring(2), 16) }
            elseif ($s.StartsWith('0o', [StringComparison]::OrdinalIgnoreCase)) { $value = [Convert]::ToInt64($s.Substring(2), 8) }
            elseif ($s.StartsWith('0b', [StringComparison]::OrdinalIgnoreCase)) { $value = [Convert]::ToInt64($s.Substring(2), 2) }
            elseif ($s.IndexOfAny([char[]]'.eEpP') -ge 0) { $value = [double]::Parse($s, [NumberStyles]::Float, [CultureInfo]::InvariantCulture) }
            else { $value = [long]::Parse($s, [NumberStyles]::None, [CultureInfo]::InvariantCulture) }
            if ($value -is [long]) { if ($negative) { $value = - $value; $negative = $false }; $value = [TplFn]::GoInt($value) }
        }
        catch {
            throw "bad number syntax: `"$text`""
        }
        if ($negative) { $value = - $value }
        return $value
    }

    hidden static [string] ReadEscape([string] $s, [ref] $index) {
        # $index points at the character after the backslash.
        $i = [int]$index.Value
        if ($i -ge $s.Length) { throw 'unterminated quoted string' }
        $e = $s[$i]
        $result = ''
        switch -CaseSensitive ([string]$e) {
            'n' { $result = "`n" }
            't' { $result = "`t" }
            'r' { $result = "`r" }
            'a' { $result = [string][char]7 }
            'b' { $result = [string][char]8 }
            'f' { $result = [string][char]12 }
            'v' { $result = [string][char]11 }
            '\' { $result = '\' }
            '"' { $result = '"' }
            "'" { $result = "'" }
            'x' { $result = [char]::ConvertFromUtf32([Convert]::ToInt32($s.Substring($i + 1, 2), 16)); $i += 2 }
            'u' { $result = [char]::ConvertFromUtf32([Convert]::ToInt32($s.Substring($i + 1, 4), 16)); $i += 4 }
            'U' { $result = [char]::ConvertFromUtf32([Convert]::ToInt32($s.Substring($i + 1, 8), 16)); $i += 8 }
            default {
                if ($e -ge '0' -and $e -le '7') {
                    $result = [string][char][Convert]::ToInt32($s.Substring($i, 3), 8); $i += 2
                }
                else { throw "invalid syntax: unknown escape \$e" }
            }
        }
        $index.Value = $i
        return $result
    }

    hidden static [List[TplToken]] Tokenize([string] $s) {
        $tokens = [List[TplToken]]::new()
        $n = $s.Length
        $i = 0
        $adjacent = $false
        while ($i -lt $n) {
            $c = $s[$i]
            if ([TplParser]::IsSpace($c)) { $i++; $adjacent = $false; continue }
            $token = [TplToken]::new()
            $token.Adjacent = $adjacent
            if ($c -eq '"') {
                $sb = [StringBuilder]::new()
                $j = $i + 1
                while ($true) {
                    if ($j -ge $n) { throw 'unterminated quoted string' }
                    $d = $s[$j]
                    if ($d -eq '"') { break }
                    if ($d -eq '\') {
                        $j++
                        $ref = [ref] $j
                        [void]$sb.Append([TplParser]::ReadEscape($s, $ref))
                        $j = [int]$ref.Value + 1
                        continue
                    }
                    [void]$sb.Append($d)
                    $j++
                }
                $token.Kind = 'string'; $token.Value = $sb.ToString()
                $i = $j + 1
            }
            elseif ($c -eq '`') {
                $j = $s.IndexOf('`', $i + 1)
                if ($j -lt 0) { throw 'unterminated raw quoted string' }
                $token.Kind = 'string'; $token.Value = $s.Substring($i + 1, $j - $i - 1)
                $i = $j + 1
            }
            elseif ($c -eq "'") {
                $j = $i + 1
                $text = ''
                if ($j -lt $n -and $s[$j] -eq '\') {
                    $j++
                    $ref = [ref] $j
                    $text = [TplParser]::ReadEscape($s, $ref)
                    $j = [int]$ref.Value + 1
                }
                else {
                    $end = $s.IndexOf("'", $j)
                    if ($end -lt 0) { throw 'unterminated character constant' }
                    $text = $s.Substring($j, $end - $j)
                    $j = $end
                }
                if ($j -ge $n -or $s[$j] -ne "'" -or $text.Length -eq 0) { throw 'malformed character constant' }
                $token.Kind = 'number'; $token.Value = [int][char]::ConvertToUtf32($text, 0)
                $i = $j + 1
            }
            elseif ($c -eq '|') { $token.Kind = 'pipe'; $i++ }
            elseif ($c -eq '(') { $token.Kind = 'lparen'; $i++ }
            elseif ($c -eq ')') { $token.Kind = 'rparen'; $i++ }
            elseif ($c -eq ',') { $token.Kind = 'comma'; $i++ }
            elseif ($c -eq ':' -and $i + 1 -lt $n -and $s[$i + 1] -eq '=') { $token.Kind = 'declare'; $i += 2 }
            elseif ($c -eq '=') { $token.Kind = 'assign'; $i++ }
            elseif ($c -eq '$') {
                $j = $i + 1
                while ($j -lt $n -and [TplParser]::IsIdentChar($s[$j])) { $j++ }
                $token.Kind = 'var'; $token.Value = $s.Substring($i, $j - $i)
                $ref = [ref] $j
                $token.Fields = [TplParser]::ReadFields($s, $ref)
                $i = [int]$ref.Value
            }
            elseif ($c -eq '.' -and $i + 1 -lt $n -and [char]::IsDigit($s[$i + 1])) {
                $j = $i + 1
                while ($j -lt $n -and ([TplParser]::IsIdentChar($s[$j]) -or $s[$j] -eq '.')) { $j++ }
                $token.Kind = 'number'; $token.Value = [TplParser]::ParseNumber($s.Substring($i, $j - $i))
                $i = $j
            }
            elseif ($c -eq '.') {
                if ($i + 1 -lt $n -and [TplParser]::IsIdentChar($s[$i + 1])) {
                    $ref = [ref] $i
                    $token.Kind = 'field'; $token.Fields = [TplParser]::ReadFields($s, $ref)
                    $i = [int]$ref.Value
                }
                else { $token.Kind = 'dot'; $i++ }
            }
            elseif ([char]::IsDigit($c) -or (($c -eq '+' -or $c -eq '-') -and $i + 1 -lt $n -and ([char]::IsDigit($s[$i + 1]) -or $s[$i + 1] -eq '.'))) {
                $j = $i + 1
                while ($j -lt $n) {
                    $d = $s[$j]
                    if ([TplParser]::IsIdentChar($d) -or $d -eq '.') { $j++; continue }
                    if (($d -eq '+' -or $d -eq '-') -and ($s[$j - 1] -eq 'e' -or $s[$j - 1] -eq 'E') -and -not $s.Substring($i, $j - $i).TrimStart('+', '-').StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) { $j++; continue }
                    break
                }
                $token.Kind = 'number'; $token.Value = [TplParser]::ParseNumber($s.Substring($i, $j - $i))
                $i = $j
            }
            elseif ([TplParser]::IsIdentChar($c)) {
                $j = $i
                while ($j -lt $n -and [TplParser]::IsIdentChar($s[$j])) { $j++ }
                $word = $s.Substring($i, $j - $i)
                if ($word -ceq 'true') { $token.Kind = 'bool'; $token.Value = $true }
                elseif ($word -ceq 'false') { $token.Kind = 'bool'; $token.Value = $false }
                elseif ($word -ceq 'nil') { $token.Kind = 'nil' }
                else { $token.Kind = 'ident'; $token.Value = $word }
                $i = $j
            }
            else {
                throw "unexpected `"$c`" in command"
            }
            $tokens.Add($token)
            $adjacent = $true
        }
        return $tokens
    }

    hidden [TplNode] ParseList([bool] $top) {
        $list = [TplNode]::new('list')
        while ($this.RawIndex -lt $this.Raw.Count) {
            $item = $this.Raw[$this.RawIndex]
            $this.RawIndex++
            if ($item.Kind -eq 'text') { $list.Items.Add($item); continue }
            $tokens = [TplParser]::Tokenize([string]$item.Value)
            if ($tokens.Count -eq 0) { throw 'missing value for command' }
            $first = $tokens[0]
            $keyword = if ($first.Kind -eq 'ident') { [string]$first.Value } else { '' }
            if ($keyword -ceq 'end') {
                if ($top) { throw 'unexpected {{end}}' }
                $this.Terminator = 'end'; $this.TermTokens = $null
                return $list
            }
            if ($keyword -ceq 'else') {
                if ($top) { throw 'unexpected {{else}}' }
                $this.Terminator = 'else'
                $this.TermTokens = $tokens.GetRange(1, $tokens.Count - 1)
                return $list
            }
            if ($keyword -ceq 'if' -or $keyword -ceq 'range' -or $keyword -ceq 'with') {
                $this.Tok = $tokens; $this.Ti = 1
                $list.Items.Add($this.ParseControl($keyword))
                continue
            }
            if ($keyword -ceq 'break' -or $keyword -ceq 'continue') {
                if ($this.RangeDepth -eq 0) { throw "{{$keyword}} outside {{range}}" }
                $list.Items.Add([TplNode]::new($keyword))
                continue
            }
            if ($keyword -ceq 'define' -or $keyword -ceq 'block') {
                if ($tokens.Count -lt 2 -or $tokens[1].Kind -ne 'string') { throw "missing name in $keyword clause" }
                $name = [string]$tokens[1].Value
                $pipe = $null
                if ($keyword -ceq 'block') {
                    $this.Tok = $tokens; $this.Ti = 2
                    $pipe = $this.ParsePipeline($false, $false)
                }
                $savedVars = $this.VarNames
                $this.VarNames = [List[string]]::new()
                $this.VarNames.Add('$')
                $savedDepth = $this.RangeDepth
                $this.RangeDepth = 0
                $body = $this.ParseList($false)
                if ($this.Terminator -ne 'end') { throw "unexpected {{else}} in $keyword clause" }
                $this.VarNames = $savedVars
                $this.RangeDepth = $savedDepth
                $this.Templates[$name] = $body
                if ($keyword -ceq 'block') {
                    $node = [TplNode]::new('template', $name)
                    $node.Pipe = $pipe
                    $list.Items.Add($node)
                }
                continue
            }
            if ($keyword -ceq 'template') {
                if ($tokens.Count -lt 2 -or $tokens[1].Kind -ne 'string') { throw 'missing name in template clause' }
                $node = [TplNode]::new('template', [string]$tokens[1].Value)
                if ($tokens.Count -gt 2) {
                    $this.Tok = $tokens; $this.Ti = 2
                    $node.Pipe = $this.ParsePipeline($false, $false)
                }
                $list.Items.Add($node)
                continue
            }
            $this.Tok = $tokens; $this.Ti = 0
            $action = [TplNode]::new('action')
            $action.Pipe = $this.ParsePipeline($false, $false)
            $list.Items.Add($action)
        }
        if (-not $top) { throw 'unexpected EOF' }
        $this.Terminator = 'eof'
        return $list
    }

    hidden [TplNode] ParseControl([string] $kind) {
        $node = [TplNode]::new($kind)
        $mark = $this.VarNames.Count
        $node.Pipe = $this.ParsePipeline($false, $kind -ceq 'range')
        if ($kind -ceq 'range') { $this.RangeDepth++ }
        $node.List = $this.ParseList($false)
        if ($kind -ceq 'range') { $this.RangeDepth-- }
        if ($this.Terminator -eq 'else') {
            $rest = $this.TermTokens
            if ($null -ne $rest -and $rest.Count -gt 0) {
                $nestedKind = if ($rest[0].Kind -eq 'ident') { [string]$rest[0].Value } else { '' }
                if ($nestedKind -cne 'if' -and $nestedKind -cne 'with') { throw 'unexpected token in {{else}}' }
                $this.Tok = $rest; $this.Ti = 1
                $elseList = [TplNode]::new('list')
                $elseList.Items.Add($this.ParseControl($nestedKind))
                $node.ElseList = $elseList
            }
            else {
                $node.ElseList = $this.ParseList($false)
                if ($this.Terminator -ne 'end') { throw 'expected end; found {{else}}' }
            }
        }
        $this.VarNames.RemoveRange($mark, $this.VarNames.Count - $mark)
        return $node
    }

    hidden [TplNode] ParsePipeline([bool] $inParen, [bool] $isRange) {
        $t = $this.Tok
        $pipe = [TplNode]::new('pipe')
        $i = $this.Ti
        if (-not $inParen -and $i -lt $t.Count -and $t[$i].Kind -eq 'var' -and $t[$i].Fields.Count -eq 0) {
            $decl = $null
            $isAssign = $false
            if ($i + 1 -lt $t.Count -and ($t[$i + 1].Kind -eq 'declare' -or $t[$i + 1].Kind -eq 'assign')) {
                $decl = @([string]$t[$i].Value)
                $isAssign = $t[$i + 1].Kind -eq 'assign'
                $this.Ti = $i + 2
            }
            elseif ($isRange -and $i + 3 -lt $t.Count -and $t[$i + 1].Kind -eq 'comma' -and $t[$i + 2].Kind -eq 'var' -and ($t[$i + 3].Kind -eq 'declare' -or $t[$i + 3].Kind -eq 'assign')) {
                $decl = @([string]$t[$i].Value, [string]$t[$i + 2].Value)
                $isAssign = $t[$i + 3].Kind -eq 'assign'
                $this.Ti = $i + 4
            }
            if ($null -ne $decl) {
                $pipe.Decl = [string[]]$decl
                $pipe.IsAssign = $isAssign
                foreach ($name in $decl) {
                    if ($isAssign) {
                        if (-not $this.VarNames.Contains($name)) { throw "undefined variable `"$name`"" }
                    }
                    else { $this.VarNames.Add($name) }
                }
            }
        }
        while ($true) {
            $command = [TplNode]::new('cmd')
            while ($this.Ti -lt $t.Count) {
                $kind = $t[$this.Ti].Kind
                if ($kind -eq 'pipe' -or $kind -eq 'rparen') { break }
                $command.Items.Add($this.ParseOperand())
            }
            if ($command.Items.Count -eq 0) { throw 'missing value for command' }
            $pipe.Items.Add($command)
            if ($this.Ti -lt $t.Count -and $t[$this.Ti].Kind -eq 'pipe') { $this.Ti++; continue }
            break
        }
        if ($inParen) {
            if ($this.Ti -ge $t.Count -or $t[$this.Ti].Kind -ne 'rparen') { throw 'unclosed left paren' }
            $this.Ti++
        }
        elseif ($this.Ti -lt $t.Count) {
            throw 'unexpected right paren'
        }
        return $pipe
    }

    hidden [TplNode] ParseOperand() {
        $t = $this.Tok
        $token = $t[$this.Ti]
        $this.Ti++
        $node = $null
        switch ($token.Kind) {
            'field' { $node = [TplNode]::new('field'); $node.Fields = $token.Fields }
            'var' {
                if (-not $this.VarNames.Contains([string]$token.Value)) { throw "undefined variable `"$($token.Value)`"" }
                $node = [TplNode]::new('var', $token.Value); $node.Fields = $token.Fields
            }
            'dot' { $node = [TplNode]::new('dot') }
            'nil' { $node = [TplNode]::new('nil') }
            'bool' { $node = [TplNode]::new('bool', $token.Value) }
            'number' { $node = [TplNode]::new('number', $token.Value) }
            'string' { $node = [TplNode]::new('string', $token.Value) }
            'ident' { $node = [TplNode]::new('ident', $token.Value) }
            'lparen' { $node = [TplNode]::new('subpipe'); $node.Pipe = $this.ParsePipeline($true, $false) }
            default { throw "unexpected $($token.Kind) in operand" }
        }
        if ($this.Ti -lt $t.Count -and $t[$this.Ti].Kind -eq 'field' -and $t[$this.Ti].Adjacent) {
            $fields = [List[string]]::new()
            while ($this.Ti -lt $t.Count -and $t[$this.Ti].Kind -eq 'field' -and $t[$this.Ti].Adjacent) {
                $fields.AddRange([string[]]$t[$this.Ti].Fields)
                $this.Ti++
            }
            if ($node.Kind -eq 'field' -or $node.Kind -eq 'var') {
                $node.Fields = [string[]]($node.Fields + $fields.ToArray())
            }
            elseif ($node.Kind -eq 'ident' -or $node.Kind -eq 'subpipe') {
                $chain = [TplNode]::new('chain')
                $chain.Items.Add($node)
                $chain.Fields = $fields.ToArray()
                $node = $chain
            }
            else { throw 'unexpected . after term' }
        }
        return $node
    }
}

[NoRunspaceAffinity()]
class TplExec {
    [StringBuilder] $Out = [StringBuilder]::new()
    [List[object[]]] $Vars = [List[object[]]]::new()
    [Dictionary[string, TplNode]] $Templates
    [int] $Depth

    TplExec([Dictionary[string, TplNode]] $templates, [object] $data) {
        $this.Templates = $templates
        $this.Vars.Add([object[]]@('$', $data))
    }

    hidden [void] PushVar([string] $name, [object] $value) { $this.Vars.Add([object[]]@($name, $value)) }

    hidden [void] SetVar([string] $name, [object] $value) {
        for ($i = $this.Vars.Count - 1; $i -ge 0; $i--) {
            if ([string]$this.Vars[$i][0] -ceq $name) { $this.Vars[$i][1] = $value; return }
        }
        throw "undefined variable: $name"
    }

    hidden [object] GetVar([string] $name) {
        for ($i = $this.Vars.Count - 1; $i -ge 0; $i--) {
            if ([string]$this.Vars[$i][0] -ceq $name) { return $this.Vars[$i][1] }
        }
        throw "undefined variable: $name"
    }

    hidden [void] PopVars([int] $mark) { $this.Vars.RemoveRange($mark, $this.Vars.Count - $mark) }

    # Returns 0 (normal), 1 (break) or 2 (continue).
    [int] Walk([object] $dot, [TplNode] $node) {
        switch ($node.Kind) {
            'list' {
                foreach ($child in $node.Items) {
                    $r = $this.Walk($dot, $child)
                    if ($r -ne 0) { return $r }
                }
                return 0
            }
            'text' { [void]$this.Out.Append([string]$node.Value); return 0 }
            'action' {
                $value = $this.EvalPipeline($dot, $node.Pipe)
                if ($node.Pipe.Decl.Count -eq 0) { [void]$this.Out.Append([TplFn]::Format($value, $true)) }
                return 0
            }
            'break' { return 1 }
            'continue' { return 2 }
            'template' {
                $body = $null
                if (-not $this.Templates.TryGetValue([string]$node.Value, [ref] $body)) { throw "template `"$($node.Value)`" not defined" }
                $newDot = $null
                if ($null -ne $node.Pipe) { $newDot = $this.EvalPipeline($dot, $node.Pipe) }
                if ($this.Depth -ge 1000) { throw 'exceeded maximum template depth (1000)' }
                $saved = $this.Vars
                $this.Vars = [List[object[]]]::new()
                $this.Vars.Add([object[]]@('$', $newDot))
                $this.Depth++
                try { [void]$this.Walk($newDot, $body) }
                finally { $this.Depth--; $this.Vars = $saved }
                return 0
            }
        }
        if ($node.Kind -eq 'if' -or $node.Kind -eq 'with') {
            $mark = $this.Vars.Count
            $value = $this.EvalPipeline($dot, $node.Pipe)
            $r = 0
            if ([TplFn]::Truth($value)) {
                $inner = $dot
                if ($node.Kind -eq 'with') { $inner = $value }
                $r = $this.Walk($inner, $node.List)
            }
            elseif ($null -ne $node.ElseList) {
                $r = $this.Walk($dot, $node.ElseList)
            }
            $this.PopVars($mark)
            return $r
        }
        if ($node.Kind -eq 'range') { return $this.WalkRange($dot, $node) }
        throw "unknown node $($node.Kind)"
    }

    hidden [int] WalkRange([object] $dot, [TplNode] $node) {
        $mark = $this.Vars.Count
        $value = [TplFn]::Unwrap($this.EvalPipeline($dot, $node.Pipe))
        $decl = $node.Pipe.Decl
        $indexes = [List[object]]::new()
        $elements = [List[object]]::new()
        if ($null -eq $value) { }
        elseif ($value -is [IDictionary]) {
            foreach ($key in [TplFn]::SortedKeys($value)) { $indexes.Add($key); $elements.Add($value[$key]) }
        }
        elseif ($value -is [string]) { throw "range can't iterate over $value" }
        elseif ($value -is [IEnumerable]) {
            $i = 0
            foreach ($element in $value) { $indexes.Add([int]$i); $elements.Add($element); $i++ }
        }
        elseif ([TplFn]::IsInt($value)) {
            for ($i = 0; $i -lt [long]$value; $i++) { $indexes.Add([int]$i); $elements.Add([int]$i) }
        }
        else { throw "range can't iterate over $([TplFn]::Format($value, $false))" }

        $result = 0
        for ($i = 0; $i -lt $elements.Count; $i++) {
            if ($decl.Count -eq 1) { $this.SetVar($decl[0], $elements[$i]) }
            elseif ($decl.Count -eq 2) { $this.SetVar($decl[0], $indexes[$i]); $this.SetVar($decl[1], $elements[$i]) }
            $innerMark = $this.Vars.Count
            $r = $this.Walk($elements[$i], $node.List)
            $this.PopVars($innerMark)
            if ($r -eq 1) { break }
        }
        if ($elements.Count -eq 0 -and $null -ne $node.ElseList) { $result = $this.Walk($dot, $node.ElseList) }
        $this.PopVars($mark)
        return $result
    }

    [object] EvalPipeline([object] $dot, [TplNode] $pipe) {
        $value = $null
        $hasFinal = $false
        foreach ($command in $pipe.Items) {
            $value = $this.EvalCommand($dot, $command, $value, $hasFinal)
            $hasFinal = $true
        }
        foreach ($name in $pipe.Decl) {
            if ($pipe.IsAssign) { $this.SetVar($name, $value) } else { $this.PushVar($name, $value) }
        }
        return $value
    }

    hidden [object] EvalCommand([object] $dot, [TplNode] $command, [object] $final, [bool] $hasFinal) {
        $first = $command.Items[0]
        $hasArgs = $command.Items.Count -gt 1 -or $hasFinal
        switch ($first.Kind) {
            'field' { return $this.EvalFieldChain($dot, $dot, $first.Fields, $command, $final, $hasFinal) }
            'chain' {
                $receiver = $this.EvalArg($dot, $first.Items[0])
                return $this.EvalFieldChain($dot, $receiver, $first.Fields, $command, $final, $hasFinal)
            }
            'ident' { return $this.EvalFunction($dot, [string]$first.Value, $command, $final, $hasFinal) }
            'var' {
                $value = $this.GetVar([string]$first.Value)
                if ($first.Fields.Count -eq 0) {
                    if ($hasArgs) { throw "can't give argument to non-function $($first.Value)" }
                    return $value
                }
                return $this.EvalFieldChain($dot, $value, $first.Fields, $command, $final, $hasFinal)
            }
            'subpipe' {
                if ($hasArgs) { throw "can't give argument to non-function (pipeline)" }
                return $this.EvalPipeline($dot, $first.Pipe)
            }
            'nil' { throw 'nil is not a command' }
        }
        if ($hasArgs) {
            $repr = if ($first.Kind -eq 'string') { [TplFn]::GoQuote([string]$first.Value) } elseif ($first.Kind -eq 'dot') { '.' } else { [TplFn]::Format($first.Value, $false) }
            throw "can't give argument to non-function $repr"
        }
        if ($first.Kind -eq 'dot') { return $dot }
        return $first.Value
    }

    hidden [object] EvalArg([object] $dot, [TplNode] $node) {
        switch ($node.Kind) {
            'dot' { return $dot }
            'nil' { return $null }
            'field' { return $this.EvalFieldChain($dot, $dot, $node.Fields, $null, $null, $false) }
            'var' {
                $value = $this.GetVar([string]$node.Value)
                if ($node.Fields.Count -eq 0) { return $value }
                return $this.EvalFieldChain($dot, $value, $node.Fields, $null, $null, $false)
            }
            'subpipe' { return $this.EvalPipeline($dot, $node.Pipe) }
            'ident' { return $this.EvalFunction($dot, [string]$node.Value, $null, $null, $false) }
            'chain' {
                $receiver = $this.EvalArg($dot, $node.Items[0])
                return $this.EvalFieldChain($dot, $receiver, $node.Fields, $null, $null, $false)
            }
        }
        return $node.Value
    }

    hidden [object] EvalFieldChain([object] $dot, [object] $receiver, [string[]] $fields, [TplNode] $command, [object] $final, [bool] $hasFinal) {
        $count = $fields.Count
        for ($i = 0; $i -lt $count - 1; $i++) {
            $receiver = $this.EvalField($dot, $receiver, $fields[$i], $null, $null, $false)
        }
        return $this.EvalField($dot, $receiver, $fields[$count - 1], $command, $final, $hasFinal)
    }

    hidden [object] EvalField([object] $dot, [object] $receiver, [string] $name, [TplNode] $command, [object] $final, [bool] $hasFinal) {
        $hasArgs = ($null -ne $command -and $command.Items.Count -gt 1) -or $hasFinal
        $r = [TplFn]::Unwrap($receiver)
        if ($null -eq $r) { return $null }
        if ($r -is [IDictionary]) {
            if ($hasArgs) { throw "$name is not a method but has arguments" }
            if ($r.Contains($name)) { return $r[$name] }
            return $null
        }
        if ($r -is [datetime] -or $r -is [DateTimeOffset]) {
            $arguments = [List[object]]::new()
            if ($null -ne $command) {
                for ($k = 1; $k -lt $command.Items.Count; $k++) { $arguments.Add($this.EvalArg($dot, $command.Items[$k])) }
            }
            if ($hasFinal) { $arguments.Add($final) }
            return [TplFn]::TimeMethod($r, $name, $arguments.ToArray())
        }
        if ($r -is [string] -or $r -is [ValueType] -or $r -is [IEnumerable]) {
            throw "can't evaluate field $name in type $([TplFn]::TypeOf($r))"
        }
        $property = $r.psobject.Properties[$name]
        if ($null -eq $property) { throw "can't evaluate field $name in type $([TplFn]::TypeOf($r))" }
        if ($hasArgs) { throw "$name is not a method but has arguments" }
        return $property.Value
    }

    hidden [object] EvalFunction([object] $dot, [string] $name, [TplNode] $command, [object] $final, [bool] $hasFinal) {
        $argCount = if ($null -ne $command) { $command.Items.Count - 1 } else { 0 }
        if ($name -ceq 'and' -or $name -ceq 'or') {
            $total = $argCount + [int]$hasFinal
            if ($total -eq 0) { throw "wrong number of args for ${name}: want at least 1 got 0" }
            $value = $null
            for ($k = 0; $k -lt $total; $k++) {
                if ($k -lt $argCount) { $value = $this.EvalArg($dot, $command.Items[$k + 1]) } else { $value = $final }
                $truth = [TplFn]::Truth($value)
                if (($name -ceq 'and' -and -not $truth) -or ($name -ceq 'or' -and $truth)) { return $value }
            }
            return $value
        }
        $arguments = [List[object]]::new()
        for ($k = 0; $k -lt $argCount; $k++) { $arguments.Add($this.EvalArg($dot, $command.Items[$k + 1])) }
        if ($hasFinal) { $arguments.Add($final) }
        return [TplFn]::Call($name, $arguments.ToArray())
    }
}

[NoRunspaceAffinity()]
class TplFn {
    # ---- value helpers -------------------------------------------------------------------

    static [object] Unwrap([object] $v) {
        if ($v -is [psobject] -and $v -isnot [System.Management.Automation.PSCustomObject]) { return $v.psobject.BaseObject }
        return $v
    }

    static [bool] IsInt([object] $v) {
        return $v -is [int] -or $v -is [long] -or $v -is [short] -or $v -is [byte] -or $v -is [sbyte] -or
            $v -is [uint16] -or $v -is [uint32] -or $v -is [uint64] -or $v -is [bigint]
    }

    static [object[]] Rest([object[]] $a, [int] $skip) {
        $count = [Math]::Max($a.Count - $skip, 0)
        $result = [object[]]::new($count)
        if ($count -gt 0) { [Array]::Copy($a, $skip, $result, 0, $count) }
        return $result
    }

    # Go "int" is modelled as [int] and "int64" as [long] so that typeOf/kindOf match.
    static [object] GoInt([long] $value) {
        if ($value -ge [int]::MinValue -and $value -le [int]::MaxValue) { return [int]$value }
        return $value
    }

    static [bool] IsFloat([object] $v) { return $v -is [double] -or $v -is [single] -or $v -is [decimal] }

    static [bool] IsNumber([object] $v) { return [TplFn]::IsInt($v) -or [TplFn]::IsFloat($v) }

    static [bool] IsList([object] $v) {
        return $null -ne $v -and $v -isnot [string] -and $v -isnot [IDictionary] -and $v -is [IEnumerable]
    }

    static [int] Count([object] $v) {
        if ($v -is [array]) { return $v.Length }
        if ($v -is [ICollection]) { return ([ICollection]$v).get_Count() }
        $n = 0
        foreach ($item in $v) { $n++ }
        return $n
    }

    static [string[]] SortedKeys([object] $dict) {
        $keys = [List[string]]::new()
        foreach ($key in ([IDictionary]$dict).get_Keys()) { $keys.Add([string]$key) }
        $array = $keys.ToArray()
        [Array]::Sort($array, [StringComparer]::Ordinal)
        return $array
    }

    static [bool] Truth([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($null -eq $v) { return $false }
        if ($v -is [bool]) { return [bool]$v }
        if ($v -is [string]) { return $v.Length -gt 0 }
        if ([TplFn]::IsNumber($v)) { return $v -ne 0 }
        if ($v -is [IDictionary] -or $v -is [ICollection]) { return [TplFn]::Count($v) -gt 0 }
        return $true
    }

    static [List[object]] ToList([object] $value) {
        $list = [List[object]]::new()
        $v = [TplFn]::Unwrap($value)
        if ($null -eq $v) { return $list }
        if (-not [TplFn]::IsList($v)) { throw "cannot use $([TplFn]::TypeOf($v)) as a list" }
        foreach ($item in $v) { $list.Add($item) }
        return $list
    }

    static [IDictionary] ToDict([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($v -is [IDictionary]) { return $v }
        throw "cannot use $([TplFn]::TypeOf($v)) as a map"
    }

    static [OrderedDictionary] NewDict() { return [OrderedDictionary]::new() }

    static [long] ToInt64([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($null -eq $v) { return 0 }
        if ($v -is [bool]) { if ($v) { return 1 }; return 0 }
        if ([TplFn]::IsInt($v)) { return [long]$v }
        if ([TplFn]::IsFloat($v)) { return [long][Math]::Truncate([double]$v) }
        if ($v -is [string]) {
            $parsed = 0L
            if ([long]::TryParse($v, [NumberStyles]::AllowLeadingSign, [CultureInfo]::InvariantCulture, [ref] $parsed)) { return $parsed }
        }
        return 0
    }

    static [double] ToFloat64([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($null -eq $v) { return 0 }
        if ($v -is [bool]) { if ($v) { return 1 }; return 0 }
        if ([TplFn]::IsNumber($v)) { return [double]$v }
        if ($v -is [string]) {
            $parsed = 0.0
            if ([double]::TryParse($v.Trim(), [NumberStyles]::Float, [CultureInfo]::InvariantCulture, [ref] $parsed)) { return $parsed }
        }
        return 0
    }

    static [string] Str([object] $value) {
        if ($null -eq $value) { return '' }
        return [TplFn]::Format($value, $false)
    }

    static [string] FormatFloat([double] $d) { return [TplFn]::FormatFloat($d, $false) }

    static [string] FormatFloat([double] $d, [bool] $json) {
        if ([double]::IsNaN($d)) { return 'NaN' }
        if ([double]::IsPositiveInfinity($d)) { return '+Inf' }
        if ([double]::IsNegativeInfinity($d)) { return '-Inf' }
        if ($d -eq 0) { return '0' }
        $sign = if ($d -lt 0) { '-' } else { '' }
        $r = [Math]::Abs($d).ToString('R', [CultureInfo]::InvariantCulture)
        $exponent = 0
        $ePos = $r.IndexOf('E')
        if ($ePos -ge 0) {
            $exponent = [int]::Parse($r.Substring($ePos + 1), [NumberStyles]::AllowLeadingSign, [CultureInfo]::InvariantCulture)
            $r = $r.Substring(0, $ePos)
        }
        $dotPos = $r.IndexOf('.')
        $intPart = if ($dotPos -ge 0) { $r.Substring(0, $dotPos) } else { $r }
        $fracPart = if ($dotPos -ge 0) { $r.Substring($dotPos + 1) } else { '' }
        $digits = $intPart + $fracPart
        $dp = $intPart.Length + $exponent
        $leading = 0
        while ($leading -lt $digits.Length - 1 -and $digits[$leading] -eq '0') { $leading++ }
        $digits = $digits.Substring($leading).TrimEnd('0')
        $dp -= $leading
        if ($digits.Length -eq 0) { return '0' }
        $nd = $digits.Length
        $exp = $dp - 1
        $useExponent = if ($json) { $exp -lt -6 -or $exp -ge 21 } else { $exp -lt -4 -or $exp -ge 6 }
        if ($useExponent) {
            $mantissa = $digits.Substring(0, 1)
            if ($nd -gt 1) { $mantissa += '.' + $digits.Substring(1) }
            $expSign = if ($exp -lt 0) { '-' } else { '+' }
            return $sign + $mantissa + 'e' + $expSign + [Math]::Abs($exp).ToString('00', [CultureInfo]::InvariantCulture)
        }
        if ($dp -le 0) { return $sign + '0.' + ('0' * (- $dp)) + $digits }
        if ($dp -ge $nd) { return $sign + $digits + ('0' * ($dp - $nd)) }
        return $sign + $digits.Substring(0, $dp) + '.' + $digits.Substring($dp)
    }

    # Formats a value like Go's %v. $top selects the "<no value>" form for nil.
    static [string] Format([object] $value, [bool] $top) {
        $v = [TplFn]::Unwrap($value)
        if ($null -eq $v) { if ($top) { return '<no value>' }; return '<nil>' }
        if ($v -is [string]) { return $v }
        if ($v -is [bool]) { if ($v) { return 'true' }; return 'false' }
        if ($v -is [char]) { return [string]$v }
        if ([TplFn]::IsInt($v)) { return ([IFormattable]$v).ToString($null, [CultureInfo]::InvariantCulture) }
        if ([TplFn]::IsFloat($v)) { return [TplFn]::FormatFloat([double]$v) }
        if ($v -is [datetime] -or $v -is [DateTimeOffset]) {
            return [TplFn]::GoTimeFormat([TplFn]::ToTime($v), '2006-01-02 15:04:05.999999999 -0700 MST')
        }
        if ($v -is [timespan]) { return [TplFn]::DurationString($v) }
        if ($v -is [IDictionary]) {
            $parts = [List[string]]::new()
            foreach ($key in [TplFn]::SortedKeys($v)) { $parts.Add($key + ':' + [TplFn]::Format($v[$key], $false)) }
            return 'map[' + [string]::Join(' ', $parts) + ']'
        }
        if ($v -is [IEnumerable]) {
            $parts = [List[string]]::new()
            foreach ($item in $v) { $parts.Add([TplFn]::Format($item, $false)) }
            return '[' + [string]::Join(' ', $parts) + ']'
        }
        return [string]$v
    }

    static [string] GoQuote([string] $s) {
        $sb = [StringBuilder]::new('"')
        foreach ($c in $s.ToCharArray()) {
            switch ([int]$c) {
                34 { [void]$sb.Append('\"') }
                92 { [void]$sb.Append('\\') }
                10 { [void]$sb.Append('\n') }
                13 { [void]$sb.Append('\r') }
                9 { [void]$sb.Append('\t') }
                7 { [void]$sb.Append('\a') }
                8 { [void]$sb.Append('\b') }
                12 { [void]$sb.Append('\f') }
                11 { [void]$sb.Append('\v') }
                default {
                    if ([int]$c -lt 32 -or [int]$c -eq 127) { [void]$sb.Append('\x' + ([int]$c).ToString('x2')) }
                    else { [void]$sb.Append($c) }
                }
            }
        }
        return $sb.Append('"').ToString()
    }

    static [string] TypeOf([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($null -eq $v) { return '<nil>' }
        if ($v -is [string]) { return 'string' }
        if ($v -is [bool]) { return 'bool' }
        if ($v -is [long] -or $v -is [uint64]) { return 'int64' }
        if ([TplFn]::IsInt($v)) { return 'int' }
        if ([TplFn]::IsFloat($v)) { return 'float64' }
        if ($v -is [IDictionary]) { return 'map[string]interface {}' }
        if ($v -is [datetime] -or $v -is [DateTimeOffset]) { return 'time.Time' }
        if ($v -is [timespan]) { return 'time.Duration' }
        if ($v -is [IEnumerable]) { return '[]interface {}' }
        return $v.GetType().Name
    }

    static [string] KindOf([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($null -eq $v) { return 'invalid' }
        if ($v -is [string]) { return 'string' }
        if ($v -is [bool]) { return 'bool' }
        if ($v -is [long] -or $v -is [uint64]) { return 'int64' }
        if ([TplFn]::IsInt($v)) { return 'int' }
        if ([TplFn]::IsFloat($v)) { return 'float64' }
        if ($v -is [IDictionary]) { return 'map' }
        if ($v -is [timespan]) { return 'int64' }
        if ($v -is [datetime] -or $v -is [DateTimeOffset]) { return 'struct' }
        if ($v -is [IEnumerable]) { return 'slice' }
        return 'struct'
    }

    static [bool] DeepEqual([object] $left, [object] $right) {
        $a = [TplFn]::Unwrap($left)
        $b = [TplFn]::Unwrap($right)
        if ($null -eq $a -or $null -eq $b) { return ($null -eq $a) -and ($null -eq $b) }
        if ($a -is [IDictionary]) {
            if ($b -isnot [IDictionary] -or [TplFn]::Count($a) -ne [TplFn]::Count($b)) { return $false }
            foreach ($key in $a.get_Keys()) {
                if (-not $b.Contains($key) -or -not [TplFn]::DeepEqual($a[$key], $b[$key])) { return $false }
            }
            return $true
        }
        if ([TplFn]::IsList($a)) {
            if (-not [TplFn]::IsList($b)) { return $false }
            $x = [TplFn]::ToList($a)
            $y = [TplFn]::ToList($b)
            if ($x.Count -ne $y.Count) { return $false }
            for ($i = 0; $i -lt $x.Count; $i++) { if (-not [TplFn]::DeepEqual($x[$i], $y[$i])) { return $false } }
            return $true
        }
        if ([TplFn]::IsNumber($a) -and [TplFn]::IsNumber($b)) {
            if ([TplFn]::IsInt($a) -and [TplFn]::IsInt($b)) { return [decimal]$a -eq [decimal]$b }
            if ([TplFn]::IsFloat($a) -and [TplFn]::IsFloat($b)) { return [double]$a -eq [double]$b }
            return $false
        }
        if ($a -is [string] -and $b -is [string]) { return [string]::Equals($a, $b, [StringComparison]::Ordinal) }
        if ($a.GetType() -ne $b.GetType()) { return $false }
        return $a.Equals($b)
    }

    static [bool] Equal([object] $left, [object] $right) {
        $a = [TplFn]::Unwrap($left)
        $b = [TplFn]::Unwrap($right)
        if ($null -eq $a -or $null -eq $b) { return ($null -eq $a) -and ($null -eq $b) }
        $comparable = ([TplFn]::IsNumber($a) -and [TplFn]::IsNumber($b)) -or
            ($a -is [string] -and $b -is [string]) -or ($a -is [bool] -and $b -is [bool]) -or
            ($a -is [IDictionary] -and $b -is [IDictionary]) -or ([TplFn]::IsList($a) -and [TplFn]::IsList($b)) -or
            ($a.GetType() -eq $b.GetType())
        if (-not $comparable) { throw 'incompatible types for comparison' }
        if ([TplFn]::IsNumber($a) -and [TplFn]::IsNumber($b)) { return [TplFn]::Compare($a, $b) -eq 0 }
        return [TplFn]::DeepEqual($a, $b)
    }

    static [int] Compare([object] $left, [object] $right) {
        $a = [TplFn]::Unwrap($left)
        $b = [TplFn]::Unwrap($right)
        if ([TplFn]::IsNumber($a) -and [TplFn]::IsNumber($b)) {
            if ([TplFn]::IsInt($a) -and [TplFn]::IsInt($b)) { return ([decimal]$a).CompareTo([decimal]$b) }
            return ([double]$a).CompareTo([double]$b)
        }
        if ($a -is [string] -and $b -is [string]) { return [Math]::Sign([string]::CompareOrdinal($a, $b)) }
        throw 'incompatible types for comparison'
    }

    # ---- printf ---------------------------------------------------------------------------

    hidden static [string] BadVerb([char] $verb, [object] $arg) {
        if ($null -eq $arg) { return "%!$verb(<nil>)" }
        return "%!$verb($([TplFn]::TypeOf($arg))=$([TplFn]::Format($arg, $false)))"
    }

    hidden static [string] FormatVerb([char] $verb, [object] $value, [bool] $plus, [bool] $sharp, [bool] $space, [int] $precision) {
        $arg = [TplFn]::Unwrap($value)
        $inv = [CultureInfo]::InvariantCulture
        $v = [string]$verb
        if ($v -ceq 'v') {
            if ($sharp -and $arg -is [string]) { return [TplFn]::GoQuote($arg) }
            return [TplFn]::Format($arg, $false)
        }
        if ($v -ceq 'T') { return [TplFn]::TypeOf($arg) }
        if ($v -ceq 's') {
            if ($null -eq $arg -or $arg -is [bool] -or [TplFn]::IsNumber($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            $s = [TplFn]::Format($arg, $false)
            if ($precision -ge 0 -and $precision -lt $s.Length) { $s = $s.Substring(0, $precision) }
            return $s
        }
        if ($v -ceq 'q') {
            if ($arg -is [string]) { return [TplFn]::GoQuote($arg) }
            if ([TplFn]::IsInt($arg)) { return "'" + [char]::ConvertFromUtf32([int]$arg) + "'" }
            return [TplFn]::BadVerb($verb, $arg)
        }
        if ($v -ceq 't') {
            if ($arg -is [bool]) { return [TplFn]::Format($arg, $false) }
            return [TplFn]::BadVerb($verb, $arg)
        }
        $signPrefix = ''
        if ([TplFn]::IsNumber($arg) -and $arg -ge 0) { if ($plus) { $signPrefix = '+' } elseif ($space) { $signPrefix = ' ' } }
        if ($v -ceq 'd') {
            if (-not [TplFn]::IsInt($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            return $signPrefix + ([IFormattable]$arg).ToString($null, $inv)
        }
        if ($v -ceq 'f' -or $v -ceq 'F') {
            if (-not [TplFn]::IsNumber($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            $p = if ($precision -lt 0) { 6 } else { $precision }
            return $signPrefix + ([double]$arg).ToString("F$p", $inv)
        }
        if ($v -ceq 'e' -or $v -ceq 'E') {
            if (-not [TplFn]::IsNumber($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            $p = if ($precision -lt 0) { 6 } else { $precision }
            $pattern = '0' + $(if ($p -gt 0) { '.' + ('0' * $p) } else { '' }) + $v + '+00'
            return $signPrefix + ([double]$arg).ToString($pattern, $inv)
        }
        if ($v -ceq 'g' -or $v -ceq 'G') {
            if (-not [TplFn]::IsNumber($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            if ($precision -lt 0) { return $signPrefix + [TplFn]::FormatFloat([double]$arg) }
            return $signPrefix + ([double]$arg).ToString("G$precision", $inv)
        }
        if ($v -ceq 'x' -or $v -ceq 'X') {
            $hex = ''
            if ([TplFn]::IsInt($arg)) { $hex = ([long]$arg).ToString('x', $inv) }
            elseif ($arg -is [string]) { $hex = [Convert]::ToHexString([Encoding]::UTF8.GetBytes($arg)).ToLowerInvariant() }
            else { return [TplFn]::BadVerb($verb, $arg) }
            if ($v -ceq 'X') { $hex = $hex.ToUpperInvariant() }
            if ($sharp) { $hex = '0' + $v + $hex }
            return $hex
        }
        if ($v -ceq 'o') {
            if (-not [TplFn]::IsInt($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            return [Convert]::ToString([long]$arg, 8)
        }
        if ($v -ceq 'b') {
            if (-not [TplFn]::IsInt($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            return [Convert]::ToString([long]$arg, 2)
        }
        if ($v -ceq 'c') {
            if (-not [TplFn]::IsInt($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            return [char]::ConvertFromUtf32([int]$arg)
        }
        if ($v -ceq 'U') {
            if (-not [TplFn]::IsInt($arg)) { return [TplFn]::BadVerb($verb, $arg) }
            return 'U+' + ([long]$arg).ToString('X4', $inv)
        }
        return [TplFn]::BadVerb($verb, $arg)
    }

    static [string] Sprintf([string] $format, [object[]] $a) {
        $sb = [StringBuilder]::new()
        $n = $format.Length
        $i = 0
        $ai = 0
        while ($i -lt $n) {
            $c = $format[$i]
            if ($c -ne '%') { [void]$sb.Append($c); $i++; continue }
            $i++
            $minus = $false; $plus = $false; $zero = $false; $space = $false; $sharp = $false
            while ($i -lt $n -and '+-# 0'.IndexOf($format[$i]) -ge 0) {
                switch ($format[$i]) { '+' { $plus = $true } '-' { $minus = $true } '#' { $sharp = $true } ' ' { $space = $true } '0' { $zero = $true } }
                $i++
            }
            $width = -1
            if ($i -lt $n -and $format[$i] -eq '*') {
                if ($ai -lt $a.Count) { $width = [int][TplFn]::ToInt64($a[$ai]); $ai++ }
                $i++
            }
            else {
                $start = $i
                while ($i -lt $n -and [char]::IsDigit($format[$i])) { $i++ }
                if ($i -gt $start) { $width = [int]$format.Substring($start, $i - $start) }
            }
            $precision = -1
            if ($i -lt $n -and $format[$i] -eq '.') {
                $i++
                $precision = 0
                if ($i -lt $n -and $format[$i] -eq '*') {
                    if ($ai -lt $a.Count) { $precision = [int][TplFn]::ToInt64($a[$ai]); $ai++ }
                    $i++
                }
                else {
                    $start = $i
                    while ($i -lt $n -and [char]::IsDigit($format[$i])) { $i++ }
                    if ($i -gt $start) { $precision = [int]$format.Substring($start, $i - $start) }
                }
            }
            if ($i -ge $n) { [void]$sb.Append('%!(NOVERB)'); break }
            $verb = $format[$i]
            $i++
            if ($verb -eq '%') { [void]$sb.Append('%'); continue }
            if ($ai -ge $a.Count) { [void]$sb.Append("%!$verb(MISSING)"); continue }
            $arg = $a[$ai]
            $ai++
            $text = [TplFn]::FormatVerb($verb, $arg, $plus, $sharp, $space, $precision)
            if ($width -gt $text.Length) {
                if ($minus) { $text = $text.PadRight($width) }
                elseif ($zero -and [TplFn]::IsNumber([TplFn]::Unwrap($arg))) {
                    $signLength = if ($text.Length -gt 0 -and '+- '.IndexOf($text[0]) -ge 0) { 1 } else { 0 }
                    $text = $text.Substring(0, $signLength) + ('0' * ($width - $text.Length)) + $text.Substring($signLength)
                }
                else { $text = $text.PadLeft($width) }
            }
            [void]$sb.Append($text)
        }
        if ($ai -lt $a.Count) {
            $extra = [List[string]]::new()
            for ($k = $ai; $k -lt $a.Count; $k++) {
                if ($null -eq $a[$k]) { $extra.Add('<nil>') } else { $extra.Add([TplFn]::TypeOf($a[$k]) + '=' + [TplFn]::Format($a[$k], $false)) }
            }
            [void]$sb.Append('%!(EXTRA ' + [string]::Join(', ', $extra) + ')')
        }
        return $sb.ToString()
    }

    static [string] Sprint([object[]] $a, [bool] $newline) {
        $sb = [StringBuilder]::new()
        for ($i = 0; $i -lt $a.Count; $i++) {
            if ($i -gt 0) {
                $bothNonString = ([TplFn]::Unwrap($a[$i]) -isnot [string]) -and ([TplFn]::Unwrap($a[$i - 1]) -isnot [string])
                if ($newline -or $bothNonString) { [void]$sb.Append(' ') }
            }
            [void]$sb.Append([TplFn]::Format($a[$i], $false))
        }
        if ($newline) { [void]$sb.Append("`n") }
        return $sb.ToString()
    }

    # ---- JSON / YAML ----------------------------------------------------------------------

    hidden static [string] JsonString([string] $s, [bool] $escapeHtml) {
        $sb = [StringBuilder]::new('"')
        foreach ($c in $s.ToCharArray()) {
            $code = [int]$c
            if ($c -eq '"') { [void]$sb.Append('\"') }
            elseif ($c -eq '\') { [void]$sb.Append('\\') }
            elseif ($code -eq 10) { [void]$sb.Append('\n') }
            elseif ($code -eq 13) { [void]$sb.Append('\r') }
            elseif ($code -eq 9) { [void]$sb.Append('\t') }
            elseif ($code -lt 32 -or $code -eq 0x2028 -or $code -eq 0x2029) { [void]$sb.Append('\u' + $code.ToString('x4')) }
            elseif ($escapeHtml -and ($c -eq '<' -or $c -eq '>' -or $c -eq '&')) { [void]$sb.Append('\u' + $code.ToString('x4')) }
            else { [void]$sb.Append($c) }
        }
        return $sb.Append('"').ToString()
    }

    static [string] ToJson([object] $value, [bool] $escapeHtml, [string] $indent, [string] $current) {
        $v = [TplFn]::Unwrap($value)
        if ($null -eq $v) { return 'null' }
        if ($v -is [bool]) { if ($v) { return 'true' }; return 'false' }
        if ($v -is [string]) { return [TplFn]::JsonString($v, $escapeHtml) }
        if ([TplFn]::IsInt($v)) { return [TplFn]::Format($v, $false) }
        if ([TplFn]::IsFloat($v)) { return [TplFn]::FormatFloat([double]$v, $true) }
        $pretty = $indent.Length -gt 0
        $inner = $current + $indent
        if ($v -is [IDictionary]) {
            $parts = [List[string]]::new()
            foreach ($key in [TplFn]::SortedKeys($v)) {
                $separator = if ($pretty) { ': ' } else { ':' }
                $parts.Add([TplFn]::JsonString($key, $escapeHtml) + $separator + [TplFn]::ToJson($v[$key], $escapeHtml, $indent, $inner))
            }
            if ($parts.Count -eq 0) { return '{}' }
            if ($pretty) { return "{`n$inner" + [string]::Join(",`n$inner", $parts) + "`n$current}" }
            return '{' + [string]::Join(',', $parts) + '}'
        }
        if ($v -is [datetime] -or $v -is [DateTimeOffset]) {
            return [TplFn]::JsonString([TplFn]::ToTime($v).ToString('yyyy-MM-ddTHH:mm:ss.FFFFFFFK', [CultureInfo]::InvariantCulture), $escapeHtml)
        }
        if ($v -is [IEnumerable]) {
            $parts = [List[string]]::new()
            foreach ($item in $v) { $parts.Add([TplFn]::ToJson($item, $escapeHtml, $indent, $inner)) }
            if ($parts.Count -eq 0) { return '[]' }
            if ($pretty) { return "[`n$inner" + [string]::Join(",`n$inner", $parts) + "`n$current]" }
            return '[' + [string]::Join(',', $parts) + ']'
        }
        return [TplFn]::JsonString([string]$v, $escapeHtml)
    }

    hidden static [object] FromJsonElement([System.Text.Json.JsonElement] $element) {
        switch ($element.ValueKind) {
            ([System.Text.Json.JsonValueKind]::Object) {
                $dict = [OrderedDictionary]::new()
                foreach ($property in $element.EnumerateObject()) { $dict[[string]$property.Name] = [TplFn]::FromJsonElement($property.Value) }
                return $dict
            }
            ([System.Text.Json.JsonValueKind]::Array) {
                $list = [List[object]]::new()
                foreach ($item in $element.EnumerateArray()) { $list.Add([TplFn]::FromJsonElement($item)) }
                return $list
            }
            ([System.Text.Json.JsonValueKind]::String) { return $element.GetString() }
            ([System.Text.Json.JsonValueKind]::Number) {
                return $element.GetDouble()
            }
            ([System.Text.Json.JsonValueKind]::True) { return $true }
            ([System.Text.Json.JsonValueKind]::False) { return $false }
        }
        return $null
    }

    static [object] FromJson([string] $text) {
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try { return [TplFn]::FromJsonElement($document.RootElement) }
        finally { $document.Dispose() }
    }

    static [object] FromYaml([string] $text) { return [TaskYaml]::Parse($text) }

    static [string] ToYaml([object] $value) {
        $text = [string](ConvertTo-Yaml -Data $value)
        return $text.Replace("`r`n", "`n").TrimEnd("`n") + "`n"
    }

    # ---- paths ----------------------------------------------------------------------------

    static [string] PathClean([string] $p) {
        if ($p.Length -eq 0) { return '.' }
        $rooted = $p[0] -eq '/'
        $stack = [List[string]]::new()
        foreach ($part in $p.Split('/')) {
            if ($part.Length -eq 0 -or $part -eq '.') { continue }
            if ($part -eq '..') {
                if ($stack.Count -gt 0 -and $stack[$stack.Count - 1] -ne '..') { $stack.RemoveAt($stack.Count - 1) }
                elseif (-not $rooted) { $stack.Add('..') }
                continue
            }
            $stack.Add($part)
        }
        $joined = [string]::Join('/', $stack)
        if ($rooted) { return '/' + $joined }
        if ($joined.Length -eq 0) { return '.' }
        return $joined
    }

    static [string] PathBase([string] $p) {
        if ($p.Length -eq 0) { return '.' }
        $trimmed = $p.TrimEnd('/')
        if ($trimmed.Length -eq 0) { return '/' }
        $index = $trimmed.LastIndexOf('/')
        if ($index -ge 0) { return $trimmed.Substring($index + 1) }
        return $trimmed
    }

    static [string] PathDir([string] $p) {
        $index = $p.LastIndexOf('/')
        return [TplFn]::PathClean($p.Substring(0, $index + 1))
    }

    static [string] PathExt([string] $p) {
        for ($i = $p.Length - 1; $i -ge 0 -and $p[$i] -ne '/'; $i--) {
            if ($p[$i] -eq '.') { return $p.Substring($i) }
        }
        return ''
    }

    static [string] OsClean([string] $p) {
        $separator = [System.IO.Path]::DirectorySeparatorChar
        $normalized = $p.Replace([System.IO.Path]::AltDirectorySeparatorChar, $separator)
        $volume = ''
        if ($separator -eq '\' -and $normalized -match '^[A-Za-z]:') { $volume = $normalized.Substring(0, 2); $normalized = $normalized.Substring(2) }
        $cleaned = [TplFn]::PathClean($normalized.Replace($separator, '/')).Replace('/', $separator)
        if ($volume.Length -gt 0 -and $cleaned -eq '.') { return $volume + $(if ($normalized.Length -eq 0) { '.' } else { '' }) }
        return $volume + $cleaned
    }

    static [string] OsJoin([object[]] $parts) {
        $items = [List[string]]::new()
        foreach ($part in $parts) { $s = [TplFn]::Str($part); if ($s.Length -gt 0) { $items.Add($s) } }
        if ($items.Count -eq 0) { return '' }
        return [TplFn]::OsClean([string]::Join([System.IO.Path]::DirectorySeparatorChar, $items))
    }

    # ---- shell ----------------------------------------------------------------------------

    static [string] ShellQuote([string] $s) { return "'" + $s.Replace("'", "''") + "'" }

    static [List[object]] SplitArgs([string] $s) {
        $result = [List[object]]::new()
        $sb = [StringBuilder]::new()
        $inWord = $false
        $quote = [char]0
        for ($i = 0; $i -lt $s.Length; $i++) {
            $c = $s[$i]
            if ($quote -eq "'") {
                if ($c -eq "'") { $quote = [char]0 } else { [void]$sb.Append($c) }
                continue
            }
            if ($quote -eq '"') {
                if ($c -eq '"') { $quote = [char]0 }
                elseif ($c -eq '\' -and $i + 1 -lt $s.Length -and '"\$`'.IndexOf($s[$i + 1]) -ge 0) { $i++; [void]$sb.Append($s[$i]) }
                else { [void]$sb.Append($c) }
                continue
            }
            if ($c -eq "'" -or $c -eq '"') { $quote = $c; $inWord = $true; continue }
            if ($c -eq '\' -and $i + 1 -lt $s.Length) { $i++; [void]$sb.Append($s[$i]); $inWord = $true; continue }
            if ([char]::IsWhiteSpace($c)) {
                if ($inWord) { $result.Add($sb.ToString()); [void]$sb.Clear(); $inWord = $false }
                continue
            }
            [void]$sb.Append($c)
            $inWord = $true
        }
        if ($quote -ne [char]0) { throw 'splitArgs: unterminated quote' }
        if ($inWord) { $result.Add($sb.ToString()) }
        return $result
    }

    # ---- time -----------------------------------------------------------------------------

    static [DateTimeOffset] ToTime([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($v -is [DateTimeOffset]) { return $v }
        if ($v -is [datetime]) { return [DateTimeOffset]::new($v) }
        if ([TplFn]::IsInt($v)) { return [DateTimeOffset]::FromUnixTimeSeconds([long]$v).ToLocalTime() }
        return [DateTimeOffset]::Now
    }

    hidden static [string] ZoneOffset([timespan] $offset, [bool] $colon, [bool] $minutes, [bool] $z) {
        if ($z -and $offset -eq [timespan]::Zero) { return 'Z' }
        $sign = if ($offset -lt [timespan]::Zero) { '-' } else { '+' }
        $absolute = $offset.Duration()
        $text = $sign + $absolute.Hours.ToString('00')
        if ($minutes) { $text += $(if ($colon) { ':' } else { '' }) + $absolute.Minutes.ToString('00') }
        return $text
    }

    static [string] GoTimeFormat([DateTimeOffset] $t, [string] $layout) {
        $inv = [CultureInfo]::InvariantCulture
        $sb = [StringBuilder]::new()
        $i = 0
        $n = $layout.Length
        $tokens = @('January', 'Monday', '2006', 'Z07:00', '-07:00', 'Z0700', '-0700', 'Jan', 'Mon', 'MST', 'Z07', '-07', '002',
            '01', '02', '03', '04', '05', '06', '15', 'PM', 'pm', '_2', '1', '2', '3', '4', '5')
        while ($i -lt $n) {
            $c = $layout[$i]
            if (($c -eq '.' -or $c -eq ',') -and $i + 1 -lt $n -and ($layout[$i + 1] -eq '0' -or $layout[$i + 1] -eq '9')) {
                $digit = $layout[$i + 1]
                $j = $i + 1
                while ($j -lt $n -and $layout[$j] -eq $digit) { $j++ }
                if ($j -ge $n -or -not [char]::IsDigit($layout[$j])) {
                    $count = $j - $i - 1
                    $fraction = ($t.Ticks % [timespan]::TicksPerSecond).ToString('0000000', $inv).PadRight(9, '0').Substring(0, [Math]::Min($count, 9))
                    if ($digit -eq '9') { $fraction = $fraction.TrimEnd('0') }
                    if ($fraction.Length -gt 0) { [void]$sb.Append($c).Append($fraction) }
                    $i = $j
                    continue
                }
            }
            $matched = $null
            foreach ($token in $tokens) {
                if ([string]::CompareOrdinal($layout, $i, $token, 0, $token.Length) -eq 0) { $matched = $token; break }
            }
            if ($null -eq $matched) { [void]$sb.Append($c); $i++; continue }
            $i += $matched.Length
            $hour12 = $t.Hour % 12
            if ($hour12 -eq 0) { $hour12 = 12 }
            switch -CaseSensitive ($matched) {
                'January' { [void]$sb.Append($t.ToString('MMMM', $inv)) }
                'Jan' { [void]$sb.Append($t.ToString('MMM', $inv)) }
                'Monday' { [void]$sb.Append($t.ToString('dddd', $inv)) }
                'Mon' { [void]$sb.Append($t.ToString('ddd', $inv)) }
                '2006' { [void]$sb.Append($t.Year.ToString('0000', $inv)) }
                '06' { [void]$sb.Append(($t.Year % 100).ToString('00', $inv)) }
                '01' { [void]$sb.Append($t.Month.ToString('00', $inv)) }
                '1' { [void]$sb.Append($t.Month.ToString($inv)) }
                '02' { [void]$sb.Append($t.Day.ToString('00', $inv)) }
                '_2' { [void]$sb.Append($t.Day.ToString($inv).PadLeft(2)) }
                '2' { [void]$sb.Append($t.Day.ToString($inv)) }
                '002' { [void]$sb.Append($t.DayOfYear.ToString('000', $inv)) }
                '15' { [void]$sb.Append($t.Hour.ToString('00', $inv)) }
                '03' { [void]$sb.Append($hour12.ToString('00', $inv)) }
                '3' { [void]$sb.Append($hour12.ToString($inv)) }
                '04' { [void]$sb.Append($t.Minute.ToString('00', $inv)) }
                '4' { [void]$sb.Append($t.Minute.ToString($inv)) }
                '05' { [void]$sb.Append($t.Second.ToString('00', $inv)) }
                '5' { [void]$sb.Append($t.Second.ToString($inv)) }
                'PM' { [void]$sb.Append($(if ($t.Hour -ge 12) { 'PM' } else { 'AM' })) }
                'pm' { [void]$sb.Append($(if ($t.Hour -ge 12) { 'pm' } else { 'am' })) }
                'MST' { [void]$sb.Append($(if ($t.Offset -eq [timespan]::Zero) { 'UTC' } else { [TplFn]::ZoneOffset($t.Offset, $false, $t.Offset.Minutes -ne 0, $false) })) }
                'Z07:00' { [void]$sb.Append([TplFn]::ZoneOffset($t.Offset, $true, $true, $true)) }
                '-07:00' { [void]$sb.Append([TplFn]::ZoneOffset($t.Offset, $true, $true, $false)) }
                'Z0700' { [void]$sb.Append([TplFn]::ZoneOffset($t.Offset, $false, $true, $true)) }
                '-0700' { [void]$sb.Append([TplFn]::ZoneOffset($t.Offset, $false, $true, $false)) }
                'Z07' { [void]$sb.Append([TplFn]::ZoneOffset($t.Offset, $false, $false, $true)) }
                '-07' { [void]$sb.Append([TplFn]::ZoneOffset($t.Offset, $false, $false, $false)) }
            }
        }
        return $sb.ToString()
    }

    static [DateTimeOffset] ParseGoTime([string] $layout, [string] $value) {
        $goTokens = @('January', 'Monday', '2006', 'Z07:00', '-07:00', '-0700', 'Jan', 'Mon', '-07', '01', '02', '03', '04', '05', '06', '15', 'PM', 'pm', '_2', '1', '2', '3', '4', '5')
        $netTokens = @('MMMM', 'dddd', 'yyyy', 'K', 'zzz', 'zzz', 'MMM', 'ddd', 'zz', 'MM', 'dd', 'hh', 'mm', 'ss', 'yy', 'HH', 'tt', 'tt', 'd', 'M', 'd', 'h', 'm', 's')
        $sb = [StringBuilder]::new()
        $i = 0
        $n = $layout.Length
        while ($i -lt $n) {
            $c = $layout[$i]
            if ($c -eq '.' -and $i + 1 -lt $n -and ($layout[$i + 1] -eq '0' -or $layout[$i + 1] -eq '9')) {
                $digit = $layout[$i + 1]
                $j = $i + 1
                while ($j -lt $n -and $layout[$j] -eq $digit) { $j++ }
                $count = [Math]::Min($j - $i - 1, 7)
                [void]$sb.Append('.').Append($(if ($digit -eq '0') { 'f' * $count } else { 'F' * $count }))
                $i = $j
                continue
            }
            $matched = -1
            for ($k = 0; $k -lt $goTokens.Count; $k++) {
                if ([string]::CompareOrdinal($layout, $i, $goTokens[$k], 0, $goTokens[$k].Length) -eq 0) { $matched = $k; break }
            }
            if ($matched -ge 0) { [void]$sb.Append($netTokens[$matched]); $i += $goTokens[$matched].Length; continue }
            if ($c -eq "'") { [void]$sb.Append("\'") } elseif ([char]::IsLetter($c) -or $c -eq '\' -or $c -eq '%') { [void]$sb.Append('\').Append($c) } else { [void]$sb.Append($c) }
            $i++
        }
        $candidate = $value
        if ($layout.Contains('-0700') -and $candidate -match '([+-]\d{2})(\d{2})$') { $candidate = $candidate.Substring(0, $candidate.Length - 2) + ':' + $Matches[2] }
        return [DateTimeOffset]::ParseExact($candidate, $sb.ToString(), [CultureInfo]::InvariantCulture, [DateTimeStyles]::AssumeLocal)
    }

    static [string] DurationString([timespan] $duration) {
        if ($duration -eq [timespan]::Zero) { return '0s' }
        $inv = [CultureInfo]::InvariantCulture
        $sign = if ($duration -lt [timespan]::Zero) { '-' } else { '' }
        $ticks = [Math]::Abs($duration.Ticks)
        if ($ticks -lt [timespan]::TicksPerSecond) {
            if ($ticks -lt 10) { return $sign + ($ticks * 100).ToString($inv) + 'ns' }
            if ($ticks -lt [timespan]::TicksPerMillisecond) { return $sign + ([decimal]$ticks / 10).ToString('0.#######', $inv) + 'µs' }
            return $sign + ([decimal]$ticks / [timespan]::TicksPerMillisecond).ToString('0.#######', $inv) + 'ms'
        }
        $hours = [Math]::Floor($ticks / [timespan]::TicksPerHour)
        $rest = $ticks - $hours * [timespan]::TicksPerHour
        $minutes = [Math]::Floor($rest / [timespan]::TicksPerMinute)
        $rest -= $minutes * [timespan]::TicksPerMinute
        $seconds = ([decimal]$rest / [timespan]::TicksPerSecond).ToString('0.#######', $inv)
        if ($hours -gt 0) { return "$sign$($hours)h$($minutes)m$($seconds)s" }
        if ($minutes -gt 0) { return "$sign$($minutes)m$($seconds)s" }
        return "$sign$($seconds)s"
    }

    static [timespan] ParseDuration([string] $text) {
        $s = $text.Trim()
        $negative = $false
        if ($s.StartsWith('-')) { $negative = $true; $s = $s.Substring(1) } elseif ($s.StartsWith('+')) { $s = $s.Substring(1) }
        if ($s -eq '0') { return [timespan]::Zero }
        $found = [regex]::Matches($s, '(\d+(?:\.\d*)?|\.\d+)(ns|us|µs|μs|ms|s|m|h)')
        $consumed = 0
        $ticks = [decimal]0
        foreach ($match in $found) {
            $consumed += $match.Length
            $number = [decimal]::Parse($match.Groups[1].Value, [CultureInfo]::InvariantCulture)
            switch -CaseSensitive ($match.Groups[2].Value) {
                'h' { $ticks += $number * [timespan]::TicksPerHour }
                'm' { $ticks += $number * [timespan]::TicksPerMinute }
                's' { $ticks += $number * [timespan]::TicksPerSecond }
                'ms' { $ticks += $number * [timespan]::TicksPerMillisecond }
                'ns' { $ticks += $number / 100 }
                default { $ticks += $number * 10 }
            }
        }
        if ($found.Count -eq 0 -or $consumed -ne $s.Length) { throw "time: invalid duration `"$text`"" }
        if ($negative) { $ticks = - $ticks }
        return [timespan]::FromTicks([long]$ticks)
    }

    static [string] DurationRound([timespan] $duration) {
        $seconds = [Math]::Abs($duration.TotalSeconds)
        if ($seconds -ge 31536000) { return "$([Math]::Floor($seconds / 31536000))y" }
        if ($seconds -ge 2592000) { return "$([Math]::Floor($seconds / 2592000))mo" }
        if ($seconds -ge 86400) { return "$([Math]::Floor($seconds / 86400))d" }
        if ($seconds -ge 3600) { return "$([Math]::Floor($seconds / 3600))h" }
        if ($seconds -ge 60) { return "$([Math]::Floor($seconds / 60))m" }
        if ($seconds -ge 1) { return "$([Math]::Floor($seconds))s" }
        return '0s'
    }

    static [timespan] ToDuration([object] $value) {
        $v = [TplFn]::Unwrap($value)
        if ($v -is [timespan]) { return $v }
        if ($v -is [string]) { return [TplFn]::ParseDuration($v) }
        return [timespan]::FromTicks([TplFn]::ToInt64($v) / 100)
    }

    static [object] TimeMethod([object] $receiver, [string] $name, [object[]] $a) {
        $t = [TplFn]::ToTime($receiver)
        switch -CaseSensitive ($name) {
            'Format' { return [TplFn]::GoTimeFormat($t, [TplFn]::Str($a[0])) }
            'Unix' { return $t.ToUnixTimeSeconds() }
            'UnixMilli' { return $t.ToUnixTimeMilliseconds() }
            'UnixNano' { return ($t.UtcTicks - [DateTimeOffset]::UnixEpoch.Ticks) * 100 }
            'Year' { return [int]$t.Year }
            'Month' { return $t.ToString('MMMM', [CultureInfo]::InvariantCulture) }
            'Day' { return [int]$t.Day }
            'Hour' { return [int]$t.Hour }
            'Minute' { return [int]$t.Minute }
            'Second' { return [int]$t.Second }
            'Nanosecond' { return ($t.Ticks % [timespan]::TicksPerSecond) * 100 }
            'YearDay' { return [int]$t.DayOfYear }
            'Weekday' { return $t.ToString('dddd', [CultureInfo]::InvariantCulture) }
            'UTC' { return $t.ToUniversalTime() }
            'Local' { return $t.ToLocalTime() }
            'String' { return [TplFn]::Format($t, $false) }
            'IsZero' { return $t -eq [DateTimeOffset]::MinValue }
            'Add' { return $t.Add([TplFn]::ToDuration($a[0])) }
            'AddDate' { return $t.AddYears([int][TplFn]::ToInt64($a[0])).AddMonths([int][TplFn]::ToInt64($a[1])).AddDays([TplFn]::ToInt64($a[2])) }
            'Sub' { return $t - [TplFn]::ToTime($a[0]) }
            'Before' { return $t -lt [TplFn]::ToTime($a[0]) }
            'After' { return $t -gt [TplFn]::ToTime($a[0]) }
            'Equal' { return $t -eq [TplFn]::ToTime($a[0]) }
        }
        throw "can't evaluate field $name in type time.Time"
    }

    # ---- misc helpers ---------------------------------------------------------------------

    hidden static [string] Hash([string] $algorithm, [string] $text) {
        $bytes = [Encoding]::UTF8.GetBytes($text)
        $hash = if ($algorithm -eq 'sha1') { [System.Security.Cryptography.SHA1]::HashData($bytes) } else { [System.Security.Cryptography.SHA256]::HashData($bytes) }
        return [Convert]::ToHexString($hash).ToLowerInvariant()
    }

    hidden static [string] Base32Encode([byte[]] $bytes) {
        $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
        $sb = [StringBuilder]::new()
        $buffer = 0
        $bits = 0
        foreach ($b in $bytes) {
            $buffer = ($buffer -shl 8) -bor $b
            $bits += 8
            while ($bits -ge 5) {
                [void]$sb.Append($alphabet[($buffer -shr ($bits - 5)) -band 31])
                $bits -= 5
            }
            $buffer = $buffer -band ((1 -shl $bits) - 1)
        }
        if ($bits -gt 0) { [void]$sb.Append($alphabet[($buffer -shl (5 - $bits)) -band 31]) }
        while ($sb.Length % 8 -ne 0) { [void]$sb.Append('=') }
        return $sb.ToString()
    }

    hidden static [byte[]] Base32Decode([string] $text) {
        $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
        $output = [List[byte]]::new()
        $buffer = 0
        $bits = 0
        foreach ($c in $text.TrimEnd('=').ToUpperInvariant().ToCharArray()) {
            $index = $alphabet.IndexOf($c)
            if ($index -lt 0) { throw 'illegal base32 data' }
            $buffer = ($buffer -shl 5) -bor $index
            $bits += 5
            if ($bits -ge 8) {
                $output.Add([byte](($buffer -shr ($bits - 8)) -band 255))
                $bits -= 8
                $buffer = $buffer -band ((1 -shl $bits) - 1)
            }
        }
        return $output.ToArray()
    }

    hidden static [string] Title([string] $s) {
        $sb = [StringBuilder]::new($s.Length)
        $previousIsLetter = $false
        foreach ($c in $s.ToCharArray()) {
            $isLetter = [char]::IsLetterOrDigit($c) -or $c -eq '_' -or $c -eq "'"
            if ($isLetter -and -not $previousIsLetter) { [void]$sb.Append([char]::ToUpperInvariant($c)) } else { [void]$sb.Append($c) }
            $previousIsLetter = $isLetter
        }
        return $sb.ToString()
    }

    hidden static [string] ExpandEnv([string] $s) {
        return [regex]::Replace($s, '\$(\{([^}]*)\}|([A-Za-z_][A-Za-z0-9_]*))', {
                param($match)
                $name = if ($match.Groups[2].Success) { $match.Groups[2].Value } else { $match.Groups[3].Value }
                $value = [Environment]::GetEnvironmentVariable($name)
                if ($null -eq $value) { '' } else { $value }
            })
    }

    hidden static [List[object]] UntilStep([long] $start, [long] $stop, [long] $step) {
        $list = [List[object]]::new()
        if ($stop -lt $start) {
            if ($step -ge 0) { return $list }
            for ($i = $start; $i -gt $stop; $i += $step) { $list.Add([TplFn]::GoInt($i)) }
            return $list
        }
        if ($step -le 0) { return $list }
        for ($i = $start; $i -lt $stop; $i += $step) { $list.Add([TplFn]::GoInt($i)) }
        return $list
    }

    hidden static [object] Index([object] $item, [object[]] $indexes) {
        $current = $item
        foreach ($index in $indexes) {
            $c = [TplFn]::Unwrap($current)
            if ($null -eq $c) { throw 'index of untyped nil' }
            if ($c -is [IDictionary]) {
                $key = [TplFn]::Unwrap($index)
                if ($c.Contains($key)) { $current = $c[$key] }
                elseif ($c.Contains([TplFn]::Str($key))) { $current = $c[[TplFn]::Str($key)] }
                else { $current = $null }
            }
            elseif ($c -is [string]) {
                $position = [TplFn]::ToInt64($index)
                if ($position -lt 0 -or $position -ge $c.Length) { throw "index out of range: $position" }
                $current = [int]$c[[int]$position]
            }
            elseif ([TplFn]::IsList($c)) {
                if (-not [TplFn]::IsInt([TplFn]::Unwrap($index))) { throw "cannot index slice/array with type $([TplFn]::TypeOf($index))" }
                $position = [TplFn]::ToInt64($index)
                $list = $null
                if ($c -is [IList]) { $list = $c } else { $list = [TplFn]::ToList($c) }
                if ($position -lt 0 -or $position -ge $list.Count) { throw "index out of range: $position" }
                $current = $list[[int]$position]
            }
            else { throw "can't index item of type $([TplFn]::TypeOf($c))" }
        }
        return $current
    }

    hidden static [string] JsEscape([string] $s) {
        $sb = [StringBuilder]::new()
        foreach ($c in $s.ToCharArray()) {
            $code = [int]$c
            if ($c -eq '\') { [void]$sb.Append('\\') }
            elseif ($c -eq "'") { [void]$sb.Append("\'") }
            elseif ($c -eq '"') { [void]$sb.Append('\"') }
            elseif ($c -eq '<' -or $c -eq '>' -or $c -eq '&' -or $c -eq '=' -or $code -lt 32) { [void]$sb.Append('\').Append('u').Append($code.ToString('X4')) }
            else { [void]$sb.Append($c) }
        }
        return $sb.ToString()
    }

    hidden static [string] RegexQuoteMeta([string] $s) {
        $sb = [StringBuilder]::new()
        foreach ($c in $s.ToCharArray()) {
            if ('\.+*?()|[]{}^$'.IndexOf($c) -ge 0) { [void]$sb.Append('\') }
            [void]$sb.Append($c)
        }
        return $sb.ToString()
    }

    hidden static [string] Arch() {
        switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
            'X64' { return 'amd64' }
            'X86' { return '386' }
            'Arm64' { return 'arm64' }
            'Arm' { return 'arm' }
        }
        return ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture).ToString().ToLowerInvariant()
    }

    static [string] OS() {
        if ($global:IsWindows) { return 'windows' }
        if ($global:IsMacOS) { return 'darwin' }
        return 'linux'
    }

    hidden static [long] Fold([string] $name, [object[]] $a) {
        if ($a.Count -eq 0) { throw "wrong number of args for ${name}: want at least 1 got 0" }
        $result = [TplFn]::ToInt64($a[0])
        for ($i = 1; $i -lt $a.Count; $i++) {
            $value = [TplFn]::ToInt64($a[$i])
            switch -CaseSensitive ($name) {
                'add' { $result += $value }
                'mul' { $result *= $value }
                'max' { if ($value -gt $result) { $result = $value } }
                'min' { if ($value -lt $result) { $result = $value } }
            }
        }
        return $result
    }

    # ---- the function table ----------------------------------------------------------------

    static [object] Call([string] $name, [object[]] $a) {
        try { return [TplFn]::Invoke($name, $a) }
        catch {
            $message = $_.Exception.Message
            if ($message.StartsWith('function "') -or $message.StartsWith('error calling ')) { throw $message }
            throw "error calling ${name}: $message"
        }
    }

    hidden static [object] Invoke([string] $name, [object[]] $a) {
        $n = $a.Count
        switch -CaseSensitive ($name) {
            # -- text/template builtins
            'not' { return -not [TplFn]::Truth($a[0]) }
            'eq' {
                if ($n -lt 2) { throw 'missing argument for comparison' }
                for ($i = 1; $i -lt $n; $i++) { if ([TplFn]::Equal($a[0], $a[$i])) { return $true } }
                return $false
            }
            'ne' { return -not [TplFn]::Equal($a[0], $a[1]) }
            'lt' { return [TplFn]::Compare($a[0], $a[1]) -lt 0 }
            'le' { return [TplFn]::Compare($a[0], $a[1]) -le 0 }
            'gt' { return [TplFn]::Compare($a[0], $a[1]) -gt 0 }
            'ge' { return [TplFn]::Compare($a[0], $a[1]) -ge 0 }
            'len' {
                $v = [TplFn]::Unwrap($a[0])
                if ($v -is [string]) { return [Encoding]::UTF8.GetByteCount($v) }
                if ($v -is [IDictionary] -or [TplFn]::IsList($v)) { return [TplFn]::Count($v) }
                throw "len of type $([TplFn]::TypeOf($v))"
            }
            'index' { return [TplFn]::Index($a[0], [TplFn]::Rest($a, 1)) }
            'print' { return [TplFn]::Sprint($a, $false) }
            'println' { return [TplFn]::Sprint($a, $true) }
            'printf' { return [TplFn]::Sprintf([TplFn]::Str($a[0]), [TplFn]::Rest($a, 1)) }
            'html' { return [TplFn]::Sprint($a, $false).Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&#34;').Replace("'", '&#39;') }
            'js' { return [TplFn]::JsEscape([TplFn]::Sprint($a, $false)) }
            'urlquery' { return [System.Net.WebUtility]::UrlEncode([TplFn]::Sprint($a, $false)) }
            'call' { throw 'call is not supported' }

            # -- Task functions
            'OS' { return [TplFn]::OS() }
            'ARCH' { return [TplFn]::Arch() }
            'numCPU' { return [Environment]::ProcessorCount }
            'catLines' { return [TplFn]::Str($a[0]).Replace("`r`n", ' ').Replace("`n", ' ') }
            'splitLines' {
                $list = [List[object]]::new()
                foreach ($line in [TplFn]::Str($a[0]).Replace("`r`n", "`n").Split("`n")) { $list.Add($line) }
                return $list
            }
            { $_ -ceq 'fromSlash' -or $_ -ceq 'FromSlash' } { return [TplFn]::Str($a[0]).Replace('/', [System.IO.Path]::DirectorySeparatorChar) }
            { $_ -ceq 'toSlash' -or $_ -ceq 'ToSlash' } { return [TplFn]::Str($a[0]).Replace([System.IO.Path]::DirectorySeparatorChar, '/') }
            { $_ -ceq 'exeExt' -or $_ -ceq 'ExeExt' } { if ($global:IsWindows) { return '.exe' }; return '' }
            { $_ -ceq 'shellQuote' -or $_ -ceq 'q' } { return [TplFn]::ShellQuote([TplFn]::Str($a[0])) }
            'splitArgs' { return [TplFn]::SplitArgs([TplFn]::Str($a[0])) }
            'IsSH' { return $false }
            'joinPath' { return [TplFn]::OsJoin($a) }
            'relPath' { return [System.IO.Path]::GetRelativePath([TplFn]::Str($a[0]), [TplFn]::Str($a[1])) }
            'merge' {
                $result = [TplFn]::NewDict()
                foreach ($item in $a) {
                    $dict = [TplFn]::ToDict($item)
                    foreach ($key in @($dict.get_Keys())) { $result[[string]$key] = $dict[$key] }
                }
                return $result
            }
            'spew' { return "($([TplFn]::TypeOf($a[0]))) $([TplFn]::Format($a[0], $false))`n" }
            { $_ -ceq 'fromYaml' -or $_ -ceq 'mustFromYaml' } { return [TplFn]::FromYaml([TplFn]::Str($a[0])) }
            { $_ -ceq 'toYaml' -or $_ -ceq 'mustToYaml' } { return [TplFn]::ToYaml($a[0]) }
            'uuid' { return [guid]::NewGuid().ToString() }
            'randIntN' { return [TplFn]::GoInt([System.Random]::Shared.NextInt64([TplFn]::ToInt64($a[0]))) }

            # -- strings
            'hello' { return 'Hello!' }
            'trim' { return [TplFn]::Str($a[0]).Trim() }
            { $_ -ceq 'trimAll' -or $_ -ceq 'trimall' } { return [TplFn]::Str($a[1]).Trim([TplFn]::Str($a[0]).ToCharArray()) }
            'trimPrefix' {
                $prefix = [TplFn]::Str($a[0]); $s = [TplFn]::Str($a[1])
                if ($prefix.Length -gt 0 -and $s.StartsWith($prefix, [StringComparison]::Ordinal)) { return $s.Substring($prefix.Length) }
                return $s
            }
            'trimSuffix' {
                $suffix = [TplFn]::Str($a[0]); $s = [TplFn]::Str($a[1])
                if ($suffix.Length -gt 0 -and $s.EndsWith($suffix, [StringComparison]::Ordinal)) { return $s.Substring(0, $s.Length - $suffix.Length) }
                return $s
            }
            'upper' { return [TplFn]::Str($a[0]).ToUpperInvariant() }
            'lower' { return [TplFn]::Str($a[0]).ToLowerInvariant() }
            'title' { return [TplFn]::Title([TplFn]::Str($a[0])) }
            'untitle' { $s = [TplFn]::Str($a[0]); if ($s.Length -eq 0) { return $s }; return [char]::ToLowerInvariant($s[0]) + $s.Substring(1) }
            'repeat' { return [TplFn]::Str($a[1]) * [int][TplFn]::ToInt64($a[0]) }
            'substr' {
                $start = [int][TplFn]::ToInt64($a[0]); $end = [int][TplFn]::ToInt64($a[1]); $s = [TplFn]::Str($a[2])
                if ($start -lt 0) { return $s.Substring(0, [Math]::Min([Math]::Max($end, 0), $s.Length)) }
                if ($start -gt $s.Length) { return '' }
                if ($end -lt 0 -or $end -gt $s.Length) { return $s.Substring($start) }
                return $s.Substring($start, [Math]::Max($end - $start, 0))
            }
            'trunc' {
                $count = [int][TplFn]::ToInt64($a[0]); $s = [TplFn]::Str($a[1])
                if ($count -lt 0 -and $s.Length + $count -gt 0) { return $s.Substring($s.Length + $count) }
                if ($count -ge 0 -and $s.Length -gt $count) { return $s.Substring(0, $count) }
                return $s
            }
            'contains' { return [TplFn]::Str($a[1]).Contains([TplFn]::Str($a[0]), [StringComparison]::Ordinal) }
            'hasPrefix' { return [TplFn]::Str($a[1]).StartsWith([TplFn]::Str($a[0]), [StringComparison]::Ordinal) }
            'hasSuffix' { return [TplFn]::Str($a[1]).EndsWith([TplFn]::Str($a[0]), [StringComparison]::Ordinal) }
            'quote' {
                $parts = [List[string]]::new()
                foreach ($item in $a) { if ($null -ne $item) { $parts.Add([TplFn]::GoQuote([TplFn]::Str($item))) } }
                return [string]::Join(' ', $parts)
            }
            'squote' {
                $parts = [List[string]]::new()
                foreach ($item in $a) { if ($null -ne $item) { $parts.Add("'" + [TplFn]::Str($item) + "'") } }
                return [string]::Join(' ', $parts)
            }
            'cat' {
                $parts = [List[string]]::new()
                foreach ($item in $a) { if ($null -ne $item) { $parts.Add([TplFn]::Str($item)) } }
                return [string]::Join(' ', $parts)
            }
            'indent' { $pad = ' ' * [int][TplFn]::ToInt64($a[0]); return $pad + [TplFn]::Str($a[1]).Replace("`n", "`n$pad") }
            'nindent' { $pad = ' ' * [int][TplFn]::ToInt64($a[0]); return "`n" + $pad + [TplFn]::Str($a[1]).Replace("`n", "`n$pad") }
            'replace' {
                $old = [TplFn]::Str($a[0]); $s = [TplFn]::Str($a[2])
                if ($old.Length -eq 0) { return $s }
                return $s.Replace($old, [TplFn]::Str($a[1]), [StringComparison]::Ordinal)
            }
            'plural' { if ([TplFn]::ToInt64($a[2]) -eq 1) { return [TplFn]::Str($a[0]) }; return [TplFn]::Str($a[1]) }
            'sha1sum' { return [TplFn]::Hash('sha1', [TplFn]::Str($a[0])) }
            'sha256sum' { return [TplFn]::Hash('sha256', [TplFn]::Str($a[0])) }
            'adler32sum' {
                $x = [uint32]1; $y = [uint32]0
                foreach ($b in [Encoding]::UTF8.GetBytes([TplFn]::Str($a[0]))) { $x = ($x + $b) % 65521; $y = ($y + $x) % 65521 }
                return ([uint32](($y -shl 16) -bor $x)).ToString([CultureInfo]::InvariantCulture)
            }
            'toString' { return [TplFn]::Format($a[0], $false) }
            'toStrings' {
                $list = [List[object]]::new()
                foreach ($item in [TplFn]::ToList($a[0])) { if ($null -ne $item) { $list.Add([TplFn]::Str($item)) } }
                return $list
            }
            'split' {
                $dict = [TplFn]::NewDict()
                $index = 0
                foreach ($part in [TplFn]::Str($a[1]).Split([string[]]@([TplFn]::Str($a[0])), [StringSplitOptions]::None)) { $dict["_$index"] = $part; $index++ }
                return $dict
            }
            'splitn' {
                $dict = [TplFn]::NewDict()
                $index = 0
                foreach ($part in [TplFn]::Str($a[2]).Split([string[]]@([TplFn]::Str($a[0])), [int][TplFn]::ToInt64($a[1]), [StringSplitOptions]::None)) { $dict["_$index"] = $part; $index++ }
                return $dict
            }
            'splitList' {
                $list = [List[object]]::new()
                $separator = [TplFn]::Str($a[0]); $s = [TplFn]::Str($a[1])
                if ($separator.Length -eq 0) { foreach ($c in $s.ToCharArray()) { $list.Add([string]$c) }; return $list }
                foreach ($part in $s.Split([string[]]@($separator), [StringSplitOptions]::None)) { $list.Add($part) }
                return $list
            }
            'join' {
                $v = [TplFn]::Unwrap($a[1])
                if ($null -eq $v) { return '' }
                if (-not [TplFn]::IsList($v)) { return [TplFn]::Str($v) }
                $parts = [List[string]]::new()
                foreach ($item in $v) { if ($null -ne $item) { $parts.Add([TplFn]::Str($item)) } }
                return [string]::Join([TplFn]::Str($a[0]), $parts)
            }
            'sortAlpha' {
                $v = [TplFn]::Unwrap($a[0])
                $parts = [List[string]]::new()
                if ([TplFn]::IsList($v)) { foreach ($item in $v) { $parts.Add([TplFn]::Str($item)) } } else { $parts.Add([TplFn]::Str($v)) }
                $array = $parts.ToArray()
                [Array]::Sort($array, [StringComparer]::Ordinal)
                return [List[object]]::new([object[]]$array)
            }

            # -- math / conversion
            'atoi' {
                $parsed = 0
                if ([int]::TryParse([TplFn]::Str($a[0]), [NumberStyles]::AllowLeadingSign, [CultureInfo]::InvariantCulture, [ref] $parsed)) { return $parsed }
                return 0
            }
            'int' { return [TplFn]::GoInt([TplFn]::ToInt64($a[0])) }
            'int64' { return [TplFn]::ToInt64($a[0]) }
            'float64' { return [TplFn]::ToFloat64($a[0]) }
            'toDecimal' { try { return [Convert]::ToInt64([TplFn]::Str($a[0]), 8) } catch { return 0L } }
            'add1' { return [TplFn]::ToInt64($a[0]) + 1 }
            { $_ -ceq 'add' -or $_ -ceq 'mul' -or $_ -ceq 'max' -or $_ -ceq 'min' } { return [TplFn]::Fold($name, $a) }
            'biggest' { return [TplFn]::Fold('max', $a) }
            'sub' { return [TplFn]::ToInt64($a[0]) - [TplFn]::ToInt64($a[1]) }
            'div' {
                $divisor = [TplFn]::ToInt64($a[1])
                if ($divisor -eq 0) { throw 'runtime error: integer divide by zero' }
                return [long][Math]::Truncate([decimal][TplFn]::ToInt64($a[0]) / $divisor)
            }
            'mod' {
                $divisor = [TplFn]::ToInt64($a[1])
                if ($divisor -eq 0) { throw 'runtime error: integer divide by zero' }
                return [TplFn]::ToInt64($a[0]) % $divisor
            }
            'maxf' { $r = [TplFn]::ToFloat64($a[0]); foreach ($item in $a) { $r = [Math]::Max($r, [TplFn]::ToFloat64($item)) }; return $r }
            'minf' { $r = [TplFn]::ToFloat64($a[0]); foreach ($item in $a) { $r = [Math]::Min($r, [TplFn]::ToFloat64($item)) }; return $r }
            'ceil' { return [Math]::Ceiling([TplFn]::ToFloat64($a[0])) }
            'floor' { return [Math]::Floor([TplFn]::ToFloat64($a[0])) }
            'round' {
                $places = [int][TplFn]::ToInt64($a[1])
                return [Math]::Round([TplFn]::ToFloat64($a[0]), $places, [MidpointRounding]::AwayFromZero)
            }
            'randInt' {
                $low = [TplFn]::ToInt64($a[0]); $high = [TplFn]::ToInt64($a[1])
                return [TplFn]::GoInt([System.Random]::Shared.NextInt64($low, $high))
            }
            'seq' {
                $values = $null
                if ($n -eq 1) {
                    $end = [TplFn]::ToInt64($a[0])
                    $step = if ($end -lt 1) { -1 } else { 1 }
                    $values = [TplFn]::UntilStep(1, $end + $step, $step)
                }
                elseif ($n -eq 2) {
                    $start = [TplFn]::ToInt64($a[0]); $end = [TplFn]::ToInt64($a[1])
                    $step = if ($end -lt $start) { -1 } else { 1 }
                    $values = [TplFn]::UntilStep($start, $end + $step, $step)
                }
                elseif ($n -eq 3) {
                    $start = [TplFn]::ToInt64($a[0]); $step = [TplFn]::ToInt64($a[1]); $end = [TplFn]::ToInt64($a[2])
                    $increment = 1
                    if ($end -lt $start) { $increment = -1; if ($step -gt 0) { return '' } }
                    $values = [TplFn]::UntilStep($start, $end + $increment, $step)
                }
                else { return '' }
                $parts = [List[string]]::new()
                foreach ($value in $values) { $parts.Add([TplFn]::Str($value)) }
                return [string]::Join(' ', $parts)
            }
            'until' {
                $count = [TplFn]::ToInt64($a[0])
                $step = if ($count -lt 0) { -1 } else { 1 }
                return [TplFn]::UntilStep(0, $count, $step)
            }
            'untilStep' { return [TplFn]::UntilStep([TplFn]::ToInt64($a[0]), [TplFn]::ToInt64($a[1]), [TplFn]::ToInt64($a[2])) }

            # -- defaults / logic
            'default' { if ($n -lt 2 -or -not [TplFn]::Truth($a[1])) { return $a[0] }; return $a[1] }
            'empty' { return -not [TplFn]::Truth($a[0]) }
            'coalesce' { foreach ($item in $a) { if ([TplFn]::Truth($item)) { return $item } }; return $null }
            'all' { foreach ($item in $a) { if (-not [TplFn]::Truth($item)) { return $false } }; return $true }
            'any' { foreach ($item in $a) { if ([TplFn]::Truth($item)) { return $true } }; return $false }
            'ternary' { if ([TplFn]::Truth($a[2])) { return $a[0] }; return $a[1] }
            'fail' { throw [TplFn]::Str($a[0]) }

            # -- JSON
            'fromJson' { try { return [TplFn]::FromJson([TplFn]::Str($a[0])) } catch { return $null } }
            'mustFromJson' { return [TplFn]::FromJson([TplFn]::Str($a[0])) }
            { $_ -ceq 'toJson' -or $_ -ceq 'mustToJson' } { return [TplFn]::ToJson($a[0], $true, '', '') }
            { $_ -ceq 'toPrettyJson' -or $_ -ceq 'mustToPrettyJson' } { return [TplFn]::ToJson($a[0], $true, '  ', '') }
            { $_ -ceq 'toRawJson' -or $_ -ceq 'mustToRawJson' } { return [TplFn]::ToJson($a[0], $false, '', '') }

            # -- reflection
            'typeOf' { return [TplFn]::TypeOf($a[0]) }
            'typeIs' { return [TplFn]::TypeOf($a[1]) -ceq [TplFn]::Str($a[0]) }
            'typeIsLike' { $t = [TplFn]::TypeOf($a[1]); $want = [TplFn]::Str($a[0]); return $t -ceq $want -or "*$t" -ceq $want }
            'kindOf' { return [TplFn]::KindOf($a[0]) }
            'kindIs' { return [TplFn]::KindOf($a[1]) -ceq [TplFn]::Str($a[0]) }
            'deepEqual' { return [TplFn]::DeepEqual($a[0], $a[1]) }

            # -- OS / network
            'env' { $value = [Environment]::GetEnvironmentVariable([TplFn]::Str($a[0])); if ($null -eq $value) { return '' }; return $value }
            'expandenv' { return [TplFn]::ExpandEnv([TplFn]::Str($a[0])) }
            'getHostByName' {
                try { return [System.Net.Dns]::GetHostAddresses([TplFn]::Str($a[0]))[0].ToString() } catch { return '' }
            }

            # -- paths
            'base' { return [TplFn]::PathBase([TplFn]::Str($a[0])) }
            'dir' { return [TplFn]::PathDir([TplFn]::Str($a[0])) }
            'clean' { return [TplFn]::PathClean([TplFn]::Str($a[0])) }
            'ext' { return [TplFn]::PathExt([TplFn]::Str($a[0])) }
            'isAbs' { return [TplFn]::Str($a[0]).StartsWith('/') }
            'osBase' {
                $p = [TplFn]::Str($a[0])
                if ($p.Length -eq 0) { return '.' }
                $file = [System.IO.Path]::GetFileName($p.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar))
                if ($file.Length -eq 0) { return [string][System.IO.Path]::DirectorySeparatorChar }
                return $file
            }
            'osDir' {
                $directory = [System.IO.Path]::GetDirectoryName([TplFn]::Str($a[0]))
                if ([string]::IsNullOrEmpty($directory)) { return '.' }
                return [TplFn]::OsClean($directory)
            }
            'osClean' { return [TplFn]::OsClean([TplFn]::Str($a[0])) }
            'osExt' { return [System.IO.Path]::GetExtension([TplFn]::Str($a[0])) }
            'osIsAbs' { return [System.IO.Path]::IsPathFullyQualified([TplFn]::Str($a[0])) }

            # -- encoding
            'b64enc' { return [Convert]::ToBase64String([Encoding]::UTF8.GetBytes([TplFn]::Str($a[0]))) }
            'b64dec' { return [Encoding]::UTF8.GetString([Convert]::FromBase64String([TplFn]::Str($a[0]))) }
            'b32enc' { return [TplFn]::Base32Encode([Encoding]::UTF8.GetBytes([TplFn]::Str($a[0]))) }
            'b32dec' { return [Encoding]::UTF8.GetString([TplFn]::Base32Decode([TplFn]::Str($a[0]))) }

            # -- lists
            { $_ -ceq 'list' -or $_ -ceq 'tuple' } { return [List[object]]::new($a) }
            { $_ -ceq 'append' -or $_ -ceq 'push' -or $_ -ceq 'mustAppend' -or $_ -ceq 'mustPush' } {
                $list = [TplFn]::ToList($a[0]); $list.Add($a[1]); return $list
            }
            { $_ -ceq 'prepend' -or $_ -ceq 'mustPrepend' } { $list = [TplFn]::ToList($a[0]); $list.Insert(0, $a[1]); return $list }
            { $_ -ceq 'first' -or $_ -ceq 'mustFirst' } { $list = [TplFn]::ToList($a[0]); if ($list.Count -eq 0) { return $null }; return $list[0] }
            { $_ -ceq 'last' -or $_ -ceq 'mustLast' } { $list = [TplFn]::ToList($a[0]); if ($list.Count -eq 0) { return $null }; return $list[$list.Count - 1] }
            { $_ -ceq 'rest' -or $_ -ceq 'mustRest' } { $list = [TplFn]::ToList($a[0]); if ($list.Count -eq 0) { return $null }; return $list.GetRange(1, $list.Count - 1) }
            { $_ -ceq 'initial' -or $_ -ceq 'mustInitial' } { $list = [TplFn]::ToList($a[0]); if ($list.Count -eq 0) { return $null }; return $list.GetRange(0, $list.Count - 1) }
            { $_ -ceq 'reverse' -or $_ -ceq 'mustReverse' } { $list = [TplFn]::ToList($a[0]); $list.Reverse(); return $list }
            { $_ -ceq 'uniq' -or $_ -ceq 'mustUniq' } {
                $result = [List[object]]::new()
                foreach ($item in [TplFn]::ToList($a[0])) {
                    $found = $false
                    foreach ($existing in $result) { if ([TplFn]::DeepEqual($existing, $item)) { $found = $true; break } }
                    if (-not $found) { $result.Add($item) }
                }
                return $result
            }
            { $_ -ceq 'without' -or $_ -ceq 'mustWithout' } {
                $result = [List[object]]::new()
                foreach ($item in [TplFn]::ToList($a[0])) {
                    $omit = $false
                    for ($i = 1; $i -lt $n; $i++) { if ([TplFn]::DeepEqual($a[$i], $item)) { $omit = $true; break } }
                    if (-not $omit) { $result.Add($item) }
                }
                return $result
            }
            { $_ -ceq 'has' -or $_ -ceq 'mustHas' } {
                foreach ($item in [TplFn]::ToList($a[1])) { if ([TplFn]::DeepEqual($a[0], $item)) { return $true } }
                return $false
            }
            { $_ -ceq 'compact' -or $_ -ceq 'mustCompact' } {
                $result = [List[object]]::new()
                foreach ($item in [TplFn]::ToList($a[0])) { if ([TplFn]::Truth($item)) { $result.Add($item) } }
                return $result
            }
            { $_ -ceq 'slice' -or $_ -ceq 'mustSlice' } {
                $v = [TplFn]::Unwrap($a[0])
                $length = if ($v -is [string]) { $v.Length } else { [TplFn]::ToList($v).Count }
                $start = if ($n -gt 1) { [int][TplFn]::ToInt64($a[1]) } else { 0 }
                $end = if ($n -gt 2) { [int][TplFn]::ToInt64($a[2]) } else { $length }
                if ($start -lt 0 -or $end -gt $length -or $start -gt $end) { throw "slice bounds out of range [${start}:${end}] with length $length" }
                if ($v -is [string]) { return $v.Substring($start, $end - $start) }
                return [TplFn]::ToList($v).GetRange($start, $end - $start)
            }
            'concat' {
                $result = [List[object]]::new()
                foreach ($item in $a) { $result.AddRange([TplFn]::ToList($item)) }
                return $result
            }
            { $_ -ceq 'chunk' -or $_ -ceq 'mustChunk' } {
                $size = [int][TplFn]::ToInt64($a[0])
                if ($size -le 0) { throw 'chunk size must be positive' }
                $list = [TplFn]::ToList($a[1])
                $result = [List[object]]::new()
                for ($i = 0; $i -lt $list.Count; $i += $size) { $result.Add($list.GetRange($i, [Math]::Min($size, $list.Count - $i))) }
                return $result
            }

            # -- dicts
            'dict' {
                $dict = [TplFn]::NewDict()
                for ($i = 0; $i -lt $n; $i += 2) {
                    if ($i + 1 -lt $n) { $dict[[TplFn]::Str($a[$i])] = $a[$i + 1] } else { $dict[[TplFn]::Str($a[$i])] = '' }
                }
                return $dict
            }
            'get' { $dict = [TplFn]::ToDict($a[0]); $key = [TplFn]::Str($a[1]); if ($dict.Contains($key)) { return $dict[$key] }; return '' }
            'set' { $dict = [TplFn]::ToDict($a[0]); $dict[[TplFn]::Str($a[1])] = $a[2]; return $dict }
            'unset' { $dict = [TplFn]::ToDict($a[0]); $dict.Remove([TplFn]::Str($a[1])); return $dict }
            'hasKey' { return [TplFn]::ToDict($a[0]).Contains([TplFn]::Str($a[1])) }
            'pluck' {
                $result = [List[object]]::new()
                $key = [TplFn]::Str($a[0])
                for ($i = 1; $i -lt $n; $i++) { $dict = [TplFn]::ToDict($a[$i]); if ($dict.Contains($key)) { $result.Add($dict[$key]) } }
                return $result
            }
            'keys' {
                $result = [List[object]]::new()
                foreach ($item in $a) { foreach ($key in [TplFn]::ToDict($item).get_Keys()) { $result.Add([string]$key) } }
                return $result
            }
            'values' {
                $result = [List[object]]::new()
                $dict = [TplFn]::ToDict($a[0])
                foreach ($key in $dict.get_Keys()) { $result.Add($dict[$key]) }
                return $result
            }
            'pick' {
                $source = [TplFn]::ToDict($a[0]); $dict = [TplFn]::NewDict()
                for ($i = 1; $i -lt $n; $i++) { $key = [TplFn]::Str($a[$i]); if ($source.Contains($key)) { $dict[$key] = $source[$key] } }
                return $dict
            }
            'omit' {
                $source = [TplFn]::ToDict($a[0]); $dict = [TplFn]::NewDict()
                $omitted = [HashSet[string]]::new([StringComparer]::Ordinal)
                for ($i = 1; $i -lt $n; $i++) { [void]$omitted.Add([TplFn]::Str($a[$i])) }
                foreach ($key in $source.get_Keys()) { if (-not $omitted.Contains([string]$key)) { $dict[[string]$key] = $source[$key] } }
                return $dict
            }
            'dig' {
                if ($n -lt 3) { throw 'dig needs at least three arguments' }
                $current = [TplFn]::Unwrap($a[$n - 1])
                $default = $a[$n - 2]
                for ($i = 0; $i -lt $n - 2; $i++) {
                    $key = [TplFn]::Str($a[$i])
                    if ($current -isnot [IDictionary] -or -not $current.Contains($key)) { return $default }
                    $current = [TplFn]::Unwrap($current[$key])
                }
                return $current
            }

            # -- regex
            { $_ -ceq 'regexMatch' -or $_ -ceq 'mustRegexMatch' } { return [regex]::IsMatch([TplFn]::Str($a[1]), [TplFn]::Str($a[0])) }
            { $_ -ceq 'regexFindAll' -or $_ -ceq 'mustRegexFindAll' } {
                $result = [List[object]]::new()
                $limit = [TplFn]::ToInt64($a[2])
                foreach ($match in [regex]::Matches([TplFn]::Str($a[1]), [TplFn]::Str($a[0]))) {
                    if ($limit -ge 0 -and $result.Count -ge $limit) { break }
                    $result.Add($match.Value)
                }
                return $result
            }
            { $_ -ceq 'regexFind' -or $_ -ceq 'mustRegexFind' } { return [regex]::Match([TplFn]::Str($a[1]), [TplFn]::Str($a[0])).Value }
            { $_ -ceq 'regexReplaceAll' -or $_ -ceq 'mustRegexReplaceAll' } { return [regex]::Replace([TplFn]::Str($a[1]), [TplFn]::Str($a[0]), [TplFn]::Str($a[2])) }
            { $_ -ceq 'regexReplaceAllLiteral' -or $_ -ceq 'mustRegexReplaceAllLiteral' } {
                return [regex]::Replace([TplFn]::Str($a[1]), [TplFn]::Str($a[0]), [TplFn]::Str($a[2]).Replace('$', '$$'))
            }
            { $_ -ceq 'regexSplit' -or $_ -ceq 'mustRegexSplit' } {
                $limit = [int][TplFn]::ToInt64($a[2])
                $regex = [regex]::new([TplFn]::Str($a[0]))
                $parts = [string[]]@()
                if ($limit -lt 0) { $parts = $regex.Split([TplFn]::Str($a[1])) } else { $parts = $regex.Split([TplFn]::Str($a[1]), $limit) }
                return [List[object]]::new([object[]]$parts)
            }
            'regexQuoteMeta' { return [TplFn]::RegexQuoteMeta([TplFn]::Str($a[0])) }

            # -- URLs
            'urlParse' {
                $uri = [uri]::new([TplFn]::Str($a[0]))
                $dict = [TplFn]::NewDict()
                $dict['scheme'] = $uri.Scheme
                $dict['host'] = $uri.Authority
                $dict['hostname'] = $uri.Host
                $dict['path'] = $uri.AbsolutePath
                $dict['query'] = $uri.Query.TrimStart('?')
                $dict['opaque'] = ''
                $dict['fragment'] = $uri.Fragment.TrimStart('#')
                $dict['userinfo'] = $uri.UserInfo
                return $dict
            }
            'urlJoin' {
                $dict = [TplFn]::ToDict($a[0])
                $sb = [StringBuilder]::new()
                if ([TplFn]::Truth($dict['scheme'])) { [void]$sb.Append([TplFn]::Str($dict['scheme'])).Append('://') }
                if ([TplFn]::Truth($dict['userinfo'])) { [void]$sb.Append([TplFn]::Str($dict['userinfo'])).Append('@') }
                [void]$sb.Append([TplFn]::Str($dict['host'])).Append([TplFn]::Str($dict['path']))
                if ([TplFn]::Truth($dict['query'])) { [void]$sb.Append('?').Append([TplFn]::Str($dict['query'])) }
                if ([TplFn]::Truth($dict['fragment'])) { [void]$sb.Append('#').Append([TplFn]::Str($dict['fragment'])) }
                return $sb.ToString()
            }

            # -- dates
            'now' { return [DateTimeOffset]::Now }
            'date' { return [TplFn]::GoTimeFormat([TplFn]::ToTime($a[1]), [TplFn]::Str($a[0])) }
            { $_ -ceq 'dateInZone' -or $_ -ceq 'date_in_zone' } {
                $zone = [TimeZoneInfo]::FindSystemTimeZoneById([TplFn]::Str($a[2]))
                return [TplFn]::GoTimeFormat([TimeZoneInfo]::ConvertTime([TplFn]::ToTime($a[1]), $zone), [TplFn]::Str($a[0]))
            }
            { $_ -ceq 'dateModify' -or $_ -ceq 'date_modify' -or $_ -ceq 'mustDateModify' -or $_ -ceq 'must_date_modify' } {
                return [TplFn]::ToTime($a[1]).Add([TplFn]::ParseDuration([TplFn]::Str($a[0])))
            }
            'ago' {
                $elapsed = [DateTimeOffset]::Now - [TplFn]::ToTime($a[0])
                return [TplFn]::DurationString([timespan]::FromSeconds([Math]::Round($elapsed.TotalSeconds)))
            }
            'duration' { return [TplFn]::DurationString([timespan]::FromSeconds([TplFn]::ToInt64($a[0]))) }
            'durationRound' { return [TplFn]::DurationRound([TplFn]::ToDuration($a[0])) }
            'htmlDate' { return [TplFn]::GoTimeFormat([TplFn]::ToTime($a[0]), '2006-01-02') }
            'htmlDateInZone' {
                $zone = [TimeZoneInfo]::FindSystemTimeZoneById([TplFn]::Str($a[1]))
                return [TplFn]::GoTimeFormat([TimeZoneInfo]::ConvertTime([TplFn]::ToTime($a[0]), $zone), '2006-01-02')
            }
            'toDate' { try { return [TplFn]::ParseGoTime([TplFn]::Str($a[0]), [TplFn]::Str($a[1])) } catch { return [DateTimeOffset]::MinValue } }
            'mustToDate' { return [TplFn]::ParseGoTime([TplFn]::Str($a[0]), [TplFn]::Str($a[1])) }
            'unixEpoch' { return [TplFn]::ToTime($a[0]).ToUnixTimeSeconds().ToString([CultureInfo]::InvariantCulture) }
        }
        throw "function `"$name`" not defined"
    }
}

[NoRunspaceAffinity()]
class TplEngine {
    static [string] Expand([string] $text, [object] $data) {
        if ([string]::IsNullOrEmpty($text)) { return '' }
        if ($text.IndexOf('{{', [StringComparison]::Ordinal) -lt 0) { return $text }
        try {
            $parser = [TplParser]::Parse($text)
            $exec = [TplExec]::new($parser.Templates, $data)
            [void]$exec.Walk($data, $parser.Root)
            return $exec.Out.ToString().Replace('<no value>', '')
        }
        catch {
            throw [System.InvalidOperationException]::new([TplEngine]::ErrorMessage($_.Exception))
        }
    }

    # Evaluates a single pipeline (the content of an action) and returns the typed result.
    static [object] Resolve([string] $expression, [object] $data) {
        if ($expression.Trim() -eq '.') { return $data }
        try {
            $parser = [TplParser]::Parse('{{' + $expression + '}}')
            $exec = [TplExec]::new($parser.Templates, $data)
            foreach ($node in $parser.Root.Items) {
                if ($node.Kind -eq 'action') { return $exec.EvalPipeline($data, $node.Pipe) }
            }
            return $null
        }
        catch {
            throw [System.InvalidOperationException]::new([TplEngine]::ErrorMessage($_.Exception))
        }
    }

    # Expands every string inside a (possibly nested) value. Returns new collections.
    static [object] ExpandValue([object] $value, [object] $data) {
        $v = [TplFn]::Unwrap($value)
        if ($v -is [string]) { return [TplEngine]::Expand($v, $data) }
        if ($v -is [IDictionary]) {
            $dict = [OrderedDictionary]::new()
            foreach ($key in @($v.get_Keys())) { $dict[[string]$key] = [TplEngine]::ExpandValue($v[$key], $data) }
            return $dict
        }
        if ([TplFn]::IsList($v)) {
            $list = [List[object]]::new()
            foreach ($item in $v) { $list.Add([TplEngine]::ExpandValue($item, $data)) }
            return $list
        }
        return $v
    }

    hidden static [string] ErrorMessage([Exception] $exception) {
        $inner = $exception
        while ($null -ne $inner.InnerException -and $inner -is [System.Management.Automation.MethodInvocationException]) { $inner = $inner.InnerException }
        $message = $inner.Message
        if ($message.StartsWith('template: ')) { return $message }
        return "template: $message"
    }
}

function Expand-TaskTemplate {
    <#
    .SYNOPSIS
        Expands a Go-style template string against a variable map.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowNull()][AllowEmptyString()][string]$Template,
        [Parameter(Position = 1)][AllowNull()][object]$Data
    )
    [TplEngine]::Expand($Template, $Data)
}

function Resolve-TaskTemplateValue {
    <#
    .SYNOPSIS
        Evaluates a template pipeline (the "ref" syntax) and returns the typed value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Expression,
        [Parameter(Position = 1)][AllowNull()][object]$Data
    )
    , [TplEngine]::Resolve($Expression, $Data)
}

function Expand-TaskTemplateValue {
    <#
    .SYNOPSIS
        Expands the template strings nested inside a list / map value.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$Value,
        [Parameter(Position = 1)][AllowNull()][object]$Data
    )
    , [TplEngine]::ExpandValue($Value, $Data)
}
