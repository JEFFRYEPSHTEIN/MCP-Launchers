[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 8765,
    [string]$CloudflaredPath,
    [ValidateRange(10, 120)][int]$StartupTimeoutSeconds = 120,
    [switch]$ShowToken
)

$ErrorActionPreference = 'Stop'
$launcherDirectory = $PSScriptRoot
if (-not $launcherDirectory) { $launcherDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $launcherDirectory 'Common.ps1')
Initialize-PcMcpPaths $launcherDirectory
$newTunnelIdentity = $null
try {
    Enter-PcMcpLock
    $cloudflaredExecutable = Find-PcMcpCloudflared $CloudflaredPath
    $connection = Start-PcMcpLocal $Port
    $oldTunnel = Get-PcMcpField $connection 'tunnel_process'
    if (Test-PcMcpProcessIdentity $oldTunnel) {
        Write-Host '[OK] Reusing the running HTTPS tunnel.'
    }
    else {
        $outputLog = Join-Path $script:PcMcpRuntime 'tunnel-output.log'
        $errorLog = Join-Path $script:PcMcpRuntime 'tunnel-error.log'
        $arguments = @('tunnel', '--url', "http://127.0.0.1:$Port", '--http-host-header', "127.0.0.1:$Port", '--no-autoupdate')
        $process = Start-Process -FilePath $cloudflaredExecutable -ArgumentList $arguments -WorkingDirectory $script:PcMcpRoot -WindowStyle Hidden -RedirectStandardOutput $outputLog -RedirectStandardError $errorLog -PassThru
        $newTunnelIdentity = Get-PcMcpProcessIdentity $process.Id
        $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
        $publicBase = ''
        while (([DateTime]::UtcNow -lt $deadline) -and (Test-PcMcpProcessIdentity $newTunnelIdentity)) {
            foreach ($logPath in @($outputLog, $errorLog)) {
                if (Test-Path -LiteralPath $logPath) {
                    $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
                    if ($logText -and ($logText -match 'https://[a-z0-9-]+\.trycloudflare\.com')) { $publicBase = $Matches[0]; break }
                }
            }
            if ($publicBase) { break }
            Start-Sleep -Milliseconds 300
        }
        if (-not $publicBase) { throw "Cloudflare did not provide an HTTPS URL. See $errorLog" }
        $connection = [ordered]@{
            version = 1
            port = $Port
            endpoint = $publicBase + '/mcp'
            server_process = Get-PcMcpField $connection 'server_process'
            tunnel_process = $newTunnelIdentity
            updated_at = [DateTime]::UtcNow.ToString('o')
        }
        Write-PcMcpConnection $connection
        $newTunnelIdentity = $null
        Write-Host '[OK] Cloudflare has allocated the HTTPS URL.'
    }
    $publicEndpoint = [string](Get-PcMcpField $connection 'endpoint' '')
    $publicHealthUrl = $publicEndpoint -replace '/mcp$', '/health'
    $readyDeadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $publicReady = $false
    Write-Host '[WAIT] Checking that the HTTPS tunnel reaches this server...'
    while ([DateTime]::UtcNow -lt $readyDeadline) {
        try {
            $remoteHealth = Invoke-RestMethod -Uri $publicHealthUrl -TimeoutSec 3 -Method Get
            $expectedServer = Get-PcMcpField $connection 'server_process'
            if (((Get-PcMcpField $remoteHealth 'service' '') -eq 'pc-control-mcp') -and
                ([int](Get-PcMcpField $remoteHealth 'pid' 0) -eq [int](Get-PcMcpField $expectedServer 'pid' 0))) {
                $publicReady = $true
                break
            }
        }
        catch {}
        Start-Sleep -Milliseconds 500
    }
    if (-not $publicReady) { throw 'The tunnel process is running but HTTPS is not reachable yet. Retry Start-Remote.ps1; it will reuse the current tunnel.' }
    Write-Host '[OK] HTTPS tunnel is reachable.'
    Show-PcMcpConnection -IncludeToken:$ShowToken
}
catch {
    if ($null -ne $newTunnelIdentity) { Stop-PcMcpTunnel @{ tunnel_process = $newTunnelIdentity } }
    Write-Error $_
    exit 1
}
finally { Exit-PcMcpLock }
