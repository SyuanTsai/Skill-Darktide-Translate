# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [string] $ToolRoot,
    [ValidateSet('Pester', 'PowerShell')][string[]] $Component = @('Pester', 'PowerShell'),
    [string] $OfflinePackagePath,
    [string] $ExpectedSha256
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $repositoryRoot 'config/test-environment.json') -Raw | ConvertFrom-Json
$runningOnWindows = $env:OS -eq 'Windows_NT'
if ([string]::IsNullOrWhiteSpace($ToolRoot)) {
    $override = [Environment]::GetEnvironmentVariable([string]$config.toolRoot.environmentOverride)
    if (-not [string]::IsNullOrWhiteSpace($override)) { $ToolRoot = $override }
    elseif ($runningOnWindows) { $ToolRoot = [string]$config.toolRoot.windows }
    else { $ToolRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.local/share/ai-test-env' }
}
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
if (-not [string]::IsNullOrWhiteSpace($OfflinePackagePath) -and [string]::IsNullOrWhiteSpace($ExpectedSha256)) {
    throw '-OfflinePackagePath requires -ExpectedSha256.'
}
if (-not [string]::IsNullOrWhiteSpace($OfflinePackagePath) -and $Component.Count -ne 1) {
    throw '-OfflinePackagePath requires exactly one -Component.'
}

function Get-InstallSha256([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-InstallReceipt([string] $Path) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    [pscustomobject][ordered]@{ schemaVersion = 1; pester = $null; powerShell = $null }
}

function Write-InstallReceipt([string] $Path, [object] $Receipt) {
    $json = $Receipt | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Move-InstallDirectoryIntoPlace([string] $Staging, [string] $Target) {
    $backup = $null
    if (Test-Path -LiteralPath $Target) {
        $backup = $Target + '.backup.' + [guid]::NewGuid().ToString('N')
        Move-Item -LiteralPath $Target -Destination $backup
    }
    try {
        Move-Item -LiteralPath $Staging -Destination $Target
        if ($null -ne $backup) { Remove-Item -LiteralPath $backup -Recurse -Force }
    }
    catch {
        if ((-not (Test-Path -LiteralPath $Target)) -and $null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Move-Item -LiteralPath $backup -Destination $Target
        }
        throw
    }
}

function Get-LatestPesterVersion {
    $resource = Get-Command Find-PSResource -ErrorAction SilentlyContinue
    if ($null -ne $resource) {
        return [version](Find-PSResource -Name Pester -Repository PSGallery -Prerelease:$false -ErrorAction Stop | Select-Object -First 1).Version
    }
    $module = Get-Command Find-Module -ErrorAction SilentlyContinue
    if ($null -ne $module) { return [version](Find-Module -Name Pester -Repository PSGallery -ErrorAction Stop).Version }
    throw 'Find-PSResource and Find-Module are unavailable; supply -OfflinePackagePath.'
}

function Install-PesterPackage {
    param([string] $PackagePath, [string] $SourceUrl, [string] $PackageSha256, [object] $Receipt)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $inspect = Join-Path ([IO.Path]::GetTempPath()) ("ai-test-env-install/inspect-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $inspect -Force | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $inspect)
        $manifests = @(Get-ChildItem -LiteralPath $inspect -Recurse -File -Filter Pester.psd1)
        if ($manifests.Count -ne 1) { throw 'Pester package must contain exactly one Pester.psd1.' }
        $manifestData = Import-PowerShellDataFile -LiteralPath $manifests[0].FullName
        $version = [version]$manifestData.ModuleVersion
        if ($version -lt [version]$config.pester.minimumVersion) { throw "Pester $version is below $($config.pester.minimumVersion)." }
        $target = Join-Path $ToolRoot "modules/Pester/$version"
        $existing = $Receipt.pester
        if ((Test-Path -LiteralPath (Join-Path $target 'Pester.psd1') -PathType Leaf) -and $null -ne $existing -and
            [string]$existing.version -ceq $version.ToString() -and [string]$existing.packageSha256 -ceq $PackageSha256 -and
            (Get-InstallSha256 (Join-Path $target 'Pester.psd1')) -ceq [string]$existing.manifestSha256) {
            return $existing
        }
        $parent = Split-Path -Parent $target
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        $staging = Join-Path $parent ('.' + $version + '.' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging | Out-Null
        try {
            foreach ($entry in @(Get-ChildItem -LiteralPath $inspect -Force)) {
                if ($entry.Name -in @('[Content_Types].xml', '_rels', 'package') -or $entry.Name -like '*.nuspec') { continue }
                Copy-Item -LiteralPath $entry.FullName -Destination $staging -Recurse
            }
            $installedManifest = Join-Path $staging 'Pester.psd1'
            if (-not (Test-Path -LiteralPath $installedManifest -PathType Leaf)) {
                foreach ($entry in @(Get-ChildItem -LiteralPath $manifests[0].Directory.FullName -Force)) {
                    Copy-Item -LiteralPath $entry.FullName -Destination $staging -Recurse -Force
                }
                Get-ChildItem -LiteralPath $staging -Force | Where-Object { $_.Name -in @('[Content_Types].xml', '_rels', 'package') -or $_.Name -like '*.nuspec' } | Remove-Item -Recurse -Force
            }
            Move-InstallDirectoryIntoPlace -Staging $staging -Target $target
        }
        catch {
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
            throw
        }
        [pscustomobject][ordered]@{
            version = $version.ToString(); sourceUrl = $SourceUrl; packageSha256 = $PackageSha256
            installedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); manifestPath = (Join-Path $target 'Pester.psd1')
            manifestSha256 = Get-InstallSha256 (Join-Path $target 'Pester.psd1')
        }
    }
    finally { if (Test-Path -LiteralPath $inspect) { Remove-Item -LiteralPath $inspect -Recurse -Force } }
}

function Install-PowerShellPackage {
    param([string] $PackagePath, [string] $SourceUrl, [string] $PackageSha256, [string] $Version, [object] $Receipt)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if ([version]$Version -lt [version]$config.powerShell.minimumVersion) {
        throw "PowerShell $Version is below $($config.powerShell.minimumVersion)."
    }
    $target = Join-Path $ToolRoot "pwsh/$Version"
    $existing = $Receipt.powerShell
    $exeName = if ($runningOnWindows) { 'pwsh.exe' } else { 'pwsh' }
    if ((Test-Path -LiteralPath (Join-Path $target $exeName) -PathType Leaf) -and $null -ne $existing -and
        [string]$existing.version -ceq $Version -and [string]$existing.packageSha256 -ceq $PackageSha256 -and
        (Get-InstallSha256 (Join-Path $target $exeName)) -ceq [string]$existing.executableSha256) { return $existing }
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $staging = Join-Path $parent ('.' + $Version + '.' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $staging)
        $exe = Join-Path $staging $exeName
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "PowerShell package does not contain $exeName." }
        if ($runningOnWindows) {
            $policyConfig = '{"Microsoft.PowerShell:ExecutionPolicy":"RemoteSigned"}' + "`n"
            [IO.File]::WriteAllText((Join-Path $staging 'powershell.config.json'), $policyConfig, [Text.UTF8Encoding]::new($false))
        }
        Move-InstallDirectoryIntoPlace -Staging $staging -Target $target
    }
    catch {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        throw
    }
    [pscustomobject][ordered]@{
        version = $Version; sourceUrl = $SourceUrl; packageSha256 = $PackageSha256
        installedAtUtc = [DateTimeOffset]::UtcNow.ToString('o'); executablePath = (Join-Path $target $exeName)
        executableSha256 = Get-InstallSha256 (Join-Path $target $exeName)
    }
}

New-Item -ItemType Directory -Path $ToolRoot -Force | Out-Null
$scratchRoot = Join-Path ([IO.Path]::GetTempPath()) 'ai-test-env-install'
New-Item -ItemType Directory -Path $scratchRoot -Force | Out-Null
$receiptPath = Join-Path $ToolRoot 'install-receipt.json'
$receipt = Read-InstallReceipt $receiptPath
foreach ($name in $Component) {
    $packagePath = $OfflinePackagePath
    $sourceUrl = if ($OfflinePackagePath) { [IO.Path]::GetFullPath($OfflinePackagePath) } else { $null }
    $deletePackage = $false
    $version = $null
    $expected = $ExpectedSha256
    if ([string]::IsNullOrWhiteSpace($packagePath)) {
        $deletePackage = $true
        if ($name -ceq 'Pester') {
            $version = Get-LatestPesterVersion
            $sourceUrl = "$($config.pester.repository)/package/Pester/$version"
            $packagePath = Join-Path $scratchRoot "Pester.$version.nupkg"
            Invoke-WebRequest -Uri $sourceUrl -OutFile $packagePath -UseBasicParsing
            $expected = Get-InstallSha256 $packagePath
        }
        else {
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest' -Headers @{ 'User-Agent' = 'Skill-Darktide-Translate-test-environment' }
            $version = ([string]$release.tag_name).TrimStart('v')
            if (-not $runningOnWindows) { throw 'Automatic PowerShell ZIP installation currently supports Windows only.' }
            $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture
            $rid = if ($architecture -eq [Runtime.InteropServices.Architecture]::X64) { 'win-x64' }
            elseif ($architecture -eq [Runtime.InteropServices.Architecture]::Arm64) { 'win-arm64' }
            else { throw "Unsupported Windows architecture for PowerShell ZIP installation: $architecture" }
            $assetName = "PowerShell-$version-$rid.zip"
            $asset = @($release.assets | Where-Object name -ceq $assetName)
            if ($asset.Count -ne 1 -or [string]$asset[0].digest -cnotmatch '^sha256:(?<hash>[0-9a-fA-F]{64})$') { throw "Release asset or digest missing: $assetName" }
            $expected = $Matches.hash.ToLowerInvariant()
            $sourceUrl = [string]$asset[0].browser_download_url
            $packagePath = Join-Path $scratchRoot $assetName
            Invoke-WebRequest -Uri $sourceUrl -OutFile $packagePath -UseBasicParsing
        }
    }
    try {
        $actual = Get-InstallSha256 $packagePath
        if ($actual -cne $expected.ToLowerInvariant()) { throw "Package sha256 mismatch: expected $($expected.ToLowerInvariant()), actual $actual." }
        if ($name -ceq 'Pester') { $receipt.pester = Install-PesterPackage $packagePath $sourceUrl $actual $receipt }
        else {
            if ([string]::IsNullOrWhiteSpace($version)) {
                $leaf = Split-Path -Leaf $packagePath
                if ($leaf -notmatch '(?i)PowerShell-(?<version>\d+\.\d+\.\d+)-') { throw 'Offline PowerShell ZIP filename must contain PowerShell-<version>-.' }
                $version = $Matches.version
            }
            $receipt.powerShell = Install-PowerShellPackage $packagePath $sourceUrl $actual $version $receipt
        }
        Write-InstallReceipt $receiptPath $receipt
    }
    finally { if ($deletePackage -and (Test-Path -LiteralPath $packagePath)) { Remove-Item -LiteralPath $packagePath -Force } }
}
$receipt
