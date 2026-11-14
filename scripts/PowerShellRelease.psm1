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

function Test-PowerShellReleaseCleanupReceipt {
    param($Receipt)

    if ($null -eq $Receipt) { return $false }
    foreach ($name in @('CleanedUp', 'CaptureReadersStopped', 'CaptureResourcesClosed')) {
        $property = $Receipt.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [bool] -or -not $property.Value) { return $false }
    }
    $remainingProperty = $Receipt.PSObject.Properties['RemainingPids']
    $uncertaintyProperty = $Receipt.PSObject.Properties['Uncertainty']
    if ($null -eq $remainingProperty -or $remainingProperty.Value -isnot [array] -or
        @($remainingProperty.Value).Count -ne 0) {
        return $false
    }
    return ($null -eq $uncertaintyProperty -or $null -eq $uncertaintyProperty.Value -or
        ($uncertaintyProperty.Value -is [string] -and $uncertaintyProperty.Value.Length -eq 0))
}

function Get-PowerShellReleaseProcessEnvironment {
    $environment = [ordered]@{}
    foreach ($name in @(
        'SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'PATH', 'PATHEXT', 'HOME', 'USERPROFILE',
        'LANG', 'LC_ALL', 'TZ', 'DOTNET_ROOT', 'DOTNET_ROOT_X64', 'LD_LIBRARY_PATH', 'DYLD_LIBRARY_PATH'
    )) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ($null -ne $value) { $environment[$name] = $value }
    }
    return $environment
}

function Read-PowerShellReleaseProcessCapture {
    param(
        [Parameter(Mandatory)] $DirectoryLease,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][int] $Limit
    )

    $capture = Open-PlatformFile -ParentLease $DirectoryLease -Leaf $Leaf -Access Read -CreateMode OpenExisting
    try {
        $identity = Assert-PlatformFileIdentity -Lease $capture -Expected $capture.Observation -SingleLink -VerifyPath
        [byte[]]$bytes = $capture.ReadAllBytes($Limit)
        [void](Assert-PlatformFileIdentity -Lease $capture -Expected $identity -SingleLink -VerifyPath)
        return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    finally { $capture.Dispose() }
}

function Invoke-PowerShellReleaseOwnedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ExecutableLease,
        [Parameter(Mandatory)][string] $ExecutablePath,
        [Parameter(Mandatory)] $WorkingDirectoryLease,
        [Parameter(Mandatory)][string] $WorkingDirectoryPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ArgumentList,
        [Collections.IDictionary] $Environment,
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 30,
        [ValidateRange(1, 1048576)][int] $OutputLimitCharacters = 1048576
    )

    $workingFullPath = [IO.Path]::GetFullPath($WorkingDirectoryPath)
    $requestedExecutablePath = [IO.Path]::GetFullPath($ExecutablePath)
    $captureLeaf = '.owned-process-' + [guid]::NewGuid().ToString('N')
    $capturePath = Join-Path $workingFullPath $captureLeaf
    $captureDirectory = $null
    $processLease = $null
    $cleanupReceipt = $null
    $cleanupFailure = $null
    $stdout = ''
    $stderr = ''
    $exitCode = $null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    try {
        $executableIdentity = Assert-PlatformFileIdentity -Lease $ExecutableLease `
            -Expected $ExecutableLease.Observation -SingleLink -VerifyPath
        $captureDirectory = Open-PlatformDirectory -Root $workingFullPath -RelativePath $captureLeaf -CreatePrivate
        $stdoutPath = Join-Path $capturePath 'stdout.txt'
        $stderrPath = Join-Path $capturePath 'stderr.txt'
        $childEnvironment = if ($null -eq $Environment) {
            Get-PowerShellReleaseProcessEnvironment
        }
        else { $Environment }

        $processLease = Start-PlatformOwnedProcess -ExecutableLease $ExecutableLease `
            -ArgumentZero $requestedExecutablePath -ArgumentList $ArgumentList -Environment $childEnvironment `
            -WorkingDirectoryLease $WorkingDirectoryLease -Deadline $deadline -StdoutPath $stdoutPath `
            -StderrPath $stderrPath -OutputLimitCharacters $OutputLimitCharacters
        while (-not $processLease.HasExited -and $null -eq $processLease.Cleanup -and
            [DateTimeOffset]::UtcNow -lt $deadline.AddSeconds(5)) {
            [void]$processLease.WaitForExit([TimeSpan]::FromMilliseconds(50))
        }
    }
    finally {
        if ($null -ne $processLease) {
            try {
                $cleanupReceipt = Stop-PlatformOwnedProcess -Lease $processLease `
                    -ExpectedStartIdentity $processLease.StartIdentity -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(5))
                if ($null -ne $processLease.ExitCode) { $exitCode = [int]$processLease.ExitCode }
            }
            catch { $cleanupFailure = $_ }
            finally {
                try { $processLease.Dispose() }
                catch {
                    if ($null -eq $cleanupFailure) { $cleanupFailure = $_ }
                }
            }
        }
        if ($null -ne $captureDirectory) {
            try {
                $stdout = Read-PowerShellReleaseProcessCapture -DirectoryLease $captureDirectory -Leaf 'stdout.txt' -Limit $OutputLimitCharacters
                $stderr = Read-PowerShellReleaseProcessCapture -DirectoryLease $captureDirectory -Leaf 'stderr.txt' -Limit $OutputLimitCharacters
            }
            catch {
                if ($null -eq $cleanupFailure) { $cleanupFailure = $_ }
            }
            finally { $captureDirectory.Dispose() }
        }
    }

    [void](Assert-PlatformFileIdentity -Lease $ExecutableLease -Expected $executableIdentity -SingleLink -VerifyPath)
    if ($null -ne $cleanupFailure) {
        throw [IO.IOException]::new('Owned PowerShell process cleanup or capture verification failed.', $cleanupFailure.Exception)
    }
    if (-not (Test-PowerShellReleaseCleanupReceipt -Receipt $cleanupReceipt)) {
        throw 'Owned PowerShell process cleanup was incomplete or uncertain.'
    }
    if ($null -eq $exitCode) {
        $timeoutFailure = [TimeoutException]::new(
            "Owned PowerShell process exceeded its $TimeoutSeconds second deadline without a verified exit code."
        )
        $timeoutFailure.Data['CapturePath'] = $capturePath
        $timeoutFailure.Data['Stdout'] = $stdout
        $timeoutFailure.Data['Stderr'] = $stderr
        $timeoutFailure.Data['CleanupReceipt'] = $cleanupReceipt
        throw $timeoutFailure
    }
    return [pscustomobject][ordered]@{
        exitCode = $exitCode
        stdout = $stdout
        stderr = $stderr
        cleanup = $cleanupReceipt
        capturePath = $capturePath
    }
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
    try {
        [byte[]]$manifestBytes = $manifestBinding.File.ReadAllBytes(16777216)
        [void](Assert-PlatformFileIdentity -Lease $manifestBinding.File -Expected $manifestBinding.Identity -SingleLink -VerifyPath)
        if ($manifestBytes.Length -ge 2 -and $manifestBytes[0] -eq 0xFF -and $manifestBytes[1] -eq 0xFE) {
            $manifestText = [Text.UnicodeEncoding]::new($false, $true, $true).GetString(
                $manifestBytes, 2, $manifestBytes.Length - 2)
        }
        elseif ($manifestBytes.Length -ge 3 -and $manifestBytes[0] -eq 0xEF -and
            $manifestBytes[1] -eq 0xBB -and $manifestBytes[2] -eq 0xBF) {
            $manifestText = [Text.UTF8Encoding]::new($false, $true).GetString(
                $manifestBytes, 3, $manifestBytes.Length - 3)
        }
        else {
            $manifestText = [Text.UTF8Encoding]::new($false, $true).GetString($manifestBytes)
        }
        $manifestLines = $manifestText -split '\r?\n'
    }
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

function Get-SafePowerShellArchiveRelativePath {
    param([Parameter(Mandatory)][string] $Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('\') -or $Name.Contains(':') -or
        $Name.StartsWith('/', [StringComparison]::Ordinal) -or $Name -cmatch '^[A-Za-z]:' -or
        $Name.IndexOf([char]0) -ge 0) {
        throw "PowerShell archive member '$Name' escapes the run-owned runtime directory."
    }
    $relative = $Name.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($relative)) {
        throw "PowerShell archive member '$Name' has an empty path."
    }
    foreach ($segment in $relative.Split('/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -in @('.', '..')) {
            throw "PowerShell archive member '$Name' escapes the run-owned runtime directory."
        }
    }
    if ($relative -ceq '.powershell-runtime-unusable.json') {
        throw "PowerShell archive member '$Name' uses the reserved failure marker name."
    }
    return $relative
}

function Assert-PowerShellArchivePlan {
    param([Parameter(Mandatory)][object[]] $Plan)

    if ($Plan.Count -eq 0) { throw 'PowerShell archive contains no members.' }
    $kinds = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Plan) {
        if ($kinds.ContainsKey([string]$item.Path)) {
            throw "PowerShell archive contains duplicate member '$($item.Path)'."
        }
        $kinds.Add([string]$item.Path, [string]$item.Kind)
    }
    foreach ($item in $Plan) {
        $parts = ([string]$item.Path).Split('/')
        for ($index = 1; $index -lt $parts.Length; $index++) {
            $ancestor = [string]::Join('/', $parts[0..($index - 1)])
            if ($kinds.ContainsKey($ancestor) -and $kinds[$ancestor] -cne 'directory') {
                throw "PowerShell archive member '$($item.Path)' descends from file '$ancestor'."
            }
        }
    }
}

function Get-PowerShellTarArchivePlan {
    param([Parameter(Mandatory)][byte[]] $ArchiveBytes)

    Add-Type -AssemblyName System.Formats.Tar -ErrorAction Stop
    $plan = [Collections.Generic.List[object]]::new()
    $memory = [IO.MemoryStream]::new($ArchiveBytes, $false)
    $gzip = $null
    $reader = $null
    try {
        $gzip = [IO.Compression.GZipStream]::new($memory, [IO.Compression.CompressionMode]::Decompress, $true)
        $reader = [Formats.Tar.TarReader]::new($gzip, $true)
        while ($null -ne ($entry = $reader.GetNextEntry($false))) {
            $relative = Get-SafePowerShellArchiveRelativePath -Name ([string]$entry.Name)
            $kind = switch ($entry.EntryType) {
                ([Formats.Tar.TarEntryType]::Directory) { 'directory'; break }
                ([Formats.Tar.TarEntryType]::RegularFile) { 'file'; break }
                ([Formats.Tar.TarEntryType]::V7RegularFile) { 'file'; break }
                default { throw "PowerShell tar archive member '$relative' is a link or unsupported special entry." }
            }
            if ($kind -ceq 'file' -and ([long]$entry.Length -lt 0 -or [long]$entry.Length -gt 268435456)) {
                throw "PowerShell tar member '$relative' exceeds the extraction bound."
            }
            $plan.Add([pscustomobject]@{
                Path = $relative
                Kind = $kind
                Length = [long]$entry.Length
                Mode = [int]$entry.Mode
            })
        }
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $gzip) { $gzip.Dispose() }
        $memory.Dispose()
    }
    Assert-PowerShellArchivePlan -Plan $plan.ToArray()
    return ,$plan.ToArray()
}

function Get-PowerShellZipArchivePlan {
    param([Parameter(Mandatory)] $Zip)

    $plan = [Collections.Generic.List[object]]::new()
    foreach ($entry in $Zip.Entries) {
        $name = [string]$entry.FullName
        $relative = Get-SafePowerShellArchiveRelativePath -Name $name
        $externalAttributes = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$entry.ExternalAttributes), 0)
        if ((($externalAttributes -shr 16) -band [uint32]0xF000) -eq 0xA000) {
            throw "PowerShell zip archive member '$relative' is a symbolic link."
        }
        $kind = if ($name.EndsWith('/', [StringComparison]::Ordinal) -or [string]::IsNullOrEmpty([string]$entry.Name)) {
            'directory'
        }
        else { 'file' }
        if ($kind -ceq 'file' -and ([long]$entry.Length -lt 0 -or [long]$entry.Length -gt 268435456)) {
            throw "PowerShell zip member '$relative' exceeds the extraction bound."
        }
        $plan.Add([pscustomobject]@{ Path = $relative; Kind = $kind; Length = [long]$entry.Length; Mode = $null })
    }
    Assert-PowerShellArchivePlan -Plan $plan.ToArray()
    return ,$plan.ToArray()
}

function New-PowerShellArchiveDirectoryLeases {
    param(
        [Parameter(Mandatory)][object[]] $Plan,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $Plan) {
        $relative = [string]$item.Path
        if ([string]$item.Kind -ceq 'directory') { [void]$directories.Add($relative) }
        $parts = $relative.Split('/')
        for ($index = 1; $index -lt $parts.Length; $index++) {
            [void]$directories.Add([string]::Join('/', $parts[0..($index - 1)]))
        }
    }

    [string[]]$ordered = @($directories)
    [Array]::Sort($ordered, [StringComparer]::Ordinal)
    $leases = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    try {
        $maximumDepth = if ($ordered.Count -eq 0) { 0 } else { ($ordered | ForEach-Object { $_.Split('/').Length } | Measure-Object -Maximum).Maximum }
        for ($depth = 1; $depth -le $maximumDepth; $depth++) {
            foreach ($relative in $ordered) {
                $parts = $relative.Split('/')
                if ($parts.Length -ne $depth) { continue }
                $lease = Open-PlatformDirectory -Root $DestinationPath `
                    -RelativePath $relative.Replace('/', [IO.Path]::DirectorySeparatorChar) -CreatePrivate
                $leases.Add($relative, $lease)
            }
        }
        return ,$leases
    }
    catch {
        foreach ($lease in $leases.Values) { $lease.Dispose() }
        throw
    }
}

function Close-PowerShellArchiveDirectoryLeases {
    param($Leases)
    if ($null -eq $Leases) { return }
    foreach ($lease in $Leases.Values) { $lease.Dispose() }
}

function Get-PowerShellArchiveParentLease {
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)] $RootLease,
        [Parameter(Mandatory)] $DirectoryLeases
    )
    $separator = $RelativePath.LastIndexOf('/')
    if ($separator -lt 0) { return $RootLease }
    return $DirectoryLeases[$RelativePath.Substring(0, $separator)]
}

function Write-PowerShellArchiveFailureMarker {
    param([Parameter(Mandatory)] $DestinationLease)

    $marker = Open-PlatformFile -ParentLease $DestinationLease -Leaf '.powershell-runtime-unusable.json' -Access ReadWrite -CreateMode CreateNew
    try {
        $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes(
            '{"schemaVersion":1,"status":"unusable","retry":"use-a-new-destination"}' + "`n")
        $marker.WriteNewBytes($bytes)
        [void](Assert-PlatformFileIdentity -Lease $marker -Expected $marker.Observation -SingleLink -VerifyPath)
    }
    finally { $marker.Dispose() }
}

function Set-PowerShellRuntimeUnusable {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $DestinationPath)

    $destinationLease = Open-PlatformDirectory -Root ([IO.Path]::GetFullPath($DestinationPath)) -RootOnly
    try { Write-PowerShellArchiveFailureMarker -DestinationLease $destinationLease }
    finally { $destinationLease.Dispose() }
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
    $destinationLease = $null
    try {
        [void](New-PlatformPrivateRoot -Parent $destinationParentPath -Leaf $destinationLeaf)
        $destinationLease = Open-PlatformDirectory -Root $destinationParentPath -RelativePath $destinationLeaf
    }
    catch {
        $destinationParentLease.Dispose()
        throw 'Run-owned PowerShell runtime extraction path already exists or is unsafe.'
    }

    $archiveBinding = $null
    $archiveStream = $null
    $zip = $null
    $directoryLeases = $null
    $executableLease = $null
    try {
        $archiveBinding = Open-PowerShellReleaseFile -Path $ArchivePath -Access Read
        $assetSize = [long](Get-ReleaseField -Object $Asset -Name 'size')
        if ($assetSize -le 0 -or $assetSize -ge [int]::MaxValue) { throw 'PowerShell archive size is outside the in-memory extraction bound.' }
        [byte[]]$archiveBytes = $archiveBinding.File.ReadAllBytes([int]($assetSize + 1))
        if ($archiveBytes.Length -ne $assetSize) { throw 'PowerShell archive bytes changed before extraction.' }
        $expectedDigest = [string](Get-ReleaseField -Object $Asset -Name 'digest')
        $actualDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($archiveBytes)).ToLowerInvariant()
        if ($expectedDigest -cne ('sha256:' + $actualDigest)) {
            throw 'PowerShell archive bytes do not match the bound release digest at extraction time.'
        }
        [void](Assert-PlatformFileIdentity -Lease $archiveBinding.File -Expected $archiveBinding.Identity -SingleLink -VerifyPath)

        if ($platform -ceq 'windows') {
            $archiveStream = [IO.MemoryStream]::new($archiveBytes, $false)
            $zip = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $false)
            [object[]]$plan = Get-PowerShellZipArchivePlan -Zip $zip
            $directoryLeases = New-PowerShellArchiveDirectoryLeases -Plan $plan -DestinationPath $destinationFullPath
            for ($index = 0; $index -lt $plan.Count; $index++) {
                $item = $plan[$index]
                if ([string]$item.Kind -ceq 'directory') { continue }
                $entry = $zip.Entries[$index]
                $input = $entry.Open()
                $output = $null
                try {
                    $buffer = [IO.MemoryStream]::new()
                    try { $input.CopyTo($buffer); [byte[]]$bytes = $buffer.ToArray() } finally { $buffer.Dispose() }
                    if ($bytes.Length -ne [long]$item.Length) { throw "PowerShell zip member '$($item.Path)' changed during extraction." }
                    $outputParent = Get-PowerShellArchiveParentLease -RelativePath $item.Path -RootLease $destinationLease -DirectoryLeases $directoryLeases
                    $leaf = ([string]$item.Path).Substring(([string]$item.Path).LastIndexOf('/') + 1)
                    $output = Open-PlatformFile -ParentLease $outputParent -Leaf $leaf -Access ReadWrite -CreateMode CreateNew
                    $output.WriteNewBytes($bytes)
                    [void](Assert-PlatformFileIdentity -Lease $output -Expected $output.Observation -SingleLink -VerifyPath)
                }
                finally {
                    if ($null -ne $output) { $output.Dispose() }
                    $input.Dispose()
                }
            }
        }
        else {
            [object[]]$plan = Get-PowerShellTarArchivePlan -ArchiveBytes $archiveBytes
            $directoryLeases = New-PowerShellArchiveDirectoryLeases -Plan $plan -DestinationPath $destinationFullPath
            $memory = [IO.MemoryStream]::new($archiveBytes, $false)
            $gzip = $null
            $reader = $null
            try {
                $gzip = [IO.Compression.GZipStream]::new($memory, [IO.Compression.CompressionMode]::Decompress, $true)
                $reader = [Formats.Tar.TarReader]::new($gzip, $true)
                $index = 0
                while ($null -ne ($entry = $reader.GetNextEntry($false))) {
                    $item = $plan[$index++]
                    $relative = Get-SafePowerShellArchiveRelativePath -Name ([string]$entry.Name)
                    if ($relative -cne [string]$item.Path) { throw 'PowerShell tar archive changed between validation and extraction.' }
                    if ([string]$item.Kind -ceq 'directory') { continue }
                    if ($null -eq $entry.DataStream) {
                        if ([long]$item.Length -ne 0) { throw "PowerShell tar member '$relative' has no content stream." }
                        [byte[]]$bytes = @()
                    }
                    else {
                        $buffer = [IO.MemoryStream]::new()
                        try { $entry.DataStream.CopyTo($buffer); [byte[]]$bytes = $buffer.ToArray() } finally { $buffer.Dispose() }
                    }
                    if ($bytes.Length -ne [long]$item.Length) { throw "PowerShell tar member '$relative' changed during extraction." }
                    $outputParent = Get-PowerShellArchiveParentLease -RelativePath $relative -RootLease $destinationLease -DirectoryLeases $directoryLeases
                    $leaf = $relative.Substring($relative.LastIndexOf('/') + 1)
                    $output = Open-PlatformFile -ParentLease $outputParent -Leaf $leaf -Access ReadWrite -CreateMode CreateNew
                    try {
                        $output.WriteNewBytes($bytes)
                        [void](Set-PlatformPermissions -Lease $output -Policy @{ Mode = [int]$item.Mode })
                        [void](Assert-PlatformFileIdentity -Lease $output -Expected $output.Observation -SingleLink -VerifyPath)
                    }
                    finally { $output.Dispose() }
                }
                if ($index -ne $plan.Count) { throw 'PowerShell tar archive changed between validation and extraction.' }
            }
            finally {
                if ($null -ne $reader) { $reader.Dispose() }
                if ($null -ne $gzip) { $gzip.Dispose() }
                $memory.Dispose()
            }
            foreach ($item in $plan) {
                if ([string]$item.Kind -ceq 'directory') {
                    [void](Set-PlatformPermissions -Lease $directoryLeases[[string]$item.Path] -Policy @{ Mode = [int]$item.Mode })
                }
            }
        }

        [void](Assert-PlatformFileIdentity -Lease $archiveBinding.File -Expected $archiveBinding.Identity -SingleLink -VerifyPath)
        $executablePath = Join-Path $destinationFullPath $executableName
        try { $executableLease = Open-PlatformFile -ParentLease $destinationLease -Leaf $executableName -Access ReadWrite -CreateMode OpenExisting }
        catch { throw "PowerShell archive did not contain $executableName at its root." }
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
        return [IO.Path]::GetFullPath($executablePath)
    }
    catch {
        $failure = $_
        try { Write-PowerShellArchiveFailureMarker -DestinationLease $destinationLease }
        catch {
            throw [IO.IOException]::new(
                "$($failure.Exception.Message) Failed destination could not be marked unusable.",
                [AggregateException]::new($failure.Exception, $_.Exception))
        }
        throw $failure
    }
    finally {
        if ($null -ne $executableLease) { $executableLease.Dispose() }
        Close-PowerShellArchiveDirectoryLeases -Leases $directoryLeases
        if ($null -ne $zip) { $zip.Dispose() }
        if ($null -ne $archiveStream) { $archiveStream.Dispose() }
        if ($null -ne $archiveBinding) { Close-PowerShellReleaseFile -Binding $archiveBinding }
        if ($null -ne $destinationLease) { $destinationLease.Dispose() }
        $destinationParentLease.Dispose()
    }
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
    'Set-PowerShellRuntimeUnusable'
    'Invoke-PowerShellReleaseOwnedProcess'
    'Assert-PowerShellExecutableSignature'
    'Assert-PowerShellRuntimeVersion'
)
