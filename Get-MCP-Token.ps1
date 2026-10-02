#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)][Alias('FullPath')][string]$Path,
    [ValidateSet('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo')][string]$Server,
    [string]$MappingPath,
    [switch]$Header,
    [switch]$Show,
    [switch]$DefineOnly
)

$ErrorActionPreference = 'Stop'
# Initialize after param: Windows PowerShell -File may not yet have PSScriptRoot
# when evaluating parameter defaults.
if ([string]::IsNullOrWhiteSpace($MappingPath)) {
    $MappingPath = Join-Path $PSScriptRoot '.runtime\servers.json'
}

function Test-McpTokenAbsolutePath {
    param([string]$Value)
    return (-not [string]::IsNullOrWhiteSpace($Value)) -and
        ($Value -match '^[a-zA-Z]:[\\/]' -or $Value -match '^\\\\[^\\/]+[\\/][^\\/]+')
}

function Read-McpTokenMapping {
    param([Parameter(Mandatory = $true)][string]$MappingPath)
    try {
        $tokenParsedMapping = Get-Content -LiteralPath $MappingPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $tokenDefinitions = @($tokenParsedMapping)
    } catch {
        throw 'Cannot read the server map. Configure .runtime\servers.json or supply -MappingPath.'
    }
    if ($tokenDefinitions.Count -eq 0) { throw 'The server map is empty.' }
    $tokenSeenIds = @()
    foreach ($tokenDefinition in $tokenDefinitions) {
        if (-not $tokenDefinition -or $tokenDefinition.id -notin @('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo') -or
            $tokenDefinition.id -in $tokenSeenIds -or $tokenDefinition.projectDirectory -isnot [string] -or
            -not (Test-McpTokenAbsolutePath -Value $tokenDefinition.projectDirectory)) {
            throw 'The server map contains an invalid or duplicate server entry.'
        }
        $tokenSeenIds += $tokenDefinition.id
    }
    return $tokenDefinitions
}

function Resolve-McpTokenServer {
    param([string]$Path, [string]$Server, [Parameter(Mandatory = $true)][object[]]$Definitions)
    $tokenMatches = @()
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        # Also accept a quoted path pasted into the interactive prompt.
        $Path = $Path.Trim()
        if ($Path.Length -ge 2 -and (($Path.StartsWith('"') -and $Path.EndsWith('"')) -or
            ($Path.StartsWith("'") -and $Path.EndsWith("'")))) {
            $Path = $Path.Substring(1, $Path.Length - 2)
        }
        if (-not (Test-McpTokenAbsolutePath -Value $Path)) {
            throw 'Supply an absolute program or MCP folder path, or use -Server.'
        }
        try {
            $tokenResolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
            if ($tokenResolved.Provider.Name -ne 'FileSystem') { throw 'Invalid provider.' }
            $tokenFullPath = [IO.Path]::GetFullPath($tokenResolved.ProviderPath).TrimEnd('\', '/')
            $tokenItem = Get-Item -LiteralPath $tokenFullPath -ErrorAction Stop
        } catch {
            throw 'The supplied file or folder does not exist or cannot be read.'
        }

        $tokenFolderMatches = @($Definitions | Where-Object {
            $tokenRoot = [IO.Path]::GetFullPath($_.projectDirectory).TrimEnd('\', '/')
            $tokenFullPath.Equals($tokenRoot, [StringComparison]::OrdinalIgnoreCase) -or
                $tokenFullPath.StartsWith($tokenRoot + '\', [StringComparison]::OrdinalIgnoreCase)
        } | Sort-Object { ([IO.Path]::GetFullPath($_.projectDirectory)).TrimEnd('\', '/').Length } -Descending)
        if ($tokenFolderMatches.Count -gt 0) {
            $tokenLongest = ([IO.Path]::GetFullPath($tokenFolderMatches[0].projectDirectory)).TrimEnd('\', '/').Length
            $tokenMatches = @($tokenFolderMatches | Where-Object {
                ([IO.Path]::GetFullPath($_.projectDirectory)).TrimEnd('\', '/').Length -eq $tokenLongest
            })
        } elseif (-not $tokenItem.PSIsContainer) {
            $tokenNames = @{
                'blender.exe' = 'Blender'; 'robloxstudiobeta.exe' = 'Roblox-Studio'; 'rojo.exe' = 'Rojo'
                'filesystem.ps1' = 'Filesystem'; 'filesystem.cmd' = 'Filesystem'
                'blender.ps1' = 'Blender'; 'blender.cmd' = 'Blender'
                'roblox-studio.ps1' = 'Roblox-Studio'; 'roblox-studio.cmd' = 'Roblox-Studio'
                'rojo.ps1' = 'Rojo'; 'rojo.cmd' = 'Rojo'
            }
            $tokenId = $tokenNames[$tokenItem.Name.ToLowerInvariant()]
            if ($tokenId) { $tokenMatches = @($Definitions | Where-Object { $_.id -eq $tokenId }) }
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Server)) {
        $tokenSelected = @($Definitions | Where-Object { $_.id -eq $Server })
        if ($tokenSelected.Count -ne 1) { throw 'The selected MCP server is not uniquely configured.' }
        if ($tokenMatches.Count -gt 0 -and $Server -notin @($tokenMatches | ForEach-Object { $_.id })) {
            throw 'The path identifies a different MCP server than -Server. Check your selection.'
        }
        return $tokenSelected[0]
    }
    if ($tokenMatches.Count -gt 1) {
        throw 'The path matches multiple MCP servers. Use -Server to select the intended one.'
    }
    if ($tokenMatches.Count -ne 1) {
        throw 'Cannot identify one MCP for this path. Use its MCP folder or -Server Filesystem, Blender, Roblox-Studio or Rojo. Shared node.exe does not identify one server.'
    }
    return $tokenMatches[0]
}

function Read-McpBearerToken {
    param([Parameter(Mandatory = $true)]$Definition)
    try {
        $tokenConfigPath = Join-Path $Definition.projectDirectory '.runtime\config.json'
        $tokenConfig = Get-Content -LiteralPath $tokenConfigPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Cannot read this MCP private config. Configure/start the installed server first.'
    }
    if ($tokenConfig.token -isnot [string] -or [string]::IsNullOrWhiteSpace($tokenConfig.token) -or
        $tokenConfig.token -match '[\s\x00-\x1f\x7f]') {
        throw 'The MCP config has no valid Bearer token.'
    }
    return [string]$tokenConfig.token
}

function Copy-McpTokenValue {
    param([Parameter(Mandatory = $true)][string]$Value)
    try {
        Set-Clipboard -Value $Value -ErrorAction Stop
    } catch {
        throw 'Cannot access the clipboard. Add -Show to explicitly return the token instead.'
    }
}

function Invoke-McpTokenAccess {
    param([string]$Path, [string]$Server, [string]$MappingPath, [switch]$Header, [switch]$Show)
    $tokenDefinitions = @(Read-McpTokenMapping -MappingPath $MappingPath)
    $tokenDefinition = Resolve-McpTokenServer -Path $Path -Server $Server -Definitions $tokenDefinitions
    $tokenValue = Read-McpBearerToken -Definition $tokenDefinition
    if ($Header) { $tokenValue = 'Authorization: Bearer ' + $tokenValue }
    if ($Show) { Write-Output $tokenValue; return }
    Copy-McpTokenValue -Value $tokenValue
    $tokenDescription = if ($Header) { 'Authorization header' } else { 'Bearer token' }
    Write-Host ('[COPIED] ' + $tokenDefinition.id + ': ' + $tokenDescription + ' copied to the clipboard. Paste it into your MCP client.')
}

if ($DefineOnly) { return }
try {
    if ([string]::IsNullOrWhiteSpace($Path) -and [string]::IsNullOrWhiteSpace($Server)) {
        $Path = Read-Host 'Paste the full program or MCP folder path'
    }
    Invoke-McpTokenAccess -Path $Path -Server $Server -MappingPath $MappingPath -Header:$Header -Show:$Show
    $global:LASTEXITCODE = 0
} catch {
    # Do not expose raw JSON, credentials or upstream exception details.
    Write-Host ('[FAILED] ' + $_.Exception.Message)
    $global:LASTEXITCODE = 1
    exit 1
}
