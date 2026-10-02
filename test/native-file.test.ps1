#Requires -Version 5.1
param([string]$CommandsDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ([string]::IsNullOrWhiteSpace($CommandsDirectory)) {
    $CommandsDirectory = Split-Path -Parent $PSScriptRoot
}
$CommandsDirectory = (Resolve-Path -LiteralPath $CommandsDirectory).Path
$script:NativePowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:PassCount = 0
$script:FixtureId = [guid]::NewGuid().ToString('N')
$script:TempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$script:FixtureRoot = Join-Path $script:TempParent ('mcp-native-file-tests-' + $script:FixtureId)
$script:FixtureCommands = Join-Path $script:FixtureRoot 'fixture commands'
$script:ForeignDirectory = Join-Path $script:FixtureRoot 'foreign cwd'
$script:FixtureRuntime = Join-Path $script:FixtureCommands '.runtime'

function Assert-NativeFile($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Native-FileTest([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:PassCount++
    Write-Output ('[PASS] ' + $Name)
}

function Invoke-NativeFile([string]$Path, [string[]]$FileArguments = @()) {
    # Invoke the external executable with -File, never a -Command wrapper.
    # A foreign cwd and spaces in fixture paths exercise script-relative defaults.
    Push-Location -LiteralPath $script:ForeignDirectory
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $captured = @(& $script:NativePowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @FileArguments 2>&1)
        $nativeExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        Pop-Location
    }
    [pscustomobject]@{ ExitCode = $nativeExitCode; Text = ($captured | Out-String) }
}

function Assert-NativeSuccess($Result) {
    Assert-NativeFile ($Result.ExitCode -eq 0) ('Native -File failed with exit ' + $Result.ExitCode + ': ' + $Result.Text)
}

function Write-FixtureJson([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding ASCII
}

function Assert-AllDispatch($Result, [string]$ExpectedMapping, [string]$LabelPrefix) {
    Assert-NativeSuccess $Result
    $logPath = Join-Path $script:FixtureRuntime 'native-dispatch.jsonl'
    $entries = @(Get-Content -LiteralPath $logPath | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-NativeFile ($entries.Count -eq 5) ('Expected one mapping read and exactly four mocked startup calls; got ' + $entries.Count + '. ' + $Result.Text)
    Assert-NativeFile ($entries[0].operation -eq 'ReadMapping') 'Mapping was not read before dispatch.'
    Assert-NativeFile ($entries[0].path -eq $ExpectedMapping) 'The omitted or explicit MappingPath was not preserved.'
    $ids = @('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo')
    for ($index = 0; $index -lt $ids.Count; $index++) {
        $entry = $entries[$index + 1]
        $expectedId = $ids[$index]
        Assert-NativeFile ($entry.operation -eq 'Start') 'Unexpected fixture operation.'
        Assert-NativeFile ($entry.id -eq $expectedId) ('Missing or out-of-order dispatch: ' + $expectedId)
        Assert-NativeFile ($entry.label -eq ($LabelPrefix + $expectedId)) 'The wrong mapping supplied the server definition.'
        Assert-NativeFile ($entry.timeout -eq 7) 'WaitSeconds was not passed to the launcher.'
        Assert-NativeFile $entry.noRecovery 'NoRecovery was not passed to the launcher.'
        Assert-NativeFile ($Result.Text.Contains('[HTTPS READY] ' + $LabelPrefix + $expectedId)) 'A selected server was not reported ready.'
    }
    Assert-NativeFile (@(Select-String -InputObject $Result.Text -Pattern '(?m)^URL: https://fixture-[^\s]+\.invalid/mcp\s*$' -AllMatches).Matches.Count -eq 4) 'Expected four canonical fixture endpoints.'
}

try {
    Assert-NativeFile (Test-Path -LiteralPath $script:NativePowerShell -PathType Leaf) 'Windows PowerShell is required.'
    New-Item -ItemType Directory -Path $script:FixtureRoot | Out-Null
    Set-Content -LiteralPath (Join-Path $script:FixtureRoot '.fixture-owner') -Value $script:FixtureId -Encoding ASCII
    New-Item -ItemType Directory -Path $script:FixtureCommands, $script:ForeignDirectory | Out-Null
    foreach ($name in @('MCP-Commands.ps1', 'Arc-Commands.ps1')) {
        Copy-Item -LiteralPath (Join-Path $CommandsDirectory $name) -Destination (Join-Path $script:FixtureCommands $name)
    }

    $engineProbe = Join-Path $script:FixtureRoot 'engine-probe.ps1'
    Set-Content -LiteralPath $engineProbe -Value '$PSVersionTable.PSVersion.ToString()' -Encoding ASCII
    Native-FileTest 'The external -File runner is Windows PowerShell 5.1' {
        $result = Invoke-NativeFile $engineProbe
        Assert-NativeSuccess $result
        Assert-NativeFile ($result.Text.Trim() -match '^5\.1\.') ('Unexpected engine: ' + $result.Text)
    }

    Native-FileTest 'Actual MCP Help works with default paths from a foreign cwd' {
        $result = Invoke-NativeFile (Join-Path $CommandsDirectory 'MCP-Commands.ps1') @('Help')
        Assert-NativeSuccess $result
        Assert-NativeFile ($result.Text.Contains('Targets: All, Filesystem, Blender, Roblox-Studio, Rojo.')) 'MCP usage was not printed.'
    }
    Native-FileTest 'Actual ARC Help works with default paths from a foreign cwd' {
        $result = Invoke-NativeFile (Join-Path $CommandsDirectory 'Arc-Commands.ps1') @('Help')
        Assert-NativeSuccess $result
        Assert-NativeFile ($result.Text.Contains('Arc-Commands.ps1 Status')) 'ARC usage was not printed.'
    }

    Native-FileTest 'Legacy native launchers return failure for a missing mapping without startup' {
        $missingMapping = Join-Path $script:FixtureRoot 'absent mapping.json'
        foreach ($name in @('Start-MCP.ps1', 'Start-All.ps1', 'Filesystem.ps1', 'Blender.ps1', 'Roblox-Studio.ps1', 'Rojo.ps1')) {
            $result = Invoke-NativeFile (Join-Path $CommandsDirectory $name) @('-NonInteractive', '-ConfigPath', $missingMapping)
            Assert-NativeFile ($result.ExitCode -eq 1) ('A failed native launcher returned success: ' + $name)
            Assert-NativeFile ($result.Text.Contains('[FAILED]')) ('Failure was not explained: ' + $name)
        }
        Assert-NativeFile (-not (Test-Path -LiteralPath $missingMapping)) 'Missing-mapping check created configuration.'
    }

    # Only these isolated helpers can be reached by the copied MCP command.
    # They contain no credentials, network requests or process startup/shutdown.
    $launcherStub = @'
param([switch]$DefineOnly)
$ErrorActionPreference = 'Stop'
if (-not $DefineOnly) { throw 'The fixture launcher only supports definitions.' }
$script:NativeDispatchLog = Join-Path $PSScriptRoot '.runtime\native-dispatch.jsonl'
function Read-McpServerDefinitions {
    param([string]$Path)
    [pscustomobject]@{ operation = 'ReadMapping'; path = [IO.Path]::GetFullPath($Path) } |
        ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $script:NativeDispatchLog -Encoding ASCII
    $definitions = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($definition in $definitions) { $definition }
}
function Start-McpServer {
    param($Server, [int]$TimeoutSeconds, [switch]$NoRecovery)
    [pscustomobject]@{ operation = 'Start'; id = $Server.id; label = $Server.label; timeout = $TimeoutSeconds; noRecovery = [bool]$NoRecovery } |
        ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $script:NativeDispatchLog -Encoding ASCII
    [pscustomobject]@{
        id = $Server.id; label = $Server.label; ready = $true
        serverUrl = ('https://fixture-' + $Server.id.ToLowerInvariant() + '.invalid/mcp')
        connectionFile = Join-Path $Server.projectDirectory '.runtime\connection.json'
    }
}
function Get-McpNow { [DateTimeOffset]::Parse('2026-01-01T00:00:00Z') }
function Invoke-McpProjectScript { throw 'Project actions are forbidden in the native fixture.' }
'@
    Set-Content -LiteralPath (Join-Path $script:FixtureCommands 'Start-MCP.ps1') -Value $launcherStub -Encoding ASCII

    Native-FileTest 'MCP and ARC Help need no runtime config and perform no fixture actions' {
        Assert-NativeFile (-not (Test-Path -LiteralPath $script:FixtureRuntime)) 'Help fixture unexpectedly has runtime configuration.'
        foreach ($name in @('MCP-Commands.ps1', 'Arc-Commands.ps1')) {
            $result = Invoke-NativeFile (Join-Path $script:FixtureCommands $name) @('Help')
            Assert-NativeSuccess $result
            Assert-NativeFile ($result.Text.Contains($name + ' Status')) ('Missing fixture help: ' + $name)
        }
        Assert-NativeFile (-not (Test-Path -LiteralPath $script:FixtureRuntime)) 'Help created runtime state.'
    }

    New-Item -ItemType Directory -Path $script:FixtureRuntime | Out-Null
    $defaultMapping = Join-Path $script:FixtureRuntime 'servers.json'
    $explicitMapping = Join-Path $script:FixtureRoot 'explicit servers.json'
    foreach ($mapping in @(@{ path = $defaultMapping; prefix = 'default-' }, @{ path = $explicitMapping; prefix = 'explicit-' })) {
        $definitions = @('Filesystem', 'Blender', 'Roblox-Studio', 'Rojo' | ForEach-Object {
            [pscustomobject]@{ id = $_; label = ($mapping.prefix + $_); projectDirectory = (Join-Path $script:FixtureRoot ('server-' + $_)) }
        })
        Write-FixtureJson $mapping.path $definitions
    }
    Native-FileTest 'Native Start All resolves the default mapping at the saved script directory' {
        $result = Invoke-NativeFile (Join-Path $script:FixtureCommands 'MCP-Commands.ps1') @('Start', 'All', '-WaitSeconds', '7', '-NoRecovery')
        Assert-AllDispatch $result $defaultMapping 'default-'
    }
    Native-FileTest 'Native Start All preserves an explicit mapping with spaces' {
        Set-Content -LiteralPath (Join-Path $script:FixtureRuntime 'native-dispatch.jsonl') -Value '' -NoNewline -Encoding ASCII
        $result = Invoke-NativeFile (Join-Path $script:FixtureCommands 'MCP-Commands.ps1') @('Start', 'All', '-MappingPath', $explicitMapping, '-WaitSeconds', '7', '-NoRecovery')
        Assert-AllDispatch $result $explicitMapping 'explicit-'
    }

    $rojoProject = Join-Path $script:FixtureRoot 'server-Rojo'
    $rojoRuntime = Join-Path $rojoProject '.runtime'
    New-Item -ItemType Directory -Path $rojoRuntime | Out-Null
    Write-FixtureJson (Join-Path $rojoRuntime 'config.json') ([pscustomobject]@{ projectRoot = 'fixture-configured-project' })
    $defaultProfile = Join-Path $script:FixtureRuntime 'arc-command-settings.json'
    $explicitProfile = Join-Path $script:FixtureRoot 'explicit ARC profile.json'
    foreach ($profile in @(@{ path = $defaultProfile; label = 'default' }, @{ path = $explicitProfile; label = 'explicit' })) {
        $projectRoot = Join-Path $script:FixtureRoot ($profile.label + ' ARC project')
        New-Item -ItemType Directory -Path $projectRoot | Out-Null
        Set-Content -LiteralPath (Join-Path $projectRoot 'default.project.json') -Value '{}' -Encoding ASCII
        $fakeRojo = Join-Path $projectRoot 'fixture-rojo.cmd'
        @('@echo off', 'if not "%~1"=="--version" exit /b 81', ('echo rojo fixture-' + $profile.label), 'exit /b 0') |
            Set-Content -LiteralPath $fakeRojo -Encoding ASCII
        Write-FixtureJson $profile.path ([pscustomobject]@{ projectRoot = $projectRoot; rojoExecutable = $fakeRojo; servePort = 65430 })
    }
    Native-FileTest 'Native ARC Status resolves its default profile from the saved script directory' {
        $result = Invoke-NativeFile (Join-Path $script:FixtureCommands 'Arc-Commands.ps1') @('Status')
        Assert-NativeSuccess $result
        Assert-NativeFile ($result.Text.Contains('Selected project: ' + (Join-Path $script:FixtureRoot 'default ARC project'))) 'Default profile resolved against the wrong directory.'
        Assert-NativeFile ($result.Text.Contains('Selected CLI: rojo fixture-default')) 'Default profile executable was not used.'
        Assert-NativeFile ($result.Text.Contains('Rojo MCP configured project: fixture-configured-project')) 'Status did not read the isolated Rojo config.'
    }
    Native-FileTest 'Native ARC Status preserves an explicit profile with spaces' {
        $result = Invoke-NativeFile (Join-Path $script:FixtureCommands 'Arc-Commands.ps1') @('Status', '-SettingsPath', $explicitProfile)
        Assert-NativeSuccess $result
        Assert-NativeFile ($result.Text.Contains('Selected project: ' + (Join-Path $script:FixtureRoot 'explicit ARC project'))) 'Explicit SettingsPath was ignored.'
        Assert-NativeFile ($result.Text.Contains('Selected CLI: rojo fixture-explicit')) 'Explicit profile executable was not used.'
    }
    Write-Output ('Native -File checks passed: ' + $script:PassCount + '. All startup calls used isolated mocks; no live services or configuration were changed.')
} finally {
    # Delete only the unique directory this test created, after checking its
    # resolved parent, GUID-based name, ownership marker and reparse status.
    if (Test-Path -LiteralPath $script:FixtureRoot -PathType Container) {
        $cleanupTarget = (Get-Item -LiteralPath $script:FixtureRoot -Force)
        $expectedName = 'mcp-native-file-tests-' + $script:FixtureId
        $marker = Join-Path $cleanupTarget.FullName '.fixture-owner'
        $expectedParent = $script:TempParent.TrimEnd('\', '/')
        $safeParent = [IO.Path]::GetFullPath($cleanupTarget.Parent.FullName).TrimEnd('\', '/')
        Assert-NativeFile ($safeParent -eq $expectedParent) 'Refusing cleanup outside the verified temp parent.'
        Assert-NativeFile ($cleanupTarget.Name -eq $expectedName) 'Refusing cleanup of an unexpected directory.'
        Assert-NativeFile (($cleanupTarget.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) 'Refusing cleanup of a reparse point.'
        Assert-NativeFile ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $script:FixtureId) 'Refusing cleanup without the matching fixture owner.'
        $reparseChildren = @(Get-ChildItem -LiteralPath $cleanupTarget.FullName -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
        Assert-NativeFile ($reparseChildren.Count -eq 0) 'Refusing cleanup of fixture reparse points.'
        Remove-Item -LiteralPath $cleanupTarget.FullName -Recurse -Force
    }
}
