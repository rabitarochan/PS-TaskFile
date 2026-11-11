BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'PSTaskFile' 'PSTaskFile.psd1') -Force
    $module = Get-Module PSTaskFile
    $script:ExpandCommand = & $module { Get-Command Expand-TaskTemplate }
    $script:ResolveCommand = & $module { Get-Command Resolve-TaskTemplateValue }
    $script:ExpandValueCommand = & $module { Get-Command Expand-TaskTemplateValue }

    $env:PSTF_TEST_VAR = 'envval'

    function New-TestData {
        $map = [System.Collections.Specialized.OrderedDictionary]::new()
        $map['x'] = 1
        $map['y'] = 'two'
        $inner = [System.Collections.Specialized.OrderedDictionary]::new()
        $inner['value'] = 'deep'
        $nested = [System.Collections.Specialized.OrderedDictionary]::new()
        $nested['inner'] = $inner

        $data = [System.Collections.Specialized.OrderedDictionary]::new()
        $data['FOO'] = 'bar'
        $data['NUM'] = 42
        $data['ZERO'] = 0
        $data['FLOAT'] = 1.5
        $data['FLAG'] = $true
        $data['OFF'] = $false
        $data['EMPTY'] = ''
        $data['LIST'] = @('a', 'b', 'c')
        $data['LISTS'] = @(, @('a', 'b')) + @(, @('c', 'd'))
        $data['EMPTYLIST'] = @()
        $data['MAP'] = $map
        $data['NESTED'] = $nested
        $data['MULTI'] = "l1`nl2`r`nl3"
        $data
    }

    function Expand-T {
        param([string]$Template, $Data = (New-TestData))
        & $script:ExpandCommand -Template $Template -Data $Data
    }

    function Resolve-T {
        param([string]$Expression, $Data = (New-TestData))
        , (& $script:ResolveCommand -Expression $Expression -Data $Data)
    }
}

AfterAll {
    Remove-Item Env:PSTF_TEST_VAR -ErrorAction Ignore
}

Describe 'Expand-TaskTemplate' {
    Context 'text and fields' {
        It 'expands <Template>' -ForEach @(
            @{ Template = 'plain text'; Expected = 'plain text' }
            @{ Template = ''; Expected = '' }
            @{ Template = '{{.FOO}}'; Expected = 'bar' }
            @{ Template = '{{ .FOO }}-{{.NUM}}'; Expected = 'bar-42' }
            @{ Template = 'a{{.MISSING}}b'; Expected = 'ab' }
            @{ Template = '{{.FLAG}} {{.OFF}}'; Expected = 'true false' }
            @{ Template = '{{.LIST}}'; Expected = '[a b c]' }
            @{ Template = '{{.MAP}}'; Expected = 'map[x:1 y:two]' }
            @{ Template = '{{.NESTED.inner.value}}'; Expected = 'deep' }
            @{ Template = '{{.NESTED.missing}}'; Expected = '' }
            @{ Template = '{{.NESTED.missing.deeper}}'; Expected = '' }
            @{ Template = '{{.MISSING.x}}'; Expected = '' }
            @{ Template = '{{.FLOAT}}'; Expected = '1.5' }
            @{ Template = 'single } brace { and }} stay'; Expected = 'single } brace { and }} stay' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }

        It 'is case-sensitive for keys' {
            $data = [System.Collections.Specialized.OrderedDictionary]::new()
            $data['foo'] = 'lower'
            $data['FOO'] = 'upper'
            Expand-T '{{.foo}}/{{.FOO}}' $data | Should -BeExactly 'lower/upper'
        }
    }

    Context 'literals' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{"lit"}}'; Expected = 'lit' }
            @{ Template = '{{`raw\n`}}'; Expected = 'raw\n' }
            @{ Template = '{{"a\tb"}}'; Expected = "a`tb" }
            @{ Template = '{{"q\"q"}}'; Expected = 'q"q' }
            @{ Template = '{{42}}'; Expected = '42' }
            @{ Template = '{{-5}}'; Expected = '-5' }
            @{ Template = '{{1.5}}'; Expected = '1.5' }
            @{ Template = '{{0x10}}'; Expected = '16' }
            @{ Template = '{{1e3}}'; Expected = '1000' }
            @{ Template = '{{1000000.0}}'; Expected = '1e+06' }
            @{ Template = '{{1234567.0}}'; Expected = '1.234567e+06' }
            @{ Template = '{{123456.0}}'; Expected = '123456' }
            @{ Template = '{{0.000001}}'; Expected = '1e-06' }
            @{ Template = '{{0.0001}}'; Expected = '0.0001' }
            @{ Template = '{{1_000}}'; Expected = '1000' }
            @{ Template = '{{true}}'; Expected = 'true' }
            @{ Template = "{{'a'}}"; Expected = '97' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'whitespace trimming and comments' {
        It 'expands <Name>' -ForEach @(
            @{ Name = 'both trims'; Template = 'a  {{- .FOO -}}  b'; Expected = 'abarb' }
            @{ Name = 'left trim'; Template = 'a {{- .FOO }} b'; Expected = 'abar b' }
            @{ Name = 'right trim'; Template = 'a {{ .FOO -}} b'; Expected = 'a barb' }
            @{ Name = 'comment'; Template = 'x{{/* a comment */}}y'; Expected = 'xy' }
            @{ Name = 'trimmed comment'; Template = "x`n  {{- /* c */ -}}`n  y"; Expected = 'xy' }
            @{ Name = 'negative number is not a trim marker'; Template = '{{-5}}'; Expected = '-5' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'pipelines' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{.FOO | upper}}'; Expected = 'BAR' }
            @{ Template = '{{.FOO | upper | lower}}'; Expected = 'bar' }
            @{ Template = '{{.FOO | printf "%s-%s" "a"}}'; Expected = 'a-bar' }
            @{ Template = '{{printf "%d items" .NUM}}'; Expected = '42 items' }
            @{ Template = '{{.EMPTY | default "dflt"}}'; Expected = 'dflt' }
            @{ Template = '{{.MISSING | default "dflt"}}'; Expected = 'dflt' }
            @{ Template = '{{default "d" .FOO}}'; Expected = 'bar' }
            @{ Template = '{{(index .LIST 1) | upper}}'; Expected = 'B' }
            @{ Template = '{{index .MAP "y"}}'; Expected = 'two' }
            @{ Template = '{{index .LISTS 1 0}}'; Expected = 'c' }
            @{ Template = '{{len .LIST}}'; Expected = '3' }
            @{ Template = '{{len .FOO}}'; Expected = '3' }
            @{ Template = '{{len .MAP}}'; Expected = '2' }
            @{ Template = '{{.LIST | len}}'; Expected = '3' }
            @{ Template = '{{(dict "a" (dict "b" "c")).a.b}}'; Expected = 'c' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'control structures' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{if .FLAG}}yes{{else}}no{{end}}'; Expected = 'yes' }
            @{ Template = '{{if .OFF}}yes{{else}}no{{end}}'; Expected = 'no' }
            @{ Template = '{{if .MISSING}}y{{else if .FOO}}elif{{else}}n{{end}}'; Expected = 'elif' }
            @{ Template = '{{if eq .FOO "bar"}}eq{{end}}'; Expected = 'eq' }
            @{ Template = '{{if ne .FOO "bar"}}ne{{else}}same{{end}}'; Expected = 'same' }
            @{ Template = '{{if and .FLAG (not .OFF)}}both{{end}}'; Expected = 'both' }
            @{ Template = '{{if or .OFF .EMPTY}}y{{else}}n{{end}}'; Expected = 'n' }
            @{ Template = '{{or .EMPTY "fallback"}}'; Expected = 'fallback' }
            @{ Template = '{{and .FOO .NUM}}'; Expected = '42' }
            @{ Template = '{{if eq .NUM 42}}n{{end}}'; Expected = 'n' }
            @{ Template = '{{if eq .FOO "x" "bar"}}any{{end}}'; Expected = 'any' }
            @{ Template = '{{if lt .NUM 100}}lt{{end}}'; Expected = 'lt' }
            @{ Template = '{{if ge .NUM 42}}ge{{end}}'; Expected = 'ge' }
            @{ Template = '{{if gt "b" "a"}}gt{{end}}'; Expected = 'gt' }
            @{ Template = '{{if le 1.5 2.5}}le{{end}}'; Expected = 'le' }
            @{ Template = '{{if .EMPTY}}y{{else}}empty{{end}}'; Expected = 'empty' }
            @{ Template = '{{if .ZERO}}y{{else}}zero{{end}}'; Expected = 'zero' }
            @{ Template = '{{if .EMPTYLIST}}y{{else}}nolist{{end}}'; Expected = 'nolist' }
            @{ Template = '{{range .LIST}}{{.}},{{end}}'; Expected = 'a,b,c,' }
            @{ Template = '{{range $i, $e := .LIST}}{{$i}}={{$e}};{{end}}'; Expected = '0=a;1=b;2=c;' }
            @{ Template = '{{range $e := .LIST}}{{$e}}{{end}}'; Expected = 'abc' }
            @{ Template = '{{range $k, $v := .MAP}}{{$k}}={{$v}};{{end}}'; Expected = 'x=1;y=two;' }
            @{ Template = '{{range .NOLIST}}x{{else}}empty{{end}}'; Expected = 'empty' }
            @{ Template = '{{range .LIST}}{{if eq . "b"}}{{continue}}{{end}}{{.}}{{end}}'; Expected = 'ac' }
            @{ Template = '{{range .LIST}}{{if eq . "b"}}{{break}}{{end}}{{.}}{{end}}'; Expected = 'a' }
            @{ Template = '{{range 3}}{{.}}{{end}}'; Expected = '012' }
            @{ Template = '{{range $i, $e := .LIST}}{{if $i}},{{end}}{{$e}}{{end}}'; Expected = 'a,b,c' }
            @{ Template = '{{with .FOO}}[{{.}}]{{end}}'; Expected = '[bar]' }
            @{ Template = '{{with .MISSING}}x{{else}}none{{end}}'; Expected = 'none' }
            @{ Template = '{{$x := "v"}}{{$x}}'; Expected = 'v' }
            @{ Template = '{{$x := 1}}{{$x = 2}}{{$x}}'; Expected = '2' }
            @{ Template = '{{$x := 1}}{{if true}}{{$x = 5}}{{end}}{{$x}}'; Expected = '5' }
            @{ Template = '{{$.FOO}}'; Expected = 'bar' }
            @{ Template = '{{with .MAP}}{{$.FOO}}{{.y}}{{end}}'; Expected = 'bartwo' }
            @{ Template = '{{range .LIST}}{{with $.FOO}}{{.}}{{end}}{{end}}'; Expected = 'barbarbar' }
            @{ Template = '{{define "T"}}hi {{.}}{{end}}{{template "T" .FOO}}'; Expected = 'hi bar' }
            @{ Template = '{{block "B" .FOO}}[{{.}}]{{end}}'; Expected = '[bar]' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'printf / print' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{printf "%5d|" .NUM}}'; Expected = '   42|' }
            @{ Template = '{{printf "%-5d|" .NUM}}'; Expected = '42   |' }
            @{ Template = '{{printf "%05d" .NUM}}'; Expected = '00042' }
            @{ Template = '{{printf "%.2f" 3.14159}}'; Expected = '3.14' }
            @{ Template = '{{printf "%q" .FOO}}'; Expected = '"bar"' }
            @{ Template = '{{printf "%v %v" .FOO .NUM}}'; Expected = 'bar 42' }
            @{ Template = '{{printf "%t" .FLAG}}'; Expected = 'true' }
            @{ Template = '{{printf "%x" 255}}'; Expected = 'ff' }
            @{ Template = '{{printf "%X" 255}}'; Expected = 'FF' }
            @{ Template = '{{printf "100%%"}}'; Expected = '100%' }
            @{ Template = '{{printf "%s" .LIST}}'; Expected = '[a b c]' }
            @{ Template = '{{printf "%10s|" .FOO}}'; Expected = '       bar|' }
            @{ Template = '{{printf "%-10s|" .FOO}}'; Expected = 'bar       |' }
            @{ Template = '{{printf "%T" .FOO}}'; Expected = 'string' }
            @{ Template = '{{printf "%c" 65}}'; Expected = 'A' }
            @{ Template = '{{printf "%+d" 5}}'; Expected = '+5' }
            @{ Template = '{{printf "%e" 1234.5678}}'; Expected = '1.234568e+03' }
            @{ Template = '{{printf "%s=%d" "n" 7}}'; Expected = 'n=7' }
            @{ Template = '{{print "a" 1 "b"}}'; Expected = 'a1b' }
            @{ Template = '{{print 1 2}}'; Expected = '1 2' }
            @{ Template = '{{printf "%v" nil}}'; Expected = '<nil>' }
            @{ Template = '{{.MISSING | printf "%s"}}'; Expected = '%!s(<nil>)' }
            @{ Template = '{{printf "%s %s" "a"}}'; Expected = 'a %!s(MISSING)' }
            @{ Template = '{{printf "%s" "a" "b"}}'; Expected = 'a%!(EXTRA string=b)' }
            @{ Template = '{{println "a" 1}}'; Expected = "a 1`n" }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'string functions' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{trim "  x  "}}'; Expected = 'x' }
            @{ Template = '{{trimAll "$" "$5.00$"}}'; Expected = '5.00' }
            @{ Template = '{{trimPrefix "foo" "foobar"}}'; Expected = 'bar' }
            @{ Template = '{{trimSuffix "bar" "foobar"}}'; Expected = 'foo' }
            @{ Template = '{{upper "abc"}}{{lower "ABC"}}'; Expected = 'ABCabc' }
            @{ Template = '{{title "hello world"}}'; Expected = 'Hello World' }
            @{ Template = '{{repeat 3 "ab"}}'; Expected = 'ababab' }
            @{ Template = '{{substr 0 3 "abcdef"}}'; Expected = 'abc' }
            @{ Template = '{{substr 2 -1 "abcdef"}}'; Expected = 'cdef' }
            @{ Template = '{{trunc 3 "abcdef"}}'; Expected = 'abc' }
            @{ Template = '{{trunc -3 "abcdef"}}'; Expected = 'def' }
            @{ Template = '{{contains "b" "abc"}}'; Expected = 'true' }
            @{ Template = '{{"abc" | contains "x"}}'; Expected = 'false' }
            @{ Template = '{{hasPrefix "ab" "abc"}}{{hasSuffix "bc" "abc"}}'; Expected = 'truetrue' }
            @{ Template = '{{quote "a" "b"}}'; Expected = '"a" "b"' }
            @{ Template = '{{squote "a"}}'; Expected = "'a'" }
            @{ Template = '{{cat "a" "b" 1}}'; Expected = 'a b 1' }
            @{ Template = '{{indent 2 "a\nb"}}'; Expected = "  a`n  b" }
            @{ Template = '{{nindent 2 "a"}}'; Expected = "`n  a" }
            @{ Template = '{{replace "a" "b" "banana"}}'; Expected = 'bbnbnb' }
            @{ Template = '{{plural "one" "many" 1}}/{{plural "one" "many" 2}}'; Expected = 'one/many' }
            @{ Template = '{{sha256sum "abc"}}'; Expected = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad' }
            @{ Template = '{{sha1sum "abc"}}'; Expected = 'a9993e364706816aba3e25717850c26c9cd0d89d' }
            @{ Template = '{{adler32sum "abc"}}'; Expected = '38600999' }
            @{ Template = '{{b64enc "hello"}}'; Expected = 'aGVsbG8=' }
            @{ Template = '{{b64dec "aGVsbG8="}}'; Expected = 'hello' }
            @{ Template = '{{b32enc "hello"}}'; Expected = 'NBSWY3DP' }
            @{ Template = '{{b32dec "NBSWY3DP"}}'; Expected = 'hello' }
            @{ Template = '{{toString 42}}'; Expected = '42' }
            @{ Template = '{{"a,b,c" | splitList ","}}'; Expected = '[a b c]' }
            @{ Template = '{{split "," "a,b"}}'; Expected = 'map[_0:a _1:b]' }
            @{ Template = '{{(split "," "a,b")._1}}'; Expected = 'b' }
            @{ Template = '{{splitn "," 2 "a,b,c"}}'; Expected = 'map[_0:a _1:b,c]' }
            @{ Template = '{{join "-" .LIST}}'; Expected = 'a-b-c' }
            @{ Template = '{{list "c" "a" "b" | sortAlpha}}'; Expected = '[a b c]' }
            @{ Template = '{{toStrings (list 1 2)}}'; Expected = '[1 2]' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'math functions' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{add 1 2 3}}'; Expected = '6' }
            @{ Template = '{{sub 5 2}}'; Expected = '3' }
            @{ Template = '{{mul 2 3 4}}'; Expected = '24' }
            @{ Template = '{{div 7 2}}'; Expected = '3' }
            @{ Template = '{{mod 7 2}}'; Expected = '1' }
            @{ Template = '{{add1 5}}'; Expected = '6' }
            @{ Template = '{{max 1 5 3}}'; Expected = '5' }
            @{ Template = '{{min 4 2 8}}'; Expected = '2' }
            @{ Template = '{{atoi "42" | add 1}}'; Expected = '43' }
            @{ Template = '{{int "7"}}'; Expected = '7' }
            @{ Template = '{{int "0x10"}}{{int " 5 "}}{{int "5.0"}}{{int true}}'; Expected = '0001' }
            @{ Template = '{{int64 3.9}}'; Expected = '3' }
            @{ Template = '{{float64 "1.5"}}'; Expected = '1.5' }
            @{ Template = '{{ceil 1.2}}'; Expected = '2' }
            @{ Template = '{{floor 1.8}}'; Expected = '1' }
            @{ Template = '{{round 3.14159 2}}'; Expected = '3.14' }
            @{ Template = '{{maxf 1.5 2.5}}'; Expected = '2.5' }
            @{ Template = '{{minf 1.5 2.5}}'; Expected = '1.5' }
            @{ Template = '{{seq 3}}'; Expected = '1 2 3' }
            @{ Template = '{{seq 0 2}}'; Expected = '0 1 2' }
            @{ Template = '{{seq 2 2 6}}'; Expected = '2 4 6' }
            @{ Template = '{{until 3}}'; Expected = '[0 1 2]' }
            @{ Template = '{{untilStep 0 10 5}}'; Expected = '[0 5]' }
            @{ Template = '{{toDecimal "777"}}'; Expected = '511' }
            @{ Template = '{{randInt 1 2}}'; Expected = '1' }
            @{ Template = '{{randIntN 1}}'; Expected = '0' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'list and dict functions' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{list 1 2 3}}'; Expected = '[1 2 3]' }
            @{ Template = '{{dict "a" 1 "b" 2}}'; Expected = 'map[a:1 b:2]' }
            @{ Template = '{{get (dict "a" 1) "a"}}'; Expected = '1' }
            @{ Template = '{{get (dict "a" 1) "zz"}}'; Expected = '' }
            @{ Template = '{{$d := dict "a" 1}}{{$_ := set $d "b" 2}}{{$d}}'; Expected = 'map[a:1 b:2]' }
            @{ Template = '{{$d := dict "a" 1 "b" 2}}{{$_ := unset $d "a"}}{{$d}}'; Expected = 'map[b:2]' }
            @{ Template = '{{hasKey (dict "a" 1) "a"}}{{hasKey (dict "a" 1) "b"}}'; Expected = 'truefalse' }
            @{ Template = '{{keys (dict "b" 1 "a" 2) | sortAlpha}}'; Expected = '[a b]' }
            @{ Template = '{{values (dict "a" 1)}}'; Expected = '[1]' }
            @{ Template = '{{pick (dict "a" 1 "b" 2 "c" 3) "a" "c"}}'; Expected = 'map[a:1 c:3]' }
            @{ Template = '{{omit (dict "a" 1 "b" 2) "a"}}'; Expected = 'map[b:2]' }
            @{ Template = '{{pluck "a" (dict "a" 1) (dict "a" 2)}}'; Expected = '[1 2]' }
            @{ Template = '{{first .LIST}}{{last .LIST}}'; Expected = 'ac' }
            @{ Template = '{{rest .LIST}}'; Expected = '[b c]' }
            @{ Template = '{{initial .LIST}}'; Expected = '[a b]' }
            @{ Template = '{{reverse .LIST}}'; Expected = '[c b a]' }
            @{ Template = '{{uniq (list 1 1 2)}}'; Expected = '[1 2]' }
            @{ Template = '{{without .LIST "b"}}'; Expected = '[a c]' }
            @{ Template = '{{has "b" .LIST}}{{has "z" .LIST}}'; Expected = 'truefalse' }
            @{ Template = '{{append .LIST "d"}}'; Expected = '[a b c d]' }
            @{ Template = '{{prepend .LIST "z"}}'; Expected = '[z a b c]' }
            @{ Template = '{{concat .LIST (list 1)}}'; Expected = '[a b c 1]' }
            @{ Template = '{{compact (list "a" "" "b")}}'; Expected = '[a b]' }
            @{ Template = '{{slice .LIST 1}}'; Expected = '[b c]' }
            @{ Template = '{{slice .LIST 0 2}}'; Expected = '[a b]' }
            @{ Template = '{{chunk 2 .LIST}}'; Expected = '[[a b] [c]]' }
            @{ Template = '{{dig "inner" "value" "dflt" .NESTED}}'; Expected = 'deep' }
            @{ Template = '{{dig "nope" "value" "dflt" .NESTED}}'; Expected = 'dflt' }
            @{ Template = '{{merge (dict "a" 1) (dict "b" 2)}}'; Expected = 'map[a:1 b:2]' }
            @{ Template = '{{append .LIST "d" | len}}/{{len .LIST}}'; Expected = '4/3' }
            @{ Template = '{{index (list "abc") 0}}'; Expected = 'abc' }
            @{ Template = '{{with (list "solo")}}{{len .}}:{{index . 0}}{{end}}'; Expected = '1:solo' }
            @{ Template = '{{dict "k" (list 1) | toJson}}'; Expected = '{"k":[1]}' }
            @{ Template = '{{or (list) (list "x") | len}}'; Expected = '1' }
            @{ Template = '{{define "T"}}{{len .}}{{end}}{{template "T" (list "x")}}'; Expected = '1' }
            @{ Template = '{{regexSplit "," "abc" -1 | len}}'; Expected = '1' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'logic, type and encoding functions' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{ternary "y" "n" true}}'; Expected = 'y' }
            @{ Template = '{{false | ternary "y" "n"}}'; Expected = 'n' }
            @{ Template = '{{empty ""}}{{empty "x"}}'; Expected = 'truefalse' }
            @{ Template = '{{coalesce "" 0 "x"}}'; Expected = 'x' }
            @{ Template = '{{all 1 "a"}}{{any "" 0}}'; Expected = 'truefalse' }
            @{ Template = '{{not true}}'; Expected = 'false' }
            @{ Template = '{{toJson (dict "a" 1 "b" (list "x" true))}}'; Expected = '{"a":1,"b":["x",true]}' }
            @{ Template = '{{toJson "<a>"}}'; Expected = '"' + '\' + 'u003ca' + '\' + 'u003e"' }
            @{ Template = '{{toRawJson "<a>"}}'; Expected = '"<a>"' }
            @{ Template = '{{toPrettyJson (dict "a" 1)}}'; Expected = "{`n  `"a`": 1`n}" }
            @{ Template = '{{(fromJson "{\"a\":[1,2]}").a}}'; Expected = '[1 2]' }
            @{ Template = '{{index (fromJson "{\"a\":[1,2]}").a 1}}'; Expected = '2' }
            @{ Template = '{{typeOf "x"}}/{{typeOf 1}}/{{typeOf 1.5}}/{{typeOf true}}'; Expected = 'string/int/float64/bool' }
            @{ Template = '{{typeOf (add 1 2)}}/{{kindOf (int64 1)}}/{{typeOf (len "a")}}'; Expected = 'int64/int64/int' }
            @{ Template = '{{typeOf (fromJson "1")}}'; Expected = 'float64' }
            @{ Template = '{{fromJson "{\"n\":10000000000}" | toJson}}'; Expected = '{"n":10000000000}' }
            @{ Template = '{{.MISSING | toString}}'; Expected = '<nil>' }
            @{ Template = '{{deepEqual 1 1.0}}{{eq 3 (add 1 2)}}'; Expected = 'falsetrue' }
            @{ Template = '{{kindOf (list)}}/{{kindOf (dict)}}/{{kindOf "s"}}'; Expected = 'slice/map/string' }
            @{ Template = '{{kindIs "string" "x"}}{{typeIs "int" 1}}'; Expected = 'truetrue' }
            @{ Template = '{{deepEqual (list 1 2) (list 1 2)}}{{deepEqual (list 1) (list 2)}}'; Expected = 'truefalse' }
            @{ Template = '{{toYaml (dict "a" 1)}}'; Expected = "a: 1`n" }
            @{ Template = '{{(fromYaml "a: 1\nb: [x, y]").b}}'; Expected = '[x y]' }
            @{ Template = '{{env "PSTF_TEST_VAR"}}'; Expected = 'envval' }
            @{ Template = '{{expandenv "$PSTF_TEST_VAR/x"}}'; Expected = 'envval/x' }
            @{ Template = '{{expandenv "${PSTF_TEST_VAR}y"}}'; Expected = 'envvaly' }
            @{ Template = '{{html "<a & b>"}}'; Expected = '&lt;a &amp; b&gt;' }
            @{ Template = '{{js "it''s <b>"}}'; Expected = 'it\''s \' + 'u003Cb\' + 'u003E' }
            @{ Template = '{{urlquery "a b&c"}}'; Expected = 'a+b%26c' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'path and regex functions' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{base "a/b/c.txt"}}'; Expected = 'c.txt' }
            @{ Template = '{{dir "a/b/c.txt"}}'; Expected = 'a/b' }
            @{ Template = '{{ext "a/b/c.txt"}}'; Expected = '.txt' }
            @{ Template = '{{clean "a//b/../c"}}'; Expected = 'a/c' }
            @{ Template = '{{isAbs "/a"}}{{isAbs "a"}}'; Expected = 'truefalse' }
            @{ Template = '{{base ""}}{{dir "file"}}'; Expected = '..' }
            @{ Template = '{{osBase "a/b/c.txt"}}'; Expected = 'c.txt' }
            @{ Template = '{{regexMatch "^b" "bar"}}'; Expected = 'true' }
            @{ Template = '{{regexFind "a." "bar"}}'; Expected = 'ar' }
            @{ Template = '{{regexFindAll "a" "banana" -1}}'; Expected = '[a a a]' }
            @{ Template = '{{regexFindAll "a" "banana" 2}}'; Expected = '[a a]' }
            @{ Template = '{{regexReplaceAll "a(n)" "banana" "<${1}>"}}'; Expected = 'b<n><n>a' }
            @{ Template = '{{regexReplaceAllLiteral "a" "banana" "$1"}}'; Expected = 'b$1n$1n$1' }
            @{ Template = '{{regexSplit "," "a,b,c" -1}}'; Expected = '[a b c]' }
            @{ Template = '{{regexQuoteMeta "1.2"}}'; Expected = '1\.2' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }
    }

    Context 'Task-specific functions' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{OS}}'; Expected = $(if ($IsWindows) { 'windows' } elseif ($IsMacOS) { 'darwin' } else { 'linux' }) }
            @{ Template = '{{exeExt}}'; Expected = $(if ($IsWindows) { '.exe' } else { '' }) }
            @{ Template = '{{catLines "a\nb\r\nc"}}'; Expected = 'a b c' }
            @{ Template = '{{splitLines "a\nb\r\nc"}}'; Expected = '[a b c]' }
            @{ Template = '{{.MULTI | splitLines | len}}'; Expected = '3' }
            @{ Template = '{{toSlash "a\\b"}}'; Expected = $(if ($IsWindows) { 'a/b' } else { 'a\b' }) }
            @{ Template = '{{fromSlash "a/b"}}'; Expected = "a$([System.IO.Path]::DirectorySeparatorChar)b" }
            @{ Template = '{{joinPath "a" "b" "c"}}'; Expected = "a$([System.IO.Path]::DirectorySeparatorChar)b$([System.IO.Path]::DirectorySeparatorChar)c" }
            @{ Template = '{{relPath "/a" "/a/b/c"}}'; Expected = "b$([System.IO.Path]::DirectorySeparatorChar)c" }
            @{ Template = '{{shellQuote "it''s"}}'; Expected = "'it''s'" }
            @{ Template = '{{q "a b"}}'; Expected = "'a b'" }
            @{ Template = '{{splitArgs "a \"b c\" d"}}'; Expected = '[a b c d]' }
            @{ Template = '{{len (splitArgs "a \"b c\" d")}}'; Expected = '3' }
            @{ Template = '{{uuid | toString | len}}'; Expected = '36' }
            @{ Template = '{{if gt numCPU 0}}ok{{end}}'; Expected = 'ok' }
            @{ Template = '{{IsSH}}'; Expected = 'false' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }

        It 'reports ARCH as a Go architecture name' {
            Expand-T '{{ARCH}}' | Should -BeIn @('amd64', 'arm64', '386', 'arm')
        }
    }

    Context 'date functions' {
        It 'expands <Template>' -ForEach @(
            @{ Template = '{{toDate "2006-01-02" "2024-03-05" | date "02/01/2006"}}'; Expected = '05/03/2024' }
            @{ Template = '{{date "2006-01-02 15:04:05" (toDate "2006-01-02T15:04:05" "2024-03-05T13:14:15")}}'; Expected = '2024-03-05 13:14:15' }
            @{ Template = '{{htmlDate (toDate "2006-01-02" "2024-03-05")}}'; Expected = '2024-03-05' }
            @{ Template = '{{toDate "2006-01-02" "2024-03-05" | date "Jan 2, 2006 Mon"}}'; Expected = 'Mar 5, 2024 Tue' }
            @{ Template = '{{toDate "2006-01-02 15:04" "2024-03-05 13:07" | date "3:04PM"}}'; Expected = '1:07PM' }
            @{ Template = '{{duration "3661"}}'; Expected = '1h1m1s' }
            @{ Template = '{{(toDate "2006-01-02" "2024-03-05").Year}}'; Expected = '2024' }
        ) {
            Expand-T $Template | Should -BeExactly $Expected
        }

        It 'formats the current time' {
            Expand-T '{{now | date "2006"}}' | Should -BeExactly ([datetime]::Now.Year.ToString())
            Expand-T '{{now.Format "2006"}}' | Should -BeExactly ([datetime]::Now.Year.ToString())
        }
    }

    Context 'errors' {
        It 'throws for <Template>' -ForEach @(
            @{ Template = '{{.FOO'; Pattern = 'unclosed action' }
            @{ Template = '{{nofunc 1}}'; Pattern = 'function "nofunc" not defined' }
            @{ Template = '{{.FOO.x}}'; Pattern = "can't evaluate field x" }
            @{ Template = '{{fail "boom"}}'; Pattern = 'boom' }
            @{ Template = '{{if .FOO}}x'; Pattern = 'unexpected EOF' }
            @{ Template = '{{end}}'; Pattern = 'unexpected \{\{end\}\}' }
            @{ Template = '{{index .LIST 10}}'; Pattern = 'index out of range' }
            @{ Template = '{{div 1 0}}'; Pattern = 'divide by zero' }
            @{ Template = '{{eq 1 "1"}}'; Pattern = 'incompatible types for comparison' }
            @{ Template = '{{"a" "b"}}'; Pattern = "can't give argument to non-function" }
            @{ Template = '{{$undefined}}'; Pattern = 'undefined variable' }
        ) {
            { Expand-T $Template } | Should -Throw -ExpectedMessage "*template:*"
            $message = try { Expand-T $Template } catch { $_.Exception.Message }
            $message | Should -Match $Pattern
        }
    }
}

Describe 'Resolve-TaskTemplateValue' {
    It 'returns typed values' {
        $list = Resolve-T '.LIST'
        $list.Count | Should -Be 3
        $list[1] | Should -BeExactly 'b'

        (Resolve-T '.MAP') -is [System.Collections.IDictionary] | Should -BeTrue
        Resolve-T 'index .LIST 0' | Should -BeExactly 'a'
        Resolve-T '.NUM' | Should -Be 42
        (Resolve-T '.NUM') -is [string] | Should -BeFalse
        Resolve-T '.FLAG' | Should -BeTrue
        Resolve-T '.MISSING' | Should -BeNullOrEmpty
    }

    It 'returns the whole data for "."' {
        $data = New-TestData
        $resolved = Resolve-T '.' $data
        [object]::ReferenceEquals($resolved, $data) | Should -BeTrue
    }

    It 'evaluates function calls' {
        $dict = Resolve-T 'dict "a" .NUM'
        $dict['a'] | Should -Be 42
    }
}

Describe 'Expand-TaskTemplateValue' {
    It 'expands strings nested in lists and maps and keeps other types' {
        $map = [System.Collections.Specialized.OrderedDictionary]::new()
        $map['s'] = '{{.FOO}}'
        $map['n'] = 5
        $map['l'] = @('{{.NUM}}', $true)
        $result = & $script:ExpandValueCommand -Value $map -Data (New-TestData)
        $result['s'] | Should -BeExactly 'bar'
        $result['n'] | Should -Be 5
        $result['l'][0] | Should -BeExactly '42'
        $result['l'][1] | Should -BeTrue
        $map['s'] | Should -BeExactly '{{.FOO}}'
    }

    It 'returns non-template values unchanged' {
        & $script:ExpandValueCommand -Value 12 -Data (New-TestData) | Should -Be 12
        & $script:ExpandValueCommand -Value $null -Data (New-TestData) | Should -BeNullOrEmpty
    }
}
