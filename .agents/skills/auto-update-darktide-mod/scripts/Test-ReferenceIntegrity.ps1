[CmdletBinding()]
param(
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot
$provenancePath = Join-Path $skillRoot 'references/source-provenance.json'
if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) {
    throw 'Missing references/source-provenance.json.'
}

$provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
if ($provenance.schemaVersion -ne 1) {
    throw 'Unsupported source provenance schemaVersion.'
}
if ($provenance.sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Source provenance commit must be a full Git SHA.'
}

$resolvedSkillRoot = [IO.Path]::GetFullPath($skillRoot).TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
)

function Test-Document {
    param(
        [Parameter(Mandatory = $true)] [string] $Name,
        [Parameter(Mandatory = $true)] $Document
    )

    $candidate = [IO.Path]::GetFullPath((Join-Path $skillRoot $Document.packagedPath))
    $expectedPrefix = $resolvedSkillRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name reference escaped the Skill root."
    }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "$Name reference is missing: $($Document.packagedPath)"
    }

    $file = Get-Item -LiteralPath $candidate
    $actualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash.ToLowerInvariant()
    if ($file.Length -ne [int64] $Document.sizeBytes) {
        throw "$Name reference size mismatch."
    }
    if ($actualSha -ne $Document.sha256) {
        throw "$Name reference SHA-256 mismatch."
    }

    [ordered]@{
        path = $Document.packagedPath
        originalPath = $Document.originalPath
        gitBlobOid = $Document.gitBlobOid
        sizeBytes = [int64] $file.Length
        sha256 = $actualSha
    }
}

$result = [ordered]@{
    result = 'passed'
    sourceRepository = $provenance.sourceRepository
    sourceRef = $provenance.sourceRef
    sourceCommit = $provenance.sourceCommit
    workflow = Test-Document -Name 'Workflow' -Document $provenance.documents.workflow
    reviewBaseline = Test-Document -Name 'Review Baseline' -Document $provenance.documents.reviewBaseline
}

if ($PassThru) {
    [PSCustomObject] $result
}
else {
    $result | ConvertTo-Json -Depth 6
}
