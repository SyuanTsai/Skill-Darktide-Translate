# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

$script:PowerShellReleasePlatforms = @('windows', 'linux', 'macos')
$script:PowerShellReleaseArchitectures = @('x64', 'arm64')
$script:PowerShellHashesManifestName = 'hashes.sha256'

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
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Downloaded PowerShell $Description is missing." }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrEmpty([string]$item.LinkType)) {
        throw "Downloaded PowerShell $Description is not a regular file."
    }
    if ([long]$item.Length -ne [long]$ExpectedSize) { throw "Downloaded PowerShell $Description size does not match release metadata." }
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

    $actualDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLowerInvariant()
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
    $digests = @(foreach ($line in [IO.File]::ReadAllLines($Path, [Text.UTF8Encoding]::new($false, $true))) {
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

    $actualManifestDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLowerInvariant()
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
    if (Test-Path -LiteralPath $destinationFullPath) { throw 'Run-owned PowerShell runtime extraction path already exists.' }

    if ($platform -ceq 'windows') {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $destinationFullPath -ErrorAction Stop
    }
    else {
        $tarPath = (Get-Command -Name 'tar' -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $members = @(& $tarPath -tzf $ArchivePath)
        if ($LASTEXITCODE -ne 0 -or $members.Count -eq 0) { throw 'PowerShell tar archive listing failed.' }
        $detailedMembers = @(& $tarPath -tvzf $ArchivePath)
        if ($LASTEXITCODE -ne 0) { throw 'PowerShell tar archive detailed listing failed.' }
        Assert-SafePowerShellTarArchiveListing -Members $members -DetailedMembers $detailedMembers
        [void](New-Item -ItemType Directory -Path $destinationFullPath -ErrorAction Stop)
        # Extract without -p so ownership is not restored, while the archive's
        # file modes, including the executable bit, are retained under umask.
        & $tarPath -xzf $ArchivePath -C $destinationFullPath
        if ($LASTEXITCODE -ne 0) { throw 'PowerShell tar archive extraction failed.' }
        foreach ($item in @(Get-ChildItem -LiteralPath $destinationFullPath -Recurse -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                -not [string]::IsNullOrEmpty([string]$item.LinkType)) {
                throw "PowerShell tar extraction produced an unsafe link: $($item.FullName)"
            }
        }
    }

    $executablePath = Join-Path $destinationFullPath $executableName
    if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
        throw "Verified PowerShell archive did not contain $executableName at its root."
    }
    $executable = Get-Item -LiteralPath $executablePath -Force -ErrorAction Stop
    if ($executable.PSIsContainer -or ($executable.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrEmpty([string]$executable.LinkType)) {
        throw 'Downloaded PowerShell executable is not a regular file.'
    }
    if ($platform -cne 'windows') {
        $mode = [IO.File]::GetUnixFileMode($executablePath)
        if (($mode -band [IO.UnixFileMode]::UserExecute) -eq 0) {
            $executeBits = [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherExecute
            [IO.File]::SetUnixFileMode($executablePath, ($mode -bor $executeBits))
        }
        if (([IO.File]::GetUnixFileMode($executablePath) -band [IO.UnixFileMode]::UserExecute) -eq 0) {
            throw 'Downloaded PowerShell executable is not executable by its owner.'
        }
    }
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
