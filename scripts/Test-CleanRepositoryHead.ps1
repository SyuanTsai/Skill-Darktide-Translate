# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedHeadOid,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$pathSafetyModule = Import-Module -Name (Join-Path $PSScriptRoot '../skills/auto-update-darktide-mod/scripts/PathSafety.psm1') -Force -PassThru -ErrorAction Stop
$platformRuntimeModule = & $pathSafetyModule { $script:VendoredPlatformRuntimeModule }
if ($platformRuntimeModule -isnot [Management.Automation.PSModuleInfo]) { throw 'Vendored authority platform runtime was not registry-bound.' }
Import-Module -ModuleInfo $platformRuntimeModule -Force -ErrorAction Stop
$logicalRoot = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot).Path)
$resolvedRoot = [IO.Path]::GetFullPath((Resolve-PlatformPhysicalPath -Path $logicalRoot))

function Resolve-PhysicalRepositoryPath {
    param([Parameter(Mandatory = $true)] [string] $Path)

    return [IO.Path]::GetFullPath((Resolve-PlatformPhysicalPath -Path $Path)).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitPhysicalPath = Resolve-PhysicalRepositoryPath -Path ([string]$gitCommand.Path)
$gitParentLease = Open-PlatformDirectory -Root ([IO.Path]::GetDirectoryName($gitPhysicalPath)) -RootOnly
$gitLease = Open-PlatformFile -ParentLease $gitParentLease -Leaf ([IO.Path]::GetFileName($gitPhysicalPath)) -Access Read -CreateMode OpenExisting
$gitIdentity = Assert-PlatformFileIdentity -Lease $gitLease -Expected $gitLease.Observation -SingleLink -VerifyPath

function Invoke-GitText {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)

    [void](Assert-PlatformFileIdentity -Lease $gitLease -Expected $gitIdentity -SingleLink -VerifyPath)
    $output = @(& $gitPhysicalPath -C $resolvedRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    @($output | ForEach-Object { [string] $_ })
}

$gitRoot = @(Invoke-GitText -Arguments @('rev-parse', '--show-toplevel'))[0].Trim()
$physicalGitRoot = Resolve-PhysicalRepositoryPath -Path (Resolve-Path -LiteralPath $gitRoot).Path
$physicalRoot = Resolve-PhysicalRepositoryPath -Path $resolvedRoot
$pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not $physicalGitRoot.Equals($physicalRoot, $pathComparison)) {
    throw 'RepositoryRoot must be the Git repository root.'
}

$headOid = @(Invoke-GitText -Arguments @('rev-parse', '--verify', 'HEAD^{commit}'))[0].Trim()
if ($headOid -notmatch '^[0-9a-f]{40}$') {
    throw 'HEAD did not resolve to a full commit SHA.'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedHeadOid) -and $headOid -cne $ExpectedHeadOid) {
    throw "HEAD changed during pre-push validation: expected $ExpectedHeadOid but found $headOid."
}

$status = @(Invoke-GitText -Arguments @('status', '--porcelain=v1', '--untracked-files=all'))
if ($status.Count -ne 0) {
    throw "The working tree and index must be clean before pre-push validation ($($status.Count) changed path(s))."
}

$result = [ordered]@{
    result = 'passed'
    repositoryRoot = $logicalRoot
    headOid = $headOid
}

try {
    if ($PassThru) { [PSCustomObject]$result }
    else { $result | ConvertTo-Json }
}
finally {
    $gitLease.Dispose()
    $gitParentLease.Dispose()
    Remove-Module -ModuleInfo $platformRuntimeModule -Force -ErrorAction SilentlyContinue
    Remove-Module -ModuleInfo $pathSafetyModule -Force -ErrorAction SilentlyContinue
}
