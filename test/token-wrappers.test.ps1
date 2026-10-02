#Requires -Version 5.1
param([string]$LauncherPath)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($LauncherPath)) {
    $LauncherPath = Split-Path -Parent $PSScriptRoot
}
$script:WrapperPassCount = 0

function Assert-Wrapper($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Wrapper-Test([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:WrapperPassCount++
    Write-Output ('[PASS] ' + $Name)
}
function Write-WrapperJson([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Invoke-NativeTokenWrapper {
    param([string]$Wrapper, [string[]]$Arguments, [switch]$UseLocalAppDataFallback)
    $wrapperFile = Join-Path $script:WrapperPortableFolder $Wrapper
    Assert-Wrapper (Test-Path -LiteralPath $wrapperFile -PathType Leaf) 'The portable wrapper file is missing.'
    $quotedArguments = @($Arguments | ForEach-Object {
        if ($_ -match '["\r\n&|<>^]') { throw 'The isolated test argument contains unsupported command syntax.' }
        '"' + $_ + '"'
    })
    $command = '"' + $wrapperFile + '" ' + ($quotedArguments -join ' ') + ' <nul'
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $env:ComSpec
    $startInfo.Arguments = '/d /c "' + $command + '"'
    $startInfo.WorkingDirectory = $script:WrapperOtherWorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    # The child sees only isolated token locations; the parent environment is unchanged.
    $startInfo.EnvironmentVariables['LOCALAPPDATA'] = $script:WrapperLocalAppData
    if ($UseLocalAppDataFallback) {
        $startInfo.EnvironmentVariables.Remove('PC_MCP_DATA_DIR')
    } else {
        $startInfo.EnvironmentVariables['PC_MCP_DATA_DIR'] = $script:WrapperCmdDataFolder
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        $started = $process.Start()
        Assert-Wrapper $started 'Native CMD process did not start.'
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            throw 'Native wrapper did not finish within 30 seconds. No process was killed.'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = ($stdoutTask.Result + $stderrTask.Result)
        }
    } finally {
        $process.Dispose()
    }
}
function Assert-WrapperTokenResult($Result, [string]$Value) {
    Assert-Wrapper ($Result.ExitCode -eq 0) 'The native wrapper returned a failure status.'
    $valueLines = @($Result.Output -split '\r?\n' | Where-Object { $_ -ceq $Value })
    Assert-Wrapper ($valueLines.Count -eq 1) 'The native wrapper did not return exactly one expected token/header line.'
    foreach ($otherValue in $script:WrapperFakeKeys.Values) {
        if (-not $Value.Contains($otherValue)) {
            Assert-Wrapper (-not $Result.Output.Contains($otherValue)) 'The wrapper disclosed a different server credential.'
        }
    }
}
function Assert-WrapperFailure($Result) {
    Assert-Wrapper ($Result.ExitCode -eq 1) 'The helper failure status was not retained across pause.'
    foreach ($value in $script:WrapperFakeKeys.Values) {
        Assert-Wrapper (-not $Result.Output.Contains($value)) 'A failed wrapper disclosed a fake credential.'
    }
    Assert-Wrapper (-not $Result.Output.Contains('PRIVATE-FIXTURE-CONTENT')) 'A failed wrapper dumped private fixture contents.'
}

$wrapperFixtureId = [guid]::NewGuid().ToString('N')
$wrapperTempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$wrapperFixtureName = 'mcp-token-wrappers-' + $wrapperFixtureId
$script:WrapperFixtureRoot = Join-Path $wrapperTempParent $wrapperFixtureName
New-Item -ItemType Directory -Path $script:WrapperFixtureRoot | Out-Null
Set-Content -LiteralPath (Join-Path $script:WrapperFixtureRoot '.fixture-owner') -Value $wrapperFixtureId -Encoding ASCII
try {
    $unicodePart = ([char]0x0422).ToString() + ([char]0x0435).ToString() + ([char]0x0441).ToString() + ([char]0x0442).ToString()
    $script:WrapperPortableFolder = Join-Path $script:WrapperFixtureRoot ('portable scripts with spaces ' + $unicodePart)
    $script:WrapperOtherWorkingDirectory = Join-Path $script:WrapperFixtureRoot 'different cwd'
    $script:WrapperLocalAppData = Join-Path $script:WrapperFixtureRoot ('fake Local App Data ' + $unicodePart)
    $script:WrapperCmdDataFolder = Join-Path $script:WrapperFixtureRoot ('fake CMD data ' + $unicodePart)
    foreach ($folder in @($script:WrapperPortableFolder, $script:WrapperOtherWorkingDirectory, $script:WrapperLocalAppData, $script:WrapperCmdDataFolder)) {
        New-Item -ItemType Directory -Path $folder | Out-Null
    }
    foreach ($sourceFile in @(
        'Get-MCP-Token.ps1', 'Get-CMD-MCP-Token.ps1',
        'Token-Filesystem.cmd', 'Token-Blender.cmd', 'Token-Roblox-Studio.cmd', 'Token-Rojo.cmd', 'Token-CMD.cmd'
    )) {
        $sourcePath = Join-Path $LauncherPath $sourceFile
        Assert-Wrapper (Test-Path -LiteralPath $sourcePath -PathType Leaf) ('Required portable file is missing: ' + $sourceFile)
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $script:WrapperPortableFolder $sourceFile)
    }
    $script:WrapperFakeKeys = @{
        'Filesystem' = ('a1' * 32)
        'Blender' = ('b2' * 32)
        'Roblox-Studio' = ('c3' * 32)
        'Rojo' = ('d4' * 32)
        'CMD' = ([Convert]::ToBase64String([byte[]](1..32)).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
        'CMD-Fallback' = ([Convert]::ToBase64String([byte[]](33..64)).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
    }
    $serverParent = Join-Path $script:WrapperFixtureRoot ('fake server roots ' + $unicodePart)
    $definitions = @()
    foreach ($id in @('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo')) {
        $serverFolder = Join-Path $serverParent $id
        $runtimeFolder = Join-Path $serverFolder '.runtime'
        New-Item -ItemType Directory -Path $runtimeFolder -Force | Out-Null
        Write-WrapperJson (Join-Path $runtimeFolder 'config.json') @{ token = $script:WrapperFakeKeys[$id] }
        $definitions += [pscustomobject]@{ id = $id; label = ('Fake ' + $id); projectDirectory = $serverFolder }
    }
    $script:WrapperMappingPath = Join-Path $script:WrapperFixtureRoot ('fake server map ' + $unicodePart + '.json')
    Write-WrapperJson $script:WrapperMappingPath $definitions
    $script:WrapperCmdTokenFile = Join-Path $script:WrapperCmdDataFolder 'token.json'
    Write-WrapperJson $script:WrapperCmdTokenFile @{ version = 1; token = $script:WrapperFakeKeys.CMD }
    $fallbackFolder = Join-Path $script:WrapperLocalAppData 'PcControlMcp'
    New-Item -ItemType Directory -Path $fallbackFolder | Out-Null
    Write-WrapperJson (Join-Path $fallbackFolder 'token.json') @{ version = 1; token = $script:WrapperFakeKeys['CMD-Fallback'] }
    $cmdConfigBefore = (Get-FileHash -LiteralPath $script:WrapperCmdTokenFile -Algorithm SHA256).Hash
    $parentDataDirectoryBefore = $env:PC_MCP_DATA_DIR
    $parentLocalAppDataBefore = $env:LOCALAPPDATA

    foreach ($id in @('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo')) {
        $serverId = $id
        Wrapper-Test ('FR-5: ' + $serverId + ' native wrapper selects its own fake key from another cwd') {
            $result = Invoke-NativeTokenWrapper -Wrapper ('Token-' + $serverId + '.cmd') -Arguments @('-MappingPath', $script:WrapperMappingPath, '-Show')
            Assert-WrapperTokenResult $result $script:WrapperFakeKeys[$serverId]
        }
    }
    Wrapper-Test 'FR-5: native server wrapper forwards Header mode' {
        $result = Invoke-NativeTokenWrapper -Wrapper 'Token-Rojo.cmd' -Arguments @('-MappingPath', $script:WrapperMappingPath, '-Header', '-Show')
        Assert-WrapperTokenResult $result ('Authorization: Bearer ' + $script:WrapperFakeKeys.Rojo)
    }
    Wrapper-Test 'FR-5: missing mapping failure status survives pause' {
        $result = Invoke-NativeTokenWrapper -Wrapper 'Token-Blender.cmd' -Arguments @('-MappingPath', (Join-Path $script:WrapperFixtureRoot 'missing map.json'), '-Show')
        Assert-WrapperFailure $result
    }
    Wrapper-Test 'FR-6: CMD native wrapper accepts an explicit token file with spaces and Unicode' {
        $result = Invoke-NativeTokenWrapper -Wrapper 'Token-CMD.cmd' -Arguments @('-TokenFilePath', $script:WrapperCmdTokenFile, '-Show')
        Assert-WrapperTokenResult $result $script:WrapperFakeKeys.CMD
    }
    Wrapper-Test 'FR-6: CMD native wrapper forwards Header mode' {
        $result = Invoke-NativeTokenWrapper -Wrapper 'Token-CMD.cmd' -Arguments @('-TokenFilePath', $script:WrapperCmdTokenFile, '-Header', '-Show')
        Assert-WrapperTokenResult $result ('Authorization: Bearer ' + $script:WrapperFakeKeys.CMD)
    }
    Wrapper-Test 'FR-6: CMD chooses child-local PC_MCP_DATA_DIR by default' {
        $result = Invoke-NativeTokenWrapper -Wrapper 'Token-CMD.cmd' -Arguments @('-Show')
        Assert-WrapperTokenResult $result $script:WrapperFakeKeys.CMD
    }
    Wrapper-Test 'FR-6: CMD falls back to child-local LOCALAPPDATA when override is absent' {
        $result = Invoke-NativeTokenWrapper -Wrapper 'Token-CMD.cmd' -Arguments @('-Show') -UseLocalAppDataFallback
        Assert-WrapperTokenResult $result $script:WrapperFakeKeys['CMD-Fallback']
    }
    Wrapper-Test 'FR-6: invalid version/token data is rejected without dumping private contents' {
        $invalidPath = Join-Path $script:WrapperFixtureRoot 'invalid CMD token.json'
        foreach ($invalid in @(
            @{ token = $script:WrapperFakeKeys.CMD; private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 2; token = $script:WrapperFakeKeys.CMD; private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 1; private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 1; token = ''; private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 1; token = ('a' * 42); private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 1; token = ('a' * 44); private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 1; token = (('a' * 42) + '='); private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 1; token = ($script:WrapperFakeKeys.CMD + "`r`nX-Injected: yes"); private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 1; token = 123; private = 'PRIVATE-FIXTURE-CONTENT' }
            @{ version = 1; token = @($script:WrapperFakeKeys.CMD); private = 'PRIVATE-FIXTURE-CONTENT' }
        )) {
            Write-WrapperJson $invalidPath $invalid
            $result = Invoke-NativeTokenWrapper -Wrapper 'Token-CMD.cmd' -Arguments @('-TokenFilePath', $invalidPath, '-Show')
            Assert-WrapperFailure $result
        }
    }
    Wrapper-Test 'FR-6: malformed and missing CMD token stores retain failure status without disclosure' {
        $malformedPath = Join-Path $script:WrapperFixtureRoot 'malformed CMD token.json'
        Set-Content -LiteralPath $malformedPath -Value ('{"token":"' + $script:WrapperFakeKeys.CMD + '","private":"PRIVATE-FIXTURE-CONTENT"') -Encoding ASCII
        $result = Invoke-NativeTokenWrapper -Wrapper 'Token-CMD.cmd' -Arguments @('-TokenFilePath', $malformedPath, '-Show')
        Assert-WrapperFailure $result
        $result = Invoke-NativeTokenWrapper -Wrapper 'Token-CMD.cmd' -Arguments @('-TokenFilePath', (Join-Path $script:WrapperFixtureRoot 'missing CMD token.json'), '-Show')
        Assert-WrapperFailure $result
    }
    Wrapper-Test 'NFR-2: native wrapper reads did not rotate fake keys or change parent environment' {
        Assert-Wrapper ((Get-FileHash -LiteralPath $script:WrapperCmdTokenFile -Algorithm SHA256).Hash -ceq $cmdConfigBefore) 'CMD token store was modified.'
        foreach ($definition in $definitions) {
            $config = Get-Content -LiteralPath (Join-Path $definition.projectDirectory '.runtime\config.json') -Raw | ConvertFrom-Json
            Assert-Wrapper ($config.token -ceq $script:WrapperFakeKeys[$definition.id]) 'A server credential was modified.'
        }
        Assert-Wrapper ($env:PC_MCP_DATA_DIR -ceq $parentDataDirectoryBefore) 'Parent PC_MCP_DATA_DIR was changed.'
        Assert-Wrapper ($env:LOCALAPPDATA -ceq $parentLocalAppDataBefore) 'Parent LOCALAPPDATA was changed.'
    }
    Write-Output ('Native token wrapper checks passed: ' + $script:WrapperPassCount + '. Only isolated fake credentials and child-local environments were used; no clipboard or live service was changed.')
} finally {
    $resolvedFixture = (Resolve-Path -LiteralPath $script:WrapperFixtureRoot -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $expectedFixture = [IO.Path]::GetFullPath($script:WrapperFixtureRoot).TrimEnd('\')
    $fixtureItem = Get-Item -LiteralPath $resolvedFixture -Force
    $ownerPath = Join-Path $resolvedFixture '.fixture-owner'
    $ownedFixture = (Test-Path -LiteralPath $ownerPath -PathType Leaf) -and ((Get-Content -LiteralPath $ownerPath -Raw).Trim() -ceq $wrapperFixtureId)
    $insideExpectedParent = ($fixtureItem.Parent.FullName.TrimEnd('\') -ieq $wrapperTempParent) -and ($fixtureItem.Name -ceq $wrapperFixtureName)
    $ordinaryDirectory = -not (($fixtureItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
    if ($resolvedFixture -ieq $expectedFixture -and $insideExpectedParent -and $ownedFixture -and $ordinaryDirectory) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    } else {
        throw 'Fixture cleanup refused because its resolved path or ownership changed.'
    }
}
