param([switch]$NonInteractive, [int]$TimeoutSeconds = 180, [string]$ConfigPath, [switch]$NoRecovery)
$taskArguments = @{} + $PSBoundParameters
$taskArguments['Server'] = 'Rojo'
& (Join-Path $PSScriptRoot 'Start-MCP.ps1') @taskArguments
exit $LASTEXITCODE
