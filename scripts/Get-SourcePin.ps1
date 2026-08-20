[CmdletBinding()]
param(
    [string] $Ref = 'HEAD'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Invoke-GitText {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)

    $output = & git -C $repoRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    @($output | ForEach-Object { [string] $_ })
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

$version = (Get-Content -LiteralPath (Join-Path $repoRoot 'VERSION') -Raw).Trim()
[ordered]@{
    sourceId = 'darktide-translate'
    repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
    requestedRef = $Ref
    resolvedCommit = $resolvedCommit
    resolvedVersion = $version
    contentSha256 = $contentSha256
} | ConvertTo-Json -Depth 4
