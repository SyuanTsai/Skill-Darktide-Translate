# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CorePesterPlatformRuntimeModule = $null
$script:CorePesterAuthorityRevision = 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
$script:CorePesterAuthorityRuntimeFiles = [ordered]@{
    'scripts/platform-runtime.psd1'='d3d8eef434484b3b2449cd4762e60b94afc314d9beb91481538c7f57207a11c9'
    'scripts/platform-runtime.psm1'='ad051b2794ce4dc10108404201735d02f7b032ed0e633c5f22f73c884fb10370'
    'scripts/installer-safe-mutation.psm1'='dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293'
    'scripts/WindowsDacl.psm1'='ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6'
    'scripts/platform/PlatformNative.cs'='f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514'
    'scripts/platform/UnixNative.cs'='171da4acded889da89ab4e7af2729e9bbf4f3639cf1e63fe08a4c046f7545c74'
    'scripts/platform/WindowsNative.cs'='6eea8ca2701b6a6de88ee4a3348f053d07a0543d607832e667335c838bb7d433'
    'scripts/platform/WindowsInstallerMutation.cs'='b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218'
    'scripts/platform/OwnedProcess.cs'='097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58'
    'scripts/platform/UnixProcess.cs'='125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1'
    'scripts/platform/WindowsProcess.cs'='7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6'
    'scripts/platform/Unix.psm1'='ec3b3bb0b39e1ce84d4c8f60a78c44fb40cb9d58c13ed88a6b9d9db978fcc147'
    'scripts/platform/RuntimePreparation.psm1'='dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077'
    'scripts/platform/Windows.psm1'='9b7442178083a9b165ed3bf53367d5c3ce1b1f09d56f0f6efe964b524e17be0b'
    'scripts/platform/Linux.psm1'='52c261d577ee7b3946771d1112030996896fdd119e06ac3849e430a3d56fb38c'
    'scripts/platform/MacOS.psm1'='8f25edfbee5ab36b5e1c42eb55c6dbab44db0bc29896c180612b1248920c7c47'
}

function Import-CorePesterAuthorityPlatformRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AuthorityRoot,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $AuthorityRevision
    )
    if ($AuthorityRevision -cne $script:CorePesterAuthorityRevision) { throw 'Core Pester authority revision differs from the reviewed tuple.' }
    $root = [IO.Path]::GetFullPath($AuthorityRoot)
    foreach ($entry in $script:CorePesterAuthorityRuntimeFiles.GetEnumerator()) {
        $path = [IO.Path]::GetFullPath((Join-Path $root ($entry.Key -replace '/', [IO.Path]::DirectorySeparatorChar)))
        $stream = [IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        try { $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant() }
        finally { $stream.Dispose() }
        if ($hash -cne [string]$entry.Value) { throw "Core Pester authority runtime file differs from the reviewed tuple: $($entry.Key)" }
    }
    $manifestPath = Join-Path $root 'scripts/platform-runtime.psd1'
    $module = Import-Module -Name $manifestPath -Force -PassThru -ErrorAction Stop
    & $module { param($RuntimeRoot,$Manifest) Assert-PlatformRuntimeInventory -Root $RuntimeRoot -ManifestPath $Manifest | Out-Null } (Split-Path -Parent $manifestPath) $manifestPath
    $script:CorePesterPlatformRuntimeModule = $module
    Import-Module -ModuleInfo $module -Force -ErrorAction Stop
    return $module
}

$script:expectedMetadataEntries = @(
    '_rels/.rels',
    '[Content_Types].xml',
    'package/services/metadata/core-properties/nuget.psmdcp',
    'Pester.nuspec'
)

function Open-CorePesterFileBinding {
    param([Parameter(Mandatory)][string] $Path, [string] $Access = 'Read')
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($full)) -RootOnly
    try {
        $file = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($full)) -Access $Access -CreateMode OpenExisting
        $identity = Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink -VerifyPath
        return [pscustomobject]@{ Parent = $parent; File = $file; Identity = $identity; Path = $full }
    }
    catch { $parent.Dispose(); throw }
}

function Close-CorePesterFileBinding {
    param([Parameter(Mandatory)] $Binding)
    try { $Binding.File.Dispose() } finally { $Binding.Parent.Dispose() }
}

function Get-CorePesterLeasedBytes {
    param([Parameter(Mandatory)][string] $Path, [int] $Limit = 268435456)
    $binding = Open-CorePesterFileBinding -Path $Path
    try {
        [byte[]]$bytes = $binding.File.ReadAllBytes($Limit)
        [void](Assert-PlatformFileIdentity -Lease $binding.File -Expected $binding.Identity -SingleLink -VerifyPath)
        return $bytes
    }
    finally { Close-CorePesterFileBinding -Binding $binding }
}

function Get-CorePesterPathComparison {
    if ($IsWindows) { return [StringComparison]::OrdinalIgnoreCase }
    return [StringComparison]::Ordinal
}

function Get-CorePesterPathComparer {
    if ($IsWindows) { return [StringComparer]::OrdinalIgnoreCase }
    return [StringComparer]::Ordinal
}

function Assert-CorePesterObjectKeys {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Object,
        [Parameter(Mandatory)][string[]] $Expected,
        [Parameter(Mandatory)][string] $Context
    )

    $actual = @($Object.Keys | ForEach-Object { [string]$_ })
    if ($actual.Count -ne $Expected.Count -or
        @($actual | Where-Object { $_ -cnotin $Expected }).Count -gt 0 -or
        @($Expected | Where-Object { $_ -cnotin $actual }).Count -gt 0) {
        throw "$Context has missing or unexpected properties."
    }
}

function Assert-CorePesterNoDuplicateJsonProperties {
    param([Parameter(Mandatory)][System.Text.Json.JsonElement] $Element, [Parameter(Mandatory)][string] $Context)

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw "$Context contains duplicate or case-ambiguous JSON property '$($property.Name)'." }
            Assert-CorePesterNoDuplicateJsonProperties -Element $property.Value -Context $Context
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-CorePesterNoDuplicateJsonProperties -Element $item -Context $Context
        }
    }
}

function Assert-CorePesterSafeRelativePath {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Context)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Contains('\') -or $Path.StartsWith('/') -or
        $Path -match '[:\x00-\x1f]' -or $Path -match '[<>"|?*]') {
        throw "$Context contains an unsafe relative path '$Path'."
    }
    $segments = @($Path.Split('/'))
    if (@($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -ceq '.' -or $_ -ceq '..' }).Count -gt 0) {
        throw "$Context contains an unsafe relative path '$Path'."
    }
}

function Read-CorePesterClosureLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $LiteralPath)

    $fullPath = [IO.Path]::GetFullPath($LiteralPath)
    $bytes = Get-CorePesterLeasedBytes -Path $fullPath -Limit 16777216
    $json = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $document = [System.Text.Json.JsonDocument]::Parse($json)
    try {
        Assert-CorePesterNoDuplicateJsonProperties -Element $document.RootElement -Context 'Pester closure lock'
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { throw 'Pester closure lock root must be an object.' }
    }
    finally { $document.Dispose() }

    $lock = ConvertFrom-Json -InputObject $json -AsHashtable -Depth 20 -ErrorAction Stop
    Assert-CorePesterObjectKeys -Object $lock -Expected @('schemaVersion', 'kind', 'source', 'runtime', 'packageInventory', 'modulePayload') -Context 'Pester closure lock'
    if ([int]$lock.schemaVersion -ne 1 -or [string]$lock.kind -cne 'pester-module-closure') {
        throw 'Pester closure lock schema or kind is unsupported.'
    }

    Assert-CorePesterObjectKeys -Object $lock.source -Expected @('packageId', 'moduleName', 'version', 'packageUri', 'sourceName', 'archiveDigest') -Context 'Pester closure source'
    if ([string]$lock.source.packageId -cne 'Pester' -or [string]$lock.source.moduleName -cne 'Pester' -or
        [string]$lock.source.version -cne '6.2.0' -or
        [string]$lock.source.packageUri -cne 'https://www.powershellgallery.com/api/v2/package/Pester/6.2.0' -or
        [string]$lock.source.sourceName -cne 'PowerShell Gallery PSGallery official package endpoint' -or
        [string]$lock.source.archiveDigest -cne 'not-pinned; observed download SHA is evidence only and is not an independently published official digest') {
        throw 'Pester closure lock source identity or digest claim is invalid.'
    }

    Assert-CorePesterObjectKeys -Object $lock.runtime -Expected @('moduleRelativePath', 'manifestRelativePath') -Context 'Pester closure runtime'
    if ([string]$lock.runtime.moduleRelativePath -cne 'Modules/Pester/6.2.0' -or [string]$lock.runtime.manifestRelativePath -cne 'Pester.psd1') {
        throw 'Pester closure lock runtime layout is invalid.'
    }

    Assert-CorePesterObjectKeys -Object $lock.packageInventory -Expected @('entryCount', 'metadataEntries', 'payloadEntries', 'payloadDirectory', 'generatedInstallMetadata') -Context 'Pester package inventory'
    if ([int]$lock.packageInventory.entryCount -ne 21 -or [int]$lock.packageInventory.payloadEntries -ne 17 -or
        [string]$lock.packageInventory.payloadDirectory -cne 'package root' -or
        @(Compare-Object -ReferenceObject $script:expectedMetadataEntries -DifferenceObject @($lock.packageInventory.metadataEntries) -CaseSensitive).Count -ne 0) {
        throw 'Pester package inventory lock differs from the observed package classification.'
    }
    Assert-CorePesterObjectKeys -Object $lock.packageInventory.generatedInstallMetadata -Expected @('path', 'presentInOfficialPackage', 'presentInPreparedInstalledCopy', 'includedInClosure', 'handling') -Context 'Pester generated metadata'
    if ([string]$lock.packageInventory.generatedInstallMetadata.path -cne 'PSGetModuleInfo.xml' -or
        [bool]$lock.packageInventory.generatedInstallMetadata.presentInOfficialPackage -or
        -not [bool]$lock.packageInventory.generatedInstallMetadata.presentInPreparedInstalledCopy -or
        [bool]$lock.packageInventory.generatedInstallMetadata.includedInClosure -or
        [string]$lock.packageInventory.generatedInstallMetadata.handling -cne 'Never copy installer metadata; stage exact archive payload only.') {
        throw 'Pester generated-install metadata classification is invalid.'
    }

    if ($lock.modulePayload -isnot [System.Collections.IEnumerable] -or $lock.modulePayload -is [string] -or @($lock.modulePayload).Count -ne 17) {
        throw 'Pester closure lock must contain exactly 17 payload entries.'
    }
    $paths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in @($lock.modulePayload)) {
        Assert-CorePesterObjectKeys -Object $entry -Expected @('path', 'sha256') -Context 'Pester module payload entry'
        $path = [string]$entry.path
        Assert-CorePesterSafeRelativePath -Path $path -Context 'Pester module payload'
        if ($path -cin $script:expectedMetadataEntries -or $path -ieq 'PSGetModuleInfo.xml') { throw "Package metadata cannot be a module closure payload: $path" }
        if (-not $paths.Add($path)) { throw "Pester closure lock contains duplicate or case-ambiguous payload path '$path'." }
        if ([string]$entry.sha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Pester closure lock hash is invalid for '$path'." }
    }

    return [pscustomobject]@{
        Value = $lock
        Path = $fullPath
        Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        RawBytes = $bytes
    }
}

function Get-CorePesterRuntimeModuleRoot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ExecutablePath)

    $fullExecutable = [IO.Path]::GetFullPath($ExecutablePath)
    $expectedName = if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' }
    if ([IO.Path]::GetFileName($fullExecutable) -cne $expectedName) {
        throw "Verified PowerShell executable path must name an existing $expectedName."
    }
    $executableBinding = Open-CorePesterFileBinding -Path $fullExecutable
    Close-CorePesterFileBinding -Binding $executableBinding
    $runtimeRoot = Split-Path -Parent $fullExecutable
    return [IO.Path]::GetFullPath((Join-Path $runtimeRoot 'Modules/Pester/6.2.0'))
}

function Assert-NoLegacyCorePesterBootstrapEnvironment {
    [CmdletBinding()]
    param()

    $processEnvironment = [Environment]::GetEnvironmentVariables([EnvironmentVariableTarget]::Process)
    foreach ($name in @('STANDARD_VALIDATION_BOOTSTRAP_RELEASE_PATH', 'STANDARD_VALIDATION_BOOTSTRAP_COMMAND')) {
        if ($processEnvironment.Contains($name)) {
            throw "Core Pester received unexpected legacy bootstrap transport variable '$name'."
        }
    }
}

function Test-CorePesterPathBoundary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Boundary
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullBoundary = [IO.Path]::GetFullPath($Boundary)
    $errors = [System.Collections.Generic.List[string]]::new()
    $boundaryPrefix = if ($fullBoundary.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $fullBoundary
    }
    else {
        $fullBoundary + [IO.Path]::DirectorySeparatorChar
    }
    $pathComparison = Get-CorePesterPathComparison
    if (-not $fullPath.Equals($fullBoundary, $pathComparison) -and
        -not $fullPath.StartsWith($boundaryPrefix, $pathComparison)) {
        $errors.Add('Path escaped its registered boundary.')
        return [pscustomobject]@{ IsValid = $false; Path = $fullPath; Boundary = $fullBoundary; Errors = @($errors.ToArray()) }
    }

    $physicalBoundary = [IO.Path]::GetFullPath((Resolve-PlatformPhysicalPath -Path $fullBoundary))
    if (-not $physicalBoundary.Equals($fullBoundary, $pathComparison)) {
        $errors.Add("Path ancestry contains a reparse point: $fullBoundary")
        return [pscustomobject]@{ IsValid = $false; Path = $fullPath; Boundary = $fullBoundary; Errors = @($errors.ToArray()) }
    }

    $boundaryLease = $null
    $currentLease = $null
    try {
        $boundaryLease = Open-PlatformDirectory -Root $fullBoundary -RootOnly
        $currentLease = $boundaryLease
        $relative = $fullPath.Substring($fullBoundary.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $currentPath = $fullBoundary
        foreach ($segment in @($relative.Split([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar), [StringSplitOptions]::RemoveEmptyEntries))) {
            try { $nextLease = Open-PlatformDirectory -Root $currentPath -RelativePath $segment }
            catch [IO.DirectoryNotFoundException] { break }
            catch [IO.FileNotFoundException] { break }
            if ($currentLease -ne $boundaryLease) { $currentLease.Dispose() }
            $currentLease = $nextLease
            $currentPath = Join-Path $currentPath $segment
        }
    }
    catch { $errors.Add("Path ancestry contains a reparse point: $currentPath. $($_.Exception.Message)") }
    finally {
        if ($null -ne $currentLease -and $currentLease -ne $boundaryLease) { $currentLease.Dispose() }
        if ($null -ne $boundaryLease) { $boundaryLease.Dispose() }
    }

    return [pscustomobject]@{
        IsValid = ($errors.Count -eq 0)
        Path = $fullPath
        Boundary = $fullBoundary
        Errors = @($errors.ToArray())
    }
}

function Test-CorePesterClosure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ModuleRoot,
        [Parameter(Mandatory)][object] $Lock
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $expected = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedExact = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Lock.modulePayload)) {
        $path = [string]$entry.path
        try { Assert-CorePesterSafeRelativePath -Path $path -Context 'Pester closure payload' }
        catch { $errors.Add($_.Exception.Message); continue }
        if ($expected.ContainsKey($path)) { $errors.Add("Duplicate expected payload path: $path") }
        else { $expected.Add($path, $entry); [void]$expectedExact.Add($path) }
    }

    $root = [IO.Path]::GetFullPath($ModuleRoot)
    $actual = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rows = [System.Collections.Generic.List[object]]::new()
    $rootLease = $null
    try {
        $rootLease = Open-PlatformDirectory -Root $root -RootOnly
    }
    catch { $rootLease = $null }
    if ($null -eq $rootLease) {
        $errors.Add('Pester module closure directory is missing.')
    }
    else {
        $entries = @(Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop)
        foreach ($item in $entries) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $errors.Add("Pester closure contains a reparse point: $($item.FullName)")
                continue
            }
            if ($item.PSIsContainer) { continue }
            $fullPath = [IO.Path]::GetFullPath($item.FullName)
            $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $fullPath.StartsWith($prefix, (Get-CorePesterPathComparison))) {
                $errors.Add("Pester closure file escaped its module root: $fullPath")
                continue
            }
            $relativePath = [IO.Path]::GetRelativePath($root, $fullPath).Replace('\', '/')
            try { Assert-CorePesterSafeRelativePath -Path $relativePath -Context 'Pester closure file' }
            catch { $errors.Add($_.Exception.Message); continue }
            if ($actual.ContainsKey($relativePath)) {
                $errors.Add("Pester closure contains duplicate or case-ambiguous file path: $relativePath")
                continue
            }
            $actual.Add($relativePath, $fullPath)
            if (-not $expected.ContainsKey($relativePath) -or -not $expectedExact.Contains($relativePath)) {
                $errors.Add("Pester closure contains unpinned file: $relativePath")
                continue
            }
            $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData((Get-CorePesterLeasedBytes -Path $fullPath))).ToLowerInvariant()
            $wantedHash = [string]$expected[$relativePath].sha256
            $rows.Add([pscustomobject]@{ path = $relativePath; sha256 = $hash })
            if ($hash -cne $wantedHash) { $errors.Add("Pester closure hash mismatch: $relativePath") }
        }
    }
    if ($null -ne $rootLease) { $rootLease.Dispose() }
    foreach ($path in $expected.Keys) {
        if (-not $actual.ContainsKey($path)) { $errors.Add("Pester closure payload is missing: $path") }
    }
    $canonicalRows = @($rows | Sort-Object -Property path -CaseSensitive | ConvertTo-Json -Depth 3 -Compress)
    $closureBytes = [Text.UTF8Encoding]::new($false).GetBytes(($canonicalRows -join "`n"))
    return [pscustomobject]@{
        IsValid = $errors.Count -eq 0
        ModuleRoot = $root
        ClosureSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($closureBytes)).ToLowerInvariant()
        Inventory = @($rows.ToArray() | Sort-Object -Property path -CaseSensitive)
        Errors = @($errors.ToArray())
    }
}

function Test-CorePesterModuleCandidates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedManifestPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Candidates
    )

    $expected = [IO.Path]::GetFullPath($ExpectedManifestPath)
    $errors = [System.Collections.Generic.List[string]]::new()
    $sameVersion = @($Candidates | Where-Object { [version]$_.Version -eq [version]'6.2.0' })
    $expectedCount = 0
    foreach ($candidate in $sameVersion) {
        $pathProperty = $candidate.PSObject.Properties['Path']
        if ($null -eq $pathProperty -or [string]::IsNullOrWhiteSpace([string]$pathProperty.Value)) {
            $errors.Add('A Pester 6.2.0 candidate has no manifest path.')
            continue
        }
        $path = [IO.Path]::GetFullPath([string]$pathProperty.Value)
        if ($path.Equals($expected, (Get-CorePesterPathComparison))) { $expectedCount++ }
        else { $errors.Add("An ambient Pester 6.2.0 module candidate exists outside the verified runtime: $path") }
    }
    if ($expectedCount -ne 1) { $errors.Add('The verified runtime must expose exactly one Pester 6.2.0 manifest candidate.') }
    return [pscustomobject]@{ IsValid = $errors.Count -eq 0; Errors = @($errors.ToArray()); SameVersionCount = $sameVersion.Count }
}

function Get-CorePesterExpectedLoadedModulePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $ModuleRoot,
        [Parameter(Mandatory)][object] $Lock
    )

    $fullRoot = [IO.Path]::GetFullPath($ModuleRoot)
    $fullManifest = [IO.Path]::GetFullPath($ManifestPath)
    $expectedManifest = [IO.Path]::GetFullPath((Join-Path $fullRoot ([string]$Lock.runtime.manifestRelativePath)))
    if (-not $fullManifest.Equals($expectedManifest, (Get-CorePesterPathComparison))) {
        throw 'Pester loaded-module identity was requested from a manifest outside the locked module root.'
    }
    $manifestBinding = Open-CorePesterFileBinding -Path $fullManifest
    $manifestData = Import-PowerShellDataFile -LiteralPath $fullManifest -ErrorAction Stop
    [void](Assert-PlatformFileIdentity -Lease $manifestBinding.File -Expected $manifestBinding.Identity -SingleLink -VerifyPath)
    Close-CorePesterFileBinding -Binding $manifestBinding
    $rootModule = [string]$manifestData.RootModule
    if ([string]::IsNullOrWhiteSpace($rootModule) -or [IO.Path]::IsPathRooted($rootModule)) {
        throw 'Locked Pester manifest must declare a relative RootModule entry point.'
    }
    $relativeRootModule = $rootModule.Replace('\', '/')
    try { Assert-CorePesterSafeRelativePath -Path $relativeRootModule -Context 'Pester manifest RootModule' }
    catch { throw }
    $payloadMatch = @($Lock.modulePayload | Where-Object { [string]$_.path -ceq $relativeRootModule })
    if ($payloadMatch.Count -ne 1) { throw 'Pester manifest RootModule is not one exact locked package payload entry.' }

    $fullLoadedModulePath = [IO.Path]::GetFullPath((Join-Path $fullRoot ($relativeRootModule.Replace('/', [IO.Path]::DirectorySeparatorChar))))
    $rootPrefix = $fullRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $fullLoadedModulePath.StartsWith($rootPrefix, (Get-CorePesterPathComparison))) {
        throw 'Pester manifest RootModule escaped the locked module root.'
    }
    return $fullLoadedModulePath
}

function Test-CorePesterLoadedModuleIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Modules,
        [Parameter(Mandatory)][string] $ExpectedVersion,
        [Parameter(Mandatory)][string] $ExpectedPath,
        [Parameter(Mandatory)][string] $ExpectedModuleBase
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $expectedVersionValue = [version]$ExpectedVersion
    $expectedPathValue = [IO.Path]::GetFullPath($ExpectedPath)
    $expectedBaseValue = [IO.Path]::GetFullPath($ExpectedModuleBase)
    if ($Modules.Count -ne 1) {
        $errors.Add('Exactly one Pester module must be loaded in the Core child.')
    }
    foreach ($module in $Modules) {
        if ($null -eq $module) { $errors.Add('A loaded Pester module entry is null.'); continue }
        if ([string]$module.Name -cne 'Pester') { $errors.Add('The loaded Core test module name is not Pester.') }
        if ([version]$module.Version -ne $expectedVersionValue) { $errors.Add('Loaded Pester module version differs from the locked version.') }
        if ([string]::IsNullOrWhiteSpace([string]$module.Path) -or
            -not [IO.Path]::GetFullPath([string]$module.Path).Equals($expectedPathValue, (Get-CorePesterPathComparison))) {
            $errors.Add('Loaded Pester module path differs from the manifest RootModule entry point.')
        }
        if ([string]::IsNullOrWhiteSpace([string]$module.ModuleBase) -or
            -not [IO.Path]::GetFullPath([string]$module.ModuleBase).Equals($expectedBaseValue, (Get-CorePesterPathComparison))) {
            $errors.Add('Loaded Pester module base differs from the verified runtime module root.')
        }
    }
    return [pscustomobject]@{ IsValid = ($errors.Count -eq 0); Errors = @($errors.ToArray()) }
}

function Get-CorePesterCaseIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RelativeSourceFile,
        [Parameter(Mandatory)][int] $StartOffset,
        [Parameter(Mandatory)][string] $ExpandedPath
    )

    Assert-CorePesterSafeRelativePath -Path $RelativeSourceFile -Context 'Pester case identity source'
    if ($StartOffset -lt 0 -or [string]::IsNullOrWhiteSpace($ExpandedPath)) { throw 'Pester case identity fields are incomplete.' }
    $tuple = ConvertTo-Json -InputObject ([object[]]@($RelativeSourceFile.ToUpperInvariant(), $StartOffset, $ExpandedPath)) -Compress -Depth 3
    return [Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes($tuple))
}

function ConvertFrom-CorePesterProgressLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Line,
        [Parameter(Mandatory)][ValidateRange(0, [int]::MaxValue)][int] $ActiveCaseStarts
    )

    $cleanLine = $Line -replace '\x1b\[[0-9;]*m', ''
    if ($cleanLine -notmatch '^\s*(Running tests from|Describing|Context|\[[+!|\-]\]|Tests completed)') {
        return [pscustomobject]@{ IsRecognized = $false; Phase = 'status'; ActiveCaseStarts = $ActiveCaseStarts; CompletedDelta = 0; Line = $cleanLine }
    }
    $phase = 'status'
    $nextActive = $ActiveCaseStarts
    $completedDelta = 0
    if ($cleanLine -match '^\s*\[\|\]\s+.+$') {
        $nextActive++
        $phase = 'case-start'
    }
    elseif ($cleanLine -match '^\s*\[[+!\-]\]\s+.+$' -and $nextActive -gt 0) {
        # Pester prints a template (for example <Value>) at start and the
        # expanded name at completion. Its detailed stream pairs them in order.
        $nextActive--
        $completedDelta = 1
        $phase = 'case-end'
    }
    elseif ($cleanLine -match '^\s*Running tests from') { $phase = 'file-start' }
    return [pscustomobject]@{ IsRecognized = $true; Phase = $phase; ActiveCaseStarts = $nextActive; CompletedDelta = $completedDelta; Line = $cleanLine }
}

function Test-CorePesterCaseIdentityPartition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $DiscoveryCases,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $ExecutionCases
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $discovery = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    $execution = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($row in $DiscoveryCases) {
        $identity = [string]$row.identity
        if ([string]::IsNullOrEmpty($identity)) { $errors.Add('Pester discovery contains a case without an identity.'); continue }
        if ($discovery.ContainsKey($identity)) {
            $errors.Add("Pester discovered duplicate or ambiguous case identity: $($row.sourceFile):$($row.sourceStartLine) $($row.expandedPath)")
        }
        else { $discovery.Add($identity, $row) }
    }
    foreach ($row in $ExecutionCases) {
        $identity = [string]$row.identity
        if ([string]::IsNullOrEmpty($identity)) { $errors.Add('Pester execution contains a case without an identity.'); continue }
        if ($execution.ContainsKey($identity)) {
            $errors.Add("Pester execution contains duplicate or ambiguous case identity: $($row.sourceFile):$($row.sourceStartLine) $($row.expandedPath)")
        }
        else { $execution.Add($identity, $row) }
    }
    foreach ($identity in $discovery.Keys) {
        if (-not $execution.ContainsKey($identity)) {
            $row = $discovery[$identity]
            $errors.Add("Pester discovered a case with no execution status: $($row.sourceFile):$($row.sourceStartLine) $($row.expandedPath)")
            continue
        }
        if ([string]$discovery[$identity].result -cne [string]$execution[$identity].result) {
            $row = $discovery[$identity]
            $errors.Add("Pester discovered and executed statuses differ: $($row.sourceFile):$($row.sourceStartLine) $($row.expandedPath)")
        }
    }
    foreach ($identity in $execution.Keys) {
        if (-not $discovery.ContainsKey($identity)) {
            $row = $execution[$identity]
            $errors.Add("Pester executed an unexpected case: $($row.sourceFile):$($row.sourceStartLine) $($row.expandedPath)")
        }
    }
    return [pscustomobject]@{
        IsValid = $errors.Count -eq 0
        Errors = @($errors.ToArray())
        DiscoveryIdentities = @($discovery.Keys)
        ExecutionIdentities = @($execution.Keys)
    }
}

function Test-CorePesterShardUnion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $DiscoveredIdentities,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Shards
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $discovered = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($identity in $DiscoveredIdentities) {
        if ([string]::IsNullOrWhiteSpace($identity)) { $errors.Add('Discovery contains an empty case identity.'); continue }
        if (-not $discovered.Add($identity)) { $errors.Add("Discovery contains a duplicate case identity: $identity") }
    }
    if ($Shards.Count -ne 1) { $errors.Add('Only the authorized single core-full shard is supported.') }
    $union = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($shard in $Shards) {
        if ([string]$shard.id -cne 'core-full') { $errors.Add("Unknown Pester shard identity: $([string]$shard.id)") }
        foreach ($identity in @($shard.caseIdentities)) {
            if ([string]::IsNullOrWhiteSpace([string]$identity)) { $errors.Add('Shard contains an empty case identity.'); continue }
            if (-not $union.Add([string]$identity)) { $errors.Add("Shard union contains a duplicate case identity: $identity") }
        }
    }
    foreach ($identity in $discovered) { if (-not $union.Contains($identity)) { $errors.Add("Shard union omitted discovered identity: $identity") } }
    foreach ($identity in $union) { if (-not $discovered.Contains($identity)) { $errors.Add("Shard union contains unexpected identity: $identity") } }
    return [pscustomobject]@{ IsValid = $errors.Count -eq 0; Errors = @($errors.ToArray()); DiscoveryCount = $discovered.Count; UnionCount = $union.Count }
}

function Test-CorePesterAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][bool] $CaseInventoryLedgerWritten,
        [Parameter(Mandatory)][bool] $CaseInventoryComplete,
        [Parameter(Mandatory)][int] $Total,
        [Parameter(Mandatory)][int] $Passed,
        [Parameter(Mandatory)][int] $Failed,
        [Parameter(Mandatory)][int] $FailedBlocks,
        [Parameter(Mandatory)][int] $FailedContainers,
        [Parameter(Mandatory)][int] $Inconclusive,
        [Parameter(Mandatory)][int] $Skipped,
        [Parameter(Mandatory)][int] $NotRun
    )
    return $CaseInventoryLedgerWritten -and $CaseInventoryComplete -and
        $Total -gt 0 -and $Passed -gt 0 -and $Failed -eq 0 -and
        $FailedBlocks -eq 0 -and $FailedContainers -eq 0 -and
        $Inconclusive -eq 0 -and $Skipped -eq 0 -and $NotRun -eq 0 -and
        $Passed -eq $Total
}

function Get-CorePesterTreeSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Root)

    $fullRoot = [IO.Path]::GetFullPath($Root)
    $errors = [System.Collections.Generic.List[string]]::new()
    $files = [System.Collections.Generic.List[object]]::new()
    $fileKeys = [System.Collections.Generic.HashSet[string]]::new((Get-CorePesterPathComparer))
    $rootLease = $null
    try {
        $rootLease = Open-PlatformDirectory -Root $fullRoot -RootOnly
    }
    catch { $rootLease = $null }
    if ($null -eq $rootLease) {
        return [pscustomobject]@{ IsValid = $false; Root = $fullRoot; Sha256 = $null; Files = @(); Errors = @('Candidate snapshot root is missing.') }
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $fullRoot -Force -Recurse -ErrorAction Stop)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $errors.Add("Candidate snapshot contains a reparse point: $($item.FullName)")
            continue
        }
        if ($item.PSIsContainer) { continue }
        $path = [IO.Path]::GetFullPath($item.FullName)
        $prefix = $fullRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if (-not $path.StartsWith($prefix, (Get-CorePesterPathComparison))) {
            $errors.Add("Candidate snapshot file escaped its root: $path")
            continue
        }
        $relative = [IO.Path]::GetRelativePath($fullRoot, $path).Replace('\', '/')
        try { Assert-CorePesterSafeRelativePath -Path $relative -Context 'candidate snapshot file' }
        catch { $errors.Add($_.Exception.Message); continue }
        if (-not $fileKeys.Add($relative)) { $errors.Add("Candidate snapshot contains a duplicate or case-ambiguous file path: $relative"); continue }
        try {
            $binding = Open-CorePesterFileBinding -Path $path
            try {
                $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($binding.File.ReadAllBytes(268435456))).ToLowerInvariant()
                [void](Assert-PlatformFileIdentity -Lease $binding.File -Expected $binding.Identity -SingleLink -VerifyPath)
                $files.Add([pscustomobject]@{ path = $relative; sha256 = $hash })
            }
            finally { Close-CorePesterFileBinding -Binding $binding }
        }
        catch { $errors.Add("Candidate snapshot file identity could not be bound: $relative. $($_.Exception.Message)") }
    }
    $rootLease.Dispose()
    $ordered = @($files.ToArray() | Sort-Object -Property path -CaseSensitive)
    $canonical = ConvertTo-Json -InputObject $ordered -Depth 3 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($canonical)
    return [pscustomobject]@{
        IsValid = $errors.Count -eq 0
        Root = $fullRoot
        Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        Files = $ordered
        Errors = @($errors.ToArray())
    }
}

function Test-CorePesterPackageArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][object] $Lock
    )

    $fullArchive = [IO.Path]::GetFullPath($ArchivePath)
    $archiveBinding = Open-CorePesterFileBinding -Path $fullArchive
    [byte[]]$archiveBytes = $archiveBinding.File.ReadAllBytes(33554433)
    $archiveSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archiveBytes)).ToLowerInvariant()
    if ([long]$archiveBytes.Length -le 0 -or [long]$archiveBytes.Length -gt 33554432) {
        Close-CorePesterFileBinding -Binding $archiveBinding
        throw 'Pester package archive exceeds the 32 MiB acquisition bound.'
    }
    $expectedPayload = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedPayloadExact = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in @($Lock.modulePayload)) {
        $expectedPayload.Add([string]$entry.path, [string]$entry.sha256)
        [void]$expectedPayloadExact.Add([string]$entry.path)
    }
    $expectedEntries = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $expectedEntriesExact = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $script:expectedMetadataEntries) { [void]$expectedEntries.Add($name); [void]$expectedEntriesExact.Add($name) }
    foreach ($name in $expectedPayload.Keys) { [void]$expectedEntries.Add($name); [void]$expectedEntriesExact.Add($name) }
    $errors = [System.Collections.Generic.List[string]]::new()
    $entrySet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $archive = [IO.Compression.ZipFile]::OpenRead($fullArchive)
    try {
        if ($archive.Entries.Count -ne 21) { $errors.Add("Official Pester archive must contain exactly 21 entries; found $($archive.Entries.Count).") }
        $uncompressedBytes = [long]0
        $nuspecSeen = $false
        foreach ($entry in $archive.Entries) {
            $name = [string]$entry.FullName
            if ([long]$entry.Length -lt 0 -or [long]$entry.Length -gt 8388608) {
                $errors.Add("Pester package archive entry exceeds the 8 MiB expanded-entry bound: $name")
                continue
            }
            $uncompressedBytes += [long]$entry.Length
            if ($uncompressedBytes -gt 16777216) {
                $errors.Add('Pester package archive exceeds the 16 MiB expanded-payload bound.')
                break
            }
            try { Assert-CorePesterSafeRelativePath -Path $name -Context 'Pester package archive entry' }
            catch { $errors.Add($_.Exception.Message); continue }
            if (-not $entrySet.Add($name)) { $errors.Add("Pester package archive has duplicate or case-ambiguous entry: $name"); continue }
            # ZipArchive exposes the 32-bit external-attribute field as a signed Int32.
            # Reinterpret its bits so Unix mode values with the sign bit set remain valid.
            $externalAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
            $unixType = ($externalAttributes -shr 16) -band [uint32]0xF000
            if ($unixType -eq 0xA000) { $errors.Add("Pester package archive contains a symbolic link: $name"); continue }
            if (-not $expectedEntries.Contains($name) -or -not $expectedEntriesExact.Contains($name)) { $errors.Add("Pester package archive contains an unclassified or case-mismatched entry: $name"); continue }
            if ($name -ceq 'Pester.nuspec') {
                $nuspecSeen = $true
                $stream = $entry.Open()
                try {
                    $settings = [Xml.XmlReaderSettings]::new()
                    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
                    $settings.XmlResolver = $null
                    $reader = [Xml.XmlReader]::Create($stream, $settings)
                    try { $nuspec = [Xml.XmlDocument]::new(); $nuspec.XmlResolver = $null; $nuspec.Load($reader) }
                    finally { $reader.Dispose() }
                }
                finally { $stream.Dispose() }
                $idNodes = @($nuspec.SelectNodes("/*[local-name()='package']/*[local-name()='metadata']/*[local-name()='id']"))
                $versionNodes = @($nuspec.SelectNodes("/*[local-name()='package']/*[local-name()='metadata']/*[local-name()='version']"))
                $id = if ($idNodes.Count -eq 1) { [string]$idNodes[0].InnerText } else { '' }
                $version = if ($versionNodes.Count -eq 1) { [string]$versionNodes[0].InnerText } else { '' }
                $dependencies = @($nuspec.SelectNodes("//*[local-name()='metadata']/*[local-name()='dependencies']/*"))
                if ($null -eq $nuspec.DocumentElement -or $nuspec.DocumentElement.LocalName -cne 'package' -or
                    $idNodes.Count -ne 1 -or $versionNodes.Count -ne 1 -or $id -cne 'Pester' -or
                    $version -cne '6.2.0' -or $dependencies.Count -gt 0) {
                    $errors.Add('Pester package nuspec identity, version or dependency inventory is invalid.')
                }
                continue
            }
            if ($expectedPayload.ContainsKey($name) -and $expectedPayloadExact.Contains($name)) {
                $stream = $entry.Open()
                $sha = [Security.Cryptography.SHA256]::HashData($stream)
                $stream.Dispose()
                $actualHash = [Convert]::ToHexString($sha).ToLowerInvariant()
                if ($actualHash -cne $expectedPayload[$name]) { $errors.Add("Pester package payload hash mismatch: $name") }
            }
        }
        foreach ($expectedName in $expectedEntries) {
            if (-not $entrySet.Contains($expectedName)) { $errors.Add("Pester package archive omitted expected entry: $expectedName") }
        }
        if (-not $nuspecSeen) { $errors.Add('Pester package archive has no package identity nuspec.') }
    }
    finally { $archive.Dispose() }
    [void](Assert-PlatformFileIdentity -Lease $archiveBinding.File -Expected $archiveBinding.Identity -SingleLink -VerifyPath)
    Close-CorePesterFileBinding -Binding $archiveBinding
    return [pscustomobject]@{
        IsValid = $errors.Count -eq 0
        ArchivePath = $fullArchive
        ObservedArchiveSha256 = $archiveSha
        EntryCount = $entrySet.Count
        PayloadCount = @($expectedPayload.Keys).Count
        MetadataEntries = @($script:expectedMetadataEntries)
        Errors = @($errors.ToArray())
    }
}

Export-ModuleMember -Function Import-CorePesterAuthorityPlatformRuntime, Open-CorePesterFileBinding, Close-CorePesterFileBinding, Get-CorePesterLeasedBytes, Read-CorePesterClosureLock, Get-CorePesterRuntimeModuleRoot, Assert-NoLegacyCorePesterBootstrapEnvironment, Test-CorePesterPathBoundary, Test-CorePesterClosure, Test-CorePesterModuleCandidates, Get-CorePesterExpectedLoadedModulePath, Test-CorePesterLoadedModuleIdentity, Get-CorePesterCaseIdentity, ConvertFrom-CorePesterProgressLine, Test-CorePesterCaseIdentityPartition, Test-CorePesterShardUnion, Test-CorePesterAcceptance, Get-CorePesterTreeSnapshot, Test-CorePesterPackageArchive
