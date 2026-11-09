#Requires -Version 5.1
<#
.SYNOPSIS
Optional astra:// protocol registration for Astra Gate Portable.

.DESCRIPTION
Registers HKCU\Software\Classes\astra so join links can launch Astra.exe from this app
directory.

Run this manually from the Scoop Notes when you want the protocol; it is not run
automatically by the manifest. It does not touch ASTRA_HOME or autostart entries.
Use scoop-unregister-protocol.ps1 to undo it.

.PARAMETER AppDir
The Scoop application directory. Defaults to the directory containing this script.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\scoop-register-protocol.ps1 -AppDir "$dir"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $AppDir = $PSScriptRoot
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
$iconKey = Join-Path $protocolKey 'DefaultIcon'
$commandKey = Join-Path $protocolKey 'shell\open\command'

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Astra.exe not found in $appDirPath. Pass -AppDir <Scoop app directory>."
}

if ($PSCmdlet.ShouldProcess($protocolKey, "Register astra:// for $exe")) {
    New-Item -Path $protocolKey -Force | Out-Null
    Set-Item -Path $protocolKey -Value 'URL:Astra join link'
    New-ItemProperty -Path $protocolKey -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null

    New-Item -Path $iconKey -Force | Out-Null
    Set-Item -Path $iconKey -Value "$exe,0"

    New-Item -Path $commandKey -Force | Out-Null
    Set-Item -Path $commandKey -Value ('"' + $exe + '" "%1"')

    Write-Host "Registered astra:// for $exe"
}
