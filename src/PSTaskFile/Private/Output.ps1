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
            $record = [InformationRecord]::new($message, 'PSTaskFile')
            $record.Tags.Add('PSHOST')
            $ctx.Sink.Add([DictionaryEntry]::new('i', $record))
            return
        }
        if ($useColor) { Write-Host $text -ForegroundColor $color } else { Write-Host $text }
    }

    static [void] Verbose([hashtable] $ctx, [string] $text) {
        if (-not $ctx.Options.Verbose) { return }
        if ($null -ne $ctx.Sink) { $ctx.Sink.Add([DictionaryEntry]::new('v', $text)); return }
        Write-Verbose -Message $text -Verbose
    }

    static [void] Error([hashtable] $ctx, [ErrorRecord] $record) {
        if ($null -ne $ctx.Sink) { $ctx.Sink.Add([DictionaryEntry]::new('e', $record)); return }
        $record | Out-Default
    }

    # Writes plain text lines (grouped / prefixed command output).
    static [void] Lines([hashtable] $ctx, [IEnumerable] $lines) {
        foreach ($line in $lines) {
            if ($null -ne $ctx.Sink) { $ctx.Sink.Add([DictionaryEntry]::new('o', [string]$line)) }
            else { $global:Host.UI.WriteLine([string]$line) }
        }
    }
}
