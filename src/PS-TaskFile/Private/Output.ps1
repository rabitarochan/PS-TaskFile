using namespace System.Collections
using namespace System.Collections.Generic
using namespace System.Management.Automation

# Engine messages ("task: ...") and the routing of command output.
#
# Two destinations exist:
#   * host  - the default. Messages and command output are written straight to the host, like
#             a console application would do.
#   * sink  - used by -PassThru. Everything is queued and re-emitted by the calling cmdlet on
#             its own streams, so it can be captured, redirected and piped.
# Sink items are DictionaryEntry(kind, value):
#   'x' any record produced by a command (all streams merged)   'o' a text line
#   'i' an InformationRecord of the engine                      'v' a verbose message
#   'e' an ErrorRecord

[NoRunspaceAffinity()]
class TaskLog {
    static [void] Info([hashtable] $ctx, [string] $text, [string] $color) {
        $useColor = $ctx.Options.Color -and -not [string]::IsNullOrEmpty($color)
        if ($null -ne $ctx.Sink) {
            $message = [HostInformationMessage]::new()
            $message.Message = $text
            if ($useColor) { $message.ForegroundColor = [ConsoleColor]$color }
            $record = [InformationRecord]::new($message, 'PS-TaskFile')
            $record.Tags.Add('PSHOST')
            $ctx.Sink.Add([DictionaryEntry]::new('i', $record))
            return
        }
        # The lock keeps a message from landing in the middle of a line that a task writes in
        # several parts (the prefixed style).
        [System.Threading.Monitor]::Enter($ctx.OutputLock)
        try { if ($useColor) { Write-Host $text -ForegroundColor $color } else { Write-Host $text } }
        finally { [System.Threading.Monitor]::Exit($ctx.OutputLock) }
    }

    static [void] Verbose([hashtable] $ctx, [string] $text) {
        if (-not $ctx.Options.Verbose) { return }
        if ($null -ne $ctx.Sink) { $ctx.Sink.Add([DictionaryEntry]::new('v', $text)); return }
        [System.Threading.Monitor]::Enter($ctx.OutputLock)
        try { Write-Verbose -Message $text -Verbose }
        finally { [System.Threading.Monitor]::Exit($ctx.OutputLock) }
    }

    static [void] Error([hashtable] $ctx, [ErrorRecord] $record) {
        if ($null -ne $ctx.Sink) { $ctx.Sink.Add([DictionaryEntry]::new('e', $record)); return }
        [System.Threading.Monitor]::Enter($ctx.OutputLock)
        try { $record | Out-Default }
        finally { [System.Threading.Monitor]::Exit($ctx.OutputLock) }
    }

    # Writes plain text lines (grouped / prefixed command output).
    static [void] Lines([hashtable] $ctx, [IEnumerable] $lines) {
        foreach ($line in $lines) {
            if ($null -ne $ctx.Sink) { $ctx.Sink.Add([DictionaryEntry]::new('o', [string]$line)) }
            else { $global:Host.UI.WriteLine([string]$line) }
        }
    }
}

# The layout of the `prefixed` output style. Every line of a task starts with the prefix of
# the task, the prefixes are padded to the widest one seen so far, and on a terminal a line
# that does not fit continues below its own text:
#
#   [app]    | a line of the app task
#   [worker] | a line that is wider than the terminal continues
#            | here
#
# The state (@{ Lock; Seen; Width }) is shared by the whole run: $ctx.Prefixes. Width counts
# the cells of the widest prefix including its brackets.
[NoRunspaceAffinity()]
class TaskPrefix {
    # Colours of the prefixes, handed out in the order the prefixes appear.
    static [ConsoleColor[]] $Colors = @(
        'DarkCyan', 'DarkYellow', 'DarkGreen', 'DarkMagenta', 'DarkBlue', 'DarkRed',
        'Cyan', 'Yellow', 'Green', 'Magenta', 'Blue', 'Red'
    )

    # With less room than this for the text, wrapping would not make it more readable.
    static [int] $MinimumText = 20

    hidden static [string] $Esc = [string][char]27

    # CSI and OSC sequences and two-character escapes: they take no room on the screen.
    hidden static [regex] $Escape = [regex]::new('\G(?:\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[@-_])')

    # Anything but printable ASCII: text without it takes one cell per character.
    hidden static [regex] $NotPlain = [regex]::new('[^\x20-\x7E]')

    static [hashtable] NewState() {
        return @{ Lock = [object]::new(); Seen = [Dictionary[string, int]]::new([StringComparer]::Ordinal); Width = 0 }
    }

    # The cells of the text element at $index: 2 for East Asian wide characters and emoji,
    # 0 for control and combining characters.
    hidden static [int] ElementCells([string] $text, [int] $index) {
        $rune = [System.Text.Rune]::ReplacementChar
        if (-not [System.Text.Rune]::TryGetRuneAt($text, $index, [ref] $rune)) { return 1 }
        $code = $rune.Value
        if ($code -lt 0x20 -or ($code -ge 0x7F -and $code -lt 0xA0)) { return 0 }
        if ($code -lt 0x300) { return 1 }
        $category = [System.Text.Rune]::GetUnicodeCategory($rune)
        if ($category -eq [System.Globalization.UnicodeCategory]::NonSpacingMark -or
            $category -eq [System.Globalization.UnicodeCategory]::EnclosingMark -or
            $category -eq [System.Globalization.UnicodeCategory]::Format) { return 0 }
        if ($code -lt 0x1100) { return 1 }
        if ($code -le 0x115F -or $code -eq 0x2329 -or $code -eq 0x232A -or
            ($code -ge 0x2E80 -and $code -le 0xA4CF -and $code -ne 0x303F) -or
            ($code -ge 0xAC00 -and $code -le 0xD7A3) -or
            ($code -ge 0xF900 -and $code -le 0xFAFF) -or
            ($code -ge 0xFE10 -and $code -le 0xFE19) -or
            ($code -ge 0xFE30 -and $code -le 0xFE6F) -or
            ($code -ge 0xFF00 -and $code -le 0xFF60) -or
            ($code -ge 0xFFE0 -and $code -le 0xFFE6) -or
            ($code -ge 0x1F300 -and $code -le 0x1FAFF) -or
            ($code -ge 0x20000 -and $code -le 0x3FFFD)) { return 2 }
        return 1
    }

    # The number of cells $text takes on the screen. Escape sequences take none.
    static [int] Cells([string] $text) {
        if ([string]::IsNullOrEmpty($text)) { return 0 }
        if (-not [TaskPrefix]::NotPlain.IsMatch($text)) { return $text.Length }
        $total = 0
        $index = 0
        while ($index -lt $text.Length) {
            if ($text[$index] -eq [char]27) {
                $found = [TaskPrefix]::Escape.Match($text, $index)
                if ($found.Success) { $index += $found.Length; continue }
            }
            $total += [TaskPrefix]::ElementCells($text, $index)
            $index += [System.Globalization.StringInfo]::GetNextTextElementLength($text, $index)
        }
        return $total
    }

    # Splits $text into pieces of at most $cells cells. A colour that is active at a break is
    # closed there and opened again in the next piece, so that it does not run into the prefix
    # column. Tabs become blanks. A line with a carriage return (a progress display) stays as it is.
    static [string[]] Wrap([string] $text, [int] $cells) {
        if ($cells -lt 1 -or [string]::IsNullOrEmpty($text) -or $text.Contains("`r")) { return @($text) }
        $pieces = [List[string]]::new()
        if (-not [TaskPrefix]::NotPlain.IsMatch($text)) {
            for ($start = 0; $start -lt $text.Length; $start += $cells) {
                $pieces.Add($text.Substring($start, [Math]::Min($cells, $text.Length - $start)))
            }
            return $pieces.ToArray()
        }

        $piece = [System.Text.StringBuilder]::new()
        $active = [System.Text.StringBuilder]::new()    # the colour sequences since the last reset
        $used = 0
        $index = 0
        while ($index -lt $text.Length) {
            if ($text[$index] -eq [char]27) {
                $found = [TaskPrefix]::Escape.Match($text, $index)
                if ($found.Success) {
                    $sequence = $found.Value
                    [void]$piece.Append($sequence)
                    if ($sequence.Length -gt 2 -and $sequence[1] -eq '[' -and $sequence.EndsWith('m')) {
                        if ([regex]::IsMatch($sequence, '\[0*[;m]')) { [void]$active.Clear() }
                        if (-not [regex]::IsMatch($sequence, '\[0*m$')) { [void]$active.Append($sequence) }
                    }
                    $index += $found.Length
                    continue
                }
            }
            $length = [System.Globalization.StringInfo]::GetNextTextElementLength($text, $index)
            $element = $text.Substring($index, $length)
            $tab = $element -eq "`t"
            $width = 0
            if ($tab) { $width = 8 - ($used % 8) } else { $width = [TaskPrefix]::ElementCells($text, $index) }
            if ($used -gt 0 -and $used + $width -gt $cells) {
                if ($active.Length -gt 0) { [void]$piece.Append([TaskPrefix]::Esc + '[0m') }
                $pieces.Add($piece.ToString())
                [void]$piece.Clear().Append($active.ToString())
                $used = 0
                if ($tab) { $width = [Math]::Min(8, $cells) }
            }
            if ($tab) { $element = ' ' * $width }
            [void]$piece.Append($element)
            $used += $width
            $index += $length
        }
        $pieces.Add($piece.ToString())
        return $pieces.ToArray()
    }

    # Makes room for a prefix that is about to write. It gets its colour when it is registered.
    static [void] Reserve([hashtable] $state, [string] $prefix) {
        $cells = [TaskPrefix]::Cells($prefix) + 2
        [System.Threading.Monitor]::Enter($state.Lock)
        try { if ($cells -gt $state.Width) { $state.Width = $cells } }
        finally { [System.Threading.Monitor]::Exit($state.Lock) }
    }

    # Returns the number of the prefix - prefixes are numbered as they appear - and makes room for it.
    static [int] Register([hashtable] $state, [string] $prefix) {
        $cells = [TaskPrefix]::Cells($prefix) + 2
        $number = 0
        [System.Threading.Monitor]::Enter($state.Lock)
        try {
            if ($cells -gt $state.Width) { $state.Width = $cells }
            if (-not $state.Seen.TryGetValue($prefix, [ref] $number)) {
                $number = $state.Seen.Count
                $state.Seen[$prefix] = $number
            }
        }
        finally { [System.Threading.Monitor]::Exit($state.Lock) }
        return $number
    }

    static [ConsoleColor] Color([hashtable] $state, [string] $prefix) {
        $number = [TaskPrefix]::Register($state, $prefix)
        return [TaskPrefix]::Colors[$number % [TaskPrefix]::Colors.Length]
    }

    # The lines to write for one line of output of the task with $prefix; the first one starts
    # with "[$prefix]". $columns is the width of the terminal; 0 means the line is not wrapped.
    static [string[]] Format([hashtable] $state, [string] $prefix, [string] $line, [int] $columns) {
        $null = [TaskPrefix]::Register($state, $prefix)
        $width = [int]$state.Width
        $padding = [Math]::Max(0, $width - [TaskPrefix]::Cells($prefix) - 2)
        $head = '[' + $prefix + ']' + (' ' * $padding) + ' |'
        if ([string]::IsNullOrEmpty($line)) { return @($head) }

        # Next to the prefix column and its separator; the last column of the terminal stays free.
        $room = $columns - $width - 4
        if ($columns -lt 1 -or $room -lt [TaskPrefix]::MinimumText) { return @($head + ' ' + $line) }
        $pieces = [TaskPrefix]::Wrap($line, $room)
        $rest = (' ' * $width) + ' | '
        $lines = [List[string]]::new()
        $lines.Add($head + ' ' + $pieces[0])
        for ($i = 1; $i -lt $pieces.Length; $i++) { $lines.Add($rest + $pieces[$i]) }
        return $lines.ToArray()
    }

    # The index of the separator in a line that Format returned. Behind the prefix of a first
    # line and at the start of a continued one there are only blanks before it.
    static [int] Separator([string] $row, [string] $prefix, [bool] $first) {
        if ($first) { return $row.IndexOf('|', $prefix.Length + 2) }
        return $row.IndexOf('|')
    }
}

# Writes the output lines of one command in the `prefixed` style. One writer exists per
# command, in the runspace that runs it; TaskScript calls WriteLine for every line.
[NoRunspaceAffinity()]
class TaskLineWriter {
    hidden [hashtable] $State
    hidden [object] $Gate
    hidden [object] $Sink
    hidden [object] $UI
    hidden [string] $Prefix
    hidden [bool] $Terminal
    hidden [bool] $Colored
    hidden [ConsoleColor] $Tint
    hidden [ConsoleColor] $Background

    TaskLineWriter([hashtable] $ctx, [string] $name) {
        $this.State = $ctx.Prefixes
        $this.Gate = $ctx.OutputLock
        $this.Sink = $ctx.Sink
        $this.UI = $global:Host.UI
        $this.Prefix = $name
        $this.Tint = [TaskPrefix]::Color($this.State, $name)
        # Colours and wrapping are for people at a terminal, not for -PassThru or a log file.
        $this.Terminal = $null -eq $ctx.Sink -and -not [Console]::IsOutputRedirected
        $this.Colored = $false
        if ($this.Terminal -and $ctx.Options.Color) {
            try { $this.Background = $this.UI.RawUI.BackgroundColor; $this.Colored = $true } catch { }
        }
    }

    # Writes one line that Format returned: the prefix and the separator in the colour of the
    # task, the rest as it is. The colour is set through the host like Write-Host does it, not
    # with an escape sequence: while a native command runs, the Windows console does not
    # interpret escape sequences, and the sequence itself would show up on the screen.
    hidden [void] WriteColored([string] $row, [bool] $first) {
        $bar = [TaskPrefix]::Separator($row, $this.Prefix, $first)
        $start = 0
        if ($first) {
            $this.UI.Write('[')
            $this.UI.Write($this.Tint, $this.Background, $this.Prefix)
            $start = $this.Prefix.Length + 1
        }
        $this.UI.Write($row.Substring($start, $bar - $start))
        $this.UI.Write($this.Tint, $this.Background, '|')
        $this.UI.WriteLine($row.Substring($bar + 1))
    }

    # The width of the terminal; 0 when the output does not go to one.
    hidden [int] Columns() {
        if (-not $this.Terminal) { return 0 }
        try { return [int]$this.UI.RawUI.BufferSize.Width } catch { return 0 }
    }

    # The parameters of Out-String for the command: tables and lists are laid out for the room
    # next to the prefix column instead of the whole width of the terminal.
    [hashtable] FormatOptions() {
        $options = @{ Stream = $true }
        $room = $this.Columns() - [int]$this.State.Width - 4
        if ($room -ge [TaskPrefix]::MinimumText) { $options['Width'] = $room }
        return $options
    }

    # Writes one line of output. The lock keeps the parts of a line and the pieces of a wrapped
    # line together when tasks write at the same time.
    [void] WriteLine([string] $line) {
        [System.Threading.Monitor]::Enter($this.Gate)
        try {
            $first = $true
            foreach ($row in [TaskPrefix]::Format($this.State, $this.Prefix, $line, $this.Columns())) {
                if ($null -ne $this.Sink) { $this.Sink.Add([DictionaryEntry]::new('o', $row)) }
                elseif ($this.Colored) { $this.WriteColored($row, $first) }
                else { $this.UI.WriteLine($row) }
                $first = $false
            }
        }
        finally { [System.Threading.Monitor]::Exit($this.Gate) }
    }
}
