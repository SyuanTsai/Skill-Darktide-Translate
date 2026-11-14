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
Import-Module -Name (Join-Path $PSScriptRoot 'PowerShellRelease.psm1') -Force -ErrorAction Stop
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
    if ($IsWindows) { return [IO.Path]::GetFullPath($Path) }
    $resolved = @(& realpath $Path)
    if ($LASTEXITCODE -ne 0 -or $resolved.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$resolved[0])) {
        throw "Could not resolve physical path: $Path"
    }
    return ([string]$resolved[0]).Trim()
}

function Assert-RequiredValue {
    param([Parameter(Mandatory)][string] $Value, [Parameter(Mandatory)][string] $Name)
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Name is required for workflow PowerShell $Mode mode." }
}

function Get-OfficialManifestArchiveSha256 {
    param([Parameter(Mandatory)][string] $ManifestPath, [Parameter(Mandatory)][string] $ArchiveName)
    return Get-OfficialPowerShellManifestDigest -Path $ManifestPath -ArchiveName $ArchiveName
}

function Assert-WorkflowRuntimeRootEmpty {
    param([Parameter(Mandatory)][string] $Path)
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) {
        throw 'Verified PowerShell runtime root must be fresh and empty.'
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
    $archiveItem = Get-Item -LiteralPath $ArchivePath -Force -ErrorAction Stop
    $manifestItem = Get-Item -LiteralPath $ManifestPath -Force -ErrorAction Stop
    return [pscustomobject][ordered]@{
        platform = $Platform
        name = $ArchiveName
        digest = "sha256:$ArchiveSha256"
        size = [long]$archiveItem.Length
        hashesManifest = [pscustomobject][ordered]@{
            name = 'hashes.sha256'
            digest = "sha256:$ManifestSha256"
            size = [long]$manifestItem.Length
        }
    }
}

if ($DefineFunctionsOnly) { return }

Assert-WorkflowArchitecture

switch ($Mode) {
    'Resolve' {
        Assert-RequiredValue -Value $AssetTemplate -Name 'AssetTemplate'
        Assert-RequiredValue -Value $env:GITHUB_OUTPUT -Name 'GITHUB_OUTPUT'
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
        $metadataRoot = Join-Path ([IO.Path]::GetTempPath()) ("dt-pwsh-metadata-$Platform-$([guid]::NewGuid().ToString('N'))")
        [void](New-Item -ItemType Directory -Path $metadataRoot -ErrorAction Stop)
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
        [void](New-Item -ItemType Directory -Path $CacheRoot -Force -ErrorAction Stop)
        $archivePath = Join-Path $CacheRoot $AssetName
        $cachedManifestPath = Join-Path $CacheRoot 'hashes.sha256'
        $cacheValid = $false
        if ((Test-Path -LiteralPath $archivePath -PathType Leaf) -and (Test-Path -LiteralPath $cachedManifestPath -PathType Leaf)) {
            try {
                $cachedAsset = New-WorkflowPowerShellAssetEvidence -ArchivePath $archivePath -ManifestPath $cachedManifestPath `
                    -ArchiveName $AssetName -ArchiveSha256 $OfficialArchiveSha256 -ManifestSha256 $HashesManifestSha256
                [void](Assert-VerifiedPowerShellArchive -Asset $cachedAsset -Path $archivePath)
                [void](Assert-VerifiedPowerShellHashesManifest -Asset $cachedAsset -Path $cachedManifestPath)
                $cacheValid = $true
            }
            catch {
                Remove-Item -LiteralPath $archivePath, $cachedManifestPath -Force -ErrorAction SilentlyContinue
                Write-Warning "Discarded invalid PowerShell cache entry: $($_.Exception.Message)"
            }
        }
        if (-not $cacheValid) {
            Invoke-WebRequest -Uri $ArchiveUrl -OutFile $archivePath -MaximumRedirection 3 -TimeoutSec 300 -ErrorAction Stop
            [IO.File]::Copy($FreshHashesPath, $cachedManifestPath, $false)
        }
        $verifiedAsset = New-WorkflowPowerShellAssetEvidence -ArchivePath $archivePath -ManifestPath $cachedManifestPath `
            -ArchiveName $AssetName -ArchiveSha256 $OfficialArchiveSha256 -ManifestSha256 $HashesManifestSha256
        [void](Assert-VerifiedPowerShellArchive -Asset $verifiedAsset -Path $archivePath)
        [void](Assert-VerifiedPowerShellHashesManifest -Asset $verifiedAsset -Path $cachedManifestPath)
        if ($AssetName -cne (Get-PowerShellReleaseAssetName -Version $Version -Platform $Platform -Architecture $ExpectedArchitecture)) {
            throw 'AssetName is not the official archive for this platform and architecture.'
        }
        Assert-WorkflowRuntimeRootEmpty -Path $RuntimeRoot
        # The shared extractor requires a fresh destination; the empty run-owned
        # root is removed and recreated by the verified extraction.
        Remove-Item -LiteralPath $RuntimeRoot -Force -ErrorAction Stop
        $executable = Expand-VerifiedPowerShellArchive -Asset $verifiedAsset -ArchivePath $archivePath -DestinationPath $RuntimeRoot
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'Official archive did not contain the expected PowerShell executable.' }
        $signature = Assert-PowerShellExecutableSignature -Path $executable -Platform $Platform
        $signatureStatus = $signature.status; $signerSubject = $signature.signerSubject; $signerThumbprint = $signature.signerThumbprint
        $versionOutput = @(& $executable -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()')
        if ($LASTEXITCODE -ne 0 -or $versionOutput.Count -ne 1) { throw 'Installed PowerShell did not report one version.' }
        [void](Assert-PowerShellRuntimeVersion -Tag $ReleaseTag -ActualVersion ([string]$versionOutput[0]).Trim())
        if (([string]$versionOutput[0]).Trim() -cne $Version) { throw 'Installed PowerShell version differs from the latest stable release tag.' }
        $receipt = [ordered]@{
            schemaVersion = 1; report = 'verified-latest-official-powershell-runtime-v1'
            sourceRepository = 'https://github.com/PowerShell/PowerShell'; releaseApi = 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            releaseTag = $ReleaseTag; version = $Version; platform = $Platform; architecture = $ExpectedArchitecture
            archiveUri = $ArchiveUrl; hashesManifestUri = $HashesUrl; officialArchiveSha256 = $OfficialArchiveSha256
            observedArchiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            executablePath = [IO.Path]::GetFullPath($executable); executableAuthenticodeStatus = $signatureStatus
            executableSignerSubject = $signerSubject; executableSignerThumbprint = $signerThumbprint; cacheRestoredAndValid = $cacheValid
        }
        $receiptPath = Join-Path $OwnedRoot 'powershell-runtime-setup.json'
        [IO.File]::WriteAllText($receiptPath, (($receipt | ConvertTo-Json -Depth 8) + "`n"), [Text.UTF8Encoding]::new($false))
        [IO.File]::Copy($receiptPath, (Join-Path $ArtifactsRoot 'powershell-runtime-setup.json'), $false)
        [IO.File]::Copy($cachedManifestPath, (Join-Path $ArtifactsRoot 'powershell-release-hashes.sha256'), $false)
        [IO.File]::AppendAllText($env:GITHUB_ENV, "DT_POWERSHELL_EXECUTABLE=$([IO.Path]::GetFullPath($executable))`nDT_POWERSHELL_VERSION=$Version`nDT_POWERSHELL_ARCHIVE_SHA256=$OfficialArchiveSha256`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::AppendAllText($env:GITHUB_PATH, "$RuntimeRoot`n", [Text.UTF8Encoding]::new($false))
        break
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
