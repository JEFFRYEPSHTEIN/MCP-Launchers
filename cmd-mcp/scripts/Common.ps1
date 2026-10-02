Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-PcMcpPaths {
    param([Parameter(Mandatory = $true)][string]$ScriptDirectory)
    $script:PcMcpRoot = Split-Path -Parent $ScriptDirectory
    if ($env:PC_MCP_DATA_DIR) {
        $script:PcMcpRuntime = [System.IO.Path]::GetFullPath($env:PC_MCP_DATA_DIR)
    }
    elseif ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        throw 'LOCALAPPDATA is unavailable. Run under a Windows user account.'
    }
    else { $script:PcMcpRuntime = Join-Path $env:LOCALAPPDATA 'PcControlMcp' }
    $script:PcMcpConnectionFile = Join-Path $script:PcMcpRuntime 'connection.json'
    $script:PcMcpTokenFile = Join-Path $script:PcMcpRuntime 'token.json'
    New-Item -ItemType Directory -Path $script:PcMcpRuntime -Force | Out-Null
}

function Get-PcMcpField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    }
    else {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}

function Enter-PcMcpLock {
    $script:PcMcpMutex = New-Object System.Threading.Mutex($false, 'Local\PcControlMcpLaunchers')
    $script:PcMcpLockHeld = $false
    try { $script:PcMcpLockHeld = $script:PcMcpMutex.WaitOne(60000) }
    catch [System.Threading.AbandonedMutexException] { $script:PcMcpLockHeld = $true }
    if (-not $script:PcMcpLockHeld) { throw 'Another MCP launcher is busy. Retry shortly.' }
}

function Exit-PcMcpLock {
    if (Get-Variable PcMcpMutex -Scope Script -ErrorAction SilentlyContinue) {
        if ($script:PcMcpLockHeld) { $script:PcMcpMutex.ReleaseMutex() }
        $script:PcMcpMutex.Dispose()
    }
}

function Read-PcMcpConnection {
    $result = $null
    if (Test-Path -LiteralPath $script:PcMcpConnectionFile) {
        $result = Get-Content -LiteralPath $script:PcMcpConnectionFile -Raw | ConvertFrom-Json
    }
    return $result
}

function Write-PcMcpConnection {
    param([Parameter(Mandatory = $true)]$Connection)
    $json = $Connection | ConvertTo-Json -Depth 10
    $temporary = Join-Path $script:PcMcpRuntime ('connection-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $script:PcMcpConnectionFile -Force
}

function Get-PcMcpProcessIdentity {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    # Windows may expose a new PID before its executable path is readable.
    $identityDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ((-not $process.Path) -and ([DateTime]::UtcNow -lt $identityDeadline)) {
        Start-Sleep -Milliseconds 100
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
    }
    if (-not $process.Path) { throw 'Cannot read the new process executable identity.' }
    return [ordered]@{
        pid = $process.Id
        start_time_utc = $process.StartTime.ToUniversalTime().ToString('o')
        executable = $process.Path
    }
}

function Test-PcMcpProcessIdentity {
    param($Identity)
    $matched = $false
    if ($null -ne $Identity) {
        try {
            $targetId = [int](Get-PcMcpField $Identity 'pid' 0)
            $storedTime = Get-PcMcpField $Identity 'start_time_utc' ''
            # PowerShell 7 can deserialize an ISO JSON string as DateTime.
            if ($storedTime -is [DateTime]) { $expectedTime = $storedTime.ToUniversalTime().ToString('o') }
            else { $expectedTime = [string]$storedTime }
            $expectedExecutable = [string](Get-PcMcpField $Identity 'executable' '')
            if (($targetId -gt 0) -and $expectedTime -and $expectedExecutable) {
                $process = Get-Process -Id $targetId -ErrorAction Stop
                $actualTime = $process.StartTime.ToUniversalTime().ToString('o')
                $matched = ($actualTime -eq $expectedTime) -and ($process.Path -eq $expectedExecutable)
            }
        }
        catch { $matched = $false }
    }
    return $matched
}

function Test-PcMcpHealth {
    param([int]$Port, [int]$ExpectedProcessId = 0)
    $healthy = $false
    try {
        $health = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 2 -Method Get
        $healthy = ((Get-PcMcpField $health 'ok' $false) -eq $true) -and ((Get-PcMcpField $health 'service' '') -eq 'pc-control-mcp')
        if ($ExpectedProcessId -gt 0) {
            $healthy = $healthy -and ([int](Get-PcMcpField $health 'pid' 0) -eq $ExpectedProcessId)
        }
    }
    catch { $healthy = $false }
    return $healthy
}

function Get-PcMcpToken {
    if (-not (Test-Path -LiteralPath $script:PcMcpTokenFile)) {
        throw 'Token file is missing. Run Start-Local.ps1 or Start-Remote.ps1 first.'
    }
    $configuration = Get-Content -LiteralPath $script:PcMcpTokenFile -Raw | ConvertFrom-Json
    $secret = [string](Get-PcMcpField $configuration 'token' '')
    if ([string]::IsNullOrWhiteSpace($secret)) { throw 'Token file is invalid.' }
    return $secret
}

function ConvertTo-PcMcpArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]' -and $Value.Length -gt 0) { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Ensure-PcMcpBuild {
    $nodeCommand = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($null -eq $nodeCommand) { throw 'Node.js is missing. Install Node.js 22 LTS or newer.' }
    $script:PcMcpNode = $nodeCommand.Source
    $entryPoint = Join-Path $script:PcMcpRoot 'dist\main.js'
    if (-not (Test-Path -LiteralPath $entryPoint)) {
        $npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
        if ($null -eq $npmCommand) { throw 'npm.cmd is missing. Reinstall Node.js with npm.' }
        Push-Location -LiteralPath $script:PcMcpRoot
        try {
            if (-not (Test-Path -LiteralPath (Join-Path $script:PcMcpRoot 'node_modules'))) {
                if (Test-Path -LiteralPath (Join-Path $script:PcMcpRoot 'package-lock.json')) {
                    & $npmCommand.Source ci
                }
                else { & $npmCommand.Source install }
                if ($LASTEXITCODE -ne 0) { throw 'Dependency installation failed.' }
            }
            & $npmCommand.Source run build
            if ($LASTEXITCODE -ne 0) { throw 'MCP build failed.' }
        }
        finally { Pop-Location }
    }
    if (-not (Test-Path -LiteralPath $entryPoint)) { throw 'dist/main.js was not created.' }
    & $script:PcMcpNode $entryPoint init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'MCP token initialization failed.' }
}

function Stop-PcMcpServer {
    param($Connection)
    $identity = Get-PcMcpField $Connection 'server_process'
    if (Test-PcMcpProcessIdentity $identity) {
        $port = [int](Get-PcMcpField $Connection 'port' 8765)
        $secret = Get-PcMcpToken
        $headers = @{ Authorization = 'Bearer ' + $secret }
        Invoke-RestMethod -Uri "http://127.0.0.1:$port/admin/shutdown" -Method Post -Headers $headers -TimeoutSec 10 | Out-Null
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ((Test-PcMcpProcessIdentity $identity) -and ([DateTime]::UtcNow -lt $deadline)) {
            Start-Sleep -Milliseconds 200
        }
        if (Test-PcMcpProcessIdentity $identity) { throw 'MCP did not finish graceful shutdown. Its process was left running.' }
    }
}

function Stop-PcMcpTunnel {
    param($Connection)
    $identity = Get-PcMcpField $Connection 'tunnel_process'
    if (Test-PcMcpProcessIdentity $identity) {
        $targetId = [int](Get-PcMcpField $identity 'pid' 0)
        Stop-Process -Id $targetId -ErrorAction Stop
    }
}

function Start-PcMcpLocal {
    param([int]$Port)
    $connection = Read-PcMcpConnection
    $identity = Get-PcMcpField $connection 'server_process'
    $savedPort = [int](Get-PcMcpField $connection 'port' $Port)
    if (Test-PcMcpProcessIdentity $identity) {
        if ($savedPort -ne $Port) { throw "MCP is running on port $savedPort. Stop it before changing the port." }
        if (-not (Test-PcMcpHealth $Port ([int](Get-PcMcpField $identity 'pid' 0)))) { throw 'The tracked MCP process is running but unhealthy. Check the local server error log.' }
        Write-Host '[OK] Reusing the running MCP server.'
    }
    else {
        if (Test-PcMcpHealth $Port) { throw 'This port already hosts an untracked MCP server. Stop that server using its own launcher first.' }
        Stop-PcMcpTunnel $connection
        Ensure-PcMcpBuild
        $entryPoint = Join-Path $script:PcMcpRoot 'dist\main.js'
        $arguments = @($entryPoint, 'serve', '--port', [string]$Port) | ForEach-Object { ConvertTo-PcMcpArgument $_ }
        $outputLog = Join-Path $script:PcMcpRuntime 'server-output.log'
        $errorLog = Join-Path $script:PcMcpRuntime 'server-error.log'
        $process = Start-Process -FilePath $script:PcMcpNode -ArgumentList ($arguments -join ' ') -WorkingDirectory $script:PcMcpRoot -WindowStyle Hidden -RedirectStandardOutput $outputLog -RedirectStandardError $errorLog -PassThru
        $identity = Get-PcMcpProcessIdentity $process.Id
        $connection = [ordered]@{
            version = 1
            port = $Port
            endpoint = "http://127.0.0.1:$Port/mcp"
            server_process = $identity
            tunnel_process = $null
            updated_at = [DateTime]::UtcNow.ToString('o')
        }
        Write-PcMcpConnection $connection
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        while (([DateTime]::UtcNow -lt $deadline) -and (Test-PcMcpProcessIdentity $identity) -and (-not (Test-PcMcpHealth $Port $process.Id))) {
            Start-Sleep -Milliseconds 250
        }
        if (-not (Test-PcMcpHealth $Port $process.Id)) { throw "MCP startup failed. See $errorLog" }
        Write-Host '[OK] MCP server is running on localhost.'
    }
    return $connection
}

function Find-PcMcpCloudflared {
    param([string]$RequestedPath)
    $result = $null
    if ($RequestedPath) {
        if (-not (Test-Path -LiteralPath $RequestedPath -PathType Leaf)) { throw 'The supplied cloudflared executable does not exist.' }
        $result = (Resolve-Path -LiteralPath $RequestedPath).Path
    }
    else {
        $command = Get-Command cloudflared.exe -ErrorAction SilentlyContinue
        if ($null -ne $command) { $result = $command.Source }
        else {
            $candidates = @(
                (Join-Path $script:PcMcpRoot 'bin\cloudflared.exe')
            )
            foreach ($candidate in $candidates) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $result = $candidate; break }
            }
        }
    }
    if (-not $result) { throw 'cloudflared.exe is missing. Install it or pass -CloudflaredPath to Start-Remote.ps1.' }
    return $result
}

function Show-PcMcpConnection {
    param([switch]$IncludeToken)
    $connection = Read-PcMcpConnection
    $endpoint = [string](Get-PcMcpField $connection 'endpoint' '')
    if ($endpoint) { Write-Host "MCP URL: $endpoint" }
    else { Write-Host 'MCP is stopped. Start-Remote.ps1 creates an HTTPS URL.' }
    if ($IncludeToken) {
        $secret = Get-PcMcpToken
        Write-Host "Bearer token: $secret"
        Write-Host 'HTTP header: Authorization'
        Write-Host 'HTTP value: Bearer <the token above>'
    }
    else { Write-Host 'Run Show-Connection.ps1 to view the bearer token locally.' }
}
