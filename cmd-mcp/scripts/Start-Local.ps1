[CmdletBinding()]
param([ValidateRange(1024, 65535)][int]$Port = 8765, [switch]$ShowToken)

$ErrorActionPreference = 'Stop'
$launcherDirectory = $PSScriptRoot
if (-not $launcherDirectory) { $launcherDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $launcherDirectory 'Common.ps1')
Initialize-PcMcpPaths $launcherDirectory
try {
    Enter-PcMcpLock
    Start-PcMcpLocal $Port | Out-Null
    Show-PcMcpConnection -IncludeToken:$ShowToken
}
catch { Write-Error $_; exit 1 }
finally { Exit-PcMcpLock }
