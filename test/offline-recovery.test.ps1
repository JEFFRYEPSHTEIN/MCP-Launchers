#Requires -Version 5.1
param([string]$LauncherPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
    $LauncherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-MCP.ps1'
}
. $LauncherPath -DefineOnly
$script:PassCount = 0
$script:FixtureId = [guid]::NewGuid().ToString('N')
$script:TempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
$script:FixtureRoot = Join-Path $script:TempParent ('mcp-offline-tests-' + $script:FixtureId)
$script:FixtureRuntime = Join-Path $script:FixtureRoot '.runtime'
$script:FixtureServer = [pscustomobject]@{ id = 'Rojo'; label = 'Rojo'; serverIdentity = 'test-rojo'; projectDirectory = $script:FixtureRoot }
$script:FakeKey = 'fixture-private-key-never-printed'

function Assert-Offline($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Offline-Test([string]$CaseName, [scriptblock]$Body) {
    Reset-OfflineFixture
    & $Body
    $script:PassCount++
    Write-Output ('[PASS] ' + $CaseName)
}
function Write-OfflineJson([string]$Name, $Value) {
    [IO.File]::WriteAllText((Join-Path $script:FixtureRuntime $Name), ($Value | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
}
function Reset-OfflineFixture {
    $script:StateKind = 'Unavailable'
    $script:ProcessChecks = 0
    $script:ListenerChecks = 0
    $script:OriginalConfig = [pscustomobject]@{ port = 18770; token = $script:FakeKey; projectRoot = 'C:\fixture-project'; other = [pscustomobject]@{ keep = 'unchanged' } }
    $script:OriginalConnection = [pscustomobject]@{
        running = $true; token = $script:FakeKey; projectRoot = 'C:\fixture-project'
        baseUrl = 'https://fixture.trycloudflare.com'; serverUrl = 'https://fixture.trycloudflare.com/mcp'
        custom = [pscustomobject]@{ nested = @('one', 'two') }
    }
    Write-OfflineJson 'config.json' $script:OriginalConfig
    Write-OfflineJson 'connection.json' $script:OriginalConnection
    Set-Content -LiteralPath (Join-Path $script:FixtureRuntime 'launcher.pid') -Value '123456' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $script:FixtureRuntime 'launcher.lock') -Value '123456' -Encoding ASCII
    Set-Item Function:script:Get-McpLocalState -Value { param($Server); [pscustomobject]@{ Kind = $script:StateKind } }
    Set-Item Function:script:Test-McpRecordedProcessExists -Value { param($RecordedId); $script:ProcessChecks++; return $false }
    Set-Item Function:script:Get-McpTcpListenerPorts -Value { $script:ListenerChecks++; return @() }
    Set-Item Function:script:Get-McpNow -Value { [DateTimeOffset]::Parse('2026-10-02T00:00:00Z') }
}
function Assert-RecoveryRefused([switch]$NoRecovery) {
    $before = [IO.File]::ReadAllText((Join-Path $script:FixtureRuntime 'connection.json'))
    $failed = $false
    try { Repair-McpOfflineRecord -Server $script:FixtureServer -NoRecovery:$NoRecovery | Out-Null } catch { $failed = $true }
    Assert-Offline $failed 'Unsafe or ambiguous ownership was accepted.'
    Assert-Offline ([IO.File]::ReadAllText((Join-Path $script:FixtureRuntime 'connection.json')) -eq $before) 'A refused recovery changed the connection record.'
}

try {
    New-Item -ItemType Directory -Path $script:FixtureRuntime | Out-Null
    Set-Content -LiteralPath (Join-Path $script:FixtureRoot '.fixture-owner') -Value $script:FixtureId -Encoding ASCII

    Offline-Test 'Proven dead owners recover metadata while preserving private fields and ownership files' {
        $configBefore = [IO.File]::ReadAllText((Join-Path $script:FixtureRuntime 'config.json'))
        $connectionBefore = [IO.File]::ReadAllText((Join-Path $script:FixtureRuntime 'connection.json'))
        $backupBefore = @(Get-ChildItem -LiteralPath $script:FixtureRuntime -Filter 'connection-before-offline-*.json').Count
        $result = Repair-McpOfflineRecord -Server $script:FixtureServer
        Assert-Offline ($result -eq $true) 'A dead record was not recovered.'
        $record = Read-McpJson -Path (Join-Path $script:FixtureRuntime 'connection.json')
        Assert-Offline ($record.running -eq $false) 'The stale running flag was preserved.'
        Assert-Offline ($record.offlineRecoveredAt -eq '2026-10-02T00:00:00.0000000+00:00') 'Recovery timestamp was not recorded.'
        Assert-Offline ($record.token -eq $script:FakeKey -and $record.projectRoot -eq $script:OriginalConnection.projectRoot) 'Private fields were changed.'
        Assert-Offline (($record.custom.nested -join ',') -eq 'one,two') 'Unknown nested fields were lost.'
        Assert-Offline ([IO.File]::ReadAllText((Join-Path $script:FixtureRuntime 'config.json')) -eq $configBefore) 'Runtime configuration changed.'
        $backups = @(Get-ChildItem -LiteralPath $script:FixtureRuntime -Filter 'connection-before-offline-*.json' | Sort-Object LastWriteTimeUtc)
        Assert-Offline ($backups.Count -eq ($backupBefore + 1)) 'Expected one private backup.'
        Assert-Offline ([IO.File]::ReadAllText($backups[-1].FullName) -eq $connectionBefore) 'Backup differs from the original record.'
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:FixtureRuntime 'connection.json'))
        Assert-Offline (-not ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Recovered JSON has a UTF-8 BOM.'
        Assert-Offline ((Get-Content -LiteralPath (Join-Path $script:FixtureRuntime 'launcher.pid') -Raw).Trim() -eq '123456') 'PID evidence was changed.'
        Assert-Offline ((Get-Content -LiteralPath (Join-Path $script:FixtureRuntime 'launcher.lock') -Raw).Trim() -eq '123456') 'Lock evidence was changed.'
        Assert-Offline ($script:ProcessChecks -ge 2 -and $script:ListenerChecks -ge 2) 'Ownership and port absence were not rechecked.'
    }
    Offline-Test 'NoRecovery refuses stale metadata' { Assert-RecoveryRefused -NoRecovery }
    Offline-Test 'Already stopped metadata is a no-op' {
        $script:OriginalConnection.running = $false
        Write-OfflineJson 'connection.json' $script:OriginalConnection
        $before = [IO.File]::ReadAllText((Join-Path $script:FixtureRuntime 'connection.json'))
        Assert-Offline (-not (Repair-McpOfflineRecord -Server $script:FixtureServer -NoRecovery)) 'Stopped record was changed.'
        Assert-Offline ([IO.File]::ReadAllText((Join-Path $script:FixtureRuntime 'connection.json')) -eq $before) 'Stopped record was rewritten.'
    }
    Offline-Test 'No connection record is a no-op' {
        Remove-Item -LiteralPath (Join-Path $script:FixtureRuntime 'connection.json')
        Assert-Offline (-not (Repair-McpOfflineRecord -Server $script:FixtureServer)) 'Missing record was invented.'
    }
    foreach ($kind in @('Healthy', 'Unhealthy', 'WrongIdentity', 'UnknownService')) {
        Offline-Test ('Local state ' + $kind + ' cannot recover offline metadata') {
            $script:StateKind = $kind
            Assert-RecoveryRefused
        }
    }
    foreach ($name in @('launcher.pid', 'launcher.lock')) {
        Offline-Test ('Missing ' + $name + ' refuses recovery') {
            Remove-Item -LiteralPath (Join-Path $script:FixtureRuntime $name)
            Assert-RecoveryRefused
        }
        foreach ($owner in @('0', '-1', 'not-a-pid', '2147483648', '123456.0')) {
            Offline-Test ('Invalid owner in ' + $name + ': ' + $owner) {
                Set-Content -LiteralPath (Join-Path $script:FixtureRuntime $name) -Value $owner -Encoding ASCII
                Assert-RecoveryRefused
            }
        }
    }
    Offline-Test 'Conflicting recorded owners refuse recovery' {
        Set-Content -LiteralPath (Join-Path $script:FixtureRuntime 'launcher.lock') -Value '123457' -Encoding ASCII
        Assert-RecoveryRefused
    }
    Offline-Test 'An existing or reused process ID refuses recovery' {
        Set-Item Function:script:Test-McpRecordedProcessExists -Value { param($RecordedId); return $true }
        Assert-RecoveryRefused
    }
    Offline-Test 'A configured TCP port listener refuses recovery' {
        Set-Item Function:script:Get-McpTcpListenerPorts -Value { return @(18770) }
        Assert-RecoveryRefused
    }
    Offline-Test 'Ambiguous process inspection refuses recovery' {
        Set-Item Function:script:Test-McpRecordedProcessExists -Value { param($RecordedId); throw 'Process access denied.' }
        Assert-RecoveryRefused
    }
    Offline-Test 'Ambiguous listener inspection refuses recovery' {
        Set-Item Function:script:Get-McpTcpListenerPorts -Value { throw 'Listener access denied.' }
        Assert-RecoveryRefused
    }
    Offline-Test 'Invalid runtime port refuses recovery' {
        $script:OriginalConfig.port = 0
        Write-OfflineJson 'config.json' $script:OriginalConfig
        Assert-RecoveryRefused
    }
    Offline-Test 'Changed launcher evidence during validation refuses recovery' {
        Set-Item Function:script:Test-McpRecordedProcessExists -Value {
            param($RecordedId)
            $script:ProcessChecks++
            if ($script:ProcessChecks -eq 1) {
                Set-Content -LiteralPath (Join-Path $script:FixtureRuntime 'launcher.pid') -Value '123457' -Encoding ASCII
                Set-Content -LiteralPath (Join-Path $script:FixtureRuntime 'launcher.lock') -Value '123457' -Encoding ASCII
            }
            return $false
        }
        Assert-RecoveryRefused
    }
    Offline-Test 'A process appearing during the final check refuses recovery' {
        Set-Item Function:script:Test-McpRecordedProcessExists -Value { param($RecordedId); $script:ProcessChecks++; return ($script:ProcessChecks -gt 1) }
        Assert-RecoveryRefused
    }
    Offline-Test 'A listener appearing during the final check refuses recovery' {
        Set-Item Function:script:Get-McpTcpListenerPorts -Value { $script:ListenerChecks++; if ($script:ListenerChecks -gt 1) { return @(18770) }; return @() }
        Assert-RecoveryRefused
    }
    Offline-Test 'A process access error during the final check preserves stale metadata' {
        Set-Item Function:script:Test-McpRecordedProcessExists -Value {
            param($RecordedId)
            $script:ProcessChecks++
            if ($script:ProcessChecks -gt 1) { throw 'Owner inspection became unavailable.' }
            return $false
        }
        Assert-RecoveryRefused
    }
    Offline-Test 'Unavailable startup reconciles the dead record before using the supported helper' {
        $script:Started = $false
        Set-Item Function:script:Invoke-McpProjectScript -Value {
            param($Server, $Action)
            Assert-Offline ($Action -eq 'Start') 'Offline recovery attempted shutdown.'
            $record = Read-McpJson -Path (Join-Path $script:FixtureRuntime 'connection.json')
            Assert-Offline ($record.running -eq $false) 'Startup preceded metadata recovery.'
            $script:Started = $true
            $script:StateKind = 'Healthy'
            $record.running = $true
            Write-OfflineJson 'connection.json' $record
        }
        Set-Item Function:script:Test-McpPublicHealth -Value { param($Connection); return $true }
        $result = Start-McpServer -Server $script:FixtureServer -TimeoutSeconds 30
        Assert-Offline ($script:Started -and $result.ready -and $result.recovered) 'Recovered startup was not reported.'
    }
    Offline-Test 'Unavailable stale startup with NoRecovery never calls the supported helper' {
        Set-Item Function:script:Invoke-McpProjectScript -Value { throw 'Startup must not be called.' }
        $failed = $false
        try { Start-McpServer -Server $script:FixtureServer -TimeoutSeconds 30 -NoRecovery | Out-Null } catch { $failed = $true }
        Assert-Offline $failed 'NoRecovery accepted stale unavailable startup.'
        $record = Read-McpJson -Path (Join-Path $script:FixtureRuntime 'connection.json')
        Assert-Offline ($record.running -eq $true) 'NoRecovery changed metadata.'
    }
    Write-Output ('Offline recovery checks passed: ' + $script:PassCount + '. Processes, listeners and HTTP are mocked; only private temporary fixtures were changed.')
} finally {
    if (Test-Path -LiteralPath $script:FixtureRoot -PathType Container) {
        $target = Get-Item -LiteralPath $script:FixtureRoot -Force
        Assert-Offline ([IO.Path]::GetFullPath($target.Parent.FullName).TrimEnd('\', '/') -eq $script:TempParent) 'Cleanup parent is not the verified temporary directory.'
        Assert-Offline ($target.Name -eq ('mcp-offline-tests-' + $script:FixtureId)) 'Unexpected fixture directory.'
        Assert-Offline (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Refusing cleanup of a fixture reparse point.'
        Assert-Offline ((Get-Content -LiteralPath (Join-Path $target.FullName '.fixture-owner') -Raw).Trim() -eq $script:FixtureId) 'Fixture ownership marker does not match.'
        $reparseChildren = @(Get-ChildItem -LiteralPath $target.FullName -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
        Assert-Offline ($reparseChildren.Count -eq 0) 'Refusing cleanup of fixture reparse points.'
        Remove-Item -LiteralPath $target.FullName -Recurse -Force
    }
}
