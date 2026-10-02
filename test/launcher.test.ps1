param([string]$LauncherPath)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
    $LauncherPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Start-MCP.ps1'
}
Set-StrictMode -Version 2.0

# Requirement-driven tests. Every network, process and wait operation is mocked.
. $LauncherPath -DefineOnly
$script:OriginalPublicHealth = ${function:Test-McpPublicHealth}
$script:OriginalLocalState = ${function:Get-McpLocalState}
$script:PassCount = 0
$script:TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('mcp-launcher-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:TestRoot | Out-Null
$script:FakeKey = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

function Assert-Test($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-LauncherTest([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:PassCount++
    Write-Output "[PASS] $Name"
}
function Reset-Scenario {
    $script:Clock = [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')
    $script:Actions = @()
    $script:LocalKinds = @{}
    $script:RemoteReady = @{}
    $script:Connections = @{}
    $script:Hosts = @()
    $script:HealthRequests = @()
    Set-Item Function:script:Get-McpLocalState -Value {
        param($Server)
        $kind = 'Healthy'
        if ($script:LocalKinds.ContainsKey($Server.id)) { $kind = $script:LocalKinds[$Server.id] }
        [pscustomobject]@{ Kind = $kind; Config = [pscustomobject]@{ port = 18770; token = $script:FakeKey } }
    }
    Set-Item Function:script:Get-McpConnection -Value {
        param($Server)
        $script:Connections[$Server.id]
    }
    Set-Item Function:script:Test-McpPublicHealth -Value {
        param($Connection)
        foreach ($id in $script:Connections.Keys) {
            if ($script:Connections[$id].serverUrl -eq $Connection.serverUrl) { return [bool]$script:RemoteReady[$id] }
        }
        return $false
    }
    Set-Item Function:script:Invoke-McpProjectScript -Value {
        param($Server, $Action)
        $script:Actions += ($Server.id + ':' + $Action)
    }
    Set-Item Function:script:Wait-McpPause -Value {
        param($Milliseconds)
        $script:Clock = $script:Clock.AddMilliseconds($Milliseconds)
    }
    Set-Item Function:script:Get-McpNow -Value { $script:Clock }
    Set-Item Function:script:Write-Host -Value {
        param([Parameter(ValueFromRemainingArguments = $true)]$Object, $ForegroundColor, $BackgroundColor, [switch]$NoNewline)
        $script:Hosts += ($Object -join ' ')
    }
}
function New-TestServer([string]$Id) {
    $directory = Join-Path $script:TestRoot $Id
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $baseUrl = 'https://mock-' + $Id.ToLowerInvariant() + '.trycloudflare.com'
    $script:Connections[$Id] = [pscustomobject]@{
        running = $true; baseUrl = $baseUrl; serverUrl = ($baseUrl + '/mcp')
        compatibilityUrl = ($baseUrl + '/' + $script:FakeKey + '/mcp')
        token = $script:FakeKey; startedAt = $script:Clock.ToString('o')
    }
    $script:RemoteReady[$Id] = $true
    [pscustomobject]@{ id = $Id; label = $Id; projectDirectory = $directory; serverIdentity = ('test-' + $Id) }
}

try {
    Invoke-LauncherTest 'PowerShell parser accepts every launcher script' {
        $folder = Split-Path -Parent $LauncherPath
        $scripts = @(Get-ChildItem -LiteralPath $folder -Filter '*.ps1' -File)
        Assert-Test ($scripts.Count -ge 6) 'Expected common launcher and five entry scripts.'
        foreach ($file in $scripts) {
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-Test (@($errors).Count -eq 0) ('Parse failure: ' + $file.Name)
        }
    }

    Invoke-LauncherTest 'Healthy reuse returns canonical current URL without duplicate starts or keys' {
        Reset-Scenario
        $server = New-TestServer 'Rojo'
        $captured = @(Start-McpServer -Server $server -TimeoutSeconds 1 -NoRecovery *>&1)
        $result = @($captured | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['ready'] })[-1]
        Assert-Test $result.ready 'Healthy local and HTTPS endpoint must be ready.'
        Assert-Test ($result.serverUrl -eq $script:Connections.Rojo.serverUrl) 'Returned URL is not the current canonical endpoint.'
        Assert-Test ($script:Actions.Count -eq 0) 'Healthy reuse must not start or stop processes.'
        $text = ($captured | Out-String) + ($script:Hosts -join "`n") + ($result | ConvertTo-Json -Depth 10)
        Assert-Test (-not $text.Contains($script:FakeKey)) 'Ready output disclosed the authentication key or compatibility URL.'
    }

    Invoke-LauncherTest 'Stale HTTPS endpoint is refused, with bounded mocked timeout and no blind recovery' {
        Reset-Scenario
        $server = New-TestServer 'Rojo'
        $script:RemoteReady.Rojo = $false
        $failed = $false
        try { Start-McpServer -Server $server -TimeoutSeconds 1 -NoRecovery | Out-Null } catch { $failed = $true }
        Assert-Test $failed 'Stale HTTPS must not be returned as ready.'
        Assert-Test ($script:Actions.Count -eq 0) 'NoRecovery must preserve running processes.'
        Assert-Test (($script:Clock - [DateTimeOffset]::Parse('2026-01-01T00:00:00Z')).TotalSeconds -ge 1) 'The mocked deadline was not enforced.'
    }

    Invoke-LauncherTest 'Wrong local identity never starts or stops a different service' {
        Reset-Scenario
        $server = New-TestServer 'Rojo'
        $script:LocalKinds.Rojo = 'WrongIdentity'
        $failed = $false
        try { Start-McpServer -Server $server -TimeoutSeconds 1 | Out-Null } catch { $failed = $true }
        Assert-Test $failed 'Wrong server identity must be rejected.'
        Assert-Test ($script:Actions.Count -eq 0) 'A service with another identity was modified.'
    }

    Invoke-LauncherTest 'Unknown authenticated listener and unhealthy NoRecovery state preserve processes' {
        foreach ($kind in @('UnknownService', 'Unhealthy')) {
            Reset-Scenario
            $server = New-TestServer 'Rojo'
            $script:LocalKinds.Rojo = $kind
            $failed = $false
            try { Start-McpServer -Server $server -TimeoutSeconds 1 -NoRecovery | Out-Null } catch { $failed = $true }
            Assert-Test $failed ('Unsafe local state was accepted: ' + $kind)
            Assert-Test ($script:Actions.Count -eq 0) ('NoRecovery modified a process in state ' + $kind)
        }
    }

    Invoke-LauncherTest 'Recovery uses supported stop then start and returns the refreshed domain' {
        Reset-Scenario
        $server = New-TestServer 'Rojo'
        $oldUrl = $script:Connections.Rojo.serverUrl
        $script:RemoteReady.Rojo = $false
        Set-Item Function:script:Invoke-McpProjectScript -Value {
            param($Server, $Action)
            $script:Actions += ($Server.id + ':' + $Action)
            if ($Action -eq 'Stop') {
                $script:LocalKinds[$Server.id] = 'Unavailable'
                $script:Connections[$Server.id].running = $false
            } else {
                $script:LocalKinds[$Server.id] = 'Healthy'
                $script:Connections[$Server.id].running = $true
                $script:Connections[$Server.id].baseUrl = 'https://refreshed-rojo.trycloudflare.com'
                $script:Connections[$Server.id].serverUrl = 'https://refreshed-rojo.trycloudflare.com/mcp'
                $script:RemoteReady[$Server.id] = $true
            }
        }
        $result = Start-McpServer -Server $server -TimeoutSeconds 20
        Assert-Test $result.ready 'Recovered endpoint is not ready.'
        Assert-Test $result.recovered 'Supported recovery was not reported.'
        Assert-Test (($script:Actions -join ',') -eq 'Rojo:Stop,Rojo:Start') 'Recovery was not exactly one supported stop followed by start.'
        Assert-Test ($result.serverUrl -ne $oldUrl -and $result.serverUrl -eq 'https://refreshed-rojo.trycloudflare.com/mcp') 'Recovery returned the old URL.'
    }

    Invoke-LauncherTest 'Unavailable local service cannot certify an old remote endpoint' {
        Reset-Scenario
        $server = New-TestServer 'Rojo'
        $script:LocalKinds.Rojo = 'Unavailable'
        $failed = $false
        try { Start-McpServer -Server $server -TimeoutSeconds 1 -NoRecovery | Out-Null } catch { $failed = $true }
        Assert-Test $failed 'A healthy-looking old endpoint was accepted while the local service was unavailable.'
        Assert-Test (($script:Actions -join ',') -eq 'Rojo:Start') 'Unavailable local service should get one start attempt and no stop.'
    }

    Invoke-LauncherTest 'All mode isolates a failed endpoint and returns the other three results' {
        Reset-Scenario
        $servers = @('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo' | ForEach-Object { New-TestServer $_ })
        $script:RemoteReady.Filesystem = $false
        $results = @(Start-McpSelection -Servers $servers -SelectedId 'All' -TimeoutSeconds 1 -NoRecovery)
        Assert-Test ($results.Count -eq 4) 'All mode did not report each server.'
        Assert-Test (@($results | Where-Object { $_.ready }).Count -eq 3) 'One failure prevented healthy services from being reported.'
        $failed = @($results | Where-Object { $_.id -eq 'Filesystem' })[0]
        Assert-Test (-not $failed.ready -and [bool]$failed.error) 'Failed endpoint has no actionable error.'
        Assert-Test (-not (($results | ConvertTo-Json -Depth 10).Contains($script:FakeKey))) 'All mode disclosed an authentication key.'
    }

    Invoke-LauncherTest 'Public health rejects credential-bearing or mismatched URLs before network access' {
        Reset-Scenario
        Set-Item Function:script:Test-McpPublicHealth -Value $script:OriginalPublicHealth
        Set-Item Function:script:Invoke-RestMethod -Value {
            param($Uri, $TimeoutSec, $ErrorAction)
            $script:HealthRequests += [string]$Uri
            [pscustomobject]@{ ok = $true }
        }
        $server = New-TestServer 'Rojo'
        $clean = $script:Connections.Rojo
        Assert-Test (Test-McpPublicHealth -Connection $clean) 'A valid public /health response was refused.'
        Assert-Test ($script:HealthRequests.Count -eq 1) 'Healthy endpoint should make one HTTP health request.'
        Assert-Test ($script:HealthRequests[0] -eq ($clean.baseUrl + '/health')) 'Health request exposed the secret MCP path.'
        $script:HealthRequests = @()
        foreach ($badUrl in @($clean.compatibilityUrl, 'https://other.trycloudflare.com/mcp', ($clean.serverUrl + '?token=' + $script:FakeKey))) {
            $candidate = [pscustomobject]@{ running = $true; baseUrl = $clean.baseUrl; serverUrl = $badUrl }
            Assert-Test (-not (Test-McpPublicHealth -Connection $candidate)) 'Unsafe URL was accepted as ready.'
        }
        Assert-Test ($script:HealthRequests.Count -eq 0) 'Unsafe URL triggered a health request.'
    }

    Invoke-LauncherTest 'Local identity check authenticates only to the configured loopback port' {
        Reset-Scenario
        Set-Item Function:script:Get-McpLocalState -Value $script:OriginalLocalState
        Set-Item Function:script:Invoke-RestMethod -Value {
            param($Uri, $Headers, $TimeoutSec, $ErrorAction)
            Assert-Test ([string]$Uri -eq 'http://127.0.0.1:18770/_status') 'Local status request used a different address or port.'
            Assert-Test ($Headers.Authorization -eq ('Bearer ' + $script:FakeKey)) 'Local status check did not use the configured key.'
            return $script:LocalResponse
        }
        $server = New-TestServer 'Rojo'
        $runtime = Join-Path $server.projectDirectory '.runtime'
        New-Item -ItemType Directory -Path $runtime -Force | Out-Null
        @{ port = 18770; token = $script:FakeKey } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runtime 'config.json') -Encoding ASCII
        $script:LocalResponse = [pscustomobject]@{ server = $server.serverIdentity; ok = $true }
        Assert-Test ((Get-McpLocalState -Server $server).Kind -eq 'Healthy') 'Expected local identity was not accepted.'
        $script:LocalResponse = [pscustomobject]@{ server = 'another-service'; ok = $true }
        Assert-Test ((Get-McpLocalState -Server $server).Kind -eq 'WrongIdentity') 'Another local service was treated as healthy.'
    }

    Write-Output ("Launcher checks passed: " + $script:PassCount + '. Real services were not started or stopped.')
} finally {
    $fullRoot = [IO.Path]::GetFullPath($script:TestRoot)
    $fullTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($fullRoot.StartsWith($fullTemp, [StringComparison]::OrdinalIgnoreCase) -and ([IO.Path]::GetFileName($fullRoot) -like 'mcp-launcher-tests-*')) {
        Remove-Item -LiteralPath $fullRoot -Recurse -Force
    } else { throw 'Refusing cleanup outside the dedicated temporary test folder.' }
}
