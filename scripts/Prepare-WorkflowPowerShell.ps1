# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Resolve', 'Install', 'Verify')][string] $Mode,
    [Parameter(Mandatory)][ValidateSet('windows', 'linux', 'macos')][string] $Platform,
    [Parameter(Mandatory)][ValidateSet('x64', 'arm64')][string] $ExpectedArchitecture,
    [Parameter(Mandatory)][string] $ExecutableName,
    [string] $AssetTemplate,
    [string] $RuntimeRoot,
    [string] $OwnedRoot,
    [string] $ArtifactsRoot,
    [string] $CacheRoot,
    [string] $Version,
    [string] $ReleaseTag,
    [string] $AssetName,
    [string] $ArchiveUrl,
    [string] $HashesUrl,
    [string] $OfficialArchiveSha256,
    [string] $HashesManifestSha256,
    [string] $FreshHashesPath,
    [switch] $DefineFunctionsOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Asset naming, manifest digest parsing, extraction, Authenticode and version
# checks are shared with the repository installer through PowerShellRelease.psm1.
$releaseModule = Import-Module -Name (Join-Path $PSScriptRoot 'PowerShellRelease.psm1') -Force -PassThru -ErrorAction Stop
$platformRuntimeModule = & $releaseModule { $script:PowerShellReleasePlatformRuntimeModule }
if ($platformRuntimeModule -isnot [Management.Automation.PSModuleInfo]) { throw 'PowerShell release module did not expose its registry-bound platform runtime.' }
Import-Module -ModuleInfo $platformRuntimeModule -Force -ErrorAction Stop
if ($ExecutableName -cne (Get-PowerShellExecutableName -Platform $Platform)) {
    throw "ExecutableName '$ExecutableName' is not the official $Platform PowerShell executable."
}

function Assert-WorkflowArchitecture {
    $actual = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($actual -cne $ExpectedArchitecture) {
        throw "Expected $ExpectedArchitecture runner architecture, got $actual."
    }
}

function Resolve-WorkflowPhysicalPath {
    param([Parameter(Mandatory)][string] $Path)
    return [IO.Path]::GetFullPath((Resolve-PlatformPhysicalPath -Path ([IO.Path]::GetFullPath($Path))))
}

function Assert-RequiredValue {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $Name)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name is required for workflow PowerShell $Mode mode." }
}

function Get-OfficialManifestArchiveSha256 {
    param([Parameter(Mandatory)][string] $ManifestPath, [Parameter(Mandatory)][string] $ArchiveName)
    return Get-OfficialPowerShellManifestDigest -Path $ManifestPath -ArchiveName $ArchiveName
}

function Open-WorkflowFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Access, [Parameter(Mandatory)][string] $CreateMode)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($full)) -RootOnly
    try {
        $file = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($full)) -Access $Access -CreateMode $CreateMode
        return [pscustomobject]@{ Parent = $parent; File = $file; Path = $full }
    }
    catch { $parent.Dispose(); throw }
}

function Close-WorkflowFile {
    param([Parameter(Mandatory)] $Binding)
    try { $Binding.File.Dispose() } finally { $Binding.Parent.Dispose() }
}

function Copy-WorkflowFile {
    param([Parameter(Mandatory)][string] $Source, [Parameter(Mandatory)][string] $Destination)
    $sourceBinding = Open-WorkflowFile -Path $Source -Access Read -CreateMode OpenExisting
    $destinationBinding = $null
    try {
        $sourceIdentity = Assert-PlatformFileIdentity -Lease $sourceBinding.File -Expected $sourceBinding.File.Observation -SingleLink -VerifyPath
        $destinationBinding = Open-WorkflowFile -Path $Destination -Access ReadWrite -CreateMode CreateNew
        $destinationBinding.File.WriteNewBytes($sourceBinding.File.ReadAllBytes(1073741824))
        [void](Assert-PlatformFileIdentity -Lease $sourceBinding.File -Expected $sourceIdentity -SingleLink -VerifyPath)
        [void](Assert-PlatformFileIdentity -Lease $destinationBinding.File -Expected $destinationBinding.File.Observation -SingleLink -VerifyPath)
    }
    finally {
        if ($null -ne $destinationBinding) { Close-WorkflowFile -Binding $destinationBinding }
        Close-WorkflowFile -Binding $sourceBinding
    }
}

function New-WorkflowPowerShellAssetEvidence {
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $ManifestPath,
        [Parameter(Mandatory)][string] $ArchiveName,
        [Parameter(Mandatory)][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $ManifestSha256
    )
    $archiveBinding = Open-WorkflowFile -Path $ArchivePath -Access Read -CreateMode OpenExisting
    $manifestBinding = Open-WorkflowFile -Path $ManifestPath -Access Read -CreateMode OpenExisting
    try {
        $archiveLength = $archiveBinding.File.ReadAllBytes(1073741824).Length
        $manifestLength = $manifestBinding.File.ReadAllBytes(16777216).Length
    }
    finally { Close-WorkflowFile -Binding $archiveBinding; Close-WorkflowFile -Binding $manifestBinding }
    return [pscustomobject][ordered]@{
        platform = $Platform
        name = $ArchiveName
        digest = "sha256:$ArchiveSha256"
        size = [long]$archiveLength
        hashesManifest = [pscustomobject][ordered]@{
            name = 'hashes.sha256'
            digest = "sha256:$ManifestSha256"
            size = [long]$manifestLength
        }
    }
}

function Get-WorkflowPowerShellVersion {
    param(
        [Parameter(Mandatory)][string] $ExecutablePath,
        [Parameter(Mandatory)] $ExecutableLease,
        [Parameter(Mandatory)][string] $WorkingDirectoryPath,
        [Parameter(Mandatory)] $WorkingDirectoryLease
    )

    $result = Invoke-PowerShellReleaseOwnedProcess -ExecutableLease $ExecutableLease `
        -ExecutablePath $ExecutablePath -WorkingDirectoryLease $WorkingDirectoryLease `
        -WorkingDirectoryPath $WorkingDirectoryPath -TimeoutSeconds 15 -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-Command',
            '[Console]::Out.Write($PSVersionTable.PSVersion.ToString())'
        )
    if ($result.exitCode -ne 0) {
        throw "Installed PowerShell version probe failed with code $($result.exitCode): $($result.stderr.Trim())"
    }
    return ([string]$result.stdout).Trim()
}

if ($DefineFunctionsOnly) { return }

Assert-WorkflowArchitecture

switch ($Mode) {
    'Resolve' {
        Assert-RequiredValue -Value $AssetTemplate -Name 'AssetTemplate'
        Assert-RequiredValue -Value $env:GITHUB_OUTPUT -Name 'GITHUB_OUTPUT'
        Assert-RequiredValue -Value $env:RUNNER_TEMP -Name 'RUNNER_TEMP'
        $releaseUri = [Uri]'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
        $metadataHeaders = @{
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2022-11-28'
            'User-Agent' = 'Skill-Darktide-Translate-Source-Validation'
        }
        if (-not [string]::IsNullOrWhiteSpace($env:DT_GITHUB_API_TOKEN) -and $releaseUri.Host -ceq 'api.github.com') {
            $metadataHeaders.Authorization = "Bearer $($env:DT_GITHUB_API_TOKEN)"
        }
        $metadataResponse = $null
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                # Do not use -PreserveAuthorizationOnRedirect: PowerShell drops Authorization on redirects by default.
                $metadataResponse = Invoke-WebRequest -Uri $releaseUri -Headers $metadataHeaders -TimeoutSec 60 -ErrorAction Stop
                break
            }
            catch {
                $responseProperty = $_.Exception.PSObject.Properties['Response']
                $statusCode = if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) { [int]$responseProperty.Value.StatusCode } else { 0 }
                if ($attempt -eq 3 -or -not ($statusCode -eq 403 -or $statusCode -eq 429 -or $statusCode -ge 500)) { throw }
                Start-Sleep -Seconds 10
            }
        }
        if ($null -eq $metadataResponse) { throw 'PowerShell release metadata request did not return a response.' }
        $finalUri = [Uri]$metadataResponse.BaseResponse.RequestMessage.RequestUri
        if ($finalUri.Host -cne 'api.github.com') {
            throw "PowerShell release metadata request redirected to an unexpected host: $($finalUri.Host)"
        }
        $release = $metadataResponse.Content | ConvertFrom-Json
        $verifiedAsset = Get-VerifiedPowerShellReleaseAsset -Release $release -Platform $Platform -Architecture $ExpectedArchitecture
        $tag = [string]$verifiedAsset.tag
        $resolvedVersion = [string]$verifiedAsset.version
        $resolvedAssetName = [string]$verifiedAsset.name
        if (($AssetTemplate -f $resolvedVersion) -cne $resolvedAssetName) {
            throw "Workflow asset template does not name the official $Platform/$ExpectedArchitecture archive '$resolvedAssetName'."
        }
        $archiveApiSha256 = ([string]$verifiedAsset.digest).Substring(7)
        $manifestApiSha256 = ([string]$verifiedAsset.hashesManifest.digest).Substring(7)
        $metadataRoot = New-PlatformPrivateRoot -Parent ([IO.Path]::GetFullPath($env:RUNNER_TEMP)) `
            -Leaf ("dt-pwsh-metadata-$Platform-$([guid]::NewGuid().ToString('N'))")
        $manifestPath = Join-Path $metadataRoot 'hashes.sha256'
        Invoke-WebRequest -Uri ([string]$verifiedAsset.hashesManifest.browserDownloadUrl) -OutFile $manifestPath -MaximumRedirection 3 -TimeoutSec 60 -ErrorAction Stop
        [void](Assert-VerifiedPowerShellHashesManifest -Asset $verifiedAsset -Path $manifestPath)
        $outputs = @(
            "version=$resolvedVersion", "tag=$tag", "asset=$resolvedAssetName",
            "archive_url=$([string]$verifiedAsset.browserDownloadUrl)",
            "hashes_url=$([string]$verifiedAsset.hashesManifest.browserDownloadUrl)",
            "official_sha256=$archiveApiSha256", "hashes_sha256=$manifestApiSha256",
            "fresh_hashes_path=$manifestPath"
        )
        [IO.File]::AppendAllText($env:GITHUB_OUTPUT, ($outputs -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
        break
    }
    'Install' {
        foreach ($required in @{
            RuntimeRoot = $RuntimeRoot; OwnedRoot = $OwnedRoot; ArtifactsRoot = $ArtifactsRoot; CacheRoot = $CacheRoot
            Version = $Version; ReleaseTag = $ReleaseTag; AssetName = $AssetName; ArchiveUrl = $ArchiveUrl
            HashesUrl = $HashesUrl; OfficialArchiveSha256 = $OfficialArchiveSha256
            HashesManifestSha256 = $HashesManifestSha256; FreshHashesPath = $FreshHashesPath
        }.GetEnumerator()) { Assert-RequiredValue -Value ([string]$required.Value) -Name ([string]$required.Key) }
        foreach ($sha in @($OfficialArchiveSha256, $HashesManifestSha256)) {
            if ($sha -cnotmatch '^[0-9a-f]{64}$') { throw 'Official PowerShell SHA-256 inputs must be lowercase hex.' }
        }
        $cacheRootFull = [IO.Path]::GetFullPath($CacheRoot)
        $cacheRootLease = Open-PlatformDirectory -Root $cacheRootFull -RootOnly
        try {
        $archivePath = Join-Path $CacheRoot $AssetName
        $cachedManifestPath = Join-Path $CacheRoot 'hashes.sha256'
        $cacheValid = $false
        $archiveState = $null
        $manifestState = $null
        $archiveProbe = $null
        try { $archiveProbe = Open-PlatformFile -ParentLease $cacheRootLease -Leaf $AssetName -Access Read -CreateMode OpenExisting }
        catch { $archiveProbe = $null }
        if ($null -ne $archiveProbe) {
            try { $archiveState = Assert-PlatformFileIdentity -Lease $archiveProbe -Expected $archiveProbe.Observation -SingleLink -VerifyPath }
            finally { $archiveProbe.Dispose() }
        }
        $manifestProbe = $null
        try { $manifestProbe = Open-PlatformFile -ParentLease $cacheRootLease -Leaf 'hashes.sha256' -Access Read -CreateMode OpenExisting }
        catch { $manifestProbe = $null }
        if ($null -ne $manifestProbe) {
            try { $manifestState = Assert-PlatformFileIdentity -Lease $manifestProbe -Expected $manifestProbe.Observation -SingleLink -VerifyPath }
            finally { $manifestProbe.Dispose() }
        }
        if (($null -eq $archiveState) -ne ($null -eq $manifestState)) {
            throw 'Existing PowerShell cache entry is incomplete and cannot be repaired in place.'
        }
        if ($null -ne $archiveState -and $null -ne $manifestState) {
            try {
                $cachedAsset = New-WorkflowPowerShellAssetEvidence -ArchivePath $archivePath -ManifestPath $cachedManifestPath `
                    -ArchiveName $AssetName -ArchiveSha256 $OfficialArchiveSha256 -ManifestSha256 $HashesManifestSha256
                [void](Assert-VerifiedPowerShellArchive -Asset $cachedAsset -Path $archivePath)
                [void](Assert-VerifiedPowerShellHashesManifest -Asset $cachedAsset -Path $cachedManifestPath)
                $cacheValid = $true
            }
            catch {
                throw "Existing PowerShell cache entry failed closed: $($_.Exception.Message)"
            }
        }
        if (-not $cacheValid) {
            $archiveBinding = Open-WorkflowFile -Path $archivePath -Access ReadWrite -CreateMode CreateNew
            $manifestBinding = $null
            try {
                $manifestBinding = Open-WorkflowFile -Path $cachedManifestPath -Access ReadWrite -CreateMode CreateNew
                $download = Invoke-WebRequest -Uri $ArchiveUrl -MaximumRedirection 3 -TimeoutSec 300 -ErrorAction Stop
                $memory = [IO.MemoryStream]::new()
                try { $download.RawContentStream.CopyTo($memory); $archiveBinding.File.WriteNewBytes($memory.ToArray()) }
                finally { $memory.Dispose() }
                $freshManifest = Open-WorkflowFile -Path $FreshHashesPath -Access Read -CreateMode OpenExisting
                try {
                    $freshIdentity = Assert-PlatformFileIdentity -Lease $freshManifest.File `
                        -Expected $freshManifest.File.Observation -SingleLink -VerifyPath
                    $manifestBinding.File.WriteNewBytes($freshManifest.File.ReadAllBytes(16777216))
                    [void](Assert-PlatformFileIdentity -Lease $freshManifest.File -Expected $freshIdentity -SingleLink -VerifyPath)
                }
                finally { Close-WorkflowFile -Binding $freshManifest }
                [void](Assert-PlatformFileIdentity -Lease $archiveBinding.File -Expected $archiveBinding.File.Observation -SingleLink -VerifyPath)
                [void](Assert-PlatformFileIdentity -Lease $manifestBinding.File -Expected $manifestBinding.File.Observation -SingleLink -VerifyPath)
            }
            finally {
                if ($null -ne $manifestBinding) { Close-WorkflowFile -Binding $manifestBinding }
                Close-WorkflowFile -Binding $archiveBinding
            }
        }
        $verifiedAsset = New-WorkflowPowerShellAssetEvidence -ArchivePath $archivePath -ManifestPath $cachedManifestPath `
            -ArchiveName $AssetName -ArchiveSha256 $OfficialArchiveSha256 -ManifestSha256 $HashesManifestSha256
        $observedArchiveSha256 = Assert-VerifiedPowerShellArchive -Asset $verifiedAsset -Path $archivePath
        [void](Assert-VerifiedPowerShellHashesManifest -Asset $verifiedAsset -Path $cachedManifestPath)
        if ($AssetName -cne (Get-PowerShellReleaseAssetName -Version $Version -Platform $Platform -Architecture $ExpectedArchitecture)) {
            throw 'AssetName is not the official archive for this platform and architecture.'
        }
        # RuntimeRoot is an attempt-specific, not-yet-existing leaf. The extractor
        # creates it once and preserves a marked unusable directory on failure.
        $executable = Expand-VerifiedPowerShellArchive -Asset $verifiedAsset -ArchivePath $archivePath -DestinationPath $RuntimeRoot
        try {
        $signature = Assert-PowerShellExecutableSignature -Path $executable -Platform $Platform
        $signatureStatus = $signature.status; $signerSubject = $signature.signerSubject; $signerThumbprint = $signature.signerThumbprint
        $runtimeLease = Open-PlatformDirectory -Root ([IO.Path]::GetFullPath($RuntimeRoot)) -RootOnly
        $ownedLease = $null
        $executableLease = $null
        try {
            $ownedLease = Open-PlatformDirectory -Root ([IO.Path]::GetFullPath($OwnedRoot)) -RootOnly
            $executableLease = Open-PlatformFile -ParentLease $runtimeLease -Leaf $ExecutableName -Access Read -CreateMode OpenExisting
            $versionOutput = Get-WorkflowPowerShellVersion -ExecutablePath $executable -ExecutableLease $executableLease `
                -WorkingDirectoryPath $OwnedRoot -WorkingDirectoryLease $ownedLease
        }
        finally {
            if ($null -ne $executableLease) { $executableLease.Dispose() }
            if ($null -ne $ownedLease) { $ownedLease.Dispose() }
            $runtimeLease.Dispose()
        }
        [void](Assert-PowerShellRuntimeVersion -Tag $ReleaseTag -ActualVersion $versionOutput)
        if ($versionOutput -cne $Version) { throw 'Installed PowerShell version differs from the latest stable release tag.' }
        $receipt = [ordered]@{
            schemaVersion = 1; report = 'verified-latest-official-powershell-runtime-v1'
            sourceRepository = 'https://github.com/PowerShell/PowerShell'; releaseApi = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            releaseTag = $ReleaseTag; version = $Version; platform = $Platform; architecture = $ExpectedArchitecture
            archiveUri = $ArchiveUrl; hashesManifestUri = $HashesUrl; officialArchiveSha256 = $OfficialArchiveSha256
            observedArchiveSha256 = $observedArchiveSha256
            executablePath = [IO.Path]::GetFullPath($executable); executableAuthenticodeStatus = $signatureStatus
            executableSignerSubject = $signerSubject; executableSignerThumbprint = $signerThumbprint; cacheRestoredAndValid = $cacheValid
        }
        $receiptPath = Join-Path $OwnedRoot 'powershell-runtime-setup.json'
        $receiptBinding = Open-WorkflowFile -Path $receiptPath -Access ReadWrite -CreateMode CreateNew
        try {
            $receiptBinding.File.WriteNewBytes([Text.UTF8Encoding]::new($false).GetBytes((($receipt | ConvertTo-Json -Depth 8) + "`n")))
            [void](Assert-PlatformFileIdentity -Lease $receiptBinding.File -Expected $receiptBinding.File.Observation -SingleLink -VerifyPath)
        }
        finally { Close-WorkflowFile -Binding $receiptBinding }
        Copy-WorkflowFile -Source $receiptPath -Destination (Join-Path $ArtifactsRoot 'powershell-runtime-setup.json')
        Copy-WorkflowFile -Source $cachedManifestPath -Destination (Join-Path $ArtifactsRoot 'powershell-release-hashes.sha256')
        [IO.File]::AppendAllText($env:GITHUB_ENV, "DT_POWERSHELL_EXECUTABLE=$([IO.Path]::GetFullPath($executable))`nDT_POWERSHELL_VERSION=$Version`nDT_POWERSHELL_ARCHIVE_SHA256=$OfficialArchiveSha256`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::AppendAllText($env:GITHUB_PATH, "$RuntimeRoot`n", [Text.UTF8Encoding]::new($false))
        break
        }
        catch {
            $runtimeFailure = $_
            try { Set-PowerShellRuntimeUnusable -DestinationPath $RuntimeRoot }
            catch {
                throw [IO.IOException]::new(
                    "$($runtimeFailure.Exception.Message) Failed runtime could not be marked unusable.",
                    [AggregateException]::new($runtimeFailure.Exception, $_.Exception))
            }
            throw $runtimeFailure
        }
        }
        finally { $cacheRootLease.Dispose() }
    }
    'Verify' {
        Assert-RequiredValue -Value $env:DT_POWERSHELL_EXECUTABLE -Name 'DT_POWERSHELL_EXECUTABLE'
        Assert-RequiredValue -Value $env:DT_POWERSHELL_VERSION -Name 'DT_POWERSHELL_VERSION'
        if ($env:DT_POWERSHELL_ARCHIVE_SHA256 -cnotmatch '^[0-9a-f]{64}$') { throw 'DT_POWERSHELL_ARCHIVE_SHA256 is invalid.' }
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        $expected = Resolve-WorkflowPhysicalPath $env:DT_POWERSHELL_EXECUTABLE
        $process = Resolve-WorkflowPhysicalPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $selected = Resolve-WorkflowPhysicalPath ((Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source)
        $pshomeExecutable = Resolve-WorkflowPhysicalPath (Join-Path $PSHOME $ExecutableName)
        if (-not $process.Equals($expected, $comparison) -or -not $selected.Equals($expected, $comparison) -or -not $pshomeExecutable.Equals($expected, $comparison)) {
            throw "The GitHub step shell is not the verified PowerShell: expected=$expected process=$process selected=$selected pshome=$pshomeExecutable"
        }
        if ($PSVersionTable.PSVersion.ToString() -cne $env:DT_POWERSHELL_VERSION) { throw 'Selected PowerShell version differs from its release receipt.' }
        break
    }
}
