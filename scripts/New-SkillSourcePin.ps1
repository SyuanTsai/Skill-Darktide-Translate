# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $Ref = 'HEAD',
    [string] $RepositoryRoot,
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-SkillPinGitText {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $output = @(& $GitPath -c "safe.directory=$Root" -C $Root @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    @($output | ForEach-Object { [string]$_ })
}

function Invoke-SkillPinGitBytes {
    param(
        [Parameter(Mandatory)][string] $GitPath,
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $GitPath
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-c', "safe.directory=$Root", '-C', $Root) + $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $memory = [IO.MemoryStream]::new()
    try {
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'Unable to start Git for source pin blob hashing.' }
        $process.StandardInput.Close()
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $copyTask.IsCompleted -and $errorTask.IsCompleted)) {
            if (-not $process.HasExited) { [void]$process.WaitForExit(1000) }
            else { [Threading.Tasks.Task]::Delay(50).Wait() }
        }
        [void]$copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "git $($Arguments -join ' ') failed: $errorText"
        }
        $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else {
    [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path)
}
$repoItem = Get-Item -LiteralPath $repoRoot -Force -ErrorAction Stop
if (-not $repoItem.PSIsContainer -or ($repoItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'RepositoryRoot must be a regular non-reparse directory.'
}
if ([string]::IsNullOrWhiteSpace($Ref)) { throw 'Ref must not be empty.' }

try {
    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
}
catch {
    throw "Git executable is required to create a Skill source pin: $($_.Exception.Message)"
}
$gitRoot = @(Invoke-SkillPinGitText -GitPath $gitPath -Root $repoRoot -Arguments @('rev-parse', '--show-toplevel'))[0].Trim()
$comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not [IO.Path]::GetFullPath($gitRoot).Equals($repoRoot, $comparison)) {
    throw 'RepositoryRoot must be the Git repository root.'
}

$resolvedCommit = @(Invoke-SkillPinGitText -GitPath $gitPath -Root $repoRoot -Arguments @('rev-parse', "$Ref^{commit}"))[0].Trim()
if ($resolvedCommit -cnotmatch '^[0-9a-f]{40}$') {
    throw "Ref '$Ref' did not resolve to a full SHA-1 commit identity."
}
$treeLines = @(
    Invoke-SkillPinGitText -GitPath $gitPath -Root $repoRoot -Arguments @('ls-tree', '-r', '--full-tree', $resolvedCommit) |
        Sort-Object -CaseSensitive
)
if ($treeLines.Count -eq 0) { throw "Ref '$Ref' contains no tracked files." }
$normalizedTree = ($treeLines -join "`n") + "`n"
$treeBytes = [Text.UTF8Encoding]::new($false).GetBytes($normalizedTree)
$contentSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($treeBytes)).ToLowerInvariant()

$version = (@(Invoke-SkillPinGitText -GitPath $gitPath -Root $repoRoot -Arguments @('show', "${resolvedCommit}:VERSION")) -join "`n").Trim()
if ($version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
    throw "VERSION at ref '$Ref' is not SemVer-compatible."
}

$skillPath = 'skills/auto-update-darktide-mod'
$skillFiles = @(
    foreach ($line in @(Invoke-SkillPinGitText -GitPath $gitPath -Root $repoRoot -Arguments @(
                'ls-tree', '-r', '--full-tree', '-l', $resolvedCommit, '--', $skillPath
            ))) {
        if ($line -cnotmatch '^(?<mode>100644|100755) blob (?<oid>[0-9a-f]{40})\s+(?<size>\d+)\t(?<path>.+)$') {
            throw "Unable to parse Skill tree entry: $line"
        }
        $mode = [string]$Matches.mode
        $blobOid = [string]$Matches.oid
        $expectedSize = [int64]$Matches.size
        $repositoryPath = [string]$Matches.path
        [byte[]]$blobBytes = @(Invoke-SkillPinGitBytes -GitPath $gitPath -Root $repoRoot -Arguments @('cat-file', 'blob', $blobOid))
        if ($blobBytes.LongLength -ne $expectedSize) {
            throw "Skill blob size differs from Git tree entry: $repositoryPath"
        }
        [ordered]@{
            repositoryPath = $repositoryPath
            mode = $mode
            blobOid = $blobOid
            size = $blobBytes.LongLength
            sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($blobBytes)).ToLowerInvariant()
        }
    }
)
if ($skillFiles.Count -eq 0) { throw "Ref '$Ref' contains no files below '$skillPath'." }

$pin = [ordered]@{
    schemaVersion = 1
    sourceId = 'darktide-translate'
    repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
    requestedRef = $Ref
    resolvedCommit = $resolvedCommit
    resolvedVersion = $version
    contentSha256 = $contentSha256
    skillPath = $skillPath
    skillFiles = $skillFiles
}
$json = ($pin | ConvertTo-Json -Depth 6).Replace("`r`n", "`n") + "`n"

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    [Console]::Out.Write($json)
    return
}

$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$outputParent = Split-Path -Parent $fullOutputPath
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "OutputPath parent directory does not exist: $outputParent"
}
if (Test-Path -LiteralPath $fullOutputPath) { throw "OutputPath already exists: $fullOutputPath" }
$temporaryPath = Join-Path $outputParent ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($fullOutputPath), [guid]::NewGuid().ToString('N'))
$stream = $null
try {
    $stream = [IO.FileStream]::new($temporaryPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $jsonBytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream.Write($jsonBytes)
    $stream.Flush($true)
    $stream.Dispose()
    $stream = $null
    [IO.File]::Move($temporaryPath, $fullOutputPath, $false)
}
finally {
    if ($null -ne $stream) { $stream.Dispose() }
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) { [IO.File]::Delete($temporaryPath) }
}
