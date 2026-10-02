[CmdletBinding()]
param(
    [ValidateSet('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo', 'All')]
    [string]$Server = 'All',
    [switch]$NonInteractive,
    [ValidateRange(1, 600)]
    [int]$TimeoutSeconds = 180,
    [string]$ConfigPath,
    [switch]$NoRecovery,
    [switch]$DefineOnly
)

function Read-McpJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    $taskContent = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    $taskDocument = $taskContent | ConvertFrom-Json -ErrorAction Stop
    return $taskDocument
}

function Get-McpNow { return [DateTimeOffset]::UtcNow }
function Wait-McpPause { param([int]$Milliseconds = 500); Start-Sleep -Milliseconds $Milliseconds }

function Get-McpLocalState {
    param([Parameter(Mandatory = $true)]$Server)
    $taskConfigFile = Join-Path $Server.projectDirectory '.runtime\config.json'
    if (-not (Test-Path -LiteralPath $taskConfigFile -PathType Leaf)) {
        return [pscustomobject]@{ Kind = 'Unavailable'; Config = $null }
    }
    try { $taskConfig = Read-McpJson -Path $taskConfigFile }
    catch { throw 'Cannot read the server runtime config. Inspect its .runtime/config.json.' }
    if (-not $taskConfig -or -not $taskConfig.port -or -not $taskConfig.token) {
        throw 'Server runtime config is missing its HTTP port or key. Inspect .runtime/config.json.'
    }
    $taskPort = 0
    if (-not ([int]::TryParse([string]$taskConfig.port, [ref]$taskPort)) -or $taskPort -lt 1024 -or $taskPort -gt 65535) {
        throw 'Server runtime config has an invalid HTTP port.'
    }
    $taskLocalUri = 'http://127.0.0.1:' + $taskPort + '/_status'
    $taskState = [pscustomobject]@{ Kind = 'Unavailable'; Config = $taskConfig }
    try {
        $taskStatus = Invoke-RestMethod -Uri $taskLocalUri -Headers @{ Authorization = ('Bearer ' + $taskConfig.token) } -TimeoutSec 2 -ErrorAction Stop
        if ($taskStatus -and $taskStatus.server -ne $Server.serverIdentity) {
            $taskState.Kind = 'WrongIdentity'
        } elseif ($taskStatus -and $taskStatus.ok -eq $true) {
            $taskState.Kind = 'Healthy'
        } else { $taskState.Kind = 'Unhealthy' }
    } catch {
        $taskStatusError = $_
        if ($taskStatusError.Exception.Response) {
            # HTTP 503 can still identify our own service. Authentication errors
            # or unidentified listeners must never trigger automatic shutdown.
            $taskState.Kind = 'UnknownService'
            $taskFailureStatus = $null
            try {
                if ($taskStatusError.ErrorDetails -and $taskStatusError.ErrorDetails.Message) {
                    $taskFailureStatus = $taskStatusError.ErrorDetails.Message | ConvertFrom-Json -ErrorAction Stop
                }
            } catch { $taskFailureStatus = $null }
            if (-not $taskFailureStatus) {
                try {
                    $taskResponse = $taskStatusError.Exception.Response
                    if ($taskResponse.PSObject.Methods['GetResponseStream']) {
                        $taskResponseStream = $taskResponse.GetResponseStream()
                        if ($taskResponseStream.CanSeek) { $taskResponseStream.Position = 0 }
                        $taskResponseReader = [System.IO.StreamReader]::new($taskResponseStream)
                        try { $taskFailureText = $taskResponseReader.ReadToEnd() }
                        finally { $taskResponseReader.Dispose() }
                    } else { $taskFailureText = $taskResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
                    $taskFailureStatus = $taskFailureText | ConvertFrom-Json -ErrorAction Stop
                } catch { $taskFailureStatus = $null }
            }
            if ($taskFailureStatus -and $taskFailureStatus.server -eq $Server.serverIdentity) {
                $taskState.Kind = 'Unhealthy'
            } elseif ($taskFailureStatus -and $taskFailureStatus.server) {
                $taskState.Kind = 'WrongIdentity'
            }
        }
    }
    return $taskState
}

function Get-McpConnection {
    param([Parameter(Mandatory = $true)]$Server)
    $taskConnectionFile = Join-Path $Server.projectDirectory '.runtime\connection.json'
    $taskConnection = $null
    if (Test-Path -LiteralPath $taskConnectionFile -PathType Leaf) {
        try { $taskConnection = Read-McpJson -Path $taskConnectionFile }
        catch { $taskConnection = $null }
    }
    return $taskConnection
}

function Test-McpRecordedProcessExists {
    param([Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int]$RecordedId)
    try {
        $taskOwner = Get-Process -Id $RecordedId -ErrorAction Stop
        return [bool]$taskOwner
    } catch {
        # Only the specific absent-ID result proves an owner is gone. Access
        # failures and all other lookup errors must preserve the running record.
        if ($_.FullyQualifiedErrorId -eq 'NoProcessFoundForGivenId,Microsoft.PowerShell.Commands.GetProcessCommand' -and
            $_.CategoryInfo.Category -eq [Management.Automation.ErrorCategory]::ObjectNotFound -and
            [string]$_.TargetObject -eq [string]$RecordedId) { return $false }
        throw 'Cannot determine whether the recorded launcher owner exists. Offline recovery was refused.'
    }
}

function Get-McpTcpListenerPorts {
    try {
        $taskListeners = [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        return @($taskListeners | ForEach-Object { $_.Port })
    } catch {
        throw 'Cannot inspect TCP listeners. Offline recovery was refused.'
    }
}

function Get-McpOfflineEvidence {
    param([Parameter(Mandatory = $true)]$Server)
    $taskRuntime = Join-Path $Server.projectDirectory '.runtime'
    try {
        $taskConfigText = [IO.File]::ReadAllText((Join-Path $taskRuntime 'config.json'))
        $taskOfflineConfig = $taskConfigText | ConvertFrom-Json -ErrorAction Stop
        $taskPidText = [IO.File]::ReadAllText((Join-Path $taskRuntime 'launcher.pid'))
        $taskLockText = [IO.File]::ReadAllText((Join-Path $taskRuntime 'launcher.lock'))
        $taskConnectionText = [IO.File]::ReadAllText((Join-Path $taskRuntime 'connection.json'))
    } catch {
        throw 'Cannot read complete launcher ownership and connection evidence. Inspect the private runtime files; offline recovery was refused.'
    }
    $taskOfflinePort = 0
    if (-not $taskOfflineConfig -or -not $taskOfflineConfig.PSObject.Properties['port'] -or
        -not ([int]::TryParse([string]$taskOfflineConfig.port, [ref]$taskOfflinePort)) -or
        $taskOfflinePort -lt 1024 -or $taskOfflinePort -gt 65535) {
        throw 'The configured HTTP port is invalid. Offline recovery was refused.'
    }
    $taskPidOwner = 0
    $taskLockOwner = 0
    if ($taskPidText.Trim() -notmatch '^[0-9]+$' -or $taskLockText.Trim() -notmatch '^[0-9]+$' -or
        -not ([int]::TryParse($taskPidText.Trim(), [ref]$taskPidOwner)) -or
        -not ([int]::TryParse($taskLockText.Trim(), [ref]$taskLockOwner)) -or
        $taskPidOwner -le 0 -or $taskLockOwner -le 0 -or $taskPidOwner -ne $taskLockOwner) {
        throw 'Launcher PID and lock must contain the same positive owner ID. Offline recovery was refused.'
    }
    if (Test-McpRecordedProcessExists -RecordedId $taskPidOwner) {
        throw 'The recorded launcher owner still exists or its PID was reused. Offline recovery was refused.'
    }
    if ($taskOfflinePort -in @(Get-McpTcpListenerPorts)) {
        throw 'The configured HTTP port has a TCP listener. Offline recovery was refused.'
    }
    return [pscustomobject]@{
        ConfigText = $taskConfigText; PidText = $taskPidText; LockText = $taskLockText
        ConnectionText = $taskConnectionText
    }
}

function Repair-McpOfflineRecord {
    param([Parameter(Mandatory = $true)]$Server, [switch]$NoRecovery)
    $taskOfflineState = Get-McpLocalState -Server $Server
    if ($taskOfflineState.Kind -ne 'Unavailable') {
        throw 'The local service is not unavailable. Offline recovery was refused.'
    }
    $taskRecordPath = Join-Path $Server.projectDirectory '.runtime\connection.json'
    try { $taskOriginalText = [IO.File]::ReadAllText($taskRecordPath) }
    catch [IO.FileNotFoundException] { return $false }
    catch [IO.DirectoryNotFoundException] { return $false }
    catch { throw 'Cannot read the private connection record. Offline recovery was refused.' }
    try { $taskOfflineRecord = $taskOriginalText | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'The private connection record is invalid JSON. Offline recovery was refused.' }
    if (-not $taskOfflineRecord -or -not $taskOfflineRecord.PSObject.Properties['running'] -or
        $taskOfflineRecord.running -isnot [bool]) {
        throw 'The private connection record has no valid running flag. Offline recovery was refused.'
    }
    if ($taskOfflineRecord.running -eq $false) { return $false }
    if ($NoRecovery) { throw 'The unavailable MCP has a stale running record. Rerun without -NoRecovery for guarded offline recovery.' }

    $taskEvidence = Get-McpOfflineEvidence -Server $Server
    if ($taskEvidence.ConnectionText -cne $taskOriginalText) {
        throw 'The connection record changed during offline validation. Recovery was refused.'
    }
    $taskOfflineRecord.running = $false
    $taskOfflineRecord | Add-Member -MemberType NoteProperty -Name offlineRecoveredAt -Value (Get-McpNow).ToString('o') -Force
    $taskRepairedText = ($taskOfflineRecord | ConvertTo-Json -Depth 100) + [Environment]::NewLine
    $taskBackupPath = Join-Path $Server.projectDirectory ('.runtime\connection-before-offline-' + [guid]::NewGuid().ToString('N') + '.json')
    try { Copy-Item -LiteralPath $taskRecordPath -Destination $taskBackupPath -ErrorAction Stop }
    catch { throw 'Cannot back up the private connection record. Offline recovery was refused.' }

    # Re-read both owner files, the config/record, process absence and listeners
    # after backup, immediately before writing. Node reclaims its own dead lock.
    $taskOfflineState = Get-McpLocalState -Server $Server
    if ($taskOfflineState.Kind -ne 'Unavailable') { throw 'The local service changed during offline validation. Recovery was refused.' }
    $taskFinalEvidence = Get-McpOfflineEvidence -Server $Server
    foreach ($taskField in @('ConfigText', 'PidText', 'LockText', 'ConnectionText')) {
        if ($taskFinalEvidence.$taskField -cne $taskEvidence.$taskField) {
            throw 'Private runtime evidence changed during offline validation. Recovery was refused.'
        }
    }
    try { [IO.File]::WriteAllText($taskRecordPath, $taskRepairedText, [Text.UTF8Encoding]::new($false)) }
    catch { throw 'Cannot update the private connection record. Its backup is preserved.' }
    return $true
}

function Test-McpPublicHealth {
    param([Parameter(Mandatory = $true)]$Connection)
    if (-not $Connection -or $Connection.running -ne $true -or -not $Connection.baseUrl -or -not $Connection.serverUrl) { return $false }
    $taskBase = $null
    $taskEndpoint = $null
    if (-not ([Uri]::TryCreate([string]$Connection.baseUrl, [UriKind]::Absolute, [ref]$taskBase))) { return $false }
    if (-not ([Uri]::TryCreate([string]$Connection.serverUrl, [UriKind]::Absolute, [ref]$taskEndpoint))) { return $false }
    if ($taskBase.Scheme -ne 'https' -or $taskBase.Host -notmatch '^[a-z0-9-]+\.trycloudflare\.com$' -or $taskBase.Port -ne 443 -or $taskBase.AbsolutePath -ne '/' -or $taskBase.Query -or $taskBase.Fragment -or $taskBase.UserInfo) { return $false }
    if ($taskEndpoint.Scheme -ne 'https' -or $taskEndpoint.Authority -ne $taskBase.Authority -or $taskEndpoint.AbsolutePath -ne '/mcp' -or $taskEndpoint.Query -or $taskEndpoint.Fragment -or $taskEndpoint.UserInfo) { return $false }
    $taskReady = $false
    try {
        $taskHealthUri = $taskBase.GetLeftPart([UriPartial]::Authority) + '/health'
        $taskHealth = Invoke-RestMethod -Uri $taskHealthUri -TimeoutSec 4 -ErrorAction Stop
        $taskReady = $taskHealth -and $taskHealth.ok -eq $true
    } catch { $taskReady = $false }
    return [bool]$taskReady
}

function Invoke-McpProjectScript {
    param([Parameter(Mandatory = $true)]$Server, [ValidateSet('Start', 'Stop')][string]$Action)
    $taskFileName = if ($Action -eq 'Start') { 'start.ps1' } else { 'stop.ps1' }
    $taskScriptPath = Join-Path $Server.projectDirectory $taskFileName
    if (-not (Test-Path -LiteralPath $taskScriptPath -PathType Leaf)) { throw "Missing supported $taskFileName in the configured project directory." }
    # Existing helpers can print compatibility URLs. Suppress their normal output;
    # display only our validated canonical endpoint after the health check.
    & $taskScriptPath | Out-Null
}

function New-McpReadyResult {
    param($Server, $Connection, [bool]$Reused = $false, [bool]$Recovered = $false)
    # Public health validation accepts only the canonical Bearer /mcp path.
    $taskPublicUri = [Uri]$Connection.baseUrl
    $taskServerUrl = $taskPublicUri.GetLeftPart([UriPartial]::Authority) + '/mcp'
    return [pscustomobject]@{
        id = $Server.id; label = $Server.label; ready = $true
        serverUrl = $taskServerUrl
        connectionFile = (Join-Path $Server.projectDirectory 'connection.md')
        reused = $Reused; recovered = $Recovered; error = $null
    }
}

function Start-McpServer {
    param([Parameter(Mandatory = $true)]$Server, [int]$TimeoutSeconds = 180, [switch]$NoRecovery)
    $taskDeadline = (Get-McpNow).AddSeconds($TimeoutSeconds)
    $taskLocal = Get-McpLocalState -Server $Server
    $taskRecovered = $false
    if ($taskLocal.Kind -eq 'WrongIdentity') { throw 'The configured local port belongs to a different service. Nothing was started or stopped.' }
    if ($taskLocal.Kind -eq 'UnknownService') { throw 'The local port rejected authentication or returned no recognized identity. Inspect runtime config and logs; nothing was started or stopped.' }
    if ($taskLocal.Kind -eq 'Unavailable') {
        $taskOfflineConnection = Get-McpConnection -Server $Server
        if ($taskOfflineConnection -and $taskOfflineConnection.running -eq $true) {
            $taskRecovered = Repair-McpOfflineRecord -Server $Server -NoRecovery:$NoRecovery
        }
    }
    if ($taskLocal.Kind -eq 'Healthy' -or $taskLocal.Kind -eq 'Unhealthy') {
        if ($taskLocal.Kind -eq 'Healthy') {
            for ($taskAttempt = 0; $taskAttempt -lt 3; $taskAttempt++) {
                $taskConnection = Get-McpConnection -Server $Server
                if ($taskConnection -and (Test-McpPublicHealth -Connection $taskConnection)) {
                    return New-McpReadyResult -Server $Server -Connection $taskConnection -Reused $true
                }
                if ((Get-McpNow) -ge $taskDeadline) { throw 'HTTPS validation timed out. A stale endpoint was not marked ready.' }
                if ($taskAttempt -lt 2) { Wait-McpPause -Milliseconds 1000 }
            }
        }
        if ($NoRecovery) { throw 'The local MCP or its current HTTPS endpoint is unhealthy. Check runtime logs or rerun without -NoRecovery for supported recovery.' }
        Invoke-McpProjectScript -Server $Server -Action Stop
        $taskShutdownDeadline = (Get-McpNow).AddSeconds(15)
        do {
            $taskLocal = Get-McpLocalState -Server $Server
            $taskConnection = Get-McpConnection -Server $Server
            $taskStopped = $taskLocal.Kind -eq 'Unavailable' -and (-not $taskConnection -or $taskConnection.running -ne $true)
            if (-not $taskStopped) {
                if ((Get-McpNow) -ge $taskShutdownDeadline -or (Get-McpNow) -ge $taskDeadline) { throw 'Graceful shutdown did not finish. Inspect local logs; no processes were killed and no duplicate was started.' }
                Wait-McpPause -Milliseconds 500
            }
        } while (-not $taskStopped)
        Wait-McpPause -Milliseconds 500
        $taskRecovered = $true
    }
    if ((Get-McpNow) -ge $taskDeadline) { throw 'Startup time limit was reached before a new launch. Check runtime logs.' }
    Invoke-McpProjectScript -Server $Server -Action Start
    do {
        if ((Get-McpNow) -ge $taskDeadline) { throw 'HTTPS startup timed out. Check .runtime/server.log and tunnel.log. The helper was left running; rerun to check it.' }
        $taskLocal = Get-McpLocalState -Server $Server
        if ($taskLocal.Kind -eq 'WrongIdentity') { throw 'A different service occupies the configured local port. Nothing was stopped.' }
        if ($taskLocal.Kind -eq 'Healthy') {
            $taskConnection = Get-McpConnection -Server $Server
            if ($taskConnection -and (Test-McpPublicHealth -Connection $taskConnection)) {
                return New-McpReadyResult -Server $Server -Connection $taskConnection -Recovered $taskRecovered
            }
        }
        Wait-McpPause -Milliseconds 1000
    } while ($true)
}

function Start-McpSelection {
    param([Parameter(Mandatory = $true)][object[]]$Servers, [string]$SelectedId = 'All', [int]$TimeoutSeconds = 180, [switch]$NoRecovery)
    $taskSelected = @($Servers | Where-Object { $SelectedId -eq 'All' -or $_.id -eq $SelectedId })
    if ($taskSelected.Count -eq 0) { throw 'No server matches the selection. Check .runtime/servers.json.' }
    $taskResults = @()
    foreach ($taskDefinition in $taskSelected) {
        Write-Host ('[' + $taskDefinition.id + '] Starting/checking HTTPS...')
        try { $taskResult = Start-McpServer -Server $taskDefinition -TimeoutSeconds $TimeoutSeconds -NoRecovery:$NoRecovery }
        catch {
            $taskResult = [pscustomobject]@{
                id = $taskDefinition.id; label = $taskDefinition.label; ready = $false
                serverUrl = $null; connectionFile = (Join-Path $taskDefinition.projectDirectory 'connection.md')
                reused = $false; recovered = $false; error = $_.Exception.Message
            }
        }
        $taskResults += $taskResult
        if ($taskResult.ready) { Write-Host ('[' + $taskDefinition.id + '] READY') }
        else { Write-Host ('[' + $taskDefinition.id + '] FAILED: ' + $taskResult.error) }
    }
    return $taskResults
}

function Read-McpServerDefinitions {
    param([Parameter(Mandatory = $true)][string]$Path)
    $taskDefinitions = @(Read-McpJson -Path $Path)
    if ($taskDefinitions.Count -eq 0) { throw 'The launcher configuration contains no servers.' }
    $taskIds = @()
    foreach ($taskDefinition in $taskDefinitions) {
        if (-not $taskDefinition -or $taskDefinition.id -notin @('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo') -or -not $taskDefinition.label -or -not $taskDefinition.serverIdentity -or -not $taskDefinition.projectDirectory) {
            throw 'Each launcher config entry requires a known id, label, serverIdentity and projectDirectory.'
        }
        if ($taskDefinition.id -in $taskIds) { throw 'Duplicate server id in launcher config.' }
        if (-not ([IO.Path]::IsPathRooted([string]$taskDefinition.projectDirectory))) { throw 'Each projectDirectory must be an absolute path.' }
        $taskIds += $taskDefinition.id
    }
    return $taskDefinitions
}

function Show-McpResults {
    param([Parameter(Mandatory = $true)][object[]]$Results)
    foreach ($taskResult in $Results) {
        if ($taskResult.ready) {
            $taskReuseMessage = if ($taskResult.reused) { 'existing service reused' } elseif ($taskResult.recovered) { 'HTTPS recovered through supported launch helpers' } else { 'started' }
            Write-Output ('[READY] ' + $taskResult.label + ' (' + $taskReuseMessage + ')')
            Write-Output ('URL: ' + $taskResult.serverUrl)
            Write-Output ('Key and settings file: ' + $taskResult.connectionFile)
        } else {
            Write-Output ('[FAILED] ' + $taskResult.label)
            Write-Output ('Reason: ' + $taskResult.error)
        }
        Write-Output ''
    }
}

if ($DefineOnly) { return }
$ErrorActionPreference = 'Stop'
$taskExitCode = 1
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot '.runtime\servers.json' }
try {
    Write-Output ('Checking MCP HTTPS: ' + $Server)
    Write-Output 'Existing keys and project folders are preserved. A changed tunnel URL must be updated in Notion.'
    $taskDefinitions = @(Read-McpServerDefinitions -Path $ConfigPath)
    $taskResults = @(Start-McpSelection -Servers $taskDefinitions -SelectedId $Server -TimeoutSeconds $TimeoutSeconds -NoRecovery:$NoRecovery)
    Show-McpResults -Results $taskResults
    $taskOutputDirectory = Join-Path $PSScriptRoot '.runtime'
    New-Item -ItemType Directory -Path $taskOutputDirectory -Force -ErrorAction Stop | Out-Null
    $taskSavedLines = @('PRIVATE LOCAL CONNECTIONS. Do not publish this file.', ('Checked at: ' + (Get-McpNow).ToString('o')), '')
    foreach ($taskResult in $taskResults) {
        if ($taskResult.ready) {
            $taskSavedLines += @($taskResult.label, $taskResult.serverUrl, ('Settings: ' + $taskResult.connectionFile), '')
        } else { $taskSavedLines += @($taskResult.label + ': FAILED', $taskResult.error, '') }
    }
    $taskLinksFile = Join-Path $taskOutputDirectory 'links.txt'
    $taskSavedLines | Set-Content -LiteralPath $taskLinksFile -Encoding UTF8 -ErrorAction Stop
    Write-Output ('Current checked links saved to: ' + $taskLinksFile)
    $taskFailedCount = @($taskResults | Where-Object { -not $_.ready }).Count
    Write-Output ('Result: ' + ($taskResults.Count - $taskFailedCount) + '/' + $taskResults.Count + ' ready.')
    $taskExitCode = if ($taskFailedCount) { 1 } else { 0 }
    $global:LASTEXITCODE = $taskExitCode
} catch {
    Write-Output ('[FAILED] ' + $_.Exception.Message)
    Write-Output ('Check launcher config: ' + $ConfigPath)
    $taskExitCode = 1
    $global:LASTEXITCODE = 1
} finally {
    if (-not $NonInteractive) { Read-Host 'Press Enter to close this window' | Out-Null }
}
# Explicit exit also gives the wrapping .ps1/.cmd entry points a process status.
exit $taskExitCode
