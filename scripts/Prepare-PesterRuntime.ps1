# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RuntimeExecutable,
    [Parameter(Mandatory)][string] $OwnedRoot,
    [string] $PackageCacheRoot = $env:DT_PESTER_PACKAGE_CACHE,
    [Parameter(Mandatory)][string] $AuthorityRepositoryRoot,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $AuthorityRevision
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Open-PesterPackageCacheRoot {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $RunOwnedRoot)

    $root = [IO.Path]::GetFullPath($RunOwnedRoot).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, $comparison)) { throw 'cache root must be below the run-owned root' }
    $relative = $fullPath.Substring($prefix.Length).Replace([IO.Path]::DirectorySeparatorChar, '/')
    if ([string]::IsNullOrWhiteSpace($relative)) { throw 'cache root must be a child directory' }
    return Open-PlatformDirectory -Root $root -RelativePath $relative
}

function Open-PesterRelativeDirectory {
    param(
        [Parameter(Mandatory)] $RootLease,
        [Parameter(Mandatory)][string] $RootPath,
        [Parameter(Mandatory)][string] $RelativePath
    )

    $currentLease = $RootLease
    $ownsCurrent = $false
    $currentPath = $RootPath
    try {
        foreach ($segment in @($RelativePath.Replace('\', '/').Split('/', [StringSplitOptions]::RemoveEmptyEntries))) {
            $state = Get-PlatformDirectoryState -ParentLease $currentLease -Leaf $segment
            $nextLease = if ($state.exists) {
                Open-PlatformDirectory -Root $currentPath -RelativePath $segment
            }
            else {
                Open-PlatformDirectory -Root $currentPath -RelativePath $segment -CreatePrivate
            }
            if ($ownsCurrent) { $currentLease.Dispose() }
            $currentLease = $nextLease
            $ownsCurrent = $true
            $currentPath = Join-Path $currentPath $segment
        }
        if (-not $ownsCurrent) { throw 'Relative directory path must contain at least one child segment.' }
        $result = $currentLease
        $currentLease = $null
        return $result
    }
    finally { if ($null -ne $currentLease -and $ownsCurrent) { $currentLease.Dispose() } }
}

function Copy-PesterLeasedFile {
    param(
        [Parameter(Mandatory)] $SourceParentLease,
        [Parameter(Mandatory)][string] $SourceLeaf,
        [Parameter(Mandatory)] $DestinationParentLease,
        [Parameter(Mandatory)][string] $DestinationLeaf
    )

    $source = $null
    $destination = $null
    try {
        $source = Open-PlatformFile -ParentLease $SourceParentLease -Leaf $SourceLeaf -Access Read -CreateMode OpenExisting
        $sourceIdentity = Assert-PlatformFileIdentity -Lease $source -Expected $source.Observation -SingleLink -VerifyPath
        $destination = Open-PlatformFile -ParentLease $DestinationParentLease -Leaf $DestinationLeaf -Access ReadWrite -CreateMode CreateNew
        $destinationIdentity = $destination.Observation
        $destination.WriteNewBytes($source.ReadAllBytes(268435456))
        [void](Assert-PlatformFileIdentity -Lease $source -Expected $sourceIdentity -SingleLink -VerifyPath)
        [void](Assert-PlatformFileIdentity -Lease $destination -Expected $destinationIdentity -SingleLink -VerifyPath)
    }
    finally {
        if ($null -ne $destination) { $destination.Dispose() }
        if ($null -ne $source) { $source.Dispose() }
    }
}

$helperPath = Join-Path $PSScriptRoot 'CorePesterIntegrity.psm1'
Import-Module -Name $helperPath -Force -ErrorAction Stop
$driverModule = Import-Module -Name (Join-Path $PSScriptRoot 'StandardSourceDriver.psm1') -Force -PassThru -ErrorAction Stop
$platformRuntimeModule = Import-DarktideAuthorityPlatformRuntime -AuthorityRoot $AuthorityRepositoryRoot -AuthorityRevision $AuthorityRevision
Import-Module -ModuleInfo $platformRuntimeModule -Force -ErrorAction Stop
$cacheRootLease = $null
$cacheFileLease = $null
$cacheArchiveParentLease = $null
$cacheArchiveLease = $null
$archivePayloadLease = $null
$setupRootLease = $null
$stageRootLease = $null
$lockPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../config/pester-6.2.0-closure.lock.json'))
$lockRecord = Read-CorePesterClosureLock -LiteralPath $lockPath
$runtimeExecutable = [IO.Path]::GetFullPath($RuntimeExecutable)
$actualExecutable = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not $runtimeExecutable.Equals($actualExecutable, $pathComparison)) {
    throw 'Pester setup must run under the exact verified PowerShell executable it will populate.'
}
$runtimeModuleRoot = Get-CorePesterRuntimeModuleRoot -ExecutablePath $runtimeExecutable
$ownedRoot = [IO.Path]::GetFullPath($OwnedRoot)
$ownedBoundary = Test-CorePesterPathBoundary -Path $ownedRoot -Boundary $ownedRoot
if (-not $ownedBoundary.IsValid) { throw ('Pester setup evidence root is unsafe: ' + (@($ownedBoundary.Errors) -join '; ')) }
$registeredOwnedRoot = [Environment]::GetEnvironmentVariable('RUN_OWNED_ROOT', 'Process')
if ([string]::IsNullOrWhiteSpace($registeredOwnedRoot) -or
    -not ([IO.Path]::GetFullPath($registeredOwnedRoot)).Equals($ownedRoot, $pathComparison)) {
    throw 'Pester setup root does not match the workflow-registered run-owned root.'
}
$setupRoot = Join-Path $ownedRoot 'pester-setup'
$setupBoundary = Test-CorePesterPathBoundary -Path $setupRoot -Boundary $ownedRoot
if (-not $setupBoundary.IsValid) { throw ('Pester setup evidence path is unsafe: ' + (@($setupBoundary.Errors) -join '; ')) }
$setupRootLease = Open-PlatformDirectory -Root $ownedRoot -RelativePath 'pester-setup' -CreatePrivate
$setupBoundary = Test-CorePesterPathBoundary -Path $setupRoot -Boundary $ownedRoot
if (-not $setupBoundary.IsValid) { throw ('Pester setup evidence path became unsafe: ' + (@($setupBoundary.Errors) -join '; ')) }
$archivePath = Join-Path $setupRoot 'Pester.6.2.0.nupkg'
$stageRoot = Join-Path $setupRoot 'staging'
$destinationCreated = $false
$destinationModuleRoot = $runtimeModuleRoot
$cleanupFailed = $false
$successMessage = $null

try {
    $sourceUri = [string]$lockRecord.Value.source.packageUri
    if ($sourceUri -cne 'https://www.powershellgallery.com/api/v2/package/Pester/6.2.0') {
        throw 'Pester setup source URI differs from the pinned official PSGallery endpoint.'
    }
    $observedFinalPackageUri = $null
    $cacheArchivePath = $null
    $cacheWasUsed = $false
    if (-not [string]::IsNullOrWhiteSpace($PackageCacheRoot)) {
        try {
            if (-not [IO.Path]::IsPathFullyQualified($PackageCacheRoot)) { throw 'cache root is not fully qualified' }
            if ([string]::IsNullOrWhiteSpace($AuthorityRepositoryRoot) -or [string]::IsNullOrWhiteSpace($AuthorityRevision)) {
                throw 'verified authority platform runtime parameters were not supplied'
            }
            $cacheRoot = [IO.Path]::GetFullPath($PackageCacheRoot)
            $cacheRootLease = Open-PesterPackageCacheRoot -Path $cacheRoot -RunOwnedRoot $ownedRoot
            [void](Assert-PlatformFileIdentity -Lease $cacheRootLease -Expected $cacheRootLease.Observation -VerifyPath)
            $cacheArchivePath = Join-Path $cacheRoot 'Pester.6.2.0.nupkg'
            try {
                $cacheFileLease = Open-PlatformFile -ParentLease $cacheRootLease -Leaf 'Pester.6.2.0.nupkg' -Access Read -CreateMode OpenExisting
                $cacheIdentity = Assert-PlatformFileIdentity -Lease $cacheFileLease -Expected $cacheFileLease.Observation -SingleLink -VerifyPath
                $cachedPackage = Test-CorePesterPackageArchive -ArchivePath $cacheArchivePath -Lock $lockRecord.Value
                if (-not $cachedPackage.IsValid) { throw (@($cachedPackage.Errors) -join '; ') }
                $cacheArchiveParentLease = Open-PlatformDirectory -Root $setupRoot -RootOnly
                $cacheArchiveLease = Open-PlatformFile -ParentLease $cacheArchiveParentLease -Leaf 'Pester.6.2.0.nupkg' -Access ReadWrite -CreateMode CreateNew
                $archiveIdentity = $cacheArchiveLease.Observation
                $cacheArchiveLease.WriteNewBytes($cacheFileLease.ReadAllBytes(268435456))
                [void](Assert-PlatformFileIdentity -Lease $cacheArchiveLease -Expected $archiveIdentity -SingleLink -VerifyPath)
                $cacheArchiveLease.Dispose(); $cacheArchiveLease = $null
                [void](Assert-PlatformFileIdentity -Lease $cacheFileLease -Expected $cacheIdentity -SingleLink -VerifyPath)
                $cacheWasUsed = $true
            }
            catch {
                throw "existing cache package could not be leased and verified: $($_.Exception.Message)"
            }
        }
        catch {
            $cacheArchivePath = $null
            if ($null -ne $cacheFileLease) { $cacheFileLease.Dispose(); $cacheFileLease = $null }
            if ($null -ne $cacheRootLease) { $cacheRootLease.Dispose(); $cacheRootLease = $null }
            [Console]::Error.WriteLine("Pester package cache disabled: $($_.Exception.Message)")
        }
    }
    if (-not $cacheWasUsed) {
        $downloadResponse = Invoke-WebRequest -Uri $sourceUri -OutFile $archivePath -PassThru -MaximumRedirection 3 -TimeoutSec 180 -ErrorAction Stop
        if ($null -ne $downloadResponse -and $null -ne $downloadResponse.BaseResponse -and
            $null -ne $downloadResponse.BaseResponse.RequestMessage -and
            $null -ne $downloadResponse.BaseResponse.RequestMessage.RequestUri) {
            $observedFinalPackageUri = [string]$downloadResponse.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
        }
    }
    if ($null -ne $observedFinalPackageUri -and $observedFinalPackageUri -cnotmatch '^https://') {
        throw 'PSGallery acquisition resolved to a non-HTTPS final package URI.'
    }
    $package = Test-CorePesterPackageArchive -ArchivePath $archivePath -Lock $lockRecord.Value
    if (-not $package.IsValid) { throw ('Official Pester package does not match the complete reviewed lock: ' + (@($package.Errors) -join '; ')) }
    $archivePayloadLease = Open-PlatformFile -ParentLease $setupRootLease -Leaf 'Pester.6.2.0.nupkg' -Access Read -CreateMode OpenExisting
    $archivePayloadIdentity = Assert-PlatformFileIdentity -Lease $archivePayloadLease -Expected $archivePayloadLease.Observation -SingleLink -VerifyPath
    $runtimeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $destinationModuleRoot))
    $runtimeRootLease = Open-PlatformDirectory -Root $runtimeRoot -RootOnly
    try {
        $destinationState = Get-PlatformDirectoryState -ParentLease $runtimeRootLease -Leaf 'Modules'
        if ($destinationState.exists) {
            $modulesProbe = Open-PlatformDirectory -Root $runtimeRoot -RelativePath 'Modules'
            try {
                $pesterState = Get-PlatformDirectoryState -ParentLease $modulesProbe -Leaf 'Pester'
                if ($pesterState.exists) { throw 'The verified PowerShell runtime already contains a Pester destination; setup refuses overwrite.' }
            }
            finally { $modulesProbe.Dispose() }
        }
    }
    finally { $runtimeRootLease.Dispose() }
    $destinationBoundary = Test-CorePesterPathBoundary -Path $destinationModuleRoot -Boundary $runtimeRoot
    if (-not $destinationBoundary.IsValid) {
        throw ('Pester destination is outside the verified runtime or has a reparse-point ancestor: ' + (@($destinationBoundary.Errors) -join '; '))
    }

    $stageBoundary = Test-CorePesterPathBoundary -Path $stageRoot -Boundary $setupRoot
    if (-not $stageBoundary.IsValid) { throw ('Pester staging path is unsafe: ' + (@($stageBoundary.Errors) -join '; ')) }
    $stageRootLease = Open-PlatformDirectory -Root $setupRoot -RelativePath 'staging' -CreatePrivate
    $stageBoundary = Test-CorePesterPathBoundary -Path $stageRoot -Boundary $setupRoot
    if (-not $stageBoundary.IsValid) { throw ('Pester staging path became unsafe: ' + (@($stageBoundary.Errors) -join '; ')) }
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        foreach ($payload in $lockRecord.Value.modulePayload) {
            $relative = [string]$payload.path
            $archiveEntry = @($archive.Entries | Where-Object { [string]$_.FullName -ceq $relative })
            if ($archiveEntry.Count -ne 1) { throw "Verified package payload does not have one exact entry: $relative" }
            $targetPath = [IO.Path]::GetFullPath((Join-Path $stageRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))))
            $stagePrefix = $stageRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if (-not $targetPath.StartsWith($stagePrefix, $pathComparison)) { throw "Package path escaped owned staging: $relative" }
            $targetRelativeDirectory = Split-Path -Parent ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $targetDirectoryLease = if ([string]::IsNullOrWhiteSpace($targetRelativeDirectory)) { $null }
                else { Open-PesterRelativeDirectory -RootLease $stageRootLease -RootPath $stageRoot -RelativePath $targetRelativeDirectory }
            $inputStream = $archiveEntry[0].Open()
            $outputParentLease = if ($null -eq $targetDirectoryLease) { $stageRootLease } else { $targetDirectoryLease }
            $outputLease = Open-PlatformFile -ParentLease $outputParentLease -Leaf ([IO.Path]::GetFileName($targetPath)) -Access ReadWrite -CreateMode CreateNew
            try {
                $buffer = [IO.MemoryStream]::new()
                try { $inputStream.CopyTo($buffer); $outputLease.WriteNewBytes($buffer.ToArray()) }
                finally { $buffer.Dispose() }
                [void](Assert-PlatformFileIdentity -Lease $outputLease -Expected $outputLease.Observation -SingleLink -VerifyPath)
            }
            finally {
                $inputStream.Dispose()
                $outputLease.Dispose()
                if ($null -ne $targetDirectoryLease) { $targetDirectoryLease.Dispose() }
            }
        }
    }
    finally { $archive.Dispose() }
    [void](Assert-PlatformFileIdentity -Lease $archivePayloadLease -Expected $archivePayloadIdentity -SingleLink -VerifyPath)

    $stagedClosure = Test-CorePesterClosure -ModuleRoot $stageRoot -Lock $lockRecord.Value
    if (-not $stagedClosure.IsValid) { throw ('Staged Pester package closure failed: ' + (@($stagedClosure.Errors) -join '; ')) }
    $runtimeRootLease = Open-PlatformDirectory -Root $runtimeRoot -RootOnly
    $destinationModuleLease = Open-PesterRelativeDirectory -RootLease $runtimeRootLease -RootPath $runtimeRoot -RelativePath 'Modules/Pester/6.2.0'
    $destinationCreated = $true
    try {
        foreach ($payload in $lockRecord.Value.modulePayload) {
            $relative = [string]$payload.path
            $relativeDirectory = Split-Path -Parent ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
            $sourceParent = if ([string]::IsNullOrWhiteSpace($relativeDirectory)) { $stageRootLease }
                else { Open-PlatformDirectory -Root $stageRoot -RelativePath $relativeDirectory }
            $destinationParent = if ([string]::IsNullOrWhiteSpace($relativeDirectory)) { $destinationModuleLease }
                else { Open-PesterRelativeDirectory -RootLease $destinationModuleLease -RootPath $destinationModuleRoot -RelativePath $relativeDirectory }
            try {
                Copy-PesterLeasedFile -SourceParentLease $sourceParent -SourceLeaf ([IO.Path]::GetFileName($relative)) `
                    -DestinationParentLease $destinationParent -DestinationLeaf ([IO.Path]::GetFileName($relative))
            }
            finally {
                if ($sourceParent -ne $stageRootLease) { $sourceParent.Dispose() }
                if ($destinationParent -ne $destinationModuleLease) { $destinationParent.Dispose() }
            }
        }
    }
    finally {
        $destinationModuleLease.Dispose()
        $runtimeRootLease.Dispose()
    }
    $runtimeClosure = Test-CorePesterClosure -ModuleRoot $destinationModuleRoot -Lock $lockRecord.Value
    if (-not $runtimeClosure.IsValid) { throw ('Installed PowerShell runtime closure failed: ' + (@($runtimeClosure.Errors) -join '; ')) }

    $archiveSha = [string]$package.ObservedArchiveSha256
    $receipt = [ordered]@{
        schemaVersion = 1
        report = 'verified-pester-runtime-setup-v1'
        sourceUri = $sourceUri
        observedFinalPackageUri = $observedFinalPackageUri
        finalPackageUriObserved = ($null -ne $observedFinalPackageUri)
        packageCacheUsed = $cacheWasUsed
        sourceName = [string]$lockRecord.Value.source.sourceName
        version = [string]$lockRecord.Value.source.version
        officialArchiveDigestClaimed = $false
        observedArchiveSha256 = $archiveSha
        archiveEntryCount = $package.EntryCount
        modulePayloadCount = $package.PayloadCount
        installerMetadata = [ordered]@{ path = 'PSGetModuleInfo.xml'; observedInOfficialPackage = $false; copied = $false }
        lockPath = $lockRecord.Path
        lockSha256 = $lockRecord.Sha256
        runtimeExecutable = $runtimeExecutable
        runtimeModuleRoot = $destinationModuleRoot
        closureSha256 = $runtimeClosure.ClosureSha256
        payload = @($runtimeClosure.Inventory)
        terminalStatus = 'verified'
    }
    $receiptPath = Join-Path $setupRoot 'setup-receipt.json'
    $receiptBytes = [Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $receipt -Depth 6 -Compress) + "`n")
    $receiptLease = Open-PlatformFile -ParentLease $setupRootLease -Leaf 'setup-receipt.json' -Access ReadWrite -CreateMode CreateNew
    try {
        $receiptLease.WriteNewBytes($receiptBytes)
        [void](Assert-PlatformFileIdentity -Lease $receiptLease -Expected $receiptLease.Observation -SingleLink -VerifyPath)
    }
    finally { $receiptLease.Dispose() }
    $receiptHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData((Get-CorePesterLeasedBytes -Path $receiptPath -Limit 16777216))).ToLowerInvariant()
    [Console]::Error.WriteLine("Verified Pester setup: path=`"$receiptPath`" sha256=$receiptHash archiveSha256=$archiveSha payloads=$($package.PayloadCount) closureSha256=$($runtimeClosure.ClosureSha256)")
    $successMessage = "Pester 6.2.0 exact closure installed under verified PowerShell runtime; receipt SHA256 $receiptHash"
}
catch {
    [Console]::Error.WriteLine("Pester runtime setup failed: $($_.Exception.Message)")
    if ($destinationCreated) {
        try {
            $runtimeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $destinationModuleRoot))
            $destinationBoundary = Test-CorePesterPathBoundary -Path $destinationModuleRoot -Boundary $runtimeRoot
            if (-not $destinationBoundary.IsValid) { throw ('Refusing unsafe recursive runtime cleanup: ' + (@($destinationBoundary.Errors) -join '; ')) }
            $pesterParentLease = Open-PlatformDirectory -Root $runtimeRoot -RelativePath 'Modules/Pester'
            try {
                $destinationState = Get-PlatformDirectoryState -ParentLease $pesterParentLease -Leaf '6.2.0'
                if ($destinationState.exists) {
                    Remove-PlatformOwnedDirectoryTree -TransactionRootLease $pesterParentLease -Leaf '6.2.0' -ExpectedIdentity $destinationState.identity
                }
                if ((Get-PlatformDirectoryState -ParentLease $pesterParentLease -Leaf '6.2.0').exists) {
                    throw 'Owned runtime destination cleanup did not remove the Pester directory.'
                }
            }
            finally { $pesterParentLease.Dispose() }
        }
        catch {
            $cleanupFailed = $true
            [Console]::Error.WriteLine("Pester runtime cleanup failed closed: $($_.Exception.Message)")
        }
    }
    exit 1
}
finally {
    if ($null -ne $cacheArchiveLease) { $cacheArchiveLease.Dispose(); $cacheArchiveLease = $null }
    if ($null -ne $archivePayloadLease) { $archivePayloadLease.Dispose(); $archivePayloadLease = $null }
    if ($null -ne $cacheArchiveParentLease) { $cacheArchiveParentLease.Dispose(); $cacheArchiveParentLease = $null }
    if ($null -ne $cacheFileLease) { $cacheFileLease.Dispose(); $cacheFileLease = $null }
    if ($null -ne $cacheRootLease) { $cacheRootLease.Dispose(); $cacheRootLease = $null }
    try {
        $stageBoundary = Test-CorePesterPathBoundary -Path $stageRoot -Boundary $setupRoot
        if (-not $stageBoundary.IsValid) { throw ('Refusing unsafe recursive staging cleanup: ' + (@($stageBoundary.Errors) -join '; ')) }
        if ($null -ne $stageRootLease) { $stageRootLease.Dispose(); $stageRootLease = $null }
        $stageState = Get-PlatformDirectoryState -ParentLease $setupRootLease -Leaf 'staging'
        if ($stageState.exists) {
            Remove-PlatformOwnedDirectoryTree -TransactionRootLease $setupRootLease -Leaf 'staging' -ExpectedIdentity $stageState.identity
        }
        if ((Get-PlatformDirectoryState -ParentLease $setupRootLease -Leaf 'staging').exists) { throw 'Owned staging cleanup did not remove the staging directory.' }
    }
    catch {
        $cleanupFailed = $true
        [Console]::Error.WriteLine("Pester staging cleanup failed closed: $($_.Exception.Message)")
    }
    if ($null -ne $setupRootLease) { $setupRootLease.Dispose(); $setupRootLease = $null }
    if ($null -ne $platformRuntimeModule) { Remove-Module -ModuleInfo $platformRuntimeModule -Force -ErrorAction SilentlyContinue; $platformRuntimeModule = $null }
    if ($null -ne $driverModule) { Remove-Module -ModuleInfo $driverModule -Force -ErrorAction SilentlyContinue; $driverModule = $null }
}
if ($cleanupFailed) { exit 1 }
if ($null -ne $successMessage) { Write-Output $successMessage }
