#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('acquire-source', 'claim', 'verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate', 'publish', 'review-snapshot', 'finalize-merge', 'run')]
    [string] $Command,

    [Parameter(Mandatory)]
    [string] $RepositoryRoot,

    [string] $StatePath,
    [string] $ArchivePath,
    [string] $ModDirectory,
    [ValidateScript({
        $parsedRunId = [guid]::Empty
        if (-not [guid]::TryParse([string]$_, [ref]$parsedRunId)) {
            throw 'RunId must be a GUID, for example 7a923183-8edc-4a62-9af3-3bfe77023d02.'
        }
        $true
    })]
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
    [string] $SecurityOverridePath,
    [string] $LocalReviewPath,
    [string[]] $MetadataPath = @(),
    [string] $BaseRef = 'origin/main',
    [string] $WorktreeParent,
    [string] $Remote = 'origin',
    [string] $PullRequestBase = 'main',
    [ValidateSet('source-verified', 'localized', 'awaiting-user-merge')]
    [string] $Until = 'awaiting-user-merge',
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertFrom-JsonToken {
    param([AllowNull()][Newtonsoft.Json.Linq.JToken] $Token, [switch] $AsHashtable)
    if ($null -eq $Token -or $Token.Type -in @(
        [Newtonsoft.Json.Linq.JTokenType]::Null,
        [Newtonsoft.Json.Linq.JTokenType]::Undefined
    )) { return $null }
    if ($Token -is [Newtonsoft.Json.Linq.JObject]) {
        $properties = [ordered]@{}
        foreach ($property in $Token.Properties()) {
            $properties[[string]$property.Name] = ConvertFrom-JsonToken -Token $property.Value -AsHashtable:$AsHashtable
        }
        if ($AsHashtable) { return $properties }
        return [pscustomobject]$properties
    }
    if ($Token -is [Newtonsoft.Json.Linq.JArray]) {
        $items = [object[]]::new($Token.Count)
        for ($index = 0; $index -lt $Token.Count; $index++) {
            $items[$index] = ConvertFrom-JsonToken -Token $Token[$index] -AsHashtable:$AsHashtable
        }
        Write-Output -NoEnumerate $items
        return
    }
    ([Newtonsoft.Json.Linq.JValue]$Token).Value
}

function ConvertFrom-Json {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowEmptyString()]
        [string] $InputObject,
        [switch] $AsHashtable
    )
    process {
        $parameters = @{ InputObject = $InputObject }
        if ($AsHashtable) { $parameters.AsHashtable = $true }
        $nativeCommand = Get-Command -Name 'Microsoft.PowerShell.Utility\ConvertFrom-Json'
        if ($nativeCommand.Parameters.ContainsKey('DateKind')) {
            $parameters.DateKind = 'String'
            Microsoft.PowerShell.Utility\ConvertFrom-Json @parameters
            return
        }
        $settings = [Newtonsoft.Json.JsonSerializerSettings]::new()
        $settings.DateParseHandling = [Newtonsoft.Json.DateParseHandling]::None
        $token = [Newtonsoft.Json.JsonConvert]::DeserializeObject($InputObject, $settings)
        ConvertFrom-JsonToken -Token $token -AsHashtable:$AsHashtable
    }
}

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        for ($offset = 0; $offset -lt $Bytes.Length; $offset += 1MB) {
            $count = [Math]::Min(1MB, $Bytes.Length - $offset)
            $hasher.AppendData($Bytes, $offset, $count)
            Update-ActiveReservationHeartbeat
            Update-ActiveSharedCoordinationHeartbeat
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
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
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
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
    if ([string]$State.localizationMode -cne 'none' -and [string]$State.localizationMode -cne 'zh-tw') {
        throw "$Checkpoint reason localization mode must be exactly none or zh-tw."
    }
    $targetPaths = @($State.evidenceTargetPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $targetPathsJson = ConvertTo-Json -InputObject @($targetPaths) -Compress
    $targetPathsSha256 = Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($targetPathsJson))
    if ($targetPathsSha256 -cne [string]$State.evidenceTargetPathsSha256) {
        throw "$Checkpoint reason target paths differ from the immutable localization target contract."
    }
    $manifestSha256 = Get-FileSha256 -Path ([string]$State.localizationManifestPath)
    $manifest = Get-Content -LiteralPath ([string]$State.localizationManifestPath) -Raw | ConvertFrom-Json -AsHashtable
    $expectedManifestMode = if ([int]$State.schemaVersion -ge 15 -and [string]$State.localizationMode -ceq 'zh-tw') {
        'zh-tw-workset'
    }
    else { [string]$State.localizationMode }
    if ([string]$manifest.mode -cne $expectedManifestMode) {
        throw "$Checkpoint reason localization mode contradicts its immutable manifest."
    }
    $contractParentTreeOid = if ([string]::IsNullOrWhiteSpace($ParentTreeOid)) { $null } else { $ParentTreeOid }
    $contractTreeOid = if ([string]::IsNullOrWhiteSpace($TreeOid)) { $null } else { $TreeOid }
    $isNotApplicable = [string]$State.localizationMode -ceq 'none'
    $isKeep = $isNotApplicable -or $contractParentTreeOid -ceq $contractTreeOid
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
        parentTreeOid = $contractParentTreeOid
        treeOid = $contractTreeOid
        targetPathsSha256 = $targetPathsSha256
        targetPathCount = $targetPaths.Count
        localizationManifestSha256 = $manifestSha256
    }
    [ordered]@{
        schemaVersion = 1
        code = $code
        disposition = $contract.disposition
        localizationMode = $contract.localizationMode
        parentTreeOid = $contractParentTreeOid
        treeOid = $contractTreeOid
        targetPathsSha256 = $targetPathsSha256
        targetPathCount = $targetPaths.Count
        localizationManifestSha256 = $manifestSha256
        contractSha256 = Get-SourceTupleContractSha256 -Contract $contract
    }
}

function Test-MetadataSourceFieldMatch {
    param(
        [string] $RelativePath,
        [string] $Text,
        [string] $FieldName,
        [string] $FieldValue,
        [string] $NexusPageUrl
    )
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
    $readmeText = $Text
    if (-not [string]::IsNullOrWhiteSpace($NexusPageUrl)) {
        $targetUri = $null
        if (-not [Uri]::TryCreate($NexusPageUrl, [UriKind]::Absolute, [ref]$targetUri) -or
            $targetUri.Scheme -cne 'https' -or $targetUri.Host -notin @('nexusmods.com', 'www.nexusmods.com') -or
            -not [string]::IsNullOrEmpty($targetUri.UserInfo) -or -not [string]::IsNullOrEmpty($targetUri.Query) -or
            -not [string]::IsNullOrEmpty($targetUri.Fragment) -or -not $targetUri.IsDefaultPort) {
            return $false
        }
        $targetPathMatch = [regex]::Match(
            $targetUri.AbsolutePath.TrimEnd('/'),
            '^/warhammer40kdarktide/mods/(?<modId>\d+)$'
        )
        if (-not $targetPathMatch.Success) { return $false }
        $headingMatches = @([regex]::Matches(
            $Text,
            '(?m)^###\s+\[[^\]\r\n]+\]\((?i:https://(?:www\.)?nexusmods\.com)/warhammer40kdarktide/mods/(?<modId>\d+)/?(?:\?[^#)\r\n]*)?(?:#[^)\r\n]*)?\)\s*\r?$'
        ))
        if ($headingMatches.Count -ne 0) {
            $targetHeadings = @($headingMatches | Where-Object {
                [string]$_.Groups['modId'].Value -ceq [string]$targetPathMatch.Groups['modId'].Value
            })
            if ($targetHeadings.Count -ne 1) { return $false }
            $sectionStart = $targetHeadings[0].Index
            $tailStart = $targetHeadings[0].Index + $targetHeadings[0].Length
            $nextHeading = [regex]::Match($Text.Substring($tailStart), '(?m)^#{1,3}\s+')
            $sectionEnd = if ($nextHeading.Success) { $tailStart + $nextHeading.Index } else { $Text.Length }
            $readmeText = $Text.Substring($sectionStart, $sectionEnd - $sectionStart)
        }
    }
    $readmeLabels = [ordered]@{
        nexusModId = 'Nexus MOD ID'; nexusPageUrl = 'Nexus URL'; nexusPageVersion = 'Nexus page version'
        nexusPageUpdatedAt = 'Nexus last updated'; nexusMainFileId = 'Main file ID'; nexusMainFileVersion = 'Main file version'
        nexusMainFileUploadedAtUtc = 'Main file uploaded at UTC'; archiveFileName = 'Archive filename'
        archiveSize = 'Archive size bytes'; archiveSha256 = 'Archive SHA-256'; acquisitionMethod = 'Acquisition method'
    }
    if (-not $readmeLabels.Contains($FieldName)) { return $false }
    $label = [regex]::Escape([string]$readmeLabels[$FieldName])
    $matchesForLabel = @([regex]::Matches($readmeText, "(?m)^\s*-\s+$label\s*:\s*([^`r`n]*)`r?$") )
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

function Write-BytesWithHeartbeat {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes
    )
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        for ($offset = [int64]0; $offset -lt $Bytes.LongLength; $offset += 1MB) {
            $count = [int][Math]::Min([int64]1MB, $Bytes.LongLength - $offset)
            $stream.Write($Bytes, [int]$offset, $count)
            Update-ActiveReservationHeartbeat
            Update-ActiveSharedCoordinationHeartbeat
        }
        $stream.Flush($true)
        Update-ActiveReservationHeartbeat -Force
        Update-ActiveSharedCoordinationHeartbeat -Force
    }
    finally { $stream.Dispose() }
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][byte[]] $Bytes
    )
    Update-ActiveReservationHeartbeat -Force
    Update-ActiveSharedCoordinationHeartbeat -Force
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.bin')
    try {
        Write-BytesWithHeartbeat -Path $temporary -Bytes $Bytes
        Update-ActiveReservationHeartbeat -Force
        Update-ActiveSharedCoordinationHeartbeat -Force
        [IO.File]::Move($temporary, $fullPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { [IO.File]::Delete($temporary) }
    }
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
$luaLocalizationScannerModulePath = Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1'
Import-Module -Name $luaLocalizationScannerModulePath -Force -ErrorAction Stop
$mergeFinalizationScriptPath = Join-Path $PSScriptRoot 'Finalize-ModUpdateMerge.ps1'
. $mergeFinalizationScriptPath

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
    if ($script:activeStageContext -and $lease.Contains('waitingMilliseconds')) {
        $null = Add-StageWait -Context $script:activeStageContext -Reason 'coordination' `
            -Milliseconds ([int64]$lease.waitingMilliseconds)
    }
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
    $requiresCoordination = $gitCommand -in @('fetch', 'push', 'update-ref') -or
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
                $script:activeReservationState.coordinationReceipts = @($priorReceipts) + @($coordinationReceipt)
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
    try {
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $copyTask.IsCompleted -and $errorTask.IsCompleted)) {
            if (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
            else { [Threading.Tasks.Task]::Delay(50).Wait() }
            Update-ActiveReservationHeartbeat
            Update-ActiveSharedCoordinationHeartbeat
        }
        $null = $copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "git cat-file failed: $errorText" }
        $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function New-Manifest {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $OutputPath,
        [string] $Kind = 'files',
        [AllowNull()][Collections.IDictionary] $SecurityDispositions
    )
    $rootFull = [IO.Path]::GetFullPath($Root)
    $files = @(
        Get-ChildItem -LiteralPath $rootFull -File -Recurse |
            ForEach-Object {
                $relative = [IO.Path]::GetRelativePath($rootFull, $_.FullName).Replace('\', '/')
                $record = [ordered]@{
                    path = $relative
                    size = $_.Length
                    sha256 = Get-FileSha256 -Path $_.FullName
                }
                if ($SecurityDispositions -and $SecurityDispositions.Contains($relative)) {
                    $record.securityDisposition = $SecurityDispositions[$relative]
                }
                $record
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

function Get-ArchivePayloadRisk {
    param(
        [Parameter(Mandatory)][string] $RelativePath,
        [Parameter(Mandatory)][byte[]] $Bytes,
        [int64] $ExternalAttributes = 0
    )
    $extension = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($extension -in @('.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.cab', '.iso', '.jar')) {
        return 'nested-archive'
    }
    if ($extension -in @('.dll', '.exe', '.com', '.scr', '.msi', '.msp', '.cpl', '.ocx', '.sys', '.drv', '.efi', '.so', '.dylib')) {
        return 'native-executable'
    }
    if ($extension -in @('.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.sh', '.bash', '.zsh', '.fish', '.vbs', '.vbe', '.wsf', '.wsh', '.hta', '.reg')) {
        return 'install-or-system-script'
    }
    $unixMode = ($ExternalAttributes -shr 16) -band 0xFFFF
    $hasUnixMode = ($unixMode -band 0xF000) -ne 0 -or ($ExternalAttributes -band 0xFFFF) -eq 0
    if ($hasUnixMode -and ($unixMode -band 73) -ne 0) { return 'native-executable' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x4D -and $Bytes[1] -eq 0x5A) { return 'native-executable' }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0x7F -and $Bytes[1] -eq 0x45 -and $Bytes[2] -eq 0x4C -and $Bytes[3] -eq 0x46) {
        return 'native-executable'
    }
    if ($Bytes.Length -ge 4) {
        $magic = [Convert]::ToHexString($Bytes[0..3])
        if ($magic -in @('FEEDFACE', 'CEFAEDFE', 'FEEDFACF', 'CFFAEDFE', 'CAFEBABE')) { return 'native-executable' }
    }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x23 -and $Bytes[1] -eq 0x21) { return 'install-or-system-script' }
    $null
}

function Import-SecurityOverrides {
    param([Collections.IDictionary] $State, [AllowEmptyString()][string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $fullPath = [IO.Path]::GetFullPath($Path)
    $item = Get-Item -LiteralPath $fullPath -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Security override input must be one ordinary non-reparse JSON file.'
    }
    $overrideDocument = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$overrideDocument.schemaVersion -ne 1 -or [string]$overrideDocument.runId -cne [string]$State.runId -or
        [string]$overrideDocument.archiveSha256 -cne [string]$State.archive.sha256) {
        throw 'Security override input does not bind this exact run and archive SHA-256.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $approvals = [Collections.Generic.List[object]]::new()
    foreach ($approval in @($overrideDocument.approvals)) {
        if ($approval -isnot [Collections.IDictionary]) { throw 'Security override approval must be an object.' }
        $relative = [string]$approval.relativePath
        $fileSha256 = [string]$approval.fileSha256
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Contains('\') -or [IO.Path]::IsPathRooted($relative) -or
            $relative.Contains(':') -or @($relative.Split('/')) -contains '..' -or
            -not $relative.StartsWith(([string]$State.repoModDirectory + '/'), [StringComparison]::Ordinal)) {
            throw 'Security override relativePath must be one exact normalized file below the canonical archive root.'
        }
        if ($fileSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Security override fileSha256 must be 64 lowercase hexadecimal characters.' }
        $key = "$relative`n$fileSha256"
        if (-not $seen.Add($key)) { throw 'Security override contains a duplicate approval tuple.' }
        $approvals.Add([ordered]@{ archiveSha256 = [string]$State.archive.sha256; relativePath = $relative; fileSha256 = $fileSha256 })
    }
    if ($approvals.Count -eq 0) { throw 'Security override input contains no exact approvals.' }
    $artifactPath = Join-Path ([string]$State.artifactsRoot) 'security-overrides.json'
    Write-AtomicJson -Path $artifactPath -Value ([ordered]@{
        schemaVersion = 1; runId = $State.runId; archiveSha256 = $State.archive.sha256
        approvals = $approvals; importedAt = Get-UtcTimestamp
    })
    $State.securityOverrides = $approvals
    $State.securityOverrideReceipt = [ordered]@{ path = $artifactPath; sha256 = Get-FileSha256 -Path $artifactPath }
    Save-State -State $State
}

function Assert-ArchivePayloadSecurity {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][string] $ExtractedRoot,
        [Parameter(Mandatory)][object[]] $Entries
    )
    $entryAttributes = [ordered]@{}
    foreach ($entry in @($Entries | Where-Object { -not $_.directory })) {
        $entryAttributes[[string]$entry.path] = [int64]$entry.externalAttributes
    }
    $overrides = @($State.securityOverrides)
    $usedOverrides = [Collections.Generic.HashSet[int]]::new()
    $dispositions = [ordered]@{}
    $c0Oid = if ($State.evidenceChain -and -not [string]::IsNullOrWhiteSpace([string]$State.evidenceChain.c0Oid)) {
        [string]$State.evidenceChain.c0Oid
    }
    else { [string]$State.baseOid }
    foreach ($file in Get-ChildItem -LiteralPath $ExtractedRoot -File -Recurse | Sort-Object FullName) {
        $relative = [IO.Path]::GetRelativePath($ExtractedRoot, $file.FullName).Replace('\', '/')
        $bytes = Read-FileBytesWithHeartbeat -Path $file.FullName
        $risk = Get-ArchivePayloadRisk -RelativePath $relative -Bytes $bytes -ExternalAttributes ([int64]$entryAttributes[$relative])
        if ([string]::IsNullOrWhiteSpace($risk)) {
            $dispositions[$relative] = [ordered]@{ result = 'not-risky' }
            continue
        }
        $fileSha256 = Get-Sha256Bytes -Bytes $bytes
        $modRelative = $relative.Substring(([string]$State.repoModDirectory).Length).TrimStart('/')
        $repositoryPath = if ([string]::IsNullOrWhiteSpace($modRelative)) { [string]$State.modRelativePath } else { "$($State.modRelativePath)/$modRelative" }
        $oldSha256 = $null
        if (-not [string]::IsNullOrWhiteSpace($c0Oid)) {
            $exists = Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('cat-file', '-e', "${c0Oid}:$repositoryPath") -AllowFailure
            if ($exists.exitCode -eq 0) {
                $blobOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', "${c0Oid}:$repositoryPath")).output.Trim()
                $oldSha256 = Get-Sha256Bytes -Bytes (Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $blobOid)
            }
            elseif ($exists.exitCode -notin @(1, 128)) { throw "Unable to compare risky archive payload with C0: $repositoryPath" }
        }
        if ($oldSha256 -ceq $fileSha256) {
            $dispositions[$relative] = [ordered]@{ result = 'unchanged-from-c0'; risk = $risk; fileSha256 = $fileSha256; c0Sha256 = $oldSha256 }
            continue
        }
        $matchingIndexes = @(
            for ($index = 0; $index -lt $overrides.Count; $index++) {
                $override = $overrides[$index]
                if ($override -is [Collections.IDictionary] -and
                    [string]$override.archiveSha256 -ceq [string]$State.archive.sha256 -and
                    [string]$override.relativePath -ceq $relative -and
                    [string]$override.fileSha256 -ceq $fileSha256) { $index }
            }
        )
        if ($matchingIndexes.Count -ne 1) {
            throw "Security approval required for changed risky archive payload: $risk $relative fileSha256=$fileSha256 archiveSha256=$($State.archive.sha256)"
        }
        $null = $usedOverrides.Add([int]$matchingIndexes[0])
        $dispositions[$relative] = [ordered]@{ result = 'approved-exact-tuple'; risk = $risk; fileSha256 = $fileSha256; c0Sha256 = $oldSha256; archiveSha256 = $State.archive.sha256 }
    }
    if ($usedOverrides.Count -ne $overrides.Count) { throw 'Security override does not match one unique changed risky payload in this archive.' }
    $dispositions
}

function Test-CrlfNormalizationOnly {
    param([byte[]] $RawBytes, [byte[]] $IndexedBytes)
    $normalized = [IO.MemoryStream]::new()
    try {
        for ($index = 0; $index -lt $RawBytes.LongLength; $index++) {
            if (($index -band 0xFFFFF) -eq 0) { Update-ActiveReservationHeartbeat }
            if ($RawBytes[$index] -eq 13 -and ($index + 1) -lt $RawBytes.LongLength -and $RawBytes[$index + 1] -eq 10) {
                continue
            }
            $normalized.WriteByte($RawBytes[$index])
        }
        $candidate = $normalized.ToArray()
        if ($candidate.LongLength -ne $IndexedBytes.LongLength) { return $false }
        for ($index = 0; $index -lt $candidate.LongLength; $index++) {
            if (($index -band 0xFFFFF) -eq 0) { Update-ActiveReservationHeartbeat }
            if ($candidate[$index] -ne $IndexedBytes[$index]) { return $false }
        }
        $true
    }
    finally { $normalized.Dispose() }
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
        'finalize-merge' { Join-Path ([string]$State.artifactsRoot) 'merge-finalization.json' }
    }
}

function New-GitNormalizationManifest {
    param([Collections.IDictionary] $State)
    $records = [Collections.Generic.List[object]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $State.installRoot -File -Recurse | Sort-Object FullName) {
        $relativeToRepository = [IO.Path]::GetRelativePath($State.worktreePath, $file.FullName).Replace('\', '/')
        $relativeToMod = [IO.Path]::GetRelativePath($State.installRoot, $file.FullName).Replace('\', '/')
        $rawBytes = Read-FileBytesWithHeartbeat -Path $file.FullName
        $blobOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.autocrlf=true', 'hash-object', '-w', "--path=$relativeToRepository", '--', $file.FullName)).output.Trim()
        $indexedBytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $blobOid
        $transform = if ((Get-Sha256Bytes -Bytes $rawBytes) -eq (Get-Sha256Bytes -Bytes $indexedBytes)) { 'none' }
            elseif (Test-CrlfNormalizationOnly -RawBytes $rawBytes -IndexedBytes $indexedBytes) { 'crlf-to-lf' }
            else { throw "Git clean processing changed bytes beyond CRLF-to-LF for $relativeToRepository." }
        $records.Add([ordered]@{
            path = $relativeToMod
            repositoryPath = $relativeToRepository
            rawSize = $rawBytes.LongLength
            rawSha256 = Get-Sha256Bytes -Bytes $rawBytes
            indexedSize = $indexedBytes.LongLength
            indexedSha256 = Get-Sha256Bytes -Bytes $indexedBytes
            blobOid = $blobOid
            transform = $transform
            whitespacePreserved = $true
        })
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
    $files = [Collections.Generic.List[object]]::new()
    foreach ($line in @($listing -split "`r?`n" | Where-Object { $_ })) {
        if ($line -notmatch '^[0-7]{6} blob ([0-9a-f]{40})\s+(\d+)\t(.+)$') { throw "Unable to parse candidate Git tree entry: $line" }
        $repositoryPath = $Matches[3]
        $relative = $repositoryPath.Substring(([string]$State.modRelativePath).Length).TrimStart('/')
        $bytes = Get-GitBlobBytes -WorkingDirectory $State.worktreePath -Object $Matches[1]
        if ($bytes.LongLength -ne [int64]$Matches[2]) { throw "Candidate Git blob size mismatch: $repositoryPath" }
        $files.Add([ordered]@{
            path = $relative
            repositoryPath = $repositoryPath
            blobOid = $Matches[1]
            size = $bytes.LongLength
            sha256 = Get-Sha256Bytes -Bytes $bytes
        })
    }
    $path = Join-Path $State.artifactsRoot 'candidate-tree-manifest.json'
    Write-AtomicJson -Path $path -Value ([ordered]@{
        schemaVersion = 1
        kind = 'candidate-git-tree'
        commitOid = $CommitOid
        treeOid = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', "$CommitOid^{tree}")).output.Trim()
        files = @($files | Sort-Object { $_.path })
    })
    [ordered]@{ path = $path; size = (Get-Item -LiteralPath $path).Length; sha256 = Get-FileSha256 -Path $path; fileCount = $files.Count }
}

function Start-Stage {
    param(
        [string] $Name,
        [scriptblock] $MonotonicClock = { [Environment]::TickCount64 }
    )
    $context = [ordered]@{
        name = $Name
        startedAt = Get-UtcTimestamp
        monotonicClock = $MonotonicClock
        startedMonotonicMilliseconds = [int64](& $MonotonicClock)
        stabilityObservationMilliseconds = [int64]0
        coordinationWaitMilliseconds = [int64]0
    }
    $script:lastFailedStageName = $null
    $script:activeStageContext = $context
    $context
}

function Add-StageWait {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Context,
        [Parameter(Mandatory)][ValidateSet('stability-observation', 'coordination')][string] $Reason,
        [Parameter(Mandatory)][ValidateRange(0, [int64]::MaxValue)][int64] $Milliseconds
    )
    $field = if ($Reason -ceq 'stability-observation') { 'stabilityObservationMilliseconds' } else { 'coordinationWaitMilliseconds' }
    $Context[$field] = [int64]$Context[$field] + $Milliseconds
}

function Get-StageTimingBreakdown {
    param([Parameter(Mandatory)][Collections.IDictionary] $Context)
    $wallClockMilliseconds = [int64](& $Context.monotonicClock) - [int64]$Context.startedMonotonicMilliseconds
    if ($wallClockMilliseconds -lt 0) { throw 'Stage monotonic clock moved backwards.' }
    $stabilityObservationMilliseconds = [int64]$Context.stabilityObservationMilliseconds
    $coordinationWaitMilliseconds = [int64]$Context.coordinationWaitMilliseconds
    $waitingMilliseconds = $stabilityObservationMilliseconds + $coordinationWaitMilliseconds
    if ($waitingMilliseconds -gt $wallClockMilliseconds) { throw 'Classified stage waits exceed measured wall-clock time.' }
    [ordered]@{
        wallClockMilliseconds = $wallClockMilliseconds
        activeMilliseconds = $wallClockMilliseconds - $waitingMilliseconds
        waitingMilliseconds = $waitingMilliseconds
        stabilityObservationMilliseconds = $stabilityObservationMilliseconds
        coordinationWaitMilliseconds = $coordinationWaitMilliseconds
    }
}

function Complete-Stage {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $Context,
        [Parameter(Mandatory)][string] $ArtifactSha256,
        [Collections.IDictionary] $Data = @{}
    )
    $name = [string]$Context.name
    if (-not $State.Contains('stageTimings')) { $State.stageTimings = [ordered]@{} }
    if (-not $State.Contains('completedStages')) { $State.completedStages = @() }
    $previousTiming = if ($State.stageTimings.Contains($name)) { $State.stageTimings[$name] } else { $null }
    $previousAttempt = if ($previousTiming) { [int]$previousTiming.attempt } else { 0 }
    $attemptHistory = @(Get-StageAttemptHistory -Timing $previousTiming)
    $breakdown = Get-StageTimingBreakdown -Context $Context
    $attemptRecord = [ordered]@{
        attempt = $previousAttempt + 1
        startedAt = $Context.startedAt
        completedAt = Get-UtcTimestamp
        wallClockMilliseconds = $breakdown.wallClockMilliseconds
        activeMilliseconds = $breakdown.activeMilliseconds
        waitingMilliseconds = $breakdown.waitingMilliseconds
        stabilityObservationMilliseconds = $breakdown.stabilityObservationMilliseconds
        coordinationWaitMilliseconds = $breakdown.coordinationWaitMilliseconds
        result = 'passed'
        artifactSha256 = $ArtifactSha256
    }
    $timing = [ordered]@{}
    foreach ($field in $attemptRecord.Keys) { $timing[$field] = $attemptRecord[$field] }
    $timing.attempts = @($attemptHistory) + @($attemptRecord)
    $State.stageTimings[$name] = $timing
    $State.completedStages = @($State.completedStages | Where-Object { $_ -ne $name }) + $name
    if ($script:activeStageContext -eq $Context) { $script:activeStageContext = $null }
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

function Get-StageAttemptHistory {
    param([AllowNull()][Collections.IDictionary] $Timing)
    if (-not $Timing) { return @() }
    if ($Timing.Contains('attempts')) { return @($Timing.attempts) }
    $legacy = [ordered]@{}
    foreach ($field in $Timing.Keys) {
        if ([string]$field -cne 'attempts') { $legacy[$field] = $Timing[$field] }
    }
    @($legacy)
}

function Fail-Stage {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $Context,
        [Parameter(Mandatory)][string] $ErrorMessage,
        [string] $PartialCheckpoint,
        [string] $RecoveryDisposition
    )
    $name = [string]$Context.name
    if (-not $State.Contains('stageTimings')) { $State.stageTimings = [ordered]@{} }
    $previousTiming = if ($State.stageTimings.Contains($name)) { $State.stageTimings[$name] } else { $null }
    $previousAttempt = if ($previousTiming) { [int]$previousTiming.attempt } else { 0 }
    $attemptHistory = @(Get-StageAttemptHistory -Timing $previousTiming)
    $breakdown = Get-StageTimingBreakdown -Context $Context
    $attemptRecord = [ordered]@{
        attempt = $previousAttempt + 1
        startedAt = $Context.startedAt
        completedAt = Get-UtcTimestamp
        wallClockMilliseconds = $breakdown.wallClockMilliseconds
        activeMilliseconds = $breakdown.activeMilliseconds
        waitingMilliseconds = $breakdown.waitingMilliseconds
        stabilityObservationMilliseconds = $breakdown.stabilityObservationMilliseconds
        coordinationWaitMilliseconds = $breakdown.coordinationWaitMilliseconds
        result = 'failed'
        error = $ErrorMessage
        partialCheckpoint = $PartialCheckpoint
        recoveryDisposition = $RecoveryDisposition
    }
    $timing = [ordered]@{}
    foreach ($field in $attemptRecord.Keys) { $timing[$field] = $attemptRecord[$field] }
    $timing.attempts = @($attemptHistory) + @($attemptRecord)
    $State.stageTimings[$name] = $timing
    $script:lastFailedStageName = $name
    if ($script:activeStageContext -eq $Context) { $script:activeStageContext = $null }
    Save-State -State $State
    $timing
}

function Suspend-Stage {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $Context,
        [Parameter(Mandatory)][ValidateSet('waiting-input', 'waiting-user', 'waiting-system', 'automation-excluded')][string] $Result,
        [AllowEmptyString()][string] $ArtifactSha256,
        [string] $OutputStage,
        [Collections.IDictionary] $Data = @{}
    )
    $name = [string]$Context.name
    if (-not $State.Contains('stageTimings')) { $State.stageTimings = [ordered]@{} }
    $previousTiming = if ($State.stageTimings.Contains($name)) { $State.stageTimings[$name] } else { $null }
    $previousAttempt = if ($previousTiming) { [int]$previousTiming.attempt } else { 0 }
    $attemptHistory = @(Get-StageAttemptHistory -Timing $previousTiming)
    $breakdown = Get-StageTimingBreakdown -Context $Context
    $attemptRecord = [ordered]@{
        attempt = $previousAttempt + 1
        startedAt = $Context.startedAt
        completedAt = Get-UtcTimestamp
        wallClockMilliseconds = $breakdown.wallClockMilliseconds
        activeMilliseconds = $breakdown.activeMilliseconds
        waitingMilliseconds = $breakdown.waitingMilliseconds
        stabilityObservationMilliseconds = $breakdown.stabilityObservationMilliseconds
        coordinationWaitMilliseconds = $breakdown.coordinationWaitMilliseconds
        result = $Result
        artifactSha256 = if ([string]::IsNullOrWhiteSpace($ArtifactSha256)) { $null } else { $ArtifactSha256 }
    }
    $timing = [ordered]@{}
    foreach ($field in $attemptRecord.Keys) { $timing[$field] = $attemptRecord[$field] }
    $timing.attempts = @($attemptHistory) + @($attemptRecord)
    $State.stageTimings[$name] = $timing
    if ($script:activeStageContext -eq $Context) { $script:activeStageContext = $null }
    Save-State -State $State
    [ordered]@{
        result = $Result
        runId = $State.runId
        stage = if ([string]::IsNullOrWhiteSpace($OutputStage)) { $name } else { $OutputStage }
        status = $State.status
        statePath = $State.statePath
        stageTimings = $timing
        artifactSha256 = $attemptRecord.artifactSha256
        data = $Data
    }
}

function Assert-RunLocalSkillPinRecord {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $PinRecord,
        [Parameter(Mandatory)][string] $ActualPinSha256
    )
    $checks = [ordered]@{
        'pin bytes' = @([string]$State.workflowSourcePinSha256, $ActualPinSha256)
        'repository' = @([string]$State.workflowSourceRepository, [string]$PinRecord.repository)
        'requestedRef' = @([string]$State.workflowRef, [string]$PinRecord.requestedRef)
        'resolvedCommit' = @([string]$State.workflowCommitOid, [string]$PinRecord.resolvedCommit)
        'resolvedVersion' = @([string]$State.workflowSourceVersion, [string]$PinRecord.resolvedVersion)
        'contentSha256' = @([string]$State.workflowSourceContentSha256, [string]$PinRecord.contentSha256)
        'pin receipt' = @([string]$State.workflowSourcePinSha256, [string]$PinRecord.pinSha256)
    }
    foreach ($name in $checks.Keys) {
        $values = @($checks[$name])
        if ([string]::IsNullOrWhiteSpace($values[0]) -or [string]::IsNullOrWhiteSpace($values[1]) -or
            $values[0] -cne $values[1]) {
            throw "Skill package drift: run-local $name does not match the installed package pin."
        }
    }
    $PinRecord
}

function Assert-LegacySchema14SkillPackageRecord {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $Integrity
    )
    if ([string]$Integrity.result -cne 'passed' -or
        [string]$Integrity.authoringSourceCommit -cne [string]$State.workflowCommitOid -or
        [string]$Integrity.workflow.originalPath -cne [string]$State.workflowPath -or
        [string]$Integrity.workflow.gitBlobOid -cne [string]$State.workflowBlobOid -or
        [string]$Integrity.workflow.sha256 -cne [string]$State.workflowSha256 -or
        [string]$Integrity.reviewBaseline.originalPath -cne [string]$State.reviewBaselinePath -or
        [string]$Integrity.reviewBaseline.gitBlobOid -cne [string]$State.reviewBaselineBlobOid -or
        [string]$Integrity.reviewBaseline.sha256 -cne [string]$State.reviewBaselineSha256) {
        throw 'Legacy Schema 14 authoring reference tuple does not match the installed package.'
    }
    [ordered]@{ result = 'legacy-schema-14'; pinPath = $null; workflowSha256 = [string]$State.workflowSha256 }
}

function Assert-RunLocalSkillPackage {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    try {
        $integrityScript = Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1'
        $hasPinPath = $State.Contains('workflowSourcePinPath') -and
            -not [string]::IsNullOrWhiteSpace([string]$State.workflowSourcePinPath)
        $hasPinSha256 = $State.Contains('workflowSourcePinSha256') -and
            -not [string]::IsNullOrWhiteSpace([string]$State.workflowSourcePinSha256)
        if (-not $hasPinPath -and -not $hasPinSha256) {
            $schemaVersion = if ($State.Contains('workflowSchemaVersion')) { [int]$State.workflowSchemaVersion }
                elseif ($State.Contains('schemaVersion')) { [int]$State.schemaVersion }
                elseif ($State.Contains('schema_version')) { [int]$State.schema_version }
                else { 0 }
            if ($schemaVersion -eq 14) {
                $legacyIntegrity = & $integrityScript -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
                $legacyIntegrityRecord = $legacyIntegrity | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
                return (Assert-LegacySchema14SkillPackageRecord -State $State -Integrity $legacyIntegrityRecord)
            }
            throw 'Run-local Skill source pin is missing.'
        }
        if (-not $hasPinPath -or -not $hasPinSha256) {
            throw 'Run-local Skill source pin record is incomplete.'
        }
        $expectedPinPath = [IO.Path]::GetFullPath((Join-Path ([string]$State.runRoot) 'review-artifacts/skill-source-pin.json'))
        $pinPath = [IO.Path]::GetFullPath([string]$State.workflowSourcePinPath)
        if ($pinPath -cne $expectedPinPath) { throw 'Run-local pin path changed.' }
        $null = Assert-NoReparsePath -Path $pinPath -Root ([string]$State.repositoryRoot) -Label 'Run-local Skill source pin'
        if (-not (Test-Path -LiteralPath $pinPath -PathType Leaf)) { throw 'Run-local Skill source pin is missing.' }
        $actualPinSha = Get-FileSha256 -Path $pinPath
        $integrity = & $integrityScript -SkillSourcePinPath $pinPath `
            -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
        if ($integrity.result -cne 'passed' -or -not $integrity.skillSourcePin) {
            throw 'Installed package integrity did not pass.'
        }
        $pinRecord = $integrity.skillSourcePin | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $null = Assert-RunLocalSkillPinRecord -State $State -PinRecord $pinRecord -ActualPinSha256 $actualPinSha
        [ordered]@{ result = 'passed'; pinPath = $pinPath; pinSha256 = $actualPinSha; pin = $pinRecord }
    }
    catch {
        $message = $_.Exception.Message
        if ($message -match '^Skill package drift:') { throw $message }
        throw "Skill package drift: $message"
    }
}

function Get-CompletedStageResult {
    param([Collections.IDictionary] $State, [string] $Name)
    if (@($State.completedStages) -contains $Name) {
        $null = Assert-RunLocalSkillPackage -State $State
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
        if ($Name -ceq 'localization' -and [string]$State.status -ceq 'installed') {
            $State.status = 'localized'
            Save-State -State $State
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

function Test-ReservationLeaseMatchesOwner {
    param(
        [AllowNull()][Collections.IDictionary] $Lease,
        [AllowNull()][Collections.IDictionary] $Owner
    )
    if (-not $Lease -or -not $Owner) { return $false }
    foreach ($field in @('runId', 'reservationToken', 'workerToken', 'machineName', 'workerId', 'workerProcessStartTicks')) {
        if (-not $Lease.Contains($field) -or -not $Owner.Contains($field)) { return $false }
    }
    [string]$Owner.leaseMode -ceq 'active' -and
        [string]$Owner.runId -ceq [string]$Lease.runId -and
        [string]$Owner.reservationToken -ceq [string]$Lease.reservationToken -and
        [string]$Owner.workerToken -ceq [string]$Lease.workerToken -and
        [string]$Owner.machineName -ceq [string]$Lease.machineName -and
        [int]$Owner.workerId -eq [int]$Lease.workerId -and
        [int64]$Owner.workerProcessStartTicks -eq [int64]$Lease.workerProcessStartTicks
}

function Enter-ModReservationWorker {
    param([Collections.IDictionary] $State)
    Assert-LockOwner -State $State
    $owner = Read-ModReservationOwner -ModLockPath ([string]$State.modLockPath) -Repository ([string]$State.repositoryRoot)
    $reservationToken = [string]$owner.reservationToken
    $previousWorkerToken = [string]$owner.workerToken
    $identity = Get-CurrentProcessIdentity
    $sameWorker = Test-ReservationLeaseMatchesOwner -Lease $script:activeReservationLease -Owner $owner

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
    if (-not (Test-ReservationLeaseMatchesOwner -Lease $lease -Owner $owner)) {
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
    # Child scripts invoke the supplied heartbeat callback in their own script
    # scope. Use dynamic lookup here, then keep the immutable lease explicit.
    $lease = $activeReservationLease
    if (-not $lease) { return }
    if (-not $Force -and ([DateTimeOffset]::UtcNow - [DateTimeOffset]$lease.lastHeartbeatUtc).TotalSeconds -lt 30) { return }
    $owner = Read-ModReservationOwner -ModLockPath ([string]$lease.modLockPath) -Repository ([string]$lease.repositoryRoot)
    if (-not (Test-ReservationLeaseMatchesOwner -Lease $lease -Owner $owner)) {
        throw 'MOD reservation ownership changed after this worker acquired its immutable lease.'
    }
    $owner.heartbeat = Get-UtcTimestamp
    Write-ModReservationOwner -ModLockPath ([string]$lease.modLockPath) -Repository ([string]$lease.repositoryRoot) -Value $owner `
        -ExpectedReservationToken ([string]$lease.reservationToken) -ExpectedWorkerToken ([string]$lease.workerToken)
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
        $null = Assert-RunLocalSkillPackage -State $State
        Enter-ModReservationWorker -State $State
        try {
            $script:writerLease = Enter-RunWriterLock -State $State
        }
        catch {
            Suspend-ModReservationWorker -State $State
            throw
        }
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
    $publishedPreparedOwner = $null
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
            $publishedPreparedOwner = $preparedOwner
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
    $createdByThisInvocation = $publishedPreparedOwner -and
        [string]$owner.reservationToken -ceq [string]$publishedPreparedOwner.reservationToken -and
        [string]$owner.workerToken -ceq [string]$publishedPreparedOwner.workerToken -and
        [string]$owner.machineName -ceq [string]$publishedPreparedOwner.machineName -and
        [int]$owner.workerId -eq [int]$publishedPreparedOwner.workerId -and
        [int64]$owner.workerProcessStartTicks -eq [int64]$publishedPreparedOwner.workerProcessStartTicks
    $sameWorker = $createdByThisInvocation -or
        (Test-ReservationLeaseMatchesOwner -Lease $script:activeReservationLease -Owner $owner)
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

    foreach ($path in $localizationPaths) {
        $blobOid = (Invoke-Git -WorkingDirectory $Repository -Arguments @('rev-parse', "$BaseOid`:$path")).output.Trim()
        $bytes = Get-GitBlobBytes -WorkingDirectory $Repository -Object $blobOid
        $document = Get-LuaLocalizationDocument -Bytes $bytes -SourceId $path -HeartbeatAction { Update-ActiveReservationHeartbeat }
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
    if (-not $incomingExists -and -not $deliveredExists) { throw 'Interrupted source delivery has no recoverable file.' }
    $candidate = if ($deliveredExists) { $deliveredCandidate } else { $incomingCandidate }
    $null = Assert-NoReparsePath -Path $candidate -Root $RepositoryRoot -Label 'Interrupted source file'
    $source = [IO.File]::Open($candidate, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    $temporaryDelivery = $null
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $source.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $readCount)
            Update-ActiveReservationHeartbeat
        }
        $candidateSha256 = [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
        if ([int64]$source.Length -ne [int64]$receipt.size -or $candidateSha256 -cne [string]$receipt.sha256) {
            throw 'Interrupted source delivery file no longer matches its receipt.'
        }
        if (-not $deliveredExists) {
            if (-not (Test-Path -LiteralPath $DeliveryDirectory -PathType Container)) {
                $null = Assert-NoReparsePath -Path (Split-Path -Parent $DeliveryDirectory) -Root $RepositoryRoot -Label 'Interrupted delivery parent'
                New-Item -ItemType Directory -Path $DeliveryDirectory | Out-Null
            }
            $null = Assert-NoReparsePath -Path $DeliveryDirectory -Root $RepositoryRoot -Label 'Interrupted delivery directory'
            $null = Assert-NoReparsePath -Path $deliveredCandidate -Root $RepositoryRoot -Label 'Interrupted delivered source' -AllowMissing
            $temporaryDelivery = Join-Path $DeliveryDirectory ('.delivery-' + [guid]::NewGuid().ToString('N') + '.tmp')
            $null = Assert-NoReparsePath -Path $temporaryDelivery -Root $RepositoryRoot -Label 'Interrupted temporary delivery' -AllowMissing
            $destination = [IO.File]::Open($temporaryDelivery, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $source.Position = 0
                Copy-StreamWithHeartbeat -Source $source -Destination $destination
                $destination.Flush($true)
            }
            finally { $destination.Dispose() }
            [IO.File]::Move($temporaryDelivery, $deliveredCandidate)
            $temporaryDelivery = $null
        }
    }
    finally {
        $hasher.Dispose()
        $source.Dispose()
        if ($temporaryDelivery -and (Test-Path -LiteralPath $temporaryDelivery -PathType Leaf)) {
            [IO.File]::Delete($temporaryDelivery)
        }
    }
    if ($incomingExists) {
        $null = Assert-NoReparsePath -Path $incomingCandidate -Root $RepositoryRoot -Label 'Interrupted incoming source'
        [IO.File]::Delete($incomingCandidate)
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
        try {
            Write-BytesWithHeartbeat -Path $temporaryRequestPath -Bytes $suppliedRequestBytes
            $null = Get-Content -LiteralPath $temporaryRequestPath -Raw | ConvertFrom-Json -AsHashtable
            Update-ActiveReservationHeartbeat -Force
            [IO.File]::Move($temporaryRequestPath, $boundRequestPath)
        }
        finally {
            if (Test-Path -LiteralPath $temporaryRequestPath -PathType Leaf) { [IO.File]::Delete($temporaryRequestPath) }
        }
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
    param(
        [Collections.IDictionary] $State,
        [Collections.IDictionary] $Context
    )
    Assert-LockOwner -State $State
    $stage = if ($Context) {
        $script:activeStageContext = $Context
        $Context
    }
    else { Start-Stage -Name 'claim' }
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
    $claimStage = Start-Stage -Name 'claim'
    $actualRunId = if ($RunId) { [guid]::Parse($RunId).ToString() } else { [guid]::NewGuid().ToString() }
    $plan = Get-ModRunPlan -Repository $repository -CanonicalModDirectory $ModDirectory -ActualRunId $actualRunId
    $queueRoot = [string]$plan.queueRoot
    $slug = [string]$plan.slug
    $short = [string]$plan.short
    $runRoot = [string]$plan.runRoot
    $actualStatePath = if ($StatePath) {
        Assert-ContainedPath -Candidate $StatePath -Root $runRoot -Label 'State path'
    }
    else { Join-Path $runRoot 'state.json' }
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
        $baseOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', '--verify', "$BaseRef^{commit}")).output.Trim()
        $baseTreeOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', "$baseOid^{tree}")).output.Trim()
        Assert-Schema15BaseLocalizationEligibility -Repository $repository -BaseOid $baseOid -ModRelativePath ([string]$plan.modRelativePath)
        $plannedOwner = Enter-ModReservation -Plan $plan -ActualRunId $actualRunId -PlannedStatePath $actualStatePath
    }
    else {
        $sourceRequestInputFull = [IO.Path]::GetFullPath($SourceRequestPath)
        $null = Assert-NoReparsePath -Path $sourceRequestInputFull -Root ([IO.Path]::GetPathRoot($sourceRequestInputFull)) -Label 'Manual source request'
        if (-not (Test-Path -LiteralPath $sourceRequestInputFull -PathType Leaf)) { throw 'Manual source request is missing.' }
        $sourceRequestData = Get-Content -LiteralPath $sourceRequestInputFull -Raw | ConvertFrom-Json -AsHashtable
        $sourceIdentity = ConvertTo-NexusSourceIdentity -Request $sourceRequestData -RequireMetadata
        $baseOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', '--verify', "$BaseRef^{commit}")).output.Trim()
        $baseTreeOid = (Invoke-Git -WorkingDirectory $repository -Arguments @('rev-parse', "$baseOid^{tree}")).output.Trim()
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
        $plannedOwner = Enter-ModReservation -Plan $plan -ActualRunId $actualRunId -PlannedStatePath $actualStatePath
        $stabilityStartedMilliseconds = [int64](& $claimStage.monotonicClock)
        try {
            for ($second = 0; $second -lt 10; $second++) {
                [Threading.Thread]::Sleep(1000)
                Update-ActiveReservationHeartbeat
            }
        }
        finally {
            $stabilityMilliseconds = [int64](& $claimStage.monotonicClock) - $stabilityStartedMilliseconds
            $null = Add-StageWait -Context $claimStage -Reason 'stability-observation' -Milliseconds $stabilityMilliseconds
        }
        $null = Assert-NoReparsePath -Path $sourceFull -Root $repository -Label 'Source archive'
        $sampleTwo = Get-Item -LiteralPath $sourceFull
        if ($sampleOne.Length -ne $sampleTwo.Length -or $sampleOne.LastWriteTimeUtc -ne $sampleTwo.LastWriteTimeUtc) {
            throw 'Archive did not remain stable across the required ten-second observation.'
        }
    }
    if ($sampleOne.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source archive must be a regular file, not a reparse point.' }
    if (Test-Path -LiteralPath $actualStatePath -PathType Leaf) {
        $existing = Read-State -Path $actualStatePath
        if ($existing.runId -ne $actualRunId) { throw 'Existing state belongs to another run.' }
        Ensure-RunWriterLock -State $existing
        $completed = Get-CompletedStageResult -State $existing -Name 'claim'
        if ($completed) { return $completed }
        return Complete-IncompleteClaim -State $existing -Context $claimStage
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
    $translationQualitySourceEntry = Get-SkillSourceFileEntry -SkillSourcePin $skillSourcePin -RepositoryPath '.agents/skills/auto-update-darktide-mod/references/translation-quality.md'
    $skillSourceEntry = Get-SkillSourceFileEntry -SkillSourcePin $skillSourcePin -RepositoryPath '.agents/skills/auto-update-darktide-mod/SKILL.md'
    $schema15SourceEntry = if ($sourceReceipt) { Get-SkillSourceFileEntry -SkillSourcePin $skillSourcePin -RepositoryPath ([string]$integrity.schema15.path) } else { $null }
    $plannedOwner = Read-ActiveReservationOwner
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

    $resolvedMetadataPaths = if (@($MetadataPath).Count -eq 0) {
        @('README.md', ".hash/$slug.hash")
    }
    else {
        @($MetadataPath)
    }
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
        metadataPaths = @($resolvedMetadataPaths)
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
        translationQualityPath = $translationQualitySourceEntry.repositoryPath
        translationQualityBlobOid = $translationQualitySourceEntry.blobOid
        translationQualitySha256 = $translationQualitySourceEntry.sha256
        schema15Path = if ($sourceReceipt) { $integrity.schema15.path } else { $null }
        schema15BlobOid = if ($sourceReceipt) { $schema15SourceEntry.blobOid } else { $null }
        schema15Sha256 = if ($sourceReceipt) { $integrity.schema15.sha256 } else { $null }
        referenceSources = @(
            [ordered]@{ role = 'workflow'; path = $integrity.workflow.path; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $workflowSourceEntry.blobOid; size = $workflowSourceEntry.size; sha256 = $workflowSourceEntry.sha256; expandedSize = $integrity.workflow.sizeBytes; expandedSha256 = $integrity.workflow.sha256 },
            [ordered]@{ role = 'review-baseline'; path = $integrity.reviewBaseline.path; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $reviewSourceEntry.blobOid; size = $reviewSourceEntry.size; sha256 = $reviewSourceEntry.sha256; expandedSize = $integrity.reviewBaseline.sizeBytes; expandedSha256 = $integrity.reviewBaseline.sha256 },
            [ordered]@{ role = 'package-binding'; path = $bindingSourceEntry.repositoryPath; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $bindingSourceEntry.blobOid; size = $bindingSourceEntry.size; sha256 = $bindingSourceEntry.sha256 },
            [ordered]@{ role = 'translation-quality'; path = $translationQualitySourceEntry.repositoryPath; sourceCommit = $skillSourcePin.resolvedCommit; blobOid = $translationQualitySourceEntry.blobOid; size = $translationQualitySourceEntry.size; sha256 = $translationQualitySourceEntry.sha256 },
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
        lastRecovery = if ($plannedOwner.Contains('lastRecovery')) { $plannedOwner.lastRecovery } else { $null }
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
    Complete-IncompleteClaim -State $state -Context $claimStage
}

function Assert-NoArchiveFileAncestorCollisions {
    param(
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, bool]] $Seen
    )
    $filePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($pair in $Seen.GetEnumerator()) {
        if (-not $pair.Value) { $null = $filePaths.Add($pair.Key) }
    }
    foreach ($path in $Seen.Keys) {
        $separatorIndex = $path.IndexOf([char]'/')
        while ($separatorIndex -ge 0) {
            if ($separatorIndex -gt 0) {
                $ancestor = $path.Substring(0, $separatorIndex)
                if ($filePaths.Contains($ancestor)) {
                    throw "Archive file/ancestor archive path collision rejected: $ancestor"
                }
            }
            $separatorIndex = $path.IndexOf([char]'/', $separatorIndex + 1)
        }
    }
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
        $seen = [Collections.Generic.Dictionary[string, bool]]::new([StringComparer]::OrdinalIgnoreCase)
        $entries = [Collections.Generic.List[object]]::new()
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
            $isDirectory = $entryPath.EndsWith('/')
            $collisionKey = $entryPath.TrimEnd('/').Normalize([Text.NormalizationForm]::FormC)
            if ($seen.ContainsKey($collisionKey)) { throw "Duplicate or Unicode/case-colliding archive path rejected: $entryPath" }
            $seen.Add($collisionKey, $isDirectory)
            $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($unixType -eq 0xA000) { throw "Archive symlink rejected: $entryPath" }
            if ((($entry.ExternalAttributes -band 0xFFFF) -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Archive reparse point rejected: $entryPath"
            }
            if ($unixType -notin @(0, 0x4000, 0x8000) -or
                ($unixType -eq 0x4000 -and -not $isDirectory) -or
                ($unixType -eq 0x8000 -and $isDirectory)) {
                throw "Archive special entry type rejected: $entryPath"
            }
            $totalLength += $entry.Length
            if ($entry.Length -gt 1GB -or $totalLength -gt 4GB -or ($entry.CompressedLength -gt 0 -and ($entry.Length / $entry.CompressedLength) -gt 1000)) {
                throw "Archive expansion limit rejected: $entryPath"
            }
            if (-not $isDirectory) {
                try {
                    $probe = $entry.Open()
                    try { $null = $probe.ReadByte() } finally { $probe.Dispose() }
                }
                catch { throw "Encrypted or unreadable archive entry rejected: $entryPath. $($_.Exception.Message)" }
            }
            $entries.Add([ordered]@{
                path = $entryPath
                size = $entry.Length
                compressedSize = $entry.CompressedLength
                externalAttributes = $entry.ExternalAttributes
                directory = $isDirectory
            })
        }
        Assert-NoArchiveFileAncestorCollisions -Seen $seen
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
    Import-SecurityOverrides -State $State -Path $SecurityOverridePath
    $stagingRoot = Join-Path $State.runRoot 'staging'
    $temporaryRoot = Join-Path $stagingRoot ('.extract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    $zip = Get-ZipEntries -Path $State.archive.path -ExpectedSha256 $State.archive.sha256
    $payloadSecurity = $null
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
        $payloadSecurity = Assert-ArchivePayloadSecurity -State $State -ExtractedRoot $temporaryRoot -Entries $zip.entries
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
    $manifest = New-Manifest -Root $finalRoot -OutputPath $manifestPath -Kind 'extraction' -SecurityDispositions $payloadSecurity
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
    try {
        Write-BytesWithHeartbeat -Path $temporary -Bytes $Bytes
        Update-ActiveReservationHeartbeat -Force
        [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { [IO.File]::Delete($temporary) }
    }
}

function Write-MemoryByteRangeWithHeartbeat {
    param([IO.Stream] $Destination, [byte[]] $Bytes, [int64] $Offset, [int64] $Count)
    for ($written = [int64]0; $written -lt $Count; $written += 1MB) {
        $chunk = [int][Math]::Min([int64]1MB, $Count - $written)
        $Destination.Write($Bytes, [int]($Offset + $written), $chunk)
        Update-ActiveReservationHeartbeat
        Update-ActiveSharedCoordinationHeartbeat
    }
}

function Copy-ByteRangeWithHeartbeat {
    param(
        [byte[]] $Source,
        [int64] $SourceOffset,
        [byte[]] $Destination,
        [int64] $DestinationOffset,
        [int64] $Count
    )
    for ($copied = [int64]0; $copied -lt $Count; $copied += 1MB) {
        $chunk = [int64][Math]::Min([int64]1MB, $Count - $copied)
        [Array]::Copy($Source, $SourceOffset + $copied, $Destination, $DestinationOffset + $copied, $chunk)
        Update-ActiveReservationHeartbeat
        Update-ActiveSharedCoordinationHeartbeat
    }
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
        Copy-ByteRangeWithHeartbeat -Source $IndexedBytes -SourceOffset $start `
            -Destination $oldBytes -DestinationOffset 0 -Count $length
        if ((Get-Sha256Bytes -Bytes $oldBytes) -ne [string]$span.oldSha256) { throw 'Approved span oldSha256 does not match indexed bytes.' }
        $replacement = [Convert]::FromBase64String([string]$span.replacementBase64)
        $memory = [IO.MemoryStream]::new()
        try {
            if ($start -gt 0) { Write-MemoryByteRangeWithHeartbeat -Destination $memory -Bytes $result -Offset 0 -Count $start }
            if ($replacement.Length -gt 0) {
                Write-MemoryByteRangeWithHeartbeat -Destination $memory -Bytes $replacement -Offset 0 -Count $replacement.Length
            }
            $tailStart = $start + $length
            if ($tailStart -lt $result.LongLength) {
                Write-MemoryByteRangeWithHeartbeat -Destination $memory -Bytes $result -Offset $tailStart -Count ($result.LongLength - $tailStart)
            }
            $updated = $memory.ToArray()
        }
        finally { $memory.Dispose() }
        $result = $updated
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
        $artifactSha = if (Test-Path -LiteralPath $worksetPath -PathType Leaf) { Get-FileSha256 -Path $worksetPath } else { $null }
        return Suspend-Stage -State $State -Context $stage -Result 'waiting-input' -ArtifactSha256 $artifactSha `
            -OutputStage 'localization-workset' -Data $State.waitingReason
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
        $waitingData = [ordered]@{ worksetPath = $worksetPath; pendingUnitIds = @($pending.unitId); required = 'Review only AI_REQUIRED units, set reviewStatus=approved and suggestedZhTwExpression, then resume localization.' }
        return Suspend-Stage -State $State -Context $stage -Result 'waiting-input' `
            -ArtifactSha256 ([string]$State.localizationWorkset.sha256) -OutputStage 'localization-workset' -Data $waitingData
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
    $State.waitingReason = $null
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
        $installRoot = Assert-NoReparseTree -Path ([string]$State.installRoot) `
            -Root ([string]$State.worktreePath) -Label 'Installed MOD tree before Schema 14 localization plan detection'
        $registeredModFiles = @(
            Get-ChildItem -LiteralPath $installRoot -File -Filter '*.mod' | ForEach-Object {
                $descriptorPath = Assert-NoReparsePath -Path $_.FullName -Root ([string]$State.worktreePath) `
                    -Label 'Schema 14 MOD descriptor'
                $descriptorText = [Text.UTF8Encoding]::new($false, $true).GetString(
                    (Read-FileBytesWithHeartbeat -Path $descriptorPath)
                )
                if (Test-LuaTableFieldAssignment -Text $descriptorText -Key 'mod_localization') {
                    [IO.Path]::GetRelativePath($installRoot, $descriptorPath).Replace('\', '/')
                }
            } | Sort-Object -Unique
        )
        if ($registeredModFiles.Count -ne 0) {
            $State.status = 'waiting-input'
            $State.waitingReason = [ordered]@{
                code = 'localization_plan_required'
                message = 'The installed Schema 14 MOD registers mod_localization. Review its active localization and resume with an explicit localization plan.'
                registeredModFiles = $registeredModFiles
            }
            return (Suspend-Stage -State $State -Context $stage -Result 'waiting-input' `
                -ArtifactSha256 ([string]$State.rawInstallManifest.sha256) -OutputStage 'localization-plan' `
                -Data ([ordered]@{
                    code = $State.waitingReason.code
                    required = $State.waitingReason.message
                    registeredModFiles = $registeredModFiles
                }))
        }
        [ordered]@{ schemaVersion = 1; mode = 'none'; files = @(); metadataPaths = @($State.metadataPaths) }
    }
    else {
        Get-Content -LiteralPath $LocalizationPlanPath -Raw | ConvertFrom-Json -AsHashtable
    }
    if ($plan.mode -notin @('none', 'zh-tw')) { throw 'Localization plan mode must be none or zh-tw.' }
    if ($plan.mode -eq 'none' -and @($plan.files).Count -ne 0) { throw 'Localization mode none cannot contain files.' }
    $removedPaths = @()
    if ($plan.Contains('removedPaths')) { $removedPaths = @($plan.removedPaths) }
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
    $records = [Collections.Generic.List[object]]::new()
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
        try {
            $null = Get-LuaLocalizationDocument -Bytes $mergedBytes -DisplayPath $relative -SourceId $relative -HeartbeatAction { Update-ActiveReservationHeartbeat }
        }
        catch {
            throw "Merged Schema 14 localization structure is invalid: $($_.Exception.Message)"
        }
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
        $records.Add([ordered]@{
            relativePath = $relative
            safeId = $safeId
            rawSha256 = Get-Sha256Bytes -Bytes $rawBytes
            indexedSha256 = $indexedSha
            mergedSha256 = Get-Sha256Bytes -Bytes $mergedBytes
            approvedSpans = @($file.approvedSpans)
            artifactDirectory = $artifactDirectory
            decisionsSha256 = Get-FileSha256 -Path $decisionsPath
        })
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
    $State.waitingReason = $null
    $State.status = 'localized'
    Complete-Stage -State $State -Context $stage -ArtifactSha256 (Get-FileSha256 -Path $manifestPath) -Data ([ordered]@{ mode = $plan.mode; fileCount = $records.Count })
}

function New-GitEvidenceBatch {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][object[]] $TaskSpecifications,
        [ValidateRange(1, 16)][int] $MaxConcurrency = 4
    )
    $pending = [Collections.Generic.Queue[object]]::new()
    foreach ($specification in @($TaskSpecifications)) { $pending.Enqueue($specification) }
    $active = [Collections.Generic.List[object]]::new()
    $completed = [Collections.Generic.List[object]]::new()
    $batchStartedAt = Get-UtcTimestamp
    try {
        while ($pending.Count -gt 0 -or $active.Count -gt 0) {
            while ($pending.Count -gt 0 -and $active.Count -lt $MaxConcurrency) {
                $specification = $pending.Dequeue()
                $start = [Diagnostics.ProcessStartInfo]::new()
                $start.FileName = 'git'
                $start.UseShellExecute = $false
                $start.RedirectStandardOutput = $true
                $start.RedirectStandardError = $true
                foreach ($argument in @('-C', [string]$State.worktreePath) + @($specification.arguments)) { $start.ArgumentList.Add([string]$argument) }
                $process = [Diagnostics.Process]::new()
                $process.StartInfo = $start
                $memory = [IO.MemoryStream]::new()
                try {
                    $startedAt = Get-UtcTimestamp
                    if (-not $process.Start()) { throw "Unable to start Git evidence task $($specification.name)." }
                    $active.Add([ordered]@{
                        specification = $specification
                        process = $process
                        memory = $memory
                        copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
                        errorTask = $process.StandardError.ReadToEndAsync()
                        startedAt = $startedAt
                    })
                }
                catch {
                    $memory.Dispose()
                    $process.Dispose()
                    throw
                }
            }
            $madeProgress = $false
            for ($index = $active.Count - 1; $index -ge 0; $index--) {
                $item = $active[$index]
                if (-not ($item.process.HasExited -and $item.copyTask.IsCompleted -and $item.errorTask.IsCompleted)) { continue }
                $madeProgress = $true
                $null = $item.copyTask.GetAwaiter().GetResult()
                $errorText = $item.errorTask.GetAwaiter().GetResult()
                if ($item.process.ExitCode -ne 0) {
                    throw "Git evidence task $($item.specification.name) failed ($($item.process.ExitCode)): $errorText"
                }
                $completed.Add([ordered]@{
                    specification = $item.specification
                    bytes = $item.memory.ToArray()
                    startedAt = $item.startedAt
                    completedAt = Get-UtcTimestamp
                })
                $item.memory.Dispose()
                $item.process.Dispose()
                $active.RemoveAt($index)
            }
            Update-ActiveReservationHeartbeat
            Update-ActiveSharedCoordinationHeartbeat
            if (-not $madeProgress -and $active.Count -gt 0) { [Threading.Tasks.Task]::Delay(20).Wait() }
        }
    }
    finally {
        foreach ($item in @($active)) {
            try { if (-not $item.process.HasExited) { $item.process.Kill($true) } } catch { }
            try { $item.memory.Dispose() } catch { }
            try { $item.process.Dispose() } catch { }
        }
    }
    if ($completed.Count -ne @($TaskSpecifications).Count) { throw 'Bounded Git evidence batch did not complete every task.' }
    $artifacts = [ordered]@{}
    $tasks = @()
    foreach ($specification in @($TaskSpecifications)) {
        $taskResults = @($completed | Where-Object { [string]$_.specification.name -ceq [string]$specification.name })
        if ($taskResults.Count -ne 1) { throw "Bounded Git evidence batch produced an ambiguous task result: $($specification.name)" }
        $result = $taskResults[0]
        $path = Join-Path (Join-Path ([string]$State.artifactsRoot) 'git-evidence') ([string]$specification.artifactName)
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Write-AtomicBytes -Path $path -Bytes ([byte[]]$result.bytes)
        $artifact = [ordered]@{ path = $path; size = ([byte[]]$result.bytes).LongLength; sha256 = Get-FileSha256 -Path $path }
        $artifacts[[string]$specification.name] = $artifact
        $tasks += [ordered]@{
            name = [string]$specification.name
            baseOid = [string]$specification.baseOid
            headOid = [string]$specification.headOid
            treeOid = [string]$specification.treeOid
            artifact = $artifact
            startedAt = [string]$result.startedAt
            completedAt = [string]$result.completedAt
        }
    }
    [ordered]@{
        executionMode = 'bounded-parallel'
        maxConcurrency = $MaxConcurrency
        startedAt = $batchStartedAt
        completedAt = Get-UtcTimestamp
        artifacts = $artifacts
        tasks = $tasks
    }
}

function Assert-EvidenceChangedPathAllowlists {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    $targets = @($State.evidenceTargetPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $metadata = @($State.metadataPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $chain = $State.evidenceChain
    $ranges = @(
        [ordered]@{ name = 'c1-parent'; baseOid = $chain.c1ParentOid; headOid = $chain.c1Oid; allowlist = 'mod-non-target' },
        [ordered]@{ name = 'c0-c1'; baseOid = $chain.c0Oid; headOid = $chain.c1Oid; allowlist = 'mod-non-target' }
    )
    if ([string]$State.localizationMode -ceq 'zh-tw') {
        $ranges += @(
            [ordered]@{ name = 'c2-parent'; baseOid = $chain.c2ParentOid; headOid = $chain.c2Oid; allowlist = 'target-only' },
            [ordered]@{ name = 'c1-c2'; baseOid = $chain.c1Oid; headOid = $chain.c2Oid; allowlist = 'target-only' },
            [ordered]@{ name = 'c3-parent'; baseOid = $chain.c3ParentOid; headOid = $chain.c3Oid; allowlist = 'target-only' },
            [ordered]@{ name = 'c2-c3'; baseOid = $chain.c2Oid; headOid = $chain.c3Oid; allowlist = 'target-only' }
        )
        if ([string]$chain.fOid -cne [string]$chain.c3Oid) {
            $ranges += [ordered]@{ name = 'c3-f'; baseOid = $chain.c3Oid; headOid = $chain.fOid; allowlist = 'metadata-only' }
        }
    }
    $ranges += [ordered]@{ name = 'c0-f'; baseOid = $chain.c0Oid; headOid = $chain.fOid; allowlist = 'mod-or-metadata' }
    $records = @()
    foreach ($range in $ranges) {
        $paths = @(
            (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('-c', 'core.quotePath=false', 'diff', '--name-only', '--no-renames', "$($range.baseOid)..$($range.headOid)")).output -split "`r?`n" |
                Where-Object { $_ } |
                Sort-Object -Unique
        )
        foreach ($path in $paths) {
            $inMod = $path.StartsWith(([string]$State.modRelativePath + '/'), [StringComparison]::Ordinal)
            $allowed = switch ([string]$range.allowlist) {
                'mod-non-target' { $inMod -and $path -cnotin $targets }
                'target-only' { $path -cin $targets }
                'metadata-only' { $path -cin $metadata }
                'mod-or-metadata' { $inMod -or $path -cin $metadata }
                default { $false }
            }
            if (-not $allowed) { throw "Coordinator changed-path allowlist rejected $($range.name): $path" }
        }
        $pathsSha256 = Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject @($paths) -Compress)))
        $records += [ordered]@{
            name = [string]$range.name; baseOid = [string]$range.baseOid; headOid = [string]$range.headOid
            allowlist = [string]$range.allowlist; paths = $paths; pathCount = $paths.Count; pathsSha256 = $pathsSha256
        }
    }
    $contract = [ordered]@{
        generation = [int]$State.evidenceGeneration
        targetPathsSha256 = [string]$State.evidenceTargetPathsSha256
        metadataPaths = $metadata
        records = $records
    }
    [ordered]@{
        result = 'passed'
        records = $records
        contractSha256 = Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $contract -Depth 20 -Compress)))
        verifiedAt = Get-UtcTimestamp
    }
}

function Assert-BuildMetadataPaths {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [switch] $AllowMissing
    )
    $worktree = [IO.Path]::GetFullPath([string]$State.worktreePath)
    $required = @('README.md', ".hash/$($State.modSlug).hash")
    $actual = @($State.metadataPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $matchesRequiredContract = $actual.Count -eq $required.Count
    foreach ($requiredPath in $required) {
        $pathMatches = @($actual | Where-Object { $_.Equals($requiredPath, [StringComparison]::OrdinalIgnoreCase) })
        if ($pathMatches.Count -ne 1) { $matchesRequiredContract = $false }
    }
    if (-not $matchesRequiredContract) {
        throw "Metadata preflight requires README.md and .hash/$($State.modSlug).hash before C1."
    }
    $records = @()
    foreach ($metadataRelative in $actual) {
        $metadataFull = Assert-ContainedPath -Candidate (Join-Path $worktree $metadataRelative) -Root $worktree -Label 'Metadata path'
        $null = Assert-NoReparsePath -Path $metadataFull -Root $worktree -Label 'Metadata path' -AllowMissing
        $exists = Test-Path -LiteralPath $metadataFull -PathType Leaf
        if (-not $exists -and -not $AllowMissing) { throw "Metadata path is missing: $metadataRelative" }
        $records += [ordered]@{ relativePath = $metadataRelative; fullPath = $metadataFull; exists = $exists }
    }
    if (@($records | Where-Object { -not $_.exists }).Count -gt 0) {
        return @($records)
    }

    $records = @()
    $trackedMetadata = Invoke-Git -WorkingDirectory $worktree -Arguments @('ls-files', '--full-name', '--', 'README.md', '.hash')
    $trackedMetadataPaths = @($trackedMetadata.output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($metadataRelative in $actual) {
        $trackedPaths = @($trackedMetadataPaths | Where-Object {
            $_.Equals($metadataRelative, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($trackedPaths.Count -gt 1 -or
            ($trackedPaths.Count -eq 1 -and -not $trackedPaths[0].Equals($metadataRelative, [StringComparison]::OrdinalIgnoreCase))) {
            throw "Metadata path has ambiguous tracked casing: $metadataRelative"
        }
        $canonicalRelative = if ($trackedPaths.Count -eq 1) { [string]$trackedPaths[0] } else { $metadataRelative }
        $metadataFull = Assert-ContainedPath -Candidate (Join-Path $worktree $canonicalRelative) -Root $worktree -Label 'Metadata path'
        $null = Assert-NoReparsePath -Path $metadataFull -Root $worktree -Label 'Metadata path' -AllowMissing
        $exists = Test-Path -LiteralPath $metadataFull -PathType Leaf
        if (-not $exists -and -not $AllowMissing) { throw "Metadata path is missing: $canonicalRelative" }
        $records += [ordered]@{ relativePath = $canonicalRelative; fullPath = $metadataFull; exists = $exists }
    }
    $State.metadataPaths = @($records | ForEach-Object { [string]$_.relativePath })
    @($records)
}

function New-BuildMetadataPreview {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    $metadataPaths = @(Assert-BuildMetadataPaths -State $State)
    if (-not $State.Contains('sourceTuple') -or -not $State.sourceTuple) { throw 'Build commits requires the immutable Nexus Main file source tuple.' }
    $sourceTuplePath = [string]$State.sourceTuple.path
    $null = Assert-NoReparsePath -Path $sourceTuplePath -Root ([string]$State.repositoryRoot) -Label 'Source tuple'
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
    foreach ($metadataPath in $metadataPaths) {
        $metadataBytes = Read-FileBytesWithHeartbeat -Path ([string]$metadataPath.fullPath)
        $metadataText = [Text.UTF8Encoding]::new($false, $true).GetString($metadataBytes)
        $metadataBlobOid = (Invoke-Git -WorkingDirectory ([string]$State.worktreePath) -Arguments @(
            '-c', 'core.autocrlf=true', 'hash-object', '-w', "--path=$([string]$metadataPath.relativePath)", '--', [string]$metadataPath.fullPath
        )).output.Trim()
        $metadataIndexedBytes = Get-GitBlobBytes -WorkingDirectory ([string]$State.worktreePath) -Object $metadataBlobOid
        $metadataRawSha256 = Get-Sha256Bytes -Bytes $metadataBytes
        $metadataIndexedSha256 = Get-Sha256Bytes -Bytes $metadataIndexedBytes
        $metadataTransform = if ($metadataRawSha256 -ceq $metadataIndexedSha256) { 'none' }
            elseif (Test-CrlfNormalizationOnly -RawBytes $metadataBytes -IndexedBytes $metadataIndexedBytes) { 'crlf-to-lf' }
            else { throw "Metadata Git clean processing changed bytes beyond CRLF-to-LF for $($metadataPath.relativePath)." }
        $fieldMatches = [ordered]@{}
        foreach ($fieldName in $sourceFields.Keys) {
            $fieldValue = [string]$sourceFields[$fieldName]
            $fieldMatches[$fieldName] = Test-MetadataSourceFieldMatch -RelativePath ([string]$metadataPath.relativePath) `
                -Text $metadataText -FieldName $fieldName -FieldValue $fieldValue `
                -NexusPageUrl ([string]$sourceFields.nexusPageUrl)
        }
        $mismatchedFields = @($fieldMatches.Keys | Where-Object { -not [bool]$fieldMatches[$_] })
        if ($mismatchedFields.Count -ne 0) {
            throw "Metadata preflight field mismatch: $($metadataPath.relativePath) $($mismatchedFields -join ', ')."
        }
        $metadataRecords += [ordered]@{
            path = [string]$metadataPath.relativePath
            sha256 = $metadataRawSha256
            size = $metadataBytes.Length
            indexedSha256 = $metadataIndexedSha256
            indexedSize = $metadataIndexedBytes.Length
            blobOid = $metadataBlobOid
            transform = $metadataTransform
            sourceFieldMatches = $fieldMatches
        }
    }
    $metadataPreviewPath = Join-Path ([string]$State.artifactsRoot) 'metadata-preview.json'
    $previewInput = [ordered]@{
        schemaVersion = 2
        runId = $State.runId
        sourceTuplePath = $sourceTuplePath
        sourceTupleSha256 = $State.sourceTuple.sha256
        sourceTupleContractSha256 = $State.sourceTuple.contractSha256
        sourceFields = $sourceFields
        files = $metadataRecords
    }
    $previewInputSha256 = Get-SourceTupleContractSha256 -Contract $previewInput
    if ($State.Contains('metadataPreview') -and $State.metadataPreview) {
        if (-not $State.metadataPreview.Contains('path') -or
            [IO.Path]::GetFullPath([string]$State.metadataPreview.path) -cne [IO.Path]::GetFullPath($metadataPreviewPath)) {
            throw 'Recorded metadata preview path changed after build-commits preflight.'
        }
        $previousPreviewPath = Assert-NoReparsePath -Path ([string]$State.metadataPreview.path) `
            -Root ([string]$State.repositoryRoot) -Label 'Metadata preview'
        if (-not (Test-Path -LiteralPath $previousPreviewPath -PathType Leaf) -or
            (Get-FileSha256 -Path $previousPreviewPath) -cne [string]$State.metadataPreview.sha256) {
            throw 'Recorded metadata preview bytes changed after build-commits preflight.'
        }
        $previousPreview = Get-Content -LiteralPath $previousPreviewPath -Raw | ConvertFrom-Json -AsHashtable
        $previousInput = [ordered]@{
            schemaVersion = $previousPreview.schemaVersion
            runId = $previousPreview.runId
            sourceTuplePath = $previousPreview.sourceTuplePath
            sourceTupleSha256 = $previousPreview.sourceTupleSha256
            sourceTupleContractSha256 = $previousPreview.sourceTupleContractSha256
            sourceFields = $previousPreview.sourceFields
            files = $previousPreview.files
        }
        if ((Get-SourceTupleContractSha256 -Contract $previousInput) -cne $previewInputSha256) {
            throw 'Metadata preview inputs changed after build-commits preflight.'
        }
        return $State.metadataPreview
    }
    $preview = [ordered]@{}
    foreach ($field in $previewInput.Keys) { $preview[$field] = $previewInput[$field] }
    $preview.inputContractSha256 = $previewInputSha256
    $preview.generatedAt = Get-UtcTimestamp
    Write-AtomicJson -Path $metadataPreviewPath -Value $preview
    $State.metadataPreview = [ordered]@{
        path = $metadataPreviewPath
        sha256 = Get-FileSha256 -Path $metadataPreviewPath
        fileCount = $metadataRecords.Count
        sourceTupleContractSha256 = $State.sourceTuple.contractSha256
        inputContractSha256 = $previewInputSha256
    }
    Save-State -State $State
    $State.metadataPreview
}

function Get-BuildCommitsResumeCheckpoint {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][string] $HeadOid,
        [Parameter(Mandatory)][string] $HeadTreeOid
    )
    $chain = $State.evidenceChain
    $recorded = @(
        [ordered]@{ name = 'c0'; oid = [string]$chain.c0Oid; tree = [string]$chain.c0TreeOid },
        [ordered]@{ name = 'c1'; oid = [string]$chain.c1Oid; tree = [string]$chain.c1TreeOid },
        [ordered]@{ name = 'c2'; oid = [string]$chain.c2Oid; tree = [string]$chain.c2TreeOid },
        [ordered]@{ name = 'c3'; oid = [string]$chain.c3Oid; tree = [string]$chain.c3TreeOid },
        [ordered]@{ name = 'f'; oid = [string]$chain.fOid; tree = [string]$chain.fTreeOid }
    )
    $latest = $null
    foreach ($checkpoint in $recorded) {
        if ([string]::IsNullOrWhiteSpace([string]$checkpoint.oid)) { continue }
        if ([string]::IsNullOrWhiteSpace([string]$checkpoint.tree)) {
            throw "Recorded build-commits partial checkpoint tree is missing for $($checkpoint.name)."
        }
        $latest = $checkpoint
    }
    if (-not $latest -or [string]$latest.oid -cne $HeadOid) {
        throw 'Incomplete build-commits recovery requires HEAD to equal the latest recorded same-run checkpoint.'
    }
    if ([string]$latest.tree -cne $HeadTreeOid) {
        throw "Recorded build-commits partial checkpoint tree no longer matches HEAD at $($latest.name)."
    }
    [string]$latest.name
}

function Assert-BuildCommitsRecordedCheckpoints {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    $worktree = [string]$State.worktreePath
    foreach ($name in @('c0', 'c1', 'c2', 'c3', 'f')) {
        $oid = [string]$State.evidenceChain["${name}Oid"]
        $tree = [string]$State.evidenceChain["${name}TreeOid"]
        if ([string]::IsNullOrWhiteSpace($oid)) { continue }
        if ([string]::IsNullOrWhiteSpace($tree)) { throw "Recorded build-commits checkpoint $name is missing its tree." }
        $actualTree = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', "$oid^{tree}")).output.Trim()
        if ($actualTree -cne $tree) { throw "Recorded build-commits checkpoint $name tree changed." }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$State.evidenceChain.c1Oid) -and
        [string]$State.evidenceChain.c1ParentTreeOid -cne [string]$State.evidenceChain.c0TreeOid) {
        throw 'Recorded C1 partial checkpoint no longer starts from the C0 tree.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$State.evidenceChain.c2Oid) -and
        [string]$State.evidenceChain.c2ParentTreeOid -cne [string]$State.evidenceChain.c1TreeOid) {
        throw 'Recorded C2 partial checkpoint no longer starts from the C1 tree.'
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$State.evidenceChain.c3Oid) -and
        [string]$State.evidenceChain.c3ParentTreeOid -cne [string]$State.evidenceChain.c2TreeOid) {
        throw 'Recorded C3 partial checkpoint no longer starts from the C2 tree.'
    }
    foreach ($name in @('c1', 'c2', 'c3')) {
        $oid = [string]$State.evidenceChain["${name}Oid"]
        if ([string]::IsNullOrWhiteSpace($oid)) { continue }
        $parentOid = [string]$State.evidenceChain["${name}ParentOid"]
        $parentTreeOid = [string]$State.evidenceChain["${name}ParentTreeOid"]
        $actualParentOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', "$oid^" )).output.Trim()
        $actualParentTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', "$oid^^{tree}" )).output.Trim()
        if ($actualParentOid -cne $parentOid -or $actualParentTreeOid -cne $parentTreeOid) {
            throw "Recorded $($name.ToUpperInvariant()) partial checkpoint parent tuple changed."
        }
    }
}

function Assert-StagedCheckpointBoundary {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][ValidateSet('C1', 'C2', 'C3', 'F')][string] $Checkpoint,
        [string[]] $AllowedPaths = @(),
        [string] $AllowedRoot,
        [string[]] $ExcludedPaths = @()
    )
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($AllowedPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) { $null = $allowed.Add($path.Replace('\', '/')) }
    }
    $excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($ExcludedPaths)) {
        if (-not [string]::IsNullOrWhiteSpace($path)) { $null = $excluded.Add($path.Replace('\', '/')) }
    }
    $root = if ([string]::IsNullOrWhiteSpace($AllowedRoot)) { $null } else { $AllowedRoot.Replace('\', '/').TrimEnd('/') }
    $stagedResult = Invoke-Git -WorkingDirectory $WorkingDirectory -Arguments @('diff', '--cached', '--name-only', '-z', '--no-renames')
    $stagedPaths = @($stagedResult.output -split ([string][char]0) | Where-Object { -not [string]::IsNullOrEmpty($_) })
    foreach ($path in $stagedPaths) {
        $normalized = $path.Replace('\', '/')
        $withinRoot = $root -and ($normalized -ceq $root -or $normalized.StartsWith("$root/", [StringComparison]::Ordinal))
        if ($excluded.Contains($normalized) -or (-not $allowed.Contains($normalized) -and -not $withinRoot)) {
            throw "$Checkpoint staged path is outside its allowlist: $normalized"
        }
    }
    $diffCheck = Invoke-Git -WorkingDirectory $WorkingDirectory -Arguments @('diff', '--cached', '--check') -AllowFailure
    if ($diffCheck.exitCode -ne 0) {
        $upstreamWhitespacePaths = @(
            $diffCheck.output -split "`r?`n" | ForEach-Object {
                if ($_ -match '^(.+):(\d+):\s') { $Matches[1].Replace('\', '/') }
            } | Where-Object { $_ } | Sort-Object -Unique
        )
        $isExactUpstreamException = $diffCheck.exitCode -eq 2 -and $Checkpoint -in @('C1', 'C2') -and
            $upstreamWhitespacePaths.Count -gt 0 -and
            @($upstreamWhitespacePaths | Where-Object { $_ -cnotin $stagedPaths }).Count -eq 0
        if (-not $isExactUpstreamException) {
            throw "$Checkpoint staged diff failed git diff --cached --check: $($diffCheck.warning) $($diffCheck.output)".Trim()
        }
    }
    [ordered]@{
        checkpoint = $Checkpoint
        stagedPaths = $stagedPaths
        diffCheck = if ($diffCheck.exitCode -eq 0) { 'passed' } else { 'upstream-whitespace' }
        upstreamWhitespacePaths = if ($diffCheck.exitCode -eq 0) { @() } else { $upstreamWhitespacePaths }
    }
}

function Assert-FileTreeMatchesManifest {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][Collections.IDictionary] $ManifestReceipt,
        [Parameter(Mandatory)][string] $Label
    )
    $rootFull = [IO.Path]::GetFullPath($Root)
    $manifestPath = Assert-NoReparsePath -Path ([string]$ManifestReceipt.path) `
        -Root $Repository -Label "$Label manifest"
    if ((Get-FileSha256 -Path $manifestPath) -cne [string]$ManifestReceipt.sha256) {
        throw "$Label immutable manifest SHA-256 changed."
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ([IO.Path]::GetFullPath([string]$manifest.root) -cne $rootFull) { throw "$Label manifest root changed." }
    $expected = @($manifest.files | Sort-Object { [string]$_.path })
    $actual = @(
        Get-ChildItem -LiteralPath $rootFull -File -Recurse | ForEach-Object {
            Update-ActiveReservationHeartbeat
            [ordered]@{
                path = [IO.Path]::GetRelativePath($rootFull, $_.FullName).Replace('\', '/')
                size = [int64]$_.Length
                sha256 = Get-FileSha256 -Path $_.FullName
            }
        } | Sort-Object { [string]$_.path }
    )
    if ($actual.Count -ne $expected.Count) { throw "$Label file count differs from its immutable manifest." }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        if ([string]$actual[$index].path -cne [string]$expected[$index].path -or
            [int64]$actual[$index].size -ne [int64]$expected[$index].size -or
            [string]$actual[$index].sha256 -cne [string]$expected[$index].sha256) {
            throw "$Label differs from its immutable manifest at $($actual[$index].path)."
        }
    }
    [ordered]@{ root = $rootFull; fileCount = $actual.Count; manifestSha256 = [string]$ManifestReceipt.sha256 }
}

function Assert-CheckpointIndexState {
    param(
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][ValidateSet('C1', 'C2', 'C3', 'F')][string] $Checkpoint,
        [object[]] $ExpectedRecords = @(),
        [string[]] $AbsentPaths = @()
    )
    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($ExpectedRecords)) {
        $path = ([string]$record.path).Replace('\', '/')
        $sha256 = [string]$record.sha256
        if ([string]::IsNullOrWhiteSpace($path) -or $sha256 -notmatch '^[0-9a-f]{64}$') {
            throw "$Checkpoint expected index record is incomplete."
        }
        if ($expected.ContainsKey($path)) { throw "$Checkpoint expected index path is duplicated: $path" }
        $expected.Add($path, $sha256)
    }
    foreach ($path in $expected.Keys) {
        $blobBytes = Get-GitBlobBytes -WorkingDirectory $WorkingDirectory -Object ":$path"
        if ((Get-Sha256Bytes -Bytes $blobBytes) -cne $expected[$path]) {
            throw "$Checkpoint index blob differs from its immutable expected SHA-256: $path"
        }
    }
    $absent = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($pathValue in @($AbsentPaths)) {
        if ([string]::IsNullOrWhiteSpace($pathValue)) { continue }
        $path = $pathValue.Replace('\', '/')
        if ($expected.ContainsKey($path)) { throw "$Checkpoint path cannot be both expected and absent: $path" }
        if (-not $absent.Add($path)) { continue }
        $indexed = Invoke-Git -WorkingDirectory $WorkingDirectory -Arguments @('ls-files', '--stage', '--', $path)
        if (-not [string]::IsNullOrWhiteSpace($indexed.output)) {
            throw "$Checkpoint expected the index path to be absent: $path"
        }
    }
    [ordered]@{ checkpoint = $Checkpoint; expectedCount = $expected.Count; absentCount = $absent.Count }
}

function Get-BuildCommitsPartialCheckpoint {
    param([Parameter(Mandatory)][Collections.IDictionary] $State)
    foreach ($name in @('f', 'c3', 'c2', 'c1', 'c0')) {
        if (-not [string]::IsNullOrWhiteSpace([string]$State.evidenceChain["${name}Oid"])) { return $name }
    }
    $null
}

function Save-BuildCommitsFailure {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $Context,
        [Parameter(Mandatory)][string] $ErrorMessage
    )
    $worktree = [string]$State.worktreePath
    $head = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $tree = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
    $checkpoint = Get-BuildCommitsPartialCheckpoint -State $State
    $disposition = if ($checkpoint -and $checkpoint -cne 'c0') { 'same-run-checkpoint-resume' } else { 'restart-before-c1' }
    $State.buildCommitsRecovery = [ordered]@{
        status = 'partial-failure'
        failedAt = Get-UtcTimestamp
        partialCheckpoint = $checkpoint
        partialHeadOid = $head
        partialHeadTreeOid = $tree
        evidenceGeneration = $State.evidenceGeneration
        evidenceChain = $State.evidenceChain
        recoveryDisposition = $disposition
        error = $ErrorMessage
    }
    $null = Fail-Stage -State $State -Context $Context -ErrorMessage $ErrorMessage `
        -PartialCheckpoint $checkpoint -RecoveryDisposition $disposition
}

function Invoke-BuildCommits {
    param([Collections.IDictionary] $State)
    $completed = Get-CompletedStageResult -State $State -Name 'build-commits'
    if ($completed) { return $completed }
    $stage = Start-Stage -Name 'build-commits'
    try {
        Assert-LockOwner -State $State
        $worktree = Assert-NoReparsePath -Path ([string]$State.worktreePath) `
            -Root ([IO.Path]::GetPathRoot([string]$State.worktreePath)) -Label 'Evidence worktree'
        $null = Assert-NoReparseTree -Path ([string]$State.installRoot) -Root $worktree -Label 'Installed MOD tree before evidence commits'

        $remoteTrackingRef = "refs/remotes/$($State.remote)/$($State.branch)"
        $remoteTracking = Invoke-Git -WorkingDirectory $worktree -Arguments @('show-ref', '--verify', '--quiet', $remoteTrackingRef) -AllowFailure
        if (-not $State.published -and $remoteTracking.exitCode -eq 0) {
            $remoteTrackingOid = Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', '--verify', "$remoteTrackingRef^{commit}")
            $State.published = $true
            $State.headOid = $remoteTrackingOid.output.Trim()
            Save-State -State $State
            throw 'The run state said unpublished, but its remote-tracking branch already exists. State was repaired to published; prepare an append-only same-run refresh before rebuilding checkpoints.'
        }
        if ($remoteTracking.exitCode -notin @(0, 1)) { throw 'Unable to inspect the run remote-tracking branch before build-commits.' }

        if ($State.published) {
            throw 'A published evidence branch is append-only; completed checkpoints are never reset or rebuilt in place. Use the Workflow append-only same-run refresh procedure.'
        }

        $metadataPreparation = @(Assert-BuildMetadataPaths -State $State -AllowMissing)
        $missingMetadataPaths = @($metadataPreparation | Where-Object { -not $_.exists } | ForEach-Object { [string]$_.relativePath })
        if ($missingMetadataPaths.Count -gt 0) {
            $State.status = 'waiting-input'
            $State.waitingReason = [ordered]@{
                code = 'metadata_preparation_required'
                message = 'Prepare the missing README/formal-hash metadata from the immutable source tuple, then resume build-commits.'
                missingPaths = $missingMetadataPaths
            }
            return Suspend-Stage -State $State -Context $stage -Result 'waiting-input' `
                -ArtifactSha256 ([string]$State.sourceTuple.sha256) -OutputStage 'metadata-preparation' `
                -Data ([ordered]@{
                    required = $State.waitingReason.message
                    missingPaths = $missingMetadataPaths
                    sourceTuplePath = [string]$State.sourceTuple.path
                    sourceTupleSha256 = [string]$State.sourceTuple.sha256
                })
        }

        $State.waitingReason = $null
        $validator = Join-Path $PSScriptRoot 'Test-ModUpdateCandidate.ps1'
        $securityValidation = & $validator -StatePath $State.statePath -SecurityPayloadOnly `
            -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
        if ($securityValidation.result -ne 'passed') { throw 'Independent pre-commit payload security validation rejected the run.' }
        $State.securityPrecommitValidation = [ordered]@{
            path = $securityValidation.path; sha256 = $securityValidation.sha256; result = $securityValidation.result
            archiveSha256 = $State.archive.sha256; extractionManifestSha256 = $State.extractionManifest.sha256
            securityOverrideReceiptSha256 = if ($State.Contains('securityOverrideReceipt') -and $State.securityOverrideReceipt) { $State.securityOverrideReceipt.sha256 } else { $null }
        }
        Save-State -State $State

        # Metadata is prepared by the Agent but is not staged until after C3. Validate all inputs before C1.
        $null = New-BuildMetadataPreview -State $State
        $startingHead = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $startingTree = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
        $resumeCheckpoint = Get-BuildCommitsResumeCheckpoint -State $State -HeadOid $startingHead -HeadTreeOid $startingTree
        Assert-BuildCommitsRecordedCheckpoints -State $State
        $checkpointRanks = @{ c0 = 0; c1 = 1; c2 = 2; c3 = 3; f = 4 }
        $resumeRank = [int]$checkpointRanks[$resumeCheckpoint]
        if ($resumeRank -lt 3) {
            $null = Assert-FileTreeMatchesManifest -Root ([string]$State.installRoot) `
                -Repository ([string]$State.repositoryRoot) -ManifestReceipt $State.rawInstallManifest `
                -Label 'Pre-C1 raw install tree'
            $normalizationPath = Assert-NoReparsePath -Path ([string]$State.gitIndexNormalization.path) `
                -Root ([string]$State.repositoryRoot) -Label 'Git index normalization manifest'
            if ((Get-FileSha256 -Path $normalizationPath) -cne [string]$State.gitIndexNormalization.sha256) {
                throw 'Git index normalization manifest SHA-256 changed before checkpoint commits.'
            }
            $normalization = Get-Content -LiteralPath $normalizationPath -Raw | ConvertFrom-Json -AsHashtable
        }
        if ($resumeRank -gt 0) {
            if (-not $State.Contains('buildCommitsRecovery') -or -not $State.buildCommitsRecovery -or
                [string]$State.buildCommitsRecovery.partialHeadOid -cne $startingHead -or
                [string]$State.buildCommitsRecovery.partialHeadTreeOid -cne $startingTree) {
                throw 'Recorded partial HEAD is not bound to the saved build-commits recovery evidence.'
            }
            $State.buildCommitsRecovery.status = 'resuming'
            $State.buildCommitsRecovery.resumedAt = Get-UtcTimestamp
            $State.buildCommitsRecovery.recoveryDisposition = 'same-run-checkpoint-resume'
            Save-State -State $State
        }

        $targets = @($State.evidenceTargetPaths)
        if ($resumeRank -lt 1) {
            $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('reset', '--quiet', 'HEAD', '--', $State.modRelativePath)
            $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('-c', 'core.autocrlf=true', 'add', '-A', '--', $State.modRelativePath)
            foreach ($target in $targets) {
                $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('reset', '--quiet', 'HEAD', '--', $target)
            }
            $c1Boundary = Assert-StagedCheckpointBoundary -WorkingDirectory $worktree -Checkpoint 'C1' `
                -AllowedRoot ([string]$State.modRelativePath) -ExcludedPaths $targets
            $c1Expected = @($normalization.files | Where-Object { [string]$_.repositoryPath -cnotin $targets } |
                ForEach-Object { [ordered]@{ path = [string]$_.repositoryPath; sha256 = [string]$_.indexedSha256 } })
            $c1ExpectedPaths = @($c1Expected | ForEach-Object { [string]$_.path })
            $c1Absent = @($c1Boundary.stagedPaths | Where-Object { [string]$_ -cnotin $c1ExpectedPaths })
            $null = Assert-CheckpointIndexState -WorkingDirectory $worktree -Checkpoint 'C1' `
                -ExpectedRecords $c1Expected -AbsentPaths $c1Absent
            $c1Staged = Invoke-Git -WorkingDirectory $worktree -Arguments @('diff', '--cached', '--quiet') -AllowFailure
            if ($c1Staged.exitCode -eq 0 -and $State.localizationMode -eq 'none') { throw 'The archive is already current; an empty non-localization evidence commit is not allowed.' }
            if ($c1Staged.exitCode -notin @(0, 1)) { throw 'Unable to inspect the C1 index.' }
            $State.evidenceChain.c1ParentOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
            $State.evidenceChain.c1ParentTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
            $c1Arguments = @('commit', '-m', "chore($($State.modSlug)): sync upstream non-localization [C1]")
            if ($c1Staged.exitCode -eq 0) {
                $c1Arguments = @('commit', '--allow-empty', '-m', "chore($($State.modSlug)): sync upstream non-localization [C1]")
                $State.evidenceChain.c1EmptyReason = 'active localization target contains the only upstream delta'
            }
            $null = Invoke-Git -WorkingDirectory $worktree -Arguments $c1Arguments
            $State.evidenceChain.c1Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
            $State.evidenceChain.c1TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
            Save-State -State $State
            $resumeRank = 1
        }

        if ($State.localizationMode -eq 'zh-tw') {
            if ($resumeRank -lt 2) {
                $State.evidenceChain.c2ParentOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
                $State.evidenceChain.c2ParentTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
                foreach ($target in $targets) {
                    $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('reset', '--quiet', 'HEAD', '--', $target)
                }
                $null = Invoke-Git -WorkingDirectory $worktree -Arguments (@('-c', 'core.autocrlf=true', 'add', '-A', '--') + $targets)
                foreach ($record in $State.localizationFiles) {
                    $indexObject = ":$([string]$record.relativePath)"
                    $actualIndexed = Get-GitBlobBytes -WorkingDirectory $worktree -Object $indexObject
                    if ((Get-Sha256Bytes -Bytes $actualIndexed) -ne $record.indexedSha256) { throw 'C2 index bytes do not match the immutable indexed localization artifact.' }
                }
                $null = Assert-StagedCheckpointBoundary -WorkingDirectory $worktree -Checkpoint 'C2' -AllowedPaths $targets
                $c2Expected = @($State.localizationFiles | ForEach-Object {
                    [ordered]@{ path = [string]$_.relativePath; sha256 = [string]$_.indexedSha256 }
                })
                $c2ExpectedPaths = @($c2Expected | ForEach-Object { [string]$_.path })
                $null = Assert-CheckpointIndexState -WorkingDirectory $worktree -Checkpoint 'C2' `
                    -ExpectedRecords $c2Expected -AbsentPaths @($targets | Where-Object { [string]$_ -cnotin $c2ExpectedPaths })
                $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '--allow-empty', '-m', "chore($($State.modSlug)): checkpoint upstream localization [C2]")
                $State.evidenceChain.c2Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
                $State.evidenceChain.c2TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
                $State.evidenceChain.c2Status = 'committed'
                $State.evidenceChain.c2Reason = New-CheckpointReason -State $State -Checkpoint C2 `
                    -ParentTreeOid ([string]$State.evidenceChain.c2ParentTreeOid) -TreeOid ([string]$State.evidenceChain.c2TreeOid)
                Save-State -State $State
                $resumeRank = 2
            }
            if ($resumeRank -lt 3) {
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
                $null = Assert-StagedCheckpointBoundary -WorkingDirectory $worktree -Checkpoint 'C3' -AllowedPaths $c3Targets
                $c3Expected = @($State.localizationFiles | ForEach-Object {
                    [ordered]@{ path = [string]$_.relativePath; sha256 = [string]$_.mergedSha256 }
                })
                $null = Assert-CheckpointIndexState -WorkingDirectory $worktree -Checkpoint 'C3' `
                    -ExpectedRecords $c3Expected -AbsentPaths @($targets | Where-Object { [string]$_ -cnotin $c3Targets })
                $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '--allow-empty', '-m', "feat($($State.modSlug)): restore approved zh-tw localization [C3]")
                $State.evidenceChain.c3Oid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
                $State.evidenceChain.c3TreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
                $State.evidenceChain.c3Status = 'committed'
                $State.evidenceChain.c3Reason = New-CheckpointReason -State $State -Checkpoint C3 `
                    -ParentTreeOid ([string]$State.evidenceChain.c3ParentTreeOid) -TreeOid ([string]$State.evidenceChain.c3TreeOid)
                Save-State -State $State
                $resumeRank = 3
            }
        }
        elseif ($resumeRank -lt 4) {
            $State.evidenceChain.c2Status = 'not-applicable'
            $State.evidenceChain.c2Reason = New-CheckpointReason -State $State -Checkpoint C2 -ParentTreeOid $null -TreeOid $null
            $State.evidenceChain.c3Status = 'not-applicable'
            $State.evidenceChain.c3Reason = New-CheckpointReason -State $State -Checkpoint C3 -ParentTreeOid $null -TreeOid $null
            Save-State -State $State
        }

        if ($resumeRank -lt 4) {
            $null = Invoke-Git -WorkingDirectory $worktree -Arguments (@('-c', 'core.autocrlf=true', 'add', '--') + @($State.metadataPaths))
            $null = Assert-StagedCheckpointBoundary -WorkingDirectory $worktree -Checkpoint 'F' -AllowedPaths @($State.metadataPaths)
            $metadataPreview = Get-Content -LiteralPath ([string]$State.metadataPreview.path) -Raw | ConvertFrom-Json -AsHashtable
            $fExpected = @($metadataPreview.files | ForEach-Object {
                [ordered]@{ path = [string]$_.path; sha256 = [string]$_.indexedSha256 }
            })
            $null = Assert-CheckpointIndexState -WorkingDirectory $worktree -Checkpoint 'F' -ExpectedRecords $fExpected
            $staged = Invoke-Git -WorkingDirectory $worktree -Arguments @('diff', '--cached', '--quiet') -AllowFailure
            if ($staged.exitCode -eq 1) {
                $null = Invoke-Git -WorkingDirectory $worktree -Arguments @('commit', '-m', "docs($($State.modSlug)): update archive metadata [F]")
            }
            elseif ($staged.exitCode -ne 0) { throw 'Unable to inspect staged metadata.' }
            $State.evidenceChain.fOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
            $State.evidenceChain.fTreeOid = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD^{tree}')).output.Trim()
            $State.candidateOid = $State.evidenceChain.fOid
            $State.candidateTreeOid = $State.evidenceChain.fTreeOid
            $State.status = 'candidate-committed'
            Save-State -State $State
        }
        $finalInstallManifestPath = Join-Path $State.artifactsRoot 'install-manifest.json'
        $State.installManifest = New-Manifest -Root $State.installRoot -OutputPath $finalInstallManifestPath -Kind 'install'

        $notApplicableEvidence = [ordered]@{ status = 'not-applicable'; path = $null; sha256 = 'not-applicable' }
        $evidence = [ordered]@{
            c1C2Diff = $notApplicableEvidence; c1C2NameStatus = $notApplicableEvidence
            c2C3Diff = $notApplicableEvidence; c2C3NameStatus = $notApplicableEvidence
            c3FDiff = $notApplicableEvidence; c3FNameStatus = $notApplicableEvidence
        }
        $evidenceTasks = @(
            [ordered]@{ name = 'c0C1Diff'; artifactName = 'c0-c1.diff'; baseOid = $State.evidenceChain.c0Oid; headOid = $State.evidenceChain.c1Oid; treeOid = $State.evidenceChain.c1TreeOid; arguments = @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.c1Oid)") }
            [ordered]@{ name = 'c0C1NameStatus'; artifactName = 'c0-c1.name-status.txt'; baseOid = $State.evidenceChain.c0Oid; headOid = $State.evidenceChain.c1Oid; treeOid = $State.evidenceChain.c1TreeOid; arguments = @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.c1Oid)") }
            [ordered]@{ name = 'c1ParentNameStatus'; artifactName = 'c1-parent.name-status.txt'; baseOid = $State.evidenceChain.c1ParentOid; headOid = $State.evidenceChain.c1Oid; treeOid = $State.evidenceChain.c1TreeOid; arguments = @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c1ParentOid)..$($State.evidenceChain.c1Oid)") }
        )
        if ($State.localizationMode -eq 'zh-tw') {
            $evidenceTasks += @(
                [ordered]@{ name = 'c1C2Diff'; artifactName = 'c1-c2.diff'; baseOid = $State.evidenceChain.c1Oid; headOid = $State.evidenceChain.c2Oid; treeOid = $State.evidenceChain.c2TreeOid; arguments = @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c1Oid)..$($State.evidenceChain.c2Oid)") }
                [ordered]@{ name = 'c1C2NameStatus'; artifactName = 'c1-c2.name-status.txt'; baseOid = $State.evidenceChain.c1Oid; headOid = $State.evidenceChain.c2Oid; treeOid = $State.evidenceChain.c2TreeOid; arguments = @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c1Oid)..$($State.evidenceChain.c2Oid)") }
                [ordered]@{ name = 'c2C3Diff'; artifactName = 'c2-c3.diff'; baseOid = $State.evidenceChain.c2Oid; headOid = $State.evidenceChain.c3Oid; treeOid = $State.evidenceChain.c3TreeOid; arguments = @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c2Oid)..$($State.evidenceChain.c3Oid)") }
                [ordered]@{ name = 'c2C3NameStatus'; artifactName = 'c2-c3.name-status.txt'; baseOid = $State.evidenceChain.c2Oid; headOid = $State.evidenceChain.c3Oid; treeOid = $State.evidenceChain.c3TreeOid; arguments = @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c2Oid)..$($State.evidenceChain.c3Oid)") }
                [ordered]@{ name = 'c2ParentNameStatus'; artifactName = 'c2-parent.name-status.txt'; baseOid = $State.evidenceChain.c2ParentOid; headOid = $State.evidenceChain.c2Oid; treeOid = $State.evidenceChain.c2TreeOid; arguments = @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c2ParentOid)..$($State.evidenceChain.c2Oid)") }
                [ordered]@{ name = 'c3ParentNameStatus'; artifactName = 'c3-parent.name-status.txt'; baseOid = $State.evidenceChain.c3ParentOid; headOid = $State.evidenceChain.c3Oid; treeOid = $State.evidenceChain.c3TreeOid; arguments = @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c3ParentOid)..$($State.evidenceChain.c3Oid)") }
            )
            if ($State.evidenceChain.fOid -ne $State.evidenceChain.c3Oid) {
                $evidenceTasks += @(
                    [ordered]@{ name = 'c3FDiff'; artifactName = 'c3-f.diff'; baseOid = $State.evidenceChain.c3Oid; headOid = $State.evidenceChain.fOid; treeOid = $State.evidenceChain.fTreeOid; arguments = @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c3Oid)..$($State.evidenceChain.fOid)") }
                    [ordered]@{ name = 'c3FNameStatus'; artifactName = 'c3-f.name-status.txt'; baseOid = $State.evidenceChain.c3Oid; headOid = $State.evidenceChain.fOid; treeOid = $State.evidenceChain.fTreeOid; arguments = @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c3Oid)..$($State.evidenceChain.fOid)") }
                )
            }
        }
        $evidenceTasks += @(
            [ordered]@{ name = 'c0FDiff'; artifactName = 'c0-f.diff'; baseOid = $State.evidenceChain.c0Oid; headOid = $State.evidenceChain.fOid; treeOid = $State.evidenceChain.fTreeOid; arguments = @('diff', '--full-index', '--binary', '--no-ext-diff', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.fOid)") }
            [ordered]@{ name = 'c0FNameStatus'; artifactName = 'c0-f.name-status.txt'; baseOid = $State.evidenceChain.c0Oid; headOid = $State.evidenceChain.fOid; treeOid = $State.evidenceChain.fTreeOid; arguments = @('diff', '--name-status', '--no-renames', "$($State.evidenceChain.c0Oid)..$($State.evidenceChain.fOid)") }
        )
        $evidenceBatch = New-GitEvidenceBatch -State $State -TaskSpecifications $evidenceTasks -MaxConcurrency 4
        foreach ($name in $evidenceBatch.artifacts.Keys) { $evidence[$name] = $evidenceBatch.artifacts[$name] }
        $State.evidenceDiffs = $evidence
        $candidateTaskStartedAt = Get-UtcTimestamp
        $State.candidateTreeManifest = New-GitTreeManifest -State $State -CommitOid $State.evidenceChain.fOid
        $candidateTask = [ordered]@{
            name = 'candidateTreeManifest'; baseOid = $State.evidenceChain.fOid; headOid = $State.evidenceChain.fOid
            treeOid = $State.evidenceChain.fTreeOid; artifact = $State.candidateTreeManifest
            startedAt = $candidateTaskStartedAt; completedAt = Get-UtcTimestamp
        }
        $parameterVersion = 'full-index-binary-no-renames-v2'
        $tuple = [ordered]@{
            generation = $State.evidenceGeneration; chain = $State.evidenceChain
            targetPathsSha256 = $State.evidenceTargetPathsSha256; archiveSha256 = $State.archive.sha256
            artifactSha256 = [ordered]@{
                extraction = $State.extractionManifest.sha256; rawInstall = $State.rawInstallManifest.sha256
                install = $State.installManifest.sha256; candidateTree = $State.candidateTreeManifest.sha256
                gitIndexNormalization = $State.gitIndexNormalization.sha256; metadataPreview = $State.metadataPreview.sha256
                securityOverride = if ($State.Contains('securityOverrideReceipt') -and $State.securityOverrideReceipt) { $State.securityOverrideReceipt.sha256 } else { $null }
                precommitSecurity = $State.securityPrecommitValidation.sha256
            }
            parameterVersion = $parameterVersion
        }
        $tupleSha = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $tuple -Depth 20 -Compress)))
        Assert-BuildCommitsRecordedCheckpoints -State $State
        foreach ($task in @($evidenceBatch.tasks) + @($candidateTask)) {
            if (-not (Test-Path -LiteralPath ([string]$task.artifact.path) -PathType Leaf) -or
                (Get-FileSha256 -Path ([string]$task.artifact.path)) -cne [string]$task.artifact.sha256 -or
                (Get-Item -LiteralPath ([string]$task.artifact.path)).Length -ne [int64]$task.artifact.size) {
                throw "Coordinator verification rejected Git evidence task $($task.name)."
            }
        }
        $spotCheckTask = @($evidenceBatch.tasks | Sort-Object { [string]$_.name })[0]
        $spotCheckTree = (Invoke-Git -WorkingDirectory $worktree -Arguments @('rev-parse', "$($spotCheckTask.headOid)^{tree}")).output.Trim()
        if ($spotCheckTree -cne [string]$spotCheckTask.treeOid) { throw 'Coordinator Git object spot-check rejected the bounded evidence batch.' }
        $changedPathVerification = Assert-EvidenceChangedPathAllowlists -State $State
        $receiptPath = Join-Path $State.artifactsRoot 'evidence-generation-receipt.json'
        Write-AtomicJson -Path $receiptPath -Value ([ordered]@{
            schemaVersion = 2; generation = $State.evidenceGeneration; runId = $State.runId
            executionMode = $evidenceBatch.executionMode; maxConcurrency = $evidenceBatch.maxConcurrency
            batchStartedAt = $evidenceBatch.startedAt; batchCompletedAt = Get-UtcTimestamp
            gitVersion = (Invoke-Git -WorkingDirectory $worktree -Arguments @('--version')).output
            parameterVersion = $parameterVersion; inputTupleSha256 = $tupleSha
            evidenceChain = $State.evidenceChain; candidateTreeManifest = $State.candidateTreeManifest
            artifacts = $evidence; tasks = @($evidenceBatch.tasks) + @($candidateTask)
            coordinatorVerification = [ordered]@{
                result = 'passed'; artifactCount = @($evidenceBatch.tasks).Count + 1; changedPathAllowlists = $changedPathVerification
                spotCheckTask = [string]$spotCheckTask.name; spotCheckHeadOid = [string]$spotCheckTask.headOid
                spotCheckTreeOid = $spotCheckTree; verifiedAt = Get-UtcTimestamp
            }
            generatedAt = Get-UtcTimestamp
        })
        $State.evidenceReceipt = [ordered]@{ path = $receiptPath; sha256 = Get-FileSha256 -Path $receiptPath }
        $State.candidateGate = [ordered]@{ status = 'not-run' }
        if ($State.Contains('buildCommitsRecovery') -and $State.buildCommitsRecovery) {
            $State.buildCommitsRecovery.status = 'recovered'
            $State.buildCommitsRecovery.recoveredAt = Get-UtcTimestamp
            $State.buildCommitsRecovery.recoveredHeadOid = $State.evidenceChain.fOid
            $State.buildCommitsRecovery.recoveryDisposition = 'same-run-checkpoint-resume'
        }
        Complete-Stage -State $State -Context $stage -ArtifactSha256 $State.evidenceReceipt.sha256 -Data ([ordered]@{ evidenceChain = $State.evidenceChain; receipt = $State.evidenceReceipt })
    }
    catch {
        $failureMessage = $_.Exception.Message
        try { Save-BuildCommitsFailure -State $State -Context $stage -ErrorMessage $failureMessage } catch { }
        throw
    }
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

function Repair-SuccessfulCandidateGateState {
    param([Collections.IDictionary] $State)
    if ([string]$State.candidateGate.status -cne 'passed' -or [string]$State.status -cne 'failed') { return $false }
    $State.status = 'candidate-committed'
    $State.waitingReason = $null
    $State.lastError = $null
    $true
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
        if (Repair-SuccessfulCandidateGateState -State $State) {
            Save-State -State $State
            $State = Read-State -Path $State.statePath
        }
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
        $rows = foreach ($changeType in @('unchanged', 'localized_source', 'missing_zh_tw', 'zh_tw_only_changed', 'source_changed_translation_unchanged', 'source_and_translation_changed', 'new_key', 'deleted_key', 'blocked')) {
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
    $securityOverrideSummary = @(
        $State.securityOverrides |
            Sort-Object { [string]$_.relativePath } |
            ForEach-Object { "archiveSha256=$($_.archiveSha256);relativePath=$($_.relativePath);fileSha256=$($_.fileSha256)" }
    ) -join ' | '
    if ([string]::IsNullOrWhiteSpace($securityOverrideSummary)) { $securityOverrideSummary = 'none' }
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
- Translation quality path/blob/SHA-256: $($State.translationQualityPath) / $($State.translationQualityBlobOid) / $($State.translationQualitySha256)
- Localization mode/ids: $($State.localizationMode) / $localizationIds
- Localization raw/indexed/merged evidence: $localizationEvidence
- Localization workset SHA-256: $worksetSha
- Localization workset deletion receipt SHA-256: $worksetDeletionReceiptSha
- Localization target/approved-span/unchanged/removed/BLOCKED counts: $(@($State.evidenceTargetPaths).Count) / $approvedSpanCount / $unchangedTargetCount / $removedTargetCount / 0
- Localization scope: $localizationScope
- Archive filename/SHA-256: $($State.archive.filename) / $($State.archive.sha256)
- Source tuple contract SHA-256: $($State.sourceTuple.contractSha256)
- Source receipt SHA-256: $(if ($State.Contains('sourceReceipt') -and $State.sourceReceipt) { $State.sourceReceipt.sha256 } else { 'not-applicable' })
- Security overrides: $securityOverrideSummary
- Security override receipt SHA-256: $(if ($State.Contains('securityOverrideReceipt') -and $State.securityOverrideReceipt) { $State.securityOverrideReceipt.sha256 } else { 'not-applicable' })
- Pre-commit security validation SHA-256: $($State.securityPrecommitValidation.sha256)
- External review: $($State.externalReview.status)
$localizationTable
"@
}

function Assert-PublishedPrAtF {
    param([Collections.IDictionary] $State)
    $localHead = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('rev-parse', 'HEAD')).output.Trim()
    $remoteHead = (Invoke-Git -WorkingDirectory $State.worktreePath -Arguments @('ls-remote', '--heads', $State.remote, "refs/heads/$($State.branch)")).output.Split("`t")[0]
    $pr = (Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'view', [string]$State.prNumber, '--json', 'state,isDraft,baseRefName,headRefName,headRefOid,body')).output | ConvertFrom-Json -AsHashtable
    if ($localHead -ne $State.evidenceChain.fOid -or $remoteHead -ne $localHead -or $pr.headRefOid -ne $localHead) {
        throw 'Local, remote, PR head, and immutable F are not identical.'
    }
    if ($pr.state -ne 'OPEN' -or $pr.isDraft -or $pr.baseRefName -ne $State.pullRequestBase -or $pr.headRefName -ne $State.branch) {
        throw 'Published PR state, draft flag, base, or head branch changed.'
    }
    $expectedBody = (Get-PrBody -State $State).Replace("`r`n", "`n")
    $actualBody = ([string]$pr.body).Replace("`r`n", "`n")
    if ($actualBody -cne $expectedBody) { throw 'Published PR evidence summary body changed.' }
    [ordered]@{
        localHead = $localHead
        remoteHead = $remoteHead
        prHead = $pr.headRefOid
        prBodySha256 = Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($actualBody))
    }
}

function Assert-LocalReviewInput {
    param([Collections.IDictionary] $State, [Collections.IDictionary] $Review)
    if ($Review.result -ne 'passed' -or $Review.headOid -ne $State.evidenceChain.fOid -or
        $Review.candidateGateSha256 -ne $State.candidateGate.validationReportSha256 -or
        -not $State.reviewSnapshot -or $Review.feedbackSnapshotSha256 -ne $State.reviewSnapshot.sha256) {
        throw 'Local Review does not pass and bind the current F/Candidate Gate/feedback snapshot tuple.'
    }
    $reviewedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact([string]$Review.reviewedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$reviewedAt)) {
        throw 'Local Review reviewedAt must be an ISO-8601 round-trip timestamp.'
    }
    $capturedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact([string]$State.reviewSnapshot.capturedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$capturedAt) -or
        $reviewedAt -lt $capturedAt) {
        throw 'Local review predates the immutable feedback snapshot.'
    }
    if (@($Review.securityBlocking).Count -ne 0) { throw 'Local Review contains a security-blocking finding.' }
    foreach ($finding in @($Review.findings)) {
        if ($finding -isnot [Collections.IDictionary]) { throw 'Local Review finding is not an object.' }
        foreach ($field in @('priority', 'location', 'violatedBaseline', 'evidence', 'consequence', 'disposition')) {
            if (-not $finding.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$finding[$field])) { throw "Local Review finding is missing $field." }
        }
        if ([string]$finding.disposition -notin @('keep', 'resolved')) { throw 'Local Review contains a finding without a completed disposition.' }
    }
    $true
}

function Assert-ReviewSnapshotReceipt {
    param([Collections.IDictionary] $State)
    if (-not $State.reviewSnapshot -or [string]::IsNullOrWhiteSpace([string]$State.reviewSnapshot.path) -or
        [string]::IsNullOrWhiteSpace([string]$State.reviewSnapshot.sha256)) {
        throw 'Review feedback snapshot receipt is missing.'
    }
    $path = Assert-NoReparsePath -Path ([string]$State.reviewSnapshot.path) -Root ([string]$State.repositoryRoot) -Label 'Review feedback snapshot'
    $expectedPath = [IO.Path]::GetFullPath((Join-Path ([string]$State.artifactsRoot) 'review-snapshot.json'))
    if ($path -cne $expectedPath) { throw 'Review feedback snapshot path changed.' }
    if ((Get-FileSha256 -Path $path) -cne [string]$State.reviewSnapshot.sha256) { throw 'Feedback snapshot SHA-256 changed.' }
    $document = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$document.schemaVersion -ne 1 -or [string]$document.runId -cne [string]$State.runId -or
        [string]$document.headOid -cne [string]$State.evidenceChain.fOid -or
        [string]$State.reviewSnapshot.headOid -cne [string]$State.evidenceChain.fOid) {
        throw 'Review feedback snapshot does not bind this run and immutable F.'
    }
    if (($document.externalReview | ConvertTo-Json -Depth 20 -Compress) -cne
        ($State.externalReview | ConvertTo-Json -Depth 20 -Compress)) {
        throw 'Review feedback snapshot external observation differs from state.'
    }
    $document
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
    $pr = (Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'view', [string]$prNumber, '--json', 'number,url,state,isDraft,baseRefName,headRefName,headRefOid,body')).output | ConvertFrom-Json -AsHashtable
    if ($pr.state -ne 'OPEN' -or $pr.isDraft -or $pr.baseRefName -ne $State.pullRequestBase -or $pr.headRefName -ne $State.branch -or $pr.headRefOid -ne $head) {
        throw 'Created or reused PR does not match the required open non-draft base/head/F tuple.'
    }
    if (([string]$pr.body).Replace("`r`n", "`n") -cne $currentBody.Replace("`r`n", "`n")) {
        throw 'Created or reused PR evidence summary body changed during publication.'
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
        $validator = Join-Path $PSScriptRoot 'Test-ModUpdateCandidate.ps1'
        $completion = & $validator -StatePath $State.statePath -ReviewCompletion -CheckOnly `
            -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
        if ($completion.result -ne 'passed') { throw 'Independent Review completion revalidation rejected the current F.' }
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
    if (-not $State.Contains('reviewSnapshot') -or -not $State.reviewSnapshot) {
        $snapshotAt = Get-UtcTimestamp
        if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
            $external = [ordered]@{ status = 'unavailable'; reason = 'gh is unavailable'; headOid = $State.headOid; verifiedAt = $snapshotAt; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
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
                $repositoryName = ((Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('repo', 'view', '--json', 'nameWithOwner')).output | ConvertFrom-Json -AsHashtable).nameWithOwner
                $repositoryParts = @(([string]$repositoryName).Split('/'))
                if ($repositoryParts.Count -ne 2 -or @($repositoryParts | Where-Object { [string]::IsNullOrWhiteSpace([string]$_) }).Count -ne 0) {
                    throw 'Unable to resolve the fixed repository owner/name for the Review feedback snapshot.'
                }
                $threadQuery = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{id isResolved isOutdated path line comments(first:100){nodes{id body path line createdAt author{login} commit{oid}} pageInfo{hasNextPage}}} pageInfo{hasNextPage}}}}}'
                $threadView = Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @(
                    'api', 'graphql', '-f', "query=$threadQuery", '-F', "owner=$($repositoryParts[0])", '-F', "name=$($repositoryParts[1])", '-F', "number=$($State.prNumber)"
                ) -AllowFailure
                if ($threadView.exitCode -ne 0) {
                    throw "Unable to capture PR review threads: $($threadView.warning) $($threadView.output)".Trim()
                }
                $threadDocument = $threadView.output | ConvertFrom-Json -AsHashtable
                $threads = $threadDocument.data.repository.pullRequest.reviewThreads
                if (-not $threads -or [bool]$threads.pageInfo.hasNextPage -or
                    @($threads.nodes | Where-Object { $_.comments -and [bool]$_.comments.pageInfo.hasNextPage }).Count -ne 0) {
                    throw 'Review feedback snapshot exceeds the bounded thread capacity or is incomplete.'
                }
                $snapshot['reviewThreads'] = @($threads.nodes)
                if ($State.localizationMode -eq 'none') {
                    $external = [ordered]@{ status = 'not-applicable'; reason = 'localization mode none'; headOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
                }
                else {
                    $matching = @($snapshot.reviews | Where-Object { $_.author.login -match 'copilot-pull-request-reviewer' -and $_.commit.oid -eq $State.headOid } | Sort-Object submittedAt -Descending)
                    $requested = @($snapshot.reviewRequests | Where-Object { $_.login -match 'copilot-pull-request-reviewer' })
                    $external = if ($matching.Count -ge 1) {
                        [ordered]@{ status = 'completed'; headOid = $State.headOid; reviewId = $matching[0].id; reviewerLogin = $matching[0].author.login; submittedAt = $matching[0].submittedAt; reviewCommitOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
                    }
                    else {
                        $requestEvidence = $null
                        $requestFailed = $false
                        if ($requested.Count -eq 0 -and $State.externalReview.status -eq 'not-requested') {
                            $request = Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('api', '--method', 'POST', "repos/$repositoryName/pulls/$($State.prNumber)/requested_reviewers", '-f', 'reviewers[]=copilot-pull-request-reviewer[bot]') -AllowFailure
                            $requestEvidence = [ordered]@{ exitCode = $request.exitCode; requestedAt = Get-UtcTimestamp; warning = $request.warning }
                            if ($request.exitCode -ne 0) { $requestFailed = $true }
                        }
                        elseif ($requested.Count -ge 1) {
                            $requestEvidence = [ordered]@{ source = 'existing-review-request'; reviewerLogin = [string]$requested[0].login; observedAt = $snapshotAt }
                        }
                        if ($requestFailed) {
                            [ordered]@{ status = 'unavailable'; reason = "External Review request failed: $($request.warning) $($request.output)".Trim(); requestEvidence = $requestEvidence; headOid = $State.headOid; verifiedAt = $snapshotAt; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
                        }
                        else {
                            [ordered]@{ status = 'requested-pending'; reason = 'No completed Copilot review existed in the one bounded snapshot; no polling was scheduled.'; requestEvidence = $requestEvidence; headOid = $State.headOid; snapshotAt = $snapshotAt; pollingWaitSeconds = 0 }
                        }
                    }
                }
            }
        }
        if (-not $external.Contains('pollingWaitSeconds') -or [int64]$external.pollingWaitSeconds -ne 0) { throw 'External Review polling wait must remain zero.' }
        $artifactPath = Join-Path $State.artifactsRoot 'review-snapshot.json'
        Write-AtomicJson -Path $artifactPath -Value ([ordered]@{ schemaVersion = 1; runId = $State.runId; headOid = $State.headOid; capturedAt = $snapshotAt; snapshot = $snapshot; externalReview = $external })
        $State.externalReview = $external
        $State.reviewSnapshot = [ordered]@{ path = $artifactPath; sha256 = Get-FileSha256 -Path $artifactPath; headOid = $State.headOid; capturedAt = $snapshotAt }
        $State.status = 'reviewing'
        Save-State -State $State
        $updatedBody = Get-PrBody -State $State
        $null = Invoke-Gh -WorkingDirectory $State.worktreePath -Arguments @('pr', 'edit', [string]$State.prNumber, '--body', $updatedBody)
        $null = Assert-PublishedPrAtF -State $State
    }
    else {
        $null = Assert-ReviewSnapshotReceipt -State $State
    }

    if ([string]::IsNullOrWhiteSpace($LocalReviewPath) -or -not (Test-Path -LiteralPath $LocalReviewPath -PathType Leaf)) {
        return (Suspend-Stage -State $State -Context $stage -Result 'waiting-input' -ArtifactSha256 ([string]$State.reviewSnapshot.sha256) `
            -OutputStage 'local-review' -Data ([ordered]@{
                required = 'Review the current F and immutable feedback snapshot with the packaged Review Baseline, then resume with -LocalReviewPath.'
                headOid = $State.evidenceChain.fOid; candidateGateSha256 = $State.candidateGate.validationReportSha256
                feedbackSnapshotPath = $State.reviewSnapshot.path; feedbackSnapshotSha256 = $State.reviewSnapshot.sha256
            }))
    }

    $localReview = Get-Content -LiteralPath $LocalReviewPath -Raw | ConvertFrom-Json -AsHashtable
    $null = Assert-LocalReviewInput -State $State -Review $localReview
    $localReviewArtifactPath = Join-Path $State.artifactsRoot 'review.json'
    Write-AtomicJson -Path $localReviewArtifactPath -Value $localReview
    $State.localReview = [ordered]@{
        path = $localReviewArtifactPath; sha256 = Get-FileSha256 -Path $localReviewArtifactPath; result = 'passed'
        headOid = $localReview.headOid; candidateGateSha256 = $localReview.candidateGateSha256
        feedbackSnapshotSha256 = $localReview.feedbackSnapshotSha256; reviewedAt = $localReview.reviewedAt
    }
    $State.reviewedOid = $State.evidenceChain.fOid
    Save-State -State $State
    $validator = Join-Path $PSScriptRoot 'Test-ModUpdateCandidate.ps1'
    $completion = & $validator -StatePath $State.statePath -ReviewCompletion `
        -HeartbeatAction { Update-ActiveReservationHeartbeat } -PassThru
    if ($completion.result -ne 'passed') { throw 'Independent Review completion validation rejected the current F.' }
    $State.status = 'awaiting-user-merge'
    Complete-Stage -State $State -Context $stage -ArtifactSha256 $completion.sha256 -Data ([ordered]@{ externalReview = $State.externalReview; reviewSnapshot = $State.reviewSnapshot; localReview = $State.localReview; completionValidation = $completion })
}

function Resolve-InitialState {
    if ([string]::IsNullOrWhiteSpace($StatePath)) { throw "$Command requires -StatePath." }
    Read-State -Path ([IO.Path]::GetFullPath($StatePath))
}

function Invoke-StageCommand {
    param([string] $StageName, [Collections.IDictionary] $State)
    $script:activeReservationState = $State
    $script:lastInvokedStageName = $StageName
    switch ($StageName) {
        'verify-source' { Invoke-VerifySource -State $State }
        'extract' { Invoke-Extract -State $State }
        'install' { Invoke-Install -State $State }
        'localization' { Invoke-Localization -State $State }
        'build-commits' { Invoke-BuildCommits -State $State }
        'validate' { Invoke-Validate -State $State }
        'publish' { Invoke-Publish -State $State }
        'review-snapshot' { Invoke-ReviewSnapshot -State $State }
        'finalize-merge' { Invoke-ModUpdateMergeFinalization -State $State }
        default { throw "Unsupported stage: $StageName" }
    }
}

$writerLease = $null
$activeStatePath = $null
$activeReservationLease = $null
$activeReservationState = $null
$activeSharedCoordinationLease = $null
$activeStageContext = $null
$lastFailedStageName = $null
$lastInvokedStageName = $null
try {
    $result = if ($Command -eq 'acquire-source') {
        Invoke-AcquireSource
    }
    elseif ($Command -eq 'claim') {
        if ($StatePath -and (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
            $state = Read-State -Path $StatePath
            $null = Assert-RunLocalSkillPackage -State $state
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
            $null = Assert-RunLocalSkillPackage -State $state
            Ensure-RunWriterLock -State $state
            $state = Read-State -Path $state.statePath
            $last = $null
            foreach ($stageName in @('verify-source', 'extract', 'install', 'localization', 'build-commits', 'validate', 'publish', 'review-snapshot')) {
                $last = Invoke-StageCommand -StageName $stageName -State $state
                $state = Read-State -Path $state.statePath
                if ($last.result -in @('waiting-input', 'waiting-user', 'waiting-system', 'automation-excluded')) { break }
                if (($Until -eq 'source-verified' -and $stageName -eq 'verify-source') -or $state.status -eq $Until) { break }
            }
            $last
        }
    }
    else {
        $state = Resolve-InitialState
        $null = Assert-RunLocalSkillPackage -State $state
        Ensure-RunWriterLock -State $state
        $state = Read-State -Path $state.statePath
        Invoke-StageCommand -StageName $Command -State $state
    }

    if ($PassThru) { $result } else { $result | ConvertTo-Json -Depth 40 -Compress }
}
catch {
    $failureMessage = $_.Exception.Message
    $isPackageDrift = $failureMessage.StartsWith('Skill package drift:', [StringComparison]::Ordinal)
    $failedStageName = if ($script:activeStageContext) { [string]$script:activeStageContext.name }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$script:lastFailedStageName)) { [string]$script:lastFailedStageName }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$script:lastInvokedStageName)) { [string]$script:lastInvokedStageName }
        else { $Command }
    $errorResult = [ordered]@{
        result = 'failed'
        failureKind = if ($isPackageDrift) { 'package-drift' } else { 'stage-failure' }
        stage = $failedStageName
        statePath = if ($activeStatePath) { $activeStatePath } else { $StatePath }
        error = $failureMessage
        at = Get-UtcTimestamp
    }
    if (-not $isPackageDrift -and $writerLease -and $activeStatePath -and (Test-Path -LiteralPath $activeStatePath -PathType Leaf)) {
        try {
            $failedState = Read-State -Path $activeStatePath
            if ($script:activeStageContext) {
                try {
                    $null = Fail-Stage -State $failedState -Context $script:activeStageContext `
                        -ErrorMessage $failureMessage -RecoveryDisposition 'same-run-stage-retry'
                }
                catch { }
            }
            $failedState.lastError = $errorResult
            $failedState.status = if ($failureMessage -match 'identity|security|archive|path|user') { 'waiting-user' } else { 'failed' }
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
