[CmdletBinding()]
param(
    [string] $SkillSourcePinPath,
    [scriptblock] $HeartbeatAction,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
$skillRoot = Split-Path -Parent $PSScriptRoot

function Invoke-Heartbeat {
    if ($HeartbeatAction) { $null = & $HeartbeatAction }
}

function Copy-StreamWithHeartbeat {
    param([Parameter(Mandatory)][IO.Stream] $Source, [Parameter(Mandatory)][IO.Stream] $Destination)
    Invoke-Heartbeat
    $buffer = [byte[]]::new(1MB)
    while (($readCount = $Source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $Destination.Write($buffer, 0, $readCount)
        Invoke-Heartbeat
    }
}

function Read-FileBytesWithHeartbeat {
    param([Parameter(Mandatory)][string] $Path)
    $source = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $memory = [IO.MemoryStream]::new()
    try {
        Copy-StreamWithHeartbeat -Source $source -Destination $memory
        $memory.ToArray()
    }
    finally { $memory.Dispose(); $source.Dispose() }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    Invoke-Heartbeat
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $readCount)
            Invoke-Heartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose(); $stream.Dispose() }
}

function Assert-NoReparsePath {
    param([string] $Path, [string] $Root, [string] $Name)
    $rawRoot = [IO.Path]::GetFullPath($Root)
    $rootFull = if ($rawRoot -ceq [IO.Path]::GetPathRoot($rawRoot)) { $rawRoot } else { $rawRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootPrefix = if ($rootFull.EndsWith([IO.Path]::DirectorySeparatorChar) -or $rootFull.EndsWith([IO.Path]::AltDirectorySeparatorChar)) { $rootFull } else { $rootFull + [IO.Path]::DirectorySeparatorChar }
    if (-not $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name escapes its physical verification root."
    }
    $current = $pathFull
    for ($depth = 0; $depth -lt 2048; $depth++) {
        if (-not (Test-Path -LiteralPath $current)) { throw "$Name path component is missing." }
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Name path contains a symlink or reparse point."
        }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $pathFull }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent)) { throw "Unable to prove $Name physical containment." }
        $current = $parent
    }
    throw "Unable to prove $Name physical containment within 2048 path components."
}

$null = Assert-NoReparsePath -Path $skillRoot -Root $skillRoot -Name 'Installed Skill root'
$provenancePath = Join-Path $skillRoot 'references/source-provenance.json'
$provenancePath = Assert-NoReparsePath -Path $provenancePath -Root $skillRoot -Name 'Source provenance'

$provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json
if ($provenance.schemaVersion -ne 4) {
    throw 'Unsupported source provenance schemaVersion.'
}
if ($provenance.sourceCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'Source provenance commit must be a full Git SHA.'
}

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        for ($offset = 0; $offset -lt $Bytes.Length; $offset += 1MB) {
            $count = [Math]::Min(1MB, $Bytes.Length - $offset)
            $hasher.AppendData($Bytes, $offset, $count)
            Invoke-Heartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
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

    $algorithm = switch ($ObjectFormat) {
        'sha1' { [Security.Cryptography.HashAlgorithmName]::SHA1; break }
        'sha256' { [Security.Cryptography.HashAlgorithmName]::SHA256; break }
        default { throw "$Name Git object format is unsupported." }
    }
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash($algorithm)
    try {
        $header = [Text.Encoding]::ASCII.GetBytes("blob $($Content.Length)`0")
        $hasher.AppendData($header)
        for ($offset = 0; $offset -lt $Content.Length; $offset += 1MB) {
            $count = [Math]::Min(1MB, $Content.Length - $offset)
            $hasher.AppendData($Content, $offset, $count)
            Invoke-Heartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
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
    $candidate = Assert-NoReparsePath -Path $candidate -Root $skillRoot -Name "$Name reference"

    $file = Get-Item -LiteralPath $candidate
    $packageSha = Get-FileSha256 -Path $candidate
    if ($file.Length -ne [int64] $Document.packagedSizeBytes) {
        throw "$Name package size mismatch."
    }
    if ($packageSha -ne $Document.packagedSha256) {
        throw "$Name package SHA-256 mismatch."
    }
    $packageBytes = Read-FileBytesWithHeartbeat -Path $candidate
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
                Copy-StreamWithHeartbeat -Source $gzipStream -Destination $expandedStream
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

    $contentSha = Get-Sha256Bytes -Bytes $expandedBytes
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
    $extensionProvenancePath = Assert-NoReparsePath -Path $extensionProvenancePath -Root $skillRoot -Name 'Schema 15 provenance'
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
    $candidate = Assert-NoReparsePath -Path $candidate -Root $skillRoot -Name 'Schema 15 reference'
    $bytes = Read-FileBytesWithHeartbeat -Path $candidate
    $sha256 = Get-Sha256Bytes -Bytes $bytes
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

function Test-SkillSourcePin {
    param([Parameter(Mandatory = $true)][string] $Path)

    $pinFull = [IO.Path]::GetFullPath($Path)
    $pinFull = Assert-NoReparsePath -Path $pinFull -Root ([IO.Path]::GetPathRoot($pinFull)) -Name 'Skill source pin'
    $pinBytes = Read-FileBytesWithHeartbeat -Path $pinFull
    $pin = [Text.UTF8Encoding]::new($false, $true).GetString($pinBytes) | ConvertFrom-Json -AsHashtable
    if ([int]$pin.schemaVersion -ne 1 -or [string]$pin.sourceId -cne 'darktide-translate' -or
        [string]$pin.repository -cne 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git' -or
        [string]$pin.skillPath -cne $skillRepositoryPath) {
        throw 'Skill source pin identity does not match darktide-translate.'
    }
    if ([string]$pin.requestedRef -match '^\s*$' -or [string]$pin.resolvedCommit -notmatch '^[0-9a-f]{40}$' -or
        [string]$pin.resolvedVersion -match '^\s*$' -or [string]$pin.contentSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Skill source pin is missing its immutable ref, commit, version, or repository content hash.'
    }
    $expected = @($pin.skillFiles)
    if ($expected.Count -eq 0) { throw 'Skill source pin contains no installed Skill file manifest.' }
    $expectedByPath = @{}
    foreach ($entry in $expected) {
        $repositoryPath = ConvertTo-NormalizedRepositoryPath -Path ([string]$entry.repositoryPath) -Name 'Skill source pin file path'
        if (-not $repositoryPath.StartsWith($skillRepositoryPath + '/', [StringComparison]::Ordinal)) {
            throw 'Skill source pin file is outside the installed Skill path.'
        }
        if ($expectedByPath.ContainsKey($repositoryPath) -or [string]$entry.mode -notin @('100644', '100755') -or
            [string]$entry.blobOid -notmatch '^[0-9a-f]{40}$' -or [int64]$entry.size -lt 0 -or
            [string]$entry.sha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'Skill source pin file manifest is malformed or duplicated.'
        }
        $expectedByPath[$repositoryPath] = $entry
    }
    $actualItems = @(Get-ChildItem -LiteralPath $skillRoot -Recurse -Force)
    if (@($actualItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -ne 0) {
        throw 'Installed Skill source contains a reparse-point path.'
    }
    $actualFiles = @($actualItems | Where-Object { -not $_.PSIsContainer })
    if ($actualFiles.Count -ne $expectedByPath.Count) { throw 'Installed Skill file count differs from its source pin.' }
    foreach ($file in $actualFiles) {
        $null = Assert-NoReparsePath -Path $file.FullName -Root $skillRoot -Name 'Installed Skill source file'
        $relative = [IO.Path]::GetRelativePath($skillRoot, $file.FullName).Replace('\', '/')
        $repositoryPath = "$skillRepositoryPath/$relative"
        if (-not $expectedByPath.ContainsKey($repositoryPath)) { throw "Installed Skill file is absent from its source pin: $repositoryPath" }
        $entry = $expectedByPath[$repositoryPath]
        $bytes = Read-FileBytesWithHeartbeat -Path $file.FullName
        if ($bytes.LongLength -ne [int64]$entry.size -or
            (Get-Sha256Bytes -Bytes $bytes) -cne [string]$entry.sha256 -or
            (Get-GitBlobOid -Content $bytes -ObjectFormat 'sha1' -Name 'Installed Skill file') -cne [string]$entry.blobOid) {
            throw "Installed Skill file differs from its source pin: $repositoryPath"
        }
    }
    [ordered]@{
        sourceId = $pin.sourceId
        repository = $pin.repository
        requestedRef = $pin.requestedRef
        resolvedCommit = $pin.resolvedCommit
        resolvedVersion = $pin.resolvedVersion
        contentSha256 = $pin.contentSha256
        skillPath = $pin.skillPath
        fileCount = $expectedByPath.Count
        files = @($expectedByPath.GetEnumerator() | Sort-Object Key -CaseSensitive | ForEach-Object { $_.Value })
        pinPath = $pinFull
        pinSha256 = Get-Sha256Bytes -Bytes $pinBytes
    }
}

$result = [ordered]@{
    result = 'passed'
    authoringSourceRepository = $provenance.sourceRepository
    authoringSourceRef = $provenance.sourceRef
    authoringSourceCommit = $provenance.sourceCommit
    workflow = Test-Document -Name 'Workflow' -Document $provenance.documents.workflow
    reviewBaseline = Test-Document -Name 'Review Baseline' -Document $provenance.documents.reviewBaseline
    schema15 = Test-Schema15Extension
    skillSourcePin = if ([string]::IsNullOrWhiteSpace($SkillSourcePinPath)) { $null } else { Test-SkillSourcePin -Path $SkillSourcePinPath }
}

if ($PassThru) {
    [PSCustomObject] $result
}
else {
    $result | ConvertTo-Json -Depth 6
}
