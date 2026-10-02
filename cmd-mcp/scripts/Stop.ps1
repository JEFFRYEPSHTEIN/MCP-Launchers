[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$launcherDirectory = $PSScriptRoot
if (-not $launcherDirectory) { $launcherDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $launcherDirectory 'Common.ps1')
Initialize-PcMcpPaths $launcherDirectory
try {
    Enter-PcMcpLock
    $connection = Read-PcMcpConnection
    Stop-PcMcpServer $connection
    Stop-PcMcpTunnel $connection
    if (Test-Path -LiteralPath $script:PcMcpConnectionFile) { Remove-Item -LiteralPath $script:PcMcpConnectionFile }
    Write-Host '[OK] CMD MCP and its HTTPS tunnel are stopped.'
}
catch { Write-Error $_; exit 1 }
finally { Exit-PcMcpLock }
