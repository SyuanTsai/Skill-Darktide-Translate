# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$script:PowerShellReleasePathSafetyModule = Import-Module -Name (Join-Path $PSScriptRoot '../skills/auto-update-darktide-mod/scripts/PathSafety.psm1') -Force -PassThru -ErrorAction Stop
$script:PowerShellReleasePlatformRuntimeModule = & $script:PowerShellReleasePathSafetyModule { $script:VendoredPlatformRuntimeModule }
if ($script:PowerShellReleasePlatformRuntimeModule -isnot [Management.Automation.PSModuleInfo]) {
    throw 'Vendored authority platform runtime was not registry-bound for PowerShell release handling.'
}
Import-Module -ModuleInfo $script:PowerShellReleasePlatformRuntimeModule -Force -ErrorAction Stop

$script:PowerShellReleasePlatforms = @('windows', 'linux', 'macos')
$script:PowerShellReleaseArchitectures = @('x64', 'arm64')
$script:PowerShellHashesManifestName = 'hashes.sha256'

function Open-PowerShellReleaseFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Access)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($fullPath)) -RootOnly
    try {
        $file = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($fullPath)) -Access $Access -CreateMode OpenExisting
        $identity = Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink -VerifyPath
        return [pscustomobject]@{ Parent = $parent; File = $file; Identity = $identity; Path = $fullPath }
    }
    catch {
        $parent.Dispose()
        throw
    }
}

function Close-PowerShellReleaseFile {
    param([Parameter(Mandatory)] $Binding)
    try { $Binding.File.Dispose() } finally { $Binding.Parent.Dispose() }
}

function Open-PowerShellReleaseRelativeDirectory {
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
            if ($segment -in @('.', '..')) { throw 'PowerShell archive directory path is unsafe.' }
            $state = Get-PlatformDirectoryState -ParentLease $currentLease -Leaf $segment
            $nextLease = if ($state.exists) { Open-PlatformDirectory -Root $currentPath -RelativePath $segment }
                else { Open-PlatformDirectory -Root $currentPath -RelativePath $segment -CreatePrivate }
            if ($ownsCurrent) { $currentLease.Dispose() }
            $currentLease = $nextLease
            $ownsCurrent = $true
            $currentPath = Join-Path $currentPath $segment
        }
        if (-not $ownsCurrent) { throw 'PowerShell archive directory path is empty.' }
        $result = $currentLease
        $currentLease = $null
        return $result
    }
    finally { if ($null -ne $currentLease -and $ownsCurrent) { $currentLease.Dispose() } }
}

function Get-ReleaseField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Object,
        [Parameter(Mandatory)][string] $Name
    )

    if ($Object -is [Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { throw "PowerShell release metadata is missing '$Name'." }
        $value = $Object[$Name]
        return ,$value
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { throw "PowerShell release metadata is missing '$Name'." }
    $value = $property.Value
    return ,$value
}

function Get-PowerShellHostPlatform {
    [CmdletBinding()]
    param()

    if ([OperatingSystem]::IsWindows()) { return 'windows' }
    if ([OperatingSystem]::IsLinux()) { return 'linux' }
    if ([OperatingSystem]::IsMacOS()) { return 'macos' }
    throw 'Latest stable PowerShell installation supports only Windows, Linux, and macOS hosts.'
}

function Get-PowerShellHostArchitecture {
    [CmdletBinding()]
    param()

    $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
    if ($architecture -cnotin $script:PowerShellReleaseArchitectures) {
        throw "Latest stable PowerShell installation does not support the '$architecture' operating-system architecture."
    }
    return $architecture
}

function Assert-PowerShellReleaseTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Platform,
        [Parameter(Mandatory)][string] $Architecture
    )

    if ($Platform -cnotin $script:PowerShellReleasePlatforms) {
        throw "PowerShell release platform '$Platform' is not one of windows, linux, or macos."
    }
    if ($Architecture -cnotin $script:PowerShellReleaseArchitectures) {
        throw "PowerShell release architecture '$Architecture' is not one of x64 or arm64."
    }
}

function Get-PowerShellReleaseAssetName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Version,
        [Parameter(Mandatory)][string] $Platform,
        [Parameter(Mandatory)][string] $Architecture
    )

    if ($Version -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
        throw 'PowerShell release version is not a stable MAJOR.MINOR.PATCH version.'
    }
    Assert-PowerShellReleaseTarget -Platform $Platform -Architecture $Architecture
    switch -CaseSensitive ($Platform) {
        'windows' { return "PowerShell-$Version-win-$Architecture.zip" }
        'linux' { return "powershell-$Version-linux-$Architecture.tar.gz" }
        'macos' { return "powershell-$Version-osx-$Architecture.tar.gz" }
    }
}

function Get-PowerShellExecutableName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Platform)

    if ($Platform -cnotin $script:PowerShellReleasePlatforms) {
        throw "PowerShell release platform '$Platform' is not one of windows, linux, or macos."
    }
    if ($Platform -ceq 'windows') { return 'pwsh.exe' }
    return 'pwsh'
}

function Get-VerifiedPowerShellStableTagFromUri {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uri] $ResolvedReleaseUri)

    if (-not $ResolvedReleaseUri.IsAbsoluteUri -or $ResolvedReleaseUri.Scheme -cne 'https' -or
        $ResolvedReleaseUri.Host -cne 'github.com' -or -not $ResolvedReleaseUri.IsDefaultPort -or
        -not [string]::IsNullOrEmpty($ResolvedReleaseUri.UserInfo) -or
        -not [string]::IsNullOrEmpty($ResolvedReleaseUri.Query) -or
        -not [string]::IsNullOrEmpty($ResolvedReleaseUri.Fragment)) {
        throw 'Microsoft stable PowerShell channel did not resolve to a canonical GitHub release URL.'
    }

    $match = [regex]::Match(
        $ResolvedReleaseUri.AbsolutePath,
        '^/PowerShell/PowerShell/releases/tag/(?<tag>v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$'
    )
    if (-not $match.Success) {
        throw 'Microsoft stable PowerShell channel resolved to a malformed or non-release tag URL.'
    }
    return $match.Groups['tag'].Value
}

function Assert-PowerShellReleaseTagMatchesStableChannel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ExpectedTag,
        [Parameter(Mandatory)][object] $Release
    )

    if ($ExpectedTag -cnotmatch '^v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$') {
        throw 'Microsoft stable PowerShell channel tag is malformed.'
    }
    $releaseTag = [string](Get-ReleaseField -Object $Release -Name 'tag_name')
    if ($releaseTag -cne $ExpectedTag) {
        throw 'PowerShell release metadata tag does not match the Microsoft stable channel redirect.'
    }
    return $releaseTag
}

function Get-VerifiedPowerShellReleaseFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Assets,
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $ExpectedName,
        [Parameter(Mandatory)][string] $Description
    )

    $matchingAssets = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $Assets) {
        if ($null -eq $candidate) { throw 'PowerShell release contains a null asset.' }
        $nameProperty = Get-ReleaseField -Object $candidate -Name 'name'
        if ($nameProperty -is [string] -and $nameProperty -ceq $ExpectedName) {
            $matchingAssets.Add($candidate)
        }
    }
    if ($matchingAssets.Count -ne 1) {
        throw "PowerShell release must contain exactly one '$ExpectedName' $Description."
    }

    $asset = $matchingAssets[0]
    $assetIdValue = Get-ReleaseField -Object $asset -Name 'id'
    $assetSizeValue = Get-ReleaseField -Object $asset -Name 'size'
    if ($assetIdValue -isnot [byte] -and $assetIdValue -isnot [int16] -and
        $assetIdValue -isnot [int] -and $assetIdValue -isnot [long]) {
        throw "PowerShell release $Description id is malformed."
    }
    if ([long]$assetIdValue -le 0) { throw "PowerShell release $Description id is invalid." }
    if ($assetSizeValue -isnot [byte] -and $assetSizeValue -isnot [int16] -and
        $assetSizeValue -isnot [int] -and $assetSizeValue -isnot [long]) {
        throw "PowerShell release $Description size is malformed."
    }
    if ([long]$assetSizeValue -le 0) { throw "PowerShell release $Description size must be nonzero." }

    $assetName = [string](Get-ReleaseField -Object $asset -Name 'name')
    $state = [string](Get-ReleaseField -Object $asset -Name 'state')
    $digest = [string](Get-ReleaseField -Object $asset -Name 'digest')
    $downloadUrl = [string](Get-ReleaseField -Object $asset -Name 'browser_download_url')
    if ($assetName -cne $ExpectedName -or $state -cne 'uploaded') {
        throw "PowerShell release $Description identity or upload state is invalid."
    }
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw "PowerShell release $Description must publish a lowercase SHA-256 digest."
    }

    $expectedUrl = "https://github.com/PowerShell/PowerShell/releases/download/$Tag/$ExpectedName"
    if ($downloadUrl -cne $expectedUrl) { throw "PowerShell release $Description URL does not match its official tag and asset name." }
    return [pscustomobject][ordered]@{
        assetId = [long]$assetIdValue
        name = $assetName
        size = [long]$assetSizeValue
        digest = $digest
        browserDownloadUrl = $downloadUrl
    }
}

function Get-VerifiedPowerShellReleaseAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Release,
        [string] $Platform = (Get-PowerShellHostPlatform),
        [string] $Architecture = (Get-PowerShellHostArchitecture)
    )

    Assert-PowerShellReleaseTarget -Platform $Platform -Architecture $Architecture
    $draft = Get-ReleaseField -Object $Release -Name 'draft'
    $prerelease = Get-ReleaseField -Object $Release -Name 'prerelease'
    if ($draft -isnot [bool] -or $draft -or $prerelease -isnot [bool] -or $prerelease) {
        throw 'PowerShell release metadata is draft or prerelease.'
    }

    $tag = [string](Get-ReleaseField -Object $Release -Name 'tag_name')
    $tagMatch = [regex]::Match($tag, '^v(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$')
    if (-not $tagMatch.Success) { throw 'PowerShell release tag is not a stable vMAJOR.MINOR.PATCH version.' }
    $version = $tagMatch.Groups['version'].Value
    $expectedAssetName = Get-PowerShellReleaseAssetName -Version $version -Platform $Platform -Architecture $Architecture

    $assetsValue = Get-ReleaseField -Object $Release -Name 'assets'
    if ($assetsValue -is [string] -or $assetsValue -isnot [Collections.IEnumerable]) {
        throw 'PowerShell release assets are malformed.'
    }

    $archive = Get-VerifiedPowerShellReleaseFile -Assets $assetsValue -Tag $tag -ExpectedName $expectedAssetName -Description 'archive'
    $hashesManifest = Get-VerifiedPowerShellReleaseFile -Assets $assetsValue -Tag $tag `
        -ExpectedName $script:PowerShellHashesManifestName -Description 'hash manifest'
    return [pscustomobject][ordered]@{
        tag = $tag
        version = $version
        platform = $Platform
        architecture = $Architecture
        executableName = Get-PowerShellExecutableName -Platform $Platform
        assetId = $archive.assetId
        name = $archive.name
        size = $archive.size
        digest = $archive.digest
        browserDownloadUrl = $archive.browserDownloadUrl
        hashesManifest = $hashesManifest
    }
}

function Assert-PowerShellDownloadedRegularFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][object] $ExpectedSize,
        [Parameter(Mandatory)][string] $Description
    )

    if ($ExpectedSize -isnot [byte] -and $ExpectedSize -isnot [int16] -and
        $ExpectedSize -isnot [int] -and $ExpectedSize -isnot [long]) {
        throw "PowerShell $Description evidence has an invalid size."
    }
    if ([long]$ExpectedSize -le 0) { throw "PowerShell $Description evidence has an invalid size." }
    $binding = Open-PowerShellReleaseFile -Path $Path -Access Read
    try {
        [byte[]]$bytes = $binding.File.ReadAllBytes(1073741824)
        [void](Assert-PlatformFileIdentity -Lease $binding.File -Expected $binding.Identity -SingleLink -VerifyPath)
        if ([long]$bytes.Length -ne [long]$ExpectedSize) { throw "Downloaded PowerShell $Description size does not match release metadata." }
    }
    finally { Close-PowerShellReleaseFile -Binding $binding }
}

function Assert-VerifiedPowerShellArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Asset,
        [Parameter(Mandatory)][string] $Path
    )

    $expectedDigest = [string](Get-ReleaseField -Object $Asset -Name 'digest')
    if ($expectedDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'PowerShell archive evidence has an invalid SHA-256 digest.'
    }
    $expectedSize = Get-ReleaseField -Object $Asset -Name 'size'
    Assert-PowerShellDownloadedRegularFile -Path $Path -ExpectedSize $expectedSize -Description 'archive'

    $archiveBinding = Open-PowerShellReleaseFile -Path $Path -Access Read
    try {
        $actualDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archiveBinding.File.ReadAllBytes(1073741824))).ToLowerInvariant()
        [void](Assert-PlatformFileIdentity -Lease $archiveBinding.File -Expected $archiveBinding.Identity -SingleLink -VerifyPath)
    }
    finally { Close-PowerShellReleaseFile -Binding $archiveBinding }
    if (('sha256:' + $actualDigest) -cne $expectedDigest) {
        throw 'Downloaded PowerShell archive bytes do not match the published release digest.'
    }
    return $actualDigest
}

function Get-OfficialPowerShellManifestDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ArchiveName
    )

    $pattern = '^(?<hash>[0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($ArchiveName) + '\s*$'
    $manifestBinding = Open-PowerShellReleaseFile -Path $Path -Access Read
    try { $manifestLines = [Text.UTF8Encoding]::new($false, $true).GetString($manifestBinding.File.ReadAllBytes(16777216)) -split '\r?\n' }
    finally { Close-PowerShellReleaseFile -Binding $manifestBinding }
    $digests = @(foreach ($line in $manifestLines) {
        $lineMatch = [regex]::Match($line, $pattern)
        if ($lineMatch.Success) { $lineMatch.Groups['hash'].Value.ToLowerInvariant() }
    })
    if ($digests.Count -ne 1) { throw "Official PowerShell hash manifest must contain exactly one '$ArchiveName' digest." }
    return [string]$digests[0]
}

function Assert-VerifiedPowerShellHashesManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Asset,
        [Parameter(Mandatory)][string] $Path
    )

    $archiveName = [string](Get-ReleaseField -Object $Asset -Name 'name')
    $archiveDigest = [string](Get-ReleaseField -Object $Asset -Name 'digest')
    if ($archiveDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'PowerShell archive evidence has an invalid SHA-256 digest.'
    }
    $manifest = Get-ReleaseField -Object $Asset -Name 'hashesManifest'
    if ($null -eq $manifest) { throw 'PowerShell archive evidence does not bind the official hash manifest.' }
    $manifestName = [string](Get-ReleaseField -Object $manifest -Name 'name')
    $manifestDigest = [string](Get-ReleaseField -Object $manifest -Name 'digest')
    if ($manifestName -cne $script:PowerShellHashesManifestName -or $manifestDigest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'PowerShell hash manifest evidence is invalid.'
    }
    Assert-PowerShellDownloadedRegularFile -Path $Path -ExpectedSize (Get-ReleaseField -Object $manifest -Name 'size') -Description 'hash manifest'

    $manifestBinding = Open-PowerShellReleaseFile -Path $Path -Access Read
    try {
        $actualManifestDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($manifestBinding.File.ReadAllBytes(16777216))).ToLowerInvariant()
        [void](Assert-PlatformFileIdentity -Lease $manifestBinding.File -Expected $manifestBinding.Identity -SingleLink -VerifyPath)
    }
    finally { Close-PowerShellReleaseFile -Binding $manifestBinding }
    if (('sha256:' + $actualManifestDigest) -cne $manifestDigest) {
        throw 'Downloaded PowerShell hash manifest bytes do not match the published release digest.'
    }
    if (('sha256:' + (Get-OfficialPowerShellManifestDigest -Path $Path -ArchiveName $archiveName)) -cne $archiveDigest) {
        throw 'PowerShell archive API digest differs from the official hash manifest.'
    }
    return $actualManifestDigest
}

function Assert-SafePowerShellTarArchiveListing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Members,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $DetailedMembers
    )

    if ($Members.Count -eq 0 -or $DetailedMembers.Count -ne $Members.Count) {
        throw 'PowerShell tar archive listings are empty or inconsistent.'
    }
    for ($index = 0; $index -lt $Members.Count; $index++) {
        $memberName = [string]$Members[$index]
        $detail = [string]$DetailedMembers[$index]
        if ([string]::IsNullOrEmpty($memberName) -or $memberName.StartsWith('/', [StringComparison]::Ordinal) -or
            $memberName.StartsWith('\', [StringComparison]::Ordinal) -or $memberName -cmatch '^[A-Za-z]:' -or
            $memberName -cmatch '(^|/)\.\.(/|$)') {
            throw "PowerShell tar archive member '$memberName' escapes the run-owned runtime directory."
        }
        if ([string]::IsNullOrEmpty($detail) -or $detail[0] -cnotin @('-', 'd')) {
            throw "PowerShell tar archive member '$memberName' is a link or unsupported special entry."
        }
    }
}

function Expand-VerifiedPowerShellArchive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Asset,
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    $platform = [string](Get-ReleaseField -Object $Asset -Name 'platform')
    $hostPlatform = Get-PowerShellHostPlatform
    if ($platform -cne $hostPlatform) {
        throw "PowerShell archive for '$platform' cannot be installed on a '$hostPlatform' host."
    }
    $executableName = Get-PowerShellExecutableName -Platform $platform
    $destinationFullPath = [IO.Path]::GetFullPath($DestinationPath)
    $destinationParentPath = [IO.Path]::GetDirectoryName($destinationFullPath)
    $destinationLeaf = [IO.Path]::GetFileName($destinationFullPath)
    $destinationParentLease = Open-PlatformDirectory -Root $destinationParentPath -RootOnly
    $destinationState = Get-PlatformDirectoryState -ParentLease $destinationParentLease -Leaf $destinationLeaf
    if ($destinationState.exists) { $destinationParentLease.Dispose(); throw 'Run-owned PowerShell runtime extraction path already exists.' }
    $destinationLease = Open-PlatformDirectory -Root $destinationParentPath -RelativePath $destinationLeaf -CreatePrivate

    if ($platform -ceq 'windows') {
        $archiveBinding = Open-PowerShellReleaseFile -Path $ArchivePath -Access Read
        $archiveStream = $null
        $zip = $null
        try {
            $assetSize = [long](Get-ReleaseField -Object $Asset -Name 'size')
            if ($assetSize -le 0 -or $assetSize -ge [int]::MaxValue) { throw 'PowerShell archive size is outside the in-memory extraction bound.' }
            $archiveBytes = $archiveBinding.File.ReadAllBytes([int]($assetSize + 1))
            if ($archiveBytes.Length -ne $assetSize) { throw 'PowerShell archive bytes changed before extraction.' }
            $archiveStream = [IO.MemoryStream]::new($archiveBytes, $false)
            $zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $false)
            foreach ($entry in $zip.Entries) {
                $relative = ([string]$entry.FullName).Replace('\', '/')
                if ([string]::IsNullOrWhiteSpace($relative) -or [IO.Path]::IsPathRooted($relative) -or
                    $relative -cmatch '(^|/)\.\.(/|$)' -or $relative.Contains(':')) {
                    throw "PowerShell zip archive member '$relative' is unsafe."
                }
                $externalAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
                if ((($externalAttributes -shr 16) -band [uint32]0xF000) -eq 0xA000) {
                    throw "PowerShell zip archive member '$relative' is a symbolic link."
                }
                $trimmed = $relative.TrimEnd('/')
                $relativeParent = [IO.Path]::GetDirectoryName($trimmed.Replace('/', [IO.Path]::DirectorySeparatorChar))
                if ($relative.EndsWith('/')) {
                    $directoryLease = Open-PowerShellReleaseRelativeDirectory -RootLease $destinationLease -RootPath $destinationFullPath -RelativePath $trimmed
                    $directoryLease.Dispose()
                    continue
                }
                $outputParent = if ([string]::IsNullOrWhiteSpace($relativeParent)) { $destinationLease }
                    else { Open-PowerShellReleaseRelativeDirectory -RootLease $destinationLease -RootPath $destinationFullPath -RelativePath $relativeParent }
                $input = $entry.Open()
                $output = $null
                try {
                    if ([long]$entry.Length -lt 0 -or [long]$entry.Length -gt 268435456) { throw "PowerShell zip member '$relative' exceeds the extraction bound." }
                    $buffer = [IO.MemoryStream]::new()
                    try { $input.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $buffer.Dispose() }
                    if ($bytes.Length -ne [long]$entry.Length) { throw "PowerShell zip member '$relative' changed during extraction." }
                    $output = Open-PlatformFile -ParentLease $outputParent -Leaf ([IO.Path]::GetFileName($trimmed)) -Access ReadWrite -CreateMode CreateNew
                    $output.WriteNewBytes($bytes)
                    [void](Assert-PlatformFileIdentity -Lease $output -Expected $output.Observation -SingleLink -VerifyPath)
                }
                finally {
                    if ($null -ne $output) { $output.Dispose() }
                    $input.Dispose()
                    if ($outputParent -ne $destinationLease) { $outputParent.Dispose() }
                }
            }
            [void](Assert-PlatformFileIdentity -Lease $archiveBinding.File -Expected $archiveBinding.Identity -SingleLink -VerifyPath)
        }
        finally {
            if ($null -ne $zip) { $zip.Dispose() }
            if ($null -ne $archiveStream) { $archiveStream.Dispose() }
            Close-PowerShellReleaseFile -Binding $archiveBinding
        }
    }
    else {
        $tarPath = (Get-Command -Name 'tar' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $tarBinding = Open-PowerShellReleaseFile -Path $tarPath -Access Read
        [void](Assert-PlatformFileIdentity -Lease $tarBinding.File -Expected $tarBinding.Identity -SingleLink -VerifyPath)
        $members = @(& $tarPath -tzf $ArchivePath)
        if ($LASTEXITCODE -ne 0 -or $members.Count -eq 0) { throw 'PowerShell tar archive listing failed.' }
        [void](Assert-PlatformFileIdentity -Lease $tarBinding.File -Expected $tarBinding.Identity -SingleLink -VerifyPath)
        $detailedMembers = @(& $tarPath -tvzf $ArchivePath)
        if ($LASTEXITCODE -ne 0) { throw 'PowerShell tar archive detailed listing failed.' }
        Assert-SafePowerShellTarArchiveListing -Members $members -DetailedMembers $detailedMembers
        # Extract without -p so ownership is not restored, while the archive's
        # file modes, including the executable bit, are retained under umask.
        & $tarPath -xzf $ArchivePath -C $destinationFullPath
        if ($LASTEXITCODE -ne 0) { throw 'PowerShell tar archive extraction failed.' }
        [void](Assert-PlatformFileIdentity -Lease $tarBinding.File -Expected $tarBinding.Identity -SingleLink -VerifyPath)
        Close-PowerShellReleaseFile -Binding $tarBinding
        [void](Get-PlatformDirectoryState -ParentLease $destinationParentLease -Leaf $destinationLeaf)
    }

    $executablePath = Join-Path $destinationFullPath $executableName
    try { $executableLease = Open-PlatformFile -ParentLease $destinationLease -Leaf $executableName -Access ReadWrite -CreateMode OpenExisting }
    catch {
        $destinationLease.Dispose()
        $destinationParentLease.Dispose()
        throw "PowerShell archive did not contain $executableName at its root."
    }
    $executableIdentity = Assert-PlatformFileIdentity -Lease $executableLease -Expected $executableLease.Observation -SingleLink -VerifyPath
    if ($platform -cne 'windows') {
        $permissions = Get-PlatformPermissions -Lease $executableLease
        $modeValue = [Convert]::ToInt32([string]$permissions.mode, 8)
        if (($modeValue -band 64) -eq 0) { [void](Set-PlatformPermissions -Lease $executableLease -Policy @{ Mode = ($modeValue -bor 73) }) }
        $permissions = Get-PlatformPermissions -Lease $executableLease
        if (([Convert]::ToInt32([string]$permissions.mode, 8) -band 64) -eq 0) {
            throw 'Downloaded PowerShell executable is not executable by its owner.'
        }
    }
    [void](Assert-PlatformFileIdentity -Lease $executableLease -Expected $executableIdentity -SingleLink -VerifyPath)
    $executableLease.Dispose()
    $destinationLease.Dispose()
    $destinationParentLease.Dispose()
    return [IO.Path]::GetFullPath($executablePath)
}

function Assert-PowerShellExecutableSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Platform = (Get-PowerShellHostPlatform)
    )

    if ($Platform -cnotin $script:PowerShellReleasePlatforms) {
        throw "PowerShell release platform '$Platform' is not one of windows, linux, or macos."
    }
    if ($Platform -cne 'windows') {
        # Official Linux and macOS archives carry no Authenticode signature; the
        # archive is bound by the release API digest and hashes.sha256 instead.
        return [pscustomobject][ordered]@{ status = $null; signerSubject = $null; signerThumbprint = $null }
    }
    if (-not [OperatingSystem]::IsWindows()) {
        throw 'Windows PowerShell executables can only be Authenticode-verified on a Windows host.'
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or $null -eq $signature.SignerCertificate -or
        [string]$signature.SignerCertificate.Subject -cnotmatch '^CN=Microsoft Corporation(,|$)') {
        throw 'PowerShell executable Authenticode signature is not valid and Microsoft-signed.'
    }
    return [pscustomobject][ordered]@{
        status = [string]$signature.Status
        signerSubject = [string]$signature.SignerCertificate.Subject
        signerThumbprint = [string]$signature.SignerCertificate.Thumbprint
    }
}

function Assert-PowerShellRuntimeVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $ActualVersion
    )

    $tagMatch = [regex]::Match($Tag, '^v(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$')
    if (-not $tagMatch.Success) { throw 'Verified PowerShell runtime tag is malformed.' }
    if ($ActualVersion -cnotmatch '^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$' -or
        $ActualVersion -cne $tagMatch.Groups['version'].Value) {
        throw 'Installed PowerShell executable version does not equal the verified release tag.'
    }
    return $ActualVersion
}

Export-ModuleMember -Function @(
    'Get-PowerShellHostPlatform'
    'Get-PowerShellHostArchitecture'
    'Get-PowerShellReleaseAssetName'
    'Get-PowerShellExecutableName'
    'Get-VerifiedPowerShellStableTagFromUri'
    'Assert-PowerShellReleaseTagMatchesStableChannel'
    'Get-VerifiedPowerShellReleaseAsset'
    'Assert-VerifiedPowerShellArchive'
    'Get-OfficialPowerShellManifestDigest'
    'Assert-VerifiedPowerShellHashesManifest'
    'Assert-SafePowerShellTarArchiveListing'
    'Expand-VerifiedPowerShellArchive'
    'Assert-PowerShellExecutableSignature'
    'Assert-PowerShellRuntimeVersion'
)
