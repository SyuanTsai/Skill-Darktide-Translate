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
if ($provenance.schemaVersion -ne 2) {
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
    $packageSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $candidate).Hash.ToLowerInvariant()
    if ($file.Length -ne [int64] $Document.packagedSizeBytes) {
        throw "$Name package size mismatch."
    }
    if ($packageSha -ne $Document.packagedSha256) {
        throw "$Name package SHA-256 mismatch."
    }

    $packageStream = [IO.File]::OpenRead($candidate)
    try {
        $gzipStream = [IO.Compression.GZipStream]::new(
            $packageStream,
            [IO.Compression.CompressionMode]::Decompress
        )
        try {
            $expandedStream = [IO.MemoryStream]::new()
            try {
                $gzipStream.CopyTo($expandedStream)
                $expandedBytes = $expandedStream.ToArray()
            }
            finally {
                $expandedStream.Dispose()
            }
        }
        finally {
            $gzipStream.Dispose()
        }
    }
    finally {
        $packageStream.Dispose()
    }

    $contentSha = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($expandedBytes)
    ).ToLowerInvariant()
    if ($expandedBytes.Length -ne [int64] $Document.contentSizeBytes) {
        throw "$Name expanded content size mismatch."
    }
    if ($contentSha -ne $Document.contentSha256) {
        throw "$Name expanded content SHA-256 mismatch."
    }

    [ordered]@{
        path = $Document.packagedPath
        contentName = $Document.contentName
        originalPath = $Document.originalPath
        gitBlobOid = $Document.gitBlobOid
        packageSizeBytes = [int64] $file.Length
        packageSha256 = $packageSha
        sizeBytes = [int64] $expandedBytes.Length
        sha256 = $contentSha
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
