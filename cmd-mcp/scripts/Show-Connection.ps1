[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$launcherDirectory = $PSScriptRoot
if (-not $launcherDirectory) { $launcherDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $launcherDirectory 'Common.ps1')
Initialize-PcMcpPaths $launcherDirectory
try { Show-PcMcpConnection -IncludeToken }
catch { Write-Error $_; exit 1 }
