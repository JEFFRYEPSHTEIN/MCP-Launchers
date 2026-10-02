#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Help', 'Mcp', 'Build', 'Serve', 'Studio', 'Status')]
    [string]$Action = 'Help',
    [string]$PlaceFile,
    [string]$SettingsPath,
    [ValidateRange(1, 600)][int]$McpWaitSeconds = 180,
    [switch]$AllowRecovery
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($SettingsPath)) {
    $SettingsPath = Join-Path $PSScriptRoot '.runtime\arc-command-settings.json'
}
$arcAllowRecovery = [bool]$AllowRecovery
if ($Action -eq 'Help') {
    Write-Output 'Arc-Commands.ps1 Mcp     Configure the selected project/CLI and show the HTTPS MCP URL.'
    Write-Output 'Arc-Commands.ps1 Build   Build the selected project into a new unique artifact.'
    Write-Output 'Arc-Commands.ps1 Serve   Run direct local Rojo synchronization; Ctrl+C stops it.'
    Write-Output 'Arc-Commands.ps1 Studio  Open the configured Place or a file passed with -PlaceFile.'
    Write-Output 'Arc-Commands.ps1 Status  Show configuration, CLI version and app/listener status.'
    return
}

$arcSettings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
$arcRoot = (Resolve-Path -LiteralPath $arcSettings.projectRoot).Path
$arcRojo = (Resolve-Path -LiteralPath $arcSettings.rojoExecutable).Path
$arcManifest = Join-Path $arcRoot 'default.project.json'
if (-not (Test-Path -LiteralPath $arcManifest -PathType Leaf)) { throw 'default.project.json is missing.' }
if (-not (Test-Path -LiteralPath $arcRojo -PathType Leaf)) { throw 'Project-local Rojo is missing.' }
$arcVersion = (& $arcRojo --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Rojo version check failed.' }

switch ($Action) {
    'Mcp' {
        . (Join-Path $PSScriptRoot 'Start-MCP.ps1') -DefineOnly
        $arcDefinitions = Read-McpServerDefinitions -Path (Join-Path $PSScriptRoot '.runtime\servers.json')
        $arcServer = @($arcDefinitions | Where-Object { $_.id -eq 'Rojo' })
        if ($arcServer.Count -ne 1) { throw 'Exactly one Rojo MCP definition is required.' }
        $arcServer = $arcServer[0]
        $arcConfigPath = Join-Path $arcServer.projectDirectory '.runtime\config.json'
        $arcConfig = Get-Content -LiteralPath $arcConfigPath -Raw | ConvertFrom-Json
        if ($arcConfig.token -notmatch '^[a-f0-9]{64}$') { throw 'The existing MCP key is invalid.' }
        $arcState = Get-McpLocalState -Server $arcServer
        if ($arcState.Kind -notin @('Healthy', 'Unhealthy', 'Unavailable')) {
            throw 'The MCP port is not a verified Rojo service. Configuration was not changed.'
        }
        $arcConnectionBefore = Get-McpConnection -Server $arcServer
        if ($arcState.Kind -eq 'Unavailable' -and $arcConnectionBefore -and $arcConnectionBefore.running -eq $true) {
            Repair-McpOfflineRecord -Server $arcServer -NoRecovery:(-not $arcAllowRecovery) | Out-Null
            $arcConnectionBefore = Get-McpConnection -Server $arcServer
        }
        $arcChanged = ($arcConfig.projectRoot -ne $arcRoot) -or ($arcConfig.rojoExecutable -ne $arcRojo)
        if ($arcChanged) {
            $arcBackup = Join-Path $arcServer.projectDirectory ('.runtime\config-before-arc-' + [guid]::NewGuid().ToString('N') + '.json')
            Copy-Item -LiteralPath $arcConfigPath -Destination $arcBackup -ErrorAction Stop
            if ($arcState.Kind -ne 'Unavailable') {
                & (Join-Path $arcServer.projectDirectory 'stop.ps1')
                $arcDeadline = [DateTime]::UtcNow.AddSeconds(15)
                do {
                    $arcState = Get-McpLocalState -Server $arcServer
                    $arcConnectionBefore = Get-McpConnection -Server $arcServer
                    $arcStopped = $arcState.Kind -eq 'Unavailable' -and (-not $arcConnectionBefore -or $arcConnectionBefore.running -ne $true)
                    if ($arcStopped) { break }
                    if ($arcState.Kind -notin @('Healthy', 'Unhealthy', 'Unavailable')) { throw 'Unexpected service appeared during shutdown.' }
                    Start-Sleep -Milliseconds 300
                } while ([DateTime]::UtcNow -lt $arcDeadline)
                if (-not $arcStopped) { throw 'Graceful shutdown did not complete; configuration was not changed.' }
            }
            $arcConfig.projectRoot = $arcRoot
            $arcConfig.rojoExecutable = $arcRojo
            [System.IO.File]::WriteAllText($arcConfigPath, ($arcConfig | ConvertTo-Json -Depth 10) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        }
        $arcPreviousRoot = $env:ROJO_PROJECT_ROOT
        $arcPreviousExecutable = $env:ROJO_EXECUTABLE
        try {
            $env:ROJO_PROJECT_ROOT = $arcRoot
            $env:ROJO_EXECUTABLE = $arcRojo
            & (Join-Path $PSScriptRoot 'Rojo.ps1') -NonInteractive -TimeoutSeconds $McpWaitSeconds -NoRecovery:(-not $arcAllowRecovery)
            $arcState = Get-McpLocalState -Server $arcServer
            if ($arcState.Kind -ne 'Healthy') { throw 'Rojo MCP is not healthy; inspect its private .runtime logs.' }
            $arcConnection = Get-McpConnection -Server $arcServer
            if (-not (Test-McpPublicHealth -Connection $arcConnection)) { throw 'The public HTTPS endpoint is not ready.' }
        } finally {
            $env:ROJO_PROJECT_ROOT = $arcPreviousRoot
            $env:ROJO_EXECUTABLE = $arcPreviousExecutable
        }
        Write-Output "Project: $arcRoot"
        Write-Output "CLI: $arcVersion"
        Write-Output 'Update the Rojo connection URL in Notion using the displayed /mcp URL; keep the existing Bearer key.'
        Write-Output 'MCP startup does not start synchronization. Use rojo_serve in Notion, or the direct Serve command.'
    }
    'Build' {
        $arcBuildDirectory = Join-Path $arcRoot 'build'
        New-Item -ItemType Directory -Path $arcBuildDirectory -Force | Out-Null
        $arcOutput = Join-Path $arcBuildDirectory ('RobloxProject-local-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N') + '.rbxlx')
        Push-Location -LiteralPath $arcRoot
        try {
            & $arcRojo build $arcManifest --output $arcOutput
            if ($LASTEXITCODE -ne 0) { throw 'Rojo build failed.' }
            if ((Get-Item -LiteralPath $arcOutput).Length -le 0) { throw 'Rojo produced an empty file.' }
        } finally { Pop-Location }
        Write-Output "New build: $arcOutput"
        Write-Output 'This is the current source checkpoint; building does not run Studio tests.'
    }
    'Serve' {
        $arcPort = [int]$arcSettings.servePort
        if ($arcPort -lt 1024 -or $arcPort -gt 65535) { throw 'Invalid synchronization port.' }
        $arcListeners = @(Get-NetTCPConnection -LocalPort $arcPort -State Listen -ErrorAction SilentlyContinue)
        if ($arcListeners.Count -gt 0) { throw 'Synchronization port is already in use. Use the existing session or stop it through its owner.' }
        Write-Output "Studio Rojo plugin: 127.0.0.1:$arcPort"
        Write-Output 'Connect in the plugin only when you intend to sync current sources into the open Place.'
        Push-Location -LiteralPath $arcRoot
        try {
            & $arcRojo serve $arcManifest --address 127.0.0.1 --port $arcPort
            if ($LASTEXITCODE -ne 0) { throw 'Rojo serve exited with an error.' }
        } finally { Pop-Location }
    }
    'Studio' {
        $arcStudio = (Resolve-Path -LiteralPath $arcSettings.studioExecutable).Path
        $arcPlace = if ($PlaceFile) { $PlaceFile } elseif (-not [string]::IsNullOrWhiteSpace([string]$arcSettings.placeFile)) { [string]$arcSettings.placeFile } else { throw 'Pass -PlaceFile or set placeFile in the local profile.' }
        $arcPlace = (Resolve-Path -LiteralPath $arcPlace).Path
        if ([System.IO.Path]::GetExtension($arcPlace) -notin @('.rbxlx', '.rbxl')) { throw 'Choose a Roblox place file.' }
        Start-Process -FilePath $arcStudio -ArgumentList @(('"' + $arcPlace + '"')) | Out-Null
        Write-Output "Opened: $arcPlace"
        Write-Output 'In Studio: Assistant > ... > Manage MCP Servers > Enable Studio as MCP server.'
        Write-Output 'Opening a Place does not enable MCP or connect the Rojo plugin automatically.'
    }
    'Status' {
        $arcMcpRoot = '<unconfigured>'
        $arcMapping = Get-Content -LiteralPath (Join-Path $PSScriptRoot '.runtime\servers.json') -Raw | ConvertFrom-Json
        $arcDefinition = @($arcMapping | Where-Object { $_.id -eq 'Rojo' })
        if ($arcDefinition.Count -eq 1) {
            $arcStatusConfig = Get-Content -LiteralPath (Join-Path $arcDefinition[0].projectDirectory '.runtime\config.json') -Raw | ConvertFrom-Json
            $arcMcpRoot = $arcStatusConfig.projectRoot
        }
        Write-Output "Selected project: $arcRoot"
        Write-Output "Selected CLI: $arcVersion"
        Write-Output "Rojo MCP configured project: $arcMcpRoot"
        Write-Output ('Studio processes: ' + @(Get-Process -Name RobloxStudioBeta -ErrorAction SilentlyContinue).Count)
        Write-Output ('Rojo port listeners: ' + @(Get-NetTCPConnection -LocalPort ([int]$arcSettings.servePort) -State Listen -ErrorAction SilentlyContinue).Count)
    }
}
