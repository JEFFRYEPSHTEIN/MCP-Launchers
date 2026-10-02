param([string]$HelperPath)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($HelperPath)) {
    $HelperPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Get-MCP-Token.ps1'
}
if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    throw 'The token helper must exist before these isolated checks can run.'
}
. $HelperPath -DefineOnly

$script:TokenPassCount = 0
$script:TokenCopied = $null
$script:TokenHosts = @()
Set-Item Function:script:Copy-McpTokenValue -Value {
    param([string]$Value)
    $script:TokenCopied = $Value
}
Set-Item Function:script:Write-Host -Value {
    param([Parameter(ValueFromRemainingArguments = $true)]$Object)
    $script:TokenHosts += ($Object -join ' ')
}

function Assert-Token($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Token-Test([string]$Name, [scriptblock]$Body) {
    $script:TokenCopied = $null
    $script:TokenHosts = @()
    & $Body
    $script:TokenPassCount++
    Write-Output ('[PASS] ' + $Name)
}
function Expect-TokenFailure([scriptblock]$Body) {
    $failed = $false
    $failureText = ''
    try { & $Body | Out-Null } catch { $failed = $true; $failureText = $_.Exception.Message }
    Assert-Token $failed 'Expected input to be refused.'
    foreach ($value in $script:TokenFakeKeys.Values) {
        Assert-Token (-not $failureText.Contains($value)) 'Failure disclosed a fake credential.'
    }
    Assert-Token ($null -eq $script:TokenCopied) 'A failing call changed the clipboard wrapper.'
}
function Write-TokenFixtureJson([string]$Path, $Value) {
    $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding UTF8
}
function Set-TokenFixtureConfiguration($Definition, $Value) {
    $runtimePath = Join-Path $Definition.projectDirectory '.runtime'
    New-Item -ItemType Directory -Path $runtimePath -Force | Out-Null
    Write-TokenFixtureJson -Path (Join-Path $runtimePath 'config.json') -Value $Value
}
function Invoke-TokenNative([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $HelperPath @Arguments 2>&1)
        $nativeCode = $LASTEXITCODE
        return [pscustomobject]@{ ExitCode = $nativeCode; Output = (($output | ForEach-Object { [string]$_ }) -join "`n") }
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

$tokenFixtureId = [guid]::NewGuid().ToString('N')
$tokenTempParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
$tokenFixtureName = 'mcp-token-test-' + $tokenFixtureId
$script:TokenFixtureRoot = Join-Path $tokenTempParent $tokenFixtureName
$tokenOwnerPath = Join-Path $script:TokenFixtureRoot '.fixture-owner'
New-Item -ItemType Directory -Path $script:TokenFixtureRoot | Out-Null
Set-Content -LiteralPath $tokenOwnerPath -Value $tokenFixtureId -Encoding ASCII

try {
    $script:TokenFakeKeys = @{
        'Filesystem' = ('a1' * 32)
        'Blender' = ('b2' * 32)
        'Roblox-Studio' = ('c3' * 32)
        'Rojo' = ('d4' * 32)
    }
    $unicodePart = ([char]0x041F).ToString() + ([char]0x0430).ToString() + ([char]0x043F).ToString() + ([char]0x043A).ToString() + ([char]0x0430).ToString()
    $serverParent = Join-Path $script:TokenFixtureRoot ('servers with spaces ' + $unicodePart)
    $script:TokenDefinitions = @(
        [pscustomobject]@{ id = 'Filesystem'; label = 'Fake Filesystem'; projectDirectory = (Join-Path $serverParent 'filesystem') }
        [pscustomobject]@{ id = 'Blender'; label = 'Fake Blender'; projectDirectory = (Join-Path $serverParent 'blender') }
        [pscustomobject]@{ id = 'Roblox-Studio'; label = 'Fake Studio'; projectDirectory = (Join-Path $serverParent 'studio') }
        [pscustomobject]@{ id = 'Rojo'; label = 'Fake Rojo'; projectDirectory = (Join-Path $serverParent 'rojo') }
    )
    foreach ($definition in $script:TokenDefinitions) {
        New-Item -ItemType Directory -Path $definition.projectDirectory -Force | Out-Null
        Set-TokenFixtureConfiguration $definition @{ token = $script:TokenFakeKeys[$definition.id] }
    }
    $script:TokenMappingPath = Join-Path $script:TokenFixtureRoot 'servers.json'
    Write-TokenFixtureJson $script:TokenMappingPath @($script:TokenDefinitions)
    $programParent = Join-Path $script:TokenFixtureRoot ('programs with spaces ' + $unicodePart)
    New-Item -ItemType Directory -Path $programParent | Out-Null
    $script:TokenPrograms = @{}
    foreach ($leaf in @('blender.exe', 'RobloxStudioBeta.exe', 'rojo.exe', 'node.exe', 'unknown.exe')) {
        $programPath = Join-Path $programParent $leaf
        Set-Content -LiteralPath $programPath -Value '' -Encoding ASCII
        $script:TokenPrograms[$leaf] = $programPath
    }

    Token-Test 'FR-1: known executables resolve one configured server' {
        $expected = @{ 'blender.exe' = 'Blender'; 'RobloxStudioBeta.exe' = 'Roblox-Studio'; 'rojo.exe' = 'Rojo' }
        foreach ($leaf in $expected.Keys) {
            $selected = Resolve-McpTokenServer -Path $script:TokenPrograms[$leaf] -Definitions $script:TokenDefinitions
            Assert-Token ($selected.id -eq $expected[$leaf]) 'An executable selected the wrong server.'
        }
    }
    Token-Test 'FR-1: configured folders and nested files resolve literally' {
        foreach ($definition in $script:TokenDefinitions) {
            $selected = Resolve-McpTokenServer -Path $definition.projectDirectory -Definitions $script:TokenDefinitions
            Assert-Token ($selected.id -eq $definition.id) 'A server folder selected the wrong definition.'
            $nestedFolder = Join-Path $definition.projectDirectory 'nested [literal] folder'
            New-Item -ItemType Directory -Path $nestedFolder | Out-Null
            $nestedFile = Join-Path $nestedFolder ('some file ' + $unicodePart + '.txt')
            Set-Content -LiteralPath $nestedFile -Value 'not a program' -Encoding ASCII
            $selected = Resolve-McpTokenServer -Path $nestedFile -Definitions $script:TokenDefinitions
            Assert-Token ($selected.id -eq $definition.id) 'A literal nested path selected the wrong definition.'
        }
    }
    Token-Test 'FR-1: individual launcher leaf names resolve their matching server' {
        foreach ($definition in $script:TokenDefinitions) {
            foreach ($extension in @('.ps1', '.cmd')) {
                $launcherPath = Join-Path $programParent ($definition.id + $extension)
                Set-Content -LiteralPath $launcherPath -Value 'throw "This supplied file must never run."' -Encoding ASCII
                $selected = Resolve-McpTokenServer -Path $launcherPath -Definitions $script:TokenDefinitions
                Assert-Token ($selected.id -eq $definition.id) 'A launcher selected the wrong server.'
            }
        }
    }
    Token-Test 'FR-1: folder boundary rejects a sibling with the same prefix' {
        $sibling = $script:TokenDefinitions[0].projectDirectory + '-other'
        New-Item -ItemType Directory -Path $sibling | Out-Null
        Expect-TokenFailure { Resolve-McpTokenServer -Path $sibling -Definitions $script:TokenDefinitions }
    }
    Token-Test 'FR-1: longest nested project root wins over its parent' {
        $inner = Join-Path $script:TokenDefinitions[0].projectDirectory 'nested-project'
        New-Item -ItemType Directory -Path $inner | Out-Null
        $definitions = @(
            $script:TokenDefinitions[0]
            [pscustomobject]@{ id = 'Blender'; label = 'Nested'; projectDirectory = $inner }
        )
        $selected = Resolve-McpTokenServer -Path $inner -Definitions $definitions
        Assert-Token ($selected.id -eq 'Blender') 'Longest root was not selected.'
        $selected = Resolve-McpTokenServer -Path $script:TokenDefinitions[0].projectDirectory -Definitions $definitions
        Assert-Token ($selected.id -eq 'Filesystem') 'Parent root was not selected for its own folder.'
    }
    Token-Test 'FR-1: configured folder wins over a misleading executable leaf' {
        $misleadingPath = Join-Path $script:TokenDefinitions[0].projectDirectory 'blender.exe'
        Set-Content -LiteralPath $misleadingPath -Value '' -Encoding ASCII
        $selected = Resolve-McpTokenServer -Path $misleadingPath -Definitions $script:TokenDefinitions
        Assert-Token ($selected.id -eq 'Filesystem') 'Executable leaf overrode configured project ownership.'
    }
    Token-Test 'FR-2: default access copies a token without emitting it' {
        $output = @(Invoke-McpTokenAccess -Path $script:TokenPrograms['blender.exe'] -MappingPath $script:TokenMappingPath)
        Assert-Token ($script:TokenCopied -eq $script:TokenFakeKeys.Blender) 'Default access did not copy the expected value.'
        Assert-Token ($output.Count -eq 0) 'Default access returned a value on stdout.'
        Assert-Token (-not (($script:TokenHosts -join ' ').Contains($script:TokenFakeKeys.Blender))) 'Default status disclosed a credential.'
    }
    Token-Test 'FR-2: Header mode copies one complete Authorization header' {
        $output = @(Invoke-McpTokenAccess -Server 'Rojo' -MappingPath $script:TokenMappingPath -Header)
        Assert-Token ($script:TokenCopied -ceq ('Authorization: Bearer ' + $script:TokenFakeKeys.Rojo)) 'Header mode formatted an incorrect value.'
        Assert-Token ($output.Count -eq 0) 'Header mode disclosed its value on stdout.'
    }
    Token-Test 'FR-2: Show returns a raw token without invoking the clipboard wrapper' {
        $output = @(Invoke-McpTokenAccess -Server 'Roblox-Studio' -MappingPath $script:TokenMappingPath -Show)
        Assert-Token ($output.Count -eq 1 -and $output[0] -ceq $script:TokenFakeKeys['Roblox-Studio']) 'Show returned an unexpected value.'
        Assert-Token ($null -eq $script:TokenCopied) 'Show changed the clipboard wrapper.'
    }
    Token-Test 'FR-2: Show plus Header returns only the formatted header' {
        $output = @(Invoke-McpTokenAccess -Server 'Filesystem' -MappingPath $script:TokenMappingPath -Show -Header)
        Assert-Token ($output.Count -eq 1 -and $output[0] -ceq ('Authorization: Bearer ' + $script:TokenFakeKeys.Filesystem)) 'Show Header returned an unexpected value.'
        Assert-Token ($null -eq $script:TokenCopied) 'Show Header changed the clipboard wrapper.'
    }
    Token-Test 'FR-3: unknown and ambiguous program paths are rejected without an explicit ID' {
        foreach ($leaf in @('node.exe', 'unknown.exe')) {
            Expect-TokenFailure { Invoke-McpTokenAccess -Path $script:TokenPrograms[$leaf] -MappingPath $script:TokenMappingPath -Show }
        }
    }
    Token-Test 'FR-3: explicit ID resolves an ambiguous program path' {
        $output = @(Invoke-McpTokenAccess -Path $script:TokenPrograms['node.exe'] -Server 'Filesystem' -MappingPath $script:TokenMappingPath -Show)
        Assert-Token ($output.Count -eq 1 -and $output[0] -ceq $script:TokenFakeKeys.Filesystem) 'Explicit server did not resolve the ambiguous program.'
    }
    Token-Test 'FR-3: an explicit ID cannot override a different identified program' {
        Expect-TokenFailure { Invoke-McpTokenAccess -Path $script:TokenPrograms['blender.exe'] -Server 'Rojo' -MappingPath $script:TokenMappingPath -Show }
    }
    Token-Test 'FR-3: relative and nonexistent supplied paths fail even with an explicit ID' {
        foreach ($path in @('relative\node.exe', (Join-Path $script:TokenFixtureRoot 'missing.exe'))) {
            Expect-TokenFailure { Invoke-McpTokenAccess -Path $path -Server 'Filesystem' -MappingPath $script:TokenMappingPath -Show }
        }
        Expect-TokenFailure { Resolve-McpTokenServer -Definitions $script:TokenDefinitions }
        Expect-TokenFailure { Resolve-McpTokenServer -Server 'Missing' -Definitions $script:TokenDefinitions }
    }
    Token-Test 'FR-3: duplicate IDs and equally owned directories fail' {
        $duplicateMap = Join-Path $script:TokenFixtureRoot 'duplicate-servers.json'
        Write-TokenFixtureJson $duplicateMap @($script:TokenDefinitions[0], $script:TokenDefinitions[0])
        Expect-TokenFailure { Read-McpTokenMapping -MappingPath $duplicateMap }
        $sameRootDefinitions = @(
            $script:TokenDefinitions[0]
            [pscustomobject]@{ id = 'Blender'; label = 'Same folder'; projectDirectory = $script:TokenDefinitions[0].projectDirectory }
        )
        Expect-TokenFailure { Resolve-McpTokenServer -Path $script:TokenDefinitions[0].projectDirectory -Definitions $sameRootDefinitions }
        $selected = Resolve-McpTokenServer -Path $script:TokenDefinitions[0].projectDirectory -Server 'Blender' -Definitions $sameRootDefinitions
        Assert-Token ($selected.id -eq 'Blender') 'An explicit ID did not disambiguate equal directory ownership.'
    }
    Token-Test 'FR-3: missing and malformed mapping files fail without disclosure' {
        Expect-TokenFailure { Read-McpTokenMapping -MappingPath (Join-Path $script:TokenFixtureRoot 'missing-map.json') }
        $invalidMap = Join-Path $script:TokenFixtureRoot 'invalid-map.json'
        Set-Content -LiteralPath $invalidMap -Value ('{"secret":"' + $script:TokenFakeKeys.Blender) -Encoding ASCII
        Expect-TokenFailure { Read-McpTokenMapping -MappingPath $invalidMap }
    }
    Token-Test 'FR-3: invalid credentials are rejected without disclosure' {
        $definition = $script:TokenDefinitions[0]
        try {
            foreach ($invalid in @(
                @{}
                @{ token = $null }
                @{ token = '' }
                @{ token = '   ' }
                @{ token = 123 }
                @{ token = @('first', 'second') }
                @{ token = @{ secret = 'not-a-string' } }
                @{ token = ($script:TokenFakeKeys.Filesystem + "`r`nX-Injected: yes") }
            )) {
                Set-TokenFixtureConfiguration $definition $invalid
                Expect-TokenFailure { Read-McpBearerToken -Definition $definition }
            }
            $configPath = Join-Path $definition.projectDirectory '.runtime\config.json'
            Set-Content -LiteralPath $configPath -Value ('{"token":"' + $script:TokenFakeKeys.Filesystem) -Encoding ASCII
            Expect-TokenFailure { Read-McpBearerToken -Definition $definition }
            Remove-Item -LiteralPath $configPath
            Expect-TokenFailure { Read-McpBearerToken -Definition $definition }
        } finally {
            Set-TokenFixtureConfiguration $definition @{ token = $script:TokenFakeKeys.Filesystem }
        }
    }
    Token-Test 'NFR-1: a supplied program is never executed' {
        $probeProgram = Join-Path $programParent 'would-write-a-marker.cmd'
        $probeMarker = Join-Path $script:TokenFixtureRoot 'program-was-executed.txt'
        Set-Content -LiteralPath $probeProgram -Value ('@echo executed>"' + $probeMarker + '"') -Encoding ASCII
        $output = @(Invoke-McpTokenAccess -Path $probeProgram -Server 'Filesystem' -MappingPath $script:TokenMappingPath -Show)
        Assert-Token ($output.Count -eq 1 -and $output[0] -ceq $script:TokenFakeKeys.Filesystem) 'Explicit program-path access did not retrieve the token.'
        Assert-Token (-not (Test-Path -LiteralPath $probeMarker)) 'Token retrieval executed the supplied program.'
    }
    Token-Test 'FR-4: Windows PowerShell 5.1 native File accepts an absolute program path with spaces and Unicode' {
        $result = Invoke-TokenNative @('-Path', $script:TokenPrograms['blender.exe'], '-MappingPath', $script:TokenMappingPath, '-Show')
        Assert-Token ($result.ExitCode -eq 0) 'Native File invocation did not succeed.'
        Assert-Token ($result.Output.Trim() -ceq $script:TokenFakeKeys.Blender) 'Native Show did not return exactly the selected fake token.'
    }
    Token-Test 'FR-4: native File accepts a positional program path and explicit Header output' {
        $result = Invoke-TokenNative @($script:TokenPrograms['rojo.exe'], '-MappingPath', $script:TokenMappingPath, '-Show', '-Header')
        Assert-Token ($result.ExitCode -eq 0) 'Native positional File invocation failed.'
        Assert-Token ($result.Output.Trim() -ceq ('Authorization: Bearer ' + $script:TokenFakeKeys.Rojo)) 'Native Header output was incorrect.'
    }
    Token-Test 'FR-4: native File failure returns nonzero without disclosing a token' {
        $result = Invoke-TokenNative @('-Path', $script:TokenPrograms['node.exe'], '-MappingPath', $script:TokenMappingPath, '-Show')
        Assert-Token ($result.ExitCode -eq 1) 'Native invalid input did not return exit code 1.'
        foreach ($value in $script:TokenFakeKeys.Values) {
            Assert-Token (-not $result.Output.Contains($value)) 'Native failure disclosed a fake credential.'
        }
    }
    Token-Test 'FR-4: native DefineOnly requires no private mapping' {
        $result = Invoke-TokenNative @('-MappingPath', (Join-Path $script:TokenFixtureRoot 'missing-map.json'), '-DefineOnly')
        Assert-Token ($result.ExitCode -eq 0) 'DefineOnly unexpectedly read a missing map.'
        Assert-Token ([string]::IsNullOrWhiteSpace($result.Output)) 'DefineOnly emitted unexpected output.'
    }
    Token-Test 'NFR-1: retrieval did not change any fixture credential' {
        foreach ($definition in $script:TokenDefinitions) {
            $value = Read-McpBearerToken -Definition $definition
            Assert-Token ($value -ceq $script:TokenFakeKeys[$definition.id]) 'A credential was modified by retrieval.'
        }
    }
    Write-Output ('Token access checks passed: ' + $script:TokenPassCount + '. Only isolated fake credentials were used; no real clipboard or service was changed.')
} finally {
    $resolvedFixture = (Resolve-Path -LiteralPath $script:TokenFixtureRoot -ErrorAction Stop).ProviderPath.TrimEnd('\')
    $expectedFixture = [System.IO.Path]::GetFullPath($script:TokenFixtureRoot).TrimEnd('\')
    $fixtureItem = Get-Item -LiteralPath $resolvedFixture -Force
    $resolvedOwner = Join-Path $resolvedFixture '.fixture-owner'
    $ownedFixture = (Test-Path -LiteralPath $resolvedOwner -PathType Leaf) -and ((Get-Content -LiteralPath $resolvedOwner -Raw).Trim() -ceq $tokenFixtureId)
    $insideExpectedParent = ($fixtureItem.Parent.FullName.TrimEnd('\') -ieq $tokenTempParent) -and ($fixtureItem.Name -ceq $tokenFixtureName)
    $ordinaryDirectory = -not (($fixtureItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    if ($resolvedFixture -ieq $expectedFixture -and $insideExpectedParent -and $ownedFixture -and $ordinaryDirectory) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    } else {
        throw 'Fixture cleanup refused because its resolved path or ownership changed.'
    }
}
