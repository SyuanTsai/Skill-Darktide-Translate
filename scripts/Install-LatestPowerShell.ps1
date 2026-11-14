# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$modulePath = Join-Path $PSScriptRoot 'PowerShellRelease.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop
$pathSafetyModule = Import-Module -Name (Join-Path $PSScriptRoot '../skills/auto-update-darktide-mod/scripts/PathSafety.psm1') -Force -PassThru -ErrorAction Stop
$platformRuntimeModule = & $pathSafetyModule { $script:VendoredPlatformRuntimeModule }
if ($platformRuntimeModule -isnot [Management.Automation.PSModuleInfo]) { throw 'Vendored authority platform runtime was not registry-bound.' }
Import-Module -ModuleInfo $platformRuntimeModule -Force -ErrorAction Stop
$hostPlatform = Get-PowerShellHostPlatform
$hostArchitecture = Get-PowerShellHostArchitecture

function Get-InstalledPowerShellVersion {
    [CmdletBinding()]
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
        throw "Downloaded PowerShell runtime version probe exited with code $($result.exitCode): $($result.stderr.Trim())"
    }
    return ([string]$result.stdout).Trim()
}

$installRootFullPath = [IO.Path]::GetFullPath($InstallRoot)
$installParent = [IO.Path]::GetDirectoryName($installRootFullPath)
$installLeaf = [IO.Path]::GetFileName($installRootFullPath)
$installRootLease = Open-PlatformDirectory -Root $installParent -RelativePath $installLeaf -CreatePrivate
$runtimeLease = $null
$executableLease = $null
try {

$stableChannelUri = [uri]'https://aka.ms/powershell-release?tag=stable'
$stableChannelResponse = Invoke-WebRequest `
    -Uri $stableChannelUri `
    -Method Get `
    -TimeoutSec 30 `
    -ErrorAction Stop
$resolvedReleaseUri = $stableChannelResponse.BaseResponse.RequestMessage.RequestUri
if ($resolvedReleaseUri -isnot [uri]) {
    throw 'Microsoft stable PowerShell channel response did not expose its final request URI.'
}
$stableTag = Get-VerifiedPowerShellStableTagFromUri -ResolvedReleaseUri $resolvedReleaseUri
$releaseApiUri = "https://api.github.com/repos/PowerShell/PowerShell/releases/tags/$stableTag"
$release = Invoke-RestMethod `
    -Uri $releaseApiUri `
    -Headers @{
        Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent' = 'Skill-Darktide-Translate-CI'
    } `
    -TimeoutSec 30 `
    -ErrorAction Stop
if ((Assert-PowerShellReleaseTagMatchesStableChannel -ExpectedTag $stableTag -Release $release) -cne $stableTag) {
    throw 'PowerShell release metadata did not match the verified Microsoft stable channel tag.'
}
$asset = Get-VerifiedPowerShellReleaseAsset -Release $release -Platform $hostPlatform -Architecture $hostArchitecture
if ($asset.tag -cne $stableTag) { throw 'Selected PowerShell archive does not match the verified Microsoft stable channel tag.' }

$hashesManifestPath = Join-Path $installRootFullPath $asset.hashesManifest.name
Invoke-WebRequest -Uri $asset.hashesManifest.browserDownloadUrl -OutFile $hashesManifestPath -TimeoutSec 60 -ErrorAction Stop
$observedHashesManifestDigest = Assert-VerifiedPowerShellHashesManifest -Asset $asset -Path $hashesManifestPath

$archivePath = Join-Path $installRootFullPath $asset.name
Invoke-WebRequest -Uri $asset.browserDownloadUrl -OutFile $archivePath -TimeoutSec 180 -ErrorAction Stop
$observedDigest = Assert-VerifiedPowerShellArchive -Asset $asset -Path $archivePath

$runtimePath = Join-Path $installRootFullPath 'runtime'
$executablePath = Expand-VerifiedPowerShellArchive -Asset $asset -ArchivePath $archivePath -DestinationPath $runtimePath
try {
$signature = Assert-PowerShellExecutableSignature -Path $executablePath -Platform $asset.platform
$runtimeLease = Open-PlatformDirectory -Root $installRootFullPath -RelativePath 'runtime'
$executableLease = Open-PlatformFile -ParentLease $runtimeLease -Leaf ([IO.Path]::GetFileName($executablePath)) -Access Read -CreateMode OpenExisting
$actualVersion = Get-InstalledPowerShellVersion -ExecutablePath $executablePath -ExecutableLease $executableLease `
    -WorkingDirectoryPath $installRootFullPath -WorkingDirectoryLease $installRootLease
[void](Assert-PowerShellRuntimeVersion -Tag $asset.tag -ActualVersion $actualVersion)

$receipt = [pscustomobject][ordered]@{
    releaseChannel = $stableChannelUri.AbsoluteUri
    resolvedReleaseUri = $resolvedReleaseUri.AbsoluteUri
    releaseApi = $releaseApiUri
    tag = $asset.tag
    version = $asset.version
    assetId = $asset.assetId
    assetName = $asset.name
    assetUrl = $asset.browserDownloadUrl
    publishedDigest = $asset.digest
    observedSha256 = $observedDigest
    hashesManifestUrl = $asset.hashesManifest.browserDownloadUrl
    hashesManifestPublishedDigest = $asset.hashesManifest.digest
    hashesManifestObservedSha256 = $observedHashesManifestDigest
    platform = $asset.platform
    architecture = $asset.architecture
    executablePath = [IO.Path]::GetFullPath($executablePath)
    executableVersion = $actualVersion
    executableAuthenticodeStatus = $signature.status
    executableSignerSubject = $signature.signerSubject
    executableSignerThumbprint = $signature.signerThumbprint
}

$receiptPath = Join-Path $installRootFullPath 'powershell-release.json'
$receiptJson = $receipt | ConvertTo-Json -Depth 5 -Compress
$receiptBytes = [Text.UTF8Encoding]::new($false).GetBytes($receiptJson + [Environment]::NewLine)
$receiptStream = Open-PlatformFile -ParentLease $installRootLease -Leaf 'powershell-release.json' -Access ReadWrite -CreateMode CreateNew
try {
    $receiptStream.WriteNewBytes($receiptBytes)
    [void](Assert-PlatformFileIdentity -Lease $receiptStream -Expected $receiptStream.Observation -SingleLink -VerifyPath)
}
finally {
    $receiptStream.Dispose()
}
Write-Output -NoEnumerate $receipt
}
catch {
    $runtimeFailure = $_
    try { Set-PowerShellRuntimeUnusable -DestinationPath $runtimePath }
    catch {
        throw [IO.IOException]::new(
            "$($runtimeFailure.Exception.Message) Failed runtime could not be marked unusable.",
            [AggregateException]::new($runtimeFailure.Exception, $_.Exception))
    }
    throw $runtimeFailure
}
}
finally {
    if ($null -ne $executableLease) { $executableLease.Dispose() }
    if ($null -ne $runtimeLease) { $runtimeLease.Dispose() }
    $installRootLease.Dispose()
    Remove-Module -ModuleInfo $platformRuntimeModule -Force -ErrorAction SilentlyContinue
    Remove-Module -ModuleInfo $pathSafetyModule -Force -ErrorAction SilentlyContinue
}
