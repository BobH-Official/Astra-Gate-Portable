#Requires -Version 5.1
<#
.SYNOPSIS
Removes the optional astra:// protocol registration for Astra Gate Portable.

.DESCRIPTION
This is the reverse of scoop-register-protocol.ps1. It removes
HKCU\Software\Classes\astra after checking that the registration points at the app
directory, unless -Force is passed.

It does not touch ASTRA_HOME, autostart entries, user data, or NSIS install keys.

.PARAMETER AppDir
The Scoop application directory. Defaults to the directory containing this script.

.PARAMETER Force
Remove the registration even if it points at a different Astra installation.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scoop-unregister-protocol.ps1 -AppDir "$dir"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $AppDir = $PSScriptRoot,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
    throw 'This helper requires Windows.'
}

function Get-NormalizedPath([string] $Path) {
    $value = [IO.Path]::GetFullPath($Path.Trim().Trim('"'))
    return $value.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

if ([string]::IsNullOrWhiteSpace($AppDir)) {
    throw 'AppDir is required. Pass -AppDir <Scoop app directory>; the default is the script directory.'
}

$appDirPath = Get-NormalizedPath $AppDir
$exe = Join-Path $appDirPath 'Astra.exe'
$protocolKey = 'HKCU:\Software\Classes\astra'
$commandKey = Join-Path $protocolKey 'shell\open\command'

if (-not (Test-Path -LiteralPath $protocolKey)) {
    Write-Host 'astra:// is not registered.'
    return
}

if (Test-Path -LiteralPath $commandKey) {
    $existing = (Get-Item -LiteralPath $commandKey).GetValue('')
    if ($existing -and -not $Force -and
        $existing.IndexOf($exe, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        throw "astra:// points to another installation: $existing. Re-run with -Force to remove it."
    }
}

if ($PSCmdlet.ShouldProcess($protocolKey, 'Remove astra:// registration')) {
    Remove-Item -LiteralPath $protocolKey -Recurse -Force
    Write-Host 'Removed astra:// registration.'
}
