#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('acquire-source', 'claim', 'verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate', 'publish', 'review-snapshot', 'run')]
    [string] $Command,

    [Parameter(Mandatory)]
    [string] $RepositoryRoot,

    [string] $StatePath,
    [string] $ArchivePath,
    [string] $ModDirectory,
    [string] $RunId,
    [string] $SourceRequestPath,
    [string] $SourceReceiptPath,
    [string] $SkillSourcePinPath,
    [ValidateSet('api', 'browser')]
    [string] $Provider = 'browser',
    [string] $DownloadedFilePath,
    [ValidateRange(0, 60000)]
    [int] $ObservationIntervalMilliseconds = 1000,
    [string] $LocalizationPlanPath,
    [string] $LocalReviewPath,
    [string[]] $MetadataPath = @(),
    [string] $BaseRef = 'origin/main',
    [string] $WorktreeParent,
    [string] $Remote = 'origin',
    [string] $PullRequestBase = 'main',
    [ValidateSet('source-verified', 'awaiting-user-merge')]
    [string] $Until = 'awaiting-user-merge',
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $buffer = [byte[]]::new(1MB)
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $read)
            Update-ActiveReservationHeartbeat
            Update-ActiveSharedCoordinationHeartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Copy-StreamWithHeartbeat {
    param(
        [Parameter(Mandatory)][IO.Stream] $Source,
        [Parameter(Mandatory)][IO.Stream] $Destination
    )
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
    $buffer = [byte[]]::new(1MB)
    while (($readCount = $Source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $Destination.Write($buffer, 0, $readCount)
        Update-ActiveReservationHeartbeat
        Update-ActiveSharedCoordinationHeartbeat
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
    finally {
        $memory.Dispose()
        $source.Dispose()
    }
}

function Copy-FileWithHeartbeat {
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter(Mandatory)][string] $DestinationPath,
        [switch] $Overwrite
    )
    $source = [IO.File]::Open($SourcePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $destinationMode = if ($Overwrite) { [IO.FileMode]::Create } else { [IO.FileMode]::CreateNew }
    $destination = $null
    try {
        $destination = [IO.File]::Open($DestinationPath, $destinationMode, [IO.FileAccess]::Write, [IO.FileShare]::None)
        Copy-StreamWithHeartbeat -Source $source -Destination $destination
        $destination.Flush($true)
    }
    finally {
        if ($destination) { $destination.Dispose() }
        $source.Dispose()
    }
}

function Remove-DirectoryTreeWithHeartbeat {
    param([Parameter(Mandatory)][string] $Path)
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
    $root = [IO.Path]::GetFullPath($Path)
    $directories = [Collections.Generic.List[string]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Refusing heartbeat-aware removal of a tree containing a reparse point.'
        }
        if ($item.PSIsContainer) { $directories.Add($item.FullName) }
        else {
            if ($item.Attributes -band [IO.FileAttributes]::ReadOnly) { [IO.File]::SetAttributes($item.FullName, [IO.FileAttributes]::Normal) }
            [IO.File]::Delete($item.FullName)
        }
        Update-ActiveReservationHeartbeat
        Update-ActiveSharedCoordinationHeartbeat
    }
    foreach ($directory in @($directories | Sort-Object { $_.Length } -Descending)) {
        [IO.File]::SetAttributes($directory, [IO.FileAttributes]::Directory)
        [IO.Directory]::Delete($directory)
        Update-ActiveReservationHeartbeat
        Update-ActiveSharedCoordinationHeartbeat
    }
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
    [IO.File]::SetAttributes($root, [IO.FileAttributes]::Directory)
    [IO.Directory]::Delete($root)
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
}

function ConvertTo-InvariantString {
    param($Value)
    if ($null -eq $Value) { return $null }
    [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-NexusSourceIdentity {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Request,
        [switch] $RequireMetadata
    )
    if ([int]$Request.schemaVersion -notin @(1, 2)) { throw 'Source request schemaVersion must be 1 or 2.' }
    foreach ($field in @('gameDomain', 'modId', 'mainFileId', 'version', 'fileName', 'pageUrl')) {
        if (-not $Request.Contains($field) -or [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $Request[$field]))) {
            throw "Source request requires a unique $field value."
        }
    }
    if ($RequireMetadata) {
        if ([int]$Request.schemaVersion -ne 2) {
            throw 'Claimed source requests must use schemaVersion 2 with the complete immutable Nexus Main identity.'
        }
        foreach ($field in @('pageVersion', 'pageUpdatedAt', 'mainFileUploadedAtUtc')) {
            if (-not $Request.Contains($field) -or [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $Request[$field]))) {
                throw "Source request requires immutable Nexus metadata field $field before claim."
            }
        }
        foreach ($timestampField in @('pageUpdatedAt', 'mainFileUploadedAtUtc')) {
            $timestamp = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParseExact(
                (ConvertTo-InvariantString $Request[$timestampField]),
                'o',
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$timestamp
            )) {
                throw "Source request $timestampField must be an ISO-8601 round-trip timestamp."
            }
        }
    }
    $pageUri = [Uri](ConvertTo-InvariantString $Request.pageUrl)
    if (-not $pageUri.IsAbsoluteUri -or $pageUri.Scheme -cne 'https' -or
        -not [string]::IsNullOrEmpty($pageUri.UserInfo) -or -not [string]::IsNullOrEmpty($pageUri.Query) -or
        -not [string]::IsNullOrEmpty($pageUri.Fragment) -or -not $pageUri.IsDefaultPort) {
        throw 'Source request pageUrl must be a canonical absolute HTTPS URL without user-info, query, fragment, or a custom port.'
    }
    $gameDomain = ConvertTo-InvariantString $Request.gameDomain
    $modId = ConvertTo-InvariantString $Request.modId
    if ($gameDomain -cne 'warhammer40kdarktide' -or
        $pageUri.Host -notin @('nexusmods.com', 'www.nexusmods.com') -or
        $pageUri.AbsolutePath.TrimEnd('/') -cne "/warhammer40kdarktide/mods/$modId") {
        throw 'Source request must identify the official Nexus MOD page for warhammer40kdarktide.'
    }
    $fileName = ConvertTo-InvariantString $Request.fileName
    if ([IO.Path]::GetFileName($fileName) -cne $fileName -or $fileName.TrimEnd([char[]]' .') -cne $fileName -or
        $fileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'Source request fileName must be one safe single file name.'
    }
    if ($fileName -match '(?i)^(con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\..*)?$') {
        throw 'Source request fileName uses a reserved Windows device name.'
    }
    $officialSha256 = if ($Request.Contains('officialSha256') -and
        -not [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $Request.officialSha256))) {
        (ConvertTo-InvariantString $Request.officialSha256).ToLowerInvariant()
    }
    else { $null }
    if ($null -ne $officialSha256 -and $officialSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Source request officialSha256 must contain 64 hexadecimal characters.'
    }
    $identity = [ordered]@{
        gameDomain = $gameDomain
        modId = $modId
        pageUrl = $pageUri.AbsoluteUri.TrimEnd('/')
        pageVersion = if ($Request.Contains('pageVersion')) { ConvertTo-InvariantString $Request.pageVersion } else { $null }
        pageUpdatedAt = if ($Request.Contains('pageUpdatedAt')) { ConvertTo-InvariantString $Request.pageUpdatedAt } else { $null }
        mainFileId = ConvertTo-InvariantString $Request.mainFileId
        mainFileVersion = ConvertTo-InvariantString $Request.version
        mainFileUploadedAtUtc = if ($Request.Contains('mainFileUploadedAtUtc')) { ConvertTo-InvariantString $Request.mainFileUploadedAtUtc } else { $null }
        fileName = $fileName
        officialSha256 = $officialSha256
    }
    foreach ($field in $identity.Keys) {
        $fieldValue = [string]$identity[$field]
        if (-not [string]::IsNullOrEmpty($fieldValue) -and @($fieldValue.ToCharArray() | Where-Object { [char]::IsControl($_) }).Count -ne 0) {
            throw "Source request $field contains a control character."
        }
    }
    $identity
}

function Get-SourceTupleContractSha256 {
    param([Parameter(Mandatory)][Collections.IDictionary] $Contract)
    Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes(
        ($Contract | ConvertTo-Json -Depth 20 -Compress)
    ))
}

function New-SourceTupleEvidence {
    param(
        [Parameter(Mandatory)][string] $OutputPath,
        [Parameter(Mandatory)][string] $ActualRunId,
        [Parameter(Mandatory)][string] $AcquisitionMethod,
        [Parameter(Mandatory)][Collections.IDictionary] $NexusIdentity,
        [Parameter(Mandatory)][string] $ArchiveFileName,
        [Parameter(Mandatory)][int64] $ArchiveSize,
        [Parameter(Mandatory)][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $BoundSourceRequestPath,
        [AllowNull()][string] $BoundSourceReceiptPath
    )
    if ($ArchiveFileName -cne [string]$NexusIdentity.fileName) {
        throw 'Archive full filename does not match the immutable Nexus Main file tuple.'
    }
    $requestFull = [IO.Path]::GetFullPath($BoundSourceRequestPath)
    $receiptFull = if ([string]::IsNullOrWhiteSpace($BoundSourceReceiptPath)) { $null } else { [IO.Path]::GetFullPath($BoundSourceReceiptPath) }
    $contract = [ordered]@{
        runId = $ActualRunId
        acquisitionMethod = $AcquisitionMethod
        nexus = $NexusIdentity
        archive = [ordered]@{ fileName = $ArchiveFileName; size = $ArchiveSize; sha256 = $ArchiveSha256 }
        sourceRequestSha256 = Get-FileSha256 -Path $requestFull
        sourceReceiptSha256 = if ($receiptFull) { Get-FileSha256 -Path $receiptFull } else { $null }
    }
    $contractSha256 = Get-SourceTupleContractSha256 -Contract $contract
    $record = [ordered]@{
        schemaVersion = 1
        contract = $contract
        contractSha256 = $contractSha256
        sourceRequestPath = $requestFull
        sourceReceiptPath = $receiptFull
        capturedAt = Get-UtcTimestamp
    }
    Write-AtomicJson -Path $OutputPath -Value $record
    [ordered]@{
        path = [IO.Path]::GetFullPath($OutputPath)
        sha256 = Get-FileSha256 -Path $OutputPath
        contractSha256 = $contractSha256
        contract = $contract
    }
}

function New-CheckpointReason {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][ValidateSet('C2', 'C3')][string] $Checkpoint,
        [AllowNull()][string] $ParentTreeOid,
        [AllowNull()][string] $TreeOid
    )
    $targetPaths = @($State.evidenceTargetPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $targetPathsJson = ConvertTo-Json -InputObject @($targetPaths) -Compress
    $targetPathsSha256 = Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($targetPathsJson))
    if ($targetPathsSha256 -cne [string]$State.evidenceTargetPathsSha256) {
        throw "$Checkpoint reason target paths differ from the immutable localization target contract."
    }
    $manifestSha256 = Get-FileSha256 -Path ([string]$State.localizationManifestPath)
    $isNotApplicable = [string]$State.localizationMode -ceq 'none'
    $isKeep = $isNotApplicable -or $ParentTreeOid -ceq $TreeOid
    $code = if ($isNotApplicable) { 'localization-not-applicable' }
        elseif ($Checkpoint -ceq 'C2' -and $isKeep) { 'upstream-localization-unchanged' }
        elseif ($Checkpoint -ceq 'C2') { 'upstream-localization-changed' }
        elseif ($isKeep) { 'approved-localization-unchanged' }
        else { 'approved-localization-changed' }
    $contract = [ordered]@{
        checkpoint = $Checkpoint
        code = $code
        disposition = if ($isKeep) { 'KEEP' } else { 'APPLY' }
        localizationMode = [string]$State.localizationMode
        parentTreeOid = $ParentTreeOid
        treeOid = $TreeOid
        targetPathsSha256 = $targetPathsSha256
        targetPathCount = $targetPaths.Count
        localizationManifestSha256 = $manifestSha256
    }
    [ordered]@{
        schemaVersion = 1
        code = $code
        disposition = $contract.disposition
        localizationMode = $contract.localizationMode
        parentTreeOid = $ParentTreeOid
        treeOid = $TreeOid
        targetPathsSha256 = $targetPathsSha256
        targetPathCount = $targetPaths.Count
        localizationManifestSha256 = $manifestSha256
        contractSha256 = Get-SourceTupleContractSha256 -Contract $contract
    }
}

function Test-MetadataSourceFieldMatch {
    param([string] $RelativePath, [string] $Text, [string] $FieldName, [string] $FieldValue)
    if ([string]::IsNullOrWhiteSpace($FieldValue)) { return $false }
    if ($RelativePath.StartsWith('.hash/', [StringComparison]::Ordinal)) {
        $hashKeys = [ordered]@{
            nexusModId = 'nexus_id'; nexusPageUrl = 'nexus_url'; nexusPageVersion = 'nexus_page_version'
            nexusPageUpdatedAt = 'nexus_last_updated'; nexusMainFileId = 'main_file_id'; nexusMainFileVersion = 'version'
            nexusMainFileUploadedAtUtc = 'main_file_uploaded_at_utc'; archiveFileName = 'filename'
            archiveSize = 'size_bytes'; archiveSha256 = 'sha256'; acquisitionMethod = 'acquisition_method'
        }
        if (-not $hashKeys.Contains($FieldName)) { return $false }
        $key = [regex]::Escape([string]$hashKeys[$FieldName])
        $matchesForKey = @([regex]::Matches($Text, "(?m)^$key=([^`r`n]*)`r?$") )
        return $matchesForKey.Count -eq 1 -and [string]$matchesForKey[0].Groups[1].Value -ceq $FieldValue
    }
    if ($RelativePath -cne 'README.md') { return $false }
    $readmeLabels = [ordered]@{
        nexusModId = 'Nexus MOD ID'; nexusPageUrl = 'Nexus URL'; nexusPageVersion = 'Nexus page version'
        nexusPageUpdatedAt = 'Nexus last updated'; nexusMainFileId = 'Main file ID'; nexusMainFileVersion = 'Main file version'
        nexusMainFileUploadedAtUtc = 'Main file uploaded at UTC'; archiveFileName = 'Archive filename'
        archiveSize = 'Archive size bytes'; archiveSha256 = 'Archive SHA-256'; acquisitionMethod = 'Acquisition method'
    }
    if (-not $readmeLabels.Contains($FieldName)) { return $false }
    $label = [regex]::Escape([string]$readmeLabels[$FieldName])
    $matchesForLabel = @([regex]::Matches($Text, "(?m)^\s*-\s+$label\s*:\s*([^`r`n]*)`r?$") )
    if ($matchesForLabel.Count -ne 1) { return $false }
    $recorded = ([string]$matchesForLabel[0].Groups[1].Value).Trim()
    if ($recorded.Length -ge 2 -and $recorded.StartsWith('`', [StringComparison]::Ordinal) -and
        $recorded.EndsWith('`', [StringComparison]::Ordinal)) {
        $recorded = $recorded.Substring(1, $recorded.Length - 2)
    }
    $recorded -ceq $FieldValue
}

function ConvertTo-SafeSlug {
    param([Parameter(Mandatory)][string] $Value)
    $slug = ($Value.ToLowerInvariant() -replace '[^a-z0-9._-]+', '-' -replace '-{2,}', '-').Trim('.', '-')
    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw 'MOD identity cannot be converted to a safe slug.'
    }
    $slug
}

function Assert-ContainedPath {
    param(
        [Parameter(Mandatory)][string] $Candidate,
        [Parameter(Mandatory)][string] $Root,
        [string] $Label = 'path'
    )
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $candidateFull = [IO.Path]::GetFullPath($Candidate)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $candidateFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the allowed root."
    }
    $candidateFull
}

function Assert-NoReparsePath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [string] $Label = 'path',
        [switch] $AllowMissing
    )
    $rawRoot = [IO.Path]::GetFullPath($Root)
    $rootFull = if ($rawRoot -ceq [IO.Path]::GetPathRoot($rawRoot)) { $rawRoot } else { $rawRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) }
    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootPrefix = if ($rootFull.EndsWith([IO.Path]::DirectorySeparatorChar) -or $rootFull.EndsWith([IO.Path]::AltDirectorySeparatorChar)) { $rootFull } else { $rootFull + [IO.Path]::DirectorySeparatorChar }
    if (-not $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes its physical verification root."
    }
    $current = $pathFull
    for ($depth = 0; $depth -lt 2048; $depth++) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "$Label path contains a symlink or reparse point."
            }
        }
        elseif (-not $AllowMissing) { throw "$Label path component is missing." }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $pathFull }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent)) { throw "Unable to prove $Label physical containment." }
        $current = $parent
    }
    throw "Unable to prove $Label physical containment within 2048 path components."
}

function Assert-NoReparseTree {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Root,
        [string] $Label = 'tree'
    )
    $treeFull = Assert-NoReparsePath -Path $Path -Root $Root -Label $Label
    if (-not (Test-Path -LiteralPath $treeFull -PathType Container)) { throw "$Label is not a directory." }
    Update-ActiveReservationHeartbeat -Force
    Get-ChildItem -LiteralPath $treeFull -Recurse -Force | ForEach-Object {
        $item = $_
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label contains a symlink or reparse point."
        }
        Update-ActiveReservationHeartbeat
        Update-ActiveSharedCoordinationHeartbeat
    }
    $treeFull
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Value,
        [switch] $SkipReservationCheck
    )
    if (-not $SkipReservationCheck) {
        Update-ActiveReservationHeartbeat -Force
        Update-ActiveSharedCoordinationHeartbeat -Force
    }
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent | Out-Null
    }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    $json = $Value | ConvertTo-Json -Depth 40
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][byte[]] $Bytes
    )
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.bin')
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    [IO.File]::Move($temporary, $fullPath, $true)
}

function Get-SkillSourceFileEntry {
    param([Collections.IDictionary] $SkillSourcePin, [string] $RepositoryPath)
    $matchingEntries = @($SkillSourcePin.files | Where-Object { [string]$_.repositoryPath -ceq $RepositoryPath })
    if ($matchingEntries.Count -ne 1) { throw "Skill source pin does not contain exactly one required file: $RepositoryPath" }
    $matchingEntries[0]
}

function Get-ModReservationOwnerPath {
    param(
        [Parameter(Mandatory)][string] $ModLockPath,
        [Parameter(Mandatory)][string] $Repository,
        [switch] $AllowMissingOwner
    )
    $lockFull = [IO.Path]::GetFullPath($ModLockPath)
    $repositoryFull = [IO.Path]::GetFullPath($Repository)
    $null = Assert-NoReparsePath -Path $lockFull -Root $repositoryFull -Label 'MOD reservation'
    $ownerPath = Join-Path $lockFull 'owner.json'
    $null = Assert-NoReparsePath -Path $ownerPath -Root $repositoryFull -Label 'MOD reservation owner' -AllowMissing:$AllowMissingOwner
    $ownerPath
}

function Read-ModReservationOwner {
    param(
        [Parameter(Mandatory)][string] $ModLockPath,
        [Parameter(Mandatory)][string] $Repository
    )
    $ownerPath = Get-ModReservationOwnerPath -ModLockPath $ModLockPath -Repository $Repository
    if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) { throw 'MOD identity lock owner is missing.' }
    Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
}

function Write-ModReservationOwner {
    param(
        [Parameter(Mandatory)][string] $ModLockPath,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][Collections.IDictionary] $Value,
        [string] $ExpectedReservationToken,
        [AllowNull()][string] $ExpectedWorkerToken
    )
    $ownerPath = Get-ModReservationOwnerPath -ModLockPath $ModLockPath -Repository $Repository -AllowMissingOwner
    $ownerExists = Test-Path -LiteralPath $ownerPath -PathType Leaf
    $guardStream = $null
    try {
        if ($ownerExists) {
            if ([string]::IsNullOrWhiteSpace($ExpectedReservationToken)) {
                throw 'Updating an existing MOD reservation requires its current reservation token.'
            }
            $guardPath = Join-Path ([IO.Path]::GetFullPath($ModLockPath)) 'owner-update.guard'
            for ($attempt = 0; $attempt -lt 80 -and -not $guardStream; $attempt++) {
                try {
                    $guardStream = [IO.File]::Open($guardPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                }
                catch [IO.IOException] { [Threading.Thread]::Sleep(25) }
            }
            if (-not $guardStream) { throw 'Unable to acquire the short MOD owner update guard.' }
            $current = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
            if ([string]$current.reservationToken -cne $ExpectedReservationToken -or
                [string]$current.workerToken -cne [string]$ExpectedWorkerToken) {
                throw 'MOD reservation ownership changed before its owner update.'
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ExpectedReservationToken)) {
            throw 'MOD reservation owner disappeared before its guarded update.'
        }
        Write-AtomicJson -Path $ownerPath -Value $Value -SkipReservationCheck
        $null = Get-ModReservationOwnerPath -ModLockPath $ModLockPath -Repository $Repository
        $written = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$written.reservationToken -cne [string]$Value.reservationToken -or
            [string]$written.workerToken -cne [string]$Value.workerToken) {
            throw 'MOD reservation owner write did not preserve its guarded token tuple.'
        }
    }
    finally {
        if ($guardStream) { $guardStream.Dispose() }
    }
}

function Get-CurrentProcessIdentity {
    $process = Get-Process -Id $PID -ErrorAction Stop
    [ordered]@{
        machineName = [Environment]::MachineName
        processId = $PID
        processStartTicks = $process.StartTime.ToUniversalTime().Ticks
    }
}

function Test-ProcessIdentityActive {
    param([Collections.IDictionary] $Owner, [string] $ProcessIdField = 'processId', [string] $ProcessStartField = 'processStartTicks')
    if (-not $Owner -or [string]$Owner.machineName -cne [Environment]::MachineName -or
        -not $Owner.Contains($ProcessIdField) -or -not $Owner.Contains($ProcessStartField) -or
        -not $Owner[$ProcessIdField] -or -not $Owner[$ProcessStartField]) {
        return $false
    }
    try {
        $process = Get-Process -Id ([int]$Owner[$ProcessIdField]) -ErrorAction Stop
        $process.StartTime.ToUniversalTime().Ticks -eq [int64]$Owner[$ProcessStartField]
    }
    catch { $false }
}

$sharedCoordinationModulePath = Join-Path $PSScriptRoot 'SharedCoordinationLock.psm1'
Import-Module -Name $sharedCoordinationModulePath -Force -ErrorAction Stop

function Enter-SharedCoordinationLock {
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][ValidateSet('source-acquisition', 'git-coordination')][string] $ResourceKey,
        [Parameter(Mandatory)][string] $ActualRunId,
        [string] $ReceiptRoot,
        [ValidateRange(1, 3600)][int] $TimeoutSeconds = 300
    )
    $lease = Enter-SharedCoordinationLease -RepositoryRoot $Repository -ResourceKey $ResourceKey `
        -RunId $ActualRunId -ReceiptRoot $ReceiptRoot -WaitHeartbeatAction { Update-ActiveReservationHeartbeat } `
        -TimeoutSeconds $TimeoutSeconds
    $script:activeSharedCoordinationLease = $lease
    $lease
}

function Update-ActiveSharedCoordinationHeartbeat {
    param([switch] $Force)
    if (-not $script:activeSharedCoordinationLease) { return }
    Update-SharedCoordinationLease -Lease $script:activeSharedCoordinationLease -Force:$Force
}

function Exit-SharedCoordinationLock {
    param([Collections.IDictionary] $Lease)
    if (-not $Lease) { return $null }
    $receipt = Exit-SharedCoordinationLease -Lease $Lease
    if ($script:activeSharedCoordinationLease -and
        [string]$script:activeSharedCoordinationLease.token -ceq [string]$Lease.token) {
        $script:activeSharedCoordinationLease = $null
    }
    $receipt
}
function Read-State {
    param([Parameter(Mandatory)][string] $Path)
    $repositoryFull = [IO.Path]::GetFullPath($RepositoryRoot)
    $stateFull = [IO.Path]::GetFullPath($Path)
    $null = Assert-NoReparsePath -Path $stateFull -Root $repositoryFull -Label 'Run state'
    if (-not (Test-Path -LiteralPath $stateFull -PathType Leaf)) {
        throw "State file does not exist: $stateFull"
    }
    $state = Get-Content -LiteralPath $stateFull -Raw | ConvertFrom-Json -AsHashtable
    foreach ($field in @('repositoryRoot', 'statePath', 'runRoot')) {
        if (-not $state.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$state[$field])) { throw "Run state is missing $field." }
    }
    if ([IO.Path]::GetFullPath([string]$state.repositoryRoot) -cne $repositoryFull) {
        throw 'Run state repositoryRoot differs from the requested repository.'
    }
    if ([IO.Path]::GetFullPath([string]$state.statePath) -cne $stateFull) {
        throw 'Run state statePath differs from the file being read.'
    }
    $runRoot = [IO.Path]::GetFullPath([string]$state.runRoot)
    $null = Assert-NoReparsePath -Path $runRoot -Root $repositoryFull -Label 'Run root'
    $null = Assert-ContainedPath -Candidate $stateFull -Root $runRoot -Label 'Run state'
    if ($script:activeReservationLease -and [string]$state.runId -ceq [string]$script:activeReservationLease.runId) {
        $script:activeReservationState = $state
    }
    $state
}

function Save-State {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    Update-ActiveReservationHeartbeat -Force
    $State.updatedAt = Get-UtcTimestamp
    Write-AtomicJson -Path ([string]$State.statePath) -Value $State
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )
    $gitCommand = if ($Arguments.Count -gt 0) { [string]$Arguments[0] } else { '' }
    $gitSubcommand = if ($Arguments.Count -gt 1) { [string]$Arguments[1] } else { '' }
    $requiresCoordination = $gitCommand -in @('fetch', 'push') -or
        ($gitCommand -ceq 'worktree' -and $gitSubcommand -in @('add', 'remove', 'prune')) -or
        ($gitCommand -ceq 'branch' -and $gitSubcommand -in @('-d', '-D', '-m', '-M', '--delete', '--move'))
    $coordinationLease = $null
    try {
        if ($requiresCoordination) {
            $coordinationRunId = if ($script:activeReservationLease) { [string]$script:activeReservationLease.runId }
                elseif (-not [string]::IsNullOrWhiteSpace($RunId)) { [guid]::Parse($RunId).ToString() }
                else { 'unbound-' + [guid]::NewGuid().ToString('N') }
            $receiptRoot = if ($script:activeReservationState -and $script:activeReservationState.Contains('artifactsRoot')) {
                [string]$script:activeReservationState.artifactsRoot
            }
            else { $null }
            $coordinationLease = Enter-SharedCoordinationLock -Repository ([IO.Path]::GetFullPath($RepositoryRoot)) `
                -ResourceKey 'git-coordination' -ActualRunId $coordinationRunId -ReceiptRoot $receiptRoot
        }
        Update-ActiveReservationHeartbeat -Force
        Update-ActiveSharedCoordinationHeartbeat -Force
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = 'git'
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-C', $WorkingDirectory) + $Arguments) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'Unable to start Git.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        while (-not $process.WaitForExit(1000)) {
            Update-ActiveReservationHeartbeat
            Update-ActiveSharedCoordinationHeartbeat
        }
        $output = $stdoutTask.Result.TrimEnd()
        $warning = $stderrTask.Result.TrimEnd()
        $exitCode = $process.ExitCode
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "git $($Arguments -join ' ') failed ($exitCode): $warning $output"
        }
        [pscustomobject]@{
            exitCode = $exitCode
            output = $output
            warning = $warning
        }
    }
    finally {
        if ($coordinationLease) {
            $coordinationReceipt = Exit-SharedCoordinationLock -Lease $coordinationLease
            if ($coordinationReceipt -and $script:activeReservationState) {
                $priorReceipts = if ($script:activeReservationState.Contains('coordinationReceipts')) {
                    @($script:activeReservationState.coordinationReceipts)
                } else { @() }
                $script:activeReservationState.coordinationReceipts = @($priorReceipts + @($coordinationReceipt))
            }
        }
    }
}

function Assert-AppendOnlyPushArguments {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Remote,
        [Parameter(Mandatory)][string] $Branch
    )
    $expected = @('push', '--set-upstream', $Remote, $Branch)
    if ($Arguments.Count -ne $expected.Count) {
        throw 'Append-only publication requires one explicit branch push.'
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ($Arguments[$index] -cne $expected[$index]) {
            throw 'Append-only publication rejected unexpected Git push arguments.'
        }
    }
    foreach ($argument in $Arguments[2..3]) {
        if ($argument.StartsWith('-', [StringComparison]::Ordinal) -or $argument.StartsWith('+', [StringComparison]::Ordinal)) {
            throw 'Append-only publication rejected an option-like remote or branch.'
        }
    }
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $AllowFailure
    )
    Update-ActiveReservationHeartbeat -Force
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'gh'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start GitHub CLI.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit(1000)) {
        Update-ActiveReservationHeartbeat
        Update-ActiveSharedCoordinationHeartbeat
    }
    $result = [ordered]@{
        exitCode = $process.ExitCode
        output = $stdoutTask.Result.TrimEnd()
        warning = $stderrTask.Result.TrimEnd()
    }
    if ($result.exitCode -ne 0 -and -not $AllowFailure) {
        throw "gh $($Arguments -join ' ') failed ($($result.exitCode)): $($result.warning) $($result.output)"
    }
    $result
}

function Get-GitBlobBytes {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $Object
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory, 'cat-file', 'blob', $Object)) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start git cat-file.' }
    $memory = [IO.MemoryStream]::new()
    Copy-StreamWithHeartbeat -Source $process.StandardOutput.BaseStream -Destination $memory
    $errorText = $process.StandardError.ReadToEnd()
    while (-not $process.WaitForExit(1000)) { Update-ActiveReservationHeartbeat }
    if ($process.ExitCode -ne 0) { throw "git cat-file failed: $errorText" }
    $memory.ToArray()
}

function New-Manifest {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $OutputPath,
        [string] $Kind = 'files'
    )
    $rootFull = [IO.Path]::GetFullPath($Root)
    $files = @(
        Get-ChildItem -LiteralPath $rootFull -File -Recurse |
            ForEach-Object {
                $relative = [IO.Path]::GetRelativePath($rootFull, $_.FullName).Replace('\', '/')
                [ordered]@{
                    path = $relative
                    size = $_.Length
                    sha256 = Get-FileSha256 -Path $_.FullName
                }
            } |
            Sort-Object { $_.path }
    )
    $manifest = [ordered]@{
        schemaVersion = 1
        kind = $Kind
        root = $rootFull
        generatedAt = Get-UtcTimestamp
        files = $files
    }
    Write-AtomicJson -Path $OutputPath -Value $manifest
    [ordered]@{ path = $OutputPath; sha256 = Get-FileSha256 -Path $OutputPath; fileCount = $files.Count }
}

function Test-CrlfNormalizationOnly {
    param([byte[]] $RawBytes, [byte[]] $IndexedBytes)
    $normalized = [IO.MemoryStream]::new()
    for ($index = 0; $index -lt $RawBytes.LongLength; $index++) {
        if ($RawBytes[$index] -eq 13 -and ($index + 1) -lt $RawBytes.LongLength -and $RawBytes[$index + 1] -eq 10) {
            continue
        }
        $normalized.WriteByte($RawBytes[$index])
    }
    $candidate = $normalized.ToArray()
    if ($candidate.LongLength -ne $IndexedBytes.LongLength) { return $false }
    for ($index = 0; $index -lt $candidate.LongLength; $index++) {
        if ($candidate[$index] -ne $IndexedBytes[$index]) { return $false }
    }
    $true
}

function Get-StageArtifactPath {
    param([Collections.IDictionary] $State, [string] $Name)
    switch ($Name) {
        'acquire-source' { if ($State.sourceReceipt) { [string]$State.sourceReceipt.path } }
        'claim' { Join-Path ([string]$State.runRoot) 'claim.json' }
        'verify-source' { Join-Path ([string]$State.artifactsRoot) 'archive-listing.json' }
        'extract' { if ($State.extractionManifest) { [string]$State.extractionManifest.path } }
        'install' { if ($State.rawInstallManifest) { [string]$State.rawInstallManifest.path } }
        'localization' { [string]$State.localizationManifestPath }
        'build-commits' { if ($State.evidenceReceipt) { [string]$State.evidenceReceipt.path } }
        'validate' { if ($State.candidateGate) { [string]$State.candidateGate.validationReportPath } }
        'publish' { Join-Path ([string]$State.artifactsRoot) 'publication.json' }
        'review-snapshot' { Join-Path ([string]$State.artifactsRoot) 'review-completion-validation.json' }
    }
}

function New-GitNormalizationManifest {
    param([Collections.IDictionary] $State)
    $records = @()
    foreach ($file in Get-ChildItem -LiteralPath $State.installRoot -File -Recurse | Sort-Object FullName) {
        $relativeToRepository = [IO.Path]::GetRelativePath($State.worktreePath, $file.FullName).Replace('\', '/')
        $relativeToMod = [IO.Path]::GetRelativePath($State.installRoot, $file.FullName).Replace('\', '/')
        $rawBytes = Read-FileBytesWithHeartbeat -Path $file.FullName
        $blobOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.autocrlf=true', 'hash-object', '-w', "--path=$relativeToRepository", '--', $file.FullName)).output.Trim()
        $indexedBytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $blobOid
        $transform = if ((Get-Sha256Bytes -Bytes $rawBytes) -eq (Get-Sha256Bytes -Bytes $indexedBytes)) { 'none' }
            elseif (Test-CrlfNormalizationOnly -RawBytes $rawBytes -IndexedBytes $indexedBytes) { 'crlf-to-lf' }
            else { throw "Git clean processing changed bytes beyond CRLF-to-LF for $relativeToRepository." }
        $records += [ordered]@{
            path = $relativeToMod
            repositoryPath = $relativeToRepository
            rawSize = $rawBytes.LongLength
            rawSha256 = Get-Sha256Bytes -Bytes $rawBytes
            indexedSize = $indexedBytes.LongLength
            indexedSha256 = Get-Sha256Bytes -Bytes $indexedBytes
            blobOid = $blobOid
            transform = $transform
            whitespacePreserved = $true
        }
    }
    $path = Join-Path $State.artifactsRoot 'git-index-normalization.json'
    Write-AtomicJson -Path $path -Value ([ordered]@{
        schemaVersion = 1
        mode = 'git-add-autocrlf-v1'
        gitVersion = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('--version')).output
        coreAutocrlf = $true
        files = $records
    })
    [ordered]@{ path = $path; sha256 = Get-FileSha256 -Path $path; fileCount = $records.Count }
}

function New-GitTreeManifest {
    param([Collections.IDictionary] $State, [string] $CommitOid)
    $listing = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.quotePath=false', 'ls-tree', '-r', '-l', '--full-tree', $CommitOid, '--', $State.modRelativePath)).output
    $files = @()
    foreach ($line in @($listing -split "`r?`n" | Where-Object { $_ })) {
        if ($line -notmatch '^[0-7]{6} blob ([0-9a-f]{40})\s+(\d+)\t(.+)$') { throw "Unable to parse candidate Git tree entry: $line" }
        $repositoryPath = $Matches[3]
        $relative = $repositoryPath.Substring(([string]$State.modRelativePath).Length).TrimStart('/')
        $bytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $Matches[1]
        if ($bytes.LongLength -ne [int64]$Matches[2]) { throw "Candidate Git blob size mismatch: $repositoryPath" }
        $files += [ordered]@{
            path = $relative
            repositoryPath = $repositoryPath
            blobOid = $Matches[1]
            size = $bytes.LongLength
            sha256 = Get-Sha256Bytes -Bytes $bytes
        }
    }
    $path = Join-Path $State.artifactsRoot 'candidate-tree-manifest.json'
    Write-AtomicJson -Path $path -Value ([ordered]@{
        schemaVersion = 1
        kind = 'candidate-git-tree'
        commitOid = $CommitOid
        treeOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', "$CommitOid^{tree}")).output.Trim()
        files = @($files | Sort-Object { $_.path })
    })
    [ordered]@{ path = $path; sha256 = Get-FileSha256 -Path $path; fileCount = $files.Count }
}

function Start-Stage {
    param([string] $Name)
    [ordered]@{
        name = $Name
        startedAt = Get-UtcTimestamp
        stopwatch = [Diagnostics.Stopwatch]::StartNew()
    }
}

function Complete-Stage {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $Context,
        [Parameter(Mandatory)][string] $ArtifactSha256,
        [Collections.IDictionary] $Data = @{}
    )
    $Context.stopwatch.Stop()
    $name = [string]$Context.name
    if (-not $State.Contains('stageTimings')) { $State.stageTimings = [ordered]@{} }
    if (-not $State.Contains('completedStages')) { $State.completedStages = @() }
    $previousAttempt = if ($State.stageTimings.Contains($name)) { [int]$State.stageTimings[$name].attempt } else { 0 }
    $timing = [ordered]@{
        attempt = $previousAttempt + 1
        startedAt = $Context.startedAt
        completedAt = Get-UtcTimestamp
        activeMilliseconds = $Context.stopwatch.ElapsedMilliseconds
        waitingMilliseconds = 0
        result = 'passed'
        artifactSha256 = $ArtifactSha256
    }
    $State.stageTimings[$name] = $timing
    $State.completedStages = @($State.completedStages | Where-Object { $_ -ne $name }) + $name
    Save-State -State $State
    [ordered]@{
        result = 'passed'
        runId = $State.runId
        stage = $name
        status = $State.status
        statePath = $State.statePath
        stageTimings = $timing
        artifactSha256 = $ArtifactSha256
        data = $Data
    }
}

function Get-CompletedStageResult {
    param([Collections.IDictionary] $State, [string] $Name)
    if (@($State.completedStages) -contains $Name) {
        Assert-LockOwner -State $State
        $artifactPath = Get-StageArtifactPath -State $State -Name $Name
        if ([string]::IsNullOrWhiteSpace($artifactPath) -or -not (Test-Path -LiteralPath $artifactPath -PathType Leaf)) {
            throw "Completed stage $Name is missing its recorded artifact. Same-run recovery must stop instead of silently reusing it."
        }
        $expectedSha = [string]$State.stageTimings[$Name].artifactSha256
        if ((Get-FileSha256 -Path $artifactPath) -ne $expectedSha) {
            throw "Completed stage $Name artifact SHA-256 no longer matches its receipt."
        }
        if ($Name -in @('build-commits', 'validate', 'publish', 'review-snapshot')) {
            $head = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', 'HEAD')).output.Trim()
            if ($head -ne $State.evidenceChain.fOid) { throw "Completed stage $Name no longer points at immutable F." }
        }
        return [ordered]@{
            result = 'passed'
            idempotent = $true
            runId = $State.runId
            stage = $Name
            status = $State.status
            statePath = $State.statePath
            stageTimings = $State.stageTimings[$Name]
            artifactSha256 = $State.stageTimings[$Name].artifactSha256
            data = [ordered]@{ recovery = 'same run completed stage and artifact receipt verified' }
        }
    }
    $null
}

function Assert-LockOwner {
    param([Collections.IDictionary] $State)
    foreach ($field in @('repositoryRoot', 'repoModDirectory', 'mod', 'modRelativePath', 'runId', 'runRoot', 'artifactsRoot', 'statePath', 'modLockKey', 'modLockPath')) {
        if (-not $State.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$State[$field])) { throw "Run state is missing $field." }
    }
    $repository = [IO.Path]::GetFullPath([string]$State.repositoryRoot)
    if ($repository -cne [IO.Path]::GetFullPath($RepositoryRoot)) { throw 'Run state repositoryRoot differs from the requested repository.' }
    $expected = Get-ModRunPlan -Repository $repository -CanonicalModDirectory ([string]$State.repoModDirectory) -ActualRunId ([string]$State.runId)
    $expectedArtifactsRoot = [IO.Path]::GetFullPath((Join-Path ([string]$expected.runRoot) 'artifacts'))
    if ([string]$State.mod -cne [string]$State.repoModDirectory -or
        [string]$State.modRelativePath -cne [string]$expected.modRelativePath -or
        [IO.Path]::GetFullPath([string]$State.runRoot) -cne [string]$expected.runRoot -or
        [IO.Path]::GetFullPath([string]$State.artifactsRoot) -cne $expectedArtifactsRoot -or
        [string]$State.modLockKey -cne [string]$expected.lockKey -or
        [IO.Path]::GetFullPath([string]$State.modLockPath) -cne [string]$expected.modLockPath) {
        throw 'MOD identity lock path differs from the canonical reservation tuple.'
    }
    $owner = Read-ModReservationOwner -ModLockPath ([string]$State.modLockPath) -Repository $repository
    foreach ($field in @('runId', 'canonicalModRelativePath', 'modLockKey', 'plannedStatePath', 'statePath', 'reservationToken', 'leaseMode')) {
        if (-not $owner.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$owner[$field])) { throw "MOD identity lock owner is missing $field." }
    }
    $statePathFull = [IO.Path]::GetFullPath([string]$State.statePath)
    if ([string]$owner.runId -cne [string]$State.runId -or
        [string]$owner.canonicalModRelativePath -cne [string]$expected.modRelativePath -or
        [string]$owner.modLockKey -cne [string]$expected.lockKey -or
        [IO.Path]::GetFullPath([string]$owner.plannedStatePath) -cne $statePathFull -or
        [IO.Path]::GetFullPath([string]$owner.statePath) -cne $statePathFull) {
        throw 'MOD identity lock does not belong to this same run tuple.'
    }
    if ([int]$owner.schemaVersion -ne 2 -or [string]$owner.reservationToken -notmatch '^[0-9a-f]{32}$' -or
        [string]$owner.leaseMode -notin @('active', 'reserved')) {
        throw 'MOD identity lock owner contract is invalid.'
    }
}

function Get-ReservationStateLabel {
    param([Collections.IDictionary] $State)
    if (-not $State -or -not $State.Contains('status')) { return 'between-stages' }
    switch ([string]$State.status) {
        'waiting-input' { 'waiting-user' }
        'waiting-user' { 'waiting-user' }
        'waiting-system' { 'waiting-system' }
        'blocked' { 'waiting-user' }
        'awaiting-user-merge' { 'awaiting-user-merge' }
        default { 'between-stages' }
    }
}

function Enter-ModReservationWorker {
    param([Collections.IDictionary] $State)
    Assert-LockOwner -State $State
    $owner = Read-ModReservationOwner -ModLockPath ([string]$State.modLockPath) -Repository ([string]$State.repositoryRoot)
    $reservationToken = [string]$owner.reservationToken
    $previousWorkerToken = [string]$owner.workerToken
    $identity = Get-CurrentProcessIdentity
    $sameWorker = [string]$owner.leaseMode -ceq 'active' -and
        [string]$owner.machineName -ceq [string]$identity.machineName -and
        [int]$owner.workerId -eq [int]$identity.processId -and
        [int64]$owner.workerProcessStartTicks -eq [int64]$identity.processStartTicks -and
        [string]$owner.workerToken -match '^[0-9a-f]{32}$'

    if ([string]$owner.leaseMode -ceq 'active' -and -not $sameWorker) {
        foreach ($field in @('machineName', 'workerId', 'workerProcessStartTicks', 'workerToken', 'heartbeat')) {
            if (-not $owner.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$owner[$field])) {
                throw "Active MOD reservation owner is missing $field."
            }
        }
        $heartbeat = [DateTimeOffset]::MinValue
        $heartbeatValid = [DateTimeOffset]::TryParseExact(
            [string]$owner.heartbeat,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$heartbeat
        )
        $sameMachineWorkerActive = [string]$owner.machineName -ceq [Environment]::MachineName -and
            (Test-ProcessIdentityActive -Owner $owner -ProcessIdField 'workerId' -ProcessStartField 'workerProcessStartTicks')
        if (-not $heartbeatValid -or $sameMachineWorkerActive -or ([DateTimeOffset]::UtcNow - $heartbeat).TotalMinutes -le 30) {
            throw 'The same run reservation still has an active worker; reattachment requires a stale heartbeat and a dead process identity.'
        }
        $historyRoot = Join-Path ([string]$State.modLockPath) 'owner-history'
        New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
        $historyPath = Join-Path $historyRoot ("stale-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))-$([guid]::NewGuid().ToString('N')).json")
        Write-AtomicJson -Path $historyPath -Value $owner
        $State.lastRecovery = [ordered]@{ at = Get-UtcTimestamp; reason = 'stale same-run reservation worker reattached'; retainedPath = $historyPath }
    }
    elseif ([string]$owner.leaseMode -ceq 'reserved') {
        if (-not [string]::IsNullOrWhiteSpace([string]$owner.workerToken) -or $owner.workerId -or $owner.workerProcessStartTicks) {
            throw 'Reserved MOD owner must not retain an active worker identity.'
        }
    }

    if (-not $sameWorker) { $owner.workerToken = [guid]::NewGuid().ToString('N') }
    $owner.machineName = $identity.machineName
    $owner.workerId = $identity.processId
    $owner.workerProcessStartTicks = $identity.processStartTicks
    $owner.leaseMode = 'active'
    $owner.reservationState = 'running'
    $owner.heartbeat = Get-UtcTimestamp
    Write-ModReservationOwner -ModLockPath ([string]$State.modLockPath) -Repository ([string]$State.repositoryRoot) -Value $owner `
        -ExpectedReservationToken $reservationToken -ExpectedWorkerToken $previousWorkerToken
    $script:activeReservationLease = [ordered]@{
        modLockPath = [string]$State.modLockPath
        repositoryRoot = [string]$State.repositoryRoot
        runId = [string]$State.runId
        reservationToken = $reservationToken
        workerToken = [string]$owner.workerToken
        machineName = $identity.machineName
        workerId = $identity.processId
        workerProcessStartTicks = $identity.processStartTicks
        lastHeartbeatUtc = [DateTimeOffset]::UtcNow
    }
    $script:activeReservationState = $State
}

function Read-ActiveReservationOwner {
    if (-not $script:activeReservationLease) {
        throw 'An active immutable reservation lease is required for this owner operation.'
    }
    $lease = $script:activeReservationLease
    $owner = Read-ModReservationOwner -ModLockPath ([string]$lease.modLockPath) -Repository ([string]$lease.repositoryRoot)
    if ([string]$owner.runId -cne [string]$lease.runId -or
        [string]$owner.reservationToken -cne [string]$lease.reservationToken -or
        [string]$owner.workerToken -cne [string]$lease.workerToken -or
        [string]$owner.machineName -cne [string]$lease.machineName -or
        [int]$owner.workerId -ne [int]$lease.workerId -or
        [int64]$owner.workerProcessStartTicks -ne [int64]$lease.workerProcessStartTicks -or
        [string]$owner.leaseMode -cne 'active') {
        throw 'MOD reservation ownership changed after this worker acquired its immutable lease.'
    }
    $owner
}

function Write-ActiveReservationOwner {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Value,
        [switch] $ReleaseWorker
    )
    $lease = $script:activeReservationLease
    if (-not $lease) { throw 'An active immutable reservation lease is required for this owner update.' }
    $null = Read-ActiveReservationOwner
    if ([string]$Value.runId -cne [string]$lease.runId -or
        [string]$Value.reservationToken -cne [string]$lease.reservationToken) {
        throw 'Reservation owner update changed the immutable run or reservation token.'
    }
    if ($ReleaseWorker) {
        if ([string]$Value.leaseMode -cne 'reserved' -or
            -not [string]::IsNullOrWhiteSpace([string]$Value.workerToken) -or
            $Value.workerId -or $Value.workerProcessStartTicks -or $Value.machineName) {
            throw 'Reservation worker release must atomically clear its entire active identity.'
        }
    }
    elseif ([string]$Value.leaseMode -cne 'active' -or
        [string]$Value.workerToken -cne [string]$lease.workerToken -or
        [string]$Value.machineName -cne [string]$lease.machineName -or
        [int]$Value.workerId -ne [int]$lease.workerId -or
        [int64]$Value.workerProcessStartTicks -ne [int64]$lease.workerProcessStartTicks) {
        throw 'Reservation owner update changed the immutable active worker tuple.'
    }
    Write-ModReservationOwner -ModLockPath ([string]$lease.modLockPath) -Repository ([string]$lease.repositoryRoot) -Value $Value `
        -ExpectedReservationToken ([string]$lease.reservationToken) -ExpectedWorkerToken ([string]$lease.workerToken)
}

function Update-ActiveReservationHeartbeat {
    param([switch] $Force)
    if (-not $script:activeReservationLease) { return }
    $lease = $script:activeReservationLease
    if (-not $Force -and ([DateTimeOffset]::UtcNow - [DateTimeOffset]$lease.lastHeartbeatUtc).TotalSeconds -lt 30) { return }
    $owner = Read-ActiveReservationOwner
    $owner.heartbeat = Get-UtcTimestamp
    Write-ActiveReservationOwner -Value $owner
    $lease.lastHeartbeatUtc = [DateTimeOffset]::UtcNow
}

function Suspend-ModReservationWorker {
    param([Collections.IDictionary] $State)
    if (-not $script:activeReservationLease) { return }
    $lease = $script:activeReservationLease
    $owner = Read-ActiveReservationOwner
    $owner.leaseMode = 'reserved'
    $owner.reservationState = Get-ReservationStateLabel -State $State
    $owner.machineName = $null
    $owner.workerId = $null
    $owner.workerProcessStartTicks = $null
    $owner.workerToken = $null
    $owner.heartbeat = Get-UtcTimestamp
    Write-ActiveReservationOwner -Value $owner -ReleaseWorker
    $script:activeReservationLease = $null
    $script:activeReservationState = $null
}

function Test-RunWriterOwnerActive {
    param([Collections.IDictionary] $Owner)
    if ($Owner.machineName -cne [Environment]::MachineName -or -not $Owner.processId -or -not $Owner.processStartTicks) {
        return $false
    }
    try {
        $process = Get-Process -Id ([int]$Owner.processId) -ErrorAction Stop
        return $process.StartTime.ToUniversalTime().Ticks -eq [int64]$Owner.processStartTicks
    }
    catch { return $false }
}

function Enter-RunWriterLock {
    param([Collections.IDictionary] $State)
    Assert-LockOwner -State $State
    $lockPath = Join-Path ([string]$State.runRoot) '.writer.lock'
    $token = [guid]::NewGuid().ToString()
    $owner = [ordered]@{
        schemaVersion = 1
        runId = $State.runId
        statePath = $State.statePath
        token = $token
        machineName = [Environment]::MachineName
        processId = $PID
        processStartTicks = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
        acquiredAt = Get-UtcTimestamp
    }
    $ownerBytes = [Text.UTF8Encoding]::new($false).GetBytes(($owner | ConvertTo-Json -Depth 10))
    $pendingWriterRecovery = $null

    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        try {
            $stream = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $stream.Write($ownerBytes, 0, $ownerBytes.Length)
                $stream.Flush($true)
            }
            finally { $stream.Dispose() }
            return [ordered]@{ path = $lockPath; token = $token; recovery = $pendingWriterRecovery }
        }
        catch [IO.IOException] {
            if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { continue }
            try { $existing = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json -AsHashtable }
            catch { $existing = [ordered]@{} }
            if (Test-RunWriterOwnerActive -Owner $existing) {
                throw 'Another process is the active single writer for this run state.'
            }

            $recoveryRoot = Join-Path ([string]$State.artifactsRoot) 'writer-lock-recovery'
            New-Item -ItemType Directory -Path $recoveryRoot -Force | Out-Null
            $retainedPath = Join-Path $recoveryRoot ("stale-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))-$([guid]::NewGuid().ToString('N')).json")
            try { [IO.File]::Move($lockPath, $retainedPath) }
            catch [IO.IOException] { continue }
            $pendingWriterRecovery = [ordered]@{
                at = Get-UtcTimestamp
                reason = 'stale run writer lock retained'
                retainedPath = $retainedPath
            }
        }
    }
    throw 'Unable to acquire the single-writer lock for this run state.'
}

function Exit-RunWriterLock {
    param([Collections.IDictionary] $Lease)
    if (-not $Lease) { return }
    if (-not (Test-Path -LiteralPath $Lease.path -PathType Leaf)) {
        throw 'Run writer lock disappeared before its owner released it.'
    }
    $owner = Get-Content -LiteralPath $Lease.path -Raw | ConvertFrom-Json -AsHashtable
    if ($owner.token -cne $Lease.token) { throw 'Run writer lock ownership changed before release.' }
    [IO.File]::Delete([string]$Lease.path)
}

function Ensure-RunWriterLock {
    param([Collections.IDictionary] $State)
    $script:activeStatePath = [string]$State.statePath
    if (-not $script:writerLease) {
        $script:writerLease = Enter-RunWriterLock -State $State
        Enter-ModReservationWorker -State $State
        if ($script:writerLease.recovery) {
            $State.lastRecovery = $script:writerLease.recovery
            Save-State -State $State
        }
    }
}

function Get-ModRunPlan {
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $CanonicalModDirectory,
        [Parameter(Mandatory)][string] $ActualRunId
    )
    if ([string]::IsNullOrWhiteSpace($CanonicalModDirectory) -or $CanonicalModDirectory -cne $CanonicalModDirectory.Trim() -or
        [IO.Path]::IsPathRooted($CanonicalModDirectory) -or [IO.Path]::GetFileName($CanonicalModDirectory) -cne $CanonicalModDirectory -or
        $CanonicalModDirectory -in @('.', '..') -or $CanonicalModDirectory.TrimEnd([char[]]' .') -cne $CanonicalModDirectory -or
        $CanonicalModDirectory.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'Canonical MOD identity must be one safe single directory name.'
    }
    if ($CanonicalModDirectory -match '(?i)^(con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\..*)?$') {
        throw 'Canonical MOD identity uses a reserved Windows device name.'
    }
    $queueRoot = Join-Path $Repository 'AI Auto Update'
    $slug = ConvertTo-SafeSlug -Value $CanonicalModDirectory
    $short = $ActualRunId.Replace('-', '').Substring(0, 8)
    $modRelativePath = "Warhammer 40,000 DARKTIDE/mods/$CanonicalModDirectory"
    $lockKey = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($modRelativePath.ToLowerInvariant()))
    $runName = if ($CanonicalModDirectory.ToLowerInvariant() -ceq $slug) {
        "$slug-$short"
    }
    else {
        "$slug-$($lockKey.Substring(0, 16))-$short"
    }
    $runRoot = Join-Path (Join-Path $queueRoot 'In Progress') $runName
    [ordered]@{
        repositoryRoot = [IO.Path]::GetFullPath($Repository)
        queueRoot = [IO.Path]::GetFullPath($queueRoot)
        slug = $slug
        short = $short
        runRoot = [IO.Path]::GetFullPath($runRoot)
        modRelativePath = $modRelativePath
        lockKey = $lockKey
        modLockPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $queueRoot 'In Progress/.locks/mod') "$lockKey.lock"))
    }
}

function Enter-ModReservation {
    param(
        [Collections.IDictionary] $Plan,
        [string] $ActualRunId,
        [string] $PlannedStatePath
    )
    $lockRoot = Split-Path -Parent ([string]$Plan.modLockPath)
    $null = Assert-NoReparsePath -Path $lockRoot -Root ([string]$Plan.repositoryRoot) -Label 'MOD reservation path' -AllowMissing
    New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
    $null = Assert-NoReparsePath -Path $lockRoot -Root ([string]$Plan.repositoryRoot) -Label 'MOD reservation path'
    $expectedStatePath = [IO.Path]::GetFullPath($PlannedStatePath)
    if (-not (Test-Path -LiteralPath ([string]$Plan.modLockPath) -PathType Container)) {
        $preparedLockPath = Join-Path $lockRoot ('.pending-' + [IO.Path]::GetFileName([string]$Plan.modLockPath) + '-' + $ActualRunId + '-' + [guid]::NewGuid().ToString('N'))
        $null = Assert-NoReparsePath -Path $preparedLockPath -Root ([string]$Plan.repositoryRoot) -Label 'Prepared MOD reservation' -AllowMissing
        New-Item -ItemType Directory -Path $preparedLockPath -ErrorAction Stop | Out-Null
        $identity = Get-CurrentProcessIdentity
        $preparedOwner = [ordered]@{
            schemaVersion = 2
            runId = $ActualRunId
            canonicalModRelativePath = $Plan.modRelativePath
            modLockKey = $Plan.lockKey
            plannedStatePath = $expectedStatePath
            statePath = $expectedStatePath
            reservationToken = [guid]::NewGuid().ToString('N')
            workerToken = [guid]::NewGuid().ToString('N')
            machineName = $identity.machineName
            workerId = $identity.processId
            workerProcessStartTicks = $identity.processStartTicks
            leaseMode = 'active'
            reservationState = 'claiming'
            acquiredAt = Get-UtcTimestamp
            heartbeat = Get-UtcTimestamp
        }
        Write-ModReservationOwner -ModLockPath $preparedLockPath -Repository ([string]$Plan.repositoryRoot) -Value $preparedOwner
        try {
            $null = Assert-NoReparsePath -Path $preparedLockPath -Root ([string]$Plan.repositoryRoot) -Label 'Prepared MOD reservation'
            [IO.Directory]::Move($preparedLockPath, [string]$Plan.modLockPath)
        }
        catch {
            if (-not (Test-Path -LiteralPath ([string]$Plan.modLockPath) -PathType Container)) { throw }
        }
        finally {
            if (Test-Path -LiteralPath $preparedLockPath -PathType Container) {
                $null = Assert-NoReparsePath -Path $preparedLockPath -Root ([string]$Plan.repositoryRoot) -Label 'Unpublished prepared MOD reservation'
                $preparedItems = @(Get-ChildItem -LiteralPath $preparedLockPath -Force)
                if ($preparedItems.Count -eq 1 -and -not $preparedItems[0].PSIsContainer -and
                    $preparedItems[0].Name -ceq 'owner.json' -and -not ($preparedItems[0].Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    [IO.File]::Delete($preparedItems[0].FullName)
                    [IO.Directory]::Delete($preparedLockPath)
                }
            }
        }
    }
    $null = Assert-NoReparsePath -Path ([string]$Plan.modLockPath) -Root ([string]$Plan.repositoryRoot) -Label 'MOD reservation'
    try { $owner = Read-ModReservationOwner -ModLockPath ([string]$Plan.modLockPath) -Repository ([string]$Plan.repositoryRoot) }
    catch { throw 'Another generation owns an incomplete canonical MOD reservation.' }
    if ([string]$owner.runId -cne $ActualRunId) { throw 'Another generation already owns this canonical MOD identity.' }
    if (-not $owner.Contains('canonicalModRelativePath') -or [string]$owner.canonicalModRelativePath -cne [string]$Plan.modRelativePath -or
        -not $owner.Contains('modLockKey') -or [string]$owner.modLockKey -cne [string]$Plan.lockKey -or
        -not $owner.Contains('plannedStatePath') -or [IO.Path]::GetFullPath([string]$owner.plannedStatePath) -cne $expectedStatePath -or
        -not $owner.Contains('statePath') -or [IO.Path]::GetFullPath([string]$owner.statePath) -cne $expectedStatePath) {
        throw 'Existing canonical MOD reservation owner tuple changed.'
    }
    if ([int]$owner.schemaVersion -ne 2 -or [string]$owner.reservationToken -notmatch '^[0-9a-f]{32}$') {
        throw 'Existing canonical MOD reservation owner token contract is invalid.'
    }
    $expectedReservationToken = [string]$owner.reservationToken
    $expectedWorkerToken = [string]$owner.workerToken
    $identity = Get-CurrentProcessIdentity
    $sameWorker = [string]$owner.leaseMode -ceq 'active' -and [string]$owner.machineName -ceq [string]$identity.machineName -and
        [int]$owner.workerId -eq [int]$identity.processId -and [int64]$owner.workerProcessStartTicks -eq [int64]$identity.processStartTicks
    if ([string]$owner.leaseMode -ceq 'active' -and -not $sameWorker) {
        foreach ($field in @('machineName', 'workerId', 'workerProcessStartTicks', 'workerToken', 'heartbeat')) {
            if (-not $owner.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$owner[$field])) {
                throw "Active canonical MOD reservation owner is missing $field."
            }
        }
        if ([string]$owner.workerToken -notmatch '^[0-9a-f]{32}$') { throw 'Active canonical MOD reservation worker token is invalid.' }
        $heartbeat = [DateTimeOffset]::MinValue
        $heartbeatValid = [DateTimeOffset]::TryParseExact(
            [string]$owner.heartbeat,
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$heartbeat
        )
        $workerActive = Test-ProcessIdentityActive -Owner $owner -ProcessIdField 'workerId' -ProcessStartField 'workerProcessStartTicks'
        if ($workerActive -or -not $heartbeatValid -or ([DateTimeOffset]::UtcNow - $heartbeat).TotalMinutes -le 30) {
            throw 'The same run reservation still has an active worker; only a stale same-run owner may reattach.'
        }
        $historyRoot = Join-Path ([string]$Plan.modLockPath) 'owner-history'
        New-Item -ItemType Directory -Path $historyRoot -Force | Out-Null
        $historyPath = Join-Path $historyRoot ("stale-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))-$([guid]::NewGuid().ToString('N')).json")
        Write-AtomicJson -Path $historyPath -Value $owner
        $owner.lastRecovery = [ordered]@{ at = Get-UtcTimestamp; reason = 'stale same-run reservation worker reattached'; retainedPath = $historyPath }
    }
    elseif ([string]$owner.leaseMode -ceq 'reserved' -and
        (-not [string]::IsNullOrWhiteSpace([string]$owner.workerToken) -or $owner.workerId -or $owner.workerProcessStartTicks -or $owner.machineName)) {
        throw 'Reserved canonical MOD owner retains a contradictory active worker identity.'
    }
    $owner.modLockKey = $Plan.lockKey
    $owner.plannedStatePath = [IO.Path]::GetFullPath($PlannedStatePath)
    $owner.statePath = [IO.Path]::GetFullPath($PlannedStatePath)
    $owner.workerToken = if ($sameWorker) { $owner.workerToken } else { [guid]::NewGuid().ToString('N') }
    $owner.machineName = $identity.machineName
    $owner.workerId = $identity.processId
    $owner.workerProcessStartTicks = $identity.processStartTicks
    $owner.leaseMode = 'active'
    $owner.reservationState = 'claiming'
    $owner.heartbeat = Get-UtcTimestamp
    Write-ModReservationOwner -ModLockPath ([string]$Plan.modLockPath) -Repository ([string]$Plan.repositoryRoot) -Value $owner `
        -ExpectedReservationToken $expectedReservationToken -ExpectedWorkerToken $expectedWorkerToken
    $script:activeReservationLease = [ordered]@{
        modLockPath = [string]$Plan.modLockPath
        repositoryRoot = [string]$Plan.repositoryRoot
        runId = $ActualRunId
        reservationToken = [string]$owner.reservationToken
        workerToken = [string]$owner.workerToken
        machineName = [string]$owner.machineName
        workerId = [int]$owner.workerId
        workerProcessStartTicks = [int64]$owner.workerProcessStartTicks
        lastHeartbeatUtc = [DateTimeOffset]::UtcNow
    }
    $owner
}

function Assert-Schema15BaseLocalizationEligibility {
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $BaseOid,
        [Parameter(Mandatory)][string] $ModRelativePath
    )
    $listing = (Invoke-Git -WorkingDirectory $Repository -Arguments @(
        'ls-tree', '-r', '--name-only', $BaseOid, '--', $ModRelativePath
    )).output
    $localizationPaths = @(
        $listing -split "`r?`n" |
            Where-Object { $_ -and [IO.Path]::GetFileName($_) -like '*_localization.lua' } |
            Sort-Object -Unique
    )
    if ($localizationPaths.Count -eq 0) { return }
    if ($localizationPaths.Count -ne 1) { throw 'AUTOMATION_BLOCKED: localization_entry_not_unique' }

    Import-Module (Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1') -Force -ErrorAction Stop
    foreach ($path in $localizationPaths) {
        $blobOid = (Invoke-Git -WorkingDirectory $Repository -Arguments @('rev-parse', "$BaseOid`:$path")).output.Trim()
        $bytes = Get-GitBlobBytes -WorkingDirectory $Repository -Object $blobOid
        $document = Get-LuaLocalizationDocument -Bytes $bytes -SourceId $path
        if (@($document.units).Count -eq 0 -and [bool]$document.isIoDofileOnlyLoader) {
            throw "AUTOMATION_EXCLUDED: localization_entry_is_loader ($path)"
        }
        if (@($document.units).Count -eq 0) { throw "AUTOMATION_BLOCKED: localization_structure_not_static ($path)" }
    }
}

function Test-SourceRequestPreflight {
    param([Parameter(Mandatory)][string] $Path)
    $full = [IO.Path]::GetFullPath($Path)
    $null = Assert-NoReparsePath -Path $full -Root ([IO.Path]::GetPathRoot($full)) -Label 'Source request'
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw 'Source request does not exist.' }
    $request = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$request.schemaVersion -notin @(1, 2)) { throw 'Source request schemaVersion must be 1 or 2.' }
    foreach ($field in @('gameDomain', 'modId', 'mainFileId', 'version', 'fileName', 'pageUrl')) {
        if (-not $request.Contains($field) -or [string]::IsNullOrWhiteSpace([Convert]::ToString($request[$field], [Globalization.CultureInfo]::InvariantCulture))) {
            throw "Source request requires a unique $field value."
        }
    }
    $pageUri = [Uri]([string]$request.pageUrl)
    if (-not $pageUri.IsAbsoluteUri -or $pageUri.Scheme -cne 'https') { throw 'Source request pageUrl must be an absolute HTTPS URL.' }
    if (-not [string]::IsNullOrEmpty($pageUri.UserInfo) -or -not [string]::IsNullOrEmpty($pageUri.Query) -or
        -not [string]::IsNullOrEmpty($pageUri.Fragment) -or -not $pageUri.IsDefaultPort) {
        throw 'Source request pageUrl must be a canonical page URL without user-info, query, fragment, or a custom port.'
    }
    $expectedGameDomain = 'warhammer40kdarktide'
    $expectedPagePath = "/$expectedGameDomain/mods/$([Convert]::ToString($request.modId, [Globalization.CultureInfo]::InvariantCulture))"
    if ([string]$request.gameDomain -cne $expectedGameDomain -or
        $pageUri.Host -notin @('nexusmods.com', 'www.nexusmods.com') -or
        $pageUri.AbsolutePath.TrimEnd('/') -cne $expectedPagePath) {
        throw 'Source request must identify the official Nexus MOD page for warhammer40kdarktide.'
    }
    $requestedFileName = [string]$request.fileName
    if ([IO.Path]::GetFileName($requestedFileName) -cne $requestedFileName -or
        $requestedFileName.TrimEnd([char[]]' .') -cne $requestedFileName -or
        $requestedFileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        throw 'Source request fileName must be one safe single file name.'
    }
    if ($requestedFileName -match '(?i)^(con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\..*)?$') {
        throw 'Source request fileName uses a reserved Windows device name.'
    }
    if ($request.Contains('officialSha256') -and -not [string]::IsNullOrWhiteSpace([string]$request.officialSha256) -and
        [string]$request.officialSha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'officialSha256 must contain 64 hexadecimal characters.'
    }
    $extension = [IO.Path]::GetExtension([string]$request.fileName).ToLowerInvariant()
    if ($extension -cne '.zip') {
        return [ordered]@{
            result = 'waiting'; status = 'waiting-user'
            waitingReason = [ordered]@{ code = 'unsupported_archive_format'; message = 'Only ZIP Main files are supported in Schema 15.' }
            archiveFormat = $extension.TrimStart('.'); sourceRequestPath = $full
        }
    }
    [ordered]@{ result = 'passed'; status = 'eligible'; sourceRequestPath = $full }
}

function Complete-InterruptedSourceDelivery {
    param(
        [Parameter(Mandatory)][string] $ReceiptPath,
        [Parameter(Mandatory)][string] $SourceRequestPath,
        [Parameter(Mandatory)][string] $IncomingDirectory,
        [Parameter(Mandatory)][string] $DeliveryDirectory,
        [Parameter(Mandatory)][string] $RunRoot,
        [Parameter(Mandatory)][string] $RepositoryRoot
    )
    foreach ($boundary in @(
        [ordered]@{ path = $ReceiptPath; label = 'Interrupted source receipt'; allowMissing = $false },
        [ordered]@{ path = $SourceRequestPath; label = 'Interrupted source request'; allowMissing = $false },
        [ordered]@{ path = $IncomingDirectory; label = 'Interrupted incoming directory'; allowMissing = $true },
        [ordered]@{ path = $DeliveryDirectory; label = 'Interrupted delivery directory'; allowMissing = $true }
    )) {
        $null = Assert-NoReparsePath -Path ([string]$boundary.path) -Root $RepositoryRoot -Label ([string]$boundary.label) -AllowMissing:([bool]$boundary.allowMissing)
        $null = Assert-ContainedPath -Candidate ([string]$boundary.path) -Root $RunRoot -Label ([string]$boundary.label)
    }
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
    if ([string]$receipt.status -cne 'verified') { return $false }
    $request = Get-Content -LiteralPath $SourceRequestPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($field in @('gameDomain', 'modId', 'mainFileId', 'version', 'fileName')) {
        if ([Convert]::ToString($receipt.sourceRequest[$field], [Globalization.CultureInfo]::InvariantCulture) -cne
            [Convert]::ToString($request[$field], [Globalization.CultureInfo]::InvariantCulture)) {
            throw "Interrupted source delivery $field no longer matches its request."
        }
    }
    if ([string]$receipt.archiveFormat -cne 'zip' -or [string]$receipt.filename -cne [string]$request.fileName -or
        [string]$receipt.sha256 -notmatch '^[0-9a-f]{64}$' -or [int64]$receipt.size -le 0) {
        throw 'Interrupted source delivery receipt is not a verified ZIP tuple.'
    }
    $incomingCandidate = [IO.Path]::GetFullPath((Join-Path $IncomingDirectory ([string]$receipt.filename)))
    $deliveredCandidate = [IO.Path]::GetFullPath((Join-Path $DeliveryDirectory ([string]$receipt.filename)))
    $incomingExists = Test-Path -LiteralPath $incomingCandidate -PathType Leaf
    $deliveredExists = Test-Path -LiteralPath $deliveredCandidate -PathType Leaf
    if ($incomingExists -and $deliveredExists) { throw 'Interrupted source delivery has both incoming and delivered copies.' }
    if (-not $incomingExists -and -not $deliveredExists) { throw 'Interrupted source delivery has no recoverable file.' }
    $candidate = if ($deliveredExists) { $deliveredCandidate } else { $incomingCandidate }
    $null = Assert-NoReparsePath -Path $candidate -Root $RepositoryRoot -Label 'Interrupted source file'
    $candidateSize = (Get-Item -LiteralPath $candidate).Length
    $candidateSha256 = Get-FileSha256 -Path $candidate
    if ([int64]$candidateSize -ne [int64]$receipt.size -or $candidateSha256 -cne [string]$receipt.sha256) {
        throw 'Interrupted source delivery file no longer matches its receipt.'
    }
    if ($incomingExists) {
        if (-not (Test-Path -LiteralPath $DeliveryDirectory -PathType Container)) {
            $null = Assert-NoReparsePath -Path (Split-Path -Parent $DeliveryDirectory) -Root $RepositoryRoot -Label 'Interrupted delivery parent'
            New-Item -ItemType Directory -Path $DeliveryDirectory | Out-Null
        }
        $null = Assert-NoReparsePath -Path $DeliveryDirectory -Root $RepositoryRoot -Label 'Interrupted delivery directory'
        $null = Assert-NoReparsePath -Path $incomingCandidate -Root $RepositoryRoot -Label 'Interrupted incoming source'
        $null = Assert-NoReparsePath -Path $deliveredCandidate -Root $RepositoryRoot -Label 'Interrupted delivered source' -AllowMissing
        Update-ActiveReservationHeartbeat -Force
        [IO.File]::Move($incomingCandidate, $deliveredCandidate)
    }
    $receipt.status = 'delivered'
    $receipt.deliveredAt = Get-UtcTimestamp
    $receipt.deliveredPath = $deliveredCandidate
    $receipt.deliveryRecovery = [ordered]@{ recoveredAt = Get-UtcTimestamp; reason = 'verified receipt delivery interruption' }
    $null = Assert-NoReparsePath -Path $ReceiptPath -Root $RepositoryRoot -Label 'Interrupted source receipt'
    Write-AtomicJson -Path $ReceiptPath -Value $receipt
    $true
}

function Invoke-AcquireSource {
    if ([string]::IsNullOrWhiteSpace($ModDirectory) -or [string]::IsNullOrWhiteSpace($SourceRequestPath)) {
        throw 'acquire-source requires -ModDirectory and -SourceRequestPath.'
    }
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $actualRunId = if ($RunId) { [guid]::Parse($RunId).ToString() } else { [guid]::NewGuid().ToString() }
    $plan = Get-ModRunPlan -Repository $repository -CanonicalModDirectory $ModDirectory -ActualRunId $actualRunId
    $plannedStatePath = Join-Path ([string]$plan.runRoot) 'state.json'
    $preflight = Test-SourceRequestPreflight -Path $SourceRequestPath
    if ($preflight.status -ne 'eligible') {
        return [ordered]@{
            result = $preflight.result; status = $preflight.status; runId = $actualRunId; stage = 'acquire-source'
            plannedStatePath = $plannedStatePath; runRoot = $plan.runRoot; modLockPath = $null
            deliveredPath = $null; receiptPath = $null; receiptSha256 = $null
            sourceRequestPath = $preflight.sourceRequestPath; sourceRequestSha256 = Get-FileSha256 -Path $preflight.sourceRequestPath
            acquisitionPath = $null; acquisitionSha256 = $null; waitingReason = $preflight.waitingReason; timings = $null
        }
    }
    $integrityScript = Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1'
    $plannedPinPath = Join-Path ([string]$plan.runRoot) 'review-artifacts/skill-source-pin.json'
    $pinInputPath = if (-not [string]::IsNullOrWhiteSpace($SkillSourcePinPath)) { [IO.Path]::GetFullPath($SkillSourcePinPath) }
        elseif (Test-Path -LiteralPath $plannedPinPath -PathType Leaf) { [IO.Path]::GetFullPath($plannedPinPath) }
        else { $null }
    if (-not $pinInputPath) {
        return [ordered]@{
            result = 'waiting'; status = 'waiting-user'; runId = $actualRunId; stage = 'acquire-source'
            plannedStatePath = $plannedStatePath; runRoot = $plan.runRoot; modLockPath = $null
            deliveredPath = $null; receiptPath = $null; receiptSha256 = $null
            sourceRequestPath = $preflight.sourceRequestPath; sourceRequestSha256 = Get-FileSha256 -Path $preflight.sourceRequestPath
            acquisitionPath = $null; acquisitionSha256 = $null
            waitingReason = [ordered]@{ code = 'skill_source_pin_required'; message = 'A verified immutable darktide-translate Skill source pin is required before acquisition.' }
            timings = $null
        }
    }
    try { $acquisitionIntegrity = & $integrityScript -SkillSourcePinPath $pinInputPath -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru }
    catch {
        return [ordered]@{
            result = 'waiting'; status = 'waiting-user'; runId = $actualRunId; stage = 'acquire-source'
            plannedStatePath = $plannedStatePath; runRoot = $plan.runRoot; modLockPath = $null
            deliveredPath = $null; receiptPath = $null; receiptSha256 = $null
            sourceRequestPath = $preflight.sourceRequestPath; sourceRequestSha256 = Get-FileSha256 -Path $preflight.sourceRequestPath
            acquisitionPath = $null; acquisitionSha256 = $null
            waitingReason = [ordered]@{ code = 'skill_source_pin_invalid'; message = $_.Exception.Message }
            timings = $null
        }
    }
    if ($acquisitionIntegrity.result -cne 'passed' -or -not $acquisitionIntegrity.skillSourcePin) { throw 'Skill source pin verification did not return a bound source tuple.' }
    $null = Assert-NoReparsePath -Path ([string]$plan.runRoot) -Root $repository -Label 'Source acquisition run root' -AllowMissing
    $null = Assert-NoReparsePath -Path ([string]$plan.modLockPath) -Root $repository -Label 'Source acquisition reservation' -AllowMissing
    $null = Enter-ModReservation -Plan $plan -ActualRunId $actualRunId -PlannedStatePath $plannedStatePath
    $reviewArtifacts = Join-Path ([string]$plan.runRoot) 'review-artifacts'
    $incoming = Join-Path ([string]$plan.runRoot) ".incoming-$actualRunId"
    $delivery = Join-Path ([string]$plan.runRoot) 'verified-source'
    $receiptPath = Join-Path $reviewArtifacts 'source-receipt.json'
    $null = Assert-NoReparsePath -Path $reviewArtifacts -Root $repository -Label 'Source acquisition review artifacts' -AllowMissing
    New-Item -ItemType Directory -Path $reviewArtifacts -Force | Out-Null
    $null = Assert-NoReparsePath -Path $reviewArtifacts -Root $repository -Label 'Source acquisition review artifacts'
    $null = Assert-NoReparsePath -Path $pinInputPath -Root ([IO.Path]::GetPathRoot($pinInputPath)) -Label 'Supplied Skill source pin'
    $pinBytes = Read-FileBytesWithHeartbeat -Path $pinInputPath
    if (Test-Path -LiteralPath $plannedPinPath -PathType Leaf) {
        if ((Get-FileSha256 -Path $plannedPinPath) -cne (Get-Sha256Bytes -Bytes $pinBytes)) { throw 'Same-run Skill source pin evidence already exists with different bytes.' }
    }
    elseif ([IO.Path]::GetFullPath($pinInputPath) -cne [IO.Path]::GetFullPath($plannedPinPath)) {
        Write-AtomicBytes -Path $plannedPinPath -Bytes $pinBytes
    }
    $acquisitionIntegrity = & $integrityScript -SkillSourcePinPath $plannedPinPath -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
    $boundSkillSourcePin = $acquisitionIntegrity.skillSourcePin
    $reservationOwner = Read-ActiveReservationOwner
    $reservationOwner.workflowCommitOid = $boundSkillSourcePin.resolvedCommit
    $reservationOwner.skillSourceContentSha256 = $boundSkillSourcePin.contentSha256
    $reservationOwner.skillSourcePinSha256 = $boundSkillSourcePin.pinSha256
    Write-ActiveReservationOwner -Value $reservationOwner
    $suppliedRequestPath = [IO.Path]::GetFullPath($SourceRequestPath)
    $null = Assert-NoReparsePath -Path $suppliedRequestPath -Root ([IO.Path]::GetPathRoot($suppliedRequestPath)) -Label 'Supplied source request'
    $boundRequestPath = Join-Path $reviewArtifacts 'source-request.json'
    $suppliedRequestBytes = Read-FileBytesWithHeartbeat -Path $suppliedRequestPath
    if (Test-Path -LiteralPath $boundRequestPath -PathType Leaf) {
        if ((Get-FileSha256 -Path $boundRequestPath) -cne (Get-Sha256Bytes -Bytes $suppliedRequestBytes)) {
            throw 'Same-run source request evidence already exists with different bytes.'
        }
    }
    elseif ($suppliedRequestPath -cne [IO.Path]::GetFullPath($boundRequestPath)) {
        $temporaryRequestPath = Join-Path $reviewArtifacts ('.source-request-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllBytes($temporaryRequestPath, $suppliedRequestBytes)
        $null = Get-Content -LiteralPath $temporaryRequestPath -Raw | ConvertFrom-Json -AsHashtable
        Update-ActiveReservationHeartbeat -Force
        [IO.File]::Move($temporaryRequestPath, $boundRequestPath)
    }
    $boundSourceRequest = Get-Content -LiteralPath $boundRequestPath -Raw | ConvertFrom-Json -AsHashtable
    $boundSourceIdentity = ConvertTo-NexusSourceIdentity -Request $boundSourceRequest
    $acquisitionPath = Join-Path $reviewArtifacts 'source-acquisition.json'
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        $preservedReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$preservedReceipt.status -ceq 'verified') {
            $null = Complete-InterruptedSourceDelivery -ReceiptPath $receiptPath -SourceRequestPath $boundRequestPath -IncomingDirectory $incoming -DeliveryDirectory $delivery -RunRoot ([string]$plan.runRoot) -RepositoryRoot $repository
            $preservedReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        }
        if ([string]$preservedReceipt.status -cne 'delivered') {
            $receiptSha = Get-FileSha256 -Path $receiptPath
            $requestSha = Get-FileSha256 -Path $boundRequestPath
            $retainedPath = [IO.Path]::GetFullPath((Join-Path $incoming ([string]$preservedReceipt.filename)))
            $receiptVerifier = Join-Path $PSScriptRoot 'Test-SourceReceipt.ps1'
            $retainedVerification = & $receiptVerifier -ReceiptPath $receiptPath -SourceRequestPath $boundRequestPath `
                -RunRoot ([string]$plan.runRoot) -RetainedPath $retainedPath -AllowNonDelivered `
                -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
            if ($retainedVerification.result -cne 'passed' -or -not $retainedVerification.recoveryResult) {
                throw 'Preserved non-delivered source receipt failed independent recovery verification.'
            }
            $verifiedResult = $retainedVerification.recoveryResult
            if (Test-Path -LiteralPath $acquisitionPath -PathType Leaf) {
                $record = Get-Content -LiteralPath $acquisitionPath -Raw | ConvertFrom-Json -AsHashtable
            }
            else {
                $record = [ordered]@{
                    schemaVersion = 1
                    workflowSchemaVersion = 15
                    runId = $actualRunId
                    mod = $ModDirectory
                    acquisitionMethod = "nexus-$Provider"
                    nexus = $boundSourceIdentity
                    sourceRequestPath = [IO.Path]::GetFullPath($boundRequestPath)
                    sourceRequestSha256 = $requestSha
                    skillSourcePinPath = [IO.Path]::GetFullPath($plannedPinPath)
                    skillSourcePinSha256 = Get-FileSha256 -Path $plannedPinPath
                    skillSourceCommit = $boundSkillSourcePin.resolvedCommit
                    skillSourceContentSha256 = $boundSkillSourcePin.contentSha256
                    result = $verifiedResult
                    receiptPath = [IO.Path]::GetFullPath($receiptPath)
                    receiptSha256 = $receiptSha
                    recordedAt = Get-UtcTimestamp
                    recovered = $true
                }
                Write-AtomicJson -Path $acquisitionPath -Value $record
            }
            $recordResultJson = $record.result | ConvertTo-Json -Depth 20 -Compress
            $verifiedResultJson = $verifiedResult | ConvertTo-Json -Depth 20 -Compress
            if ([int]$record.schemaVersion -ne 1 -or [int]$record.workflowSchemaVersion -ne 15 -or
                [string]$record.runId -cne $actualRunId -or [string]$record.mod -cne $ModDirectory -or
                [string]$record.sourceRequestPath -cne [IO.Path]::GetFullPath($boundRequestPath) -or
                [string]$record.sourceRequestSha256 -cne $requestSha -or
                [string]$record.receiptPath -cne [IO.Path]::GetFullPath($receiptPath) -or [string]$record.receiptSha256 -cne $receiptSha -or
                [string]$record.skillSourcePinPath -cne [IO.Path]::GetFullPath($plannedPinPath) -or
                [string]$record.skillSourcePinSha256 -cne [string]$boundSkillSourcePin.pinSha256 -or
                [string]$record.skillSourceCommit -cne [string]$boundSkillSourcePin.resolvedCommit -or
                [string]$record.skillSourceContentSha256 -cne [string]$boundSkillSourcePin.contentSha256 -or
                $recordResultJson -cne $verifiedResultJson) {
                throw 'Preserved non-delivered acquisition record changed.'
            }
            $owner = Read-ActiveReservationOwner
            $owner.waitingReason = $verifiedResult.waitingReason
            $owner.heartbeat = Get-UtcTimestamp
            Write-ActiveReservationOwner -Value $owner
            $script:activeReservationState = [ordered]@{ status = [string]$verifiedResult.status }
            return [ordered]@{
                result = $verifiedResult.result; status = $verifiedResult.status; idempotent = $true; runId = $actualRunId; stage = 'acquire-source'
                plannedStatePath = $plannedStatePath; runRoot = $plan.runRoot; modLockPath = $plan.modLockPath
                deliveredPath = $null; receiptPath = [IO.Path]::GetFullPath($receiptPath); receiptSha256 = $receiptSha
                sourceRequestPath = [IO.Path]::GetFullPath($boundRequestPath); sourceRequestSha256 = $requestSha
                acquisitionPath = $acquisitionPath; acquisitionSha256 = Get-FileSha256 -Path $acquisitionPath
                waitingReason = $verifiedResult.waitingReason; timings = if ($preservedReceipt.Contains('timings')) { $preservedReceipt.timings } else { $null }
            }
        }
        $receiptVerifier = Join-Path $PSScriptRoot 'Test-SourceReceipt.ps1'
        $verification = & $receiptVerifier -ReceiptPath $receiptPath -SourceRequestPath $boundRequestPath `
            -RunRoot ([string]$plan.runRoot) -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
        if ($verification.result -cne 'passed') { throw 'Preserved source receipt failed same-run acquisition recovery.' }
        $preservedReceipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        $receiptSha = Get-FileSha256 -Path $receiptPath
        $requestSha = Get-FileSha256 -Path $boundRequestPath
        $recoveredResult = [ordered]@{
            result = 'passed'; status = 'delivered'; deliveredPath = [IO.Path]::GetFullPath([string]$preservedReceipt.deliveredPath)
            receiptPath = [IO.Path]::GetFullPath($receiptPath); receiptSha256 = $receiptSha; timings = $preservedReceipt.timings
        }
        if (Test-Path -LiteralPath $acquisitionPath -PathType Leaf) {
            $record = Get-Content -LiteralPath $acquisitionPath -Raw | ConvertFrom-Json -AsHashtable
            $recordResultJson = $record.result | ConvertTo-Json -Depth 20 -Compress
            $recoveredResultJson = $recoveredResult | ConvertTo-Json -Depth 20 -Compress
            if ([int]$record.schemaVersion -ne 1 -or [int]$record.workflowSchemaVersion -ne 15 -or
                [string]$record.runId -cne $actualRunId -or [string]$record.mod -cne $ModDirectory -or
                [string]$record.sourceRequestPath -cne [IO.Path]::GetFullPath($boundRequestPath) -or
                [string]$record.sourceRequestSha256 -cne $requestSha -or
                [string]$record.receiptPath -cne [IO.Path]::GetFullPath($receiptPath) -or
                [string]$record.receiptSha256 -cne $receiptSha -or
                [string]$record.skillSourcePinPath -cne [IO.Path]::GetFullPath($plannedPinPath) -or
                [string]$record.skillSourcePinSha256 -cne [string]$boundSkillSourcePin.pinSha256 -or
                [string]$record.skillSourceCommit -cne [string]$boundSkillSourcePin.resolvedCommit -or
                [string]$record.skillSourceContentSha256 -cne [string]$boundSkillSourcePin.contentSha256 -or
                $recordResultJson -cne $recoveredResultJson) {
                throw 'Preserved acquisition record does not match the same-run recovery tuple.'
            }
        }
        else {
            $record = [ordered]@{
                schemaVersion = 1; workflowSchemaVersion = 15; runId = $actualRunId; mod = $ModDirectory
                acquisitionMethod = "nexus-$Provider"; nexus = $boundSourceIdentity
                sourceRequestPath = [IO.Path]::GetFullPath($boundRequestPath); sourceRequestSha256 = $requestSha
                skillSourcePinPath = [IO.Path]::GetFullPath($plannedPinPath); skillSourcePinSha256 = Get-FileSha256 -Path $plannedPinPath
                skillSourceCommit = $boundSkillSourcePin.resolvedCommit; skillSourceContentSha256 = $boundSkillSourcePin.contentSha256
                result = $recoveredResult; receiptPath = [IO.Path]::GetFullPath($receiptPath); receiptSha256 = $receiptSha
                recordedAt = Get-UtcTimestamp; recovered = $true
            }
            Write-AtomicJson -Path $acquisitionPath -Value $record
        }
        $owner = Read-ActiveReservationOwner
        $owner.sourceReceiptSha256 = $receiptSha
        $owner.sourceSha256 = [string]$preservedReceipt.sha256
        $owner.heartbeat = Get-UtcTimestamp
        Write-ActiveReservationOwner -Value $owner
        return [ordered]@{
            result = 'passed'; status = 'delivered'; idempotent = $true; runId = $actualRunId; stage = 'acquire-source'
            plannedStatePath = $plannedStatePath; runRoot = $plan.runRoot; modLockPath = $plan.modLockPath
            deliveredPath = [IO.Path]::GetFullPath([string]$preservedReceipt.deliveredPath)
            receiptPath = [IO.Path]::GetFullPath($receiptPath); receiptSha256 = $receiptSha
            sourceRequestPath = [IO.Path]::GetFullPath($boundRequestPath); sourceRequestSha256 = $requestSha
            acquisitionPath = $acquisitionPath; acquisitionSha256 = Get-FileSha256 -Path $acquisitionPath
            waitingReason = $null; timings = $preservedReceipt.timings
        }
    }
    $receiver = Join-Path $PSScriptRoot 'Receive-NexusMainFile.ps1'
    $arguments = @{
        SourceRequestPath = [IO.Path]::GetFullPath($boundRequestPath)
        IncomingDirectory = $incoming
        DeliveryDirectory = $delivery
        Provider = $Provider
        ReceiptPath = $receiptPath
        RunRoot = [string]$plan.runRoot
        ObservationIntervalMilliseconds = $ObservationIntervalMilliseconds
        HeartbeatAction = { Update-ActiveReservationHeartbeat }
        PassThru = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($DownloadedFilePath)) { $arguments.DownloadedFilePath = [IO.Path]::GetFullPath($DownloadedFilePath) }
    $acquired = & $receiver @arguments
    $record = [ordered]@{
        schemaVersion = 1
        workflowSchemaVersion = 15
        runId = $actualRunId
        mod = $ModDirectory
        acquisitionMethod = "nexus-$Provider"
        nexus = $boundSourceIdentity
        sourceRequestPath = [IO.Path]::GetFullPath($boundRequestPath)
        sourceRequestSha256 = Get-FileSha256 -Path ([IO.Path]::GetFullPath($boundRequestPath))
        skillSourcePinPath = [IO.Path]::GetFullPath($plannedPinPath)
        skillSourcePinSha256 = Get-FileSha256 -Path $plannedPinPath
        skillSourceCommit = $boundSkillSourcePin.resolvedCommit
        skillSourceContentSha256 = $boundSkillSourcePin.contentSha256
        result = $acquired
        receiptPath = if (Test-Path -LiteralPath $receiptPath -PathType Leaf) { [IO.Path]::GetFullPath($receiptPath) } else { $null }
        receiptSha256 = if (Test-Path -LiteralPath $receiptPath -PathType Leaf) { Get-FileSha256 -Path $receiptPath } else { $null }
        recordedAt = Get-UtcTimestamp
    }
    Write-AtomicJson -Path $acquisitionPath -Value $record
    $owner = Read-ActiveReservationOwner
    if ($acquired.status -eq 'delivered') {
        $owner.sourceReceiptSha256 = $record.receiptSha256
        $owner.sourceSha256 = (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable).sha256
    }
    else {
        $owner.waitingReason = $acquired.waitingReason
    }
    $owner.heartbeat = Get-UtcTimestamp
    Write-ActiveReservationOwner -Value $owner
    if ($acquired.status -ne 'delivered') { $script:activeReservationState = [ordered]@{ status = [string]$acquired.status } }
    [ordered]@{
        result = $acquired.result
        status = $acquired.status
        runId = $actualRunId
        stage = 'acquire-source'
        plannedStatePath = $plannedStatePath
        runRoot = $plan.runRoot
        modLockPath = $plan.modLockPath
        deliveredPath = if ($acquired.status -eq 'delivered') { $acquired.deliveredPath } else { $null }
        receiptPath = $record.receiptPath
        receiptSha256 = $record.receiptSha256
        sourceRequestPath = $record.sourceRequestPath
        sourceRequestSha256 = $record.sourceRequestSha256
        acquisitionPath = $acquisitionPath
        acquisitionSha256 = Get-FileSha256 -Path $acquisitionPath
        waitingReason = if ($acquired.status -ne 'delivered') { $acquired.waitingReason } else { $null }
        timings = if ($acquired.Contains('timings')) { $acquired.timings } else { $null }
    }
}

function Complete-IncompleteClaim {
    param([Collections.IDictionary] $State)
    Assert-LockOwner -State $State
    $stage = Start-Stage -Name 'claim'
    $isRecovery = -not [string]::IsNullOrWhiteSpace([string]$State.claimAttemptedAt)
    $State.claimAttemptedAt = Get-UtcTimestamp
    Save-State -State $State
    $repository = [string]$State.repositoryRoot
    $worktree = [string]$State.worktreePath
    $worktreeParent = Split-Path -Parent $worktree
    New-Item -ItemType Directory -Path $worktreeParent -Force | Out-Null

    if (Test-Path -LiteralPath $worktree -PathType Container) {
        $head = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $branch = (Invoke-Git -WorkingDirectory $worktree -Arguments @('branch', '--show-current')).output.Trim()
        if ($head -ne $State.baseOid -or $branch -cne $State.branch) {
            throw 'Incomplete claim worktree does not match its immutable base and branch tuple.'
        }
    }
    else {
        $branchExists = (Invoke-Git -WorkingDirectory $repository -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$($State.branch)") -AllowFailure).exitCode -eq 0
        $arguments = if ($branchExists) {
            @('worktree', 'add', $worktree, [string]$State.branch)
        }
        else {
            @('worktree', 'add', '-b', [string]$State.branch, $worktree, [string]$State.baseOid)
        }
        $null = Invoke-Git -WorkingDirectory $repository -Arguments $arguments
    }

    $coordinatorArchive = [string]$State.claimCoordinatorArchivePath
    $claimedArchive = [string]$State.archive.path
    if (-not (Test-Path -LiteralPath $claimedArchive -PathType Leaf)) {
        $sourceLease = Enter-SharedCoordinationLock -Repository $repository -ResourceKey 'source-acquisition' `
            -ActualRunId ([string]$State.runId) -ReceiptRoot ([string]$State.artifactsRoot)
        try {
            if (-not (Test-Path -LiteralPath $coordinatorArchive -PathType Leaf) -and
                -not (Test-Path -LiteralPath $claimedArchive -PathType Leaf) -and
                $State.archive.Contains('originalPath') -and
                (Test-Path -LiteralPath ([string]$State.archive.originalPath) -PathType Leaf)) {
                if ($State.archive.Contains('preserveOriginal') -and $State.archive.preserveOriginal) {
                    Copy-FileWithHeartbeat -SourcePath ([string]$State.archive.originalPath) -DestinationPath $coordinatorArchive
                }
                else {
                    Update-ActiveReservationHeartbeat -Force
                    Update-ActiveSharedCoordinationHeartbeat -Force
                    [IO.File]::Move([string]$State.archive.originalPath, $coordinatorArchive)
                }
            }
            if (Test-Path -LiteralPath $coordinatorArchive -PathType Leaf) {
                if (Test-Path -LiteralPath $claimedArchive) { throw 'Incomplete claim has both coordinator and run-owned archive copies.' }
                Update-ActiveReservationHeartbeat -Force
                Update-ActiveSharedCoordinationHeartbeat -Force
                [IO.File]::Move($coordinatorArchive, $claimedArchive)
            }
        }
        finally {
            $recoveryCoordinationReceipt = Exit-SharedCoordinationLock -Lease $sourceLease
            $priorCoordinationReceipts = if ($State.Contains('coordinationReceipts')) { @($State.coordinationReceipts) } else { @() }
            $State.coordinationReceipts = @($priorCoordinationReceipts + @($recoveryCoordinationReceipt))
        }
    }
    $claimedArchiveItem = Get-Item -LiteralPath $claimedArchive -ErrorAction SilentlyContinue
    if ($claimedArchiveItem -and ($claimedArchiveItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Claimed archive must be a regular file, not a reparse point.'
    }
    if (-not (Test-Path -LiteralPath $claimedArchive -PathType Leaf) -or (Get-FileSha256 -Path $claimedArchive) -ne $State.archive.sha256) {
        throw 'Incomplete claim archive is missing or no longer matches its source SHA-256.'
    }

    $owner = Read-ActiveReservationOwner
    $owner.worktree = $State.worktreePath
    $owner.heartbeat = Get-UtcTimestamp
    Write-ActiveReservationOwner -Value $owner

    $claimRecord = Get-Content -LiteralPath $State.claimPath -Raw | ConvertFrom-Json -AsHashtable
    $claimRecord.status = 'worktree-ready'
    $claimRecord.statePath = $State.statePath
    $claimRecord.archive = $State.archive
    Write-AtomicJson -Path $State.claimPath -Value $claimRecord
    $runClaimPath = Join-Path ([string]$State.runRoot) 'claim.json'
    Write-AtomicJson -Path $runClaimPath -Value $claimRecord
    $State.status = 'worktree-ready'
    $State.lastRecovery = if ($isRecovery) {
        [ordered]@{ at = Get-UtcTimestamp; reason = 'incomplete claim reattached to original run tuple'; retainedPath = $State.claimPath }
    }
    else { $State.lastRecovery }
    $claimSha = Get-FileSha256 -Path $runClaimPath
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $claimSha -Data ([ordered]@{ branch = $State.branch; worktreePath = $worktree })
}

function Invoke-Claim {
    if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
        $existing = Read-State -Path ([IO.Path]::GetFullPath($StatePath))
        if ($RunId -and $existing.runId -ne [guid]::Parse($RunId).ToString()) { throw 'Existing state belongs to another run.' }
        if ($ModDirectory -and $existing.repoModDirectory -cne $ModDirectory) { throw 'Existing state belongs to another MOD identity.' }
        if ([IO.Path]::GetFullPath($RepositoryRoot) -ne [IO.Path]::GetFullPath([string]$existing.repositoryRoot)) {
            throw 'Existing state belongs to another repository.'
        }
        $completed = Get-CompletedStageResult -State $existing -Name 'claim'
        if ($completed) { return $completed }
        return Complete-IncompleteClaim -State $existing
    }
    if ([string]::IsNullOrWhiteSpace($ArchivePath) -or [string]::IsNullOrWhiteSpace($ModDirectory) -or
        [string]::IsNullOrWhiteSpace($SourceRequestPath)) {
        throw 'claim requires -ArchivePath, -ModDirectory, and a complete -SourceRequestPath Nexus Main file tuple.'
    }
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $actualRunId = if ($RunId) { [guid]::Parse($RunId).ToString() } else { [guid]::NewGuid().ToString() }
    $plan = Get-ModRunPlan -Repository $repository -CanonicalModDirectory $ModDirectory -ActualRunId $actualRunId
    $queueRoot = [string]$plan.queueRoot
    $slug = [string]$plan.slug
    $short = [string]$plan.short
    $runRoot = [string]$plan.runRoot
    $null = Assert-NoReparsePath -Path $runRoot -Root $repository -Label 'Claim run root' -AllowMissing
    $integrityScript = Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1'
    $boundPinPath = Join-Path $runRoot 'review-artifacts/skill-source-pin.json'
    $pinInputPath = if (Test-Path -LiteralPath $boundPinPath -PathType Leaf) { [IO.Path]::GetFullPath($boundPinPath) }
        elseif (-not [string]::IsNullOrWhiteSpace($SkillSourcePinPath)) { [IO.Path]::GetFullPath($SkillSourcePinPath) }
        else { $null }
    if (-not $pinInputPath) { throw 'claim requires -SkillSourcePinPath for a new immutable Skill source tuple.' }
    if ((Test-Path -LiteralPath $boundPinPath -PathType Leaf) -and -not [string]::IsNullOrWhiteSpace($SkillSourcePinPath) -and
        (Get-FileSha256 -Path $boundPinPath) -cne (Get-FileSha256 -Path ([IO.Path]::GetFullPath($SkillSourcePinPath)))) {
        throw 'Supplied Skill source pin differs from the same-run bound pin.'
    }
    $integrity = & $integrityScript -SkillSourcePinPath $pinInputPath -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
    if ($integrity.result -cne 'passed' -or -not $integrity.skillSourcePin) { throw 'The immutable Skill source pin or packaged references failed integrity validation.' }
    $sourceReceipt = $null
    $sourceAcquisitionRecord = $null
    $sourceIdentity = $null
    $sourceRequestInputFull = $null
    if (-not [string]::IsNullOrWhiteSpace($SourceReceiptPath)) {
        if ([string]::IsNullOrWhiteSpace($SourceRequestPath)) { throw 'Receipt-bound claim requires -SourceRequestPath.' }
        $receiptFull = Assert-ContainedPath -Candidate $SourceReceiptPath -Root $runRoot -Label 'Source receipt path'
        $requestFull = Assert-ContainedPath -Candidate $SourceRequestPath -Root $runRoot -Label 'Source request path'
        $null = Assert-NoReparsePath -Path $receiptFull -Root $repository -Label 'Source receipt path'
        $null = Assert-NoReparsePath -Path $requestFull -Root $repository -Label 'Source request path'
        if ($requestFull -cne [IO.Path]::GetFullPath((Join-Path $runRoot 'review-artifacts/source-request.json'))) {
            throw 'Receipt-bound claim requires the run-archived source request.'
        }
        $sourceRequestInputFull = $requestFull
        $sourceRequestData = Get-Content -LiteralPath $requestFull -Raw | ConvertFrom-Json -AsHashtable
        $sourceIdentity = ConvertTo-NexusSourceIdentity -Request $sourceRequestData -RequireMetadata
        $acquisitionFull = [IO.Path]::GetFullPath((Join-Path $runRoot 'review-artifacts/source-acquisition.json'))
        $null = Assert-NoReparsePath -Path $acquisitionFull -Root $repository -Label 'Source acquisition record'
        if (-not (Test-Path -LiteralPath $acquisitionFull -PathType Leaf)) { throw 'Schema 15 acquisition record is missing.' }
        $acquisitionSha = Get-FileSha256 -Path $acquisitionFull
        $acquisition = Get-Content -LiteralPath $acquisitionFull -Raw | ConvertFrom-Json -AsHashtable
        $requestSha = Get-FileSha256 -Path $requestFull
        $receiptSha = Get-FileSha256 -Path $receiptFull
        if ([string]$acquisition.runId -cne $actualRunId -or [string]$acquisition.mod -cne $ModDirectory -or
            [string]$acquisition.sourceRequestPath -cne $requestFull -or [string]$acquisition.sourceRequestSha256 -cne $requestSha -or
            [string]$acquisition.receiptPath -cne $receiptFull -or [string]$acquisition.receiptSha256 -cne $receiptSha -or
            [string]$acquisition.result.status -cne 'delivered') {
            throw 'Schema 15 acquisition record no longer matches the run request and receipt tuple.'
        }
        try { $acquisitionOwner = Read-ModReservationOwner -ModLockPath ([string]$plan.modLockPath) -Repository ([string]$plan.repositoryRoot) }
        catch { throw 'Schema 15 acquisition reservation owner is missing or unsafe.' }
        $receiptPreview = Get-Content -LiteralPath $receiptFull -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$acquisitionOwner.runId -cne $actualRunId -or
            [string]$acquisitionOwner.sourceReceiptSha256 -cne $receiptSha -or
            [string]$acquisitionOwner.sourceSha256 -cne [string]$receiptPreview.sha256 -or
            [string]$acquisitionOwner.workflowCommitOid -cne [string]$integrity.skillSourcePin.resolvedCommit -or
            [string]$acquisitionOwner.skillSourceContentSha256 -cne [string]$integrity.skillSourcePin.contentSha256 -or
            [string]$acquisitionOwner.skillSourcePinSha256 -cne [string]$integrity.skillSourcePin.pinSha256) {
            throw 'Schema 15 acquisition record differs from the MOD reservation owner.'
        }
        $receiptVerifier = Join-Path $PSScriptRoot 'Test-SourceReceipt.ps1'
        $receiptVerification = & $receiptVerifier -ReceiptPath $receiptFull -SourceRequestPath $requestFull `
            -RunRoot $runRoot -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
        if ($receiptVerification.result -ne 'passed') { throw 'Independent source receipt verification failed.' }
        $receipt = Get-Content -LiteralPath $receiptFull -Raw | ConvertFrom-Json -AsHashtable
        $expectedAcquisitionResult = [ordered]@{
            result = 'passed'; status = 'delivered'; deliveredPath = [IO.Path]::GetFullPath([string]$receipt.deliveredPath)
            receiptPath = $receiptFull; receiptSha256 = $receiptSha; timings = $receipt.timings
        }
        if (($acquisition.result | ConvertTo-Json -Depth 20 -Compress) -cne
            ($expectedAcquisitionResult | ConvertTo-Json -Depth 20 -Compress)) {
            throw 'Schema 15 acquisition result differs from the independently verified receipt.'
        }
        $sourceFull = Assert-ContainedPath -Candidate ([string]$receipt.deliveredPath) -Root (Join-Path $runRoot 'verified-source') -Label 'Verified source path'
        $null = Assert-NoReparsePath -Path $sourceFull -Root $repository -Label 'Verified source path'
        if ([IO.Path]::GetFullPath($ArchivePath) -ne $sourceFull) { throw 'ArchivePath does not match the verified source receipt.' }
        $sampleOne = Get-Item -LiteralPath $sourceFull
        $sampleTwo = $sampleOne
        $sourceReceipt = [ordered]@{
            path = $receiptFull
            sha256 = Get-FileSha256 -Path $receiptFull
            sourceRequestPath = $requestFull
            sourceRequestSha256 = Get-FileSha256 -Path $requestFull
            verification = $receiptVerification
            provider = $receipt.provider
            sourceRequest = $receipt.sourceRequest
            timings = $receipt.timings
            startedAt = $receipt.stableObservations[0].observedAt
            completedAt = $receipt.deliveredAt
        }
        $sourceAcquisitionRecord = [ordered]@{
            recordPath = $acquisitionFull
            recordSha256 = $acquisitionSha
            sourceRequestPath = $requestFull
            sourceRequestSha256 = $requestSha
            receiptPath = $receiptFull
            receiptSha256 = $receiptSha
        }
        if ([string]$acquisition.skillSourcePinPath -cne [IO.Path]::GetFullPath($boundPinPath) -or
            [string]$acquisition.skillSourcePinSha256 -cne [string]$integrity.skillSourcePin.pinSha256 -or
            [string]$acquisition.skillSourceCommit -cne [string]$integrity.skillSourcePin.resolvedCommit -or
            [string]$acquisition.skillSourceContentSha256 -cne [string]$integrity.skillSourcePin.contentSha256) {
            throw 'Schema 15 acquisition record no longer matches its immutable Skill source pin.'
        }
    }
    else {
        $sourceRequestInputFull = [IO.Path]::GetFullPath($SourceRequestPath)
        $null = Assert-NoReparsePath -Path $sourceRequestInputFull -Root ([IO.Path]::GetPathRoot($sourceRequestInputFull)) -Label 'Manual source request'
        if (-not (Test-Path -LiteralPath $sourceRequestInputFull -PathType Leaf)) { throw 'Manual source request is missing.' }
        $sourceRequestData = Get-Content -LiteralPath $sourceRequestInputFull -Raw | ConvertFrom-Json -AsHashtable
        $sourceIdentity = ConvertTo-NexusSourceIdentity -Request $sourceRequestData -RequireMetadata
        $sourceFull = Assert-ContainedPath -Candidate $ArchivePath -Root $queueRoot -Label 'Archive path'
        if ((Split-Path -Parent $sourceFull) -ne [IO.Path]::GetFullPath($queueRoot)) {
            throw 'Archive must be a direct child of AI Auto Update.'
        }
        if (-not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) { throw 'Archive is missing.' }
        $null = Assert-NoReparsePath -Path $sourceFull -Root $repository -Label 'Source archive'
        $sampleOne = Get-Item -LiteralPath $sourceFull
        if ($sampleOne.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Source archive must be a regular file, not a reparse point.'
        }
        for ($second = 0; $second -lt 10; $second++) {
            [Threading.Thread]::Sleep(1000)
            Update-ActiveReservationHeartbeat
        }
        $null = Assert-NoReparsePath -Path $sourceFull -Root $repository -Label 'Source archive'
        $sampleTwo = Get-Item -LiteralPath $sourceFull
        if ($sampleOne.Length -ne $sampleTwo.Length -or $sampleOne.LastWriteTimeUtc -ne $sampleTwo.LastWriteTimeUtc) {
            throw 'Archive did not remain stable across the required ten-second observation.'
        }
    }
    if ($sampleOne.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source archive must be a regular file, not a reparse point.' }
    $actualStatePath = if ($StatePath) { Assert-ContainedPath -Candidate $StatePath -Root $runRoot -Label 'State path' } else { Join-Path $runRoot 'state.json' }
    if (Test-Path -LiteralPath $actualStatePath -PathType Leaf) {
        $existing = Read-State -Path $actualStatePath
        if ($existing.runId -ne $actualRunId) { throw 'Existing state belongs to another run.' }
        Ensure-RunWriterLock -State $existing
        $completed = Get-CompletedStageResult -State $existing -Name 'claim'
        if ($completed) { return $completed }
        return Complete-IncompleteClaim -State $existing
    }

    $null = Assert-NoReparsePath -Path $sourceFull -Root $repository -Label 'Source archive'
    $archiveSha = Get-FileSha256 -Path $sourceFull
    $reviewArtifacts = Join-Path $runRoot 'review-artifacts'
    New-Item -ItemType Directory -Path $reviewArtifacts -Force | Out-Null
    if (-not (Test-Path -LiteralPath $boundPinPath -PathType Leaf)) {
        Write-AtomicBytes -Path $boundPinPath -Bytes (Read-FileBytesWithHeartbeat -Path $pinInputPath)
        $integrity = & $integrityScript -SkillSourcePinPath $boundPinPath -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
    }
    if ((Get-FileSha256 -Path $boundPinPath) -cne [string]$integrity.skillSourcePin.pinSha256) { throw 'Bound Skill source pin bytes changed before claim.' }
    $boundSourceRequestPath = Join-Path $reviewArtifacts 'source-request.json'
    if ([IO.Path]::GetFullPath($sourceRequestInputFull) -cne [IO.Path]::GetFullPath($boundSourceRequestPath)) {
        $requestBytes = Read-FileBytesWithHeartbeat -Path $sourceRequestInputFull
        if (Test-Path -LiteralPath $boundSourceRequestPath -PathType Leaf) {
            if ((Get-FileSha256 -Path $boundSourceRequestPath) -cne (Get-Sha256Bytes -Bytes $requestBytes)) {
                throw 'Run-bound source request already exists with different bytes.'
            }
        }
        else { Write-AtomicBytes -Path $boundSourceRequestPath -Bytes $requestBytes }
    }
    $sourceTuplePath = Join-Path $reviewArtifacts 'source-tuple.json'
    $sourceTuple = New-SourceTupleEvidence -OutputPath $sourceTuplePath -ActualRunId $actualRunId `
        -AcquisitionMethod $(if ($sourceReceipt) { "nexus-$($sourceReceipt.provider)" } else { 'manual-queue' }) `
        -NexusIdentity $sourceIdentity -ArchiveFileName ([IO.Path]::GetFileName($sourceFull)) `
        -ArchiveSize ([int64]$sampleTwo.Length) -ArchiveSha256 $archiveSha -BoundSourceRequestPath $boundSourceRequestPath `
        -BoundSourceReceiptPath $(if ($sourceReceipt) { [string]$sourceReceipt.path } else { $null })

    $baseOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', '--verify', "$BaseRef^{commit}")).output.Trim()
    $baseTreeOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', "$baseOid^{tree}")).output.Trim()
    if ($sourceReceipt) {
        Assert-Schema15BaseLocalizationEligibility -Repository $repository -BaseOid $baseOid -ModRelativePath ([string]$plan.modRelativePath)
    }
    $branch = "Update/$slug/$([DateTimeOffset]::Now.ToString('yyyyMMdd'))-$short"
    $worktreeParent = if ([string]::IsNullOrWhiteSpace($WorktreeParent)) {
        Join-Path (Split-Path -Parent $repository) ((Split-Path -Leaf $repository) + '-worktrees')
    }
    else { [IO.Path]::GetFullPath($WorktreeParent) }
    New-Item -ItemType Directory -Path $worktreeParent -Force | Out-Null
    $worktree = Join-Path $worktreeParent "$slug-$short"

    $claimRoot = Join-Path (Join-Path $queueRoot '.claims') $actualRunId
    $claimSourceRoot = Join-Path $claimRoot 'source'
    $claimPath = Join-Path $claimRoot 'claim.json'
    $coordinatorArchive = Join-Path $claimSourceRoot ([IO.Path]::GetFileName($sourceFull))
    $modRelativePath = [string]$plan.modRelativePath
    $lockKey = [string]$plan.lockKey
    $modLockPath = [string]$plan.modLockPath
    $skillSourcePin = $integrity.skillSourcePin
    $workflowSourceEntry = Get-SkillSourceFileEntry -SkillSourcePin $skillSourcePin -RepositoryPath ([string]$integrity.workflow.path)
    $reviewSourceEntry = Get-SkillSourceFileEntry -SkillSourcePin $skillSourcePin -RepositoryPath ([string]$integrity.reviewBaseline.path)
    $bindingSourceEntry = Get-SkillSourceFileEntry -SkillSourcePin $skillSourcePin -RepositoryPath '.agents/skills/auto-update-darktide-mod/references/package-binding.md'
    $skillSourceEntry = Get-SkillSourceFileEntry -SkillSourcePin $skillSourcePin -RepositoryPath '.agents/skills/auto-update-darktide-mod/SKILL.md'
    $schema15SourceEntry = if ($sourceReceipt) { Get-SkillSourceFileEntry -SkillSourcePin $skillSourcePin -RepositoryPath ([string]$integrity.schema15.path) } else { $null }
    $plannedOwner = Enter-ModReservation -Plan $plan -ActualRunId $actualRunId -PlannedStatePath $actualStatePath
    $plannedOwner.workflowCommitOid = $skillSourcePin.resolvedCommit
    $plannedOwner.skillSourceContentSha256 = $skillSourcePin.contentSha256
    $plannedOwner.skillSourcePinSha256 = $skillSourcePin.pinSha256
    $plannedOwner.sourceSha256 = $archiveSha
    $plannedOwner.sourceTupleContractSha256 = $sourceTuple.contractSha256
    $plannedOwner.claimPath = [IO.Path]::GetFullPath($claimPath)
    $plannedOwner.worktree = $null
    Write-ActiveReservationOwner -Value $plannedOwner
    New-Item -ItemType Directory -Path $claimSourceRoot -Force | Out-Null
    $claimRecord = [ordered]@{
        runId = $actualRunId
        status = 'identified'
        workflowCommitOid = $skillSourcePin.resolvedCommit
        skillSourceContentSha256 = $skillSourcePin.contentSha256
        skillSourcePinPath = [IO.Path]::GetFullPath($boundPinPath)
        skillSourcePinSha256 = $skillSourcePin.pinSha256
        workflowSha256 = $integrity.workflow.sha256
        schema15Sha256 = if ($sourceReceipt) { $integrity.schema15.sha256 } else { $null }
        reviewBaselineSha256 = $integrity.reviewBaseline.sha256
        createdAt = Get-UtcTimestamp
        waitingReason = $null
        repoModDirectory = $ModDirectory
        modLockKey = $lockKey
        canonicalModRelativePath = $modRelativePath
        plannedStatePath = [IO.Path]::GetFullPath($actualStatePath)
        sourceReceipt = $sourceReceipt
        sourceTuple = $sourceTuple
        archive = [ordered]@{
            filename = [IO.Path]::GetFileName($coordinatorArchive)
            originalPath = $sourceFull
            path = [IO.Path]::GetFullPath($coordinatorArchive)
            size = $sampleTwo.Length
            sha256 = $archiveSha
            format = if ($sourceReceipt) { 'zip' } else { 'zip' }
            preserveOriginal = [bool]$sourceReceipt
        }
    }
    Write-AtomicJson -Path $claimPath -Value $claimRecord

    New-Item -ItemType Directory -Path (Join-Path $runRoot 'source') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runRoot 'staging') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $runRoot 'artifacts') -Force | Out-Null
    $claimedArchive = Join-Path (Join-Path $runRoot 'source') ([IO.Path]::GetFileName($sourceFull))

    $state = [ordered]@{
        schemaVersion = if ($sourceReceipt) { 15 } else { 14 }
        workflowSchemaVersion = if ($sourceReceipt) { 15 } else { 14 }
        runId = $actualRunId
        status = 'claiming'
        statePath = [IO.Path]::GetFullPath($actualStatePath)
        repositoryRoot = $repository
        runRoot = [IO.Path]::GetFullPath($runRoot)
        artifactsRoot = [IO.Path]::GetFullPath((Join-Path $runRoot 'artifacts'))
        mod = $ModDirectory
        modSlug = $slug
        repoModDirectory = $ModDirectory
        modRelativePath = $modRelativePath
        modLockKey = $lockKey
        modLockPath = [IO.Path]::GetFullPath($modLockPath)
        claimPath = [IO.Path]::GetFullPath($claimPath)
        claimCoordinatorArchivePath = [IO.Path]::GetFullPath($coordinatorArchive)
        branch = $branch
        worktreePath = [IO.Path]::GetFullPath($worktree)
        baseRef = $BaseRef
        remote = $Remote
        pullRequestBase = $PullRequestBase
        baseOid = $baseOid
        checkedMainOid = $baseOid
        metadataPaths = @($MetadataPath)
        sourceReceipt = $sourceReceipt
        sourceTuple = $sourceTuple
        sourceAcquisition = if ($sourceReceipt) {
            [ordered]@{
                recordPath = $sourceAcquisitionRecord.recordPath
                recordSha256 = $sourceAcquisitionRecord.recordSha256
                provider = $sourceReceipt.provider
                sourceRequest = $sourceReceipt.sourceRequest
                receiptPath = $sourceReceipt.path
                receiptSha256 = $sourceReceipt.sha256
                sourceRequestPath = $sourceReceipt.sourceRequestPath
                sourceRequestSha256 = $sourceReceipt.sourceRequestSha256
                skillSourcePinPath = $acquisition.skillSourcePinPath
                skillSourcePinSha256 = $acquisition.skillSourcePinSha256
                skillSourceCommit = $acquisition.skillSourceCommit
                skillSourceContentSha256 = $acquisition.skillSourceContentSha256
                timings = $sourceReceipt.timings
            }
        }
        else { $null }
        workflowRef = $skillSourcePin.requestedRef
        workflowCommitOid = $skillSourcePin.resolvedCommit
        workflowSourceRepository = $skillSourcePin.repository
        workflowSourceVersion = $skillSourcePin.resolvedVersion
        workflowSourceContentSha256 = $skillSourcePin.contentSha256
        workflowSourcePinPath = [IO.Path]::GetFullPath($boundPinPath)
        workflowSourcePinSha256 = $skillSourcePin.pinSha256
        workflowPath = $integrity.workflow.path
        workflowBlobOid = $workflowSourceEntry.blobOid
        workflowSha256 = $integrity.workflow.sha256
        workflowPackageSha256 = $workflowSourceEntry.sha256
        reviewBaselinePath = $integrity.reviewBaseline.path
        reviewBaselineBlobOid = $reviewSourceEntry.blobOid
        reviewBaselineSha256 = $integrity.reviewBaseline.sha256
        reviewBaselinePackageSha256 = $reviewSourceEntry.sha256
        schema15Path = if ($sourceReceipt) { $integrity.schema15.path } else { $null }
        schema15BlobOid = if ($sourceReceipt) { $schema15SourceEntry.blobOid } else { $null }
        schema15Sha256 = if ($sourceReceipt) { $integrity.schema15.sha256 } else { $null }
        referenceSources = @(
            [ordered]@{ role = 'workflow'; path = $integrity.workflow.path; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $workflowSourceEntry.blobOid; size = $workflowSourceEntry.size; sha256 = $workflowSourceEntry.sha256; expandedSize = $integrity.workflow.sizeBytes; expandedSha256 = $integrity.workflow.sha256 },
            [ordered]@{ role = 'review-baseline'; path = $integrity.reviewBaseline.path; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $reviewSourceEntry.blobOid; size = $reviewSourceEntry.size; sha256 = $reviewSourceEntry.sha256; expandedSize = $integrity.reviewBaseline.sizeBytes; expandedSha256 = $integrity.reviewBaseline.sha256 },
            [ordered]@{ role = 'package-binding'; path = $bindingSourceEntry.repositoryPath; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $bindingSourceEntry.blobOid; size = $bindingSourceEntry.size; sha256 = $bindingSourceEntry.sha256 },
            [ordered]@{ role = 'skill'; path = $skillSourceEntry.repositoryPath; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $skillSourceEntry.blobOid; size = $skillSourceEntry.size; sha256 = $skillSourceEntry.sha256 }
        ) + @(
            if ($sourceReceipt) { [ordered]@{ role = 'schema-15-extension'; path = $integrity.schema15.path; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $schema15SourceEntry.blobOid; size = $schema15SourceEntry.size; sha256 = $schema15SourceEntry.sha256 } }
        )
        archive = [ordered]@{
            filename = [IO.Path]::GetFileName($claimedArchive)
            originalPath = $sourceFull
            path = [IO.Path]::GetFullPath($claimedArchive)
            size = $sampleTwo.Length
            sha256 = $archiveSha
            format = 'zip'
            preserveOriginal = [bool]$sourceReceipt
        }
        completedStages = if ($sourceReceipt) { @('acquire-source') } else { @() }
        stageTimings = if ($sourceReceipt) {
            [ordered]@{
                'acquire-source' = [ordered]@{
                    attempt = 1
                    startedAt = $sourceReceipt.startedAt
                    completedAt = $sourceReceipt.completedAt
                    activeMilliseconds = [int64]$sourceReceipt.timings.downloadMilliseconds + [int64]$sourceReceipt.timings.verifyMilliseconds + [int64]$sourceReceipt.timings.deliverMilliseconds
                    waitingMilliseconds = if ($sourceReceipt.timings.Contains('waitingMilliseconds')) { [int64]$sourceReceipt.timings.waitingMilliseconds } else { 0 }
                    result = 'passed'
                    artifactSha256 = $sourceReceipt.sha256
                    downloadMilliseconds = [int64]$sourceReceipt.timings.downloadMilliseconds
                    verifyMilliseconds = [int64]$sourceReceipt.timings.verifyMilliseconds
                    deliverMilliseconds = [int64]$sourceReceipt.timings.deliverMilliseconds
                }
            }
        }
        else { [ordered]@{} }
        lastRecovery = $null
        evidenceChain = [ordered]@{
            c0Oid = $baseOid
            c0TreeOid = $baseTreeOid
            c1ParentOid = $null
            c1ParentTreeOid = $null
            c1Oid = $null
            c1TreeOid = $null
            c1EmptyReason = $null
            c2Status = 'not-run'
            c2Reason = $null
            c2ParentOid = $null
            c2ParentTreeOid = $null
            c2Oid = $null
            c2TreeOid = $null
            c3Status = 'not-run'
            c3Reason = $null
            c3ParentOid = $null
            c3ParentTreeOid = $null
            c3Oid = $null
            c3TreeOid = $null
            fOid = $null
            fTreeOid = $null
        }
        candidateGate = [ordered]@{ status = 'not-run' }
        localizationMode = 'none'
        localizationFiles = @()
        evidenceTargetPaths = @()
        evidenceTargetPathsSha256 = $null
        evidenceGeneration = 1
        prNumber = $null
        prUrl = $null
        published = $false
        externalReview = [ordered]@{ status = 'not-requested'; pollingWaitSeconds = 0 }
        securityOverrides = @()
        createdAt = Get-UtcTimestamp
        updatedAt = Get-UtcTimestamp
        claimAttemptedAt = $null
    }
    Ensure-RunWriterLock -State $state
    Write-AtomicJson -Path $state.statePath -Value $state
    $sourceCoordination = Enter-SharedCoordinationLock -Repository $repository -ResourceKey 'source-acquisition' `
        -ActualRunId $actualRunId -ReceiptRoot ([string]$state.artifactsRoot)
    try {
        if ((Get-FileSha256 -Path $sourceFull) -cne $archiveSha) {
            throw 'Source archive changed before the coordinated claim move.'
        }
        if ($sourceReceipt) { Copy-FileWithHeartbeat -SourcePath $sourceFull -DestinationPath $coordinatorArchive }
        else {
            Update-ActiveReservationHeartbeat -Force
            Update-ActiveSharedCoordinationHeartbeat -Force
            [IO.File]::Move($sourceFull, $coordinatorArchive)
        }
    }
    finally {
        $sourceCoordinationReceipt = Exit-SharedCoordinationLock -Lease $sourceCoordination
    }
    $state.coordinationReceipts = @($sourceCoordinationReceipt)
    Save-State -State $state
    Complete-IncompleteClaim -State $state
}

function Get-ZipEntries {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ExpectedSha256
    )
    Add-Type -AssemblyName System.IO.Compression
    $actualSha256 = Get-FileSha256 -Path $Path
    if ($actualSha256 -ne $ExpectedSha256) {
        throw 'Claimed archive SHA-256 changed before ZIP processing.'
    }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $false)
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $entries = @()
        $totalLength = [int64]0
        if ($archive.Entries.Count -gt 100000) { throw 'Archive entry count exceeds the 100,000 entry limit.' }
        foreach ($entry in $archive.Entries) {
            $entryPath = $entry.FullName.Replace('\', '/')
            $segments = @($entryPath.Split('/', [StringSplitOptions]::RemoveEmptyEntries))
            if ([IO.Path]::IsPathRooted($entryPath) -or $entryPath.StartsWith('/') -or $entryPath.Contains(':') -or $segments -contains '..' -or $entryPath.IndexOfAny([char[]]@(0, 10, 13)) -ge 0) {
                throw "Archive path traversal or rooted path rejected: $entryPath"
            }
            if ($segments.Count -eq 0) { continue }
            foreach ($segment in $segments) {
                if ($segment.EndsWith(' ') -or $segment.EndsWith('.')) { throw "Windows path collision rejected: $entryPath" }
                if ($segment -match '(?i)^(con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\..*)?$') {
                    throw "Archive path uses a reserved Windows device name: $entryPath"
                }
            }
            $collisionKey = $entryPath.Normalize([Text.NormalizationForm]::FormC)
            if (-not $seen.Add($collisionKey)) { throw "Duplicate or Unicode/case-colliding archive path rejected: $entryPath" }
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -eq 0xA000) { throw "Archive symlink rejected: $entryPath" }
            $totalLength += $entry.Length
            if ($entry.Length -gt 1GB -or $totalLength -gt 4GB -or ($entry.CompressedLength -gt 0 -and ($entry.Length / $entry.CompressedLength) -gt 1000)) {
                throw "Archive expansion limit rejected: $entryPath"
            }
            if (-not $entryPath.EndsWith('/')) {
                try {
                    $probe = $entry.Open()
                    try { $null = $probe.ReadByte() } finally { $probe.Dispose() }
                }
                catch { throw "Encrypted or unreadable archive entry rejected: $entryPath. $($_.Exception.Message)" }
            }
            $entries += [ordered]@{
                path = $entryPath
                size = $entry.Length
                compressedSize = $entry.CompressedLength
                externalAttributes = $entry.ExternalAttributes
                directory = $entryPath.EndsWith('/')
            }
        }
        [ordered]@{ archive = $archive; stream = $stream; entries = $entries }
    }
    catch {
        $stream.Dispose()
        throw
    }
}

function Invoke-VerifySource {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'verify-source'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'verify-source'
    Assert-LockOwner -State $State
    $archivePath = [string]$State.archive.path
    $zip = Get-ZipEntries -Path $archivePath -ExpectedSha256 $State.archive.sha256
    try {
        $fileEntries = @($zip.entries | Where-Object { -not $_.directory })
        if ($fileEntries.Count -eq 0) { throw 'Archive contains no files.' }
        $roots = @($fileEntries | ForEach-Object { $_.path.Split('/')[0] } | Sort-Object -Unique)
        if ($roots.Count -ne 1 -or $roots[0] -cne $State.repoModDirectory) {
            throw 'Invalid archive root; exactly one root matching the canonical MOD directory is required.'
        }
        $listing = [ordered]@{
            schemaVersion = 1
            archiveSha256 = $State.archive.sha256
            root = $roots[0]
            entries = @($zip.entries | Sort-Object { $_.path })
            verifiedAt = Get-UtcTimestamp
        }
        $path = Join-Path $State.artifactsRoot 'archive-listing.json'
        Write-AtomicJson -Path $path -Value $listing
        $State.archive.format = 'zip'
        Complete-Stage -State $State -Context $stage -ArtifactSha256 (Get-FileSha256 -Path $path) -Data ([ordered]@{ listingPath = $path; entryCount = $listing.entries.Count })
    }
    finally {
        $zip.archive.Dispose()
        $zip.stream.Dispose()
    }
}

function Invoke-Extract {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'extract'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'extract'
    Assert-LockOwner -State $State
    $stagingRoot = Join-Path $State.runRoot 'staging'
    $temporaryRoot = Join-Path $stagingRoot ('.extract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $zip = Get-ZipEntries -Path $State.archive.path -ExpectedSha256 $State.archive.sha256
    try {
        foreach ($entry in $zip.archive.Entries) {
            $relative = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $destination = Assert-ContainedPath -Candidate (Join-Path $temporaryRoot $relative) -Root $temporaryRoot -Label 'Archive entry'
            if ($relative.EndsWith('/')) {
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                continue
            }
            $parent = Split-Path -Parent $destination
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
            $entryStream = $entry.Open()
            $output = [IO.File]::Open($destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { Copy-StreamWithHeartbeat -Source $entryStream -Destination $output } finally { $output.Dispose(); $entryStream.Dispose() }
        }
    }
    finally {
        $zip.archive.Dispose()
        $zip.stream.Dispose()
    }
    $null = Assert-NoReparseTree -Path $temporaryRoot -Root ([string]$State.runRoot) -Label 'Extracted staging tree'
    $finalRoot = Join-Path $stagingRoot 'extracted'
    if (Test-Path -LiteralPath $finalRoot) {
        $recoveryPath = Join-Path $stagingRoot ('recovery-' + [guid]::NewGuid().ToString('N'))
        Update-ActiveReservationHeartbeat -Force
        Move-Item -LiteralPath $finalRoot -Destination $recoveryPath
        $State.lastRecovery = [ordered]@{ at = Get-UtcTimestamp; reason = 'incomplete extract replaced'; retainedPath = $recoveryPath }
    }
    Update-ActiveReservationHeartbeat -Force
    [IO.Directory]::Move($temporaryRoot, $finalRoot)
    $manifestPath = Join-Path $State.artifactsRoot 'extraction-manifest.json'
    $manifest = New-Manifest -Root $finalRoot -OutputPath $manifestPath -Kind 'extraction'
    $State.extractionRoot = [IO.Path]::GetFullPath($finalRoot)
    $State.extractionManifest = $manifest
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $manifest.sha256 -Data $manifest
}

function Copy-DirectoryBytes {
    param([string] $Source, [string] $Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Get-ChildItem -LiteralPath $Source -Directory -Recurse | ForEach-Object {
        $directory = $_
        $relative = [IO.Path]::GetRelativePath($Source, $directory.FullName)
        New-Item -ItemType Directory -Path (Join-Path $Destination $relative) -Force | Out-Null
        Update-ActiveReservationHeartbeat
    }
    Get-ChildItem -LiteralPath $Source -File -Recurse | ForEach-Object {
        $file = $_
        $relative = [IO.Path]::GetRelativePath($Source, $file.FullName)
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-FileWithHeartbeat -SourcePath $file.FullName -DestinationPath $target
    }
}

function Invoke-Install {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'install'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'install'
    Assert-LockOwner -State $State
    $source = Assert-NoReparsePath -Path (Join-Path $State.extractionRoot $State.repoModDirectory) `
        -Root ([string]$State.runRoot) -Label 'Verified extracted MOD source'
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw 'Verified archive root is missing from extraction staging.' }
    $null = Assert-NoReparseTree -Path $source -Root ([string]$State.runRoot) -Label 'Verified extracted MOD tree before install'
    $modsRoot = Assert-NoReparsePath -Path (Join-Path $State.worktreePath 'Warhammer 40,000 DARKTIDE/mods') `
        -Root ([string]$State.worktreePath) -Label 'MODs install root'
    $target = Assert-ContainedPath -Candidate (Join-Path $modsRoot $State.repoModDirectory) -Root $modsRoot -Label 'MOD install path'
    $target = Assert-NoReparsePath -Path $target -Root ([string]$State.worktreePath) -Label 'MOD install path' -AllowMissing
    if (Test-Path -LiteralPath $target) {
        $resolvedTarget = [IO.Path]::GetFullPath($target)
        $resolvedMods = [IO.Path]::GetFullPath($modsRoot) + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedTarget.StartsWith($resolvedMods, [StringComparison]::OrdinalIgnoreCase)) { throw 'Refusing broad install deletion.' }
        $null = Assert-NoReparseTree -Path $resolvedTarget -Root ([string]$State.worktreePath) -Label 'Existing MOD install tree before removal'
        Remove-DirectoryTreeWithHeartbeat -Path $resolvedTarget
    }
    Copy-DirectoryBytes -Source $source -Destination $target
    $null = Assert-NoReparseTree -Path $target -Root ([string]$State.worktreePath) -Label 'Installed MOD tree'
    $rawPath = Join-Path $State.artifactsRoot 'raw-install-manifest.json'
    $installPath = Join-Path $State.artifactsRoot 'install-manifest.json'
    $raw = New-Manifest -Root $target -OutputPath $rawPath -Kind 'raw-install'
    $install = New-Manifest -Root $target -OutputPath $installPath -Kind 'install'
    $State.installRoot = $target
    $State.rawInstallManifest = $raw
    $State.installManifest = $install
    $State.gitIndexNormalization = New-GitNormalizationManifest -State $State
    $State.status = 'installed'
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $raw.sha256 -Data ([ordered]@{ rawInstall = $raw; install = $install })
}

function Write-ByteFile {
    param([string] $Path, [byte[]] $Bytes)
    Update-ActiveReservationHeartbeat -Force
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllBytes($temporary, $Bytes)
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Invoke-ApprovedSpans {
    param([byte[]] $IndexedBytes, [object[]] $ApprovedSpans)
    $result = $IndexedBytes
    $orderedSpans = @($ApprovedSpans | Sort-Object { [int64]$_.startByte } -Descending)
    $nextStart = $IndexedBytes.LongLength
    foreach ($span in $orderedSpans) {
        $start = [int64]$span.startByte
        $length = [int64]$span.length
        if ($start -lt 0 -or $length -lt 0 -or ($start + $length) -gt $IndexedBytes.LongLength -or ($start + $length) -gt $nextStart) {
            throw 'Approved localization byte spans overlap or escape the indexed base.'
        }
        $oldBytes = [byte[]]::new($length)
        [Array]::Copy($IndexedBytes, $start, $oldBytes, 0, $length)
        if ((Get-Sha256Bytes -Bytes $oldBytes) -ne [string]$span.oldSha256) { throw 'Approved span oldSha256 does not match indexed bytes.' }
        $replacement = [Convert]::FromBase64String([string]$span.replacementBase64)
        $memory = [IO.MemoryStream]::new()
        if ($start -gt 0) { $memory.Write($result, 0, $start) }
        $memory.Write($replacement, 0, $replacement.Length)
        $tailStart = $start + $length
        if ($tailStart -lt $result.LongLength) { $memory.Write($result, $tailStart, $result.LongLength - $tailStart) }
        $result = $memory.ToArray()
        $nextStart = $start
    }
    $result
}

function Invoke-LocalizationWorkset {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'localization'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'localization'
    Assert-LockOwner -State $State
    $reviewArtifacts = Join-Path ([string]$State.runRoot) 'review-artifacts'
    $stagingParent = Join-Path ([string]$State.runRoot) 'staging/localization-workset-input'
    $stagingModRoot = Join-Path $stagingParent ([string]$State.repoModDirectory)
    $worksetPath = Join-Path $reviewArtifacts 'localization-workset.json'
    if (-not (Test-Path -LiteralPath $worksetPath -PathType Leaf)) {
        if (Test-Path -LiteralPath $stagingModRoot) { throw 'Unexpected pre-existing localization workset staging without a workset.' }
        $null = Assert-NoReparseTree -Path ([string]$State.installRoot) -Root ([string]$State.worktreePath) -Label 'Installed MOD tree before localization workset staging'
        Copy-DirectoryBytes -Source ([string]$State.installRoot) -Destination $stagingModRoot
    }
    elseif (-not (Test-Path -LiteralPath $stagingModRoot -PathType Container)) {
        throw 'Localization workset staging is missing during resume.'
    }
    $null = Assert-NoReparseTree -Path $stagingModRoot -Root ([string]$State.runRoot) -Label 'Localization workset staging tree'
    $generator = Join-Path $PSScriptRoot 'New-LocalizationWorkset.ps1'
    $generation = & $generator `
        -RepositoryRoot ([string]$State.repositoryRoot) `
        -BaseOid ([string]$State.baseOid) `
        -ModRelativePath ([string]$State.modRelativePath) `
        -StagingModPath $stagingModRoot `
        -OutputPath $worksetPath `
        -SourceId ([string]$State.modSlug) `
        -HeartbeatAction { Update-ActiveReservationHeartbeat } `
        -PassThru
    if ($generation.status -eq 'automation-excluded') {
        $State.status = 'automation-excluded'
        $State.waitingReason = [ordered]@{ code = 'localization_entry_is_loader'; message = 'The unique localization entry is a loader and cannot be automated.' }
        Save-State -State $State
        return [ordered]@{ result = 'waiting-input'; runId = $State.runId; stage = 'localization-workset'; status = $State.status; statePath = $State.statePath; data = $State.waitingReason }
    }
    if ($generation.status -eq 'blocked') { throw "Localization workset generation is blocked: $($generation.reason)" }
    $null = Assert-NoReparsePath -Path $worksetPath -Root ([string]$State.repositoryRoot) -Label 'Localization workset'
    $workset = Get-Content -LiteralPath $worksetPath -Raw | ConvertFrom-Json -AsHashtable
    $pending = @($workset.units | Where-Object { $_.action -ceq 'AI_REQUIRED' -and $_.reviewStatus -cne 'approved' })
    if ($pending.Count -gt 0) {
        $State.status = 'waiting-input'
        $State.localizationWorkset = [ordered]@{
            path = [IO.Path]::GetFullPath($worksetPath)
            sha256 = Get-FileSha256 -Path $worksetPath
            immutableContractSha256 = $workset.immutableContractSha256
            status = 'awaiting-ai-review'
            pendingUnitIds = @($pending.unitId)
            counts = $workset.counts
        }
        Save-State -State $State
        return [ordered]@{
            result = 'waiting-input'
            runId = $State.runId
            stage = 'localization-workset'
            status = $State.status
            statePath = $State.statePath
            data = [ordered]@{ worksetPath = $worksetPath; pendingUnitIds = @($pending.unitId); required = 'Review only AI_REQUIRED units, set reviewStatus=approved and suggestedZhTwExpression, then resume localization.' }
        }
    }
    $applier = Join-Path $PSScriptRoot 'Apply-LocalizationWorkset.ps1'
    $applied = & $applier -WorksetPath $worksetPath -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
    if ($applied.result -cne 'passed') { throw 'Localization workset apply did not pass.' }
    $null = Assert-NoReparsePath -Path $worksetPath -Root ([string]$State.repositoryRoot) -Label 'Applied localization workset'
    $workset = Get-Content -LiteralPath $worksetPath -Raw | ConvertFrom-Json -AsHashtable
    $stagedLocalization = [IO.Path]::GetFullPath([string]$workset.new.path)
    $null = Assert-NoReparsePath -Path $stagedLocalization -Root ([string]$State.repositoryRoot) -Label 'Applied localization output'
    $relativeToMod = [IO.Path]::GetRelativePath($stagingModRoot, $stagedLocalization).Replace('\', '/')
    if ($relativeToMod.StartsWith('../', [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relativeToMod)) { throw 'Applied localization path escapes workset staging.' }
    $relative = ([string]$State.modRelativePath).TrimEnd('/') + '/' + $relativeToMod
    $worktreeFile = Assert-ContainedPath -Candidate (Join-Path ([string]$State.worktreePath) $relative) -Root ([string]$State.worktreePath) -Label 'Localization worktree target'
    $worktreeFile = Assert-NoReparsePath -Path $worktreeFile -Root ([string]$State.worktreePath) -Label 'Raw worktree localization input'
    if ((Get-FileSha256 -Path $worktreeFile) -cne [string]$workset.new.sha256) { throw 'Raw worktree localization differs from the workset NEW input.' }
    $rawBytes = Read-FileBytesWithHeartbeat -Path $worktreeFile
    $rawBlobOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.autocrlf=true', 'hash-object', '-w', "--path=$relative", '--', $worktreeFile)).output.Trim()
    $indexedBytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $rawBlobOid
    $mergedRawBytes = Read-FileBytesWithHeartbeat -Path $stagedLocalization
    $mergedBlobOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.autocrlf=true', 'hash-object', '-w', "--path=$relative", '--', $stagedLocalization)).output.Trim()
    $mergedIndexedBytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $mergedBlobOid
    $localizationRoot = Join-Path ([string]$State.artifactsRoot) 'localization'
    $safeId = (Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($relative))).Substring(0, 16)
    $artifactDirectory = Join-Path $localizationRoot $safeId
    $oldObject = "$($State.baseOid):$([string]$workset.old.path)"
    Write-ByteFile -Path (Join-Path $artifactDirectory 'old.lua') -Bytes (Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $oldObject)
    Write-ByteFile -Path (Join-Path $artifactDirectory 'new.lua') -Bytes $rawBytes
    Write-ByteFile -Path (Join-Path $artifactDirectory 'indexed.lua') -Bytes $indexedBytes
    Write-ByteFile -Path (Join-Path $artifactDirectory 'merged.lua') -Bytes $mergedRawBytes
    Write-ByteFile -Path (Join-Path $artifactDirectory 'merged-indexed.lua') -Bytes $mergedIndexedBytes
    $worksetSha = Get-FileSha256 -Path $worksetPath
    $records = @([ordered]@{
        relativePath = $relative
        safeId = $safeId
        rawSha256 = Get-Sha256Bytes -Bytes $rawBytes
        indexedSha256 = Get-Sha256Bytes -Bytes $indexedBytes
        mergedRawSha256 = Get-Sha256Bytes -Bytes $mergedRawBytes
        mergedSha256 = Get-Sha256Bytes -Bytes $mergedIndexedBytes
        artifactDirectory = $artifactDirectory
        decisionsSha256 = $worksetSha
        worksetPath = [IO.Path]::GetFullPath($worksetPath)
        worksetUnitCount = @($workset.units).Count
        worksetEditCount = @($workset.apply.edits).Count
    })
    $manifestPath = Join-Path ([string]$State.artifactsRoot) 'localization-manifest.json'
    Write-AtomicJson -Path $manifestPath -Value ([ordered]@{
        schemaVersion = 2
        workflowSchemaVersion = 15
        mode = 'zh-tw-workset'
        worksetPath = [IO.Path]::GetFullPath($worksetPath)
        worksetSha256 = $worksetSha
        immutableContractSha256 = $workset.immutableContractSha256
        counts = $workset.counts
        files = $records
        removedPaths = @()
    })
    $State.localizationMode = 'zh-tw'
    $State.localizationFiles = $records
    $State.localizationRemovedPaths = @()
    $targetSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null = $targetSet.Add([string]$workset.old.path)
    $null = $targetSet.Add([string]$relative)
    [string[]]$targetPaths = @($targetSet)
    [Array]::Sort($targetPaths, [StringComparer]::Ordinal)
    $State.evidenceTargetPaths = $targetPaths
    $targetPathJson = ConvertTo-Json -InputObject @($State.evidenceTargetPaths) -Compress
    $State.evidenceTargetPathsSha256 = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($targetPathJson))
    $State.localizationManifestPath = $manifestPath
    $State.localizationWorkset = [ordered]@{
        path = [IO.Path]::GetFullPath($worksetPath)
        sha256 = $worksetSha
        immutableContractSha256 = $workset.immutableContractSha256
        status = 'applied'
        inputSha256 = $workset.apply.inputSha256
        outputSha256 = $workset.apply.outputSha256
        counts = $workset.counts
        unitCount = @($workset.units).Count
        editCount = @($workset.apply.edits).Count
    }
    $State.status = 'localized'
    Complete-Stage -State $State -Context $stage -ArtifactSha256 (Get-FileSha256 -Path $manifestPath) -Data ([ordered]@{ mode = 'zh-tw-workset'; fileCount = 1; workset = $State.localizationWorkset })
}

function Invoke-Localization {
    param([Collections.IDictionary] $State)
    if ([int]$State.schemaVersion -ge 15) { return Invoke-LocalizationWorkset -State $State }
    $completed = Get-CompletedStageResult -State $State -Name 'localization'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'localization'
    Assert-LockOwner -State $State
    $plan = if ([string]::IsNullOrWhiteSpace($LocalizationPlanPath)) {
        [ordered]@{ schemaVersion = 1; mode = 'none'; files = @(); metadataPaths = @($State.metadataPaths) }
    }
    else {
        Get-Content -LiteralPath $LocalizationPlanPath -Raw | ConvertFrom-Json -AsHashtable
    }
    if ($plan.mode -notin @('none', 'zh-tw')) { throw 'Localization plan mode must be none or zh-tw.' }
    if ($plan.mode -eq 'none' -and @($plan.files).Count -ne 0) { throw 'Localization mode none cannot contain files.' }
    $removedPaths = if ($plan.Contains('removedPaths')) { @($plan.removedPaths) } else { @() }
    if ($plan.mode -eq 'none' -and $removedPaths.Count -ne 0) { throw 'Localization mode none cannot contain removed paths.' }
    foreach ($removedPath in $removedPaths) {
        $removedRelative = ([string]$removedPath).Replace('\', '/')
        if (-not $removedRelative.StartsWith($State.modRelativePath + '/', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Removed localization target is outside the canonical MOD directory.'
        }
        $removedWorktreePath = Assert-ContainedPath -Candidate (Join-Path $State.worktreePath $removedRelative) -Root $State.worktreePath -Label 'Removed localization target'
        if (Test-Path -LiteralPath $removedWorktreePath) { throw 'A removed localization target still exists in the upstream install.' }
    }
    $localizationRoot = Join-Path $State.artifactsRoot 'localization'
    New-Item -ItemType Directory -Path $localizationRoot -Force | Out-Null
    $records = @()
    foreach ($file in @($plan.files)) {
        $relative = ([string]$file.relativePath).Replace('\', '/')
        if (-not $relative.StartsWith($State.modRelativePath + '/', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Localization target is outside the canonical MOD directory.'
        }
        $worktreeFile = Assert-ContainedPath -Candidate (Join-Path $State.worktreePath $relative) -Root $State.worktreePath -Label 'Localization target'
        if (-not (Test-Path -LiteralPath $worktreeFile -PathType Leaf)) { throw 'Localization target file is missing.' }
        $rawBytes = Read-FileBytesWithHeartbeat -Path $worktreeFile
        $blobOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.autocrlf=true', 'hash-object', '-w', "--path=$relative", '--', $worktreeFile)).output.Trim()
        $indexedBytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $blobOid
        $indexedSha = Get-Sha256Bytes -Bytes $indexedBytes
        if ($indexedSha -ne [string]$file.indexedSha256) { throw 'Localization indexedSha256 does not match the Git-normalized source.' }
        $mergedBytes = Invoke-ApprovedSpans -IndexedBytes $indexedBytes -ApprovedSpans @($file.approvedSpans)
        $safeId = (Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($relative))).Substring(0, 16)
        $artifactDirectory = Join-Path $localizationRoot $safeId
        $oldObject = "$($State.evidenceChain.c0Oid):$relative"
        $oldExists = Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('cat-file', '-e', $oldObject) -AllowFailure
        if ($oldExists.exitCode -eq 0) {
            Write-ByteFile -Path (Join-Path $artifactDirectory 'old.lua') -Bytes (Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $oldObject)
        }
        Write-ByteFile -Path (Join-Path $artifactDirectory 'new.lua') -Bytes $rawBytes
        Write-ByteFile -Path (Join-Path $artifactDirectory 'indexed.lua') -Bytes $indexedBytes
        Write-ByteFile -Path (Join-Path $artifactDirectory 'merged.lua') -Bytes $mergedBytes
        $decisionsPath = Join-Path $artifactDirectory 'decisions.json'
        Write-AtomicJson -Path $decisionsPath -Value $file
        $records += [ordered]@{
            relativePath = $relative
            safeId = $safeId
            rawSha256 = Get-Sha256Bytes -Bytes $rawBytes
            indexedSha256 = $indexedSha
            mergedSha256 = Get-Sha256Bytes -Bytes $mergedBytes
            approvedSpans = @($file.approvedSpans)
            artifactDirectory = $artifactDirectory
            decisionsSha256 = Get-FileSha256 -Path $decisionsPath
        }
    }
    $manifestPath = Join-Path $State.artifactsRoot 'localization-manifest.json'
    Write-AtomicJson -Path $manifestPath -Value ([ordered]@{ schemaVersion = 1; mode = $plan.mode; files = $records; removedPaths = $removedPaths })
    $State.localizationMode = $plan.mode
    $State.localizationFiles = $records
    $State.localizationRemovedPaths = @($removedPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $State.evidenceTargetPaths = @(
        @($plan.files | ForEach-Object { @($(if ($_.Contains('oldRelativePath')) { [string]$_.oldRelativePath }), [string]$_.relativePath) }) + @($State.localizationRemovedPaths) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Replace('\', '/') } |
            Sort-Object -Unique
    )
    $targetPathJson = ConvertTo-Json -InputObject @($State.evidenceTargetPaths) -Compress
    $targetPathBytes = [Text.Encoding]::UTF8.GetBytes($targetPathJson)
    $State.evidenceTargetPathsSha256 = Get-Sha256Bytes -Bytes $targetPathBytes
    $State.localizationManifestPath = $manifestPath
    Complete-Stage -State $State -Context $stage -ArtifactSha256 (Get-FileSha256 -Path $manifestPath) -Data ([ordered]@{ mode = $plan.mode; fileCount = $records.Count })
}

function New-GitEvidenceFile {
    param([Collections.IDictionary] $State, [string] $Name, [string[]] $Arguments)
    $path = Join-Path (Join-Path $State.artifactsRoot 'git-evidence') $Name
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    $result = Invoke-Git -WorkingDirectory $State.worktreePath -Arguments $Arguments
    [IO.File]::WriteAllText($path, $result.output + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [ordered]@{ path = $path; sha256 = Get-FileSha256 -Path $path }
}

function Invoke-BuildCommits {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'build-commits'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'build-commits'
    Assert-LockOwner -State $State
    if ($State.published) { throw 'A published evidence branch is append-only; completed checkpoints are never reset or rebuilt in place.' }
    $worktree = Assert-NoReparsePath -Path ([string]$State.worktreePath) `
        -Root ([IO.Path]::GetPathRoot([string]$State.worktreePath)) -Label 'Evidence worktree'
    $null = Assert-NoReparseTree -Path ([string]$State.installRoot) -Root $worktree -Label 'Installed MOD tree before evidence commits'
    $startingHead = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    if ($startingHead -ne $State.evidenceChain.c0Oid) {
        throw 'Incomplete build-commits recovery requires HEAD to equal C0; preserve the partial history and request explicit user recovery.'
    }
    $targets = @($State.evidenceTargetPaths)
    $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('-c', 'core.autocrlf=true', 'add', '-A', '--', $State.modRelativePath)
    foreach ($target in $targets) {
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('reset', '--quiet', 'HEAD', '--', $target)
    }
    $c1Staged = Invoke-Git -WorkingDirectory $worktree -Arguments @('diff', '--cached', '--quiet') -AllowFailure
    if ($c1Staged.exitCode -eq 0 -and $State.localizationMode -eq 'none') { throw 'The archive is already current; an empty non-localization evidence commit is not allowed.' }
    if ($c1Staged.exitCode -notin @(0, 1)) { throw 'Unable to inspect the C1 index.' }
    $State.evidenceChain.c1ParentOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $State.evidenceChain.c1ParentTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
    $c1Arguments = @('commit', '-m', "chore($($State.modSlug)): sync upstream non-localization [C1]")
    if ($c1Staged.exitCode -eq 0) { $c1Arguments = @('commit', '--allow-empty', '-m', "chore($($State.modSlug)): sync upstream non-localization [C1]"); $State.evidenceChain.c1EmptyReason = 'active localization target contains the only upstream delta' }
    $null = Invoke-Git -WorkingDirectory $worktree -Arguments $c1Arguments
    $State.evidenceChain.c1Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $State.evidenceChain.c1TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()

    if ($State.localizationMode -eq 'zh-tw') {
        $State.evidenceChain.c2ParentOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $State.evidenceChain.c2ParentTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments (@('-c', 'core.autocrlf=true', 'add', '-A', '--') + $targets)
        foreach ($record in $State.localizationFiles) {
            $indexObject = ":$([string]$record.relativePath)"
            $actualIndexed = Get-GitBlobBytes -WorkingDirectory $worktree -Object $indexObject
            if ((Get-Sha256Bytes -Bytes $actualIndexed) -ne $record.indexedSha256) { throw 'C2 index bytes do not match the immutable indexed localization artifact.' }
        }
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '--allow-empty', '-m', "chore($($State.modSlug)): checkpoint upstream localization [C2]")
        $State.evidenceChain.c2Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $State.evidenceChain.c2TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
        $State.evidenceChain.c2Status = 'committed'
        $State.evidenceChain.c2Reason = New-CheckpointReason -State $State -Checkpoint C2 `
            -ParentTreeOid ([string]$State.evidenceChain.c2ParentTreeOid) -TreeOid ([string]$State.evidenceChain.c2TreeOid)
        $State.evidenceChain.c3ParentOid = $State.evidenceChain.c2Oid
        $State.evidenceChain.c3ParentTreeOid = $State.evidenceChain.c2TreeOid
        $null = Assert-NoReparseTree -Path ([string]$State.installRoot) -Root $worktree -Label 'Installed MOD tree before merged localization write'
        foreach ($record in $State.localizationFiles) {
            $mergedPath = Join-Path ([string]$record.artifactDirectory) 'merged.lua'
            $mergedPath = Assert-NoReparsePath -Path $mergedPath -Root ([string]$State.repositoryRoot) -Label 'Merged localization artifact'
            $destination = Assert-ContainedPath -Candidate (Join-Path $worktree ([string]$record.relativePath)) -Root $worktree -Label 'Merged localization target'
            $destination = Assert-NoReparsePath -Path $destination -Root $worktree -Label 'Merged localization target'
            Write-ByteFile -Path $destination -Bytes (Read-FileBytesWithHeartbeat -Path $mergedPath)
        }
        $c3Targets = @($State.localizationFiles | ForEach-Object { [string]$_.relativePath })
        if ($c3Targets.Count -ne 0) {
            $null = Invoke-Git -WorkingDirectory $worktree -Arguments (@('-c', 'core.autocrlf=true', 'add', '-A', '--') + $c3Targets)
        }
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '--allow-empty', '-m', "feat($($State.modSlug)): restore approved zh-tw localization [C3]")
        $State.evidenceChain.c3Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $State.evidenceChain.c3TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
        $State.evidenceChain.c3Status = 'committed'
        $State.evidenceChain.c3Reason = New-CheckpointReason -State $State -Checkpoint C3 `
            -ParentTreeOid ([string]$State.evidenceChain.c3ParentTreeOid) -TreeOid ([string]$State.evidenceChain.c3TreeOid)
    }
    else {
        $State.evidenceChain.c2Status = 'not-applicable'
        $State.evidenceChain.c2Reason = New-CheckpointReason -State $State -Checkpoint C2 -ParentTreeOid $null -TreeOid $null
        $State.evidenceChain.c3Status = 'not-applicable'
        $State.evidenceChain.c3Reason = New-CheckpointReason -State $State -Checkpoint C3 -ParentTreeOid $null -TreeOid $null
    }

    if (-not $State.Contains('sourceTuple') -or -not $State.sourceTuple) { throw 'Build commits requires the immutable Nexus Main file source tuple.' }
    $sourceTuplePath = [string]$State.sourceTuple.path
    if ((Get-FileSha256 -Path $sourceTuplePath) -cne [string]$State.sourceTuple.sha256) { throw 'Source tuple bytes changed before metadata preview.' }
    $sourceTupleRecord = Get-Content -LiteralPath $sourceTuplePath -Raw | ConvertFrom-Json -AsHashtable
    if ([string]$sourceTupleRecord.contractSha256 -cne [string]$State.sourceTuple.contractSha256) { throw 'Source tuple contract changed before metadata preview.' }
    $sourceFields = [ordered]@{
        nexusModId = [string]$sourceTupleRecord.contract.nexus.modId
        nexusPageUrl = [string]$sourceTupleRecord.contract.nexus.pageUrl
        nexusPageVersion = [string]$sourceTupleRecord.contract.nexus.pageVersion
        nexusPageUpdatedAt = [string]$sourceTupleRecord.contract.nexus.pageUpdatedAt
        nexusMainFileId = [string]$sourceTupleRecord.contract.nexus.mainFileId
        nexusMainFileVersion = [string]$sourceTupleRecord.contract.nexus.mainFileVersion
        nexusMainFileUploadedAtUtc = [string]$sourceTupleRecord.contract.nexus.mainFileUploadedAtUtc
        archiveFileName = [string]$sourceTupleRecord.contract.archive.fileName
        archiveSize = ConvertTo-InvariantString $sourceTupleRecord.contract.archive.size
        archiveSha256 = [string]$sourceTupleRecord.contract.archive.sha256
        acquisitionMethod = [string]$sourceTupleRecord.contract.acquisitionMethod
    }
    $metadataRecords = @()
    foreach ($metadataRelative in @($State.metadataPaths)) {
        $metadataNormalized = $metadataRelative.Replace('\', '/')
        if ($metadataNormalized -cne 'README.md' -and $metadataNormalized -cne ".hash/$($State.modSlug).hash") {
            throw 'Metadata allowlist permits only README.md and the current MOD hash file.'
        }
        $metadataFull = Assert-ContainedPath -Candidate (Join-Path $worktree $metadataRelative) -Root $worktree -Label 'Metadata path'
        if (-not (Test-Path -LiteralPath $metadataFull -PathType Leaf)) { throw "Metadata path is missing: $metadataRelative" }
        $metadataBytes = Read-FileBytesWithHeartbeat -Path $metadataFull
        $metadataText = [Text.UTF8Encoding]::new($false, $true).GetString($metadataBytes)
        $fieldMatches = [ordered]@{}
        foreach ($fieldName in $sourceFields.Keys) {
            $fieldValue = [string]$sourceFields[$fieldName]
            $fieldMatches[$fieldName] = Test-MetadataSourceFieldMatch -RelativePath $metadataNormalized `
                -Text $metadataText -FieldName $fieldName -FieldValue $fieldValue
        }
        $metadataRecords += [ordered]@{
            path = $metadataNormalized
            sha256 = Get-Sha256Bytes -Bytes $metadataBytes
            size = $metadataBytes.Length
            sourceFieldMatches = $fieldMatches
        }
    }
    $metadataPreviewPath = Join-Path $State.artifactsRoot 'metadata-preview.json'
    Write-AtomicJson -Path $metadataPreviewPath -Value ([ordered]@{
        schemaVersion = 2
        runId = $State.runId
        sourceTuplePath = $sourceTuplePath
        sourceTupleSha256 = $State.sourceTuple.sha256
        sourceTupleContractSha256 = $State.sourceTuple.contractSha256
        sourceFields = $sourceFields
        files = $metadataRecords
        generatedAt = Get-UtcTimestamp
    })
    $State.metadataPreview = [ordered]@{
        path = $metadataPreviewPath
        sha256 = Get-FileSha256 -Path $metadataPreviewPath
        fileCount = $metadataRecords.Count
        sourceTupleContractSha256 = $State.sourceTuple.contractSha256
    }
    if (@($State.metadataPaths).Count -gt 0) {
        $null = Invoke-Git -WorkingDirectory $worktree -Arguments (@('add', '--') + @($State.metadataPaths))
        $staged = Invoke-Git -WorkingDirectory $worktree -Arguments @('diff', '--cached', '--quiet') -AllowFailure
        if ($staged.exitCode -eq 1) {
            $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '-m', "docs($($State.modSlug)): update archive metadata [F]")
        }
        elseif ($staged.exitCode -ne 0) { throw 'Unable to inspect staged metadata.' }
    }
    $finalInstallManifestPath = Join-Path $State.artifactsRoot 'install-manifest.json'
    $State.installManifest = New-Manifest -Root $State.installRoot -OutputPath $finalInstallManifestPath -Kind 'install'
    $State.evidenceChain.fOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $State.evidenceChain.fTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
    $State.candidateOid = $State.evidenceChain.fOid
    $State.candidateTreeOid = $State.evidenceChain.fTreeOid
    $State.status = 'candidate-committed'

    $notApplicableEvidence = [ordered]@{ status = 'not-applicable'; path = $null; sha256 = 'not-applicable' }
    $evidence = [ordered]@{
        c1C2Diff = $notApplicableEvidence; c1C2NameStatus = $notApplicableEvidence
        c2C3Diff = $notApplicableEvidence; c2C3NameStatus = $notApplicableEvidence
        c3FDiff = $notApplicableEvidence; c3FNameStatus = $notApplicableEvidence
    }
    $evidence.c0C1Diff = New-GitEvidenceFile -State $State -Name 'c0-c1.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.c1Oid)")
    $evidence.c0C1NameStatus = New-GitEvidenceFile -State $State -Name 'c0-c1.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.c1Oid)")
    $evidence.c1ParentNameStatus = New-GitEvidenceFile -State $State -Name 'c1-parent.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c1ParentOid)..$($State.evidenceChain.c1Oid)")
    if ($State.localizationMode -eq 'zh-tw') {
        $evidence.c1C2Diff = New-GitEvidenceFile -State $State -Name 'c1-c2.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c1Oid)..$($State.evidenceChain.c2Oid)")
        $evidence.c1C2NameStatus = New-GitEvidenceFile -State $State -Name 'c1-c2.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c1Oid)..$($State.evidenceChain.c2Oid)")
        $evidence.c2C3Diff = New-GitEvidenceFile -State $State -Name 'c2-c3.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c2Oid)..$($State.evidenceChain.c3Oid)")
        $evidence.c2C3NameStatus = New-GitEvidenceFile -State $State -Name 'c2-c3.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c2Oid)..$($State.evidenceChain.c3Oid)")
        $evidence.c2ParentNameStatus = New-GitEvidenceFile -State $State -Name 'c2-parent.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c2ParentOid)..$($State.evidenceChain.c2Oid)")
        $evidence.c3ParentNameStatus = New-GitEvidenceFile -State $State -Name 'c3-parent.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c3ParentOid)..$($State.evidenceChain.c3Oid)")
        if ($State.evidenceChain.fOid -ne $State.evidenceChain.c3Oid) {
            $evidence.c3FDiff = New-GitEvidenceFile -State $State -Name 'c3-f.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c3Oid)..$($State.evidenceChain.fOid)")
            $evidence.c3FNameStatus = New-GitEvidenceFile -State $State -Name 'c3-f.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c3Oid)..$($State.evidenceChain.fOid)")
        }
    }
    $evidence.c0FDiff = New-GitEvidenceFile -State $State -Name 'c0-f.diff' -Arguments @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.fOid)")
    $evidence.c0FNameStatus = New-GitEvidenceFile -State $State -Name 'c0-f.name-status.txt' -Arguments @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.fOid)")
    $State.evidenceDiffs = $evidence
    $State.candidateTreeManifest = New-GitTreeManifest -State $State -CommitOid $State.evidenceChain.fOid
    $tuple = [ordered]@{ generation = $State.evidenceGeneration; chain = $State.evidenceChain; targetPathsSha256 = $State.evidenceTargetPathsSha256; archiveSha256 = $State.archive.sha256 }
    $tupleSha = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $tuple -Depth 20 -Compress)))
    $receiptPath = Join-Path $State.artifactsRoot 'evidence-generation-receipt.json'
    Write-AtomicJson -Path $receiptPath -Value ([ordered]@{
        schemaVersion = 1; generation = $State.evidenceGeneration; runId = $State.runId; gitVersion = (Invoke-Git -WorkingDirectory $worktree -Arguments @('--version')).output; parameterVersion = 'full-index-binary-no-renames-v1'; inputTupleSha256 = $tupleSha; evidenceChain = $State.evidenceChain; candidateTreeManifest = $State.candidateTreeManifest; artifacts = $evidence; generatedAt = Get-UtcTimestamp
    })
    $State.evidenceReceipt = [ordered]@{ path = $receiptPath; sha256 = Get-FileSha256 -Path $receiptPath }
    $State.candidateGate = [ordered]@{ status = 'not-run' }
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $State.evidenceReceipt.sha256 -Data ([ordered]@{ evidenceChain = $State.evidenceChain; receipt = $State.evidenceReceipt })
}

function Assert-LocalizationWorksetDeletionEvidence {
    param([Collections.IDictionary] $State)
    if ([int]$State.schemaVersion -lt 15) { return [ordered]@{ status = 'not-applicable' } }
    if (-not $State.localizationWorkset -or -not $State.localizationWorkset.Contains('deletedBeforePublish') -or -not [bool]$State.localizationWorkset.deletedBeforePublish) {
        throw 'Schema 15 publishing requires finalized localization workset deletion evidence.'
    }
    $worksetPath = [string]$State.localizationWorkset.path
    $null = Assert-NoReparsePath -Path $worksetPath -Root ([string]$State.repositoryRoot) -Label 'Deleted localization workset' -AllowMissing
    if (Test-Path -LiteralPath $worksetPath) { throw 'Schema 15 localization workset still exists before publishing.' }
    $receiptPath = [string]$State.localizationWorkset.deletionReceiptPath
    $null = Assert-NoReparsePath -Path $receiptPath -Root ([string]$State.repositoryRoot) -Label 'Localization workset deletion receipt'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'Localization workset deletion receipt is missing.' }
    $receiptSha = Get-FileSha256 -Path $receiptPath
    if ($receiptSha -cne [string]$State.localizationWorkset.deletionReceiptSha256 -or
        $receiptSha -cne [string]$State.candidateGate.localizationWorksetDeletionReceiptSha256) {
        throw 'Localization workset deletion receipt SHA-256 is not bound to state and Candidate Gate.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
    if ([string]$receipt.status -cne 'deleted' -or [string]$receipt.worksetSha256 -cne [string]$State.localizationWorkset.sha256) {
        throw 'Localization workset deletion receipt does not prove deletion of the reviewed workset.'
    }
    $reportPath = [string]$State.candidateGate.validationReportPath
    $null = Assert-NoReparsePath -Path $reportPath -Root ([string]$State.repositoryRoot) -Label 'Candidate Gate report'
    if ((Get-FileSha256 -Path $reportPath) -cne [string]$State.candidateGate.validationReportSha256) { throw 'Candidate Gate report changed after workset deletion.' }
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -AsHashtable
    if (-not $report.Contains('worksetDeletion') -or [string]$report.worksetDeletion.status -cne 'deleted' -or
        [string]$report.worksetDeletion.receiptSha256 -cne $receiptSha -or
        [string]$report.worksetDeletion.worksetSha256 -cne [string]$State.localizationWorkset.sha256) {
        throw 'Candidate Gate report is not bound to the localization workset deletion receipt.'
    }
    [ordered]@{ status = 'deleted'; worksetSha256 = $State.localizationWorkset.sha256; receiptPath = $receiptPath; receiptSha256 = $receiptSha }
}

function Invoke-Validate {
    param([Collections.IDictionary] $State)
    $validator = Join-Path $PSScriptRoot 'Test-ModUpdateCandidate.ps1'
    $validatorSha = Get-FileSha256 -Path $validator
    $recordedValidatorSha = if ($State.candidateGate.Contains('validatorSha256')) { [string]$State.candidateGate.validatorSha256 } else { $null }
    if ([string]$State.candidateGate.status -ceq 'passed' -and $recordedValidatorSha -ne $validatorSha) {
        if ([int]$State.schemaVersion -ge 15 -and $State.localizationWorkset -and
            $State.localizationWorkset.Contains('deletedBeforePublish') -and [bool]$State.localizationWorkset.deletedBeforePublish) {
            throw 'Candidate validator changed after finalized workset deletion; restore the pinned validator before resuming.'
        }
        $State.completedStages = @($State.completedStages | Where-Object { $_ -ne 'validate' })
        $State.candidateGate.status = 'not-run'
        Save-State -State $State
        $State = Read-State -Path $State.statePath
    }
    if ([int]$State.schemaVersion -ge 15 -and [string]$State.candidateGate.status -ceq 'passed') {
        $finalizer = Join-Path $PSScriptRoot 'Finalize-LocalizationWorksetEvidence.ps1'
        $null = & $finalizer -StatePath $State.statePath -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
        $State = Read-State -Path $State.statePath
    }
    $completed = Get-CompletedStageResult -State $State -Name 'validate'
    if ($completed -and $State.candidateGate.status -eq 'passed') { return $completed }
    $stage = Start-Stage -Name 'validate'
    if ([string]$State.candidateGate.status -cne 'passed') {
        $result = & $validator -StatePath $State.statePath -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
        $State = Read-State -Path $State.statePath
        if ($result.result -ne 'passed') { throw 'Independent Final Candidate Gate rejected the candidate.' }
        if ([int]$State.schemaVersion -ge 15) {
            $finalizer = Join-Path $PSScriptRoot 'Finalize-LocalizationWorksetEvidence.ps1'
            $null = & $finalizer -StatePath $State.statePath -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
            $State = Read-State -Path $State.statePath
        }
    }
    Complete-Stage -State $State -Context $stage -ArtifactSha256 ([string]$State.candidateGate.validationReportSha256) -Data ([ordered]@{
        validationReportPath = $State.candidateGate.validationReportPath
        worksetDeletionReceiptSha256 = if ([int]$State.schemaVersion -ge 15) { $State.localizationWorkset.deletionReceiptSha256 } else { $null }
    })
}

function Get-PrBody {
    param([Collections.IDictionary] $State)
    $localizationIds = @($State.localizationFiles | ForEach-Object { $_.safeId }) -join ', '
    if ([string]::IsNullOrWhiteSpace($localizationIds)) { $localizationIds = 'not-applicable' }
    if ([int]$State.schemaVersion -ge 15) {
        $localizationEvidence = @($State.localizationFiles | ForEach-Object { "$($_.safeId): raw=$($_.rawSha256), indexed=$($_.indexedSha256), merged-raw=$($_.mergedRawSha256), merged-indexed=$($_.mergedSha256), workset-edits=$($_.worksetEditCount)" }) -join '; '
        $approvedSpanCount = [int]$State.localizationWorkset.editCount
        $unchangedTargetCount = [int]$State.localizationWorkset.counts.unchanged
        $localizationScope = 'only program-selected zh-tw workset edits; BLOCKED=0'
        $rows = foreach ($changeType in @('unchanged', 'missing_zh_tw', 'zh_tw_only_changed', 'source_changed_translation_unchanged', 'source_and_translation_changed', 'new_key', 'deleted_key', 'blocked')) {
            "| $changeType | $($State.localizationWorkset.counts[$changeType]) |"
        }
        $localizationTable = "`n| Localization change type | Count |`n| --- | ---: |`n" + ($rows -join "`n")
        $worksetSha = [string]$State.localizationWorkset.sha256
        $worksetDeletionReceiptSha = [string]$State.localizationWorkset.deletionReceiptSha256
    }
    else {
        $localizationEvidence = @($State.localizationFiles | ForEach-Object { "$($_.safeId): raw=$($_.rawSha256), indexed=$($_.indexedSha256), merged=$($_.mergedSha256), approved-spans=$(@($_.approvedSpans).Count)" }) -join '; '
        $approvedSpanCount = @($State.localizationFiles | ForEach-Object { @($_.approvedSpans).Count } | Measure-Object -Sum).Sum
        if ($null -eq $approvedSpanCount) { $approvedSpanCount = 0 }
        $unchangedTargetCount = @($State.localizationFiles | Where-Object { @($_.approvedSpans).Count -eq 0 }).Count
        $localizationScope = 'only approved zh-tw spans; BLOCKED=0'
        $localizationTable = ''
        $worksetSha = 'not-applicable'
        $worksetDeletionReceiptSha = 'not-applicable'
    }
    if ([string]::IsNullOrWhiteSpace($localizationEvidence)) { $localizationEvidence = 'not-applicable' }
    $removedTargetCount = if ($State.Contains('localizationRemovedPaths')) { @($State.localizationRemovedPaths).Count } else { 0 }
    @"
## Darktide MOD update evidence

- Run: $($State.runId)
- MOD: $($State.mod)
- Workflow Schema version: $($State.schemaVersion)
- HEAD/F: $($State.evidenceChain.fOid)
- C0: $($State.evidenceChain.c0Oid)
- C1: $($State.evidenceChain.c1Oid)
- C2: $($State.evidenceChain.c2Oid) ($($State.evidenceChain.c2Status): $($State.evidenceChain.c2Reason.code), $($State.evidenceChain.c2Reason.disposition))
- C3: $($State.evidenceChain.c3Oid) ($($State.evidenceChain.c3Status): $($State.evidenceChain.c3Reason.code), $($State.evidenceChain.c3Reason.disposition))
- Trees C0/C1/C2/C3/F: $($State.evidenceChain.c0TreeOid) / $($State.evidenceChain.c1TreeOid) / $($State.evidenceChain.c2TreeOid) / $($State.evidenceChain.c3TreeOid) / $($State.evidenceChain.fTreeOid)
- Parent-tree Gate: C1^=$($State.evidenceChain.c1ParentTreeOid); C2^=$($State.evidenceChain.c2ParentTreeOid); C3^=$($State.evidenceChain.c3ParentTreeOid)
- C0..C1 diff/name-status SHA-256: $($State.evidenceDiffs.c0C1Diff.sha256) / $($State.evidenceDiffs.c0C1NameStatus.sha256)
- C1..C2 diff/name-status SHA-256: $($State.evidenceDiffs.c1C2Diff.sha256) / $($State.evidenceDiffs.c1C2NameStatus.sha256)
- C2..C3 diff/name-status SHA-256: $($State.evidenceDiffs.c2C3Diff.sha256) / $($State.evidenceDiffs.c2C3NameStatus.sha256)
- C0..F diff/name-status SHA-256: $($State.evidenceDiffs.c0FDiff.sha256) / $($State.evidenceDiffs.c0FNameStatus.sha256)
- C3..F diff/name-status SHA-256: $($State.evidenceDiffs.c3FDiff.sha256) / $($State.evidenceDiffs.c3FNameStatus.sha256)
- Evidence target paths SHA-256: $($State.evidenceTargetPathsSha256)
- Evidence target paths: $(@($State.evidenceTargetPaths) -join ', ')
- Extraction/raw-install/install/candidate-tree manifest SHA-256: $($State.extractionManifest.sha256) / $($State.rawInstallManifest.sha256) / $($State.installManifest.sha256) / $($State.candidateTreeManifest.sha256)
- Git normalization/metadata/evidence receipt SHA-256: $($State.gitIndexNormalization.sha256) / $($State.metadataPreview.sha256) / $($State.evidenceReceipt.sha256)
- Diff readability result/SHA-256: $($State.diffReadability.result) / $($State.diffReadability.sha256)
- Candidate Gate: $($State.candidateGate.status)
- Validation SHA-256: $($State.candidateGate.validationReportSha256)
- Workflow commit/SHA-256: $($State.workflowCommitOid) / $($State.workflowSha256)
- Skill source repository/ref/content/pin SHA-256: $($State.workflowSourceRepository) / $($State.workflowRef) / $($State.workflowSourceContentSha256) / $($State.workflowSourcePinSha256)
- Review Baseline path/blob/SHA-256: $($State.reviewBaselinePath) / $($State.reviewBaselineBlobOid) / $($State.reviewBaselineSha256)
- Localization mode/ids: $($State.localizationMode) / $localizationIds
- Localization raw/indexed/merged evidence: $localizationEvidence
- Localization workset SHA-256: $worksetSha
- Localization workset deletion receipt SHA-256: $worksetDeletionReceiptSha
- Localization target/approved-span/unchanged/removed/BLOCKED counts: $(@($State.evidenceTargetPaths).Count) / $approvedSpanCount / $unchangedTargetCount / $removedTargetCount / 0
- Localization scope: $localizationScope
- Archive filename/SHA-256: $($State.archive.filename) / $($State.archive.sha256)
- Source tuple contract SHA-256: $($State.sourceTuple.contractSha256)
- Source receipt SHA-256: $(if ($State.Contains('sourceReceipt') -and $State.sourceReceipt) { $State.sourceReceipt.sha256 } else { 'not-applicable' })
- Security overrides: $(@($State.securityOverrides) -join ', ')
- External review: $($State.externalReview.status)
$localizationTable
"@
}

function Assert-PublishedPrAtF {
    param([Collections.IDictionary] $State)
    $localHead = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $remoteHead = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('ls-remote', '--heads', $State.remote, "refs/heads/$($State.branch)")).output.Split("`t")[0]
    $pr = (Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'view', [string]$State.prNumber, '--json', 'state,isDraft,baseRefName,headRefName,headRefOid')).output | ConvertFrom-Json -AsHashtable
    if ($localHead -ne $State.evidenceChain.fOid -or $remoteHead -ne $localHead -or $pr.headRefOid -ne $localHead) {
        throw 'Local, remote, PR head, and immutable F are not identical.'
    }
    if ($pr.state -ne 'OPEN' -or $pr.isDraft -or $pr.baseRefName -ne $State.pullRequestBase -or $pr.headRefName -ne $State.branch) {
        throw 'Published PR state, draft flag, base, or head branch changed.'
    }
    [ordered]@{ localHead = $localHead; remoteHead = $remoteHead; prHead = $pr.headRefOid }
}

function Invoke-Publish {
    param([Collections.IDictionary] $State)
    if ([int]$State.schemaVersion -ge 15) { $null = Assert-LocalizationWorksetDeletionEvidence -State $State }
    $currentBody = Get-PrBody -State $State
    $currentBodySha = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($currentBody))
    if (@($State.completedStages) -contains 'publish') {
        $publicationPath = Join-Path $State.artifactsRoot 'publication.json'
        $publication = if (Test-Path -LiteralPath $publicationPath -PathType Leaf) { Get-Content -LiteralPath $publicationPath -Raw | ConvertFrom-Json -AsHashtable } else { $null }
        if (-not $publication -or -not $publication.Contains('prBodySha256') -or $publication.candidateGateSha256 -ne $State.candidateGate.validationReportSha256 -or $publication.prBodySha256 -ne $currentBodySha) {
            $State.completedStages = @($State.completedStages | Where-Object { $_ -ne 'publish' })
            Save-State -State $State
        }
    }
    $completed = Get-CompletedStageResult -State $State -Name 'publish'
    if ($completed) {
        $null = Assert-PublishedPrAtF -State $State
        return $completed
    }
    $stage = Start-Stage -Name 'publish'
    Assert-LockOwner -State $State
    if ($State.candidateGate.status -ne 'passed') { throw 'Publishing requires a passed candidateGate.' }
    $head = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', 'HEAD')).output.Trim()
    if ($head -ne $State.evidenceChain.fOid) { throw 'Local HEAD no longer equals F.' }
    $pushArguments = @('push', '--set-upstream', $State.remote, $State.branch)
    Assert-AppendOnlyPushArguments -Arguments $pushArguments -Remote $State.remote -Branch $State.branch
    $null = Invoke-Git -WorkingDirectory $State.worktreePath -Arguments $pushArguments
    $remoteHead = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('ls-remote', '--heads', $State.remote, "refs/heads/$($State.branch)")).output.Split("`t")[0]
    if ($remoteHead -ne $head) { throw 'Remote branch does not equal F after append-only push.' }

    # Reuse an existing PR for this exact branch instead of creating duplicate PRs.
    $existingJson = (Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'list', '--state', 'all', '--head', $State.branch, '--base', $State.pullRequestBase, '--json', 'number,url,state,isDraft,headRefOid')).output
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($existingJson)) {
        $parsedExisting = $existingJson | ConvertFrom-Json -AsHashtable
        $existing = @($parsedExisting)
    }
    $body = $currentBody
    if ($existing.Count -gt 1) { throw 'More than one existing PR matches the run branch.' }
    if ($existing.Count -eq 1) {
        if ($existing[0].state -ne 'OPEN') { throw 'The existing PR is closed; waiting for user recovery.' }
        $prNumber = [int]$existing[0].number
        $null = Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'edit', [string]$prNumber, '--body', $body)
        $prUrl = [string]$existing[0].url
    }
    else {
        $prUrl = (Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'create', '--base', $State.pullRequestBase, '--head', $State.branch, '--title', "Update $($State.mod)", '--body', $body)).output.Trim()
        $prNumber = [int]($prUrl.TrimEnd('/').Split('/')[-1])
    }
    $pr = (Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'view', [string]$prNumber, '--json', 'number,url,state,isDraft,baseRefName,headRefName,headRefOid')).output | ConvertFrom-Json -AsHashtable
    if ($pr.state -ne 'OPEN' -or $pr.isDraft -or $pr.baseRefName -ne $State.pullRequestBase -or $pr.headRefName -ne $State.branch -or $pr.headRefOid -ne $head) {
        throw 'Created or reused PR does not match the required open non-draft base/head/F tuple.'
    }
    $prUrl = [string]$pr.url
    $State.prNumber = $prNumber
    $State.prUrl = $prUrl
    $State.headOid = $head
    $State.published = $true
    $State.status = 'pr-open'
    $artifactPath = Join-Path $State.artifactsRoot 'publication.json'
    Write-AtomicJson -Path $artifactPath -Value ([ordered]@{ prNumber = $prNumber; prUrl = $prUrl; headOid = $head; remoteHeadOid = $remoteHead; branch = $State.branch; base = $State.pullRequestBase; candidateGateSha256 = $State.candidateGate.validationReportSha256; prBodySha256 = $currentBodySha; publishedAt = Get-UtcTimestamp })
    Complete-Stage -State $State -Context $stage -ArtifactSha256 (Get-FileSha256 -Path $artifactPath) -Data ([ordered]@{ prNumber = $prNumber; prUrl = $prUrl })
}

function Invoke-ReviewSnapshot {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'review-snapshot'
    if ($completed) {
        $null = Assert-PublishedPrAtF -State $State
        if ($State.status -ne 'awaiting-user-merge') {
            $State.status = 'awaiting-user-merge'
            Save-State -State $State
            $completed.status = $State.status
        }
        return $completed
    }
    $stage = Start-Stage -Name 'review-snapshot'
    if (-not $State.prNumber) { throw 'review-snapshot requires an existing PR.' }
    if ([string]::IsNullOrWhiteSpace($LocalReviewPath) -or -not (Test-Path -LiteralPath $LocalReviewPath -PathType Leaf)) {
        throw 'review-snapshot requires -LocalReviewPath from an Agent review of the current F using the packaged Review Baseline.'
    }
    $localReview = Get-Content -LiteralPath $LocalReviewPath -Raw | ConvertFrom-Json -AsHashtable
    if ($localReview.result -ne 'passed' -or $localReview.headOid -ne $State.evidenceChain.fOid -or $localReview.candidateGateSha256 -ne $State.candidateGate.validationReportSha256) {
        throw 'Local Review does not pass and bind the current F/Candidate Gate tuple.'
    }
    if (@($localReview.securityBlocking).Count -ne 0) { throw 'Local Review contains a security-blocking finding.' }
    $unresolved = @($localReview.findings | Where-Object { $_.disposition -notin @('keep', 'resolved', 'out-of-scope') })
    if ($unresolved.Count -ne 0) { throw 'Local Review contains findings without disposition.' }
    $localReviewArtifactPath = Join-Path $State.artifactsRoot 'review.json'
    Write-AtomicJson -Path $localReviewArtifactPath -Value $localReview
    $State.localReview = [ordered]@{ path = $localReviewArtifactPath; sha256 = Get-FileSha256 -Path $localReviewArtifactPath; result = 'passed'; reviewedAt = $localReview.reviewedAt }
    $State.reviewedOid = $State.evidenceChain.fOid
    $State.status = 'reviewing'
    Save-State -State $State

    $snapshotAt = Get-UtcTimestamp
    if ($State.localizationMode -eq 'none') {
        $external = [ordered]@{ status = 'not-applicable'; reason = 'localization mode none'; headOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
        $snapshot = [ordered]@{ headRefOid = $State.headOid; reviews = @(); reviewRequests = @(); comments = @() }
    }
    elseif (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        $external = [ordered]@{ status = 'unavailable'; reason = 'gh is unavailable'; headOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
        $snapshot = [ordered]@{}
    }
    else {
        $view = Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'view', [string]$State.prNumber, '--json', 'headRefOid,reviews,reviewRequests,comments') -AllowFailure
        if ($view.exitCode -ne 0) {
            $external = [ordered]@{ status = 'unavailable'; reason = "$($view.warning) $($view.output)".Trim(); headOid = $State.headOid; verifiedAt = $snapshotAt; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
            $snapshot = [ordered]@{}
        }
        else {
            $snapshot = $view.output | ConvertFrom-Json -AsHashtable
            if ($snapshot.headRefOid -ne $State.headOid) { throw 'PR head does not equal immutable F during review snapshot.' }
            $matching = @($snapshot.reviews | Where-Object { $_.author.login -match 'copilot-pull-request-reviewer' -and $_.commit.oid -eq $State.headOid } | Sort-Object submittedAt -Descending)
            $requested = @($snapshot.reviewRequests | Where-Object { $_.login -match 'copilot-pull-request-reviewer' })
            $external = if ($matching.Count -ge 1) {
                [ordered]@{ status = 'completed'; headOid = $State.headOid; reviewId = $matching[0].id; reviewerLogin = $matching[0].author.login; submittedAt = $matching[0].submittedAt; reviewCommitOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
            }
            else {
                $requestEvidence = $null
                if ($requested.Count -eq 0 -and $State.externalReview.status -eq 'not-requested') {
                    $repositoryName = ((Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('repo', 'view', '--json', 'nameWithOwner')).output | ConvertFrom-Json -AsHashtable).nameWithOwner
                    $request = Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('api', '--method', 'POST', "repos/$repositoryName/pulls/$($State.prNumber)/requested_reviewers", '-f', 'reviewers[]=copilot-pull-request-reviewer[bot]') -AllowFailure
                    $requestEvidence = [ordered]@{ exitCode = $request.exitCode; requestedAt = Get-UtcTimestamp; warning = $request.warning }
                }
                [ordered]@{ status = 'requested-pending'; reason = 'No completed Copilot review existed in the one bounded snapshot; no polling was scheduled.'; requestEvidence = $requestEvidence; headOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
            }
        }
    }
    if (-not $external.Contains('pollingWaitSeconds') -or [int64]$external.pollingWaitSeconds -ne 0) { throw 'External Review polling wait must remain zero.' }
    $artifactPath = Join-Path $State.artifactsRoot 'review-snapshot.json'
    Write-AtomicJson -Path $artifactPath -Value ([ordered]@{ snapshot = $snapshot; externalReview = $external })
    $State.externalReview = $external
    $State.reviewedOid = $State.headOid
    Save-State -State $State
    $updatedBody = Get-PrBody -State $State
    $null = Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'edit', [string]$State.prNumber, '--body', $updatedBody)
    $validator = Join-Path $PSScriptRoot 'Test-ModUpdateCandidate.ps1'
    $completion = & $validator -StatePath $State.statePath -ReviewCompletion `
        -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
    if ($completion.result -ne 'passed') { throw 'Independent Review completion validation rejected the current F.' }
    $State.status = 'awaiting-user-merge'
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $completion.sha256 -Data ([ordered]@{ externalReview = $external; localReview = $State.localReview; completionValidation = $completion })
}

function Resolve-InitialState {
    if ([string]::IsNullOrWhiteSpace($StatePath)) { throw "$Command requires -StatePath." }
    Read-State -Path ([IO.Path]::GetFullPath($StatePath))
}

function Invoke-StageCommand {
    param([string] $StageName, [Collections.IDictionary] $State)
    $script:activeReservationState = $State
    switch ($StageName) {
        'verify-source' { Invoke-VerifySource -State $State }
        'extract' { Invoke-Extract -State $State }
        'install' { Invoke-Install -State $State }
        'localization' { Invoke-Localization -State $State }
        'build-commits' { Invoke-BuildCommits -State $State }
        'validate' { Invoke-Validate -State $State }
        'publish' { Invoke-Publish -State $State }
        'review-snapshot' { Invoke-ReviewSnapshot -State $State }
        default { throw "Unsupported stage: $StageName" }
    }
}

$writerLease = $null
$activeStatePath = $null
$activeReservationLease = $null
$activeReservationState = $null
$activeSharedCoordinationLease = $null
try {
    $result = if ($Command -eq 'acquire-source') {
        Invoke-AcquireSource
    }
    elseif ($Command -eq 'claim') {
        if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
            $state = Read-State -Path $StatePath
            Ensure-RunWriterLock -State $state
        }
        Invoke-Claim
    }
    elseif ($Command -eq 'run') {
        $acquisitionResult = $null
        if ((-not $StatePath -or -not (Test-Path -LiteralPath $StatePath -PathType Leaf)) -and
            [string]::IsNullOrWhiteSpace($ArchivePath) -and
            -not [string]::IsNullOrWhiteSpace($SourceRequestPath)) {
            $acquisitionResult = Invoke-AcquireSource
            if ($acquisitionResult.status -eq 'delivered') {
                $ArchivePath = [string]$acquisitionResult.deliveredPath
                $SourceReceiptPath = [string]$acquisitionResult.receiptPath
                $SourceRequestPath = [string]$acquisitionResult.sourceRequestPath
                $RunId = [string]$acquisitionResult.runId
            }
        }
        if ($acquisitionResult -and $acquisitionResult.status -ne 'delivered') {
            $acquisitionResult
        }
        else {
            $state = if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
                Read-State -Path $StatePath
            }
            else {
                $claimResult = Invoke-Claim
                Read-State -Path $claimResult.statePath
            }
            Ensure-RunWriterLock -State $state
            $state = Read-State -Path $state.statePath
            $last = $null
            foreach ($stageName in @('verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate', 'publish', 'review-snapshot')) {
                if ($stageName -eq 'review-snapshot' -and [string]::IsNullOrWhiteSpace($LocalReviewPath) -and @($state.completedStages) -notcontains 'review-snapshot') {
                    $last = [ordered]@{
                        result = 'waiting-input'; runId = $state.runId; stage = 'local-review'; status = $state.status; statePath = $state.statePath
                        data = [ordered]@{ required = 'Expand and read the packaged Review Baseline, review the current F, then resume run with -LocalReviewPath.'; headOid = $state.evidenceChain.fOid; candidateGateSha256 = $state.candidateGate.validationReportSha256 }
                    }
                    break
                }
                $last = Invoke-StageCommand -StageName $stageName -State $state
                $state = Read-State -Path $state.statePath
                if ($last.result -eq 'waiting-input' -or $state.status -in @('waiting-input', 'waiting-user', 'waiting-system', 'automation-excluded')) { break }
                if (($Until -eq 'source-verified' -and $stageName -eq 'verify-source') -or $state.status -eq $Until) { break }
            }
            $last
        }
    }
    else {
        $state = Resolve-InitialState
        Ensure-RunWriterLock -State $state
        $state = Read-State -Path $state.statePath
        Invoke-StageCommand -StageName $Command -State $state
    }

    if ($PassThru) { $result } else { $result | ConvertTo-Json -Depth 40 -Compress }
}
catch {
    $errorResult = [ordered]@{
        result = 'failed'
        stage = $Command
        statePath = if ($activeStatePath) { $activeStatePath } else { $StatePath }
        error = $_.Exception.Message
        at = Get-UtcTimestamp
    }
    if ($writerLease -and $activeStatePath -and (Test-Path -LiteralPath $activeStatePath -PathType Leaf)) {
        try {
            $failedState = Read-State -Path $activeStatePath
            $failedState.lastError = $errorResult
            $failedState.status = if ($_.Exception.Message -match 'identity|security|archive|path|user') { 'waiting-user' } else { 'failed' }
            Save-State -State $failedState
        }
        catch { }
    }
    if ($PassThru) { throw }
    $errorResult | ConvertTo-Json -Depth 20 -Compress
    exit 1
}
finally {
    try {
        if ($activeReservationLease) {
            $reservationState = if ($activeStatePath -and (Test-Path -LiteralPath $activeStatePath -PathType Leaf)) {
                try { Read-State -Path $activeStatePath } catch { $activeReservationState }
            }
            else { $activeReservationState }
            Suspend-ModReservationWorker -State $reservationState
        }
    }
    finally {
        if ($writerLease) { Exit-RunWriterLock -Lease $writerLease }
    }
}
