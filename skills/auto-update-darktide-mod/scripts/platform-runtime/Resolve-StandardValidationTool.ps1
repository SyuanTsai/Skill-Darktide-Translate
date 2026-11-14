[CmdletBinding()]
param(
    [ValidateSet('skillspector', 'skill-validator', 'skill-tools', 'pester')]
    [string] $ToolName,

    [string] $PolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/validation-toolchain.json'),

    [switch] $Install,

    [switch] $ValidatePolicyOnly,

    [string] $InstallRoot,

    [string] $ExpectedGoRuntimeVersion,

    [string] $RunId,

    [ValidateRange(1, 3600)][int] $AcquisitionTimeoutSeconds = 900,

    [string] $GoCommandPath,

    [string] $OutputPath
)

function Initialize-ResolverGitHubApiCredential {
    $namespaceToken = [Environment]::GetEnvironmentVariable('STANDARD_VALIDATION_GITHUB_API_TOKEN', 'Process')
    $fallbackToken = [Environment]::GetEnvironmentVariable('GITHUB_TOKEN', 'Process')
    $capturedToken = if (-not [string]::IsNullOrWhiteSpace($namespaceToken)) {
        [string]$namespaceToken
    }
    elseif (-not [string]::IsNullOrWhiteSpace($fallbackToken)) {
        [string]$fallbackToken
    }
    else {
        $null
    }

    foreach ($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN')) {
        [Environment]::SetEnvironmentVariable($name, [NullString]::Value, [EnvironmentVariableTarget]::Process)
    }
    return $capturedToken
}

$script:ResolverGitHubApiToken = Initialize-ResolverGitHubApiCredential
$ErrorActionPreference = 'Stop'
$script:ResolverProcessReceipts = [Collections.Generic.List[object]]::new()

# Clear the captured credential on every terminating failure, including early
# validation failures of a dot-sourced invocation. A top-level trap keeps every
# function definition at script scope, where the platform runtime verifier
# extracts the Pester validators verbatim.
trap {
    $script:ResolverGitHubApiToken = $null
    break
}

$script:ResolverRunId = if ([string]::IsNullOrWhiteSpace($RunId)) {
    [guid]::NewGuid().ToString('N')
}
else {
    [string]$RunId
}
if ($script:ResolverRunId -notmatch '^[0-9a-f]{32}$') {
    throw 'Resolver RunId must be a lowercase 32-character hexadecimal value.'
}
$script:ResolverResolvedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'", [Globalization.CultureInfo]::InvariantCulture)
$script:ResolverExecutionContext = [ordered]@{
    os = switch ([Environment]::OSVersion.Platform) {
        ([PlatformID]::Win32NT) { 'windows'; break }
        ([PlatformID]::Unix) { 'unix'; break }
        ([PlatformID]::MacOSX) { 'osx'; break }
        default { 'other'; break }
    }
    architecture = if (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITEW6432)) {
        [string]$env:PROCESSOR_ARCHITEW6432
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:PROCESSOR_ARCHITECTURE)) {
        [string]$env:PROCESSOR_ARCHITECTURE
    }
    else {
        'unknown'
    }
}
$script:ResolverExecutionContext.architecture = ([string]$script:ResolverExecutionContext.architecture).ToLowerInvariant()

$trustedSources = [ordered]@{
    'skillspector' = 'NVIDIA/SkillSpector'
    'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    'skill-tools' = 'npm:skill-tools'
    'pester' = 'PowerShellGallery:Pester'
}

$trustedRegistries = [ordered]@{
    'skill-tools' = 'https://registry.npmjs.org/'
}

$trustedPythonIndex = 'https://pypi.org/simple'
$trustedPowerShellRepository = 'https://www.powershellgallery.com/api/v2'
$trustedGoRuntimeSource = 'https://go.dev/dl/?mode=json'
$trustedGoRuntimeVersionRule = 'latest-stable'
$trustedGoTransportEnvironmentNames = @(
    'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY',
    'http_proxy', 'https_proxy', 'all_proxy', 'no_proxy',
    'SSL_CERT_FILE', 'SSL_CERT_DIR', 'REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE'
)

$trustedGoEnvironment = [ordered]@{
    'GOENV' = 'off'
    'GOPROXY' = 'https://proxy.golang.org'
    'GOSUMDB' = 'sum.golang.org'
    'GOPRIVATE' = ''
    'GONOPROXY' = 'none'
    'GONOSUMDB' = 'none'
    'GOINSECURE' = ''
    'GOFLAGS' = ''
    'GOTOOLCHAIN' = 'local'
    'GOWORK' = 'off'
    'CGO_ENABLED' = '0'
}

$trustedGoDistribution = [ordered]@{
    'moduleCacheIsolation' = 'temporary-empty'
    'buildCacheIsolation' = 'temporary-empty'
    'temporaryDirectoryIsolation' = 'temporary-empty'
    'binaryInstallIsolation' = 'run-owned'
    'rejectInheritedModuleCache' = $true
    'rejectInheritedBuildCache' = $true
    'rejectDangerousEnvironment' = $true
    'recordBinaryHash' = $true
}

function Write-ResolverJsonOutput {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Json
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [string]::IsNullOrWhiteSpace($directory) -and
        -not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    try {
        $stream = [System.IO.File]::Open(
            $fullPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
    }
    catch {
        $leafException = $_.Exception
        while ($null -ne $leafException.InnerException) {
            $leafException = $leafException.InnerException
        }
        if ($leafException -is [System.IO.IOException] -and [System.IO.File]::Exists($fullPath)) {
            throw 'writer-error-kind=existing-output; output-file-exists=true'
        }
        throw
    }
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        try {
            $writer.Write($Json)
            $writer.Write([Environment]::NewLine)
            $writer.Flush()
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

$deniedGoEnvironmentNames = @(
    'GOROOT', 'GOTOOLDIR', 'GOPATH', 'GO111MODULE',
    'GOOS', 'GOARCH', 'GOAMD64', 'GO386', 'GOARM', 'GOARM64',
    'GOMIPS', 'GOMIPS64', 'GOPPC64', 'GORISCV64', 'GOWASM',
    'GOCACHEPROG', 'GOAUTH', 'GOVCS', 'GOEXPERIMENT', 'GODEBUG',
    'GO_EXTLINK_ENABLED', 'GCCGO',
    'CC', 'CXX', 'FC', 'AR', 'PKG_CONFIG',
    'CGO_CFLAGS', 'CGO_CPPFLAGS', 'CGO_CXXFLAGS', 'CGO_FFLAGS', 'CGO_LDFLAGS',
    'CGO_CFLAGS_ALLOW', 'CGO_CFLAGS_DISALLOW',
    'CGO_CPPFLAGS_ALLOW', 'CGO_CPPFLAGS_DISALLOW',
    'CGO_CXXFLAGS_ALLOW', 'CGO_CXXFLAGS_DISALLOW',
    'CGO_FFLAGS_ALLOW', 'CGO_FFLAGS_DISALLOW',
    'CGO_LDFLAGS_ALLOW', 'CGO_LDFLAGS_DISALLOW'
)

# Python isolated mode ignores PYTHON* startup configuration, but rejecting the
# variables that can redirect imports or execute startup code makes the trust
# boundary explicit. Do not match every case-insensitive "python*" name here:
# setup-python intentionally publishes benign runner metadata such as
# pythonLocation, Python_ROOT_DIR, and Python3_ROOT_DIR.
$dangerousPythonEnvironmentNames = @(
    'PYTHONPATH', 'PYTHONHOME', 'PYTHONUSERBASE', 'PYTHONEXECUTABLE',
    'PYTHONSTARTUP', 'PYTHONINSPECT', 'PYTHONBREAKPOINT',
    'PYTHONNOUSERSITE', 'PYTHONSAFEPATH', 'PYTHONPLATLIBDIR',
    '_PYTHON_SYSCONFIGDATA_NAME', '__PYVENV_LAUNCHER__',
    'REQUESTS_CA_BUNDLE', 'CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR'
)

function Assert-ExactPropertySet {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($null -eq $Value -or $null -eq $Value.PSObject) {
        throw "JSON object '$Context' is missing."
    }

    $actual = @($Value.PSObject.Properties | ForEach-Object { [string]$_.Name })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "JSON object '$Context' has an invalid property set. Missing='$($missing -join ',')' Unexpected='$($unexpected -join ',')'."
    }
}

function Assert-JsonBoolean {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][bool] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [bool] -or $Value -ne $Expected) {
        throw "JSON property '$Context' must be the boolean '$($Expected.ToString().ToLowerInvariant())'."
    }
}

function Assert-JsonString {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]$Value -cne $Expected) {
        throw "JSON property '$Context' must be the exact string '$Expected'."
    }
}

function Assert-JsonIntegerOne {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $isInteger = $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
    if (-not $isInteger -or [Convert]::ToInt64($Value) -ne 1) {
        throw "JSON property '$Context' must be the integer 1."
    }
}

function Assert-JsonSingleStringArray {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $Expected,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [array]) {
        throw "JSON property '$Context' must be an array."
    }
    $items = @($Value)
    if ($items.Count -ne 1 -or $items[0] -isnot [string] -or [string]$items[0] -cne $Expected) {
        throw "JSON property '$Context' must contain only '$Expected'."
    }
}

function Normalize-RegistryUri {
    param([Parameter(Mandatory = $true)][string] $Value)

    $trimmed = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'Registry URI cannot be empty.'
    }

    try {
        $uri = [Uri]$trimmed
    }
    catch {
        throw "Invalid registry URI '$Value'."
    }

    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -cne 'https') {
        throw "Registry URI must use absolute HTTPS: '$Value'."
    }

    return $uri.AbsoluteUri.TrimEnd('/') + '/'
}

function Get-SkillSpectorApprovedSources {
    param([Parameter(Mandatory = $true)][string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "SkillSpector approved source registry not found: $fullPath"
    }
    $raw = Get-Content -Raw -Encoding UTF8 -LiteralPath $fullPath
    $schemaPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/schemas/skillspector-approved-sources-v1.schema.json'
    if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf) -or -not ($raw | Test-Json -SchemaFile $schemaPath)) {
        throw 'SkillSpector approved source registry violates its strict schema.'
    }
    $registry = $raw | ConvertFrom-Json
    $entryProperties = @($registry.entries.PSObject.Properties)
    $activeProperty = @($entryProperties | Where-Object { $_.Name -ceq [string]$registry.active })
    if ($activeProperty.Count -ne 1) {
        throw "SkillSpector approved source active entry '$($registry.active)' does not exist."
    }

    $bridgePolicyPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'docs/standards/static-parser-host-ownership.json'
    $bridgePolicy = Get-Content -Raw -Encoding UTF8 -LiteralPath $bridgePolicyPath | ConvertFrom-Json
    foreach ($property in $entryProperties) {
        $key = [string]$property.Name
        $entry = $property.Value
        if ([string]$entry.version -cne $key -or
            [string]$entry.releaseTag -cne ('v' + $key) -or
            [string]$entry.wheelFileName -cne ("skillspector-{0}-py3-none-any.whl" -f $key)) {
            throw "SkillSpector approved source entry '$key' has inconsistent version identity."
        }
        if ([string]$entry.parserCorrection -ceq 'powershell-native-command-ownership-v1' -and
            ([string]$entry.version -cne [string]$bridgePolicy.officialScannerVersion -or
             [string]$entry.releaseCommit -cne [string]$bridgePolicy.officialScannerReleaseCommit -or
             [string]$entry.wheelSha256 -cne [string]$bridgePolicy.officialScannerReleaseAssetSha256 -or
             [string]$entry.analyzerSha256 -cne [string]$bridgePolicy.officialAnalyzerSha256)) {
            throw "SkillSpector approved source entry '$key' is not bound to the reviewed PowerShell bridge analyzer."
        }
    }
    $registry | Add-Member -NotePropertyName activeEntry -NotePropertyValue $activeProperty[0].Value
    return $registry
}

function Get-Policy {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Validation toolchain policy not found: $Path"
    }

    $policy = Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    Assert-ExactPropertySet -Value $policy -Expected @(
        'schemaVersion', 'policy', 'sourceTrust', 'resolution', 'tools', 'compatibilityLane'
    ) -Context '$'
    Assert-JsonIntegerOne -Value $policy.schemaVersion -Context '$.schemaVersion'
    Assert-JsonString -Value $policy.policy -Expected 'latest-stable-per-validation-run' -Context '$.policy'

    Assert-ExactPropertySet -Value $policy.sourceTrust -Expected @(
        'enforcement', 'resolver', 'failClosedOnMismatch'
    ) -Context '$.sourceTrust'
    Assert-JsonString -Value $policy.sourceTrust.enforcement -Expected 'exact-approved-source' -Context '$.sourceTrust.enforcement'
    Assert-JsonString -Value $policy.sourceTrust.resolver -Expected 'scripts/Resolve-StandardValidationTool.ps1' -Context '$.sourceTrust.resolver'
    Assert-JsonBoolean -Value $policy.sourceTrust.failClosedOnMismatch -Expected $true -Context '$.sourceTrust.failClosedOnMismatch'

    Assert-ExactPropertySet -Value $policy.resolution -Expected @(
        'resolveAtRunStart', 'freezeForRun', 'recordResolvedVersion',
        'recordResolvedIdentityWhenAvailable', 'allowPrerelease'
    ) -Context '$.resolution'
    Assert-JsonBoolean -Value $policy.resolution.resolveAtRunStart -Expected $true -Context '$.resolution.resolveAtRunStart'
    Assert-JsonBoolean -Value $policy.resolution.freezeForRun -Expected $true -Context '$.resolution.freezeForRun'
    Assert-JsonBoolean -Value $policy.resolution.recordResolvedVersion -Expected $true -Context '$.resolution.recordResolvedVersion'
    Assert-JsonBoolean -Value $policy.resolution.recordResolvedIdentityWhenAvailable -Expected $true -Context '$.resolution.recordResolvedIdentityWhenAvailable'
    Assert-JsonBoolean -Value $policy.resolution.allowPrerelease -Expected $false -Context '$.resolution.allowPrerelease'

    Assert-ExactPropertySet -Value $policy.tools -Expected @(
        'skillspector', 'skill-validator', 'skill-tools', 'pester'
    ) -Context '$.tools'

    foreach ($entry in $trustedSources.GetEnumerator()) {
        $tool = $policy.tools.($entry.Key)
        if ($tool.source -isnot [string] -or [string]$tool.source -cne [string]$entry.Value) {
            throw "Untrusted validation tool source for '$($entry.Key)': '$($tool.source)'. Expected '$($entry.Value)'."
        }
        $expectedChannel = if ([string]$entry.Key -ceq 'skillspector') { 'approved-source-registry' } else { 'latest-stable' }
        if ($tool.channel -isnot [string] -or [string]$tool.channel -cne $expectedChannel) {
            throw "Validation tool '$($entry.Key)' must use string channel '$expectedChannel'."
        }
    }

    foreach ($entry in $trustedRegistries.GetEnumerator()) {
        $tool = $policy.tools.($entry.Key)
        if ($tool.registry -isnot [string]) {
            throw "Validation tool registry for '$($entry.Key)' must be a string."
        }
        $configuredRegistry = Normalize-RegistryUri -Value ([string]$tool.registry)
        $expectedRegistry = Normalize-RegistryUri -Value ([string]$entry.Value)
        if ($configuredRegistry -cne $expectedRegistry) {
            throw "Untrusted package registry for '$($entry.Key)': '$configuredRegistry'. Expected '$expectedRegistry'."
        }
    }

    $skillSpector = $policy.tools.skillspector
    Assert-ExactPropertySet -Value $skillSpector -Expected @(
        'source', 'channel', 'approvedSources', 'releaseVersionRule', 'pythonPackageIndex', 'pythonDistribution'
    ) -Context '$.tools.skillspector'
    Assert-JsonString -Value $skillSpector.approvedSources -Expected 'docs/standards/skillspector-approved-sources.json' -Context '$.tools.skillspector.approvedSources'
    [void](Get-SkillSpectorApprovedSources -Path (Join-Path (Split-Path -Parent $PSScriptRoot) ([string]$skillSpector.approvedSources)))
    Assert-JsonString -Value $skillSpector.releaseVersionRule -Expected 'v-semver-release-only' -Context '$.tools.skillspector.releaseVersionRule'
    if ($skillSpector.pythonPackageIndex -isnot [string]) {
        throw 'SkillSpector pythonPackageIndex must be a string.'
    }
    if ((Normalize-RegistryUri -Value ([string]$skillSpector.pythonPackageIndex)) -cne (Normalize-RegistryUri -Value $trustedPythonIndex)) {
        throw "Untrusted SkillSpector Python package index '$($skillSpector.pythonPackageIndex)'. Expected '$trustedPythonIndex'."
    }
    Assert-ExactPropertySet -Value $skillSpector.pythonDistribution -Expected @(
        'configIsolation', 'environmentOverridePolicy', 'allowedInheritedEnvironment',
        'rejectInheritedPythonEnvironment', 'onlyBinary', 'allowDirectReferences',
        'allowPipOnlineDependencyTraversal', 'allowYanked', 'disableCache',
        'candidateDiscovery', 'requiresPythonPolicy', 'dependencyAcquisition', 'dependencyResolver',
        'installEnvironment', 'interpreterIsolation', 'credentialIsolation',
        'installedMetadataVerification', 'verifyOfflineResolution',
        'installNoIndex', 'requireHashes',
        'recordDependencyClosureHashes'
    ) -Context '$.tools.skillspector.pythonDistribution'
    Assert-JsonString -Value $skillSpector.pythonDistribution.configIsolation -Expected 'os.devnull' -Context '$.tools.skillspector.pythonDistribution.configIsolation'
    Assert-JsonString -Value $skillSpector.pythonDistribution.environmentOverridePolicy -Expected 'deny-by-default' -Context '$.tools.skillspector.pythonDistribution.environmentOverridePolicy'
    Assert-JsonSingleStringArray -Value $skillSpector.pythonDistribution.allowedInheritedEnvironment -Expected 'PIP_INDEX_URL' -Context '$.tools.skillspector.pythonDistribution.allowedInheritedEnvironment'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.rejectInheritedPythonEnvironment -Expected $true -Context '$.tools.skillspector.pythonDistribution.rejectInheritedPythonEnvironment'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.onlyBinary -Expected $true -Context '$.tools.skillspector.pythonDistribution.onlyBinary'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.allowDirectReferences -Expected $false -Context '$.tools.skillspector.pythonDistribution.allowDirectReferences'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.allowPipOnlineDependencyTraversal -Expected $false -Context '$.tools.skillspector.pythonDistribution.allowPipOnlineDependencyTraversal'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.allowYanked -Expected $false -Context '$.tools.skillspector.pythonDistribution.allowYanked'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.disableCache -Expected $true -Context '$.tools.skillspector.pythonDistribution.disableCache'
    Assert-JsonString -Value $skillSpector.pythonDistribution.candidateDiscovery -Expected 'approved-simple-json-lazy' -Context '$.tools.skillspector.pythonDistribution.candidateDiscovery'
    Assert-JsonString -Value $skillSpector.pythonDistribution.requiresPythonPolicy -Expected 'simple-json-wheel-metadata-normalized-specifier-set-current-interpreter' -Context '$.tools.skillspector.pythonDistribution.requiresPythonPolicy'
    Assert-JsonString -Value $skillSpector.pythonDistribution.dependencyAcquisition -Expected 'verified-wheelhouse' -Context '$.tools.skillspector.pythonDistribution.dependencyAcquisition'
    Assert-JsonString -Value $skillSpector.pythonDistribution.dependencyResolver -Expected 'pip-offline-backtracking' -Context '$.tools.skillspector.pythonDistribution.dependencyResolver'
    Assert-JsonString -Value $skillSpector.pythonDistribution.installEnvironment -Expected 'isolated-venv' -Context '$.tools.skillspector.pythonDistribution.installEnvironment'
    Assert-JsonString -Value $skillSpector.pythonDistribution.interpreterIsolation -Expected 'python-isolated-mode' -Context '$.tools.skillspector.pythonDistribution.interpreterIsolation'
    Assert-JsonString -Value $skillSpector.pythonDistribution.credentialIsolation -Expected 'github-token-cleared-before-python' -Context '$.tools.skillspector.pythonDistribution.credentialIsolation'
    Assert-JsonString -Value $skillSpector.pythonDistribution.installedMetadataVerification -Expected 'static-dist-info-metadata' -Context '$.tools.skillspector.pythonDistribution.installedMetadataVerification'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.verifyOfflineResolution -Expected $true -Context '$.tools.skillspector.pythonDistribution.verifyOfflineResolution'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.installNoIndex -Expected $true -Context '$.tools.skillspector.pythonDistribution.installNoIndex'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.requireHashes -Expected $true -Context '$.tools.skillspector.pythonDistribution.requireHashes'
    Assert-JsonBoolean -Value $skillSpector.pythonDistribution.recordDependencyClosureHashes -Expected $true -Context '$.tools.skillspector.pythonDistribution.recordDependencyClosureHashes'

    $skillValidator = $policy.tools.'skill-validator'
    Assert-ExactPropertySet -Value $skillValidator -Expected @(
        'source', 'channel', 'stableVersionRule', 'proxy', 'checksumDatabase', 'goRuntimeVersion', 'goEnvironment', 'goDistribution'
    ) -Context '$.tools.skill-validator'
    Assert-JsonString -Value $skillValidator.stableVersionRule -Expected 'release-semver-only' -Context '$.tools.skill-validator.stableVersionRule'
    Assert-JsonString -Value $skillValidator.goRuntimeVersion -Expected $trustedGoRuntimeVersionRule -Context '$.tools.skill-validator.goRuntimeVersion'
    if ($skillValidator.proxy -isnot [string] -or $skillValidator.checksumDatabase -isnot [string]) {
        throw 'skill-validator proxy and checksumDatabase must be strings.'
    }
    if ([string]$skillValidator.proxy -cne 'https://proxy.golang.org') {
        throw "Untrusted Go module proxy '$($skillValidator.proxy)'. Expected 'https://proxy.golang.org'."
    }
    if ([string]$skillValidator.checksumDatabase -cne 'sum.golang.org') {
        throw "Untrusted Go checksum database '$($skillValidator.checksumDatabase)'. Expected 'sum.golang.org'."
    }
    foreach ($entry in $trustedGoEnvironment.GetEnumerator()) {
        $raw = $skillValidator.goEnvironment.($entry.Key)
        if ($raw -isnot [string]) {
            throw "Go environment policy '$($entry.Key)' must be a string."
        }
        $actual = [string]$raw
        if ($actual -cne [string]$entry.Value) {
            throw "Untrusted Go environment policy for '$($entry.Key)': '$actual'. Expected '$($entry.Value)'."
        }
    }
    Assert-ExactPropertySet -Value $skillValidator.goEnvironment -Expected @($trustedGoEnvironment.Keys) -Context '$.tools.skill-validator.goEnvironment'
    Assert-ExactPropertySet -Value $skillValidator.goDistribution -Expected @($trustedGoDistribution.Keys) -Context '$.tools.skill-validator.goDistribution'
    foreach ($entry in $trustedGoDistribution.GetEnumerator()) {
        if ($entry.Value -is [bool]) {
            Assert-JsonBoolean -Value $skillValidator.goDistribution.($entry.Key) -Expected ([bool]$entry.Value) -Context "$.tools.skill-validator.goDistribution.$($entry.Key)"
        }
        else {
            Assert-JsonString -Value $skillValidator.goDistribution.($entry.Key) -Expected ([string]$entry.Value) -Context "$.tools.skill-validator.goDistribution.$($entry.Key)"
        }
    }

    $skillTools = $policy.tools.'skill-tools'
    Assert-ExactPropertySet -Value $skillTools -Expected @(
        'source', 'registry', 'channel', 'npmDistribution'
    ) -Context '$.tools.skill-tools'
    Assert-ExactPropertySet -Value $skillTools.npmDistribution -Expected @(
        'configIsolation', 'environmentOverridePolicy', 'allowedInheritedEnvironment',
        'dependencyAcquisition', 'installEnvironment', 'ignoreScripts',
        'recordDependencyClosureIntegrity'
    ) -Context '$.tools.skill-tools.npmDistribution'
    Assert-JsonString -Value $skillTools.npmDistribution.configIsolation -Expected 'empty-config-and-workdir' -Context '$.tools.skill-tools.npmDistribution.configIsolation'
    Assert-JsonString -Value $skillTools.npmDistribution.environmentOverridePolicy -Expected 'deny-by-default' -Context '$.tools.skill-tools.npmDistribution.environmentOverridePolicy'
    Assert-JsonSingleStringArray -Value $skillTools.npmDistribution.allowedInheritedEnvironment -Expected 'NPM_CONFIG_REGISTRY' -Context '$.tools.skill-tools.npmDistribution.allowedInheritedEnvironment'
    Assert-JsonString -Value $skillTools.npmDistribution.dependencyAcquisition -Expected 'package-lock' -Context '$.tools.skill-tools.npmDistribution.dependencyAcquisition'
    Assert-JsonString -Value $skillTools.npmDistribution.installEnvironment -Expected 'isolated-prefix' -Context '$.tools.skill-tools.npmDistribution.installEnvironment'
    Assert-JsonBoolean -Value $skillTools.npmDistribution.ignoreScripts -Expected $true -Context '$.tools.skill-tools.npmDistribution.ignoreScripts'
    Assert-JsonBoolean -Value $skillTools.npmDistribution.recordDependencyClosureIntegrity -Expected $true -Context '$.tools.skill-tools.npmDistribution.recordDependencyClosureIntegrity'

    $pester = $policy.tools.pester
    Assert-ExactPropertySet -Value $pester -Expected @('source', 'channel', 'repository', 'approvedPayload') -Context '$.tools.pester'
    Assert-JsonString -Value $pester.repository -Expected $trustedPowerShellRepository -Context '$.tools.pester.repository'
    Assert-ExactPropertySet -Value $pester.approvedPayload -Expected @('version', 'sha256') -Context '$.tools.pester.approvedPayload'
    if ($pester.approvedPayload.version -isnot [string] -or
        [string]$pester.approvedPayload.version -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+$' -or
        $pester.approvedPayload.sha256 -isnot [string] -or
        [string]$pester.approvedPayload.sha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Pester approved payload policy must bind one stable version and lowercase SHA-256.'
    }

    Assert-ExactPropertySet -Value $policy.compatibilityLane -Expected @(
        'mayPinOlderVersion', 'requiresExplicitPurpose', 'mayBeCanonicalReleaseGate'
    ) -Context '$.compatibilityLane'
    Assert-JsonBoolean -Value $policy.compatibilityLane.mayPinOlderVersion -Expected $true -Context '$.compatibilityLane.mayPinOlderVersion'
    Assert-JsonBoolean -Value $policy.compatibilityLane.requiresExplicitPurpose -Expected $true -Context '$.compatibilityLane.requiresExplicitPurpose'
    Assert-JsonBoolean -Value $policy.compatibilityLane.mayBeCanonicalReleaseGate -Expected $false -Context '$.compatibilityLane.mayBeCanonicalReleaseGate'

    return $policy
}

function Assert-Command {
    param([Parameter(Mandatory = $true)][string] $Name)

    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        throw "Required native command '$Name' is unavailable."
    }
    $path = if ($null -ne $command.PSObject.Properties['Path']) { [string]$command.Path } else { [string]$command.Source }
    if ([string]::IsNullOrWhiteSpace($path) -or -not [IO.Path]::IsPathRooted($path)) {
        throw "Required native command '$Name' did not resolve to an absolute application path."
    }
    $resolvedPath = [IO.Path]::GetFullPath($path)
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "Required native command '$Name' does not exist at '$resolvedPath'."
    }
    return $resolvedPath
}

function Assert-NativeCommandPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw "The resolved native command path for '$Name' must be absolute."
    }
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -Force -LiteralPath $resolvedPath -ErrorAction SilentlyContinue
    if ($null -eq $item -or -not $item.PSIsContainer -and
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The resolved native command path for '$Name' must be a regular file: '$resolvedPath'."
    }
    if ($null -eq $item -or -not $item.PSIsContainer) {
        $expectedNames = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            @($Name, "$Name.exe")
        }
        else {
            @($Name)
        }
        $fileName = [IO.Path]::GetFileName($resolvedPath)
        if (@($expectedNames | Where-Object { [string]::Equals([string]$_, $fileName, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
            throw "The resolved native command path for '$Name' has an unexpected file name: '$resolvedPath'."
        }
    }
    if ($null -eq $item -or $item.PSIsContainer) {
        throw "The resolved native command path for '$Name' must be a regular file: '$resolvedPath'."
    }
    return $resolvedPath
}

function Assert-NpmCommand {
    $name = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'npm.cmd' } else { 'npm' }
    return Assert-Command -Name $name
}

function Import-ResolverPlatformRuntime {
    $path=Join-Path $PSScriptRoot 'platform-runtime.psd1'
    $module=Import-Module -Name $path -PassThru -ErrorAction Stop
    if (@($module).Count -ne 1 -or [IO.Path]::GetFullPath($module.ModuleBase) -cne [IO.Path]::GetFullPath($PSScriptRoot)) {
        throw 'Resolver platform runtime did not load from the authority bundle.'
    }
    & $module.ExportedCommands['Assert-PlatformRuntimeInventory'] | Out-Null
    return $module
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [int] $TimeoutSeconds = 0
    )
    $runtime=Import-ResolverPlatformRuntime
    $commandPath=if([IO.Path]::IsPathRooted($Command)){[IO.Path]::GetFullPath($Command)}else{Assert-Command -Name $Command}
    # npm's Windows command file dispatches to its adjacent Node CLI payload.
    if([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and [IO.Path]::GetExtension($commandPath) -ieq '.cmd') {
        if([IO.Path]::GetFileName($commandPath) -ine 'npm.cmd'){throw 'Only the approved npm command shim is supported.'}
        $nodeRoot=[IO.Path]::GetDirectoryName($commandPath)
        $cli=Join-Path $nodeRoot 'node_modules/npm/bin/npm-cli.js'
        if(-not [IO.File]::Exists($cli)){throw 'The npm command shim has no adjacent CLI payload.'}
        $commandPath=Assert-Command -Name 'node'
        $Arguments=@($cli)+$Arguments
    }
    $environment=[Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach($entry in [Environment]::GetEnvironmentVariables().GetEnumerator()){$environment[[string]$entry.Key]=[string]$entry.Value}
    $limit=if($TimeoutSeconds -gt 0){$TimeoutSeconds}else{$AcquisitionTimeoutSeconds}
    if($limit -le 0){$limit=900}
    $result=& $runtime.ExportedCommands['Invoke-PlatformPreparationCommand'] -Command $commandPath -Arguments $Arguments -Environment $environment -WorkingDirectory $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.Path -TimeoutMilliseconds ($limit*1000)
    $script:ResolverProcessReceipts.Add($result.processOwnership)
    if($result.exitCode -ne 0){throw "$commandPath failed with exit code $($result.exitCode): $($result.stderr)"}
    if(-not [string]::IsNullOrWhiteSpace($result.stderr)){Write-Verbose $result.stderr}
    return @($result.stdout -split "`r?`n" | Where-Object {$_ -ne ''})
}

function Initialize-RunOwnedInstallRoot {
    param(
        [string] $Root
    )

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $base = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
            $env:RUNNER_TEMP
        }
        else {
            [IO.Path]::GetTempPath()
        }
        $Root = Join-Path $base 'standard-validation-tools'
    }
    $fullRoot = [IO.Path]::GetFullPath($Root)
    [void](New-Item -ItemType Directory -Path $fullRoot -Force)
    $rootItem = Get-Item -Force -LiteralPath $fullRoot
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Run-owned install root must be a regular directory: '$fullRoot'."
    }
    $runtime=Import-ResolverPlatformRuntime
    return & $runtime.ExportedCommands['Resolve-PlatformPhysicalPath'] -Path $fullRoot
}

function New-RunOwnedInstallDirectory {
    param([string]$Root,[Parameter(Mandatory=$true)][string]$ToolName)
    $fullRoot=Initialize-RunOwnedInstallRoot -Root $Root
    $prefix = if ($ToolName -ceq 'skillspector') { 'ss' } else { $ToolName }
    for ($attempt = 0; $attempt -lt 8; $attempt++) {
        $identifier = [guid]::NewGuid().ToString('N')
        if ($ToolName -ceq 'skillspector') { $identifier = $identifier.Substring(0, 12) }
        $toolRoot = Join-Path $fullRoot ("{0}-{1}" -f $prefix, $identifier)
        if (-not (Test-Path -LiteralPath $toolRoot)) {
            $runtime=Import-ResolverPlatformRuntime
            return & $runtime.ExportedCommands['New-PlatformPrivateRoot'] -Parent $fullRoot -Leaf ([IO.Path]::GetFileName($toolRoot))
        }
    }
    throw "Unable to allocate a unique run-owned install directory under '$fullRoot'."
}

function Assert-PythonWheelInstallPath {
    param(
        [Parameter(Mandatory = $true)][string] $InstallPath,
        [string] $WheelPath
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { return }
    $sitePackages = Join-Path $InstallPath 'venv\Lib\site-packages'
    $probePath = Join-Path $sitePackages (('p' * 96) + '.probe')
    if ($probePath.Length -ge 248) {
        throw "SkillSpector install root leaves insufficient Windows path headroom: $($probePath.Length) characters."
    }
    [void](New-Item -ItemType Directory -Path $sitePackages -Force)
    try {
        [IO.File]::WriteAllText($probePath, 'path-probe', (New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::ReadAllText($probePath) -cne 'path-probe') {
            throw 'SkillSpector install path probe could not be read back.'
        }
    }
    finally {
        if (Test-Path -LiteralPath $probePath) { Remove-Item -LiteralPath $probePath -Force }
    }
    if ([string]::IsNullOrWhiteSpace($WheelPath)) { return }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $archive = [IO.Compression.ZipFile]::OpenRead($WheelPath)
    try {
        foreach ($member in $archive.Entries) {
            $relative = [string]$member.FullName
            if ($relative.StartsWith('/') -or $relative.StartsWith('\') -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or $relative -match '^[A-Za-z]:') {
                throw "SkillSpector wheel contains an unsafe archive path: '$relative'."
            }
            $target = Join-Path $sitePackages ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            if ($target.Length -ge 248) {
                throw "SkillSpector wheel member exceeds safe Windows install path length: $($target.Length) characters: '$relative'."
            }
        }
    }
    finally { $archive.Dispose() }
}

function Assert-PythonWheelhouseInstallPaths {
    param(
        [Parameter(Mandatory = $true)][string] $InstallPath,
        [Parameter(Mandatory = $true)][string] $WheelhousePath,
        [Parameter(Mandatory = $true)] $Manifest
    )
    foreach ($entry in @($Manifest.entries)) {
        Assert-PythonWheelInstallPath -InstallPath $InstallPath `
            -WheelPath (Join-Path $WheelhousePath ([string]$entry.file))
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "File not found for hashing: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-BytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]] $Bytes)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ResolverAsciiCaseFold {
    param([Parameter(Mandatory = $true)][string] $Value)

    $builder = New-Object Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        $code = [int][char]$character
        if ($code -ge 65 -and $code -le 90) { $code += 32 }
        [void]$builder.Append([char]$code)
    }
    return $builder.ToString()
}

function Assert-ResolverSafeRelativePath {
    param([Parameter(Mandatory = $true)][string] $Value)

    if ([string]::IsNullOrEmpty($Value) -or $Value.StartsWith('/') -or $Value.Contains('\') -or
        $Value.Contains(':') -or $Value -match '[\x00-\x1F\x7F]') {
        throw "Installed tool closure contains an unsafe relative path: '$Value'."
    }
    foreach ($segment in $Value.Split('/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.' -or $segment -ceq '..') {
            throw "Installed tool closure contains an unsafe relative path: '$Value'."
        }
    }
    try {
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$utf8.GetBytes($Value)
    }
    catch {
        throw "Installed tool closure contains a non-UTF-8 relative path: '$Value'."
    }
}

function Get-ResolverSymlinkTarget {
    param([Parameter(Mandatory = $true)] $Item)

    foreach ($propertyName in @('LinkTarget', 'Target')) {
        $property = $Item.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $property.Value -is [string] -and
            -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            return [string]$property.Value
        }
    }
    throw "Installed tool closure cannot read the symbolic-link target: $($Item.FullName)"
}

function Get-ResolverSymlinkIdentitySha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Target,
        [Parameter(Mandatory = $true)][string] $ResolvedRelativeTarget
    )

    $canonical = "symbolicLinkTarget=$Target`nresolvedTarget=$ResolvedRelativeTarget`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes($canonical))
        ) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-ResolverSafeUnixSymlinkEntry {
    param(
        [Parameter(Mandatory = $true)] $Item,
        [Parameter(Mandatory = $true)][string] $Root
    )

    # PowerShell on Unix can report a symlink as a non-container item. The
    # resolved target, not PSIsContainer on the link itself, is the
    # authoritative regular-file-or-directory check below.
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Unix) {
        throw "Installed tool closure contains an unsupported reparse point: $($Item.FullName)"
    }
    $target = Get-ResolverSymlinkTarget -Item $Item
    if ($target -match '[\x00-\x1F\x7F]' -or $target.Contains('\') -or $target.Contains(':')) {
        throw "Installed tool closure contains an unsafe symbolic-link target: '$target'."
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $parentFull = [IO.Path]::GetFullPath((Split-Path -Parent $Item.FullName))
    try {
        $targetFull = if ([IO.Path]::IsPathRooted($target)) {
            [IO.Path]::GetFullPath($target)
        }
        else {
            [IO.Path]::GetFullPath((Join-Path $parentFull $target))
        }
    }
    catch {
        throw "Installed tool closure contains an invalid symbolic-link target '$target': $($_.Exception.Message)"
    }
    $comparison = [StringComparison]::Ordinal
    $rootPrefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if ([string]::Equals($targetFull, $rootFull, $comparison) -or
        -not $targetFull.StartsWith($rootPrefix, $comparison)) {
        throw "Installed tool closure symbolic-link target escapes the install root: '$target'."
    }
    $targetItem = Get-Item -Force -LiteralPath $targetFull -ErrorAction Stop
    if ((-not $targetItem.PSIsContainer -and $targetItem -isnot [IO.FileInfo]) -or
        ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Installed tool closure symbolic-link target must be a non-reparse regular file or directory: '$target'."
    }
    $relativeTarget = $targetFull.Substring($rootFull.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $relativeTarget = $relativeTarget.Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
    Assert-ResolverSafeRelativePath -Value $relativeTarget
    return [pscustomobject][ordered]@{
        path = $Item.FullName.Substring($rootFull.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
        sha256 = Get-ResolverSymlinkIdentitySha256 -Target $target -ResolvedRelativeTarget $relativeTarget
    }
}

function Get-ResolverOrderedClosureEntries {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries)

    # The installed tool tree can contain many thousands of files. Keep the
    # canonical ordinal ordering in a native balanced tree instead of scanning
    # the growing PowerShell list once for every insertion.
    $sorted = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($entry in $Entries) {
        if ($null -eq $entry -or [string]::IsNullOrEmpty([string]$entry.path)) {
            throw 'Installed tool closure contains an entry without a path.'
        }
        $path = [string]$entry.path
        if ($sorted.ContainsKey($path)) {
            throw "Installed tool closure contains a duplicate path: '$path'."
        }
        $sorted.Add($path, $entry)
    }
    foreach ($entry in $sorted.Values) { $entry }
}

function Get-ResolverParallelFileHashes {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Paths)

    # Only acquisition opts in. Native delegates do not execute PowerShell on
    # pool threads, and the fixed cap cannot be changed by caller configuration.
    if ($null -eq ('StandardResolverAcquisitionHasherV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Threading.Tasks;

public static class StandardResolverAcquisitionHasherV1
{
    public static string[] Compute(string[] paths)
    {
        var hashes = new string[paths.Length];
        Parallel.For(0, paths.Length,
            new ParallelOptions { MaxDegreeOfParallelism = 4 },
            index =>
            {
                var attributes = File.GetAttributes(paths[index]);
                if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                    throw new IOException("Closure hashing requires a regular non-reparse file: " + paths[index]);
                // Small files must not allocate a large-object buffer per stream.
                using (var stream = new FileStream(paths[index], FileMode.Open,
                    FileAccess.Read, FileShare.Read, 4096, FileOptions.SequentialScan))
                using (var sha = SHA256.Create())
                    hashes[index] = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
            });
        // Parallel.For waits for all tasks and throws on any failure. Never
        // publish an array containing partial results.
        return hashes;
    }
}
'@ -ErrorAction Stop
    }
    return ,([StandardResolverAcquisitionHasherV1]::Compute($Paths))
}

function Get-DirectoryClosureIdentity {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [switch] $ParallelContentHash
    )

    $root = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootItem = Get-Item -Force -LiteralPath $root -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Installed tool closure root must be a regular non-reparse directory: $root"
    }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $ordinalPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $nfcPaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $asciiCasePaths = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $contentPaths = New-Object 'System.Collections.Generic.List[string]'
    $contentEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            # Unix tool/package layouts may expose in-root file or directory
            # symlinks. Keep only their verified target identities inside the
            # signed closure; every other reparse shape remains rejected.
            $symlinkEntry = Get-ResolverSafeUnixSymlinkEntry -Item $item -Root $root
            Assert-ResolverSafeRelativePath -Value ([string]$symlinkEntry.path)
            if (-not $ordinalPaths.Add([string]$symlinkEntry.path)) {
                throw "Installed tool closure contains a duplicate path: '$($symlinkEntry.path)'."
            }
            $nfcSymlinkPath = ([string]$symlinkEntry.path).Normalize([Text.NormalizationForm]::FormC)
            if ($nfcPaths.ContainsKey($nfcSymlinkPath) -and -not [string]::Equals([string]$nfcPaths[$nfcSymlinkPath], [string]$symlinkEntry.path, [StringComparison]::Ordinal)) {
                throw "Installed tool closure contains Unicode-normalization-colliding paths: '$($nfcPaths[$nfcSymlinkPath])' and '$($symlinkEntry.path)'."
            }
            $nfcPaths[$nfcSymlinkPath] = [string]$symlinkEntry.path
            $asciiCaseSymlinkPath = Get-ResolverAsciiCaseFold -Value $nfcSymlinkPath
            if ($asciiCasePaths.ContainsKey($asciiCaseSymlinkPath) -and -not [string]::Equals([string]$asciiCasePaths[$asciiCaseSymlinkPath], [string]$symlinkEntry.path, [StringComparison]::Ordinal)) {
                throw "Installed tool closure contains ASCII-case-colliding paths: '$($asciiCasePaths[$asciiCaseSymlinkPath])' and '$($symlinkEntry.path)'."
            }
            $asciiCasePaths[$asciiCaseSymlinkPath] = [string]$symlinkEntry.path
            [void]$entries.Add($symlinkEntry)
            continue
        }
        # FileSystemInfo from a native inventory need not have the provider's
        # PSIsContainer extended property. Classify the actual filesystem type.
        if ($item -is [IO.DirectoryInfo]) { continue }
        if ($item -isnot [IO.FileInfo]) {
            throw "Installed tool closure contains a non-regular filesystem entry: $($item.FullName)"
        }
        $relative = $item.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $relative = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/').Replace([IO.Path]::AltDirectorySeparatorChar, '/')
        Assert-ResolverSafeRelativePath -Value $relative
        if (-not $ordinalPaths.Add($relative)) {
            throw "Installed tool closure contains a duplicate path: '$relative'."
        }
        $nfc = $relative.Normalize([Text.NormalizationForm]::FormC)
        if ($nfcPaths.ContainsKey($nfc) -and -not [string]::Equals([string]$nfcPaths[$nfc], $relative, [StringComparison]::Ordinal)) {
            throw "Installed tool closure contains Unicode-normalization-colliding paths: '$($nfcPaths[$nfc])' and '$relative'."
        }
        $nfcPaths[$nfc] = $relative
        $asciiCase = Get-ResolverAsciiCaseFold -Value $nfc
        if ($asciiCasePaths.ContainsKey($asciiCase) -and -not [string]::Equals([string]$asciiCasePaths[$asciiCase], $relative, [StringComparison]::Ordinal)) {
            throw "Installed tool closure contains ASCII-case-colliding paths: '$($asciiCasePaths[$asciiCase])' and '$relative'."
        }
        $asciiCasePaths[$asciiCase] = $relative
        $entry = [pscustomobject][ordered]@{
                path = $relative
                sha256 = if ($ParallelContentHash) { $null } else { Get-FileSha256 -Path $item.FullName }
            }
        [void]$entries.Add($entry)
        if ($ParallelContentHash) {
            [void]$contentPaths.Add($item.FullName)
            [void]$contentEntries.Add($entry)
        }
    }
    if ($entries.Count -eq 0) {
        throw "Installed tool directory is empty: $root"
    }
    if ($ParallelContentHash -and $contentPaths.Count -gt 0) {
        # Complete root, reparse, path and collision checks before any regular
        # file content is read. Keep hashes bound to their original inventory.
        $hashes = Get-ResolverParallelFileHashes -Paths $contentPaths.ToArray()
        if ($hashes.Count -ne $contentEntries.Count) { throw 'Installed closure hashing returned an incomplete inventory.' }
        for ($index = 0; $index -lt $hashes.Count; $index++) {
            if ($hashes[$index] -cnotmatch '^[0-9a-f]{64}$') { throw 'Installed closure hashing returned an invalid SHA-256.' }
            $contentEntries[$index].sha256 = $hashes[$index]
        }
    }
    $ordered = @(Get-ResolverOrderedClosureEntries -Entries $entries.ToArray())
    $canonical = ($ordered | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $closureHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    return [ordered]@{
        sha256 = $closureHash
        entries = @($ordered)
    }
}

function Get-ResolverLauncherDigest {
    param([Parameter(Mandatory = $true)] $Launcher)

    $lines = @('launcherType=validation-launcher-v1')
    foreach ($name in @('kind', 'shimPath', 'shimSha256', 'payloadPath', 'payloadSha256', 'runtimePath', 'runtimeSha256')) {
        $propertyValue = if ($Launcher -is [System.Collections.IDictionary]) {
            if ($Launcher.Contains($name)) { $Launcher[$name] } else { $null }
        }
        else {
            $property = $Launcher.PSObject.Properties[$name]
            if ($null -eq $property) { $null } else { $property.Value }
        }
        $value = if ($null -eq $propertyValue) { 'null' } else { [string]$propertyValue }
        $lines += "$name=$value"
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash((New-Object Text.UTF8Encoding($false)).GetBytes(($lines -join "`n") + "`n"))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-DependencyClosureEntriesArray {
    param([AllowNull()] $Closure)

    if ($null -eq $Closure) {
        return ,([object[]]@())
    }
    return ,([object[]]@($Closure.entries))
}

function Get-OrdinalUniqueStrings {
    param([object[]] $Values)

    $result = @()
    foreach ($value in @($Values)) {
        $item = [string]$value
        if ($result -cnotcontains $item) {
            $result += $item
        }
    }
    return $result
}

function Add-ProcessPathValue {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Value
    )

    $separator = [IO.Path]::PathSeparator
    $current = [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    $updated = if ([string]::IsNullOrWhiteSpace($current)) { $Value } else { "$Value$separator$current" }
    [Environment]::SetEnvironmentVariable($Name, $updated, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_ENV)) {
        [IO.File]::AppendAllText($env:GITHUB_ENV, "$Name=$updated$([Environment]::NewLine)", (New-Object Text.UTF8Encoding($false)))
    }
}

function Invoke-IsolatedPythonCommand {
    param(
        [Parameter(Mandatory = $true)][string] $PythonCommand,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [int] $TimeoutSeconds = 0
    )

    return Invoke-CheckedCommand -Command $PythonCommand -Arguments (@('-I') + $Arguments) -TimeoutSeconds $TimeoutSeconds
}

function Get-RemainingAcquisitionSeconds {
    param(
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch] $Stopwatch,
        [Parameter(Mandatory = $true)][int] $LimitSeconds
    )
    $remaining = $LimitSeconds - $Stopwatch.Elapsed.TotalSeconds
    if ($remaining -le 0) { throw "SkillSpector acquisition deadline exceeded after $LimitSeconds seconds." }
    return [int][Math]::Ceiling($remaining)
}

function Wait-CancellableAcquisitionTask {
    param(
        [Parameter(Mandatory = $true)][System.Threading.Tasks.Task] $Task,
        [Parameter(Mandatory = $true)][System.Threading.CancellationToken] $CancellationToken,
        [Parameter(Mandatory = $true)][string] $PendingMessage
    )
    while (-not $Task.IsCompleted) {
        $CancellationToken.ThrowIfCancellationRequested()
        $outcome = [Threading.WaitHandle]::WaitAny(
            [Threading.WaitHandle[]]@(([IAsyncResult]$Task).AsyncWaitHandle, $CancellationToken.WaitHandle), 30000)
        if ($outcome -eq 1) { $CancellationToken.ThrowIfCancellationRequested() }
        if ($outcome -eq [Threading.WaitHandle]::WaitTimeout) { Write-Host $PendingMessage }
    }
    $CancellationToken.ThrowIfCancellationRequested()
}

function Copy-BoundedHttpBody {
    param(
        [Parameter(Mandatory = $true)][IO.Stream] $InputStream,
        [Parameter(Mandatory = $true)][IO.Stream] $OutputStream,
        [Parameter(Mandatory = $true)][System.Threading.CancellationToken] $CancellationToken,
        [Parameter(Mandatory = $true)][long] $MaximumBytes
    )
    $buffer = New-Object byte[] (1024 * 1024)
    $total = 0L
    while ($true) {
        $readTask = $InputStream.ReadAsync($buffer, 0, $buffer.Length, $CancellationToken)
        Wait-CancellableAcquisitionTask -Task $readTask -CancellationToken $CancellationToken `
            -PendingMessage ("SkillSpector HTTP body pending; bytesReceived={0}; cancellationDeadlineActive=true" -f $total)
        $received = $readTask.GetAwaiter().GetResult()
        if ($received -eq 0) { break }
        $total += $received
        if ($total -gt $MaximumBytes) { throw 'SkillSpector HTTP response exceeds the acquisition byte limit.' }
        $OutputStream.Write($buffer, 0, $received)
    }
    return $total
}

function Save-SkillSpectorFailureEvidence {
    param(
        [string] $WorkPath,
        [string] $DestinationPath
    )
    if ([string]::IsNullOrWhiteSpace($WorkPath) -or
        [string]::IsNullOrWhiteSpace($DestinationPath) -or
        -not (Test-Path -LiteralPath $WorkPath -PathType Container)) { return }
    [void](New-Item -ItemType Directory -Path $DestinationPath -Force)
    foreach ($name in @('acquisition-diagnostics.jsonl', 'offline-backtracking-plan.json')) {
        $source = Join-Path $WorkPath $name
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $DestinationPath $name) -Force
        }
    }
    $failureInventoryPath = Join-Path $WorkPath 'candidate-inventory.failure.json'
    $completedInventoryPath = Join-Path $WorkPath 'candidate-inventory.json'
    $saveIncrementalSnapshot = $false
    if (Test-Path -LiteralPath $completedInventoryPath -PathType Leaf) {
            try {
                $inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath $completedInventoryPath | ConvertFrom-Json
                if ([int]$inventory.schemaVersion -ne 1 -or $null -eq $inventory.entries) {
                    throw 'Completed candidate inventory is not a schema 1 inventory.'
                }
                $rejectedCandidates = [object[]]@()
                if ($null -ne $inventory.rejectedCandidates) {
                    $rejectedCandidates = [object[]]@($inventory.rejectedCandidates)
                }
                $diagnostic = [ordered]@{
                    schemaVersion = 1
                    kind = 'diagnostic-only'
                    source = 'completed-candidate-inventory'
                    inventorySha256 = [string]$inventory.inventorySha256
                    entries = @($inventory.entries)
                    rejectedCandidates = $rejectedCandidates
                }
                [IO.File]::WriteAllText((Join-Path $DestinationPath 'candidate-inventory.failure.json'),
                    ($diagnostic | ConvertTo-Json -Depth 64), (New-Object Text.UTF8Encoding($false)))
            }
            catch {
                Copy-Item -LiteralPath $completedInventoryPath -Destination (Join-Path $DestinationPath 'candidate-inventory.unverified.json') -Force
                $saveIncrementalSnapshot = $true
            }
    }
    else { $saveIncrementalSnapshot = $true }
    if ($saveIncrementalSnapshot -and (Test-Path -LiteralPath $failureInventoryPath -PathType Leaf)) {
        try {
            $snapshot = Get-Content -Raw -Encoding UTF8 -LiteralPath $failureInventoryPath | ConvertFrom-Json
            if ([int]$snapshot.schemaVersion -ne 1 -or
                [string]$snapshot.kind -cne 'diagnostic-only' -or $null -eq $snapshot.entries) {
                throw 'Incremental candidate inventory is not a diagnostic-only schema 1 snapshot.'
            }
            Copy-Item -LiteralPath $failureInventoryPath -Destination (Join-Path $DestinationPath 'candidate-inventory.failure.json') -Force
        }
        catch {
            Copy-Item -LiteralPath $failureInventoryPath -Destination (Join-Path $DestinationPath 'candidate-inventory.failure.unverified.json') -Force
        }
    }
}

function Invoke-BoundedGitHubGet {
    param(
        [Parameter(Mandatory = $true)][string] $Uri,
        [Parameter(Mandatory = $true)][hashtable] $Headers,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch] $Stopwatch,
        [Parameter(Mandatory = $true)][int] $LimitSeconds,
        [string] $OutFile
    )

    $remaining = Get-RemainingAcquisitionSeconds -Stopwatch $Stopwatch -LimitSeconds $LimitSeconds
    try {
        $initialUri = [Uri]$Uri
    }
    catch {
        throw "Invalid SkillSpector GitHub URI '$Uri'."
    }
    $isAssetRequest = -not [string]::IsNullOrWhiteSpace($OutFile)
    $initialHostApproved = if ($isAssetRequest) {
        $initialUri.Host -ceq 'github.com' -and
        $initialUri.AbsolutePath -match '^/NVIDIA/SkillSpector/releases/download/v(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))/skillspector-\k<version>-py3-none-any\.whl$'
    }
    else {
        $initialUri.Host -ceq 'api.github.com' -and
        $initialUri.AbsolutePath -match '^/repos/NVIDIA/SkillSpector/(?:releases/tags/v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)|git/ref/tags/v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)|git/tags/[0-9a-f]{40})$'
    }
    if (-not $initialUri.IsAbsoluteUri -or $initialUri.Scheme -cne 'https' -or
        -not $initialUri.IsDefaultPort -or -not [string]::IsNullOrEmpty($initialUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($initialUri.Query) -or -not [string]::IsNullOrEmpty($initialUri.Fragment) -or
        -not $initialHostApproved) {
        throw "Untrusted SkillSpector GitHub request URI '$Uri'."
    }

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $cancellation = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($remaining))
    $request = $null
    $response = $null
    $stream = $null
    $output = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($remaining)
        $requestUri = $initialUri
        for ($redirectCount = 0; $true; $redirectCount++) {
            if ($redirectCount -gt 5) {
                throw 'SkillSpector GitHub acquisition exceeded the redirect limit.'
            }
            if ($null -ne $request) { $request.Dispose(); $request = $null }
            if ($null -ne $response) { $response.Dispose(); $response = $null }
            $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $requestUri)
            $requestHeaders = Get-BoundedGitHubRequestHeaders -Headers $Headers -Uri $requestUri
            foreach ($key in $requestHeaders.Keys) {
                [void]$request.Headers.TryAddWithoutValidation([string]$key, [string]$requestHeaders[$key])
            }
            $headersTask = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token)
            Wait-CancellableAcquisitionTask -Task $headersTask -CancellationToken $cancellation.Token `
                -PendingMessage ("SkillSpector HTTP headers pending from {0}; acquisitionDeadlineActive=true" -f $request.RequestUri.Host)
            $response = $headersTask.GetAwaiter().GetResult()
            if ([int]$response.StatusCode -notin @(301, 302, 303, 307, 308)) { break }

            $location = $response.Headers.Location
            if ($null -eq $location) { throw 'SkillSpector GitHub redirect omitted its Location header.' }
            $nextUri = if ($location.IsAbsoluteUri) { $location } else { [Uri]::new($requestUri, $location) }
            $redirectHostApproved = if ($isAssetRequest) {
                $nextUri.Host -ceq 'github.com' -or $nextUri.Host -match '^[a-z0-9-]+\.githubusercontent\.com$'
            }
            else {
                $nextUri.Host -ceq 'api.github.com'
            }
            if ($nextUri.Scheme -cne 'https' -or -not $nextUri.IsDefaultPort -or
                -not [string]::IsNullOrEmpty($nextUri.UserInfo) -or -not $redirectHostApproved) {
                throw "SkillSpector download redirected to an unapproved host: $($nextUri.Host)."
            }
            $requestUri = $nextUri
        }
        [void]$response.EnsureSuccessStatusCode()
        $finalUri = $response.RequestMessage.RequestUri
        $allowedHost = if ([string]::IsNullOrWhiteSpace($OutFile)) {
            $finalUri.Host -ceq 'api.github.com'
        }
        else {
            $finalUri.Host -ceq 'github.com' -or $finalUri.Host -match '^[a-z0-9-]+\.githubusercontent\.com$'
        }
        if ($finalUri.Scheme -cne 'https' -or -not $allowedHost) {
            throw "SkillSpector download redirected to an unapproved host: $($finalUri.Host)."
        }
        $maximum = if ([string]::IsNullOrWhiteSpace($OutFile)) { 8 * 1024 * 1024 } else { 512 * 1024 * 1024 }
        if ($response.Content.Headers.ContentLength -gt $maximum) {
            throw 'SkillSpector HTTP response exceeds the acquisition byte limit.'
        }
        $streamTask = $response.Content.ReadAsStreamAsync()
        Wait-CancellableAcquisitionTask -Task $streamTask -CancellationToken $cancellation.Token `
            -PendingMessage ("SkillSpector HTTP stream pending from {0}; acquisitionDeadlineActive=true" -f $request.RequestUri.Host)
        $stream = $streamTask.GetAwaiter().GetResult()
        $output = if ([string]::IsNullOrWhiteSpace($OutFile)) {
            New-Object System.IO.MemoryStream
        }
        else {
            [IO.File]::Open($OutFile, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        }
        [void](Copy-BoundedHttpBody -InputStream $stream -OutputStream $output -CancellationToken $cancellation.Token -MaximumBytes $maximum)
        if (-not [string]::IsNullOrWhiteSpace($OutFile)) { return $OutFile }
        return ([Text.Encoding]::UTF8.GetString($output.ToArray()) | ConvertFrom-Json)
    }
    catch [System.OperationCanceledException] {
        throw "SkillSpector HTTP acquisition deadline exceeded after $LimitSeconds seconds."
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        $cancellation.Dispose()
        $client.Dispose()
        $handler.Dispose()
    }
}

function Get-GitHubHeaders {
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'SyuanTsai-AI-Instructions-validation-tool-resolver'
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ResolverGitHubApiToken)) {
        $headers['Authorization'] = "Bearer $script:ResolverGitHubApiToken"
    }
    return $headers
}

function Get-BoundedGitHubRequestHeaders {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Headers,
        [Parameter(Mandatory = $true)][Uri] $Uri
    )

    $requestHeaders = @{}
    foreach ($key in $Headers.Keys) {
        if ([string]$key -ieq 'Authorization' -and $Uri.Host -cne 'api.github.com') { continue }
        $requestHeaders[[string]$key] = [string]$Headers[$key]
    }
    return $requestHeaders
}

function Protect-ResolverDiagnosticText {
    param(
        [AllowEmptyString()][string] $Text,
        [AllowNull()][string] $Credential
    )

    $safeText = if ($null -eq $Text) { '' } else { [string]$Text }
    if (-not [string]::IsNullOrEmpty($Credential)) {
        $safeText = $safeText.Replace($Credential, '<redacted-credential>')
    }
    $safeText = [regex]::Replace($safeText, '(?i)\b(?:https?|file|git\+https?)://\S+', '<redacted-url>')
    return [regex]::Replace($safeText, '(?i)\b(?:authorization|token|password|secret)\s*[:=]\s*\S+', '<redacted-credential>')
}

function Get-ApprovedSkillSpectorAssetUri {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Tag,
        [Parameter(Mandatory = $true)][string] $FileName
    )

    try {
        $uri = [Uri]$Value
    }
    catch {
        throw "Invalid SkillSpector release asset URI '$Value'."
    }
    $expectedPath = "/NVIDIA/SkillSpector/releases/download/$Tag/$FileName"
    if (-not $uri.IsAbsoluteUri -or
        $uri.Scheme -cne 'https' -or
        $uri.Host -cne 'github.com' -or
        -not $uri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment) -or
        $uri.AbsolutePath -cne $expectedPath) {
        throw "Untrusted SkillSpector release asset URI '$Value'. Expected 'https://github.com$expectedPath'."
    }
    return $uri.AbsoluteUri
}

function Test-StableGoModuleVersion {
    param([Parameter(Mandatory = $true)][string] $Version)

    return $Version -match '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$'
}

function Test-StableNpmPackageVersion {
    param([Parameter(Mandatory = $true)][string] $Version)

    return $Version -cmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:\+[0-9A-Za-z.-]+)?$'
}

function Normalize-PythonPackageName {
    param([Parameter(Mandatory = $true)][string] $Name)

    return (($Name.Trim().ToLowerInvariant()) -replace '[-_.]+', '-')
}

function ConvertFrom-PythonMetadataText {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][string] $Context
    )

    $normalizedText = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    $headerBoundary = $normalizedText.IndexOf("`n`n", [StringComparison]::Ordinal)
    $headerText = if ($headerBoundary -ge 0) { $normalizedText.Substring(0, $headerBoundary) } else { $normalizedText }
    $unfoldedHeaders = [regex]::Replace($headerText, "\n[ `t]+", ' ')
    $nameMatches = @([regex]::Matches($unfoldedHeaders, '(?im)^Name:[ \t]*([^\n]+?)[ \t]*$'))
    $versionMatches = @([regex]::Matches($unfoldedHeaders, '(?im)^Version:[ \t]*([^\n]+?)[ \t]*$'))
    if ($nameMatches.Count -ne 1 -or $versionMatches.Count -ne 1) {
        throw "$Context must contain exactly one Name field and one Version field in its metadata header section. Found Name=$($nameMatches.Count), Version=$($versionMatches.Count)."
    }

    $name = $nameMatches[0].Groups[1].Value.Trim()
    $version = $versionMatches[0].Groups[1].Value.Trim()
    $normalizedName = Normalize-PythonPackageName -Name $name
    if ($normalizedName -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
        throw "$Context contains an unsafe Python distribution Name '$name'."
    }
    if ($version -notmatch '^[0-9A-Za-z][0-9A-Za-z._+!-]*$') {
        throw "$Context contains an unsafe Python distribution Version '$version'."
    }

    $requiresDist = @([regex]::Matches($unfoldedHeaders, '(?im)^Requires-Dist:[ \t]*([^\r\n]+?)[ \t]*\r?$') | ForEach-Object {
        $_.Groups[1].Value.Trim()
    })

    return [ordered]@{
        name = $name
        normalizedName = $normalizedName
        version = $version
        requiresDist = $requiresDist
    }
}

function Get-PythonWheelMetadata {
    param([Parameter(Mandatory = $true)][string] $WheelPath)

    if (-not (Test-Path -LiteralPath $WheelPath -PathType Leaf)) {
        throw "Python wheel not found: $WheelPath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($WheelPath)
    try {
        $metadataEntries = @($archive.Entries | Where-Object { $_.FullName -match '[^/]+\.dist-info/METADATA$' })
        if ($metadataEntries.Count -ne 1) {
            throw "Expected exactly one dist-info/METADATA entry in '$WheelPath'; found $($metadataEntries.Count)."
        }

        $stream = $metadataEntries[0].Open()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
        try {
            $text = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
            $stream.Dispose()
        }

        return ConvertFrom-PythonMetadataText -Text $text -Context "Wheel METADATA in '$WheelPath'"
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PythonWheelEntrySha256 {
    param(
        [Parameter(Mandatory = $true)][string] $WheelPath,
        [Parameter(Mandatory = $true)][string] $EntryPath
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($WheelPath)
    try {
        $entries = @($archive.Entries | Where-Object { $_.FullName -ceq $EntryPath })
        if ($entries.Count -ne 1) {
            throw "Expected exactly one '$EntryPath' entry in SkillSpector wheel; found $($entries.Count)."
        }
        $stream = $entries[0].Open()
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
        }
        finally {
            $sha.Dispose()
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-PythonConsoleEntryPoint {
    param(
        [Parameter(Mandatory = $true)][string] $EntryPointsPath,
        [Parameter(Mandatory = $true)][string] $CommandName
    )

    if (-not (Test-Path -LiteralPath $EntryPointsPath -PathType Leaf)) {
        throw "Installed Python entry_points.txt is missing: '$EntryPointsPath'."
    }
    $item = Get-Item -LiteralPath $EntryPointsPath -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Installed Python entry_points.txt is a reparse point: '$EntryPointsPath'."
    }

    $section = ''
    $entryPointMatches = @()
    $text = ([IO.File]::ReadAllText($item.FullName)).Replace("`r`n", "`n").Replace("`r", "`n")
    foreach ($rawLine in @($text.Split("`n"))) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) {
            continue
        }
        if ($line -match '^\[(?<section>[A-Za-z0-9_.-]+)\]$') {
            $section = [string]$Matches.section
            continue
        }
        if ($section -cne 'console_scripts') {
            continue
        }
        if ($line -notmatch '^(?<name>[A-Za-z0-9_.-]+)\s*=\s*(?<value>\S(?:.*\S)?)$') {
            throw "Installed Python console_scripts contains a malformed entry: '$line'."
        }
        if ([string]$Matches.name -ceq $CommandName) {
            $entryPointMatches += [string]$Matches.value
        }
    }
    if ($entryPointMatches.Count -ne 1) {
        throw "Expected exactly one installed Python console entry point '$CommandName'; found $($entryPointMatches.Count)."
    }
    $value = [string]$entryPointMatches[0]
    if ($value.Length -gt 512 -or
        $value -cnotmatch '^[A-Za-z_][A-Za-z0-9_.]*:[A-Za-z_][A-Za-z0-9_.]*$') {
        throw "Installed Python console entry point '$CommandName' has an unsafe target."
    }
    return $value
}

function Get-InstalledPythonDistributionMetadata {
    param(
        [Parameter(Mandatory = $true)][string] $VirtualEnvironmentPath,
        [Parameter(Mandatory = $true)][string] $DistributionName
    )

    $resolvedVenv = [IO.Path]::GetFullPath($VirtualEnvironmentPath)
    $sitePackages = @()
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $candidate = Join-Path $resolvedVenv 'Lib\site-packages'
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            $sitePackages += $candidate
        }
    }
    else {
        $libRoot = Join-Path $resolvedVenv 'lib'
        if (Test-Path -LiteralPath $libRoot -PathType Container) {
            foreach ($pythonDirectory in @(Get-ChildItem -LiteralPath $libRoot -Directory)) {
                if ($pythonDirectory.Name -notmatch '^python(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
                    continue
                }
                $candidate = Join-Path $pythonDirectory.FullName 'site-packages'
                if (Test-Path -LiteralPath $candidate -PathType Container) {
                    $sitePackages += $candidate
                }
            }
        }
    }
    if ($sitePackages.Count -ne 1) {
        throw "Expected exactly one virtual-environment site-packages directory; found $($sitePackages.Count)."
    }
    $sitePackagesItem = Get-Item -LiteralPath $sitePackages[0] -Force
    if (($sitePackagesItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Virtual-environment site-packages is a reparse point: '$($sitePackagesItem.FullName)'."
    }

    $targetName = Normalize-PythonPackageName -Name $DistributionName
    $matches = @()
    foreach ($distInfo in @(Get-ChildItem -LiteralPath $sitePackages[0] -Directory -Filter '*.dist-info')) {
        if (($distInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed Python metadata directory is a reparse point: '$($distInfo.FullName)'."
        }
        $metadataPath = Join-Path $distInfo.FullName 'METADATA'
        if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) {
            continue
        }
        $metadataItem = Get-Item -LiteralPath $metadataPath -Force
        if (($metadataItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed Python METADATA is a reparse point: '$metadataPath'."
        }
        $metadataText = Get-Content -Raw -Encoding UTF8 -LiteralPath $metadataPath
        $metadata = ConvertFrom-PythonMetadataText -Text $metadataText -Context "Installed Python METADATA '$metadataPath'"
        if ([string]$metadata.normalizedName -ceq $targetName) {
            $entryPointsPath = Join-Path $distInfo.FullName 'entry_points.txt'
            $consoleEntryPoint = Get-PythonConsoleEntryPoint -EntryPointsPath $entryPointsPath -CommandName $targetName
            $matches += [pscustomobject][ordered]@{
                name = [string]$metadata.name
                normalizedName = [string]$metadata.normalizedName
                version = [string]$metadata.version
                metadataPath = $metadataPath
                entryPointsPath = $entryPointsPath
                consoleEntryPoint = $consoleEntryPoint
            }
        }
    }
    if ($matches.Count -ne 1) {
        throw "Expected exactly one installed Python distribution '$targetName'; found $($matches.Count)."
    }
    return $matches[0]
}

function Assert-NoPythonDirectReferences {
    param(
        [Parameter(Mandatory = $true)] $Metadata,
        [Parameter(Mandatory = $true)][string] $WheelFileName
    )

    foreach ($requirement in @($Metadata.requiresDist)) {
        if ([string]$requirement -match '@|(?:https?|file|git\+https?|git\+ssh|ssh)\s*:') {
            throw "Python direct dependency reference is not allowed in '$WheelFileName': '$requirement'."
        }
    }
}

function Resolve-PythonWheelClosureFromApprovedIndex {
    param(
        [Parameter(Mandatory = $true)][string] $PythonCommand,
        [Parameter(Mandatory = $true)][string] $HelperPath,
        [Parameter(Mandatory = $true)][string] $ExpectedHelperSha256,
        [Parameter(Mandatory = $true)][string] $ApprovedIndex,
        [Parameter(Mandatory = $true)][string] $RootWheelPath,
        [Parameter(Mandatory = $true)][string] $RootWheelSha256,
        [Parameter(Mandatory = $true)][string] $CandidatePath,
        [Parameter(Mandatory = $true)][string] $WheelhousePath,
        [Parameter(Mandatory = $true)][string] $WorkPath,
        [Parameter(Mandatory = $true)][System.Diagnostics.Stopwatch] $AcquisitionStopwatch,
        [Parameter(Mandatory = $true)][int] $AcquisitionLimitSeconds
    )

    if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
        throw "Python wheel closure helper not found: $HelperPath"
    }
    if ($ExpectedHelperSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        (Get-FileSha256 -Path $HelperPath) -cne $ExpectedHelperSha256) {
        throw 'Python wheel closure helper changed before acquisition.'
    }
    [void](New-Item -ItemType Directory -Path $WorkPath -Force)
    $planPath = Join-Path $WorkPath 'offline-backtracking-plan.json'
    $inventoryPath = Join-Path $WorkPath 'candidate-inventory.json'
    $resultPath = Join-Path $WorkPath 'closure-result.json'
    $diagnosticsPath = Join-Path $WorkPath 'acquisition-diagnostics.jsonl'
    $sourceHead = if ([string]$env:GITHUB_SHA -match '^[0-9a-f]{40}$') { [string]$env:GITHUB_SHA } else { 'unknown' }
    $remaining = Get-RemainingAcquisitionSeconds -Stopwatch $AcquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds

    [void](Invoke-IsolatedPythonCommand -PythonCommand $PythonCommand -Arguments @(
        $HelperPath, 'resolve',
        '--index-url', $ApprovedIndex,
        '--root-wheel', $RootWheelPath,
        '--root-sha256', $RootWheelSha256,
        '--candidate-dir', $CandidatePath,
        '--selected-dir', $WheelhousePath,
        '--plan', $planPath,
        '--inventory', $inventoryPath,
        '--result', $resultPath,
        '--diagnostics', $diagnosticsPath,
        '--run-id', $script:ResolverRunId,
        '--head-sha', $sourceHead,
        '--deadline-seconds', [string]$remaining,
        '--max-rounds', '128', '--max-candidates', '256', '--max-bytes', '536870912',
        '--initial-bytes', [string]((Get-Item -LiteralPath $RootWheelPath).Length)
    ) -TimeoutSeconds $remaining)
    if ((Get-FileSha256 -Path $HelperPath) -cne $ExpectedHelperSha256) {
        throw 'Python wheel closure helper changed during acquisition.'
    }
    foreach ($path in @($planPath, $inventoryPath, $resultPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Python wheel closure helper did not produce required evidence: $path"
        }
    }

    try {
        $result = Get-Content -Raw -Encoding UTF8 -LiteralPath $resultPath | ConvertFrom-Json
        $inventory = Get-Content -Raw -Encoding UTF8 -LiteralPath $inventoryPath | ConvertFrom-Json
        $plan = Get-Content -Raw -Encoding UTF8 -LiteralPath $planPath | ConvertFrom-Json
    }
    catch {
        throw "Python wheel closure helper result is invalid JSON: $($_.Exception.Message)"
    }
    try {
        if ((Get-FileSha256 -Path $HelperPath) -cne $ExpectedHelperSha256) {
            throw 'Python wheel closure helper changed before evidence verification.'
        }
        $verificationOutput = @(Invoke-IsolatedPythonCommand -PythonCommand $PythonCommand -Arguments @(
            $HelperPath, 'verify',
            '--candidate-dir', $CandidatePath,
            '--selected-dir', $WheelhousePath,
            '--plan', $planPath,
            '--inventory', $inventoryPath,
            '--result', $resultPath
        ) -TimeoutSeconds (Get-RemainingAcquisitionSeconds -Stopwatch $AcquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds))
        if ((Get-FileSha256 -Path $HelperPath) -cne $ExpectedHelperSha256) {
            throw 'Python wheel closure helper changed during evidence verification.'
        }
        $verification = ($verificationOutput -join [Environment]::NewLine) | ConvertFrom-Json
    }
    catch {
        throw "Python wheel closure cross-file evidence verification failed: $($_.Exception.Message)"
    }
    if (($result.schemaVersion -isnot [int] -and $result.schemaVersion -isnot [long]) -or
        [int64]$result.schemaVersion -ne 1) {
        throw 'Python wheel closure helper returned an unsupported schemaVersion.'
    }
    foreach ($name in @('candidateInventorySha256', 'selectionPlanSha256', 'rawSelectionPlanSha256', 'selectedClosureSha256')) {
        $value = $result.$name
        if ($value -isnot [string] -or [string]$value -cnotmatch '^[0-9a-f]{64}$') {
            throw "Python wheel closure helper returned an invalid $name."
        }
        if ($verification.$name -isnot [string] -or [string]$verification.$name -cne [string]$value) {
            throw "Python wheel closure helper cross-file verification disagrees on $name."
        }
    }
    if (($verification.schemaVersion -isnot [int] -and $verification.schemaVersion -isnot [long]) -or
        [int64]$verification.schemaVersion -ne 1 -or
        $verification.verified -isnot [bool] -or
        -not [bool]$verification.verified) {
        throw 'Python wheel closure helper did not verify its cross-file evidence.'
    }
    foreach ($name in @('resolutionRounds', 'candidateCount')) {
        $value = $result.$name
        if (($value -isnot [int] -and $value -isnot [long]) -or [int64]$value -le 0) {
            throw "Python wheel closure helper returned an invalid $name."
        }
    }
    if ($result.pipVersion -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$result.pipVersion) -or
        [string]$result.pipVersion -cnotmatch '^[0-9A-Za-z][0-9A-Za-z._+!-]{0,63}$') {
        throw 'Python wheel closure helper did not record a safe pip resolver version.'
    }
    $selectedEntries = @($result.selectedEntries)
    if ($result.selectedEntries -isnot [array] -or $selectedEntries.Count -le 0) {
        throw 'Python wheel closure helper returned no selected wheel entries.'
    }
    if (($inventory.schemaVersion -isnot [int] -and $inventory.schemaVersion -isnot [long]) -or
        [int64]$inventory.schemaVersion -ne 1 -or
        $inventory.index -isnot [string] -or
        [string]$inventory.index -cne $ApprovedIndex.TrimEnd('/') -or
        $inventory.pipVersion -isnot [string] -or
        [string]$inventory.pipVersion -cne [string]$result.pipVersion -or
        $inventory.yankedAllowed -isnot [bool] -or
        [bool]$inventory.yankedAllowed -or
        $inventory.inventorySha256 -isnot [string] -or
        [string]$inventory.inventorySha256 -cne [string]$result.candidateInventorySha256 -or
        $inventory.entries -isnot [array] -or
        @($inventory.entries).Count -ne [int64]$result.candidateCount) {
        throw 'Python wheel closure candidate inventory is inconsistent with the helper result.'
    }
    $candidateRoot = [IO.Path]::GetFullPath($CandidatePath).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparison]::OrdinalIgnoreCase
    }
    else { [StringComparison]::Ordinal }
    foreach ($entry in @($inventory.entries)) {
        if ($entry.file -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$entry.file) -or
            [IO.Path]::GetFileName([string]$entry.file) -cne [string]$entry.file -or
            $entry.sha256 -isnot [string] -or [string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw 'Python wheel closure candidate inventory contains an invalid file identity.'
        }
        $candidateFile = [IO.Path]::GetFullPath((Join-Path $CandidatePath ([string]$entry.file)))
        if (-not $candidateFile.StartsWith($candidateRoot, $pathComparison) -or
            -not (Test-Path -LiteralPath $candidateFile -PathType Leaf) -or
            (Get-FileSha256 -Path $candidateFile) -cne [string]$entry.sha256) {
            throw "Python wheel closure candidate evidence changed or escaped its pool: $candidateFile"
        }
    }
    $rawPlanHash = Get-FileSha256 -Path $planPath
    if ($rawPlanHash -cne [string]$result.rawSelectionPlanSha256 -or
        $plan.install -isnot [array] -or
        @($plan.install).Count -ne $selectedEntries.Count) {
        throw 'Python wheel closure selection plan is inconsistent with the helper result.'
    }

    return [ordered]@{
        planPath = $planPath
        inventoryPath = $inventoryPath
        resultPath = $resultPath
        pipVersion = [string]$result.pipVersion
        resolutionRounds = [int64]$result.resolutionRounds
        candidateCount = [int64]$result.candidateCount
        candidateInventorySha256 = [string]$result.candidateInventorySha256
        selectionPlanSha256 = [string]$result.selectionPlanSha256
        rawSelectionPlanSha256 = [string]$result.rawSelectionPlanSha256
        selectedClosureSha256 = [string]$result.selectedClosureSha256
        selectedEntries = $selectedEntries
    }
}

function Assert-SkillSpectorWheelIdentity {
    param(
        $ApprovedEntry,
        [string] $WheelPath,
        [string] $ReleaseVersion,
        [Parameter(Mandatory = $true)][string] $WheelFileName,
        [Parameter(Mandatory = $true)][string] $MetadataName,
        [Parameter(Mandatory = $true)][string] $MetadataVersion
    )

    $releaseVersion = if ($null -eq $ApprovedEntry) { [string]$ReleaseVersion } else { [string]$ApprovedEntry.version }
    $expectedWheelName = if ($null -eq $ApprovedEntry) { "skillspector-$releaseVersion-py3-none-any.whl" } else { [string]$ApprovedEntry.wheelFileName }
    if ($WheelFileName -cne $expectedWheelName) {
        throw "SkillSpector release/wheel version mismatch. Expected '$expectedWheelName', got '$WheelFileName'."
    }
    if ((Normalize-PythonPackageName -Name $MetadataName) -cne 'skillspector') {
        throw "SkillSpector wheel METADATA Name mismatch. Expected 'skillspector', got '$MetadataName'."
    }
    if ($MetadataVersion -cne $releaseVersion) {
        throw "SkillSpector wheel METADATA Version mismatch. Expected '$releaseVersion', got '$MetadataVersion'."
    }
    if ($null -ne $ApprovedEntry) {
        if ([string]::IsNullOrWhiteSpace($WheelPath)) { throw 'Approved SkillSpector wheel identity requires wheel bytes.' }
        $analyzerHash = Get-PythonWheelEntrySha256 -WheelPath $WheelPath -EntryPath 'skillspector/nodes/analyzers/static_patterns_tool_misuse.py'
        if ($analyzerHash -cne [string]$ApprovedEntry.analyzerSha256) {
            throw "SkillSpector analyzer hash mismatch. Expected '$($ApprovedEntry.analyzerSha256)', got '$analyzerHash'."
        }
    }
}

function Get-ProcessPipEnvironmentNames {
    return @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys |
        ForEach-Object { [string]$_ } |
        Where-Object { $_ -match '^PIP_' } |
        Sort-Object)
}

function Get-ProcessPythonEnvironmentNames {
    return @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys |
        ForEach-Object { [string]$_ } |
        Where-Object { $dangerousPythonEnvironmentNames -icontains $_ } |
        Sort-Object)
}

function Assert-NoConflictingPythonEnvironment {
    foreach ($name in Get-ProcessPythonEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Python environment override for '$name': '$actual'."
        }
    }
}

function Assert-NoConflictingPipEnvironment {
    param([Parameter(Mandatory = $true)][string] $ApprovedIndex)

    $expectedIndex = Normalize-RegistryUri -Value $ApprovedIndex
    foreach ($name in Get-ProcessPipEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrEmpty($actual)) {
            continue
        }
        if ($name -ceq 'PIP_INDEX_URL') {
            $actualIndex = Normalize-RegistryUri -Value $actual
            if ($actualIndex -cne $expectedIndex) {
                throw "Untrusted pip environment override for 'PIP_INDEX_URL': '$actualIndex'. Expected '$expectedIndex'."
            }
            continue
        }
        throw "Untrusted pip environment override for '$name': '$actual'."
    }
}

function Invoke-WithApprovedPipEnvironment {
    param(
        [Parameter(Mandatory = $true)][string] $ApprovedIndex,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )

    Assert-NoConflictingPipEnvironment -ApprovedIndex $ApprovedIndex
    Assert-NoConflictingPythonEnvironment

    $names = @(Get-OrdinalUniqueStrings -Values @(
        (Get-ProcessPipEnvironmentNames) +
        (Get-ProcessPythonEnvironmentNames) +
        @('PIP_INDEX_URL', 'PIP_CONFIG_FILE')
    ))
    $previous = [ordered]@{}
    $nullDevice = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'NUL' } else { '/dev/null' }
    $normalizedIndex = Normalize-RegistryUri -Value $ApprovedIndex

    try {
        foreach ($name in $names) {
            $previous[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
        }
        [Environment]::SetEnvironmentVariable('PIP_INDEX_URL', $normalizedIndex, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('PIP_CONFIG_FILE', $nullDevice, [EnvironmentVariableTarget]::Process)

        return & $Action
    }
    finally {
        foreach ($entry in $previous.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
        }
    }
}

function New-PythonWheelhouseLock {
    param(
        [Parameter(Mandatory = $true)][string] $WheelhousePath,
        [Parameter(Mandatory = $true)][string] $LockPath
    )

    $files = @(Get-ChildItem -LiteralPath $WheelhousePath -File)
    if ($files.Count -eq 0) {
        throw 'Python wheelhouse is empty.'
    }

    $entryMap = New-Object 'System.Collections.Generic.SortedDictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($file in $files) {
        if ($file.Extension -cne '.whl') {
            throw "Non-wheel artifact found in verified wheelhouse: '$($file.Name)'."
        }
        $metadata = Get-PythonWheelMetadata -WheelPath $file.FullName
        Assert-NoPythonDirectReferences -Metadata $metadata -WheelFileName $file.Name
        $normalizedName = [string]$metadata.normalizedName
        if ($entryMap.ContainsKey($normalizedName)) {
            throw "Duplicate Python distribution '$normalizedName' in wheelhouse."
        }
        $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        $entryMap.Add($normalizedName, [pscustomobject][ordered]@{
            name = [string]$metadata.name
            normalizedName = $normalizedName
            version = [string]$metadata.version
            file = $file.Name
            sha256 = $hash
        })
    }

    $entries = @($entryMap.Values)
    $lockLines = @($entries | ForEach-Object { "$($_.normalizedName)==$($_.version) --hash=sha256:$($_.sha256)" })
    [IO.File]::WriteAllText($LockPath, (($lockLines -join [Environment]::NewLine) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))

    $canonical = ($entries | ForEach-Object { "$($_.normalizedName)`t$($_.version)`t$($_.file)`t$($_.sha256)`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $closureHash = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }

    return [ordered]@{
        lockPath = $LockPath
        closureSha256 = $closureHash
        entries = $entries
    }
}

function Get-ProcessNpmEnvironmentNames {
    $knownNames = @(
        'NPM_CONFIG_REGISTRY', 'NPM_CONFIG_USERCONFIG', 'NPM_CONFIG_GLOBALCONFIG',
        'NPM_CONFIG_CACHE', 'NPM_CONFIG_DRY_RUN', 'NPM_CONFIG_OFFLINE',
        'NPM_CONFIG_PREFER_OFFLINE', 'NPM_CONFIG_AUDIT', 'NPM_CONFIG_FUND',
        'NPM_CONFIG_UPDATE_NOTIFIER', 'NPM_CONFIG_IGNORE_SCRIPTS',
        'NPM_CONFIG_PACKAGE_LOCK', 'NPM_CONFIG_OMIT_LOCKFILE_REGISTRY_RESOLVED',
        'NPM_CONFIG_BIN_LINKS', 'NPM_CONFIG_WORKSPACES', 'NPM_CONFIG_GLOBAL'
    )
    $presentNames = @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys |
        ForEach-Object { [string]$_ } |
        Where-Object { $_ -match '^NPM_CONFIG_' } |
        Sort-Object)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $presentNames = @($presentNames | ForEach-Object {
            $presentName = [string]$_
            $canonicalName = @($knownNames | Where-Object {
                [string]::Equals([string]$_, $presentName, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($canonicalName.Count -eq 1) { [string]$canonicalName[0] } else { $presentName }
        })
    }
    return @(Get-OrdinalUniqueStrings -Values @($presentNames + $knownNames))
}

function Get-ProcessNodeEnvironmentNames {
    $knownNames = @(
        'NODE_OPTIONS', 'NODE_PATH', 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_EXTRA_CA_CERTS',
        'SSL_CERT_FILE', 'SSL_CERT_DIR'
    )
    $presentNames = @([Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process).Keys |
        ForEach-Object { [string]$_ } |
        Where-Object {
            $_ -match '^NODE_' -or
            $_ -ieq 'SSL_CERT_FILE' -or
            $_ -ieq 'SSL_CERT_DIR'
        } |
        Sort-Object)
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        $presentNames = @($presentNames | ForEach-Object {
            $presentName = [string]$_
            $canonicalName = @($knownNames | Where-Object {
                [string]::Equals([string]$_, $presentName, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($canonicalName.Count -eq 1) { [string]$canonicalName[0] } else { $presentName }
        })
    }
    return @(Get-OrdinalUniqueStrings -Values @($presentNames + $knownNames))
}

function Assert-NoConflictingNpmEnvironment {
    param([Parameter(Mandatory = $true)][string] $ExpectedRegistry)

    $expected = Normalize-RegistryUri -Value $ExpectedRegistry
    foreach ($name in Get-ProcessNpmEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrEmpty($actual)) {
            continue
        }
        if ($name -ieq 'NPM_CONFIG_REGISTRY') {
            $actualRegistry = Normalize-RegistryUri -Value $actual
            if ($actualRegistry -cne $expected) {
                throw "Untrusted npm registry from '$name': '$actualRegistry'. Expected '$expected'."
            }
            continue
        }
        throw "Untrusted npm environment override for '$name': '$actual'."
    }

    foreach ($name in Get-ProcessNodeEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Node environment override for '$name': '$actual'."
        }
    }
}

function Assert-ApprovedNpmRegistry {
    param(
        [Parameter(Mandatory = $true)][string] $NpmCommand,
        [Parameter(Mandatory = $true)][string] $ExpectedRegistry
    )

    $expected = Normalize-RegistryUri -Value $ExpectedRegistry
    $configuredRegistry = (Invoke-CheckedCommand -Command $NpmCommand -Arguments @('config', 'get', 'registry')) -join ''
    $configured = Normalize-RegistryUri -Value $configuredRegistry
    if ($configured -cne $expected) {
        throw "Untrusted npm registry from npm configuration: '$configured'. Expected '$expected'."
    }

    $configJson = (Invoke-CheckedCommand -Command $NpmCommand -Arguments @('config', 'list', '--json')) -join "`n"
    $config = $configJson | ConvertFrom-Json
    Assert-ApprovedNpmConfigurationObject -Configuration $config -ExpectedRegistry $ExpectedRegistry
    return $expected
}

function Assert-ApprovedNpmConfigurationObject {
    param(
        [Parameter(Mandatory = $true)] $Configuration,
        [Parameter(Mandatory = $true)][string] $ExpectedRegistry
    )

    $registryProperty = $Configuration.PSObject.Properties['registry']
    if ($null -eq $registryProperty -or $registryProperty.Value -isnot [string]) {
        throw 'npm configuration did not expose a string default registry.'
    }
    $expected = Normalize-RegistryUri -Value $ExpectedRegistry
    $configured = Normalize-RegistryUri -Value ([string]$registryProperty.Value)
    if ($configured -cne $expected) {
        throw "Untrusted npm registry from npm configuration object: '$configured'. Expected '$expected'."
    }
    $scopedRegistries = @($Configuration.PSObject.Properties | Where-Object { [string]$_.Name -match ':registry$' })
    if ($scopedRegistries.Count -gt 0) {
        throw "Untrusted scoped npm registry configuration remains active: '$($scopedRegistries.Name -join ',')'."
    }
}

function Invoke-WithApprovedNpmEnvironment {
    param(
        [Parameter(Mandatory = $true)][string] $NpmCommand,
        [Parameter(Mandatory = $true)][string] $ApprovedRegistry,
        [Parameter(Mandatory = $true)][string] $WorkPath,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )

    Assert-NoConflictingNpmEnvironment -ExpectedRegistry $ApprovedRegistry
    [void](New-Item -ItemType Directory -Path $WorkPath -Force)
    $cachePath = Join-Path $WorkPath 'npm-cache'
    [void](New-Item -ItemType Directory -Path $cachePath -Force)
    $normalizedRegistry = Normalize-RegistryUri -Value $ApprovedRegistry
    $userConfig = Join-Path $WorkPath 'user.npmrc'
    $globalConfig = Join-Path $WorkPath 'global.npmrc'
    $projectConfig = Join-Path $WorkPath '.npmrc'
    [IO.File]::WriteAllText($userConfig, '', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($globalConfig, '', (New-Object Text.UTF8Encoding($false)))
    $controlledNpmrc = @(
        "registry=$normalizedRegistry",
        'dry-run=false',
        'ignore-scripts=true',
        'package-lock=true',
        'omit-lockfile-registry-resolved=false',
        'audit=false',
        'fund=false'
    ) -join [Environment]::NewLine
    [IO.File]::WriteAllText($projectConfig, $controlledNpmrc + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
    $workManifest = [ordered]@{
        name = 'standard-validation-npm-work'
        version = '1.0.0'
        private = $true
    } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $WorkPath 'package.json'), $workManifest + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

    $names = @(Get-OrdinalUniqueStrings -Values @(@(Get-ProcessNpmEnvironmentNames) + @(Get-ProcessNodeEnvironmentNames) + @(
        'NPM_CONFIG_REGISTRY', 'NPM_CONFIG_USERCONFIG', 'NPM_CONFIG_GLOBALCONFIG',
        'NPM_CONFIG_CACHE', 'NPM_CONFIG_DRY_RUN', 'NPM_CONFIG_OFFLINE',
        'NPM_CONFIG_PREFER_OFFLINE', 'NPM_CONFIG_AUDIT', 'NPM_CONFIG_FUND',
        'NPM_CONFIG_UPDATE_NOTIFIER', 'NPM_CONFIG_IGNORE_SCRIPTS',
        'NPM_CONFIG_PACKAGE_LOCK', 'NPM_CONFIG_OMIT_LOCKFILE_REGISTRY_RESOLVED',
        'NPM_CONFIG_BIN_LINKS', 'NPM_CONFIG_WORKSPACES', 'NPM_CONFIG_GLOBAL',
        'NODE_OPTIONS', 'NODE_PATH', 'NODE_TLS_REJECT_UNAUTHORIZED', 'NODE_EXTRA_CA_CERTS',
        'SSL_CERT_FILE', 'SSL_CERT_DIR'
    )))
    $previous = @()
    $previousLocation = Get-Location
    try {
        foreach ($name in $names) {
            $previous += [pscustomobject]@{
                name = $name
                value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
            }
            [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
        }
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_REGISTRY', $normalizedRegistry, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_USERCONFIG', $userConfig, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_GLOBALCONFIG', $globalConfig, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_CACHE', $cachePath, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_DRY_RUN', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_OFFLINE', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_PREFER_OFFLINE', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_AUDIT', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_FUND', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_UPDATE_NOTIFIER', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_IGNORE_SCRIPTS', 'true', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_PACKAGE_LOCK', 'true', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_OMIT_LOCKFILE_REGISTRY_RESOLVED', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_BIN_LINKS', 'true', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_WORKSPACES', 'false', [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('NPM_CONFIG_GLOBAL', 'false', [EnvironmentVariableTarget]::Process)
        Set-Location -LiteralPath $WorkPath

        $approved = Assert-ApprovedNpmRegistry -NpmCommand $NpmCommand -ExpectedRegistry $ApprovedRegistry
        return & $Action $approved
    }
    finally {
        Set-Location -LiteralPath $previousLocation.Path
        $currentNames = @(Get-OrdinalUniqueStrings -Values @(
            @(Get-ProcessNpmEnvironmentNames) + @(Get-ProcessNodeEnvironmentNames) + $names
        ))
        foreach ($name in $currentNames) {
            [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
        }
        foreach ($entry in $previous) {
            [Environment]::SetEnvironmentVariable([string]$entry.name, $entry.value, [EnvironmentVariableTarget]::Process)
        }
    }
}

function New-NpmJsonNode {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Object','Array','String','Integer','Number','Boolean','Null')][string] $TokenType,
        [AllowNull()] $Value,
        [AllowNull()] $Properties,
        [AllowNull()] $Items
    )

    $node = [ordered]@{ TokenType = $TokenType }
    if ($TokenType -ceq 'Object') { $node['Properties'] = $Properties }
    elseif ($TokenType -ceq 'Array') { $node['Items'] = @($Items) }
    else { $node['Value'] = $Value }
    return [pscustomobject]$node
}

function Skip-NpmJsonWhitespace {
    param([Parameter(Mandatory = $true)] $State)

    while ($State.Index -lt $State.Text.Length) {
        $code = [int][char]$State.Text[$State.Index]
        if ($code -notin @(0x20, 0x09, 0x0A, 0x0D)) { break }
        $State.Index++
    }
}

function Add-NpmJsonSemanticToken {
    param([Parameter(Mandatory = $true)] $State)

    $State.TokenCount++
    if ($State.TokenCount -gt $State.MaxTokens) {
        throw "npm package-lock JSON exceeds the maximum semantic token count of $($State.MaxTokens)."
    }
}

function Read-NpmJsonString {
    param([Parameter(Mandatory = $true)] $State)

    if ($State.Index -ge $State.Text.Length -or [int][char]$State.Text[$State.Index] -ne 0x22) {
        throw "npm package-lock JSON expected a string at offset $($State.Index)."
    }
    $State.Index++
    $builder = New-Object System.Text.StringBuilder
    while ($State.Index -lt $State.Text.Length) {
        $code = [int][char]$State.Text[$State.Index]
        $State.Index++
        if ($code -eq 0x22) {
            return $builder.ToString()
        }
        if ($code -lt 0x20) {
            throw "npm package-lock JSON string contains an unescaped control character at offset $($State.Index - 1)."
        }
        if ($code -ne 0x5C) {
            if ($code -ge 0xD800 -and $code -le 0xDBFF) {
                if ($State.Index -ge $State.Text.Length) {
                    throw 'npm package-lock JSON string contains an unpaired raw high surrogate.'
                }
                $lowCode = [int][char]$State.Text[$State.Index]
                if ($lowCode -lt 0xDC00 -or $lowCode -gt 0xDFFF) {
                    throw 'npm package-lock JSON string contains an unpaired raw high surrogate.'
                }
                [void]$builder.Append([char]$code)
                [void]$builder.Append([char]$lowCode)
                $State.Index++
                continue
            }
            if ($code -ge 0xDC00 -and $code -le 0xDFFF) {
                throw 'npm package-lock JSON string contains an unpaired raw low surrogate.'
            }
            [void]$builder.Append([char]$code)
            continue
        }
        if ($State.Index -ge $State.Text.Length) {
            throw 'npm package-lock JSON string ends with an incomplete escape.'
        }
        $escape = [int][char]$State.Text[$State.Index]
        $State.Index++
        if ($escape -eq 0x22) { [void]$builder.Append([char]0x22); continue }
        if ($escape -eq 0x5C) { [void]$builder.Append([char]0x5C); continue }
        if ($escape -eq 0x2F) { [void]$builder.Append([char]0x2F); continue }
        if ($escape -eq 0x62) { [void]$builder.Append([char]0x08); continue }
        if ($escape -eq 0x66) { [void]$builder.Append([char]0x0C); continue }
        if ($escape -eq 0x6E) { [void]$builder.Append([char]0x0A); continue }
        if ($escape -eq 0x72) { [void]$builder.Append([char]0x0D); continue }
        if ($escape -eq 0x74) { [void]$builder.Append([char]0x09); continue }
        if ($escape -ne 0x75 -or ($State.Index + 4) -gt $State.Text.Length) {
            throw "npm package-lock JSON string contains an invalid escape at offset $($State.Index - 1)."
        }
        $hex = $State.Text.Substring($State.Index, 4)
        if ($hex -cnotmatch '^[0-9A-Fa-f]{4}$') {
            throw "npm package-lock JSON string contains an invalid Unicode escape at offset $($State.Index)."
        }
        $unit = [Convert]::ToInt32($hex, 16)
        $State.Index += 4
        if ($unit -ge 0xD800 -and $unit -le 0xDBFF) {
            if (($State.Index + 6) -gt $State.Text.Length -or
                [int][char]$State.Text[$State.Index] -ne 0x5C -or
                [int][char]$State.Text[$State.Index + 1] -ne 0x75) {
                throw 'npm package-lock JSON string contains an unpaired high surrogate.'
            }
            $lowHex = $State.Text.Substring($State.Index + 2, 4)
            if ($lowHex -cnotmatch '^[0-9A-Fa-f]{4}$') {
                throw 'npm package-lock JSON string contains an invalid low-surrogate escape.'
            }
            $lowUnit = [Convert]::ToInt32($lowHex, 16)
            if ($lowUnit -lt 0xDC00 -or $lowUnit -gt 0xDFFF) {
                throw 'npm package-lock JSON string contains an unpaired high surrogate.'
            }
            $State.Index += 6
            $scalar = 0x10000 + (($unit - 0xD800) * 0x400) + ($lowUnit - 0xDC00)
            [void]$builder.Append([char]::ConvertFromUtf32($scalar))
            continue
        }
        if ($unit -ge 0xDC00 -and $unit -le 0xDFFF) {
            throw 'npm package-lock JSON string contains an unpaired low surrogate.'
        }
        [void]$builder.Append([char]$unit)
    }
    throw 'npm package-lock JSON string is unterminated.'
}

function Read-NpmJsonNumber {
    param([Parameter(Mandatory = $true)] $State)

    $start = $State.Index
    if ([int][char]$State.Text[$State.Index] -eq 0x2D) {
        $State.Index++
        if ($State.Index -ge $State.Text.Length) { throw 'npm package-lock JSON number is incomplete.' }
    }
    $first = [int][char]$State.Text[$State.Index]
    if ($first -eq 0x30) {
        $State.Index++
        if ($State.Index -lt $State.Text.Length) {
            $next = [int][char]$State.Text[$State.Index]
            if ($next -ge 0x30 -and $next -le 0x39) {
                throw "npm package-lock JSON number has a leading zero at offset $start."
            }
        }
    }
    elseif ($first -ge 0x31 -and $first -le 0x39) {
        while ($State.Index -lt $State.Text.Length) {
            $next = [int][char]$State.Text[$State.Index]
            if ($next -lt 0x30 -or $next -gt 0x39) { break }
            $State.Index++
        }
    }
    else {
        throw "npm package-lock JSON number is invalid at offset $start."
    }

    $isInteger = $true
    if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -eq 0x2E) {
        $isInteger = $false
        $State.Index++
        $fractionStart = $State.Index
        while ($State.Index -lt $State.Text.Length) {
            $next = [int][char]$State.Text[$State.Index]
            if ($next -lt 0x30 -or $next -gt 0x39) { break }
            $State.Index++
        }
        if ($State.Index -eq $fractionStart) { throw 'npm package-lock JSON fraction is missing digits.' }
    }
    if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -in @(0x45, 0x65)) {
        $isInteger = $false
        $State.Index++
        if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -in @(0x2B, 0x2D)) {
            $State.Index++
        }
        $exponentStart = $State.Index
        while ($State.Index -lt $State.Text.Length) {
            $next = [int][char]$State.Text[$State.Index]
            if ($next -lt 0x30 -or $next -gt 0x39) { break }
            $State.Index++
        }
        if ($State.Index -eq $exponentStart) { throw 'npm package-lock JSON exponent is missing digits.' }
    }
    $raw = $State.Text.Substring($start, $State.Index - $start)
    return New-NpmJsonNode -TokenType $(if ($isInteger) { 'Integer' } else { 'Number' }) -Value $raw
}

function Read-NpmJsonValue {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)][int] $Depth
    )

    if ($Depth -gt 128) { throw 'npm package-lock JSON exceeds the maximum nesting depth.' }
    Add-NpmJsonSemanticToken -State $State
    Skip-NpmJsonWhitespace -State $State
    if ($State.Index -ge $State.Text.Length) { throw 'npm package-lock JSON ends before a value.' }
    $code = [int][char]$State.Text[$State.Index]

    if ($code -eq 0x7B) {
        $State.Index++
        $properties = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
        Skip-NpmJsonWhitespace -State $State
        if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -eq 0x7D) {
            $State.Index++
            return New-NpmJsonNode -TokenType Object -Properties $properties
        }
        while ($true) {
            $nameOffset = $State.Index
            Add-NpmJsonSemanticToken -State $State
            $name = Read-NpmJsonString -State $State
            if ($properties.ContainsKey($name)) {
                throw "npm package-lock JSON contains a duplicate object key at offset $nameOffset."
            }
            Skip-NpmJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length -or [int][char]$State.Text[$State.Index] -ne 0x3A) {
                throw "npm package-lock JSON expected ':' after the object key at offset $nameOffset."
            }
            $State.Index++
            $value = Read-NpmJsonValue -State $State -Depth ($Depth + 1)
            $properties.Add($name, $value)
            Skip-NpmJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) { throw 'npm package-lock JSON object is unterminated.' }
            $delimiter = [int][char]$State.Text[$State.Index]
            $State.Index++
            if ($delimiter -eq 0x7D) { break }
            if ($delimiter -ne 0x2C) { throw 'npm package-lock JSON object expected a comma or closing brace.' }
            Skip-NpmJsonWhitespace -State $State
        }
        return New-NpmJsonNode -TokenType Object -Properties $properties
    }

    if ($code -eq 0x5B) {
        $State.Index++
        $items = New-Object 'System.Collections.Generic.List[object]'
        Skip-NpmJsonWhitespace -State $State
        if ($State.Index -lt $State.Text.Length -and [int][char]$State.Text[$State.Index] -eq 0x5D) {
            $State.Index++
            return New-NpmJsonNode -TokenType Array -Items @()
        }
        while ($true) {
            [void]$items.Add((Read-NpmJsonValue -State $State -Depth ($Depth + 1)))
            Skip-NpmJsonWhitespace -State $State
            if ($State.Index -ge $State.Text.Length) { throw 'npm package-lock JSON array is unterminated.' }
            $delimiter = [int][char]$State.Text[$State.Index]
            $State.Index++
            if ($delimiter -eq 0x5D) { break }
            if ($delimiter -ne 0x2C) { throw 'npm package-lock JSON array expected a comma or closing bracket.' }
            Skip-NpmJsonWhitespace -State $State
        }
        return New-NpmJsonNode -TokenType Array -Items ([object[]]$items.ToArray())
    }

    if ($code -eq 0x22) {
        return New-NpmJsonNode -TokenType String -Value (Read-NpmJsonString -State $State)
    }
    if ($code -eq 0x74 -and ($State.Index + 4) -le $State.Text.Length -and
        $State.Text.Substring($State.Index, 4) -ceq 'true') {
        $State.Index += 4
        return New-NpmJsonNode -TokenType Boolean -Value $true
    }
    if ($code -eq 0x66 -and ($State.Index + 5) -le $State.Text.Length -and
        $State.Text.Substring($State.Index, 5) -ceq 'false') {
        $State.Index += 5
        return New-NpmJsonNode -TokenType Boolean -Value $false
    }
    if ($code -eq 0x6E -and ($State.Index + 4) -le $State.Text.Length -and
        $State.Text.Substring($State.Index, 4) -ceq 'null') {
        $State.Index += 4
        return New-NpmJsonNode -TokenType Null -Value $null
    }
    if ($code -eq 0x2D -or ($code -ge 0x30 -and $code -le 0x39)) {
        return Read-NpmJsonNumber -State $State
    }
    throw "npm package-lock JSON contains an unexpected token at offset $($State.Index)."
}

function ConvertFrom-NpmJsonStrict {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Text,
        [ValidateRange(1, 50000)][int] $MaxTokens = 50000
    )

    $state = [pscustomobject]@{ Text = $Text; Index = 0; TokenCount = 0; MaxTokens = $MaxTokens }
    $value = Read-NpmJsonValue -State $state -Depth 0
    Skip-NpmJsonWhitespace -State $state
    if ($state.Index -ne $state.Text.Length) {
        throw "npm package-lock JSON contains trailing content at offset $($state.Index)."
    }
    return $value
}

function Get-NpmJsonTokenType {
    param($Token)

    if ($null -eq $Token) { return $null }
    return [string]$Token.TokenType
}

function Get-NpmJsonObjectProperty {
    param(
        [Parameter(Mandatory = $true)] $Token,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Name
    )

    if ((Get-NpmJsonTokenType -Token $Token) -cne 'Object') { return $null }
    $value = $null
    if ($Token.Properties.TryGetValue($Name, [ref]$value)) { return $value }
    return $null
}

function Get-NpmJsonObjectProperties {
    param([Parameter(Mandatory = $true)] $Token)

    if ((Get-NpmJsonTokenType -Token $Token) -cne 'Object') { return @() }
    return @($Token.Properties.GetEnumerator() | ForEach-Object {
        [pscustomobject]@{ Name = [string]$_.Key; Value = $_.Value }
    })
}

function Get-NpmJsonScalarValue {
    param([Parameter(Mandatory = $true)] $Token)

    if ((Get-NpmJsonTokenType -Token $Token) -in @('Object','Array')) {
        throw 'npm package-lock JSON value is not scalar.'
    }
    return $Token.Value
}

function Get-CanonicalNpmBinTarget {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()] $Value,
        [Parameter(Mandatory = $true)][string] $Context
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Context is not a safe relative package path: expected a non-empty string."
    }
    foreach ($character in ([string]$Value).ToCharArray()) {
        if ([char]::IsControl($character)) {
            throw "$Context is not a safe relative package path: control characters are forbidden."
        }
    }
    if (([string]$Value).Contains(':')) {
        throw "$Context is not a safe relative package path: colons are forbidden."
    }

    $normalized = ([string]$Value).Replace([char]'\', [char]'/')
    if ($normalized.StartsWith('/')) {
        throw "$Context is not a safe relative package path: absolute paths are forbidden."
    }

    $segments = New-Object 'System.Collections.Generic.List[string]'
    foreach ($segment in @($normalized.Split([char[]]@([char]'/'), [System.StringSplitOptions]::None))) {
        if ($segment -ceq '.') {
            continue
        }
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '..') {
            throw "$Context is not a safe relative package path: empty and parent segments are forbidden."
        }
        [void]$segments.Add($segment)
    }
    if ($segments.Count -eq 0) {
        throw "$Context is not a safe relative package path: no package file is identified."
    }
    return [string]::Join('/', [string[]]$segments.ToArray())
}

function Get-NpmLockIdentity {
    param(
        [Parameter(Mandatory = $true)][string] $LockPath,
        [Parameter(Mandatory = $true)][string] $ApprovedRegistry,
        [Parameter(Mandatory = $true)][string] $ExpectedRootIntegrity,
        [Parameter(Mandatory = $true)][string] $ExpectedVersion
    )

    try {
        $lockStream = [System.IO.File]::Open(
            [System.IO.Path]::GetFullPath($LockPath),
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )
        try {
            $lockLength = $lockStream.Length
            if ($lockLength -gt 32MB) {
                throw 'npm package-lock exceeds the 32 MiB validation limit.'
            }
            $lockBytes = [System.Array]::CreateInstance([byte], [int]$lockLength)
            $lockOffset = 0
            while ($lockOffset -lt $lockBytes.Length) {
                $readCount = $lockStream.Read($lockBytes, $lockOffset, $lockBytes.Length - $lockOffset)
                if ($readCount -le 0) {
                    throw 'npm package-lock changed or ended while its validation snapshot was read.'
                }
                $lockOffset += $readCount
            }
            if ($lockStream.ReadByte() -ne -1 -or $lockStream.Length -ne $lockLength) {
                throw 'npm package-lock changed while its validation snapshot was read.'
            }
        }
        finally {
            $lockStream.Dispose()
        }
        $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $lockText = $utf8.GetString($lockBytes)
        $lock = ConvertFrom-NpmJsonStrict -Text $lockText
    }
    catch {
        throw "npm package-lock is not valid JSON: $($_.Exception.Message)"
    }
    $integerType = 'Integer'
    $objectType = 'Object'
    $stringType = 'String'
    $booleanType = 'Boolean'
    $lockfileVersionToken = Get-NpmJsonObjectProperty -Token $lock -Name 'lockfileVersion'
    $packages = Get-NpmJsonObjectProperty -Token $lock -Name 'packages'
    if ($null -eq $packages -or (Get-NpmJsonTokenType -Token $packages) -ne $objectType) {
        throw 'npm package-lock does not contain an object packages closure.'
    }
    if ($null -eq $lockfileVersionToken -or (Get-NpmJsonTokenType -Token $lockfileVersionToken) -ne $integerType -or
        [string](Get-NpmJsonScalarValue -Token $lockfileVersionToken) -notin @('2', '3')) {
        $actualLockfileVersion = if ($null -eq $lockfileVersionToken) { '<missing>' }
            elseif ((Get-NpmJsonTokenType -Token $lockfileVersionToken) -in @('Object','Array')) {
                "<$((Get-NpmJsonTokenType -Token $lockfileVersionToken))>"
            }
            else { Get-NpmJsonScalarValue -Token $lockfileVersionToken }
        throw "npm package-lock must use integer lockfileVersion 2 or 3. Actual='$actualLockfileVersion'."
    }

    $rootProject = Get-NpmJsonObjectProperty -Token $packages -Name ''
    $rootDependenciesObject = $null
    if ($null -ne $rootProject) {
        $rootDependenciesObject = Get-NpmJsonObjectProperty -Token $rootProject -Name 'dependencies'
    }
    if ($null -eq $rootProject -or (Get-NpmJsonTokenType -Token $rootProject) -ne $objectType -or
        $null -eq $rootDependenciesObject -or (Get-NpmJsonTokenType -Token $rootDependenciesObject) -ne $objectType) {
        throw 'npm package-lock is missing its root project dependency entry.'
    }
    $rootDependencies = @(Get-NpmJsonObjectProperties -Token $rootDependenciesObject)
    if ($rootDependencies.Count -ne 1 -or [string]$rootDependencies[0].Name -cne 'skill-tools' -or
        (Get-NpmJsonTokenType -Token $rootDependencies[0].Value) -ne $stringType -or
        [string](Get-NpmJsonScalarValue -Token $rootDependencies[0].Value) -cne $ExpectedVersion) {
        throw "npm package-lock root dependencies must bind only skill-tools@$ExpectedVersion."
    }

    $approved = Normalize-RegistryUri -Value $ApprovedRegistry
    $entries = @()
    foreach ($property in @(Get-NpmJsonObjectProperties -Token $packages | Sort-Object Name)) {
        $packagePath = [string]$property.Name
        if ($packagePath -ceq '') {
            continue
        }
        if ([string]::IsNullOrWhiteSpace($packagePath)) {
            throw 'npm lock contains a non-root whitespace package path.'
        }
        if (@($packagePath.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0) {
            throw 'npm lock contains a package path with control characters.'
        }
        $package = $property.Value
        if ((Get-NpmJsonTokenType -Token $package) -ne $objectType) {
            throw "npm lock entry '$packagePath' must be an object."
        }
        $versionToken = Get-NpmJsonObjectProperty -Token $package -Name 'version'
        $resolvedToken = Get-NpmJsonObjectProperty -Token $package -Name 'resolved'
        $integrityToken = Get-NpmJsonObjectProperty -Token $package -Name 'integrity'
        $linkToken = Get-NpmJsonObjectProperty -Token $package -Name 'link'
        $inBundleToken = Get-NpmJsonObjectProperty -Token $package -Name 'inBundle'
        if ($null -eq $versionToken -or (Get-NpmJsonTokenType -Token $versionToken) -ne $stringType -or
            $null -eq $resolvedToken -or (Get-NpmJsonTokenType -Token $resolvedToken) -ne $stringType -or
            $null -eq $integrityToken -or (Get-NpmJsonTokenType -Token $integrityToken) -ne $stringType -or
            ($null -ne $linkToken -and ((Get-NpmJsonTokenType -Token $linkToken) -ne $booleanType -or [bool](Get-NpmJsonScalarValue -Token $linkToken))) -or
            ($null -ne $inBundleToken -and ((Get-NpmJsonTokenType -Token $inBundleToken) -ne $booleanType -or [bool](Get-NpmJsonScalarValue -Token $inBundleToken)))) {
            throw "npm lock entry '$packagePath' lacks string version/resolved/integrity or uses a link/bundled package."
        }
        $version = [string](Get-NpmJsonScalarValue -Token $versionToken)
        $resolved = [string](Get-NpmJsonScalarValue -Token $resolvedToken)
        $integrity = [string](Get-NpmJsonScalarValue -Token $integrityToken)
        foreach ($identityValue in @($version, $resolved, $integrity)) {
            if (@($identityValue.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -gt 0) {
                throw "npm lock entry '$packagePath' contains control characters in closure identity fields."
            }
        }
        if ([string]::IsNullOrWhiteSpace($version) -or [string]::IsNullOrWhiteSpace($resolved) -or
            -not (Test-NpmSha512Integrity -Integrity $integrity)) {
            throw "npm lock entry '$packagePath' lacks version, approved resolved URL, or SHA-512 integrity."
        }
        try {
            $resolvedUri = [Uri]$resolved
        }
        catch {
            throw "npm lock entry '$packagePath' has invalid resolved URL '$resolved'."
        }
        if (-not $resolvedUri.IsAbsoluteUri -or $resolvedUri.Scheme -cne 'https' -or
            -not [string]::IsNullOrEmpty($resolvedUri.UserInfo) -or
            -not [string]::IsNullOrEmpty($resolvedUri.Query) -or
            -not [string]::IsNullOrEmpty($resolvedUri.Fragment) -or
            -not $resolvedUri.AbsoluteUri.StartsWith($approved, [StringComparison]::Ordinal)) {
            throw "npm lock entry '$packagePath' resolved from untrusted endpoint '$resolved'."
        }
        $entries += [pscustomobject][ordered]@{
            path = $packagePath
            version = $version
            resolved = $resolved
            integrity = $integrity
        }
    }
    if ($entries.Count -eq 0) {
        throw 'npm package-lock dependency closure is empty.'
    }
    $root = @($entries | Where-Object { $_.path -ceq 'node_modules/skill-tools' })
    if ($root.Count -ne 1 -or [string]$root[0].version -cne $ExpectedVersion -or
        [string]$root[0].integrity -cne $ExpectedRootIntegrity) {
        throw 'npm package-lock root version or integrity does not match the resolved skill-tools package.'
    }
    $rootPackage = Get-NpmJsonObjectProperty -Token $packages -Name 'node_modules/skill-tools'
    $rootBinObject = $null
    if ($null -ne $rootPackage) {
        $rootBinObject = Get-NpmJsonObjectProperty -Token $rootPackage -Name 'bin'
    }
    $rootBins = @()
    if ($null -ne $rootBinObject -and (Get-NpmJsonTokenType -Token $rootBinObject) -eq $objectType) {
        $rootBins = @(Get-NpmJsonObjectProperties -Token $rootBinObject)
    }
    if ($rootBins.Count -ne 1 -or [string]$rootBins[0].Name -cne 'skill-tools' -or
        (Get-NpmJsonTokenType -Token $rootBins[0].Value) -ne $stringType) {
        throw 'npm package-lock contains an unsafe or missing skill-tools bin target.'
    }
    try {
        $rootBinTarget = Get-CanonicalNpmBinTarget `
            -Value ([string](Get-NpmJsonScalarValue -Token $rootBins[0].Value)) `
            -Context 'npm package-lock skill-tools bin target'
    }
    catch {
        throw "npm package-lock contains an unsafe or missing skill-tools bin target. $($_.Exception.Message)"
    }

    $canonicalLines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($entry in $entries) {
        [void]$canonicalLines.Add("$($entry.path)`t$($entry.version)`t$($entry.resolved)`t$($entry.integrity)")
    }
    $canonicalLines.Sort([StringComparer]::Ordinal)
    $canonical = [string]::Join("`n", $canonicalLines) + "`n"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $closureSha256 = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    return [ordered]@{
        packageLockSha256 = Get-BytesSha256 -Bytes $lockBytes
        closureSha256 = $closureSha256
        rootBinTarget = $rootBinTarget
        entries = $entries
    }
}

function Test-NpmSha512Integrity {
    param([Parameter(Mandatory = $true)][string] $Integrity)

    if ($Integrity -notmatch '^sha512-(?<value>[A-Za-z0-9+/]+={0,2})\z') {
        return $false
    }
    try {
        return ([Convert]::FromBase64String($Matches.value).Length -eq 64)
    }
    catch {
        return $false
    }
}

function Assert-NoConflictingGoEnvironment {
    param(
        [Parameter(Mandatory = $true)] $ExpectedEnvironment,
        [string[]] $DeniedEnvironmentNames = @()
    )

    foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
        $actual = [Environment]::GetEnvironmentVariable([string]$entry.Key, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrEmpty($actual)) {
            continue
        }
        if ([string]$actual -cne [string]$entry.Value) {
            throw "Untrusted Go environment override for '$($entry.Key)': '$actual'. Expected '$($entry.Value)'."
        }
    }
    foreach ($name in $DeniedEnvironmentNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Go environment override for '$name': '$actual'. Expected an unset value."
        }
    }
}

function Assert-NoConflictingGoTransportEnvironment {
    $transportValidatorFunction = $ExecutionContext.InvokeCommand.GetCommand(
        'Assert-GoTransportEnvironmentValues',
        [System.Management.Automation.CommandTypes]::Function,
        $null
    )
    if ($null -eq $transportValidatorFunction -or $transportValidatorFunction.CommandType -ne [System.Management.Automation.CommandTypes]::Function) {
        throw 'The approved Go transport environment validator function is unavailable.'
    }
    & $transportValidatorFunction -EnvironmentReader {
        param([string] $Name)
        [Environment]::GetEnvironmentVariable($Name, [EnvironmentVariableTarget]::Process)
    }
}

function Assert-GoTransportEnvironmentValues {
    param([Parameter(Mandatory = $true)][scriptblock] $EnvironmentReader)

    foreach ($name in $trustedGoTransportEnvironmentNames) {
        $actual = [string](& $EnvironmentReader $name)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Go transport environment override for '$name'; official release metadata requires the host default transport and trust roots to be unset."
        }
    }
}

function Invoke-WithApprovedGoWebTransport {
    param([Parameter(Mandatory = $true)][scriptblock] $Action)

    # PowerShell 5.1 uses process-global WebRequest transport state. Clear the
    # caller's proxy and certificate state for the authenticated request, then
    # restore the exact objects even when the request fails. CertificatePolicy
    # was removed from newer runtimes, so use reflection instead of binding the
    # property on hosts where it does not exist.
    $previousDefaultProxy = [System.Net.WebRequest]::DefaultWebProxy
    $previousCertificateCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    $servicePointManagerType = [System.Net.ServicePointManager]
    $certificatePolicyProperty = $servicePointManagerType.GetProperty('CertificatePolicy')
    $previousCertificatePolicy = if ($null -eq $certificatePolicyProperty) {
        $null
    }
    else {
        $certificatePolicyProperty.GetValue($null, $null)
    }
    $defaultCertificatePolicy = $null
    if ($null -ne $certificatePolicyProperty) {
        # .NET Framework exposes the legacy policy as an interface and keeps
        # its framework-default implementation internal. Instantiate that
        # implementation explicitly so a caller-provided policy is replaced
        # by the framework default rather than by a null policy.
        $defaultCertificatePolicyType = $servicePointManagerType.Assembly.GetType('System.Net.DefaultCertPolicy', $false)
        if ($null -eq $defaultCertificatePolicyType) {
            throw 'The framework default certificate policy type could not be resolved.'
        }
        try {
            $defaultCertificatePolicy = [Activator]::CreateInstance($defaultCertificatePolicyType, $true)
        }
        catch {
            throw "The framework default certificate policy could not be instantiated: $($_.Exception.Message)"
        }
        if ($null -eq $defaultCertificatePolicy -or
            -not $certificatePolicyProperty.PropertyType.IsInstanceOfType($defaultCertificatePolicy)) {
            throw 'The framework default certificate policy has an unexpected type.'
        }
    }
    try {
        [System.Net.WebRequest]::DefaultWebProxy = $null
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
        if ($null -ne $certificatePolicyProperty) {
            [void]$certificatePolicyProperty.SetValue($null, $defaultCertificatePolicy, $null)
        }
        return & $Action
    }
    finally {
        if ($null -ne $certificatePolicyProperty) {
            [void]$certificatePolicyProperty.SetValue($null, $previousCertificatePolicy, $null)
        }
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $previousCertificateCallback
        [System.Net.WebRequest]::DefaultWebProxy = $previousDefaultProxy
    }
}

function Invoke-WithApprovedGoEnvironment {
    param(
        [Parameter(Mandatory = $true)] $ExpectedEnvironment,
        [Parameter(Mandatory = $true)] $DistributionPolicy,
        [string] $InstallBinPath,
        [string] $GoCommandPath,
        [scriptblock] $EnvironmentProbe,
        [Parameter(Mandatory = $true)][scriptblock] $Action
    )

    Assert-NoConflictingGoEnvironment -ExpectedEnvironment $ExpectedEnvironment -DeniedEnvironmentNames $deniedGoEnvironmentNames
    Assert-NoConflictingGoTransportEnvironment
    $dynamicNames = @('GOMODCACHE', 'GOCACHE', 'GOTMPDIR', 'GOBIN')
    foreach ($name in $dynamicNames) {
        $actual = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if (-not [string]::IsNullOrEmpty($actual)) {
            throw "Untrusted Go environment override for '$name': '$actual'. Expected an unset value."
        }
    }
    foreach ($entry in $trustedGoDistribution.GetEnumerator()) {
        $actual = $DistributionPolicy.($entry.Key)
        if ($entry.Value -is [bool]) {
            if ($actual -isnot [bool] -or [bool]$actual -ne [bool]$entry.Value) {
                throw "Unsupported Go distribution control '$($entry.Key)'."
            }
        }
        elseif ($actual -isnot [string] -or [string]$actual -cne [string]$entry.Value) {
            throw "Unsupported Go distribution control '$($entry.Key)'."
        }
    }

    $previous = [ordered]@{}
    $workRoot = Join-Path ([IO.Path]::GetTempPath()) ("standard-go-work-{0}" -f [guid]::NewGuid().ToString('N'))
    $moduleCachePath = Join-Path $workRoot 'module-cache'
    $buildCachePath = Join-Path $workRoot 'build-cache'
    $temporaryPath = Join-Path $workRoot 'tmp'
    $effectiveBinPath = if ([string]::IsNullOrWhiteSpace($InstallBinPath)) {
        Join-Path $workRoot 'bin'
    }
    else {
        [IO.Path]::GetFullPath($InstallBinPath)
    }
    try {
        $allNames = @(Get-OrdinalUniqueStrings -Values @(
            @($ExpectedEnvironment.Keys) + $deniedGoEnvironmentNames + $dynamicNames
        ))
        foreach ($name in $allNames) {
            $previous[$name] = [Environment]::GetEnvironmentVariable([string]$name, [EnvironmentVariableTarget]::Process)
            [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
        }
        foreach ($entry in $ExpectedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable([string]$entry.Key, [string]$entry.Value, [EnvironmentVariableTarget]::Process)
        }
        foreach ($path in @($moduleCachePath, $buildCachePath, $temporaryPath, $effectiveBinPath)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
        [Environment]::SetEnvironmentVariable('GOMODCACHE', $moduleCachePath, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('GOCACHE', $buildCachePath, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('GOTMPDIR', $temporaryPath, [EnvironmentVariableTarget]::Process)
        [Environment]::SetEnvironmentVariable('GOBIN', $effectiveBinPath, [EnvironmentVariableTarget]::Process)

        $processGoEnv = [Environment]::GetEnvironmentVariable('GOENV', [EnvironmentVariableTarget]::Process)
        if ([string]$processGoEnv -cne 'off') {
            throw "Canonical Go process environment requires GOENV=off. Actual='$processGoEnv'."
        }

        $effectiveNames = @(Get-OrdinalUniqueStrings -Values @(
            @($ExpectedEnvironment.Keys) + $dynamicNames
        ))
        $goCommand = $null
        if ($null -eq $EnvironmentProbe) {
            $goCommand = if ([string]::IsNullOrWhiteSpace($GoCommandPath)) {
                Assert-Command -Name 'go'
            }
            else {
                Assert-NativeCommandPath -Path $GoCommandPath -Name 'go'
            }
            $effectiveJson = (Invoke-CheckedCommand -Command $goCommand -Arguments (@('env', '-json') + $effectiveNames)) -join "`n"
            $effective = $effectiveJson | ConvertFrom-Json
        }
        else {
            $effective = & $EnvironmentProbe $effectiveNames
            if ($null -eq $effective) {
                throw 'The injected Go environment probe returned no evidence.'
            }
        }
        foreach ($name in $ExpectedEnvironment.Keys) {
            $property = $effective.PSObject.Properties[[string]$name]
            if ($null -eq $property) {
                throw "Go environment evidence omitted approved setting '$name'."
            }
            $actual = [string]$property.Value
            $expected = [string]$ExpectedEnvironment[$name]
            if ([string]$name -ceq 'GOENV' -and $expected -ceq 'off') {
                if ($actual -cne '' -and $actual -cne 'off') {
                    throw "Go did not confirm disabled environment configuration for 'GOENV': '$actual'. Expected an empty effective configuration path or 'off'."
                }
                continue
            }
            if ($actual -cne $expected) {
                throw "Go did not apply approved environment for '$name': '$actual'. Expected '$expected'."
            }
        }
        $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
            [StringComparison]::OrdinalIgnoreCase
        }
        else {
            [StringComparison]::Ordinal
        }
        $expectedPaths = [ordered]@{
            GOMODCACHE = $moduleCachePath
            GOCACHE = $buildCachePath
            GOTMPDIR = $temporaryPath
            GOBIN = $effectiveBinPath
        }
        foreach ($entry in $expectedPaths.GetEnumerator()) {
            $effectivePath = [IO.Path]::GetFullPath([string]$effective.($entry.Key))
            $expectedPath = [IO.Path]::GetFullPath([string]$entry.Value)
            if (-not [string]::Equals($effectivePath, $expectedPath, $pathComparison)) {
                throw "Go did not apply isolated path '$($entry.Key)=$expectedPath'. Actual='$effectivePath'."
            }
            if (@(Get-ChildItem -LiteralPath $expectedPath -Force).Count -ne 0) {
                throw "The isolated Go path '$($entry.Key)' was not empty before resolution: '$expectedPath'."
            }
        }

        return & $Action $goCommand $effectiveBinPath
    }
    finally {
        try {
            if (Test-Path -LiteralPath $workRoot) {
                if ($null -ne $goCommand) {
                    [void](Invoke-CheckedCommand -Command $goCommand -Arguments @('clean', '-cache', '-modcache'))
                }
                Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop
            }
        }
        finally {
            foreach ($entry in $previous.GetEnumerator()) {
                [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, [EnvironmentVariableTarget]::Process)
            }
        }
    }
}

function Get-OfficialLatestStableGoRuntimeVersion {
    $callerParameterDefaults = $PSDefaultParameterValues
    $PSDefaultParameterValues = @{}
    try {
        $transportEnvironmentFunction = $ExecutionContext.InvokeCommand.GetCommand(
            'Assert-NoConflictingGoTransportEnvironment',
            [System.Management.Automation.CommandTypes]::Function,
            $null
        )
        if ($null -eq $transportEnvironmentFunction -or $transportEnvironmentFunction.CommandType -ne [System.Management.Automation.CommandTypes]::Function) {
            throw 'The approved Go transport environment boundary function is unavailable.'
        }
        & $transportEnvironmentFunction
        try {
            # Invoke-RestMethod returns the JSON array as one Object[] value. Do not
            # wrap that value in @(), which would make the metadata parser see one
            # array entry instead of the individual official release objects.
            $webTransportFunction = $ExecutionContext.InvokeCommand.GetCommand(
                'Invoke-WithApprovedGoWebTransport',
                [System.Management.Automation.CommandTypes]::Function,
                $null
            )
            if ($null -eq $webTransportFunction -or $webTransportFunction.CommandType -ne [System.Management.Automation.CommandTypes]::Function) {
                throw 'The approved Go web transport boundary function is unavailable.'
            }
            $metadata = & $webTransportFunction -Action {
                $requestParameters = @{
                    Uri = $trustedGoRuntimeSource
                    Headers = @{ Accept = 'application/json' }
                    Method = 'Get'
                    MaximumRedirection = 0
                    ErrorAction = 'Stop'
                }
                $invokeRestMethod = @(Microsoft.PowerShell.Core\Get-Command -Name 'Microsoft.PowerShell.Utility\Invoke-RestMethod' -CommandType Cmdlet -ErrorAction Stop)[0]
                if ($null -eq $invokeRestMethod -or -not $invokeRestMethod.Parameters.ContainsKey('Uri')) {
                    throw 'The approved Invoke-RestMethod cmdlet is unavailable.'
                }
                if ($invokeRestMethod.Parameters.ContainsKey('NoProxy')) {
                    $requestParameters['NoProxy'] = $true
                }
                & $invokeRestMethod @requestParameters
            }
        }
        catch {
            throw "Could not retrieve official Go release metadata from '$trustedGoRuntimeSource': $($_.Exception.Message)"
        }
    }
    finally {
        $PSDefaultParameterValues = $callerParameterDefaults
    }
    $metadataFunction = $ExecutionContext.InvokeCommand.GetCommand(
        'Get-OfficialLatestStableGoRuntimeVersionFromMetadata',
        [System.Management.Automation.CommandTypes]::Function,
        $null
    )
    if ($null -eq $metadataFunction -or $metadataFunction.CommandType -ne [System.Management.Automation.CommandTypes]::Function) {
        throw 'The official Go metadata parser function is unavailable.'
    }
    & $metadataFunction -ReleaseMetadata $metadata
}

function Get-OfficialLatestStableGoRuntimeVersionFromMetadata {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $ReleaseMetadata
    )

    $metadata = @($ReleaseMetadata)
    if ($metadata.Count -eq 0) {
        throw "Official Go release metadata from '$trustedGoRuntimeSource' was empty."
    }

    $stableCandidates = @()
    foreach ($release in $metadata) {
        if ($null -eq $release -or $null -eq $release.PSObject) {
            throw "Official Go release metadata from '$trustedGoRuntimeSource' contained a non-object entry."
        }
        $versionProperty = $release.PSObject.Properties['version']
        $stableProperty = $release.PSObject.Properties['stable']
        if ($null -eq $versionProperty -or $null -eq $stableProperty -or
            $versionProperty.Value -isnot [string] -or
            $stableProperty.Value -isnot [bool] -or
            [string]::IsNullOrWhiteSpace([string]$versionProperty.Value)) {
            throw "Official Go release metadata from '$trustedGoRuntimeSource' contained an invalid release entry."
        }
        if (-not [bool]$stableProperty.Value) {
            continue
        }

        $versionMatch = [regex]::Match([string]$versionProperty.Value, '^go(?<version>[0-9]+\.[0-9]+\.[0-9]+)$')
        if (-not $versionMatch.Success) {
            throw "Official Go release metadata from '$trustedGoRuntimeSource' marked '$($versionProperty.Value)' as stable, but it is not a stable release version."
        }
        try {
            $parsedVersion = [version]$versionMatch.Groups['version'].Value
        }
        catch {
            throw "Official Go release metadata from '$trustedGoRuntimeSource' contained an invalid stable version '$($versionProperty.Value)'."
        }
        $stableCandidates += [pscustomobject]@{
            version = [string]$versionMatch.Groups['version'].Value
            parsedVersion = $parsedVersion
        }
    }

    if ($stableCandidates.Count -eq 0) {
        throw "Official Go release metadata from '$trustedGoRuntimeSource' contained no stable release."
    }
    # Select through .NET so a caller cannot redirect release choice with
    # shadowed cmdlets or PSDefaultParameterValues.
    $latestCandidate = $null
    foreach ($candidate in $stableCandidates) {
        if ($null -eq $latestCandidate -or $candidate.parsedVersion -gt $latestCandidate.parsedVersion) {
            $latestCandidate = $candidate
        }
    }
    return [string]$latestCandidate.version
}

function Assert-ApprovedGoRuntimeEvidence {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $VersionOutput,
        [Parameter(Mandatory = $true)][string] $ExpectedVersionRule,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ExpectedRuntimeVersion,
        [Parameter(Mandatory = $true)][string] $OfficialLatestStableVersion
    )

    if ($ExpectedVersionRule -cne $trustedGoRuntimeVersionRule) {
        throw "Unsupported Go runtime version rule '$ExpectedVersionRule'. Expected '$trustedGoRuntimeVersionRule'."
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedRuntimeVersion) -or
        $ExpectedRuntimeVersion -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') {
        throw "The run-resolved latest stable Go runtime version is required and must be a stable semver string. Expected='$ExpectedRuntimeVersion'."
    }

    if ($ExpectedRuntimeVersion -cne $OfficialLatestStableVersion) {
        throw "The caller-supplied Go runtime '$ExpectedRuntimeVersion' does not match the independently authenticated latest stable Go runtime '$OfficialLatestStableVersion' from '$trustedGoRuntimeSource'."
    }

    $lines = @($VersionOutput | ForEach-Object { [string]$_ })
    if ($lines.Count -ne 1) {
        throw "Go returned ambiguous runtime-version evidence: '$($lines -join ' ')'."
    }
    $versionMatch = [regex]::Match(
        [string]$lines[0],
        '^go version go(?<version>[0-9]+\.[0-9]+\.[0-9]+) [^\s]+/[^\s]+$'
    )
    $runtimeVersion = if ($versionMatch.Success) { [string]$versionMatch.Groups['version'].Value } else { $null }
    if ([string]::IsNullOrWhiteSpace($runtimeVersion)) {
        throw "Unapproved Go runtime '$($lines[0])'. Expected a stable release matching '$trustedGoRuntimeVersionRule'."
    }
    if ($runtimeVersion -cne $OfficialLatestStableVersion) {
        throw "Go runtime '$runtimeVersion' does not match the independently authenticated latest stable Go runtime '$OfficialLatestStableVersion' from '$trustedGoRuntimeSource'."
    }

    return $runtimeVersion
}

function Get-ApprovedGoRuntimeVersion {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $VersionOutput,
        [Parameter(Mandatory = $true)][string] $ExpectedVersionRule,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ExpectedRuntimeVersion
    )

    $callerParameterDefaults = $PSDefaultParameterValues
    $PSDefaultParameterValues = @{}
    try {
        $officialRuntimeFunction = $ExecutionContext.InvokeCommand.GetCommand(
            'Get-OfficialLatestStableGoRuntimeVersion',
            [System.Management.Automation.CommandTypes]::Function,
            $null
        )
        if ($null -eq $officialRuntimeFunction -or $officialRuntimeFunction.CommandType -ne [System.Management.Automation.CommandTypes]::Function) {
            throw 'The approved Go runtime metadata resolver function is unavailable.'
        }
        $officialLatestStableVersion = & $officialRuntimeFunction
    }
    finally {
        $PSDefaultParameterValues = $callerParameterDefaults
    }
    $evidenceFunction = $ExecutionContext.InvokeCommand.GetCommand(
        'Assert-ApprovedGoRuntimeEvidence',
        [System.Management.Automation.CommandTypes]::Function,
        $null
    )
    if ($null -eq $evidenceFunction -or $evidenceFunction.CommandType -ne [System.Management.Automation.CommandTypes]::Function) {
        throw 'The approved Go runtime evidence validator function is unavailable.'
    }
    & $evidenceFunction `
        -VersionOutput $VersionOutput `
        -ExpectedVersionRule $ExpectedVersionRule `
        -ExpectedRuntimeVersion $ExpectedRuntimeVersion `
        -OfficialLatestStableVersion $officialLatestStableVersion
}

function Get-ApprovedPesterPayloadSha256 {
    param(
        [Parameter(Mandatory = $true)] $Closure,
        [Parameter(Mandatory = $true)][string] $Version
    )

    $metadataPath = "Pester/$Version/PSGetModuleInfo.xml"
    $metadataEntries = @($Closure.entries | Where-Object { [string]$_.path -ceq $metadataPath })
    if ($metadataEntries.Count -ne 1) {
        throw 'Pester payload is missing its one generated PowerShellGet metadata file.'
    }
    $payloadEntries = @($Closure.entries | Where-Object { [string]$_.path -cne $metadataPath })
    if ($payloadEntries.Count -eq 0) { throw 'Pester payload is empty.' }
    $canonical = ($payloadEntries | ForEach-Object { "$($_.path)`t$($_.sha256)`n" }) -join ''
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical))) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Assert-ApprovedPesterManifest {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Version
    )

    # Import-PowerShellDataFile parses the manifest as data. Test-ModuleManifest
    # and Import-Module may initialize downloaded code, so neither belongs in
    # the acquisition process.
    $manifest = Import-PowerShellDataFile -Path $Path -ErrorAction Stop
    if ($manifest -isnot [System.Collections.IDictionary] -or
        [string]$manifest.ModuleVersion -cne $Version -or
        [string]$manifest.RootModule -cne 'Pester.psm1' -or
        @($manifest.FunctionsToExport | Where-Object { [string]$_ -ceq 'Invoke-Pester' }).Count -ne 1 -or
        ($manifest.Contains('ScriptsToProcess') -and @($manifest['ScriptsToProcess']).Count -gt 0) -or
        ($manifest.Contains('NestedModules') -and @($manifest['NestedModules']).Count -gt 0) -or
        ($manifest.Contains('RequiredModules') -and @($manifest['RequiredModules']).Count -gt 0) -or
        ($manifest.Contains('RequiredAssemblies') -and @($manifest['RequiredAssemblies']).Count -gt 0)) {
        throw "Saved Pester manifest metadata does not bind Pester@$Version without initialization hooks."
    }
}

function Resolve-Pester {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)][string] $RepositoryEndpoint,
        [Parameter(Mandatory = $true)] $ApprovedPayload,
        [string] $RequestedInstallRoot
    )

    $repository = Get-PSRepository -Name PSGallery -ErrorAction Stop
    $expectedRepository = $RepositoryEndpoint.TrimEnd('/')
    $actualRepository = ([string]$repository.SourceLocation).TrimEnd('/')
    if ($actualRepository -cne $expectedRepository) {
        throw "Untrusted PSGallery endpoint '$actualRepository'. Expected '$expectedRepository'."
    }

    $package = Find-Module -Name Pester -Repository PSGallery -ErrorAction Stop
    $version = [string]$package.Version
    if ([string]::IsNullOrWhiteSpace($version) -or $version.Contains('-')) {
        throw "Could not resolve a stable Pester version. Resolved='$version'."
    }
    if ($version -cne [string]$ApprovedPayload.version) {
        throw "Latest-stable Pester version '$version' has no approved immutable payload identity."
    }

    $toolInstallPath = $null
    $modulePath = $null
    $moduleClosure = $null
    $approvedPayloadSha256 = $null
    if ($ShouldInstall) {
        $toolInstallPath = New-RunOwnedInstallDirectory -Root $RequestedInstallRoot -ToolName 'pester'
        try {
            Save-Module Pester -Repository PSGallery -RequiredVersion $version -Path $toolInstallPath -Force -ErrorAction Stop
            $modulePath = Join-Path (Join-Path (Join-Path $toolInstallPath 'Pester') $version) 'Pester.psd1'
            if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
                throw "Saved Pester module manifest was not found: $modulePath"
            }
            $moduleClosure = Get-DirectoryClosureIdentity -Path $toolInstallPath
            $approvedPayloadSha256 = Get-ApprovedPesterPayloadSha256 -Closure $moduleClosure -Version $version
            if ($approvedPayloadSha256 -cne [string]$ApprovedPayload.sha256) {
                throw "Unapproved Pester payload identity for latest-stable version '$version'."
            }
            Assert-ApprovedPesterManifest -Path $modulePath -Version $version
            $closureAfterManifest = Get-DirectoryClosureIdentity -Path $toolInstallPath
            if ([string]$closureAfterManifest.sha256 -cne [string]$moduleClosure.sha256) {
                throw 'Pester payload changed after manifest metadata verification.'
            }
        }
        catch {
            if (Test-Path -LiteralPath $toolInstallPath) {
                Remove-Item -LiteralPath $toolInstallPath -Recurse -Force -ErrorAction SilentlyContinue
            }
            throw
        }
    }

    $identity = "PowerShellGallery:Pester@$version#repository=$expectedRepository"
    if ($null -ne $moduleClosure) {
        $identity += "#approvedPayloadSha256=$approvedPayloadSha256#moduleClosureSha256=$($moduleClosure.sha256)"
    }
    return [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = $identity
        identityKind = 'approved-payload-and-installed-closure'
        installRoot = $toolInstallPath
        modulePath = $modulePath
        approvedPayloadSha256 = $approvedPayloadSha256
        executablePath = $modulePath
        executableSha256 = if ($null -eq $modulePath) { $null } else { Get-FileSha256 -Path $modulePath }
        dependencyClosureSha256 = if ($null -eq $moduleClosure) { $null } else { [string]$moduleClosure.sha256 }
        dependencyClosure = (Get-DependencyClosureEntriesArray -Closure $moduleClosure)
        installedClosureSha256 = if ($null -eq $moduleClosure) { $null } else { [string]$moduleClosure.sha256 }
    }
}

function Resolve-SkillTools {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)][string] $Registry,
        [Parameter(Mandatory = $true)] $DistributionPolicy,
        [string] $RequestedInstallRoot
    )

    if ([string]$DistributionPolicy.configIsolation -cne 'empty-config-and-workdir' -or
        [string]$DistributionPolicy.environmentOverridePolicy -cne 'deny-by-default' -or
        [string]$DistributionPolicy.dependencyAcquisition -cne 'package-lock' -or
        [string]$DistributionPolicy.installEnvironment -cne 'isolated-prefix' -or
        -not [bool]$DistributionPolicy.ignoreScripts -or
        -not [bool]$DistributionPolicy.recordDependencyClosureIntegrity) {
        throw 'npm distribution policy is incomplete or untrusted.'
    }

    $npmCommand = Assert-NpmCommand
    $nodeCommand = Assert-Command -Name 'node'
    $workRoot = Join-Path ([IO.Path]::GetTempPath()) ("standard-npm-work-{0}" -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $workRoot)
    $toolInstallPath = if ($ShouldInstall) {
        New-RunOwnedInstallDirectory -Root $RequestedInstallRoot -ToolName 'skill-tools'
    }
    else {
        $null
    }
    try {
        return Invoke-WithApprovedNpmEnvironment -NpmCommand $npmCommand -ApprovedRegistry $Registry -WorkPath $workRoot -Action {
            param($approvedRegistry)

            $registryArgument = "--registry=$approvedRegistry"
            $versionJson = (Invoke-CheckedCommand -Command $npmCommand -Arguments @('view', 'skill-tools', 'version', '--json', $registryArgument)) -join "`n"
            $parsedVersion = $versionJson | ConvertFrom-Json
            if ($parsedVersion -isnot [string]) {
                throw 'npm returned a non-string skill-tools version.'
            }
            $version = [string]$parsedVersion
            if (-not (Test-StableNpmPackageVersion -Version $version)) {
                throw "Could not resolve a stable SemVer skill-tools version. Resolved='$version'."
            }

            $integrityJson = (Invoke-CheckedCommand -Command $npmCommand -Arguments @('view', "skill-tools@$version", 'dist.integrity', '--json', $registryArgument)) -join "`n"
            $parsedIntegrity = $integrityJson | ConvertFrom-Json
            if ($parsedIntegrity -isnot [string] -or -not (Test-NpmSha512Integrity -Integrity ([string]$parsedIntegrity))) {
                throw 'npm did not return a SHA-512 package integrity for skill-tools.'
            }
            $integrity = [string]$parsedIntegrity

            $lockIdentity = $null
            $executablePath = $null
            $executableSha256 = $null
            $entryPointPath = $null
            $entryPointSha256 = $null
            $nodeSha256 = $null
            $installedClosureSha256 = $null
            $executableVerified = $false
            if ($ShouldInstall) {
                $controlledProjectConfig = @(
                    "registry=$approvedRegistry",
                    'dry-run=false',
                    'ignore-scripts=true',
                    'package-lock=true',
                    'omit-lockfile-registry-resolved=false',
                    'audit=false',
                    'fund=false'
                ) -join [Environment]::NewLine
                [IO.File]::WriteAllText((Join-Path $toolInstallPath '.npmrc'), $controlledProjectConfig + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
                $packageJsonPath = Join-Path $toolInstallPath 'package.json'
                $packageJson = [ordered]@{
                    name = 'standard-validation-skill-tools'
                    private = $true
                    version = '1.0.0'
                    dependencies = [ordered]@{ 'skill-tools' = $version }
                } | ConvertTo-Json -Depth 5
                [IO.File]::WriteAllText($packageJsonPath, $packageJson + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))

                [void](Invoke-CheckedCommand -Command $npmCommand -Arguments @(
                    'install', '--package-lock-only', '--ignore-scripts=true', '--dry-run=false',
                    '--package-lock=true', '--omit-lockfile-registry-resolved=false',
                    '--workspaces=false', '--global=false', '--replace-registry-host=never', '--no-audit', '--no-fund',
                    "--prefix=$toolInstallPath", $registryArgument
                ))
                $lockPath = Join-Path $toolInstallPath 'package-lock.json'
                if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
                    throw 'npm did not create the required package-lock.json.'
                }
                $lockIdentity = Get-NpmLockIdentity -LockPath $lockPath -ApprovedRegistry $approvedRegistry -ExpectedRootIntegrity $integrity -ExpectedVersion $version
                $lockBeforeInstall = [string]$lockIdentity.packageLockSha256

                [void](Invoke-CheckedCommand -Command $npmCommand -Arguments @(
                    'ci', '--ignore-scripts=true', '--dry-run=false', '--workspaces=false', '--global=false',
                    '--replace-registry-host=never', '--no-audit', '--no-fund',
                    "--prefix=$toolInstallPath", $registryArgument
                ))
                if ((Get-FileSha256 -Path $lockPath) -cne $lockBeforeInstall) {
                    throw 'npm ci modified the verified package-lock.json.'
                }
                [void](Invoke-CheckedCommand -Command $npmCommand -Arguments @(
                    'ls', '--all', '--loglevel=error', "--prefix=$toolInstallPath"
                ))
                $installedManifestPath = Join-Path $toolInstallPath 'node_modules/skill-tools/package.json'
                if (-not (Test-Path -LiteralPath $installedManifestPath -PathType Leaf)) {
                    throw "Installed skill-tools manifest was not found: $installedManifestPath"
                }
                $installedManifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $installedManifestPath | ConvertFrom-Json
                if ($installedManifest.name -isnot [string] -or [string]$installedManifest.name -cne 'skill-tools' -or
                    $installedManifest.version -isnot [string] -or [string]$installedManifest.version -cne $version) {
                    throw "Installed skill-tools package identity mismatch. Expected 'skill-tools@$version'."
                }
                $installedBins = @($installedManifest.bin.PSObject.Properties)
                if ($installedBins.Count -ne 1 -or [string]$installedBins[0].Name -cne 'skill-tools' -or
                    $installedBins[0].Value -isnot [string]) {
                    throw 'Installed skill-tools bin metadata does not match package-lock.'
                }
                try {
                    $installedBinTarget = Get-CanonicalNpmBinTarget `
                        -Value ([string]$installedBins[0].Value) `
                        -Context 'Installed skill-tools bin target'
                }
                catch {
                    throw "Installed skill-tools bin metadata does not match package-lock. $($_.Exception.Message)"
                }
                if ([string]$installedBinTarget -cne [string]$lockIdentity.rootBinTarget) {
                    throw 'Installed skill-tools bin metadata does not match package-lock.'
                }

                $packageRoot = [IO.Path]::GetFullPath((Join-Path $toolInstallPath 'node_modules/skill-tools')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
                $entryPointPath = [IO.Path]::GetFullPath((Join-Path $packageRoot $installedBinTarget))
                $pathComparison = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    [StringComparison]::OrdinalIgnoreCase
                }
                else {
                    [StringComparison]::Ordinal
                }
                if (-not $entryPointPath.StartsWith($packageRoot, $pathComparison) -or
                    -not (Test-Path -LiteralPath $entryPointPath -PathType Leaf)) {
                    throw 'Installed skill-tools entry point escapes or is absent from its package root.'
                }
                $executablePath = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    Join-Path $toolInstallPath 'node_modules\.bin\skill-tools.cmd'
                }
                else {
                    Join-Path $toolInstallPath 'node_modules/.bin/skill-tools'
                }
                if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                    throw "Installed skill-tools executable was not found: $executablePath"
                }
                [void](Invoke-CheckedCommand -Command $nodeCommand -Arguments @($entryPointPath, '--help'))
                $executableVerified = $true
                $executableSha256 = Get-FileSha256 -Path $executablePath
                $entryPointSha256 = Get-FileSha256 -Path $entryPointPath
                $nodeSha256 = Get-FileSha256 -Path $nodeCommand
                $installedClosureSha256 = [string](Get-DirectoryClosureIdentity -Path $toolInstallPath).sha256
                Add-ProcessPathValue -Name 'PATH' -Value (Split-Path -Parent $executablePath)
            }

            $identity = "npm:skill-tools@$version#$integrity#registry=$approvedRegistry"
            if ($null -ne $lockIdentity) {
                $identity += "#packageLockSha256=$($lockIdentity.packageLockSha256)#dependencyClosureSha256=$($lockIdentity.closureSha256)#executableSha256=$executableSha256#installedClosureSha256=$installedClosureSha256"
            }
            return [ordered]@{
                resolvedVersion = $version
                resolvedIdentity = $identity
                identityKind = 'registry-integrity-and-locked-dependency-closure'
                installRoot = $toolInstallPath
                executablePath = $executablePath
                executableSha256 = $executableSha256
                packageLockSha256 = if ($null -eq $lockIdentity) { $null } else { [string]$lockIdentity.packageLockSha256 }
                dependencyClosureSha256 = if ($null -eq $lockIdentity) { $null } else { [string]$lockIdentity.closureSha256 }
                dependencyClosure = (Get-DependencyClosureEntriesArray -Closure $lockIdentity)
                installedClosureSha256 = $installedClosureSha256
                entryPointPath = $entryPointPath
                entryPointSha256 = $entryPointSha256
                nodePath = $nodeCommand
                nodeSha256 = $nodeSha256
                executableVerified = $executableVerified
            }
        }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($toolInstallPath) -and (Test-Path -LiteralPath $toolInstallPath)) {
            Remove-Item -LiteralPath $toolInstallPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $workRoot) {
            Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-SkillValidator {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)] $ToolPolicy,
        [string] $RequestedInstallRoot,
        [string] $ExpectedGoRuntimeVersion,
        [string] $GoCommandPath
    )

    $modulePath = 'github.com/agent-ecosystem/skill-validator'
    $commandPath = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    $expectedEnvironment = [ordered]@{}
    foreach ($entry in $trustedGoEnvironment.GetEnumerator()) {
        $expectedEnvironment[$entry.Key] = [string]$ToolPolicy.goEnvironment.($entry.Key)
    }

    $toolInstallPath = if ($ShouldInstall) {
        New-RunOwnedInstallDirectory -Root $RequestedInstallRoot -ToolName 'skill-validator'
    }
    else {
        $null
    }
    $installBinPath = if ($ShouldInstall) { Join-Path $toolInstallPath 'bin' } else { $null }

    try {
        return Invoke-WithApprovedGoEnvironment -ExpectedEnvironment $expectedEnvironment -DistributionPolicy $ToolPolicy.goDistribution -InstallBinPath $installBinPath -GoCommandPath $GoCommandPath -Action {
            param($goCommand, $effectiveBinPath)

            $approvedRuntimeFunction = $ExecutionContext.InvokeCommand.GetCommand(
                'Get-ApprovedGoRuntimeVersion',
                [System.Management.Automation.CommandTypes]::Function,
                $null
            )
            if ($null -eq $approvedRuntimeFunction -or $approvedRuntimeFunction.CommandType -ne [System.Management.Automation.CommandTypes]::Function) {
                throw 'The approved Go runtime evidence authenticator function is unavailable.'
            }
            $goVersionOutput = @(Invoke-CheckedCommand -Command $goCommand -Arguments @('version'))
            $goRuntimeVersion = & $approvedRuntimeFunction `
                -VersionOutput $goVersionOutput `
                -ExpectedVersionRule ([string]$ToolPolicy.goRuntimeVersion) `
                -ExpectedRuntimeVersion $ExpectedGoRuntimeVersion
            $goVersionMatch = [regex]::Match(
                [string]$goVersionOutput[0],
                '^go version go(?<version>[0-9]+\.[0-9]+\.[0-9]+) (?<os>[^\s]+)/(?<architecture>[^\s]+)$'
            )
            if (-not $goVersionMatch.Success) {
                throw 'Approved Go runtime evidence did not expose a stable OS/architecture identity.'
            }
            $goRuntimeSha256 = Get-FileSha256 -Path $goCommand

            $metadataJson = (Invoke-CheckedCommand -Command $goCommand -Arguments @('list', '-m', '-json', "$modulePath@latest")) -join "`n"
            $metadata = $metadataJson | ConvertFrom-Json
            $version = [string]$metadata.Version
            if ([string]$metadata.Path -cne $modulePath -or -not (Test-StableGoModuleVersion -Version $version)) {
                throw "Go did not resolve the expected stable release for skill-validator. Path='$($metadata.Path)' Version='$version'."
            }

            $executablePath = $null
            $executableSha256 = $null
            $installedClosure = $null
            if ($ShouldInstall) {
                [void](Invoke-CheckedCommand -Command $goCommand -Arguments @('install', "$commandPath@$version"))
                $executableName = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    'skill-validator.exe'
                }
                else {
                    'skill-validator'
                }
                $executablePath = [IO.Path]::GetFullPath((Join-Path $effectiveBinPath $executableName))
                if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
                    throw "Installed skill-validator executable was not found: $executablePath"
                }

                $buildInfo = @(Invoke-CheckedCommand -Command $goCommand -Arguments @('version', '-m', $executablePath))
                $modulePattern = '^\s*mod\s+{0}\s+{1}\s+h1:[A-Za-z0-9+/=]+\s*$' -f
                    [regex]::Escape($modulePath), [regex]::Escape($version)
                if (@($buildInfo | Where-Object { $_ -match $modulePattern }).Count -ne 1) {
                    throw "Installed skill-validator build identity did not bind '$modulePath@$version'."
                }
                [void](Invoke-CheckedCommand -Command $executablePath -Arguments @('--help'))
                $executableSha256 = Get-FileSha256 -Path $executablePath
                $installedClosure = Get-DirectoryClosureIdentity -Path $toolInstallPath
                Add-ProcessPathValue -Name 'PATH' -Value $effectiveBinPath
            }

            $identity = "go:$modulePath@$version#goRuntime=$goRuntimeVersion#goRuntimeSource=$trustedGoRuntimeSource#proxy=$($ToolPolicy.proxy)#sumdb=$($ToolPolicy.checksumDatabase)#moduleCache=$($ToolPolicy.goDistribution.moduleCacheIsolation)#buildCache=$($ToolPolicy.goDistribution.buildCacheIsolation)#goflags=empty#temporaryDirectory=$($ToolPolicy.goDistribution.temporaryDirectoryIsolation)#binaryInstall=$($ToolPolicy.goDistribution.binaryInstallIsolation)"
            if ($null -ne $installedClosure) {
                $identity += "#binarySha256=$executableSha256#installedClosureSha256=$($installedClosure.sha256)"
            }
            return [ordered]@{
                resolvedVersion = $version
                resolvedIdentity = $identity
                identityKind = 'go-module-version-build-info-and-binary-hash'
                installRoot = $toolInstallPath
                executablePath = $executablePath
                executableSha256 = $executableSha256
                dependencyClosureSha256 = if ($null -eq $installedClosure) { $null } else { [string]$installedClosure.sha256 }
                dependencyClosure = (Get-DependencyClosureEntriesArray -Closure $installedClosure)
                installedClosureSha256 = if ($null -eq $installedClosure) { $null } else { [string]$installedClosure.sha256 }
                goRuntimeVersion = $goRuntimeVersion
                goRuntimeSource = $trustedGoRuntimeSource
                goRuntimePath = $goCommand
                goRuntimeSha256 = $goRuntimeSha256
                goRuntimeVersionOutput = $goVersionOutput
                goRuntimeOs = [string]$goVersionMatch.Groups['os'].Value
                goRuntimeArchitecture = [string]$goVersionMatch.Groups['architecture'].Value
                moduleCacheIsolation = [string]$ToolPolicy.goDistribution.moduleCacheIsolation
                buildCacheIsolation = [string]$ToolPolicy.goDistribution.buildCacheIsolation
                temporaryDirectoryIsolation = [string]$ToolPolicy.goDistribution.temporaryDirectoryIsolation
                binaryInstallIsolation = [string]$ToolPolicy.goDistribution.binaryInstallIsolation
            }
        }
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($toolInstallPath) -and (Test-Path -LiteralPath $toolInstallPath)) {
            Remove-Item -LiteralPath $toolInstallPath -Recurse -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Invoke-BoundedPowerShellWorker {
    param(
        [Parameter(Mandatory = $true)][string] $ScriptText,
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch] $AcquisitionStopwatch,
        [Parameter(Mandatory = $true)][int] $AcquisitionLimitSeconds
    )
    $encodedWorker = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ScriptText))
    $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    return @(Invoke-CheckedCommand -Command $hostPath -Arguments @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedWorker
    ) -TimeoutSeconds (Get-RemainingAcquisitionSeconds -Stopwatch $AcquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds))
}

function Remove-BoundedRunOwnedDirectory {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $AllowedRoot,
        [Parameter(Mandatory = $true)][string] $LeafPattern,
        [int] $CleanupTimeoutSeconds = 15
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -cnotmatch $LeafPattern) {
        throw "Run-owned cleanup path escaped its expected root: $resolved"
    }
    if (-not (Test-Path -LiteralPath $resolved)) { return }
    $item = Get-Item -Force -LiteralPath $resolved -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Run-owned cleanup target is not a regular directory: $resolved"
    }
    $path64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($resolved))
    $root64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($root))
    $pattern64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($LeafPattern))
    $worker = @'
$ErrorActionPreference = 'Stop'
function Decode([string]$value) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }
$path = [IO.Path]::GetFullPath((Decode '%PATH%'))
$root = Decode '%ROOT%'
$pattern = Decode '%PATTERN%'
if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $path) -cnotmatch $pattern) { throw 'Run-owned cleanup path changed before deletion.' }
if (Test-Path -LiteralPath $path) {
    $item = Get-Item -Force -LiteralPath $path
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Run-owned cleanup target changed before deletion.'
    }
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
}
'@
    $worker = $worker.Replace('%PATH%', $path64).Replace('%ROOT%', $root64).Replace('%PATTERN%', $pattern64)
    $encodedWorker = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($worker))
    $hostPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    [void](Invoke-CheckedCommand -Command $hostPath -Arguments @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedWorker
    ) -TimeoutSeconds $CleanupTimeoutSeconds)
}

function Invoke-BoundedInstalledSkillSpectorVerification {
    param(
        [Parameter(Mandatory = $true)][string] $VirtualEnvironmentPath,
        [Parameter(Mandatory = $true)][string] $InstallPath,
        [Parameter(Mandatory = $true)][string] $ExpectedVersion,
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch] $AcquisitionStopwatch,
        [Parameter(Mandatory = $true)][int] $AcquisitionLimitSeconds
    )
    $sourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Resolve-StandardValidationTool.ps1'))
    $encodedPaths = @{
        source = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sourcePath))
        policy = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$PolicyPath))
        venv = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($VirtualEnvironmentPath))
        install = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($InstallPath))
        version = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ExpectedVersion))
    }
    $worker = @'
$ErrorActionPreference = 'Stop'
function Decode([string]$value) { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value)) }
$source = Decode '%SOURCE%'
$policy = Decode '%POLICY%'
$venv = Decode '%VENV%'
$postInstallRoot = Decode '%INSTALL%'
$version = Decode '%VERSION%'
. $source -PolicyPath $policy -ValidatePolicyOnly | Out-Null
$metadata = Get-InstalledPythonDistributionMetadata -VirtualEnvironmentPath $venv -DistributionName 'skillspector'
if ([string]$metadata.version -cne $version) { throw "Installed SkillSpector version mismatch. Expected '$version', got '$($metadata.version)'." }
$executable = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    Join-Path $venv 'Scripts\skillspector.exe'
} else { Join-Path $venv 'bin/skillspector' }
$executable = [IO.Path]::GetFullPath($executable)
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "Installed SkillSpector executable was not found: $executable" }
$result = [ordered]@{
    schemaVersion = 1
    consoleEntryPoint = [string]$metadata.consoleEntryPoint
    executablePath = $executable
    executableSha256 = Get-FileSha256 -Path $executable
    installedClosureSha256 = (Get-DirectoryClosureIdentity -Path $postInstallRoot -ParallelContentHash).sha256
}
Write-Output ($result | ConvertTo-Json -Compress -Depth 5)
'@
    foreach ($key in $encodedPaths.Keys) {
        $worker = $worker.Replace("%$($key.ToUpperInvariant())%", [string]$encodedPaths[$key])
    }
    $output = @(Invoke-BoundedPowerShellWorker -ScriptText $worker `
        -AcquisitionStopwatch $AcquisitionStopwatch -AcquisitionLimitSeconds $AcquisitionLimitSeconds)
    $result = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    if ([int]$result.schemaVersion -ne 1 -or
        [string]$result.executableSha256 -cnotmatch '^[0-9a-f]{64}$' -or
        [string]$result.installedClosureSha256 -cnotmatch '^[0-9a-f]{64}$') {
        throw 'Bounded installed SkillSpector verification returned invalid evidence.'
    }
    return $result
}

function Resolve-SkillSpector {
    param(
        [bool] $ShouldInstall,
        [Parameter(Mandatory = $true)] $ToolPolicy,
        [string] $RequestedInstallRoot,
        [int] $AcquisitionLimitSeconds = 900
    )

    $acquisitionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $failureRoot=$null
    $diagnosticInstallRoot = if ([string]::IsNullOrWhiteSpace($RequestedInstallRoot)) {
        $base = if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { [IO.Path]::GetTempPath() } else { $env:RUNNER_TEMP }
        Join-Path $base 'standard-validation-tools'
    } else { $RequestedInstallRoot }
    if($ShouldInstall){
        # Resolve the parent once for allocation, diagnostics and failed-run
        # reclamation; OS aliases must not produce different containment roots.
        $diagnosticInstallRoot=Initialize-RunOwnedInstallRoot -Root $diagnosticInstallRoot
        $RequestedInstallRoot=$diagnosticInstallRoot
    }
    $failureRoot = if ($ShouldInstall) {
        Join-Path ([IO.Path]::GetFullPath($diagnosticInstallRoot)) ("skillspector-failure-{0}" -f $script:ResolverRunId)
    } else { $null }
    $dependencyResolutionPath = $null
    $tag = $null
    $digest = $null
    $closureHelperSha256 = $null
    trap {
        if (-not [string]::IsNullOrWhiteSpace($failureRoot)) {
            [void](New-Item -ItemType Directory -Path $failureRoot -Force -ErrorAction SilentlyContinue)
            $safeError = Protect-ResolverDiagnosticText -Text ([string]$_.Exception.Message) -Credential $script:ResolverGitHubApiToken
            $failure = [ordered]@{
                schemaVersion = 1
                kind = 'diagnostic-only'
                runId = $script:ResolverRunId
                phase = 'skillspector-acquisition'
                elapsedSeconds = [Math]::Round($acquisitionStopwatch.Elapsed.TotalSeconds, 3)
                releaseTag = if ($null -eq $tag) { $null } else { [string]$tag }
                rootAssetDigest = if ($null -eq $digest) { $null } else { [string]$digest }
                resolverHelperSha256 = if ($null -eq $closureHelperSha256) { $null } else { [string]$closureHelperSha256 }
                errorSummary = $safeError.Substring(0, [Math]::Min(2048, $safeError.Length))
            }
            [IO.File]::WriteAllText((Join-Path $failureRoot 'failure.json'), ($failure | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
        }
        break
    }
    $pythonCommand = Assert-Command -Name 'python'
    $closureHelperPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'Resolve-PythonWheelClosure.py'))
    if (-not (Test-Path -LiteralPath $closureHelperPath -PathType Leaf)) {
        throw "Python wheel closure helper not found: $closureHelperPath"
    }
    $closureHelperSha256 = Get-FileSha256 -Path $closureHelperPath
    $approvedIndex = Normalize-RegistryUri -Value ([string]$ToolPolicy.pythonPackageIndex)
    $approvedSourcesPath = Join-Path (Split-Path -Parent $PSScriptRoot) ([string]$ToolPolicy.approvedSources)
    $approvedSources = Get-SkillSpectorApprovedSources -Path $approvedSourcesPath
    $approvedSourceId = [string]$approvedSources.active
    $approvedEntry = $approvedSources.activeEntry
    Assert-NoConflictingPipEnvironment -ApprovedIndex $approvedIndex
    Assert-NoConflictingPythonEnvironment
    $headers = Get-GitHubHeaders
    try {
        $release = Invoke-BoundedGitHubGet -Uri ("https://api.github.com/repos/NVIDIA/SkillSpector/releases/tags/{0}" -f [string]$approvedEntry.releaseTag) -Headers $headers -Stopwatch $acquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds
        if ($null -eq $release -or [bool]$release.draft -or [bool]$release.prerelease) {
            throw 'GitHub did not return a stable SkillSpector release.'
        }

        $tag = [string]$release.tag_name
        if ($tag -cne [string]$approvedEntry.releaseTag) {
            throw "SkillSpector release tag mismatch. Expected '$($approvedEntry.releaseTag)', got '$tag'."
        }
        $version = [string]$approvedEntry.version

        $tagRef = Invoke-BoundedGitHubGet -Uri ("https://api.github.com/repos/NVIDIA/SkillSpector/git/ref/tags/{0}" -f $tag) -Headers $headers -Stopwatch $acquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds
        $commitSha = [string]$tagRef.object.sha
        $objectType = [string]$tagRef.object.type
        if ($objectType -eq 'tag') {
            $tagObject = Invoke-BoundedGitHubGet -Uri ("https://api.github.com/repos/NVIDIA/SkillSpector/git/tags/{0}" -f $commitSha) -Headers $headers -Stopwatch $acquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds
            $commitSha = [string]$tagObject.object.sha
            $objectType = [string]$tagObject.object.type
        }
        if ($objectType -cne 'commit' -or $commitSha -notmatch '^[0-9a-f]{40}$') {
            throw "SkillSpector tag '$tag' did not resolve to a full commit SHA."
        }
        if ($commitSha -cne [string]$approvedEntry.releaseCommit) {
            throw "SkillSpector release commit mismatch. Expected '$($approvedEntry.releaseCommit)', got '$commitSha'."
        }

        $wheelAssets = @($release.assets | Where-Object { [string]$_.name -ceq [string]$approvedEntry.wheelFileName })
        if ($wheelAssets.Count -ne 1) {
            throw "Expected exactly one approved SkillSpector wheel '$($approvedEntry.wheelFileName)'; found $($wheelAssets.Count)."
        }
        $wheel = $wheelAssets[0]
        $expectedWheelName = [string]$approvedEntry.wheelFileName
        if ([string]$wheel.name -cne $expectedWheelName) {
            throw "SkillSpector release tag/wheel filename mismatch. Tag '$tag' requires '$expectedWheelName', got '$($wheel.name)'."
        }
        $assetUri = Get-ApprovedSkillSpectorAssetUri -Value ([string]$wheel.browser_download_url) -Tag $tag -FileName $expectedWheelName

        $apiDigest = [string]$wheel.digest
        $digest = 'sha256:' + [string]$approvedEntry.wheelSha256
        if (-not [string]::IsNullOrWhiteSpace($apiDigest) -and $apiDigest -cne $digest) {
            throw "SkillSpector release asset digest mismatch. Expected '$digest', got '$apiDigest'."
        }
    }
    catch {
        $safeError = Protect-ResolverDiagnosticText -Text ([string]$_.Exception.Message) -Credential $script:ResolverGitHubApiToken
        if ($headers.ContainsKey('Authorization')) { [void]$headers.Remove('Authorization') }
        $script:ResolverGitHubApiToken = $null
        throw $safeError
    }

    $interpreterIsolation = [string]$ToolPolicy.pythonDistribution.interpreterIsolation
    $tempRoot = $null
    $wheelhouse = $null
    $closure = $null
    $installEnvironment = $null
    $toolInstallPath = $null
    $executablePath = $null
    $executableSha256 = $null
    $installedClosure = $null
    $backtrackingEvidence = $null
    $consoleEntryPoint = $null
    $installedMetadataVerification = $null
    try {
        $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("ss-{0}" -f [guid]::NewGuid().ToString('N'))
        $wheelhouse = Join-Path $tempRoot 'wheelhouse'
        [void](New-Item -ItemType Directory -Path $wheelhouse -Force)
        if ($ShouldInstall) {
            $toolInstallPath = New-RunOwnedInstallDirectory -Root $RequestedInstallRoot -ToolName 'skillspector'
            Assert-PythonWheelInstallPath -InstallPath $toolInstallPath
        }
        $wheelPath = Join-Path $tempRoot ([string]$wheel.name)
        try {
            [void](Invoke-BoundedGitHubGet -Uri $assetUri -Headers $headers -Stopwatch $acquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds -OutFile $wheelPath)
        }
        catch {
            $safeError = Protect-ResolverDiagnosticText -Text ([string]$_.Exception.Message) -Credential $script:ResolverGitHubApiToken
            throw $safeError
        }
        finally {
            if ($headers.ContainsKey('Authorization')) { [void]$headers.Remove('Authorization') }
            $script:ResolverGitHubApiToken = $null
            foreach ($name in @('STANDARD_VALIDATION_GITHUB_API_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN')) {
                [Environment]::SetEnvironmentVariable($name, [NullString]::Value, [EnvironmentVariableTarget]::Process)
            }
        }

        $actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $wheelPath).Hash.ToLowerInvariant()
        $expectedHash = [string]$approvedEntry.wheelSha256
        if ($actualHash -cne $expectedHash) {
            throw "SkillSpector wheel hash mismatch. Expected '$expectedHash', got '$actualHash'."
        }

        $wheelMetadata = Get-PythonWheelMetadata -WheelPath $wheelPath
        Assert-SkillSpectorWheelIdentity -ApprovedEntry $approvedEntry -WheelPath $wheelPath -WheelFileName ([string]$wheel.name) -MetadataName ([string]$wheelMetadata.name) -MetadataVersion ([string]$wheelMetadata.version)
        Assert-NoPythonDirectReferences -Metadata $wheelMetadata -WheelFileName ([string]$wheel.name)
        if ($ShouldInstall) {
            Assert-PythonWheelInstallPath -InstallPath $toolInstallPath -WheelPath $wheelPath
        }

        # The resolver clears all GitHub credential variables at script start;
        # keep this idempotent guard before third-party Python/package code.
        Remove-Item -LiteralPath 'Env:STANDARD_VALIDATION_GITHUB_API_TOKEN' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GITHUB_TOKEN' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GH_TOKEN' -Force -ErrorAction SilentlyContinue

        if ($ShouldInstall) {
            $venvPath = Join-Path $toolInstallPath 'venv'
            $dependencyResolutionPath = Join-Path $tempRoot 'dependency-resolution'
            $candidatePath = Join-Path $tempRoot 'verified-candidates'
            $installation = Invoke-WithApprovedPipEnvironment -ApprovedIndex $approvedIndex -Action {
                # Keep interpreter entries as regular files so the signed
                # installed closure can reject external/file symlinks.
                [void](Invoke-IsolatedPythonCommand -PythonCommand $pythonCommand -Arguments @('-S', '-m', 'venv', '--copies', $venvPath) -TimeoutSeconds (Get-RemainingAcquisitionSeconds -Stopwatch $acquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds))
                $venvPython = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
                    Join-Path $venvPath 'Scripts\python.exe'
                }
                else {
                    Join-Path $venvPath 'bin/python'
                }
                if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
                    throw "SkillSpector isolated virtual environment Python was not created: $venvPython"
                }

                $resolutionEvidence = Resolve-PythonWheelClosureFromApprovedIndex `
                    -PythonCommand $venvPython `
                    -HelperPath $closureHelperPath `
                    -ExpectedHelperSha256 $closureHelperSha256 `
                    -ApprovedIndex $approvedIndex `
                    -RootWheelPath $wheelPath `
                    -RootWheelSha256 $expectedHash `
                    -CandidatePath $candidatePath `
                    -WheelhousePath $wheelhouse `
                    -WorkPath $dependencyResolutionPath `
                    -AcquisitionStopwatch $acquisitionStopwatch `
                    -AcquisitionLimitSeconds $AcquisitionLimitSeconds

                $wheelhouseRoot = Join-Path $wheelhouse ([string]$wheel.name)
                if (-not (Test-Path -LiteralPath $wheelhouseRoot -PathType Leaf)) {
                    Copy-Item -LiteralPath $wheelPath -Destination $wheelhouseRoot -Force
                }
                $wheelhouseRootHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $wheelhouseRoot).Hash.ToLowerInvariant()
                if ($wheelhouseRootHash -cne $expectedHash) {
                    throw "SkillSpector root wheel changed during dependency acquisition. Expected '$expectedHash', got '$wheelhouseRootHash'."
                }

                $lockPath = Join-Path $tempRoot 'skillspector-dependency-lock.txt'
                $manifest = New-PythonWheelhouseLock -WheelhousePath $wheelhouse -LockPath $lockPath
                $rootEntry = @($manifest.entries | Where-Object { $_.normalizedName -eq 'skillspector' })
                if ($rootEntry.Count -ne 1 -or [string]$rootEntry[0].version -cne $version -or [string]$rootEntry[0].sha256 -cne $expectedHash) {
                    throw 'SkillSpector root wheel is not correctly bound into the dependency closure.'
                }
                Assert-PythonWheelhouseInstallPaths -InstallPath $toolInstallPath `
                    -WheelhousePath $wheelhouse -Manifest $manifest
                $selectedEntries = @($resolutionEvidence.selectedEntries)
                if ($selectedEntries.Count -ne @($manifest.entries).Count) {
                    throw "Offline backtracking selection count mismatch. Expected '$(@($manifest.entries).Count)', got '$($selectedEntries.Count)'."
                }
                foreach ($entry in @($manifest.entries)) {
                    $selectedMatches = @($selectedEntries | Where-Object {
                        [string]$_.normalizedName -ceq [string]$entry.normalizedName -and
                        [string]$_.version -ceq [string]$entry.version -and
                        [string]$_.file -ceq [string]$entry.file -and
                        [string]$_.sha256 -ceq [string]$entry.sha256
                    })
                    if ($selectedMatches.Count -ne 1) {
                        throw "Offline backtracking evidence did not bind '$($entry.file)'."
                    }
                }

                [void](Invoke-IsolatedPythonCommand -PythonCommand $venvPython -Arguments @(
                    '-B', '-m', 'pip', 'install', '--disable-pip-version-check', '--no-cache-dir',
                    '--no-index', "--find-links=$wheelhouse", '--require-hashes', '--no-deps', '--force-reinstall',
                    '--no-compile', '-r', $lockPath
                ) -TimeoutSeconds (Get-RemainingAcquisitionSeconds -Stopwatch $acquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds))

                # Verify metadata and hash the installed closure in a bounded
                # child without starting the unverified venv interpreter.
                $installedVerification = Invoke-BoundedInstalledSkillSpectorVerification `
                    -VirtualEnvironmentPath $venvPath -InstallPath $toolInstallPath `
                    -ExpectedVersion $version -AcquisitionStopwatch $acquisitionStopwatch `
                    -AcquisitionLimitSeconds $AcquisitionLimitSeconds

                return [ordered]@{
                    manifest = $manifest
                    executablePath = [string]$installedVerification.executablePath
                    executableSha256 = [string]$installedVerification.executableSha256
                    installedClosureSha256 = [string]$installedVerification.installedClosureSha256
                    consoleEntryPoint = [string]$installedVerification.consoleEntryPoint
                    installedMetadataVerification = 'static-dist-info-metadata'
                    resolutionEvidence = $resolutionEvidence
                }
            }
            $closure = $installation.manifest
            $backtrackingEvidence = $installation.resolutionEvidence
            $executablePath = [string]$installation.executablePath
            $consoleEntryPoint = [string]$installation.consoleEntryPoint
            $installedMetadataVerification = [string]$installation.installedMetadataVerification
            $installEnvironment = 'isolated-venv'
            $executableSha256 = [string]$installation.executableSha256
            $installedClosure = [ordered]@{ sha256 = [string]$installation.installedClosureSha256 }
            Add-ProcessPathValue -Name 'PATH' -Value (Split-Path -Parent $executablePath)
        }
        # Preserve diagnostic-only bytes before destructive cleanup. They also
        # cover failures in cleanup, identity construction, or the final budget
        # check; these files never constitute a successful tool receipt.
        Save-SkillSpectorFailureEvidence -WorkPath $dependencyResolutionPath -DestinationPath $failureRoot
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-BoundedRunOwnedDirectory -Path $tempRoot -AllowedRoot ([IO.Path]::GetTempPath()) `
                -LeafPattern '^ss-[0-9a-f]{32}$'
        }
    [void](Get-RemainingAcquisitionSeconds -Stopwatch $acquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds)

    $identity = "github:NVIDIA/SkillSpector@$tag#commit=$commitSha#asset=$digest#metadata=skillspector@$version#rootDirectReferences=blocked#credentialIsolation=github-token-cleared-before-python#dependencyClosure=unresolved"
    $identityKind = 'release-commit-asset-metadata'
    if ($null -ne $closure) {
        $identity = $identity.Replace('#dependencyClosure=unresolved', '#directReferences=blocked#pipOnlineDependencyTraversal=disabled#dependencyDiscovery=approved-simple-json-lazy#requiresPython=simple-json-wheel-metadata-normalized-specifier-set-current-interpreter#offlineBacktracking=verified')
        $identity += "#pythonIndex=$approvedIndex#pipVersion=$($backtrackingEvidence.pipVersion)#resolutionRounds=$($backtrackingEvidence.resolutionRounds)#candidateCount=$($backtrackingEvidence.candidateCount)#resolverHelperSha256=$closureHelperSha256#candidateInventorySha256=$($backtrackingEvidence.candidateInventorySha256)#selectionPlanSha256=$($backtrackingEvidence.selectionPlanSha256)#selectedClosureSha256=$($backtrackingEvidence.selectedClosureSha256)#installEnvironment=$installEnvironment#interpreterIsolation=$interpreterIsolation#installedMetadataVerification=$installedMetadataVerification#consoleEntryPoint=$consoleEntryPoint#offlineResolution=verified#dependencyClosureSha256=$($closure.closureSha256)#executableSha256=$executableSha256#installedClosureSha256=$($installedClosure.sha256)"
        $identityKind = 'release-commit-asset-metadata-dependency-closure-and-executable'
    }

    $resolvedResult = [ordered]@{
        resolvedVersion = $version
        resolvedIdentity = $identity
        identityKind = $identityKind
        installRoot = $toolInstallPath
        executablePath = $executablePath
        executableSha256 = $executableSha256
        pythonPackageIndex = $approvedIndex
        installEnvironment = $installEnvironment
        interpreterIsolation = $interpreterIsolation
        credentialIsolation = 'github-token-cleared-before-python'
        installedMetadataVerification = $installedMetadataVerification
        directReferencesAllowed = [bool]$ToolPolicy.pythonDistribution.allowDirectReferences
        pipOnlineDependencyTraversalAllowed = [bool]$ToolPolicy.pythonDistribution.allowPipOnlineDependencyTraversal
        dependencyDiscovery = [string]$ToolPolicy.pythonDistribution.candidateDiscovery
        requiresPythonPolicy = [string]$ToolPolicy.pythonDistribution.requiresPythonPolicy
        dependencyResolver = [string]$ToolPolicy.pythonDistribution.dependencyResolver
        yankedAllowed = [bool]$ToolPolicy.pythonDistribution.allowYanked
        resolverHelperPath = $closureHelperPath
        resolverHelperSha256 = $closureHelperSha256
        consoleEntryPoint = $consoleEntryPoint
        pipVersion = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.pipVersion }
        resolutionRounds = if ($null -eq $backtrackingEvidence) { $null } else { [int64]$backtrackingEvidence.resolutionRounds }
        candidateCount = if ($null -eq $backtrackingEvidence) { $null } else { [int64]$backtrackingEvidence.candidateCount }
        candidateInventorySha256 = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.candidateInventorySha256 }
        selectionPlanSha256 = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.selectionPlanSha256 }
        rawSelectionPlanSha256 = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.rawSelectionPlanSha256 }
        selectedClosureSha256 = if ($null -eq $backtrackingEvidence) { $null } else { [string]$backtrackingEvidence.selectedClosureSha256 }
        offlineResolutionVerified = if ($null -eq $closure) { $false } else { $true }
        dependencyClosureSha256 = if ($null -eq $closure) { $null } else { [string]$closure.closureSha256 }
        dependencyClosure = (Get-DependencyClosureEntriesArray -Closure $closure)
        installedClosureSha256 = if ($null -eq $installedClosure) { $null } else { [string]$installedClosure.sha256 }
        approvedSourceId = $approvedSourceId
        parserCorrection = [string]$approvedEntry.parserCorrection
    }
    [void](Get-RemainingAcquisitionSeconds -Stopwatch $acquisitionStopwatch -LimitSeconds $AcquisitionLimitSeconds)
    return $resolvedResult
    }
    catch {
        $acquisitionFailure = $_
        $safeError = Protect-ResolverDiagnosticText -Text ([string]$acquisitionFailure.Exception.Message) -Credential $script:ResolverGitHubApiToken
        if ($headers.ContainsKey('Authorization')) { [void]$headers.Remove('Authorization') }
        $script:ResolverGitHubApiToken = $null
        try { Save-SkillSpectorFailureEvidence -WorkPath $dependencyResolutionPath -DestinationPath $failureRoot }
        catch { Write-Warning ("Failure evidence preservation failed: {0}" -f $_.Exception.Message) }
        if (-not [string]::IsNullOrWhiteSpace($toolInstallPath) -and (Test-Path -LiteralPath $toolInstallPath)) {
            try {
                Remove-BoundedRunOwnedDirectory -Path $toolInstallPath -AllowedRoot $diagnosticInstallRoot `
                    -LeafPattern '^ss-[0-9a-f]{12}$'
            }
            catch { Write-Warning ("Run-owned install cleanup failed: {0}" -f $_.Exception.Message) }
        }
        throw $safeError
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempRoot) -and (Test-Path -LiteralPath $tempRoot)) {
            try {
                Remove-BoundedRunOwnedDirectory -Path $tempRoot -AllowedRoot ([IO.Path]::GetTempPath()) `
                    -LeafPattern '^ss-[0-9a-f]{32}$'
            }
            catch { Write-Warning ("Run-owned temporary cleanup failed: {0}" -f $_.Exception.Message) }
        }
    }
}

$policy = Get-Policy -Path $PolicyPath

if ($ValidatePolicyOnly) {
    $result = [ordered]@{
        schemaVersion = 1
        resolutionRunId = $script:ResolverRunId
        resolvedAtUtc = $script:ResolverResolvedAtUtc
        executionContext = $script:ResolverExecutionContext
        processOwnership = @($script:ResolverProcessReceipts.ToArray())
        policy = [string]$policy.policy
        sourceTrust = [ordered]@{
            enforcement = [string]$policy.sourceTrust.enforcement
            resolver = [string]$policy.sourceTrust.resolver
            failClosedOnMismatch = [bool]$policy.sourceTrust.failClosedOnMismatch
        }
        trustedSources = $trustedSources
        trustedRegistries = $trustedRegistries
        trustedPythonIndex = $trustedPythonIndex
        trustedPowerShellRepository = $trustedPowerShellRepository
        trustedGoRuntimeVersion = $trustedGoRuntimeVersionRule
        trustedGoEnvironment = $trustedGoEnvironment
        trustedGoDistribution = $trustedGoDistribution
        recordResolvedIdentityWhenAvailable = [bool]$policy.resolution.recordResolvedIdentityWhenAvailable
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($ToolName)) {
        throw 'ToolName is required unless -ValidatePolicyOnly is specified.'
    }

    $resolved = switch ($ToolName) {
        'pester' {
            Resolve-Pester -ShouldInstall ([bool]$Install) -RepositoryEndpoint ([string]$policy.tools.pester.repository) -ApprovedPayload $policy.tools.pester.approvedPayload -RequestedInstallRoot $InstallRoot
        }
        'skill-tools' {
            Resolve-SkillTools -ShouldInstall ([bool]$Install) -Registry ([string]$policy.tools.'skill-tools'.registry) -DistributionPolicy $policy.tools.'skill-tools'.npmDistribution -RequestedInstallRoot $InstallRoot
        }
        'skill-validator' {
            Resolve-SkillValidator `
                -ShouldInstall ([bool]$Install) `
                -ToolPolicy $policy.tools.'skill-validator' `
                -RequestedInstallRoot $InstallRoot `
                -ExpectedGoRuntimeVersion $ExpectedGoRuntimeVersion `
                -GoCommandPath $GoCommandPath
        }
        'skillspector' {
            Resolve-SkillSpector -ShouldInstall ([bool]$Install) -ToolPolicy $policy.tools.skillspector -RequestedInstallRoot $InstallRoot -AcquisitionLimitSeconds $AcquisitionTimeoutSeconds
        }
    }

    $toolPolicy = $policy.tools.$ToolName
    $launcher = [pscustomobject][ordered]@{
        kind = 'direct-executable'
        shimPath = $null
        shimSha256 = $null
        payloadPath = $null
        payloadSha256 = $null
        runtimePath = $null
        runtimeSha256 = $null
    }
    if ($ToolName -ceq 'skill-tools') {
        $launcher.kind = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'windows-cmd-shim' } else { 'unix-node-shim' }
        $launcher.shimPath = $resolved.executablePath
        $launcher.shimSha256 = $resolved.executableSha256
        $launcher.payloadPath = $resolved.entryPointPath
        $launcher.payloadSha256 = $resolved.entryPointSha256
        $launcher.runtimePath = $resolved.nodePath
        $launcher.runtimeSha256 = $resolved.nodeSha256
    }
    if ($ToolName -ceq 'skillspector' -and $Install -and $resolved.consoleEntryPoint -ceq 'skillspector.cli:app') {
        # Identity only: the runner owns execution, classification and exception
        # authorization. This launcher digest is covered by the tool receipt.
        $launcher.kind = 'skillspector-python'
        $launcher.shimPath = $resolved.executablePath
        $launcher.shimSha256 = $resolved.executableSha256
        $launcher.payloadPath = $resolved.executablePath
        $launcher.payloadSha256 = $resolved.executableSha256
        $launcher.runtimePath = Join-Path ([IO.Path]::GetDirectoryName($resolved.executablePath)) $(if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'python.exe' } else { 'python' })
        $launcher.runtimeSha256 = Get-FileSha256 -Path $launcher.runtimePath
    }
    $result = [ordered]@{
        schemaVersion = 1
        resolutionRunId = $script:ResolverRunId
        resolvedAtUtc = $script:ResolverResolvedAtUtc
        executionContext = $script:ResolverExecutionContext
        processOwnership = @($script:ResolverProcessReceipts.ToArray())
        toolName = $ToolName
        source = [string]$toolPolicy.source
        channel = [string]$toolPolicy.channel
        resolvedVersion = [string]$resolved.resolvedVersion
        resolvedIdentity = [string]$resolved.resolvedIdentity
        identityKind = [string]$resolved.identityKind
        frozenForRun = [bool]$policy.resolution.freezeForRun
        installRoot = $resolved.installRoot
        executablePath = $resolved.executablePath
        executableSha256 = $resolved.executableSha256
        installedClosureSha256 = $resolved.installedClosureSha256
        dependencyClosureSha256 = $resolved.dependencyClosureSha256
        dependencyClosure = $resolved.dependencyClosure
        launcher = $launcher
        launcherDigestSha256 = Get-ResolverLauncherDigest -Launcher $launcher
    }
    if ($ToolName -eq 'pester') {
        $result.modulePath = $resolved.modulePath
        $result.approvedPayloadSha256 = $resolved.approvedPayloadSha256
    }
    if ($ToolName -eq 'skill-tools') {
        $result.registry = [string]$toolPolicy.registry
        $result.packageLockSha256 = $resolved.packageLockSha256
        $result.entryPointPath = $resolved.entryPointPath
        $result.entryPointSha256 = $resolved.entryPointSha256
        $result.nodePath = $resolved.nodePath
        $result.nodeSha256 = $resolved.nodeSha256
        $result.executableVerified = $resolved.executableVerified
        $result.installedClosureSha256 = $resolved.installedClosureSha256
    }
    if ($ToolName -eq 'skill-validator') {
        $result.proxy = [string]$toolPolicy.proxy
        $result.checksumDatabase = [string]$toolPolicy.checksumDatabase
        $result.goRuntimeVersion = [string]$resolved.goRuntimeVersion
        $result.goRuntimeSource = [string]$resolved.goRuntimeSource
        $result.goRuntimePath = [string]$resolved.goRuntimePath
        $result.goRuntimeSha256 = [string]$resolved.goRuntimeSha256
        $result.goRuntimeVersionOutput = $resolved.goRuntimeVersionOutput
        $result.goRuntimeOs = [string]$resolved.goRuntimeOs
        $result.goRuntimeArchitecture = [string]$resolved.goRuntimeArchitecture
        $result.moduleCacheIsolation = [string]$resolved.moduleCacheIsolation
        $result.buildCacheIsolation = [string]$resolved.buildCacheIsolation
        $result.temporaryDirectoryIsolation = [string]$resolved.temporaryDirectoryIsolation
        $result.binaryInstallIsolation = [string]$resolved.binaryInstallIsolation
    }
    if ($ToolName -eq 'skillspector') {
        $result.approvedSourceId = [string]$resolved.approvedSourceId
        $result.parserCorrection = [string]$resolved.parserCorrection
        $result.pythonPackageIndex = [string]$resolved.pythonPackageIndex
        $result.installEnvironment = $resolved.installEnvironment
        $result.interpreterIsolation = [string]$resolved.interpreterIsolation
        $result.credentialIsolation = [string]$resolved.credentialIsolation
        $result.installedMetadataVerification = $resolved.installedMetadataVerification
        $result.directReferencesAllowed = [bool]$resolved.directReferencesAllowed
        $result.pipOnlineDependencyTraversalAllowed = [bool]$resolved.pipOnlineDependencyTraversalAllowed
        $result.dependencyDiscovery = [string]$resolved.dependencyDiscovery
        $result.requiresPythonPolicy = [string]$resolved.requiresPythonPolicy
        $result.dependencyResolver = [string]$resolved.dependencyResolver
        $result.yankedAllowed = [bool]$resolved.yankedAllowed
        $result.resolverHelperPath = [string]$resolved.resolverHelperPath
        $result.resolverHelperSha256 = [string]$resolved.resolverHelperSha256
        $result.consoleEntryPoint = $resolved.consoleEntryPoint
        $result.pipVersion = $resolved.pipVersion
        $result.resolutionRounds = $resolved.resolutionRounds
        $result.candidateCount = $resolved.candidateCount
        $result.candidateInventorySha256 = $resolved.candidateInventorySha256
        $result.selectionPlanSha256 = $resolved.selectionPlanSha256
        $result.rawSelectionPlanSha256 = $resolved.rawSelectionPlanSha256
        $result.selectedClosureSha256 = $resolved.selectedClosureSha256
        $result.offlineResolutionVerified = [bool]$resolved.offlineResolutionVerified
        $result.dependencyClosureSha256 = $resolved.dependencyClosureSha256
        $result.dependencyClosure = $resolved.dependencyClosure
        $result.installedClosureSha256 = $resolved.installedClosureSha256
    }
}

$json = $result | ConvertTo-Json -Depth 20
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    Write-ResolverJsonOutput -Path $OutputPath -Json $json
}

$script:ResolverGitHubApiToken = $null
$json
