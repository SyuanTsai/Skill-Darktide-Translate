# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstallRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $IsWindows) { throw 'Latest stable PowerShell installation requires Windows.' }

$modulePath = Join-Path $PSScriptRoot 'PowerShellRelease.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

function Get-InstalledPowerShellVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ExecutablePath)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ExecutablePath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', '[Console]::Out.Write($PSVersionTable.PSVersion.ToString())')) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Downloaded PowerShell runtime version probe did not start.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) {
            try {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            }
            catch { throw 'Downloaded PowerShell runtime version probe timed out and could not be terminated.' }
            throw 'Downloaded PowerShell runtime version probe exceeded its 15000 millisecond timeout.'
        }
        $stdout = [string]$stdoutTask.GetAwaiter().GetResult()
        $stderr = [string]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "Downloaded PowerShell runtime version probe exited with code $($process.ExitCode): $($stderr.Trim())"
        }
        return $stdout.Trim()
    }
    finally {
        $process.Dispose()
    }
}

$installRootFullPath = [IO.Path]::GetFullPath($InstallRoot)
if (Test-Path -LiteralPath $installRootFullPath) { throw 'Run-owned PowerShell installation path already exists.' }
[void](New-Item -ItemType Directory -Path $installRootFullPath -ErrorAction Stop)

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
$asset = Get-VerifiedPowerShellReleaseAsset -Release $release
if ($asset.tag -cne $stableTag) { throw 'Selected PowerShell archive does not match the verified Microsoft stable channel tag.' }

$archivePath = Join-Path $installRootFullPath $asset.name
Invoke-WebRequest -Uri $asset.browserDownloadUrl -OutFile $archivePath -TimeoutSec 180 -ErrorAction Stop
$observedDigest = Assert-VerifiedPowerShellArchive -Asset $asset -Path $archivePath

$runtimePath = Join-Path $installRootFullPath 'runtime'
if (Test-Path -LiteralPath $runtimePath) { throw 'Run-owned PowerShell runtime extraction path already exists.' }
Expand-Archive -LiteralPath $archivePath -DestinationPath $runtimePath -ErrorAction Stop
$executablePath = Join-Path $runtimePath 'pwsh.exe'
if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) { throw 'Verified PowerShell archive did not contain pwsh.exe at its root.' }
$executable = Get-Item -LiteralPath $executablePath -Force -ErrorAction Stop
if ($executable.PSIsContainer -or ($executable.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Downloaded PowerShell executable is not a regular file.'
}
$actualVersion = Get-InstalledPowerShellVersion -ExecutablePath $executablePath
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
    executablePath = [IO.Path]::GetFullPath($executablePath)
    executableVersion = $actualVersion
}

$receiptPath = Join-Path $installRootFullPath 'powershell-release.json'
$receiptJson = $receipt | ConvertTo-Json -Depth 5 -Compress
$receiptBytes = [Text.UTF8Encoding]::new($false).GetBytes($receiptJson + [Environment]::NewLine)
$receiptStream = [IO.File]::Open($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
try {
    $receiptStream.Write($receiptBytes, 0, $receiptBytes.Length)
    $receiptStream.Flush($true)
}
finally {
    $receiptStream.Dispose()
}

Write-Output -NoEnumerate $receipt
