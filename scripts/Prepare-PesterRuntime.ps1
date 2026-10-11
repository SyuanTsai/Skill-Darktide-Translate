# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RuntimeExecutable,
    [Parameter(Mandatory)][string] $OwnedRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$helperPath = Join-Path $PSScriptRoot 'CorePesterIntegrity.psm1'
Import-Module -Name $helperPath -Force -ErrorAction Stop
$lockPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../config/pester-6.2.0-closure.lock.json'))
$lockRecord = Read-CorePesterClosureLock -LiteralPath $lockPath
$runtimeExecutable = [IO.Path]::GetFullPath($RuntimeExecutable)
$actualExecutable = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
if (-not $runtimeExecutable.Equals($actualExecutable, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Pester setup must run under the exact verified PowerShell executable it will populate.'
}
$runtimeModuleRoot = Get-CorePesterRuntimeModuleRoot -ExecutablePath $runtimeExecutable
$ownedRoot = [IO.Path]::GetFullPath($OwnedRoot)
$ownedBoundary = Test-CorePesterPathBoundary -Path $ownedRoot -Boundary $ownedRoot
if (-not $ownedBoundary.IsValid) { throw ('Pester setup evidence root is unsafe: ' + (@($ownedBoundary.Errors) -join '; ')) }
$registeredOwnedRoot = [Environment]::GetEnvironmentVariable('RUN_OWNED_ROOT', 'Process')
if ([string]::IsNullOrWhiteSpace($registeredOwnedRoot) -or
    -not ([IO.Path]::GetFullPath($registeredOwnedRoot)).Equals($ownedRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Pester setup root does not match the workflow-registered run-owned root.'
}
$setupRoot = Join-Path $ownedRoot 'pester-setup'
$setupBoundary = Test-CorePesterPathBoundary -Path $setupRoot -Boundary $ownedRoot
if (-not $setupBoundary.IsValid) { throw ('Pester setup evidence path is unsafe: ' + (@($setupBoundary.Errors) -join '; ')) }
if (Test-Path -LiteralPath $setupRoot) { throw 'Pester setup evidence directory already exists.' }
[void](New-Item -ItemType Directory -Path $setupRoot -ErrorAction Stop)
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
    $downloadResponse = Invoke-WebRequest -Uri $sourceUri -OutFile $archivePath -PassThru -MaximumRedirection 3 -TimeoutSec 180 -ErrorAction Stop
    $observedFinalPackageUri = $null
    if ($null -ne $downloadResponse -and $null -ne $downloadResponse.BaseResponse -and
        $null -ne $downloadResponse.BaseResponse.RequestMessage -and
        $null -ne $downloadResponse.BaseResponse.RequestMessage.RequestUri) {
        $observedFinalPackageUri = [string]$downloadResponse.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
    }
    if ($null -ne $observedFinalPackageUri -and $observedFinalPackageUri -cnotmatch '^https://') {
        throw 'PSGallery acquisition resolved to a non-HTTPS final package URI.'
    }
    $package = Test-CorePesterPackageArchive -ArchivePath $archivePath -Lock $lockRecord.Value
    if (-not $package.IsValid) { throw ('Official Pester package does not match the complete reviewed lock: ' + (@($package.Errors) -join '; ')) }

    if (Test-Path -LiteralPath $destinationModuleRoot) { throw 'The verified PowerShell runtime already contains a Pester destination; setup refuses overwrite.' }
    $runtimeRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $destinationModuleRoot))
    $destinationBoundary = Test-CorePesterPathBoundary -Path $destinationModuleRoot -Boundary $runtimeRoot
    if (-not $destinationBoundary.IsValid) {
        throw ('Pester destination is outside the verified runtime or has a reparse-point ancestor: ' + (@($destinationBoundary.Errors) -join '; '))
    }

    $stageBoundary = Test-CorePesterPathBoundary -Path $stageRoot -Boundary $setupRoot
    if (-not $stageBoundary.IsValid) { throw ('Pester staging path is unsafe: ' + (@($stageBoundary.Errors) -join '; ')) }
    [void](New-Item -ItemType Directory -Path $stageRoot -ErrorAction Stop)
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
            if (-not $targetPath.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) { throw "Package path escaped owned staging: $relative" }
            $targetDirectory = Split-Path -Parent $targetPath
            [void](New-Item -ItemType Directory -Path $targetDirectory -Force -ErrorAction Stop)
            $inputStream = $archiveEntry[0].Open()
            $outputStream = [IO.FileStream]::new($targetPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $inputStream.CopyTo($outputStream); $outputStream.Flush($true) }
            finally { $inputStream.Dispose(); $outputStream.Dispose() }
        }
    }
    finally { $archive.Dispose() }

    $stagedClosure = Test-CorePesterClosure -ModuleRoot $stageRoot -Lock $lockRecord.Value
    if (-not $stagedClosure.IsValid) { throw ('Staged Pester package closure failed: ' + (@($stagedClosure.Errors) -join '; ')) }
    [void](New-Item -ItemType Directory -Path (Split-Path -Parent $destinationModuleRoot) -Force -ErrorAction Stop)
    [void](New-Item -ItemType Directory -Path $destinationModuleRoot -ErrorAction Stop)
    $destinationCreated = $true
    foreach ($payload in $lockRecord.Value.modulePayload) {
        $relative = [string]$payload.path
        $sourcePath = Join-Path $stageRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        $targetPath = Join-Path $destinationModuleRoot ($relative.Replace('/', [IO.Path]::DirectorySeparatorChar))
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force -ErrorAction Stop)
        [IO.File]::Copy($sourcePath, $targetPath, $false)
    }
    $runtimeClosure = Test-CorePesterClosure -ModuleRoot $destinationModuleRoot -Lock $lockRecord.Value
    if (-not $runtimeClosure.IsValid) { throw ('Installed PowerShell runtime closure failed: ' + (@($runtimeClosure.Errors) -join '; ')) }

    $archiveSha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $receipt = [ordered]@{
        schemaVersion = 1
        report = 'verified-pester-runtime-setup-v1'
        sourceUri = $sourceUri
        observedFinalPackageUri = $observedFinalPackageUri
        finalPackageUriObserved = ($null -ne $observedFinalPackageUri)
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
    $receiptStream = [IO.FileStream]::new($receiptPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $receiptStream.Write($receiptBytes, 0, $receiptBytes.Length); $receiptStream.Flush($true) }
    finally { $receiptStream.Dispose() }
    $receiptHash = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
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
            if (Test-Path -LiteralPath $destinationModuleRoot -PathType Container) {
                Remove-Item -LiteralPath $destinationModuleRoot -Recurse -Force -ErrorAction Stop
            }
            if (Test-Path -LiteralPath $destinationModuleRoot) { throw 'Owned runtime destination cleanup did not remove the Pester directory.' }
        }
        catch {
            $cleanupFailed = $true
            [Console]::Error.WriteLine("Pester runtime cleanup failed closed: $($_.Exception.Message)")
        }
    }
    exit 1
}
finally {
    try {
        $stageBoundary = Test-CorePesterPathBoundary -Path $stageRoot -Boundary $setupRoot
        if (-not $stageBoundary.IsValid) { throw ('Refusing unsafe recursive staging cleanup: ' + (@($stageBoundary.Errors) -join '; ')) }
        if (Test-Path -LiteralPath $stageRoot -PathType Container) {
            Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $stageRoot) { throw 'Owned staging cleanup did not remove the staging directory.' }
    }
    catch {
        $cleanupFailed = $true
        [Console]::Error.WriteLine("Pester staging cleanup failed closed: $($_.Exception.Message)")
    }
}
if ($cleanupFailed) { exit 1 }
if ($null -ne $successMessage) { Write-Output $successMessage }
