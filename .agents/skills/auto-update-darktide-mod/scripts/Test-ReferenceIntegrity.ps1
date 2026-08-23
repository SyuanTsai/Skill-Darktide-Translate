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
if ($provenance.schemaVersion -ne 4) {
    throw 'Unsupported source provenance schemaVersion.'
}
if ($provenance.sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Source provenance commit must be a full Git SHA.'
}

function ConvertTo-NormalizedRepositoryPath {
    param(
        [Parameter(Mandatory = $true)] [string] $Path,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        throw "$Name must be repository-relative."
    }
    $segments = @($Path -split '[\\/]')
    if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw "$Name must be a normalized repository-relative path."
    }
    $segments -join '/'
}

function Get-GitBlobOid {
    param(
        [Parameter(Mandatory = $true)] [byte[]] $Content,
        [Parameter(Mandatory = $true)] [string] $ObjectFormat,
        [Parameter(Mandatory = $true)] [string] $Name
    )

    $header = [Text.Encoding]::ASCII.GetBytes("blob $($Content.Length)`0")
    $objectBytes = [byte[]] ($header + $Content)
    $hash = switch ($ObjectFormat) {
        'sha1' { [Security.Cryptography.SHA1]::HashData($objectBytes); break }
        'sha256' { [Security.Cryptography.SHA256]::HashData($objectBytes); break }
        default { throw "$Name Git object format is unsupported." }
    }
    [Convert]::ToHexString($hash).ToLowerInvariant()
}

$skillRepositoryPath = ConvertTo-NormalizedRepositoryPath `
    -Path $provenance.skillRepositoryPath `
    -Name 'Skill repository path'

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
    $packageBytes = [IO.File]::ReadAllBytes($candidate)
    $packageGitBlobOid = Get-GitBlobOid `
        -Content $packageBytes `
        -ObjectFormat $Document.packagedGitObjectFormat `
        -Name "$Name package"
    if ($packageGitBlobOid -ne $Document.packagedGitBlobOid) {
        throw "$Name package Git blob OID mismatch."
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

    $sourceGitBlobOid = Get-GitBlobOid `
        -Content $expandedBytes `
        -ObjectFormat $Document.sourceGitObjectFormat `
        -Name "$Name source"
    if ($sourceGitBlobOid -ne $Document.sourceGitBlobOid) {
        throw "$Name source Git blob OID mismatch."
    }

    $packagedPath = ConvertTo-NormalizedRepositoryPath `
        -Path $Document.packagedPath `
        -Name "$Name packaged path"

    [ordered]@{
        path = "$skillRepositoryPath/$packagedPath"
        packagedPath = $packagedPath
        contentName = $Document.contentName
        originalPath = $Document.originalPath
        gitBlobOid = $packageGitBlobOid
        gitObjectFormat = $Document.packagedGitObjectFormat
        sourceGitBlobOid = $sourceGitBlobOid
        sourceGitObjectFormat = $Document.sourceGitObjectFormat
        packageSizeBytes = [int64] $file.Length
        packageSha256 = $packageSha
        sizeBytes = [int64] $expandedBytes.Length
        sha256 = $contentSha
    }
}

function Test-Schema15Extension {
    $extensionProvenancePath = Join-Path $skillRoot 'references/schema-15-provenance.json'
    if (-not (Test-Path -LiteralPath $extensionProvenancePath -PathType Leaf)) { throw 'Missing references/schema-15-provenance.json.' }
    $extensionProvenance = Get-Content -LiteralPath $extensionProvenancePath -Raw | ConvertFrom-Json
    if ($extensionProvenance.schemaVersion -ne 1 -or $extensionProvenance.issue -cne 'SYP-91') { throw 'Unsupported Schema 15 provenance contract.' }
    if ($extensionProvenance.derivedFrom.workflowSchemaVersion -ne 14 -or
        $extensionProvenance.derivedFrom.workflowSha256 -cne $provenance.documents.workflow.contentSha256 -or
        $extensionProvenance.derivedFrom.reviewBaselineSha256 -cne $provenance.documents.reviewBaseline.contentSha256) {
        throw 'Schema 15 provenance does not derive from the packaged Schema 14 Workflow and Review Baseline.'
    }
    $relativePath = ConvertTo-NormalizedRepositoryPath -Path $extensionProvenance.path -Name 'Schema 15 reference path'
    $candidate = [IO.Path]::GetFullPath((Join-Path $skillRoot $relativePath))
    $expectedPrefix = $resolvedSkillRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $candidate.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Schema 15 reference escaped the Skill root.' }
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { throw 'Schema 15 reference is missing.' }
    $bytes = [IO.File]::ReadAllBytes($candidate)
    $sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($bytes.LongLength -ne [int64]$extensionProvenance.sizeBytes) { throw 'Schema 15 reference size mismatch.' }
    if ($sha256 -cne [string]$extensionProvenance.sha256) { throw 'Schema 15 reference SHA-256 mismatch.' }
    [ordered]@{
        path = "$skillRepositoryPath/$relativePath"
        packagedPath = $relativePath
        issue = $extensionProvenance.issue
        derivedFromWorkflowSchemaVersion = 14
        derivedFromWorkflowSha256 = $extensionProvenance.derivedFrom.workflowSha256
        derivedFromReviewBaselineSha256 = $extensionProvenance.derivedFrom.reviewBaselineSha256
        gitBlobOid = Get-GitBlobOid -Content $bytes -ObjectFormat 'sha1' -Name 'Schema 15 reference'
        gitObjectFormat = 'sha1'
        sizeBytes = $bytes.LongLength
        sha256 = $sha256
    }
}

$result = [ordered]@{
    result = 'passed'
    sourceRepository = $provenance.sourceRepository
    sourceRef = $provenance.sourceRef
    sourceCommit = $provenance.sourceCommit
    workflow = Test-Document -Name 'Workflow' -Document $provenance.documents.workflow
    reviewBaseline = Test-Document -Name 'Review Baseline' -Document $provenance.documents.reviewBaseline
    schema15 = Test-Schema15Extension
}

if ($PassThru) {
    [PSCustomObject] $result
}
else {
    $result | ConvertTo-Json -Depth 6
}
