using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Collections.Specialized
using namespace System.Globalization

# YAML access built on the YamlDotNet representation model that ships with powershell-yaml.
#
# ConvertFrom-Yaml is not used for Taskfiles because it returns case-insensitive
# dictionaries (Taskfile variable and task names are case-sensitive) and drops the
# position of nodes. Working on the node tree keeps both.

[NoRunspaceAffinity()]
class TaskYaml {
    hidden static [type] $StreamType

    hidden static [type] ResolveStreamType() {
        if ($null -ne [TaskYaml]::StreamType) { return [TaskYaml]::StreamType }
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            foreach ($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
                if ($assembly.GetName().Name -ne 'YamlDotNet') { continue }
                $type = $assembly.GetType('YamlDotNet.RepresentationModel.YamlStream')
                if ($null -ne $type) {
                    [TaskYaml]::StreamType = $type
                    return $type
                }
            }
            # Importing powershell-yaml and converting once loads YamlDotNet into the process.
            Import-Module powershell-yaml -ErrorAction Stop
            $null = ConvertFrom-Yaml -Yaml 'a: 1'
        }
        throw "PS-TaskFile requires the 'powershell-yaml' module (YamlDotNet could not be located)."
    }

    # Parses YAML text and returns the root node ($null for an empty document).
    static [object] Load([string] $text) {
        $stream = [Activator]::CreateInstance([TaskYaml]::ResolveStreamType())
        $reader = [System.IO.StringReader]::new($text)
        try { $stream.Load($reader) } finally { $reader.Dispose() }
        if ($stream.Documents.Count -eq 0) { return $null }
        return $stream.Documents[0].RootNode
    }

    hidden static [bool] IsNullScalar([object] $node) {
        if ([string]$node.Style -ne 'Plain') { return $false }
        $text = [string]$node.Value
        return $text.Length -eq 0 -or $text -ceq '~' -or $text -ceq 'null' -or $text -ceq 'Null' -or $text -ceq 'NULL'
    }

    # 'map', 'seq', 'scalar' or 'null'.
    static [string] Kind([object] $node) {
        if ($null -eq $node) { return 'null' }
        $type = [string]$node.NodeType
        if ($type -eq 'Mapping') { return 'map' }
        if ($type -eq 'Sequence') { return 'seq' }
        if ($type -eq 'Scalar' -and [TaskYaml]::IsNullScalar($node)) { return 'null' }
        return 'scalar'
    }

    static [bool] IsMap([object] $node) { return [TaskYaml]::Kind($node) -eq 'map' }

    static [int] Line([object] $node) { if ($null -eq $node) { return 0 }; return [int]$node.Start.Line }

    static [int] Column([object] $node) { if ($null -eq $node) { return 0 }; return [int]$node.Start.Column }

    # Child nodes of a mapping keyed by name (case-sensitive, document order, merge keys applied).
    static [OrderedDictionary] Map([object] $node) {
        $result = [OrderedDictionary]::new()
        if ([TaskYaml]::Kind($node) -ne 'map') { return $result }
        $merges = [List[object]]::new()
        foreach ($pair in $node.Children) {
            $keyNode = $pair.Key
            $key = if ([string]$keyNode.NodeType -eq 'Scalar') { [string]$keyNode.Value } else { [string]$keyNode }
            if ($key -ceq '<<' -and [string]$keyNode.Style -eq 'Plain') { $merges.Add($pair.Value); continue }
            $result[$key] = $pair.Value
        }
        foreach ($merge in $merges) {
            $sources = [List[object]]::new()
            if ([TaskYaml]::Kind($merge) -eq 'seq') { foreach ($child in $merge.Children) { $sources.Add($child) } } else { $sources.Add($merge) }
            foreach ($source in $sources) {
                $merged = [TaskYaml]::Map($source)
                foreach ($key in $merged.get_Keys()) { if (-not $result.Contains($key)) { $result[[string]$key] = $merged[$key] } }
            }
        }
        return $result
    }

    # Key nodes of a mapping by name (for positions).
    static [OrderedDictionary] KeyNodes([object] $node) {
        $result = [OrderedDictionary]::new()
        if ([TaskYaml]::Kind($node) -ne 'map') { return $result }
        foreach ($pair in $node.Children) {
            if ([string]$pair.Key.NodeType -eq 'Scalar') { $result[[string]$pair.Key.Value] = $pair.Key }
        }
        return $result
    }

    # Items of a sequence. A single non-null node is treated as a one-element list.
    static [List[object]] Seq([object] $node) {
        $list = [List[object]]::new()
        $kind = [TaskYaml]::Kind($node)
        if ($kind -eq 'null') { return $list }
        if ($kind -eq 'seq') { foreach ($child in $node.Children) { $list.Add($child) } }
        else { $list.Add($node) }
        return $list
    }

    # The raw text of a scalar ('' for null and for non-scalars).
    static [string] Str([object] $node) {
        if ([TaskYaml]::Kind($node) -ne 'scalar') { return '' }
        return [string]$node.Value
    }

    static [bool] Bool([object] $node) {
        $text = [TaskYaml]::Str($node)
        return $text -cin @('true', 'True', 'TRUE', 'yes', 'Yes', 'YES', 'on', 'On', 'ON', 'y', 'Y')
    }

    static [string[]] StrList([object] $node) {
        $list = [List[string]]::new()
        foreach ($item in [TaskYaml]::Seq($node)) { $list.Add([TaskYaml]::Str($item)) }
        return $list.ToArray()
    }

    hidden static [object] ParseInteger([string] $plain) {
        $negative = $plain.StartsWith('-')
        $digits = $plain.TrimStart('+', '-')
        $value = 0L
        if ($digits.StartsWith('0x', [StringComparison]::OrdinalIgnoreCase)) { $value = [Convert]::ToInt64($digits.Substring(2), 16) }
        elseif ($digits.StartsWith('0o', [StringComparison]::OrdinalIgnoreCase)) { $value = [Convert]::ToInt64($digits.Substring(2), 8) }
        elseif ($digits.StartsWith('0b', [StringComparison]::OrdinalIgnoreCase)) { $value = [Convert]::ToInt64($digits.Substring(2), 2) }
        elseif ($digits.Length -gt 1 -and $digits[0] -eq '0') { $value = [Convert]::ToInt64($digits, 8) }
        else { $value = [long]::Parse($digits, [NumberStyles]::None, [CultureInfo]::InvariantCulture) }
        if ($negative) { $value = - $value }
        if ($value -ge [int]::MinValue -and $value -le [int]::MaxValue) { return [int]$value }
        return $value
    }

    # Resolves a plain scalar like the YAML 1.2 core schema (as go-yaml does).
    static [object] ResolvePlain([string] $text) {
        if ($text.Length -eq 0 -or $text -ceq '~' -or $text -ceq 'null' -or $text -ceq 'Null' -or $text -ceq 'NULL') { return $null }
        if ($text -ceq 'true' -or $text -ceq 'True' -or $text -ceq 'TRUE') { return $true }
        if ($text -ceq 'false' -or $text -ceq 'False' -or $text -ceq 'FALSE') { return $false }
        if ($text -cmatch '^[-+]?\.(inf|Inf|INF)$') { if ($text.StartsWith('-')) { return [double]::NegativeInfinity }; return [double]::PositiveInfinity }
        if ($text -cmatch '^\.(nan|NaN|NAN)$') { return [double]::NaN }
        $first = $text[0]
        if (-not ([char]::IsDigit($first) -or $first -eq '-' -or $first -eq '+' -or $first -eq '.')) { return $text }
        $plain = $text.Replace('_', '')
        if ($plain -cmatch '^[-+]?(0[xX][0-9a-fA-F]+|0[oO][0-7]+|0[bB][01]+|[0-9]+)$') {
            try { return [TaskYaml]::ParseInteger($plain) } catch { }
        }
        if ($plain -cmatch '^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$') {
            return [double]::Parse($plain, [NumberStyles]::Float, [CultureInfo]::InvariantCulture)
        }
        return $text
    }

    hidden static [object] Scalar([object] $node) {
        $text = [string]$node.Value
        $tag = [string]$node.Tag
        if ($tag.EndsWith(':str')) { return $text }
        if ([string]$node.Style -ne 'Plain' -and $tag -notmatch ':(int|float|bool|null)$') { return $text }
        return [TaskYaml]::ResolvePlain($text)
    }

    # Converts a node tree into case-sensitive ordered dictionaries, lists and typed scalars.
    static [object] Value([object] $node) {
        if ($null -eq $node) { return $null }
        $type = [string]$node.NodeType
        if ($type -eq 'Mapping') {
            $result = [OrderedDictionary]::new()
            $map = [TaskYaml]::Map($node)
            foreach ($key in $map.get_Keys()) { $result[[string]$key] = [TaskYaml]::Value($map[$key]) }
            return $result
        }
        if ($type -eq 'Sequence') {
            $list = [List[object]]::new()
            foreach ($child in $node.Children) { $list.Add([TaskYaml]::Value($child)) }
            return $list
        }
        if ($type -eq 'Scalar') { return [TaskYaml]::Scalar($node) }
        return [string]$node
    }

    # Parses YAML text straight into values.
    static [object] Parse([string] $text) { return [TaskYaml]::Value([TaskYaml]::Load($text)) }
}
