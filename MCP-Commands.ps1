#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Help', 'Start', 'Status', 'Links', 'Stop', 'Restart')]
    [string]$Command = 'Help',
    [Parameter(Position = 1)]
    [ValidateSet('All', 'Filesystem', 'Blender', 'Roblox-Studio', 'Rojo')]
    [string]$Target = 'All',
    [string]$MappingPath,
    [ValidateRange(1, 600)][int]$WaitSeconds = 180,
    [switch]$NoRecovery,
    [switch]$DefineOnly
)

$ErrorActionPreference = 'Stop'
# Windows PowerShell -File binds parameter defaults before PSScriptRoot is ready.
if ([string]::IsNullOrWhiteSpace($MappingPath)) {
    $MappingPath = Join-Path $PSScriptRoot '.runtime\servers.json'
}
$commandPreventRecovery = [bool]$NoRecovery
$commandOnlyDefinitions = [bool]$DefineOnly
. (Join-Path $PSScriptRoot 'Start-MCP.ps1') -DefineOnly

function Stop-McpCommandServer {
    param([Parameter(Mandatory = $true)]$Definition, [switch]$PreventRecovery)
    $commandState = Get-McpLocalState -Server $Definition
    if ($commandState.Kind -in @('WrongIdentity', 'UnknownService')) {
        throw 'The local port is not a verified instance of this MCP. Shutdown was refused.'
    }
    if ($commandState.Kind -eq 'Unavailable') {
        # A timeout or stale tunnel record is not proof of a completed shutdown.
        $commandConnection = Get-McpConnection -Server $Definition
        if ($commandConnection -and $commandConnection.running -eq $true) {
            Repair-McpOfflineRecord -Server $Definition -NoRecovery:$PreventRecovery | Out-Null
        }
        return
    }
    if ($commandState.Kind -notin @('Healthy', 'Unhealthy')) { throw 'Unrecognized local service state.' }
    Invoke-McpProjectScript -Server $Definition -Action Stop
    $commandStopDeadline = (Get-McpNow).AddSeconds(15)
    do {
        $commandState = Get-McpLocalState -Server $Definition
        $commandConnection = Get-McpConnection -Server $Definition
        if ($commandState.Kind -eq 'Unavailable' -and (-not $commandConnection -or $commandConnection.running -ne $true)) { return }
        if ($commandState.Kind -notin @('Healthy', 'Unhealthy', 'Unavailable')) {
            throw 'An unexpected service appeared during shutdown. Restart was refused.'
        }
        if ((Get-McpNow) -ge $commandStopDeadline) { throw 'Graceful shutdown did not finish. No processes were killed.' }
        Wait-McpPause -Milliseconds 500
    } while ($true)
}

function Start-McpCommandServer {
    param([Parameter(Mandatory = $true)]$Definition, [int]$Seconds, [switch]$PreventRecovery, [bool]$UseArcProfile)
    if ($Definition.id -eq 'Rojo' -and $UseArcProfile) {
        # The existing project command preserves the key and applies the selected root/CLI.
        & (Join-Path $PSScriptRoot 'Arc-Commands.ps1') Mcp -McpWaitSeconds $Seconds -AllowRecovery:(-not $PreventRecovery) *> $null
        $commandLocal = Get-McpLocalState -Server $Definition
        $commandConnection = Get-McpConnection -Server $Definition
        if ($commandLocal.Kind -ne 'Healthy' -or -not $commandConnection -or -not (Test-McpPublicHealth -Connection $commandConnection)) {
            throw 'Rojo HTTPS startup was not verified.'
        }
        return New-McpReadyResult -Server $Definition -Connection $commandConnection
    }
    return Start-McpServer -Server $Definition -TimeoutSeconds $Seconds -NoRecovery:$PreventRecovery
}

function Get-McpCommandLink {
    param([Parameter(Mandatory = $true)]$Definition)
    $commandLocal = Get-McpLocalState -Server $Definition
    if ($commandLocal.Kind -ne 'Healthy') { throw 'Local MCP is not healthy; a saved URL was not marked active.' }
    $commandConnection = Get-McpConnection -Server $Definition
    if (-not $commandConnection -or -not (Test-McpPublicHealth -Connection $commandConnection)) {
        throw 'The current canonical HTTPS endpoint did not pass its health check.'
    }
    return New-McpReadyResult -Server $Definition -Connection $commandConnection -Reused $true
}

function Invoke-McpCommandSelection {
    param([object[]]$Definitions, [string]$Operation, [int]$Seconds, [switch]$PreventRecovery, [bool]$UseArcProfile)
    $commandOperationResults = @()
    foreach ($commandDefinition in $Definitions) {
        Write-Host ('[' + $commandDefinition.id + '] ' + $Operation + '...')
        try {
            if ($Operation -in @('Stop', 'Restart')) { Stop-McpCommandServer -Definition $commandDefinition -PreventRecovery:$PreventRecovery }
            $commandResult = if ($Operation -in @('Start', 'Restart')) {
                Start-McpCommandServer -Definition $commandDefinition -Seconds $Seconds -PreventRecovery:$PreventRecovery -UseArcProfile $UseArcProfile
            } elseif ($Operation -eq 'Links') { Get-McpCommandLink -Definition $commandDefinition }
            else { [pscustomobject]@{ id = $commandDefinition.id; label = $commandDefinition.label; ready = $true; stopped = $true } }
            $commandOperationResults += $commandResult
        } catch {
            # Do not print raw upstream exception text: it may contain a compatibility URL or a key.
            Write-Host ('[' + $commandDefinition.id + '] FAILED. Inspect its private .runtime logs. ' + (Protect-McpCommandText -Text $_.Exception.Message -Definition $commandDefinition))
            $commandOperationResults += [pscustomobject]@{ id = $commandDefinition.id; ready = $false }
        }
    }
    return $commandOperationResults
}

function Protect-McpCommandText {
    param([string]$Text, $Definition)
    try {
        $commandPrivateConfig = Read-McpJson -Path (Join-Path $Definition.projectDirectory '.runtime\config.json')
        if ($commandPrivateConfig.token) { $Text = $Text.Replace([string]$commandPrivateConfig.token, '[REDACTED]') }
    } catch { }
    $Text = $Text -replace '(?i)\bBearer\s+[^\s"''<>]+', 'Bearer [REDACTED]'
    return ($Text -replace '(?i)\b[a-f0-9]{64}\b', '[REDACTED]')
}

function Invoke-McpCommandStatus {
    param([string]$Selection, [string]$DefinitionsPath)
    if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required for authenticated MCP diagnostics.' }
    $commandReportPath = Join-Path $PSScriptRoot '.runtime\mcp-command-status.json'
    Write-Host 'Checking HTTPS and performing read-only MCP calls...'
    $commandStatusOutput = @(& node (Join-Path $PSScriptRoot 'Check-MCP.mjs') --server $Selection --config $DefinitionsPath --report $commandReportPath)
    $commandStatusExit = $LASTEXITCODE
    foreach ($commandLine in $commandStatusOutput) {
        $commandDiagnostic = $commandLine | ConvertFrom-Json
        $commandMark = if (-not $commandDiagnostic.ok) { 'FAILED' } elseif ($commandDiagnostic.applicationReady -eq $false) { 'ATTENTION' } else { 'READY' }
        Write-Output ('[' + $commandMark + '] ' + $commandDiagnostic.id + ' | HTTPS=' + $commandDiagnostic.publicHealthy + ' | MCP=' + $commandDiagnostic.protocolHealthy + ' | Tools=' + $commandDiagnostic.toolCount)
        if ($commandDiagnostic.endpoint) { Write-Output ('URL: ' + $commandDiagnostic.endpoint) }
        if ($commandDiagnostic.allowedDirectories) { Write-Output ('Allowed folder: ' + ($commandDiagnostic.allowedDirectories -join ', ')) }
        if ($commandDiagnostic.sceneName) { Write-Output ('Scene: ' + $commandDiagnostic.sceneName + ' | Objects: ' + $commandDiagnostic.objectCount) }
        if ($null -ne $commandDiagnostic.studiosCount) { Write-Output ('Available Studio Places: ' + $commandDiagnostic.studiosCount) }
        if ($commandDiagnostic.projectRoot) { Write-Output ('Project: ' + $commandDiagnostic.projectRoot + ' | CLI: ' + $commandDiagnostic.version + ' | Sync: ' + $commandDiagnostic.serveState) }
        if ($commandDiagnostic.expectedProjectRoot) { Write-Output ('Selected project: ' + $commandDiagnostic.expectedProjectRoot) }
        if ($commandDiagnostic.limitation) { Write-Output ('Action: ' + $commandDiagnostic.limitation) }
        if ($commandDiagnostic.error) { Write-Output ('Reason (' + $commandDiagnostic.stage + '): ' + $commandDiagnostic.error) }
        Write-Output ''
    }
    Write-Output ('Private diagnostic report: ' + $commandReportPath)
    if ($commandStatusExit -ne 0) { throw 'One or more MCPs need attention. See the results above.' }
}

if ($commandOnlyDefinitions) { return }
if ($Command -eq 'Help') {
    Write-Output 'MCP-Commands.ps1 Start All          Start/reuse all four HTTPS MCP endpoints.'
    Write-Output 'MCP-Commands.ps1 Status All         Check HTTPS, MCP protocol and applications without changes.'
    Write-Output 'MCP-Commands.ps1 Links All          Show current checked URLs without starting anything.'
    Write-Output 'MCP-Commands.ps1 Stop All           Gracefully stop MCP gateways and their tunnels.'
    Write-Output 'MCP-Commands.ps1 Restart Blender    Gracefully restart one MCP and show its URL.'
    Write-Output 'Targets: All, Filesystem, Blender, Roblox-Studio, Rojo.'
    $global:LASTEXITCODE = 0
    return
}

try {
    $commandDefinitions = @(Read-McpServerDefinitions -Path $MappingPath)
    $commandSelected = @($commandDefinitions | Where-Object { $Target -eq 'All' -or $_.id -eq $Target })
    if ($commandSelected.Count -eq 0) { throw 'No configured server matches the selection.' }
    if ($Command -eq 'Status') {
        Invoke-McpCommandStatus -Selection $Target -DefinitionsPath $MappingPath
    } else {
        $commandDefaultMapping = Join-Path $PSScriptRoot '.runtime\servers.json'
        $commandArcEnabled = ([IO.Path]::GetFullPath($MappingPath) -eq [IO.Path]::GetFullPath($commandDefaultMapping)) -and (Test-Path -LiteralPath (Join-Path $PSScriptRoot '.runtime\arc-command-settings.json') -PathType Leaf)
        $commandResults = @(Invoke-McpCommandSelection -Definitions $commandSelected -Operation $Command -Seconds $WaitSeconds -PreventRecovery:$commandPreventRecovery -UseArcProfile $commandArcEnabled)
        $commandLinks = @('PRIVATE LOCAL CONNECTIONS. Do not publish.', ('Checked at: ' + (Get-McpNow).ToString('o')))
        foreach ($commandResult in $commandResults) {
            if (-not $commandResult.ready) { continue }
            if ($Command -eq 'Stop') { Write-Output ('[STOPPED] ' + $commandResult.label); continue }
            Write-Output ('[HTTPS READY] ' + $commandResult.label)
            Write-Output ('URL: ' + $commandResult.serverUrl)
            Write-Output ('Key/settings file: ' + $commandResult.connectionFile)
            $commandLinks += @('', $commandResult.label, $commandResult.serverUrl, ('Settings: ' + $commandResult.connectionFile))
        }
        if ($Command -ne 'Stop') {
            $commandLinksDirectory = Join-Path $PSScriptRoot '.runtime'
            New-Item -ItemType Directory -Path $commandLinksDirectory -Force | Out-Null
            $commandLinks | Set-Content -LiteralPath (Join-Path $commandLinksDirectory 'links.txt') -Encoding UTF8
            Write-Output 'Use the URL and the existing Bearer key in Notion. A restarted tunnel may have a new domain.'
            Write-Output 'HTTPS readiness does not verify the app. Run Status to check Blender/Studio and the project.'
        }
        if (@($commandResults | Where-Object { -not $_.ready }).Count) { throw 'One or more MCP operations failed; other selected servers were still processed.' }
    }
    $global:LASTEXITCODE = 0
} catch {
    Write-Output ('[FAILED] ' + $_.Exception.Message)
    $global:LASTEXITCODE = 1
    # exit sets the process code for powershell.exe -File and returns to an & invocation.
    exit 1
}
