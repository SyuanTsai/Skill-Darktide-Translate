# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
[CmdletBinding()]
param(
    [string] $Ref = 'HEAD'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-GitText {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)

    $output = & git -c "safe.directory=$repoRoot" -C $repoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    @($output | ForEach-Object { [string] $_ })
}

function Invoke-GitBytes {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-c', "safe.directory=$repoRoot", '-C', $repoRoot) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start Git for source-pin blob hashing.' }
    $memory = [IO.MemoryStream]::new()
    try {
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $copyTask.IsCompleted -and $errorTask.IsCompleted)) {
            if (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
            else { [Threading.Tasks.Task]::Delay(50).Wait() }
        }
        $null = $copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "git $($Arguments -join ' ') failed: $errorText" }
        $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

$resolvedCommit = @(Invoke-GitText -Arguments @('rev-parse', "$Ref^{commit}"))[0].Trim()
if ($resolvedCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Ref '$Ref' did not resolve to a full commit SHA."
}

$treeLines = @(
    Invoke-GitText -Arguments @('ls-tree', '-r', '--full-tree', $resolvedCommit) |
        Sort-Object -CaseSensitive
)
if ($treeLines.Count -eq 0) {
    throw "Ref '$Ref' contains no tracked files."
}

$normalizedTree = ($treeLines -join "`n") + "`n"
$bytes = [Text.Encoding]::UTF8.GetBytes($normalizedTree)
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $contentSha256 = [Convert]::ToHexString($sha.ComputeHash($bytes)).ToLowerInvariant()
}
finally {
    $sha.Dispose()
}

$version = (@(Invoke-GitText -Arguments @('show', "${resolvedCommit}:VERSION")) -join "`n").Trim()
if ($version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$') {
    throw "VERSION at ref '$Ref' is not SemVer-compatible."
}
$skillPath = 'skills/auto-update-darktide-mod'
$skillFiles = @(
    foreach ($line in @(Invoke-GitText -Arguments @('ls-tree', '-r', '--full-tree', '-l', $resolvedCommit, '--', $skillPath))) {
        if ($line -notmatch '^([0-7]{6}) blob ([0-9a-f]{40,64})\s+(\d+)\t(.+)$') {
            throw "Unable to parse Skill tree entry: $line"
        }
        $blobBytes = Invoke-GitBytes -Arguments @('cat-file', 'blob', $Matches[2])
        if ($blobBytes.LongLength -ne [int64]$Matches[3]) { throw "Skill blob size differs from Git tree entry: $($Matches[4])" }
        [ordered]@{
            repositoryPath = $Matches[4]
            mode = $Matches[1]
            blobOid = $Matches[2]
            size = $blobBytes.LongLength
            sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($blobBytes)).ToLowerInvariant()
        }
    }
)
[ordered]@{
    schemaVersion = 1
    sourceId = 'darktide-translate'
    repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
    requestedRef = $Ref
    resolvedCommit = $resolvedCommit
    resolvedVersion = $version
    contentSha256 = $contentSha256
    skillPath = $skillPath
    skillFiles = $skillFiles
} | ConvertTo-Json -Depth 4
