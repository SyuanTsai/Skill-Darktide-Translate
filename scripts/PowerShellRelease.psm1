# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest

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

function Get-VerifiedPowerShellReleaseAsset {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Release)

    $draft = Get-ReleaseField -Object $Release -Name 'draft'
    $prerelease = Get-ReleaseField -Object $Release -Name 'prerelease'
    if ($draft -isnot [bool] -or $draft -or $prerelease -isnot [bool] -or $prerelease) {
        throw 'PowerShell release metadata is draft or prerelease.'
    }

    $tag = [string](Get-ReleaseField -Object $Release -Name 'tag_name')
    $tagMatch = [regex]::Match($tag, '^v(?<version>(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*))$')
    if (-not $tagMatch.Success) { throw 'PowerShell release tag is not a stable vMAJOR.MINOR.PATCH version.' }
    $version = $tagMatch.Groups['version'].Value
    $expectedAssetName = "PowerShell-$version-win-x64.zip"

    $assetsValue = Get-ReleaseField -Object $Release -Name 'assets'
    if ($assetsValue -is [string] -or $assetsValue -isnot [Collections.IEnumerable]) {
        throw 'PowerShell release assets are malformed.'
    }

    $matchingAssets = [Collections.Generic.List[object]]::new()
    foreach ($candidate in $assetsValue) {
        if ($null -eq $candidate) { throw 'PowerShell release contains a null asset.' }
        $nameProperty = if ($candidate -is [Collections.IDictionary]) {
            if ($candidate.Contains('name')) { [string]$candidate['name'] } else { $null }
        }
        else {
            $candidate.PSObject.Properties['name'].Value
        }
        if ($nameProperty -is [string] -and $nameProperty -ceq $expectedAssetName) {
            $matchingAssets.Add($candidate)
        }
    }
    if ($matchingAssets.Count -ne 1) {
        throw "PowerShell release must contain exactly one '$expectedAssetName' archive."
    }

    $asset = $matchingAssets[0]
    $assetIdValue = Get-ReleaseField -Object $asset -Name 'id'
    $assetSizeValue = Get-ReleaseField -Object $asset -Name 'size'
    if ($assetIdValue -isnot [byte] -and $assetIdValue -isnot [int16] -and
        $assetIdValue -isnot [int] -and $assetIdValue -isnot [long]) {
        throw 'PowerShell release asset id is malformed.'
    }
    if ([long]$assetIdValue -le 0) { throw 'PowerShell release asset id is invalid.' }
    if ($assetSizeValue -isnot [byte] -and $assetSizeValue -isnot [int16] -and
        $assetSizeValue -isnot [int] -and $assetSizeValue -isnot [long]) {
        throw 'PowerShell release asset size is malformed.'
    }
    if ([long]$assetSizeValue -le 0) { throw 'PowerShell release asset size must be nonzero.' }

    $assetName = [string](Get-ReleaseField -Object $asset -Name 'name')
    $state = [string](Get-ReleaseField -Object $asset -Name 'state')
    $digest = [string](Get-ReleaseField -Object $asset -Name 'digest')
    $downloadUrl = [string](Get-ReleaseField -Object $asset -Name 'browser_download_url')
    if ($assetName -cne $expectedAssetName -or $state -cne 'uploaded') {
        throw 'PowerShell release asset identity or upload state is invalid.'
    }
    if ($digest -cnotmatch '^sha256:[0-9a-f]{64}$') {
        throw 'PowerShell release asset must publish a lowercase SHA-256 digest.'
    }

    $expectedUrl = "https://github.com/PowerShell/PowerShell/releases/download/$tag/$expectedAssetName"
    if ($downloadUrl -cne $expectedUrl) { throw 'PowerShell release asset URL does not match its official tag and asset name.' }
    return [pscustomobject][ordered]@{
        tag = $tag
        version = $version
        assetId = [long]$assetIdValue
        name = $assetName
        size = [long]$assetSizeValue
        digest = $digest
        browserDownloadUrl = $downloadUrl
    }
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
    if ($expectedSize -isnot [byte] -and $expectedSize -isnot [int16] -and
        $expectedSize -isnot [int] -and $expectedSize -isnot [long]) {
        throw 'PowerShell archive evidence has an invalid size.'
    }
    if ([long]$expectedSize -le 0) { throw 'PowerShell archive evidence has an invalid size.' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Downloaded PowerShell archive is missing.' }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Downloaded PowerShell archive is not a regular file.'
    }
    if ([long]$item.Length -ne [long]$expectedSize) { throw 'Downloaded PowerShell archive size does not match release metadata.' }

    $actualDigest = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path -ErrorAction Stop).Hash.ToLowerInvariant()
    if (('sha256:' + $actualDigest) -cne $expectedDigest) {
        throw 'Downloaded PowerShell archive bytes do not match the published release digest.'
    }
    return $actualDigest
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
    'Get-VerifiedPowerShellStableTagFromUri'
    'Assert-PowerShellReleaseTagMatchesStableChannel'
    'Get-VerifiedPowerShellReleaseAsset'
    'Assert-VerifiedPowerShellArchive'
    'Assert-PowerShellRuntimeVersion'
)
