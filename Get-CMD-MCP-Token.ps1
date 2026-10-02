#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$TokenFilePath,
    [switch]$Header,
    [switch]$Show
)

$ErrorActionPreference = 'Stop'
try {
    if ([string]::IsNullOrWhiteSpace($TokenFilePath)) {
        if (-not [string]::IsNullOrWhiteSpace($env:PC_MCP_DATA_DIR)) {
            $cmdTokenDirectory = $env:PC_MCP_DATA_DIR
        } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $cmdTokenDirectory = Join-Path $env:LOCALAPPDATA 'PcControlMcp'
        } else {
            throw 'Cannot locate the CMD MCP token store. Supply -TokenFilePath.'
        }
        $TokenFilePath = Join-Path $cmdTokenDirectory 'token.json'
    }
    try {
        $cmdTokenDocument = Get-Content -LiteralPath $TokenFilePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Cannot read the CMD MCP token store. Set up that server first or supply -TokenFilePath.'
    }
    if ($cmdTokenDocument -is [Array] -or
        $cmdTokenDocument.version -isnot [ValueType] -or $cmdTokenDocument.version -is [bool] -or
        $cmdTokenDocument.version -ne 1 -or $cmdTokenDocument.token -isnot [string] -or
        $cmdTokenDocument.token -cnotmatch '\A[A-Za-z0-9_-]{43}\z') {
        throw 'The CMD MCP token store must contain version 1 and a valid existing token.'
    }
    $cmdTokenValue = [string]$cmdTokenDocument.token
    if ($Header) { $cmdTokenValue = 'Authorization: Bearer ' + $cmdTokenValue }
    if ($Show) {
        Write-Output $cmdTokenValue
    } else {
        try {
            Set-Clipboard -Value $cmdTokenValue -ErrorAction Stop
        } catch {
            throw 'Cannot access the clipboard. Add -Show to explicitly return the token instead.'
        }
        $cmdTokenDescription = if ($Header) { 'Authorization header' } else { 'Bearer token' }
        Write-Host ('[COPIED] CMD MCP: ' + $cmdTokenDescription + ' copied to the clipboard. Paste it into your MCP client.')
    }
    $global:LASTEXITCODE = 0
} catch {
    # The private JSON contents and raw parser/clipboard errors are not printed.
    Write-Host ('[FAILED] ' + $_.Exception.Message)
    $global:LASTEXITCODE = 1
    exit 1
}
