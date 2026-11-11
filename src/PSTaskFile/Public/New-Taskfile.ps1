function New-Taskfile {
    <#
    .SYNOPSIS
        Creates a new Taskfile.
    .DESCRIPTION
        New-Taskfile is the `task --init` mode. It writes a small starter Taskfile whose
        commands are PowerShell and returns the created file.
    .PARAMETER Path
        The directory to create Taskfile.yml in, or the path of the file to create (a name
        ending in .yml or .yaml). Defaults to the current location.
    .PARAMETER Force
        Overwrites an existing file.
    .EXAMPLE
        New-Taskfile
    .EXAMPLE
        New-Taskfile -Path ./tools/Taskfile.build.yml
    .LINK
        Invoke-Task
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Position = 0)]
        [string]$Path = '.',

        [switch]$Force
    )

    $target = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if ($target -notmatch '\.ya?ml$') { $target = Join-Path $target 'Taskfile.yml' }

    if ((Test-Path -LiteralPath $target) -and -not $Force) {
        $result = @{ Ok = $false; Message = "task: A Taskfile already exists at `"$target`""; Code = 101; ExitStatus = $null; Exception = $null }
        Complete-TaskResult -Cmdlet $PSCmdlet -Result $result
    }

    $content = @'
# https://taskfile.dev
# Commands are PowerShell: run them with Invoke-Task (module PSTaskFile).

version: '3'

vars:
  GREETING: Hello, World!

tasks:
  default:
    cmds:
      - Write-Host "{{.GREETING}}"
    silent: true
'@
    if (-not $PSCmdlet.ShouldProcess($target, 'Create Taskfile')) { return }

    $parent = Split-Path -Parent $target
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent -Force }
    [System.IO.File]::WriteAllText($target, $content.Replace("`r`n", "`n") + "`n")
    $global:LASTEXITCODE = 0
    Get-Item -LiteralPath $target
}
