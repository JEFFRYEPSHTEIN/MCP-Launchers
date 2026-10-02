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
    if (Test-PcMcpProcessIdentity (Get-PcMcpField $connection 'server_process')) {
        throw 'Stop the server with Stop.ps1 before rotating the token.'
    }
    Ensure-PcMcpBuild
    $entryPoint = Join-Path $script:PcMcpRoot 'dist\main.js'
    & $script:PcMcpNode $entryPoint rotate --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Token rotation failed.' }
    Write-Host '[OK] A new token has replaced the previous token.'
    Show-PcMcpConnection -IncludeToken
}
catch { Write-Error $_; exit 1 }
finally { Exit-PcMcpLock }
