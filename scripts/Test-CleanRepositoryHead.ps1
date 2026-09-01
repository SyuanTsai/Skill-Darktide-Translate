[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string] $ExpectedHeadOid,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot).Path

function Invoke-GitText {
    param([Parameter(Mandatory = $true)] [string[]] $Arguments)

    $output = @(& git -C $resolvedRoot @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed: $($output -join [Environment]::NewLine)"
    }
    @($output | ForEach-Object { [string] $_ })
}

$gitRoot = @(Invoke-GitText -Arguments @('rev-parse', '--show-toplevel'))[0].Trim()
$resolvedGitRoot = (Resolve-Path -LiteralPath $gitRoot).Path
if (-not $resolvedGitRoot.Equals($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
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
    repositoryRoot = $resolvedRoot
    headOid = $headOid
}

if ($PassThru) { [PSCustomObject]$result }
else { $result | ConvertTo-Json }
