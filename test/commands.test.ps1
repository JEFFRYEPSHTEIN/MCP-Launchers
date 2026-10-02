param([string]$CommandsPath)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($CommandsPath)) {
    $CommandsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'MCP-Commands.ps1'
}
. $CommandsPath -DefineOnly
$script:PassCount = 0
$script:FakeKey = ('0123456789abcdef' * 4)

function Assert-Command($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Expect-CommandFailure([scriptblock]$Body) {
    $failed = $false
    try { & $Body | Out-Null } catch { $failed = $true }
    Assert-Command $failed 'Expected operation to be refused.'
}
function Command-Test([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:PassCount++
    Write-Output ('[PASS] ' + $Name)
}
function Reset-CommandScenario {
    $script:Kinds = @{}
    $script:Connections = @{}
    $script:Actions = @()
    $script:RecoveryFlags = @()
    $script:Hosts = @()
    $script:Clock = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    $script:CompleteShutdown = $true
    Set-Item Function:script:Get-McpLocalState -Value {
        param($Server)
        $kind = if ($script:Kinds.ContainsKey($Server.id)) { $script:Kinds[$Server.id] } else { 'Healthy' }
        [pscustomobject]@{ Kind = $kind }
    }
    Set-Item Function:script:Get-McpConnection -Value { param($Server); $script:Connections[$Server.id] }
    Set-Item Function:script:Repair-McpOfflineRecord -Value {
        param($Server, [switch]$NoRecovery)
        $script:RecoveryFlags += [bool]$NoRecovery
        throw 'Offline ownership is not proven in this scenario.'
    }
    Set-Item Function:script:Test-McpPublicHealth -Value { param($Connection); [bool]$Connection.running }
    Set-Item Function:script:Get-McpNow -Value { $script:Clock }
    Set-Item Function:script:Wait-McpPause -Value {
        param($Milliseconds)
        $script:Clock = $script:Clock.AddMilliseconds($Milliseconds)
    }
    Set-Item Function:script:Invoke-McpProjectScript -Value {
        param($Server, $Action)
        $script:Actions += ($Server.id + ':' + $Action)
        if ($Action -eq 'Stop' -and $script:CompleteShutdown) {
            $script:Kinds[$Server.id] = 'Unavailable'
            $script:Connections[$Server.id].running = $false
        }
    }
    Set-Item Function:script:Start-McpServer -Value {
        param($Server, $TimeoutSeconds, $NoRecovery)
        Assert-Command ($script:Kinds[$Server.id] -eq 'Unavailable') 'Restart began before local shutdown.'
        Assert-Command (-not $script:Connections[$Server.id].running) 'Restart began before tunnel shutdown.'
        $script:Actions += ($Server.id + ':Start')
        $script:Kinds[$Server.id] = 'Healthy'
        $script:Connections[$Server.id].running = $true
        New-McpReadyResult -Server $Server -Connection $script:Connections[$Server.id]
    }
    Set-Item Function:script:Write-Host -Value {
        param([Parameter(ValueFromRemainingArguments = $true)]$Object)
        $script:Hosts += ($Object -join ' ')
    }
    Set-Item Function:script:Read-McpJson -Value { param($Path); [pscustomobject]@{ token = $script:FakeKey } }
}
function Mock-CommandServer([string]$Id) {
    $base = 'https://mock-' + $Id.ToLowerInvariant() + '.trycloudflare.com'
    $script:Connections[$Id] = [pscustomobject]@{ running = $true; baseUrl = $base; serverUrl = ($base + '/mcp') }
    [pscustomobject]@{ id = $Id; label = $Id; serverIdentity = ('test-' + $Id); projectDirectory = 'C:\mock-mcp' }
}

Command-Test 'Wrong and unknown identities never receive shutdown' {
    foreach ($kind in @('WrongIdentity', 'UnknownService')) {
        Reset-CommandScenario
        $server = Mock-CommandServer 'Blender'
        $script:Kinds.Blender = $kind
        Expect-CommandFailure { Stop-McpCommandServer -Definition $server }
        Assert-Command ($script:Actions.Count -eq 0) 'Unknown service was changed.'
    }
}
Command-Test 'Unavailable with stale running tunnel cannot certify shutdown' {
    Reset-CommandScenario
    $server = Mock-CommandServer 'Rojo'
    $script:Kinds.Rojo = 'Unavailable'
    Expect-CommandFailure { Stop-McpCommandServer -Definition $server }
    Assert-Command ($script:Actions.Count -eq 0) 'Stale service caused blind shutdown.'
}
Command-Test 'Guarded dead-record recovery certifies stopped state without a shutdown API call' {
    Reset-CommandScenario
    $server = Mock-CommandServer 'Rojo'
    $script:Kinds.Rojo = 'Unavailable'
    Set-Item Function:script:Repair-McpOfflineRecord -Value {
        param($Server, [switch]$NoRecovery)
        Assert-Command (-not $NoRecovery) 'Unexpected recovery prevention.'
        $script:Actions += ($Server.id + ':Recover')
        $script:Connections[$Server.id].running = $false
        return $true
    }
    $results = @(Invoke-McpCommandSelection -Definitions @($server) -Operation Stop -UseArcProfile $false)
    Assert-Command $results[0].ready 'Proven dead metadata was not accepted as stopped.'
    Assert-Command (-not $script:Connections.Rojo.running) 'Recovery did not reconcile the running flag.'
    Assert-Command (($script:Actions -join ',') -eq 'Rojo:Recover') 'Dead-record recovery called a shutdown or startup helper.'
}
Command-Test 'NoRecovery reaches guarded offline restart and prevents startup after refusal' {
    Reset-CommandScenario
    $server = Mock-CommandServer 'Rojo'
    $script:Kinds.Rojo = 'Unavailable'
    $results = @(Invoke-McpCommandSelection -Definitions @($server) -Operation Restart -PreventRecovery -UseArcProfile $false)
    Assert-Command (-not $results[0].ready) 'Refused offline recovery was reported ready.'
    Assert-Command ($script:RecoveryFlags.Count -eq 1 -and $script:RecoveryFlags[0]) 'NoRecovery did not reach the offline helper.'
    Assert-Command ($script:Connections.Rojo.running -and $script:Actions.Count -eq 0) 'NoRecovery changed metadata or called process helpers.'
}
Command-Test 'Already stopped service is a no-op' {
    Reset-CommandScenario
    $server = Mock-CommandServer 'Filesystem'
    $script:Kinds.Filesystem = 'Unavailable'
    $script:Connections.Filesystem.running = $false
    Stop-McpCommandServer -Definition $server
    Assert-Command ($script:Actions.Count -eq 0) 'Stopped service was touched.'
}
Command-Test 'Restart follows supported shutdown and verifies both local and tunnel state' {
    Reset-CommandScenario
    $server = Mock-CommandServer 'Blender'
    $results = @(Invoke-McpCommandSelection -Definitions @($server) -Operation Restart -Seconds 30 -UseArcProfile $false)
    Assert-Command ($results[0].ready) 'Expected restarted endpoint.'
    Assert-Command (($script:Actions -join ',') -eq 'Blender:Stop,Blender:Start') 'Incorrect stop/start order.'
}
Command-Test 'Timed-out shutdown prevents restart' {
    Reset-CommandScenario
    $server = Mock-CommandServer 'Rojo'
    $script:CompleteShutdown = $false
    $results = @(Invoke-McpCommandSelection -Definitions @($server) -Operation Restart -Seconds 30 -UseArcProfile $false)
    Assert-Command (-not $results[0].ready) 'Incomplete shutdown was accepted.'
    Assert-Command (($script:Actions -join ',') -eq 'Rojo:Stop') 'Restart attempted before shutdown finished.'
}
Command-Test 'All mode continues supported shutdown after one identity refusal' {
    Reset-CommandScenario
    $servers = @('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo' | ForEach-Object { Mock-CommandServer $_ })
    $script:Kinds.Filesystem = 'WrongIdentity'
    $results = @(Invoke-McpCommandSelection -Definitions $servers -Operation Stop -UseArcProfile $false)
    Assert-Command ($results.Count -eq 4) 'Missing per-server result.'
    Assert-Command (@($results | Where-Object { $_.ready }).Count -eq 3) 'Other servers were skipped.'
    Assert-Command (-not ($script:Actions -contains 'Filesystem:Stop')) 'Wrong identity was stopped.'
}
Command-Test 'Links rejects stale local status without starting anything' {
    Reset-CommandScenario
    $server = Mock-CommandServer 'Roblox-Studio'
    $script:Kinds['Roblox-Studio'] = 'Unavailable'
    Expect-CommandFailure { Get-McpCommandLink -Definition $server }
    Assert-Command ($script:Actions.Count -eq 0) 'Read-only Links changed a service.'
}
Command-Test 'Errors redact Bearer keys and compatibility paths' {
    Reset-CommandScenario
    $server = Mock-CommandServer 'Rojo'
    $message = 'Bearer ' + $script:FakeKey + ' https://test.trycloudflare.com/' + $script:FakeKey + '/mcp'
    $safe = Protect-McpCommandText -Text $message -Definition $server
    Assert-Command (-not $safe.Contains($script:FakeKey)) 'Error output contains a key.'
    Assert-Command ($safe.Contains('[REDACTED]')) 'Expected explicit redaction.'
}
Write-Output ('Command safety checks passed: ' + $script:PassCount + '. No live services were modified.')
