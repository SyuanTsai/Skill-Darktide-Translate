#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $StatePath,
    [switch] $SecurityPayloadOnly,
    [switch] $ReviewCompletion,
    [switch] $CheckOnly,
    [scriptblock] $HeartbeatAction,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$luaLocalizationScannerModulePath = Join-Path $PSScriptRoot 'LuaLocalizationScanner.psm1'
Import-Module -Name $luaLocalizationScannerModulePath -Force -ErrorAction Stop

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

# This validator intentionally does not import the generator entrypoint. It
# independently reads committed Git objects, manifests,
# approvedSpans, and artifact sha256 values.

function Get-UtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-Sha256Bytes {
    param([byte[]] $Bytes)
    Invoke-Heartbeat
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

function Invoke-Heartbeat {
    if ($HeartbeatAction) { $null = & $HeartbeatAction }
}

function Get-FileSha256 {
    param([string] $Path)
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

function Copy-StreamWithHeartbeat {
    param([IO.Stream] $Source, [IO.Stream] $Destination)
    Invoke-Heartbeat
    $buffer = [byte[]]::new(1MB)
    while (($readCount = $Source.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $Destination.Write($buffer, 0, $readCount)
        Invoke-Heartbeat
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
    finally {
        $memory.Dispose()
        $source.Dispose()
    }
}

function ConvertTo-InvariantString {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-ContractSha256 {
    param([Collections.IDictionary] $Contract)
    Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes(
        ($Contract | ConvertTo-Json -Depth 20 -Compress)
    ))
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

function Assert-NoReparsePath {
    param([string] $Path, [string] $Root, [string] $Label)
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
        if (-not (Test-Path -LiteralPath $current)) { throw "$Label path component is missing." }
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label path contains a symlink or reparse point."
        }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $pathFull }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent)) { throw "Unable to prove $Label physical containment." }
        $current = $parent
    }
    throw "Unable to prove $Label physical containment within 2048 path components."
}

function Assert-NoReparseTree {
    param([string] $Path, [string] $Root, [string] $Label)
    $treeFull = Assert-NoReparsePath -Path $Path -Root $Root -Label $Label
    if (-not (Test-Path -LiteralPath $treeFull -PathType Container)) { throw "$Label is not a directory." }
    Invoke-Heartbeat
    Get-ChildItem -LiteralPath $treeFull -Recurse -Force | ForEach-Object {
        $item = $_
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label contains a symlink or reparse point."
        }
        Invoke-Heartbeat
    }
    $treeFull
}

function Assert-ClaimedArchiveIntegrity {
    param([Collections.IDictionary] $State)
    $Archive = $State.archive
    if (-not $Archive -or -not $Archive.Contains('path') -or -not $Archive.Contains('size') -or -not $Archive.Contains('sha256')) {
        throw 'claimed-archive evidence is incomplete.'
    }
    $archivePath = [string]$Archive.path
    $archivePath = Assert-NoReparsePath -Path $archivePath -Root ([string]$State.repositoryRoot) -Label 'Claimed source archive'
    if ([IO.Path]::GetFileName([string]$Archive.filename) -cne [string]$Archive.filename -or
        [string]$Archive.filename -match '^\s*$') {
        throw 'claimed-archive filename is not one safe file name.'
    }
    $expectedPath = [IO.Path]::GetFullPath((Join-Path (Join-Path ([string]$State.runRoot) 'source') ([string]$Archive.filename)))
    if ($archivePath -cne $expectedPath) {
        throw 'claimed-archive path differs from its fixed run-owned source path.'
    }
    $stream = [IO.File]::Open($archivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -ne [int64]$Archive.size) {
            throw 'claimed-archive size changed after claim.'
        }
        $actualSha256 = Get-FileSha256 -Path $archivePath
        if ($actualSha256 -ne [string]$Archive.sha256) {
            throw 'claimed-archive SHA-256 changed after claim.'
        }
        $actualSha256
    }
    finally {
        $stream.Dispose()
    }
}

function Get-ArchivePayloadRisk {
    param([string] $RelativePath, [byte[]] $Bytes, [int64] $ExternalAttributes = 0)
    $extension = [IO.Path]::GetExtension($RelativePath).ToLowerInvariant()
    if ($extension -in @('.zip', '.7z', '.rar', '.tar', '.gz', '.tgz', '.bz2', '.xz', '.cab', '.iso', '.jar')) { return 'nested-archive' }
    if ($extension -in @('.dll', '.exe', '.com', '.scr', '.msi', '.msp', '.cpl', '.ocx', '.sys', '.drv', '.efi', '.so', '.dylib')) { return 'native-executable' }
    if ($extension -in @('.bat', '.cmd', '.ps1', '.psm1', '.psd1', '.sh', '.bash', '.zsh', '.fish', '.vbs', '.vbe', '.wsf', '.wsh', '.hta', '.reg')) { return 'install-or-system-script' }
    $unixMode = ($ExternalAttributes -shr 16) -band 0xFFFF
    $hasUnixMode = ($unixMode -band 0xF000) -ne 0 -or ($ExternalAttributes -band 0xFFFF) -eq 0
    if ($hasUnixMode -and ($unixMode -band 73) -ne 0) { return 'native-executable' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x4D -and $Bytes[1] -eq 0x5A) { return 'native-executable' }
    if ($Bytes.Length -ge 4 -and $Bytes[0] -eq 0x7F -and $Bytes[1] -eq 0x45 -and $Bytes[2] -eq 0x4C -and $Bytes[3] -eq 0x46) { return 'native-executable' }
    if ($Bytes.Length -ge 4 -and [Convert]::ToHexString($Bytes[0..3]) -in @('FEEDFACE', 'CEFAEDFE', 'FEEDFACF', 'CFFAEDFE', 'CAFEBABE')) { return 'native-executable' }
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0x23 -and $Bytes[1] -eq 0x21) { return 'install-or-system-script' }
    $null
}

function Assert-ArchivePayloadSecurityIntegrity {
    param([Collections.IDictionary] $State, [Collections.IDictionary] $Chain, [string] $Worktree)
    if (-not $State.extractionManifest -or [string]::IsNullOrWhiteSpace([string]$State.extractionManifest.path) -or
        [string]::IsNullOrWhiteSpace([string]$State.extractionManifest.sha256)) {
        throw 'Extraction manifest receipt is missing before payload security validation.'
    }
    $manifestPath = Assert-NoReparsePath -Path ([string]$State.extractionManifest.path) -Root ([string]$State.repositoryRoot) -Label 'Extraction manifest'
    $expectedManifestPath = [IO.Path]::GetFullPath((Join-Path ([string]$State.artifactsRoot) 'extraction-manifest.json'))
    if ($manifestPath -cne $expectedManifestPath) { throw 'Extraction manifest path changed.' }
    if ((Get-FileSha256 -Path $manifestPath) -cne [string]$State.extractionManifest.sha256) { throw 'Extraction manifest SHA-256 changed.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ([IO.Path]::GetFullPath([string]$manifest.root) -cne [IO.Path]::GetFullPath([string]$State.extractionRoot)) {
        throw 'Extraction manifest root changed before payload security validation.'
    }
    $archiveAttributes = [ordered]@{}
    Add-Type -AssemblyName System.IO.Compression
    $archiveStream = [IO.File]::Open([string]$State.archive.path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            foreach ($entry in $archive.Entries) { $archiveAttributes[$entry.FullName.Replace('\', '/')] = [int64]$entry.ExternalAttributes }
        }
        finally { $archive.Dispose() }
    }
    finally { $archiveStream.Dispose() }
    $approvalArtifact = $null
    if ($State.Contains('securityOverrideReceipt') -and $State.securityOverrideReceipt) {
        $approvalPath = Assert-NoReparsePath -Path ([string]$State.securityOverrideReceipt.path) -Root ([string]$State.repositoryRoot) -Label 'Security override receipt'
        if ($approvalPath -cne [IO.Path]::GetFullPath((Join-Path ([string]$State.artifactsRoot) 'security-overrides.json'))) {
            throw 'Security override receipt path changed.'
        }
        if ((Get-FileSha256 -Path $approvalPath) -cne [string]$State.securityOverrideReceipt.sha256) {
            throw 'Security override receipt SHA-256 changed.'
        }
        $approvalArtifact = Get-Content -LiteralPath $approvalPath -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$approvalArtifact.runId -cne [string]$State.runId -or [string]$approvalArtifact.archiveSha256 -cne [string]$State.archive.sha256) {
            throw 'Security override receipt does not bind this run/archive.'
        }
    }
    $usedApprovals = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in @($manifest.files)) {
        $relative = [string]$record.path
        $physical = Assert-NoReparsePath -Path (Join-Path ([string]$manifest.root) $relative) -Root ([string]$State.repositoryRoot) -Label 'Extraction security payload'
        $bytes = Read-FileBytesWithHeartbeat -Path $physical
        $risk = Get-ArchivePayloadRisk -RelativePath $relative -Bytes $bytes -ExternalAttributes ([int64]$archiveAttributes[$relative])
        if (-not $record.Contains('securityDisposition')) { throw "Extraction security disposition is missing: $relative" }
        $disposition = $record.securityDisposition
        if ([string]::IsNullOrWhiteSpace($risk)) {
            if ([string]$disposition.result -cne 'not-risky') { throw "Safe payload has a contradictory security disposition: $relative" }
            continue
        }
        $fileSha256 = Get-Sha256Bytes -Bytes $bytes
        $modRelative = $relative.Substring(([string]$State.repoModDirectory).Length).TrimStart('/')
        $repositoryPath = "$($State.modRelativePath)/$modRelative"
        $oldSha256 = $null
        $oldExists = Invoke-GitCheck -WorkingDirectory $Worktree -Arguments @('cat-file', '-e', "$($Chain.c0Oid):$repositoryPath") -AllowFailure
        if ($oldExists.exitCode -eq 0) {
            $oldSha256 = Get-Sha256Bytes -Bytes (Get-GitBlobBytes -WorkingDirectory $Worktree -Object "$($Chain.c0Oid):$repositoryPath")
        }
        elseif ($oldExists.exitCode -notin @(1, 128)) { throw "Unable to compare risky payload with C0: $repositoryPath" }
        if ($oldSha256 -ceq $fileSha256) {
            if ([string]$disposition.result -cne 'unchanged-from-c0' -or [string]$disposition.risk -cne $risk -or
                [string]$disposition.fileSha256 -cne $fileSha256 -or [string]$disposition.c0Sha256 -cne $oldSha256) {
                throw "Unchanged risky payload disposition changed: $relative"
            }
            continue
        }
        if (-not $approvalArtifact -or [string]$disposition.result -cne 'approved-exact-tuple' -or
            [string]$disposition.risk -cne $risk -or [string]$disposition.fileSha256 -cne $fileSha256 -or
            [string]$disposition.archiveSha256 -cne [string]$State.archive.sha256) {
            throw "Changed risky payload lacks an exact approval: $relative"
        }
        $matchingApprovals = @($approvalArtifact.approvals | Where-Object {
            [string]$_.archiveSha256 -ceq [string]$State.archive.sha256 -and [string]$_.relativePath -ceq $relative -and [string]$_.fileSha256 -ceq $fileSha256
        })
        if ($matchingApprovals.Count -ne 1) { throw "Changed risky payload approval is missing or ambiguous: $relative" }
        $null = $usedApprovals.Add("$relative`n$fileSha256")
    }
    if ($approvalArtifact -and $usedApprovals.Count -ne @($approvalArtifact.approvals).Count) { throw 'Security override receipt contains an unused or stale approval.' }
    "archive payload security passed; approvals=$($usedApprovals.Count)"
}

function Assert-SourceReceiptIntegrity {
    param([Collections.IDictionary] $State)
    if ([int]$State.schemaVersion -lt 15) { return 'not-applicable: Schema 14 manual source' }
    if (-not $State.sourceReceipt -or -not $State.sourceAcquisition) { throw 'Schema 15 source receipt evidence is missing.' }
    foreach ($field in @('path', 'sha256', 'sourceRequestPath', 'sourceRequestSha256')) {
        if (-not $State.sourceReceipt.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$State.sourceReceipt[$field])) {
            throw "Schema 15 sourceReceipt.$field is missing."
        }
    }
    if (-not $State.sourceAcquisition.Contains('skillSourcePinPath') -or -not $State.sourceAcquisition.Contains('skillSourcePinSha256') -or
        [string]$State.sourceAcquisition.skillSourcePinPath -cne [string]$State.workflowSourcePinPath -or
        [string]$State.sourceAcquisition.skillSourcePinSha256 -cne [string]$State.workflowSourcePinSha256) {
        throw 'Schema 15 source acquisition Skill source pin differs from the verified workflow source pin.'
    }
    $sourceRunRoot = [IO.Path]::GetFullPath([string]$State.runRoot)
    $receiptFull = Assert-NoReparsePath -Path ([string]$State.sourceReceipt.path) -Root ([string]$State.repositoryRoot) -Label 'Schema 15 source receipt'
    $requestFull = Assert-NoReparsePath -Path ([string]$State.sourceReceipt.sourceRequestPath) -Root ([string]$State.repositoryRoot) -Label 'Schema 15 source request'
    $recordFull = Assert-NoReparsePath -Path ([string]$State.sourceAcquisition.recordPath) -Root ([string]$State.repositoryRoot) -Label 'Schema 15 source acquisition record'
    if ($receiptFull -cne [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'review-artifacts/source-receipt.json')) -or
        $requestFull -cne [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'review-artifacts/source-request.json')) -or
        $recordFull -cne [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'review-artifacts/source-acquisition.json'))) {
        throw 'Schema 15 source evidence is outside its fixed run-local paths.'
    }
    $verifier = Join-Path $PSScriptRoot 'Test-SourceReceipt.ps1'
    $verification = & $verifier -ReceiptPath $receiptFull -SourceRequestPath $requestFull -RunRoot $sourceRunRoot `
        -HeartbeatAction $HeartbeatAction -PassThru
    if ($verification.result -cne 'passed') { throw 'Independent source receipt verifier rejected Schema 15 evidence.' }
    if ((Get-FileSha256 -Path ([string]$State.sourceReceipt.path)) -cne [string]$State.sourceReceipt.sha256) { throw 'Schema 15 source receipt SHA-256 changed.' }
    if ((Get-FileSha256 -Path ([string]$State.sourceReceipt.sourceRequestPath)) -cne [string]$State.sourceReceipt.sourceRequestSha256) { throw 'Schema 15 source request SHA-256 changed.' }
    if ([string]::IsNullOrWhiteSpace([string]$State.sourceAcquisition.recordPath) -or
        [string]::IsNullOrWhiteSpace([string]$State.sourceAcquisition.recordSha256) -or
        (Get-FileSha256 -Path ([string]$State.sourceAcquisition.recordPath)) -cne [string]$State.sourceAcquisition.recordSha256) {
        throw 'Schema 15 source acquisition record is missing or changed.'
    }
    $acquisition = Get-Content -LiteralPath $State.sourceAcquisition.recordPath -Raw | ConvertFrom-Json -AsHashtable
    if ([string]$acquisition.runId -cne [string]$State.runId -or [string]$acquisition.mod -cne [string]$State.repoModDirectory -or
        [string]$acquisition.sourceRequestPath -cne [string]$State.sourceReceipt.sourceRequestPath -or
        [string]$acquisition.sourceRequestSha256 -cne [string]$State.sourceReceipt.sourceRequestSha256 -or
        [string]$acquisition.receiptPath -cne [string]$State.sourceReceipt.path -or
        [string]$acquisition.receiptSha256 -cne [string]$State.sourceReceipt.sha256 -or
        [string]$acquisition.skillSourcePinPath -cne [string]$State.sourceAcquisition.skillSourcePinPath -or
        [string]$acquisition.skillSourcePinSha256 -cne [string]$State.sourceAcquisition.skillSourcePinSha256 -or
        [string]$acquisition.skillSourceCommit -cne [string]$State.workflowCommitOid -or
        [string]$acquisition.skillSourceContentSha256 -cne [string]$State.workflowSourceContentSha256 -or
        [string]$acquisition.result.status -cne 'delivered') {
        throw 'Schema 15 source acquisition record tuple changed.'
    }
    $receipt = Get-Content -LiteralPath $State.sourceReceipt.path -Raw | ConvertFrom-Json -AsHashtable
    $expectedAcquisitionResult = [ordered]@{
        result = 'passed'; status = 'delivered'; deliveredPath = [IO.Path]::GetFullPath([string]$receipt.deliveredPath)
        receiptPath = $receiptFull; receiptSha256 = [string]$State.sourceReceipt.sha256; timings = $receipt.timings
    }
    if (($acquisition.result | ConvertTo-Json -Depth 20 -Compress) -cne
        ($expectedAcquisitionResult | ConvertTo-Json -Depth 20 -Compress)) {
        throw 'Schema 15 source acquisition result changed.'
    }
    if ([string]$receipt.sha256 -cne [string]$State.archive.sha256) { throw 'Preserved delivered source and claimed archive SHA-256 differ.' }
    if ([string]$State.sourceAcquisition.receiptSha256 -cne [string]$State.sourceReceipt.sha256) { throw 'sourceAcquisition receipt binding changed.' }
    if (-not $State.stageTimings.Contains('acquire-source') -or [string]$State.stageTimings['acquire-source'].artifactSha256 -cne [string]$State.sourceReceipt.sha256) {
        throw 'acquire-source stage timing is not bound to the source receipt.'
    }
    [string]$State.sourceReceipt.sha256
}

function Assert-SourceTupleIntegrity {
    param([Collections.IDictionary] $State)
    if (-not $State.Contains('sourceTuple') -or -not $State.sourceTuple) { throw 'Immutable Nexus Main file source tuple is missing.' }
    foreach ($field in @('path', 'sha256', 'contractSha256')) {
        if (-not $State.sourceTuple.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$State.sourceTuple[$field])) {
            throw "Source tuple $field is missing."
        }
    }
    $tuplePath = Assert-NoReparsePath -Path ([string]$State.sourceTuple.path) -Root ([string]$State.repositoryRoot) -Label 'Source tuple'
    if ($tuplePath -cne [IO.Path]::GetFullPath((Join-Path ([string]$State.runRoot) 'review-artifacts/source-tuple.json'))) {
        throw 'Source tuple is outside its fixed run-local path.'
    }
    if ((Get-FileSha256 -Path $tuplePath) -cne [string]$State.sourceTuple.sha256) { throw 'Source tuple SHA-256 changed.' }
    $tuple = Get-Content -LiteralPath $tuplePath -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$tuple.schemaVersion -ne 1 -or -not $tuple.contract) { throw 'Source tuple schema or contract is invalid.' }
    $contractSha256 = Get-ContractSha256 -Contract $tuple.contract
    if ($contractSha256 -cne [string]$tuple.contractSha256 -or $contractSha256 -cne [string]$State.sourceTuple.contractSha256) {
        throw 'Source tuple contract SHA-256 cannot be reconstructed.'
    }
    $contract = $tuple.contract
    foreach ($field in @('runId', 'acquisitionMethod', 'nexus', 'archive', 'sourceRequestSha256')) {
        if (-not $contract.Contains($field) -or $null -eq $contract[$field] -or
            ($field -ne 'nexus' -and $field -ne 'archive' -and [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $contract[$field])))) {
            throw "Source tuple contract field is missing: $field"
        }
    }
    if ([string]$contract.runId -cne [string]$State.runId -or
        [string]$contract.archive.fileName -cne [string]$State.archive.filename -or
        [int64]$contract.archive.size -ne [int64]$State.archive.size -or
        [string]$contract.archive.sha256 -cne [string]$State.archive.sha256) {
        throw 'Source tuple does not bind the run and claimed archive.'
    }
    if ([IO.Path]::GetExtension([string]$contract.archive.fileName).ToLowerInvariant() -cne '.zip') {
        throw 'Source tuple archive filename must retain its complete ZIP extension.'
    }
    $requestPath = Assert-NoReparsePath -Path ([string]$tuple.sourceRequestPath) -Root ([string]$State.repositoryRoot) -Label 'Source tuple request'
    if ($requestPath -cne [IO.Path]::GetFullPath((Join-Path ([string]$State.runRoot) 'review-artifacts/source-request.json')) -or
        (Get-FileSha256 -Path $requestPath) -cne [string]$contract.sourceRequestSha256) {
        throw 'Source tuple request path or SHA-256 changed.'
    }
    $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$request.schemaVersion -ne 2) { throw 'Claimed source request must use complete tuple schemaVersion 2.' }
    $fieldMap = [ordered]@{
        gameDomain = 'gameDomain'; modId = 'modId'; pageUrl = 'pageUrl'; pageVersion = 'pageVersion'
        pageUpdatedAt = 'pageUpdatedAt'; mainFileId = 'mainFileId'; version = 'mainFileVersion'
        mainFileUploadedAtUtc = 'mainFileUploadedAtUtc'; fileName = 'fileName'; officialSha256 = 'officialSha256'
    }
    foreach ($requestField in $fieldMap.Keys) {
        $nexusField = [string]$fieldMap[$requestField]
        $requestValue = if ($request.Contains($requestField)) { ConvertTo-InvariantString $request[$requestField] } else { $null }
        $tupleValue = if ($contract.nexus.Contains($nexusField)) { ConvertTo-InvariantString $contract.nexus[$nexusField] } else { $null }
        if ($requestField -ne 'officialSha256' -and [string]::IsNullOrWhiteSpace($requestValue)) { throw "Source request complete tuple field is missing: $requestField" }
        if ([string]$requestValue -cne [string]$tupleValue) { throw "Source tuple Nexus field differs from its request: $requestField" }
    }
    foreach ($timestampField in @('pageUpdatedAt', 'mainFileUploadedAtUtc')) {
        $timestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact([string]$request[$timestampField], 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$timestamp)) { throw "Source tuple timestamp is invalid: $timestampField" }
    }
    $pageUri = [Uri][string]$contract.nexus.pageUrl
    if (-not $pageUri.IsAbsoluteUri -or $pageUri.Scheme -cne 'https' -or $pageUri.Host -notin @('nexusmods.com', 'www.nexusmods.com') -or
        $pageUri.AbsolutePath.TrimEnd('/') -cne "/warhammer40kdarktide/mods/$($contract.nexus.modId)" -or $pageUri.Query -or $pageUri.Fragment -or $pageUri.UserInfo) {
        throw 'Source tuple Nexus page URL is not canonical.'
    }
    if ([int]$State.schemaVersion -ge 15) {
        if ([string]$contract.acquisitionMethod -cne "nexus-$($State.sourceReceipt.provider)" -or
            [string]$tuple.sourceReceiptPath -cne [string]$State.sourceReceipt.path -or
            [string]$contract.sourceReceiptSha256 -cne [string]$State.sourceReceipt.sha256) {
            throw 'Schema 15 source tuple acquisition method or receipt binding changed.'
        }
    }
    elseif ([string]$contract.acquisitionMethod -cne 'manual-queue' -or $null -ne $contract.sourceReceiptSha256 -or $null -ne $tuple.sourceReceiptPath) {
        throw 'Schema 14 source tuple must identify one manual queue acquisition without a receipt.'
    }

    $previewPath = Assert-NoReparsePath -Path ([string]$State.metadataPreview.path) -Root ([string]$State.repositoryRoot) -Label 'Metadata preview'
    if ((Get-FileSha256 -Path $previewPath) -cne [string]$State.metadataPreview.sha256) { throw 'Metadata preview SHA-256 changed.' }
    $preview = Get-Content -LiteralPath $previewPath -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$preview.schemaVersion -ne 2 -or [string]$preview.runId -cne [string]$State.runId -or
        [string]$preview.sourceTuplePath -cne $tuplePath -or [string]$preview.sourceTupleSha256 -cne [string]$State.sourceTuple.sha256 -or
        [string]$preview.sourceTupleContractSha256 -cne $contractSha256 -or
        [string]$State.metadataPreview.sourceTupleContractSha256 -cne $contractSha256) {
        throw 'Metadata preview is not bound to the immutable source tuple.'
    }
    $expectedFields = [ordered]@{
        nexusModId = [string]$contract.nexus.modId; nexusPageUrl = [string]$contract.nexus.pageUrl
        nexusPageVersion = [string]$contract.nexus.pageVersion; nexusPageUpdatedAt = [string]$contract.nexus.pageUpdatedAt
        nexusMainFileId = [string]$contract.nexus.mainFileId; nexusMainFileVersion = [string]$contract.nexus.mainFileVersion
        nexusMainFileUploadedAtUtc = [string]$contract.nexus.mainFileUploadedAtUtc; archiveFileName = [string]$contract.archive.fileName
        archiveSize = ConvertTo-InvariantString $contract.archive.size; archiveSha256 = [string]$contract.archive.sha256
        acquisitionMethod = [string]$contract.acquisitionMethod
    }
    foreach ($fieldName in $expectedFields.Keys) {
        if (-not $preview.sourceFields.Contains($fieldName) -or [string]$preview.sourceFields[$fieldName] -cne [string]$expectedFields[$fieldName]) {
            throw "Metadata preview source field differs from the tuple: $fieldName"
        }
    }
    $previewFiles = @($preview.files)
    if ($previewFiles.Count -ne @($State.metadataPaths).Count) { throw 'Metadata preview file count differs from metadataPaths.' }
    $completeSourceFieldNames = @(
        'nexusModId', 'nexusPageUrl', 'nexusPageVersion', 'nexusPageUpdatedAt', 'nexusMainFileId', 'nexusMainFileVersion',
        'nexusMainFileUploadedAtUtc', 'archiveFileName', 'archiveSize', 'archiveSha256', 'acquisitionMethod'
    )
    $requiredMetadataFields = [ordered]@{
        'README.md' = $completeSourceFieldNames
        ".hash/$($State.modSlug).hash" = $completeSourceFieldNames
    }
    $actualMetadataPaths = @($previewFiles | ForEach-Object { ([string]$_.path).Replace('\', '/') } | Sort-Object)
    $expectedMetadataPaths = @($requiredMetadataFields.Keys | Sort-Object)
    $matchesRequiredMetadataPaths = $actualMetadataPaths.Count -eq $expectedMetadataPaths.Count
    foreach ($expectedMetadataPath in $expectedMetadataPaths) {
        $pathMatches = @($actualMetadataPaths | Where-Object {
            $_.Equals($expectedMetadataPath, [StringComparison]::OrdinalIgnoreCase)
        })
        if ($pathMatches.Count -ne 1) { $matchesRequiredMetadataPaths = $false }
    }
    if (-not $matchesRequiredMetadataPaths) {
        throw 'Metadata preview requires exactly README.md and this MOD formal hash file.'
    }
    $previewInput = [ordered]@{
        schemaVersion = $preview.schemaVersion
        runId = $preview.runId
        sourceTuplePath = $preview.sourceTuplePath
        sourceTupleSha256 = $preview.sourceTupleSha256
        sourceTupleContractSha256 = $preview.sourceTupleContractSha256
        sourceFields = $preview.sourceFields
        files = $preview.files
    }
    $previewInputSha256 = Get-ContractSha256 -Contract $previewInput
    if ([string]$preview.inputContractSha256 -cne $previewInputSha256 -or
        [string]$State.metadataPreview.inputContractSha256 -cne $previewInputSha256) {
        throw 'metadata-preview-index input contract cannot be reconstructed.'
    }
    foreach ($file in $previewFiles) {
        $relative = ([string]$file.path).Replace('\', '/')
        if ($relative -cnotin @($State.metadataPaths | ForEach-Object { ([string]$_).Replace('\', '/') })) { throw 'Metadata preview contains a path outside metadataPaths.' }
        $full = Assert-NoReparsePath -Path (Join-Path ([string]$State.worktreePath) $relative) -Root ([string]$State.worktreePath) -Label 'Metadata preview source file'
        $bytes = Read-FileBytesWithHeartbeat -Path $full
        if ((Get-Sha256Bytes -Bytes $bytes) -cne [string]$file.sha256 -or $bytes.Length -ne [int64]$file.size) { throw 'Metadata preview source file bytes changed.' }
        foreach ($indexedField in @('indexedSha256', 'indexedSize', 'blobOid', 'transform')) {
            if (-not $file.Contains($indexedField) -or [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $file[$indexedField]))) {
                throw "metadata-preview-index field is missing: $relative / $indexedField"
            }
        }
        $fObject = "$([string]$State.evidenceChain.fOid):$relative"
        $fBlobOid = (Invoke-GitCheck -WorkingDirectory ([string]$State.worktreePath) -Arguments @('rev-parse', $fObject)).output.Trim()
        $fBytes = Get-GitBlobBytes -WorkingDirectory ([string]$State.worktreePath) -Object $fObject
        $fSha256 = Get-Sha256Bytes -Bytes $fBytes
        $expectedTransform = if ((Get-Sha256Bytes -Bytes $bytes) -ceq $fSha256) { 'none' }
            elseif (Test-CrlfNormalizationOnly -RawBytes $bytes -IndexedBytes $fBytes) { 'crlf-to-lf' }
            else { throw "metadata-preview-index F blob differs beyond CRLF-to-LF: $relative" }
        if ([string]$file.indexedSha256 -cne $fSha256 -or [int64]$file.indexedSize -ne $fBytes.LongLength -or
            [string]$file.blobOid -cne $fBlobOid -or [string]$file.transform -cne $expectedTransform) {
            throw "metadata-preview-index does not match the immutable F blob: $relative"
        }
        $textValue = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        foreach ($fieldName in $expectedFields.Keys) {
            $expectedMatch = Test-MetadataSourceFieldMatch -RelativePath $relative -Text $textValue `
                -FieldName $fieldName -FieldValue ([string]$expectedFields[$fieldName]) `
                -NexusPageUrl ([string]$expectedFields.nexusPageUrl)
            if (-not $file.sourceFieldMatches.Contains($fieldName) -or [bool]$file.sourceFieldMatches[$fieldName] -ne $expectedMatch) {
                throw "Metadata preview field evidence is inconsistent: $relative / $fieldName"
            }
        }
        foreach ($requiredField in @($requiredMetadataFields[$relative])) {
            if (-not [bool]$file.sourceFieldMatches[$requiredField]) {
                throw "Metadata file is missing or mixes an immutable source tuple field: $relative / $requiredField"
            }
        }
    }
    $contractSha256
}

function Assert-CheckpointReasonIntegrity {
    param([Collections.IDictionary] $State, [Collections.IDictionary] $Chain, [string] $Worktree)
    if ([string]$State.localizationMode -cne 'none' -and [string]$State.localizationMode -cne 'zh-tw') {
        throw 'Checkpoint reason localization mode must be exactly none or zh-tw.'
    }
    $targetPaths = @($State.evidenceTargetPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $targetJson = ConvertTo-Json -InputObject @($targetPaths) -Compress
    $targetSha = Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($targetJson))
    if ($targetSha -cne [string]$State.evidenceTargetPathsSha256) { throw 'Checkpoint reason target path contract cannot be reconstructed.' }
    $manifestPath = Assert-NoReparsePath -Path ([string]$State.localizationManifestPath) -Root ([string]$State.repositoryRoot) -Label 'Checkpoint localization manifest'
    $manifestSha = Get-FileSha256 -Path $manifestPath
    if ($manifestSha -cne [string]$State.stageTimings.localization.artifactSha256) { throw 'Checkpoint reason localization manifest changed.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    $expectedManifestMode = if ([int]$State.schemaVersion -ge 15 -and [string]$State.localizationMode -ceq 'zh-tw') {
        'zh-tw-workset'
    }
    else { [string]$State.localizationMode }
    if ([string]$manifest.mode -cne $expectedManifestMode) { throw 'Checkpoint reason localization mode contradicts its manifest.' }
    foreach ($checkpoint in @('C2', 'C3')) {
        $prefix = $checkpoint.ToLowerInvariant()
        $reason = $Chain["${prefix}Reason"]
        if ($reason -isnot [Collections.IDictionary]) { throw "$checkpoint reason must be a non-empty structured object." }
        foreach ($field in @('schemaVersion', 'code', 'disposition', 'localizationMode', 'targetPathsSha256', 'targetPathCount', 'localizationManifestSha256', 'contractSha256')) {
            if (-not $reason.Contains($field) -or [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $reason[$field]))) { throw "$checkpoint reason is missing $field." }
        }
        $notApplicable = [string]$State.localizationMode -ceq 'none'
        if ($notApplicable) {
            if ([string]$Chain["${prefix}Status"] -cne 'not-applicable' -or $Chain["${prefix}Oid"] -or $Chain["${prefix}TreeOid"]) {
                throw "$checkpoint not-applicable reason contradicts checkpoint state."
            }
            $parentTree = $null; $tree = $null; $keep = $true; $code = 'localization-not-applicable'
        }
        else {
            if ([string]$Chain["${prefix}Status"] -cne 'committed') { throw "$checkpoint active localization checkpoint is not committed." }
            $parentTree = (Invoke-GitCheck -WorkingDirectory $Worktree -Arguments @('rev-parse', "$($Chain["${prefix}Oid"])^1^{tree}")).output.Trim()
            $tree = (Invoke-GitCheck -WorkingDirectory $Worktree -Arguments @('rev-parse', "$($Chain["${prefix}Oid"])^{tree}")).output.Trim()
            $keep = $parentTree -ceq $tree
            $code = if ($checkpoint -ceq 'C2' -and $keep) { 'upstream-localization-unchanged' }
                elseif ($checkpoint -ceq 'C2') { 'upstream-localization-changed' }
                elseif ($keep) { 'approved-localization-unchanged' }
                else { 'approved-localization-changed' }
        }
        $disposition = if ($keep) { 'KEEP' } else { 'APPLY' }
        $contract = [ordered]@{
            checkpoint = $checkpoint; code = $code; disposition = $disposition; localizationMode = [string]$State.localizationMode
            parentTreeOid = $parentTree; treeOid = $tree; targetPathsSha256 = $targetSha; targetPathCount = $targetPaths.Count
            localizationManifestSha256 = $manifestSha
        }
        if ([int]$reason.schemaVersion -ne 1 -or [string]$reason.code -cne $code -or [string]$reason.disposition -cne $disposition -or
            [string]$reason.localizationMode -cne [string]$State.localizationMode -or [string]$reason.parentTreeOid -cne [string]$parentTree -or
            [string]$reason.treeOid -cne [string]$tree -or [string]$reason.targetPathsSha256 -cne $targetSha -or
            [int]$reason.targetPathCount -ne $targetPaths.Count -or [string]$reason.localizationManifestSha256 -cne $manifestSha -or
            [string]$reason.contractSha256 -cne (Get-ContractSha256 -Contract $contract)) {
            throw "$checkpoint reason is unknown, blank, contradictory, or not bound to independently revalidated evidence."
        }
    }
    'C2/C3 structured reasons independently reconstructed'
}

function Assert-EvidenceGenerationReceiptIntegrity {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][Collections.IDictionary] $Chain,
        [Parameter(Mandatory)][string] $Worktree
    )
    $receiptPath = Assert-NoReparsePath -Path ([string]$State.evidenceReceipt.path) -Root ([string]$State.repositoryRoot) -Label 'Evidence generation receipt'
    if ((Get-FileSha256 -Path $receiptPath) -cne [string]$State.evidenceReceipt.sha256) {
        throw 'evidence-generation-receipt SHA-256 changed.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
    $parameterVersion = 'full-index-binary-no-renames-v2'
    if ([int]$receipt.schemaVersion -ne 2 -or [string]$receipt.runId -cne [string]$State.runId -or
        [int]$receipt.generation -ne [int]$State.evidenceGeneration -or [string]$receipt.executionMode -cne 'bounded-parallel' -or
        [int]$receipt.maxConcurrency -ne 4 -or [string]$receipt.parameterVersion -cne $parameterVersion) {
        throw 'evidence-generation-receipt batch identity or parameter contract changed.'
    }
    $tuple = [ordered]@{
        generation = $State.evidenceGeneration
        chain = $Chain
        targetPathsSha256 = $State.evidenceTargetPathsSha256
        archiveSha256 = $State.archive.sha256
        artifactSha256 = [ordered]@{
            extraction = $State.extractionManifest.sha256
            rawInstall = $State.rawInstallManifest.sha256
            install = $State.installManifest.sha256
            candidateTree = $State.candidateTreeManifest.sha256
            gitIndexNormalization = $State.gitIndexNormalization.sha256
            metadataPreview = $State.metadataPreview.sha256
            securityOverride = if ($State.Contains('securityOverrideReceipt') -and $State.securityOverrideReceipt) { $State.securityOverrideReceipt.sha256 } else { $null }
            precommitSecurity = $State.securityPrecommitValidation.sha256
        }
        parameterVersion = $parameterVersion
    }
    if ([string]$receipt.inputTupleSha256 -cne (Get-ContractSha256 -Contract $tuple) -or
        (Get-ContractSha256 -Contract $receipt.evidenceChain) -cne (Get-ContractSha256 -Contract $Chain)) {
        throw 'evidence-generation-receipt fixed input tuple cannot be independently reconstructed.'
    }
    $gitVersion = (Invoke-GitCheck -WorkingDirectory $Worktree -Arguments @('--version')).output
    if ([string]$receipt.gitVersion -cne $gitVersion) { throw 'evidence-generation-receipt Git version changed.' }
    $batchStarted = [DateTimeOffset]::MinValue
    $batchCompleted = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$receipt.batchStartedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$batchStarted) -or
        -not [DateTimeOffset]::TryParse([string]$receipt.batchCompletedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$batchCompleted) -or
        $batchCompleted -lt $batchStarted) {
        throw 'evidence-generation-receipt batch timing is invalid.'
    }

    if ($receipt.artifacts.Count -ne $State.evidenceDiffs.Count) { throw 'evidence-generation-receipt artifact map differs from state.' }
    foreach ($name in $State.evidenceDiffs.Keys) {
        if (-not $receipt.artifacts.Contains($name)) { throw "evidence-generation-receipt artifact is missing: $name" }
        $expectedArtifact = $State.evidenceDiffs[$name]
        $actualArtifact = $receipt.artifacts[$name]
        if ($expectedArtifact.Contains('status') -and [string]$expectedArtifact.status -ceq 'not-applicable') {
            if ([string]$actualArtifact.status -cne 'not-applicable') { throw "evidence-generation-receipt not-applicable artifact changed: $name" }
            continue
        }
        if ([string]$actualArtifact.path -cne [string]$expectedArtifact.path -or
            [int64]$actualArtifact.size -ne [int64]$expectedArtifact.size -or
            [string]$actualArtifact.sha256 -cne [string]$expectedArtifact.sha256) {
            throw "evidence-generation-receipt artifact tuple changed: $name"
        }
    }

    $expectedTasks = [ordered]@{
        c0C1Diff = [ordered]@{ baseOid = $Chain.c0Oid; headOid = $Chain.c1Oid; treeOid = $Chain.c1TreeOid; artifact = $State.evidenceDiffs.c0C1Diff }
        c0C1NameStatus = [ordered]@{ baseOid = $Chain.c0Oid; headOid = $Chain.c1Oid; treeOid = $Chain.c1TreeOid; artifact = $State.evidenceDiffs.c0C1NameStatus }
        c1ParentNameStatus = [ordered]@{ baseOid = $Chain.c1ParentOid; headOid = $Chain.c1Oid; treeOid = $Chain.c1TreeOid; artifact = $State.evidenceDiffs.c1ParentNameStatus }
    }
    if ([string]$State.localizationMode -ceq 'zh-tw') {
        $expectedTasks.c1C2Diff = [ordered]@{ baseOid = $Chain.c1Oid; headOid = $Chain.c2Oid; treeOid = $Chain.c2TreeOid; artifact = $State.evidenceDiffs.c1C2Diff }
        $expectedTasks.c1C2NameStatus = [ordered]@{ baseOid = $Chain.c1Oid; headOid = $Chain.c2Oid; treeOid = $Chain.c2TreeOid; artifact = $State.evidenceDiffs.c1C2NameStatus }
        $expectedTasks.c2C3Diff = [ordered]@{ baseOid = $Chain.c2Oid; headOid = $Chain.c3Oid; treeOid = $Chain.c3TreeOid; artifact = $State.evidenceDiffs.c2C3Diff }
        $expectedTasks.c2C3NameStatus = [ordered]@{ baseOid = $Chain.c2Oid; headOid = $Chain.c3Oid; treeOid = $Chain.c3TreeOid; artifact = $State.evidenceDiffs.c2C3NameStatus }
        $expectedTasks.c2ParentNameStatus = [ordered]@{ baseOid = $Chain.c2ParentOid; headOid = $Chain.c2Oid; treeOid = $Chain.c2TreeOid; artifact = $State.evidenceDiffs.c2ParentNameStatus }
        $expectedTasks.c3ParentNameStatus = [ordered]@{ baseOid = $Chain.c3ParentOid; headOid = $Chain.c3Oid; treeOid = $Chain.c3TreeOid; artifact = $State.evidenceDiffs.c3ParentNameStatus }
        if ([string]$Chain.fOid -cne [string]$Chain.c3Oid) {
            $expectedTasks.c3FDiff = [ordered]@{ baseOid = $Chain.c3Oid; headOid = $Chain.fOid; treeOid = $Chain.fTreeOid; artifact = $State.evidenceDiffs.c3FDiff }
            $expectedTasks.c3FNameStatus = [ordered]@{ baseOid = $Chain.c3Oid; headOid = $Chain.fOid; treeOid = $Chain.fTreeOid; artifact = $State.evidenceDiffs.c3FNameStatus }
        }
    }
    $expectedTasks.c0FDiff = [ordered]@{ baseOid = $Chain.c0Oid; headOid = $Chain.fOid; treeOid = $Chain.fTreeOid; artifact = $State.evidenceDiffs.c0FDiff }
    $expectedTasks.c0FNameStatus = [ordered]@{ baseOid = $Chain.c0Oid; headOid = $Chain.fOid; treeOid = $Chain.fTreeOid; artifact = $State.evidenceDiffs.c0FNameStatus }
    $expectedTasks.candidateTreeManifest = [ordered]@{ baseOid = $Chain.fOid; headOid = $Chain.fOid; treeOid = $Chain.fTreeOid; artifact = $State.candidateTreeManifest }
    if (@($receipt.tasks).Count -ne $expectedTasks.Count) { throw 'evidence-generation-receipt task count differs from the fixed generation.' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($task in @($receipt.tasks)) {
        $name = [string]$task.name
        if (-not $seen.Add($name) -or -not $expectedTasks.Contains($name)) { throw "evidence-generation-receipt task is duplicate or unknown: $name" }
        $expected = $expectedTasks[$name]
        if ([string]$task.baseOid -cne [string]$expected.baseOid -or [string]$task.headOid -cne [string]$expected.headOid -or
            [string]$task.treeOid -cne [string]$expected.treeOid -or [string]$task.artifact.path -cne [string]$expected.artifact.path -or
            [int64]$task.artifact.size -ne [int64]$expected.artifact.size -or [string]$task.artifact.sha256 -cne [string]$expected.artifact.sha256) {
            throw "evidence-generation-receipt task tuple changed: $name"
        }
        $taskStarted = [DateTimeOffset]::MinValue
        $taskCompleted = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$task.startedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$taskStarted) -or
            -not [DateTimeOffset]::TryParse([string]$task.completedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$taskCompleted) -or
            $taskStarted -lt $batchStarted -or $taskCompleted -gt $batchCompleted -or $taskCompleted -lt $taskStarted) {
            throw "evidence-generation-receipt task timing is invalid: $name"
        }
        $artifactPath = Assert-NoReparsePath -Path ([string]$task.artifact.path) -Root ([string]$State.artifactsRoot) -Label "Evidence task $name"
        if ((Get-Item -LiteralPath $artifactPath).Length -ne [int64]$task.artifact.size -or
            (Get-FileSha256 -Path $artifactPath) -cne [string]$task.artifact.sha256) {
            throw "evidence-generation-receipt task artifact changed: $name"
        }
        $actualTree = (Invoke-GitCheck -WorkingDirectory $Worktree -Arguments @('rev-parse', "$([string]$task.headOid)^{tree}")).output.Trim()
        if ($actualTree -cne [string]$task.treeOid) { throw "evidence-generation-receipt task Git tree changed: $name" }
    }
    $verification = $receipt.coordinatorVerification
    if (-not $verification -or [string]$verification.result -cne 'passed' -or
        [int]$verification.artifactCount -ne $expectedTasks.Count -or
        -not $verification.changedPathAllowlists -or [string]$verification.changedPathAllowlists.result -cne 'passed' -or
        -not $expectedTasks.Contains([string]$verification.spotCheckTask)) {
        throw 'evidence-generation-receipt coordinator verification is incomplete.'
    }
    $changedPathVerification = Get-EvidenceChangedPathAllowlistVerification -State $State -Chain $Chain -Worktree $Worktree
    if ([string]$verification.changedPathAllowlists.contractSha256 -cne [string]$changedPathVerification.contractSha256 -or
        (Get-ContractSha256 -Contract ([ordered]@{ records = @($verification.changedPathAllowlists.records) })) -cne
        (Get-ContractSha256 -Contract ([ordered]@{ records = @($changedPathVerification.records) }))) {
        throw 'evidence-generation-receipt coordinator changed-path allowlists changed.'
    }
    $spotExpected = $expectedTasks[[string]$verification.spotCheckTask]
    $spotActualTree = (Invoke-GitCheck -WorkingDirectory $Worktree -Arguments @('rev-parse', "$([string]$verification.spotCheckHeadOid)^{tree}")).output.Trim()
    if ([string]$verification.spotCheckHeadOid -cne [string]$spotExpected.headOid -or
        [string]$verification.spotCheckTreeOid -cne [string]$spotExpected.treeOid -or $spotActualTree -cne [string]$spotExpected.treeOid) {
        throw 'evidence-generation-receipt coordinator Git object spot-check changed.'
    }
    [string]$receipt.inputTupleSha256
}

function Assert-ReferenceIntegrity {
    param([Collections.IDictionary] $State)
    if (-not $State.Contains('workflowSourcePinPath') -or [string]::IsNullOrWhiteSpace([string]$State.workflowSourcePinPath)) {
        if ([int]$State.schemaVersion -ne 14) { throw 'Schema 15 state is missing its immutable Skill source pin.' }
        $legacyIntegrity = & (Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1') -HeartbeatAction $HeartbeatAction -PassThru
        if ($legacyIntegrity.result -cne 'passed' -or [string]$legacyIntegrity.authoringSourceCommit -cne [string]$State.workflowCommitOid -or
            [string]$State.workflowPath -cne [string]$legacyIntegrity.workflow.originalPath -or
            [string]$State.workflowBlobOid -cne [string]$legacyIntegrity.workflow.gitBlobOid -or
            [string]$State.workflowSha256 -cne [string]$legacyIntegrity.workflow.sha256 -or
            [string]$State.reviewBaselinePath -cne [string]$legacyIntegrity.reviewBaseline.originalPath -or
            [string]$State.reviewBaselineBlobOid -cne [string]$legacyIntegrity.reviewBaseline.gitBlobOid -or
            [string]$State.reviewBaselineSha256 -cne [string]$legacyIntegrity.reviewBaseline.sha256) {
            throw 'Legacy Schema 14 authoring reference tuple changed.'
        }
        return [string]$State.workflowSha256
    }
    foreach ($field in @('workflowSourcePinPath', 'workflowSourcePinSha256', 'workflowSourceRepository', 'workflowSourceContentSha256')) {
        if (-not $State.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$State[$field])) { throw "Recorded Skill source pin field is missing: $field" }
    }
    if ((Get-FileSha256 -Path ([string]$State.workflowSourcePinPath)) -cne [string]$State.workflowSourcePinSha256) {
        throw 'Recorded Skill source pin bytes changed.'
    }
    $integrity = & (Join-Path $PSScriptRoot 'Test-ReferenceIntegrity.ps1') `
        -SkillSourcePinPath ([string]$State.workflowSourcePinPath) -HeartbeatAction $HeartbeatAction -PassThru
    if ($integrity.result -cne 'passed' -or -not $integrity.skillSourcePin -or
        [string]$integrity.skillSourcePin.pinSha256 -cne [string]$State.workflowSourcePinSha256 -or
        [string]$integrity.skillSourcePin.repository -cne [string]$State.workflowSourceRepository -or
        [string]$integrity.skillSourcePin.requestedRef -cne [string]$State.workflowRef -or
        [string]$integrity.skillSourcePin.resolvedCommit -cne [string]$State.workflowCommitOid -or
        [string]$integrity.skillSourcePin.contentSha256 -cne [string]$State.workflowSourceContentSha256) {
        throw 'Recorded immutable Skill source tuple no longer matches the verified package.'
    }
    foreach ($binding in @(
        [ordered]@{ name = 'Workflow'; expectedPath = $State.workflowPath; expectedBlob = $State.workflowBlobOid; expectedSha = $State.workflowSha256; expectedPackageSha = $State.workflowPackageSha256; actual = $integrity.workflow },
        [ordered]@{ name = 'Review Baseline'; expectedPath = $State.reviewBaselinePath; expectedBlob = $State.reviewBaselineBlobOid; expectedSha = $State.reviewBaselineSha256; expectedPackageSha = $State.reviewBaselinePackageSha256; actual = $integrity.reviewBaseline }
    )) {
        if ([string]$binding.expectedPath -cne [string]$binding.actual.path -or
            [string]$binding.expectedBlob -cne [string]$binding.actual.gitBlobOid -or
            [string]$binding.expectedPackageSha -cne [string]$binding.actual.packageSha256 -or
            [string]$binding.expectedSha -cne [string]$binding.actual.sha256) {
            throw "$($binding.name) reference binding changed."
        }
    }
    $references = @($State.referenceSources)
    $expectedRoles = if ([int]$State.schemaVersion -ge 15) { @('workflow', 'review-baseline', 'package-binding', 'translation-quality', 'skill', 'schema-15-extension') }
        else { @('workflow', 'review-baseline', 'package-binding', 'translation-quality', 'skill') }
    if ($references.Count -ne $expectedRoles.Count) { throw 'Recorded reference_sources count changed.' }
    foreach ($role in $expectedRoles) {
        $roleReferences = @($references | Where-Object { [string]$_.role -ceq $role })
        if ($roleReferences.Count -ne 1 -or [string]$roleReferences[0].sourceCommit -cne [string]$State.workflowCommitOid) {
            throw "Recorded reference_sources role is missing, duplicated, or pinned to another commit: $role"
        }
        $pinEntries = @($integrity.skillSourcePin.files | Where-Object { [string]$_.repositoryPath -ceq [string]$roleReferences[0].path })
        if ($pinEntries.Count -ne 1 -or [string]$roleReferences[0].blobOid -cne [string]$pinEntries[0].blobOid -or
            [int64]$roleReferences[0].size -ne [int64]$pinEntries[0].size -or [string]$roleReferences[0].sha256 -cne [string]$pinEntries[0].sha256) {
            throw "Recorded reference_sources evidence differs from the source pin: $role"
        }
    }
    $translationReference = @($references | Where-Object { [string]$_.role -ceq 'translation-quality' })[0]
    if ([string]$State.translationQualityPath -cne [string]$translationReference.path -or
        [string]$State.translationQualityBlobOid -cne [string]$translationReference.blobOid -or
        [string]$State.translationQualitySha256 -cne [string]$translationReference.sha256) {
        throw 'Translation-quality reference binding changed.'
    }
    if ([int]$State.schemaVersion -ge 15) {
        if ([string]$State.schema15Path -cne [string]$integrity.schema15.path -or
            [string]$State.schema15BlobOid -cne [string]$integrity.schema15.gitBlobOid -or
            [string]$State.schema15Sha256 -cne [string]$integrity.schema15.sha256) {
            throw 'Schema 15 extension reference binding changed.'
        }
        return [string]$State.schema15Sha256
    }
    [string]$State.workflowSha256
}

function Write-AtomicJson {
    param([string] $Path, $Value)
    Invoke-Heartbeat
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ('.validation-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
    [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
}

function Invoke-GitCheck {
    param([string] $WorkingDirectory, [string[]] $Arguments, [switch] $AllowFailure)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory) + $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start Git validation.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit(1000)) { Invoke-Heartbeat }
    $output = $stdoutTask.Result.TrimEnd()
    $warning = $stderrTask.Result.TrimEnd()
    $exitCode = $process.ExitCode
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "git $($Arguments -join ' ') failed: $warning $output"
    }
    [ordered]@{ exitCode = $exitCode; output = $output; warning = $warning }
}

function Invoke-GhCheck {
    param([string] $WorkingDirectory, [string[]] $Arguments, [switch] $AllowFailure)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'gh'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.WorkingDirectory = [IO.Path]::GetFullPath($WorkingDirectory)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start GitHub CLI validation.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    while (-not $process.WaitForExit(1000)) { Invoke-Heartbeat }
    $result = [ordered]@{ exitCode = $process.ExitCode; output = $stdoutTask.Result.TrimEnd(); warning = $stderrTask.Result.TrimEnd() }
    if ($result.exitCode -ne 0 -and -not $AllowFailure) { throw "GitHub CLI validation failed: $($result.warning) $($result.output)" }
    $result
}

function Get-GitBlobBytes {
    param([string] $WorkingDirectory, [string] $Object)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = 'git'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-C', $WorkingDirectory, 'cat-file', 'blob', $Object)) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Unable to start independent Git blob validation.' }
    $memory = [IO.MemoryStream]::new()
    try {
        $copyTask = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $errorTask = $process.StandardError.ReadToEndAsync()
        while (-not ($process.HasExited -and $copyTask.IsCompleted -and $errorTask.IsCompleted)) {
            if (-not $process.HasExited) { $null = $process.WaitForExit(1000) }
            else { [Threading.Tasks.Task]::Delay(50).Wait() }
            Invoke-Heartbeat
        }
        $null = $copyTask.GetAwaiter().GetResult()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Unable to read Git blob: $errorText" }
        $memory.ToArray()
    }
    finally { $memory.Dispose(); $process.Dispose() }
}

function Test-CrlfNormalizationOnly {
    param([byte[]] $RawBytes, [byte[]] $IndexedBytes)
    $normalized = [IO.MemoryStream]::new()
    try {
        for ($index = 0; $index -lt $RawBytes.LongLength; $index++) {
            if (($index -band 0xFFFFF) -eq 0) { Invoke-Heartbeat }
            if ($RawBytes[$index] -eq 13 -and ($index + 1) -lt $RawBytes.LongLength -and $RawBytes[$index + 1] -eq 10) { continue }
            $normalized.WriteByte($RawBytes[$index])
        }
        $candidate = $normalized.ToArray()
        if ($candidate.LongLength -ne $IndexedBytes.LongLength) { return $false }
        for ($index = 0; $index -lt $candidate.LongLength; $index++) {
            if (($index -band 0xFFFFF) -eq 0) { Invoke-Heartbeat }
            if ($candidate[$index] -ne $IndexedBytes[$index]) { return $false }
        }
        $true
    }
    finally { $normalized.Dispose() }
}

function Get-DiffCheckSignatures {
    param([string] $Output)
    @(
        $Output -split "`r?`n" |
            Where-Object { $_ -match '^.+:\d+: (?:trailing whitespace|new blank line at EOF)\.?$' } |
            ForEach-Object { $_.TrimEnd('.') } |
            Sort-Object -Unique
    )
}

function Get-ChangedPaths {
    param([string] $WorkingDirectory, [string] $BaseOid, [string] $HeadOid)
    @(
        (Invoke-GitCheck -WorkingDirectory $WorkingDirectory -Arguments @('-c', 'core.quotePath=false', 'diff', '--name-only', '--no-renames', "$BaseOid..$HeadOid")).output -split "`r?`n" |
            Where-Object { $_ }
    )
}

function Get-EvidenceChangedPathAllowlistVerification {
    param([Collections.IDictionary] $State, [Collections.IDictionary] $Chain, [string] $Worktree)
    $targets = @($State.evidenceTargetPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $metadata = @($State.metadataPaths | ForEach-Object { ([string]$_).Replace('\', '/') } | Sort-Object -Unique)
    $ranges = @(
        [ordered]@{ name = 'c1-parent'; baseOid = $Chain.c1ParentOid; headOid = $Chain.c1Oid; allowlist = 'mod-non-target' },
        [ordered]@{ name = 'c0-c1'; baseOid = $Chain.c0Oid; headOid = $Chain.c1Oid; allowlist = 'mod-non-target' }
    )
    if ([string]$State.localizationMode -ceq 'zh-tw') {
        $ranges += @(
            [ordered]@{ name = 'c2-parent'; baseOid = $Chain.c2ParentOid; headOid = $Chain.c2Oid; allowlist = 'target-only' },
            [ordered]@{ name = 'c1-c2'; baseOid = $Chain.c1Oid; headOid = $Chain.c2Oid; allowlist = 'target-only' },
            [ordered]@{ name = 'c3-parent'; baseOid = $Chain.c3ParentOid; headOid = $Chain.c3Oid; allowlist = 'target-only' },
            [ordered]@{ name = 'c2-c3'; baseOid = $Chain.c2Oid; headOid = $Chain.c3Oid; allowlist = 'target-only' }
        )
        if ([string]$Chain.fOid -cne [string]$Chain.c3Oid) {
            $ranges += [ordered]@{ name = 'c3-f'; baseOid = $Chain.c3Oid; headOid = $Chain.fOid; allowlist = 'metadata-only' }
        }
    }
    $ranges += [ordered]@{ name = 'c0-f'; baseOid = $Chain.c0Oid; headOid = $Chain.fOid; allowlist = 'mod-or-metadata' }
    $records = @()
    foreach ($range in $ranges) {
        $paths = @(Get-ChangedPaths -WorkingDirectory $Worktree -BaseOid ([string]$range.baseOid) -HeadOid ([string]$range.headOid) | Sort-Object -Unique)
        foreach ($path in $paths) {
            $inMod = $path.StartsWith(([string]$State.modRelativePath + '/'), [StringComparison]::Ordinal)
            $allowed = switch ([string]$range.allowlist) {
                'mod-non-target' { $inMod -and $path -cnotin $targets }
                'target-only' { $path -cin $targets }
                'metadata-only' { $path -cin $metadata }
                'mod-or-metadata' { $inMod -or $path -cin $metadata }
                default { $false }
            }
            if (-not $allowed) { throw "Independent coordinator allowlist reconstruction rejected $($range.name): $path" }
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
    [ordered]@{ records = $records; contractSha256 = Get-ContractSha256 -Contract $contract }
}

function Test-ApprovedSpanCandidate {
    param([byte[]] $Indexed, [byte[]] $Merged, [object[]] $ApprovedSpans)
    $ordered = @($ApprovedSpans | Sort-Object { [int64]$_.startByte })
    $indexedCursor = [int64]0
    $mergedCursor = [int64]0
    foreach ($span in $ordered) {
        $start = [int64]$span.startByte
        $length = [int64]$span.length
        if ($start -lt $indexedCursor -or $length -lt 0 -or ($start + $length) -gt $Indexed.LongLength) {
            throw 'approvedSpans overlap or escape indexed localization bytes.'
        }
        $unchangedLength = $start - $indexedCursor
        for ($offset = [int64]0; $offset -lt $unchangedLength; $offset++) {
            if (($offset -band 0xFFFFF) -eq 0) { Invoke-Heartbeat }
            if ($Indexed[$indexedCursor + $offset] -ne $Merged[$mergedCursor + $offset]) {
                throw 'Merged candidate changed bytes outside approved localization spans.'
            }
        }
        $mergedCursor += $unchangedLength
        $oldBytes = [byte[]]::new($length)
        Copy-ByteRangeWithHeartbeat -Source $Indexed -SourceOffset $start `
            -Destination $oldBytes -DestinationOffset 0 -Count $length
        if ((Get-Sha256Bytes -Bytes $oldBytes) -ne [string]$span.oldSha256) {
            throw 'Approved localization oldSha256 does not match indexed bytes.'
        }
        $replacement = [Convert]::FromBase64String([string]$span.replacementBase64)
        if (($mergedCursor + $replacement.LongLength) -gt $Merged.LongLength) { throw 'Merged candidate truncates an approved replacement.' }
        for ($offset = [int64]0; $offset -lt $replacement.LongLength; $offset++) {
            if (($offset -band 0xFFFFF) -eq 0) { Invoke-Heartbeat }
            if ($Merged[$mergedCursor + $offset] -ne $replacement[$offset]) { throw 'Merged candidate replacement bytes differ from the approval plan.' }
        }
        $indexedCursor = $start + $length
        $mergedCursor += $replacement.LongLength
    }
    $remaining = $Indexed.LongLength - $indexedCursor
    if (($mergedCursor + $remaining) -ne $Merged.LongLength) { throw 'Merged candidate length differs outside approved localization spans.' }
    for ($offset = [int64]0; $offset -lt $remaining; $offset++) {
        if (($offset -band 0xFFFFF) -eq 0) { Invoke-Heartbeat }
        if ($Indexed[$indexedCursor + $offset] -ne $Merged[$mergedCursor + $offset]) {
            throw 'Merged candidate changed bytes outside approved localization spans.'
        }
    }
    $true
}

function Test-LocalizationWorksetCandidate {
    param([byte[]] $NewBytes, [byte[]] $MergedBytes, [object[]] $Edits)
    $spans = @($Edits | ForEach-Object {
        [ordered]@{
            startByte = [int64]$_.startByte
            length = [int64]$_.lengthByte
            oldSha256 = [string]$_.oldSha256
            replacementBase64 = [string]$_.replacementBase64
        }
    })
    try { $null = Test-ApprovedSpanCandidate -Indexed $NewBytes -Merged $MergedBytes -ApprovedSpans $spans }
    catch { throw "Candidate changed bytes outside approved localization workset edits. $($_.Exception.Message)" }
    $true
}

function Get-ImmutableWorksetContractSha256 {
    param($Workset)
    $unitContracts = @($Workset.units | ForEach-Object {
        [ordered]@{
            unitId = $_.unitId; sourceId = $_.sourceId; containerPath = $_.containerPath
            key = $_.key; occurrence = $_.occurrence; old = $_.old; new = $_.new
            changeType = $_.changeType; action = $_.action; blockedReason = $_.blockedReason
        }
    })
    $contract = [ordered]@{
        schemaVersion = $Workset.schemaVersion
        workflowSchemaVersion = $Workset.workflowSchemaVersion
        generatorVersion = $Workset.generatorVersion
        baseOid = $Workset.baseOid
        sourceId = $Workset.sourceId
        modRelativePath = $Workset.modRelativePath
        old = $Workset.old
        new = $Workset.new
        counts = $Workset.counts
        units = $unitContracts
    }
    Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false, $true).GetBytes(($contract | ConvertTo-Json -Depth 40 -Compress)))
}

function Assert-PrBodyEvidenceSummary {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $State,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Body
    )
    $normalized = $Body.Replace("`r`n", "`n")
    $chain = $State.evidenceChain
    $requiredFragments = [Collections.Generic.List[string]]::new()
    foreach ($fragment in @(
        "- Run: $($State.runId)",
        "- HEAD/F: $($chain.fOid)",
        "- C0: $($chain.c0Oid)",
        "- C1: $($chain.c1Oid)",
        "- C2: $($chain.c2Oid) ($($chain.c2Status): $($chain.c2Reason.code), $($chain.c2Reason.disposition))",
        "- C3: $($chain.c3Oid) ($($chain.c3Status): $($chain.c3Reason.code), $($chain.c3Reason.disposition))",
        "- Trees C0/C1/C2/C3/F: $($chain.c0TreeOid) / $($chain.c1TreeOid) / $($chain.c2TreeOid) / $($chain.c3TreeOid) / $($chain.fTreeOid)",
        "- Parent-tree Gate: C1^=$($chain.c1ParentTreeOid); C2^=$($chain.c2ParentTreeOid); C3^=$($chain.c3ParentTreeOid)",
        "- C0..C1 diff/name-status SHA-256: $($State.evidenceDiffs.c0C1Diff.sha256) / $($State.evidenceDiffs.c0C1NameStatus.sha256)",
        "- C1..C2 diff/name-status SHA-256: $($State.evidenceDiffs.c1C2Diff.sha256) / $($State.evidenceDiffs.c1C2NameStatus.sha256)",
        "- C2..C3 diff/name-status SHA-256: $($State.evidenceDiffs.c2C3Diff.sha256) / $($State.evidenceDiffs.c2C3NameStatus.sha256)",
        "- C0..F diff/name-status SHA-256: $($State.evidenceDiffs.c0FDiff.sha256) / $($State.evidenceDiffs.c0FNameStatus.sha256)",
        "- Evidence target paths SHA-256: $($State.evidenceTargetPathsSha256)",
        "- Extraction/raw-install/install/candidate-tree manifest SHA-256: $($State.extractionManifest.sha256) / $($State.rawInstallManifest.sha256) / $($State.installManifest.sha256) / $($State.candidateTreeManifest.sha256)",
        "- Git normalization/metadata/evidence receipt SHA-256: $($State.gitIndexNormalization.sha256) / $($State.metadataPreview.sha256) / $($State.evidenceReceipt.sha256)",
        "- Candidate Gate: passed",
        "- Validation SHA-256: $($State.candidateGate.validationReportSha256)",
        "- Review Baseline path/blob/SHA-256: $($State.reviewBaselinePath) / $($State.reviewBaselineBlobOid) / $($State.reviewBaselineSha256)",
        "- Translation quality path/blob/SHA-256: $($State.translationQualityPath) / $($State.translationQualityBlobOid) / $($State.translationQualitySha256)",
        "- Archive filename/SHA-256: $($State.archive.filename) / $($State.archive.sha256)",
        "- Source tuple contract SHA-256: $($State.sourceTuple.contractSha256)",
        "- Security override receipt SHA-256: $(if ($State.Contains('securityOverrideReceipt') -and $State.securityOverrideReceipt) { $State.securityOverrideReceipt.sha256 } else { 'not-applicable' })",
        "- Pre-commit security validation SHA-256: $($State.securityPrecommitValidation.sha256)",
        "- External review: $($State.externalReview.status)"
    )) { $requiredFragments.Add($fragment) }
    foreach ($approval in @($State.securityOverrides)) {
        $requiredFragments.Add("archiveSha256=$($approval.archiveSha256);relativePath=$($approval.relativePath);fileSha256=$($approval.fileSha256)")
    }
    foreach ($path in @($State.evidenceTargetPaths)) { $requiredFragments.Add([string]$path) }
    foreach ($record in @($State.localizationFiles)) {
        foreach ($value in @($record.safeId, $record.rawSha256, $record.indexedSha256, $record.mergedSha256)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $requiredFragments.Add([string]$value) }
        }
    }
    foreach ($fragment in $requiredFragments) {
        if ($normalized.IndexOf($fragment, [StringComparison]::Ordinal) -lt 0) {
            throw "PR evidence summary is missing the current immutable tuple fragment: $fragment"
        }
    }
    Get-Sha256Bytes -Bytes ([Text.UTF8Encoding]::new($false).GetBytes($normalized))
}

$stateFull = [IO.Path]::GetFullPath($StatePath)
$stateRunRoot = Split-Path -Parent $stateFull
$null = Assert-NoReparsePath -Path $stateFull -Root ([IO.Path]::GetPathRoot($stateFull)) -Label 'Candidate state'
$state = Get-Content -LiteralPath $stateFull -Raw | ConvertFrom-Json -AsHashtable
if ([IO.Path]::GetFullPath([string]$state.runRoot) -cne $stateRunRoot -or [IO.Path]::GetFullPath([string]$state.statePath) -cne $stateFull) {
    throw 'Candidate state path differs from its fixed run root tuple.'
}
$null = Assert-NoReparsePath -Path $stateFull -Root ([string]$state.repositoryRoot) -Label 'Candidate state'

if ($SecurityPayloadOnly) {
    $securityChecks = [ordered]@{}
    $securityErrors = [Collections.Generic.List[string]]::new()
    foreach ($check in @(
        [ordered]@{ name = 'claimed-archive'; action = { Assert-ClaimedArchiveIntegrity -State $state } },
        [ordered]@{ name = 'security-payload'; action = { Assert-ArchivePayloadSecurityIntegrity -State $state -Chain $state.evidenceChain -Worktree ([string]$state.worktreePath) } }
    )) {
        try { $securityChecks[$check.name] = [ordered]@{ result = 'passed'; evidence = (& $check.action) } }
        catch {
            $securityChecks[$check.name] = [ordered]@{ result = 'rejected'; evidence = $_.Exception.Message }
            $securityErrors.Add("$($check.name): $($_.Exception.Message)")
        }
    }
    $securityResult = if ($securityErrors.Count -eq 0) { 'passed' } else { 'rejected' }
    $securityPath = Join-Path ([string]$state.artifactsRoot) 'precommit-security-validation.json'
    $securityReport = [ordered]@{
        schemaVersion = 1; result = $securityResult; runId = $state.runId; archiveSha256 = $state.archive.sha256
        c0Oid = $state.evidenceChain.c0Oid; extractionManifestSha256 = $state.extractionManifest.sha256
        securityOverrideReceiptSha256 = if ($state.Contains('securityOverrideReceipt') -and $state.securityOverrideReceipt) { $state.securityOverrideReceipt.sha256 } else { $null }
        checks = $securityChecks; errors = @($securityErrors); validatedAt = Get-UtcTimestamp
    }
    if (-not $CheckOnly) { Write-AtomicJson -Path $securityPath -Value $securityReport }
    $securityOutput = [ordered]@{
        result = $securityResult; path = $securityPath
        sha256 = if ($CheckOnly) { Get-ContractSha256 -Contract $securityReport } else { Get-FileSha256 -Path $securityPath }
        errors = @($securityErrors)
    }
    if ($PassThru) {
        $securityOutput
        if ($securityResult -ne 'passed') { throw "Pre-commit payload security validation rejected the run: $($securityErrors -join '; ')" }
    }
    else {
        $securityOutput | ConvertTo-Json -Depth 20 -Compress
        if ($securityResult -ne 'passed') { exit 1 }
    }
    return
}

if ($ReviewCompletion) {
    $reviewChecks = [ordered]@{}
    $reviewErrors = [Collections.Generic.List[string]]::new()
    function Add-ReviewCheck {
        param([string] $Name, [scriptblock] $Action)
        try { $reviewChecks[$Name] = [ordered]@{ result = 'passed'; evidence = (& $Action) } }
        catch { $reviewChecks[$Name] = [ordered]@{ result = 'rejected'; evidence = $_.Exception.Message }; $reviewErrors.Add("${Name}: $($_.Exception.Message)") }
    }
    Add-ReviewCheck -Name 'claimed-archive' -Action {
        Assert-ClaimedArchiveIntegrity -State $state
    }
    Add-ReviewCheck -Name 'source-receipt' -Action {
        Assert-SourceReceiptIntegrity -State $state
    }
    Add-ReviewCheck -Name 'source-tuple' -Action {
        Assert-SourceTupleIntegrity -State $state
    }
    Add-ReviewCheck -Name 'checkpoint-reasons' -Action {
        Assert-CheckpointReasonIntegrity -State $state -Chain $state.evidenceChain -Worktree ([string]$state.worktreePath)
    }
    Add-ReviewCheck -Name 'reference-integrity' -Action {
        Assert-ReferenceIntegrity -State $state
    }
    Add-ReviewCheck -Name 'candidate-gate' -Action {
        if ($state.candidateGate.status -ne 'passed') { throw 'Candidate Gate is not passed.' }
        if ((Get-FileSha256 -Path $state.candidateGate.validationReportPath) -ne $state.candidateGate.validationReportSha256) { throw 'Candidate Gate report SHA-256 changed.' }
        $report = Get-Content -LiteralPath $state.candidateGate.validationReportPath -Raw | ConvertFrom-Json -AsHashtable
        if ($report.result -ne 'passed' -or $report.runId -ne $state.runId -or
            (Get-ContractSha256 -Contract $report.evidenceChain) -ne (Get-ContractSha256 -Contract $state.evidenceChain)) {
            throw 'Candidate Gate report no longer binds the current run/evidence chain.'
        }
        $gateBindings = [ordered]@{
            evidenceGeneration = $state.evidenceGeneration; evidenceTargetPathsSha256 = $state.evidenceTargetPathsSha256
            extractionManifestSha256 = $state.extractionManifest.sha256; rawInstallManifestSha256 = $state.rawInstallManifest.sha256
            installManifestSha256 = $state.installManifest.sha256; candidateTreeManifestSha256 = $state.candidateTreeManifest.sha256
            gitIndexNormalizationSha256 = $state.gitIndexNormalization.sha256; metadataPreviewSha256 = $state.metadataPreview.sha256
            evidenceGenerationReceiptSha256 = $state.evidenceReceipt.sha256; diffReadabilitySha256 = $state.diffReadability.sha256
            securityOverrideReceiptSha256 = if ($state.Contains('securityOverrideReceipt') -and $state.securityOverrideReceipt) { $state.securityOverrideReceipt.sha256 } else { $null }
            securityPrecommitValidationSha256 = $state.securityPrecommitValidation.sha256
        }
        foreach ($field in $gateBindings.Keys) {
            if ([string]$state.candidateGate[$field] -cne [string]$gateBindings[$field]) { throw "Candidate Gate binding changed: $field" }
        }
        foreach ($artifact in @($state.extractionManifest, $state.rawInstallManifest, $state.installManifest, $state.candidateTreeManifest, $state.gitIndexNormalization, $state.metadataPreview, $state.securityPrecommitValidation)) {
            if (-not (Test-Path -LiteralPath ([string]$artifact.path) -PathType Leaf) -or
                (Get-FileSha256 -Path ([string]$artifact.path)) -cne [string]$artifact.sha256) {
                throw "Candidate Gate artifact changed: $($artifact.path)"
            }
        }
        if (-not $state.diffReadability -or (Get-FileSha256 -Path $state.diffReadability.path) -ne $state.candidateGate.diffReadabilitySha256 -or $state.diffReadability.result -ne 'passed') { throw 'Diff readability evidence is missing, changed, or rejected.' }
        $state.candidateGate.validationReportSha256
    }
    Add-ReviewCheck -Name 'evidence-generation-receipt' -Action {
        Assert-EvidenceGenerationReceiptIntegrity -State $state -Chain $state.evidenceChain -Worktree ([string]$state.worktreePath)
    }
    Add-ReviewCheck -Name 'localization-workset-deletion' -Action {
        if ([int]$state.schemaVersion -lt 15) { return 'not-applicable: Schema 14 approved spans' }
        if (-not $state.localizationWorkset -or -not $state.localizationWorkset.Contains('deletedBeforePublish') -or -not [bool]$state.localizationWorkset.deletedBeforePublish) {
            throw 'Schema 15 localization workset deletion is not finalized.'
        }
        $worksetPath = [IO.Path]::GetFullPath([string]$state.localizationWorkset.path)
        if ($worksetPath -cne [IO.Path]::GetFullPath((Join-Path ([string]$state.runRoot) 'review-artifacts/localization-workset.json'))) {
            throw 'Schema 15 localization workset deletion evidence has a non-canonical path.'
        }
        $null = Assert-NoReparsePath -Path (Split-Path -Parent $worksetPath) -Root ([string]$state.repositoryRoot) -Label 'Deleted localization workset parent'
        if (Test-Path -LiteralPath $worksetPath) { throw 'Schema 15 localization workset still exists after Candidate Gate.' }
        $receiptPath = Assert-NoReparsePath -Path ([string]$state.localizationWorkset.deletionReceiptPath) -Root ([string]$state.repositoryRoot) -Label 'Localization workset deletion receipt'
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) { throw 'Localization workset deletion receipt is missing.' }
        $receiptSha = Get-FileSha256 -Path $receiptPath
        if ($receiptSha -cne [string]$state.localizationWorkset.deletionReceiptSha256 -or
            $receiptSha -cne [string]$state.candidateGate.localizationWorksetDeletionReceiptSha256) {
            throw 'Localization workset deletion receipt is not bound to state and Candidate Gate.'
        }
        $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json -AsHashtable
        if ([string]$receipt.status -cne 'deleted' -or [string]$receipt.worksetSha256 -cne [string]$state.localizationWorkset.sha256) {
            throw 'Localization workset deletion receipt does not prove deletion of the reviewed workset.'
        }
        $reviewReportPath = Assert-NoReparsePath -Path ([string]$state.candidateGate.validationReportPath) -Root ([string]$state.repositoryRoot) -Label 'Candidate Gate report'
        $report = Get-Content -LiteralPath $reviewReportPath -Raw | ConvertFrom-Json -AsHashtable
        if (-not $report.Contains('worksetDeletion') -or [string]$report.worksetDeletion.status -cne 'deleted' -or
            [string]$report.worksetDeletion.receiptSha256 -cne $receiptSha -or
            [string]$report.worksetDeletion.worksetSha256 -cne [string]$state.localizationWorkset.sha256) {
            throw 'Candidate Gate report does not contain matching workset deletion evidence.'
        }
        $receiptSha
    }
    Add-ReviewCheck -Name 'feedback-snapshot' -Action {
        if (-not $state.reviewSnapshot -or [string]::IsNullOrWhiteSpace([string]$state.reviewSnapshot.path) -or
            [string]::IsNullOrWhiteSpace([string]$state.reviewSnapshot.sha256)) {
            throw 'Review feedback snapshot receipt is missing.'
        }
        $snapshotPath = Assert-NoReparsePath -Path ([string]$state.reviewSnapshot.path) -Root ([string]$state.repositoryRoot) -Label 'Review feedback snapshot'
        $expectedSnapshotPath = [IO.Path]::GetFullPath((Join-Path ([string]$state.artifactsRoot) 'review-snapshot.json'))
        if ($snapshotPath -cne $expectedSnapshotPath) { throw 'Review feedback snapshot path changed.' }
        if ((Get-FileSha256 -Path $snapshotPath) -cne [string]$state.reviewSnapshot.sha256) { throw 'Feedback snapshot SHA-256 changed.' }
        $snapshotDocument = Get-Content -LiteralPath $snapshotPath -Raw | ConvertFrom-Json -AsHashtable
        if ([int]$snapshotDocument.schemaVersion -ne 1 -or [string]$snapshotDocument.runId -cne [string]$state.runId -or
            [string]$snapshotDocument.headOid -cne [string]$state.evidenceChain.fOid -or
            [string]$state.reviewSnapshot.headOid -cne [string]$state.evidenceChain.fOid) {
            throw 'Review feedback snapshot does not bind this run and immutable F.'
        }
        $capturedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact([string]$state.reviewSnapshot.capturedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$capturedAt) -or
            [string]$snapshotDocument.capturedAt -cne [string]$state.reviewSnapshot.capturedAt) {
            throw 'Review feedback snapshot capturedAt evidence is invalid.'
        }
        if (($snapshotDocument.externalReview | ConvertTo-Json -Depth 20 -Compress) -cne
            ($state.externalReview | ConvertTo-Json -Depth 20 -Compress)) {
            throw 'Review feedback snapshot external observation differs from state.'
        }
        [string]$state.reviewSnapshot.sha256
    }
    Add-ReviewCheck -Name 'local-review' -Action {
        if (-not $state.localReview -or -not (Test-Path -LiteralPath $state.localReview.path -PathType Leaf)) { throw 'Local review artifact is missing.' }
        if ((Get-FileSha256 -Path $state.localReview.path) -ne $state.localReview.sha256) { throw 'Local review artifact SHA-256 changed.' }
        $review = Get-Content -LiteralPath $state.localReview.path -Raw | ConvertFrom-Json -AsHashtable
        if ($review.result -ne 'passed' -or $review.headOid -ne $state.evidenceChain.fOid -or
            $review.candidateGateSha256 -ne $state.candidateGate.validationReportSha256 -or
            $review.feedbackSnapshotSha256 -ne $state.reviewSnapshot.sha256) { throw 'Local review is not passed for the current F/Candidate Gate/feedback snapshot.' }
        $reviewedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact([string]$review.reviewedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$reviewedAt)) {
            throw 'Local review reviewedAt is not an ISO-8601 round-trip timestamp.'
        }
        $capturedAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact([string]$state.reviewSnapshot.capturedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$capturedAt) -or
            $reviewedAt -lt $capturedAt) { throw 'Local review predates the immutable feedback snapshot.' }
        if (@($review.securityBlocking).Count -ne 0) { throw 'Local review contains a security-blocking finding.' }
        foreach ($finding in @($review.findings)) {
            if ($finding -isnot [Collections.IDictionary]) { throw 'Local review finding is not an object.' }
            foreach ($field in @('priority', 'location', 'violatedBaseline', 'evidence', 'consequence', 'disposition')) {
                if (-not $finding.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$finding[$field])) { throw "Local review finding is missing $field." }
            }
        }
        $unresolved = @($review.findings | Where-Object { $_.disposition -notin @('keep', 'resolved') })
        if ($unresolved.Count -ne 0) { throw 'Local review contains findings without a completed disposition.' }
        if ($state.localReview.reviewedAt -ne $review.reviewedAt) { throw 'Local review state timestamp differs from its artifact.' }
        if ($state.localReview.feedbackSnapshotSha256 -ne $review.feedbackSnapshotSha256) { throw 'Local review state feedback snapshot differs from its artifact.' }
        $state.localReview.sha256
    }
    Add-ReviewCheck -Name 'local-remote-pr-head' -Action {
        $local = (Invoke-GitCheck -WorkingDirectory $state.worktreePath -Arguments @('rev-parse', 'HEAD')).output.Trim()
        $remote = (Invoke-GitCheck -WorkingDirectory $state.worktreePath -Arguments @('ls-remote', '--heads', $state.remote, "refs/heads/$($state.branch)")).output.Split("`t")[0]
        $pr = (Invoke-GhCheck -WorkingDirectory $state.worktreePath -Arguments @('pr', 'view', [string]$state.prNumber, '--json', 'number,url,state,isDraft,baseRefName,headRefName,headRefOid')).output | ConvertFrom-Json -AsHashtable
        if ($local -ne $state.evidenceChain.fOid -or $remote -ne $local -or $pr.headRefOid -ne $local) { throw 'local, remote, PR head, and F are not identical.' }
        if ($pr.state -ne 'OPEN' -or $pr.isDraft -or $pr.baseRefName -ne $state.pullRequestBase -or $pr.headRefName -ne $state.branch) { throw 'PR state, draft flag, base, or head is invalid.' }
        $local
    }
    Add-ReviewCheck -Name 'pr-evidence-summary' -Action {
        $pr = (Invoke-GhCheck -WorkingDirectory $state.worktreePath -Arguments @('pr', 'view', [string]$state.prNumber, '--json', 'body')).output | ConvertFrom-Json -AsHashtable
        Assert-PrBodyEvidenceSummary -State $state -Body ([string]$pr.body)
    }
    Add-ReviewCheck -Name 'reviewed-oid' -Action {
        if ($state.reviewedOid -ne $state.evidenceChain.fOid) { throw 'reviewedOid does not equal F.' }
        if ($state.externalReview.status -notin @('completed', 'requested-pending', 'not-applicable', 'unavailable')) { throw 'External Review has no allowed zero-wait observation.' }
        if (-not $state.externalReview.Contains('pollingWaitSeconds') -or [int64]$state.externalReview.pollingWaitSeconds -ne 0) { throw 'External Review polling wait is missing or not zero.' }
        if ([string]$state.externalReview.headOid -cne [string]$state.evidenceChain.fOid) { throw 'External Review head does not equal F.' }
        $snapshotAt = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact([string]$state.externalReview.snapshotAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$snapshotAt)) {
            throw 'External Review snapshotAt is not an ISO-8601 round-trip timestamp.'
        }
        switch ([string]$state.externalReview.status) {
            'completed' {
                foreach ($field in @('reviewId', 'reviewerLogin', 'submittedAt', 'reviewCommitOid')) {
                    if ([string]::IsNullOrWhiteSpace([string]$state.externalReview[$field])) { throw "Completed External Review is missing $field." }
                }
                if ([string]$state.externalReview.reviewCommitOid -cne [string]$state.evidenceChain.fOid) { throw 'Completed External Review commit does not equal F.' }
                $submittedAt = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse([string]$state.externalReview.submittedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$submittedAt)) {
                    throw 'Completed External Review submittedAt is invalid.'
                }
            }
            'requested-pending' {
                if (-not $state.externalReview.requestEvidence) { throw 'Pending External Review is missing requestEvidence.' }
                if ($state.externalReview.requestEvidence.Contains('exitCode') -and [int]$state.externalReview.requestEvidence.exitCode -ne 0) {
                    throw 'Pending External Review request evidence records a failed request.'
                }
            }
            'not-applicable' {
                if ([string]::IsNullOrWhiteSpace([string]$state.externalReview.reason)) { throw 'Not-applicable External Review is missing its reason.' }
            }
            'unavailable' {
                if ([string]::IsNullOrWhiteSpace([string]$state.externalReview.reason)) { throw 'Unavailable External Review is missing its reason.' }
                $verifiedAt = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParseExact([string]$state.externalReview.verifiedAt, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$verifiedAt)) {
                    throw 'Unavailable External Review verifiedAt is invalid.'
                }
            }
        }
        $state.reviewedOid
    }
    $reviewResultName = if ($reviewErrors.Count -eq 0) { 'passed' } else { 'rejected' }
    $reviewValidationPath = Join-Path $state.artifactsRoot 'review-completion-validation.json'
    $reviewReport = [ordered]@{ schemaVersion = 1; result = $reviewResultName; runId = $state.runId; headOid = $state.evidenceChain.fOid; checks = $reviewChecks; errors = @($reviewErrors); validatedAt = Get-UtcTimestamp }
    if (-not $CheckOnly) { Write-AtomicJson -Path $reviewValidationPath -Value $reviewReport }
    $reviewOutput = [ordered]@{
        result = $reviewResultName; path = $reviewValidationPath
        sha256 = if ($CheckOnly) { Get-ContractSha256 -Contract $reviewReport } else { Get-FileSha256 -Path $reviewValidationPath }
        errors = @($reviewErrors)
    }
    if ($PassThru) { $reviewOutput; if ($reviewResultName -ne 'passed') { throw "Review completion validation rejected the run: $($reviewErrors -join '; ')" } }
    else { $reviewOutput | ConvertTo-Json -Depth 20 -Compress; if ($reviewResultName -ne 'passed') { exit 1 } }
    return
}

$checks = [ordered]@{}
$errors = [Collections.Generic.List[string]]::new()

function Add-ValidationCheck {
    param([string] $Name, [scriptblock] $Action)
    try {
        $value = & $Action
        if ($value -eq $false) { throw "$Name returned false." }
        $checks[$Name] = [ordered]@{ result = 'passed'; evidence = $value }
    }
    catch {
        $checks[$Name] = [ordered]@{ result = 'rejected'; evidence = $_.Exception.Message }
        $errors.Add("${Name}: $($_.Exception.Message)")
    }
}

$chain = $state.evidenceChain
$worktree = [string]$state.worktreePath

Add-ValidationCheck -Name 'claimed-archive' -Action {
    Assert-ClaimedArchiveIntegrity -State $state
}

Add-ValidationCheck -Name 'security-payload' -Action {
    Assert-ArchivePayloadSecurityIntegrity -State $state -Chain $chain -Worktree $worktree
}

Add-ValidationCheck -Name 'precommit-security-validation' -Action {
    if (-not $state.securityPrecommitValidation -or [string]::IsNullOrWhiteSpace([string]$state.securityPrecommitValidation.path) -or
        [string]::IsNullOrWhiteSpace([string]$state.securityPrecommitValidation.sha256)) {
        throw 'Pre-commit security validation receipt is missing.'
    }
    $path = Assert-NoReparsePath -Path ([string]$state.securityPrecommitValidation.path) -Root ([string]$state.repositoryRoot) -Label 'Pre-commit security validation'
    if ($path -cne [IO.Path]::GetFullPath((Join-Path ([string]$state.artifactsRoot) 'precommit-security-validation.json'))) {
        throw 'Pre-commit security validation path changed.'
    }
    if ((Get-FileSha256 -Path $path) -cne [string]$state.securityPrecommitValidation.sha256) {
        throw 'Pre-commit security validation SHA-256 changed.'
    }
    $receipt = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    $expectedOverrideSha = if ($state.Contains('securityOverrideReceipt') -and $state.securityOverrideReceipt) { [string]$state.securityOverrideReceipt.sha256 } else { '' }
    if ([string]$receipt.result -cne 'passed' -or [string]$receipt.runId -cne [string]$state.runId -or
        [string]$receipt.archiveSha256 -cne [string]$state.archive.sha256 -or
        [string]$receipt.c0Oid -cne [string]$chain.c0Oid -or
        [string]$receipt.extractionManifestSha256 -cne [string]$state.extractionManifest.sha256 -or
        [string]$receipt.securityOverrideReceiptSha256 -cne $expectedOverrideSha -or
        [string]$state.securityPrecommitValidation.archiveSha256 -cne [string]$state.archive.sha256 -or
        [string]$state.securityPrecommitValidation.extractionManifestSha256 -cne [string]$state.extractionManifest.sha256 -or
        [string]$state.securityPrecommitValidation.securityOverrideReceiptSha256 -cne $expectedOverrideSha) {
        throw 'Pre-commit security validation tuple changed.'
    }
    [string]$state.securityPrecommitValidation.sha256
}

Add-ValidationCheck -Name 'physical-install-tree' -Action {
    $verifiedWorktree = Assert-NoReparsePath -Path $worktree -Root ([IO.Path]::GetPathRoot($worktree)) -Label 'Candidate worktree'
    $expectedInstallRoot = [IO.Path]::GetFullPath((Join-Path $verifiedWorktree ([string]$state.modRelativePath)))
    if ([IO.Path]::GetFullPath([string]$state.installRoot) -cne $expectedInstallRoot) {
        throw 'Candidate installRoot differs from the fixed MOD path in its worktree.'
    }
    $null = Assert-NoReparseTree -Path ([string]$state.installRoot) -Root $verifiedWorktree -Label 'Candidate installed MOD tree'
    $expectedInstallRoot
}

Add-ValidationCheck -Name 'source-receipt' -Action {
    Assert-SourceReceiptIntegrity -State $state
}

Add-ValidationCheck -Name 'source-tuple' -Action {
    Assert-SourceTupleIntegrity -State $state
}

Add-ValidationCheck -Name 'reference-integrity' -Action {
    Assert-ReferenceIntegrity -State $state
}

Add-ValidationCheck -Name 'candidate-head' -Action {
    foreach ($field in @('c0Oid', 'c1Oid', 'fOid')) {
        if ([string]::IsNullOrWhiteSpace([string]$chain[$field])) { throw "Missing $field." }
    }
    $head = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', 'HEAD')).output.Trim()
    if ($head -ne $chain.fOid) { throw 'HEAD does not equal fOid.' }
    $ancestor = Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('merge-base', '--is-ancestor', $chain.c0Oid, $chain.fOid) -AllowFailure
    if ($ancestor.exitCode -ne 0) { throw 'c0Oid is not an ancestor of fOid.' }
    $head
}

Add-ValidationCheck -Name 'base-c0-identity' -Action {
    if ([string]::IsNullOrWhiteSpace([string]$state.baseOid) -or
        [string]::IsNullOrWhiteSpace([string]$chain.c0Oid)) {
        throw 'State base OID or C0 is missing.'
    }
    if ([string]$state.baseOid -cne [string]$chain.c0Oid) {
        throw 'State base OID differs from C0.'
    }
    [string]$state.baseOid
}

Add-ValidationCheck -Name 'parent-tree-invariants' -Action {
    $c1Parent = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain.c1Oid)^1")).output.Trim()
    $c1ParentTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain.c1Oid)^1^{tree}")).output.Trim()
    if ($c1Parent -ne $chain.c1ParentOid -or $c1ParentTree -ne $chain.c1ParentTreeOid -or $c1ParentTree -ne $chain.c0TreeOid) { throw 'C1 parent identity/tree does not equal the recorded C0 invariant.' }
    if ($state.localizationMode -eq 'zh-tw') {
        foreach ($field in @('c2Oid', 'c2TreeOid', 'c3Oid', 'c3TreeOid')) {
            if ([string]::IsNullOrWhiteSpace([string]$chain[$field])) { throw "Missing $field for active localization." }
        }
        $c2ParentTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain.c2Oid)^1^{tree}")).output.Trim()
        $c3ParentTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain.c3Oid)^1^{tree}")).output.Trim()
        if ($c2ParentTree -ne $chain.c2ParentTreeOid -or $c2ParentTree -ne $chain.c1TreeOid) { throw 'C2 parent tree does not equal C1 tree.' }
        if ($c3ParentTree -ne $chain.c3ParentTreeOid -or $c3ParentTree -ne $chain.c2TreeOid) { throw 'C3 parent tree does not equal C2 tree.' }
    }
    'parent tree invariants passed'
}

Add-ValidationCheck -Name 'checkpoint-reasons' -Action {
    Assert-CheckpointReasonIntegrity -State $state -Chain $chain -Worktree $worktree
}

Add-ValidationCheck -Name 'commit-trees' -Action {
    foreach ($prefix in @('c0', 'c1', 'f')) {
        $actualTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain["${prefix}Oid"])^{tree}")).output.Trim()
        if ($actualTree -ne $chain["${prefix}TreeOid"]) { throw "$prefix tree OID mismatch." }
    }
    if ($state.localizationMode -eq 'zh-tw') {
        foreach ($prefix in @('c2', 'c3')) {
            $actualTree = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('rev-parse', "$($chain["${prefix}Oid"])^{tree}")).output.Trim()
            if ($actualTree -ne $chain["${prefix}TreeOid"]) { throw "$prefix tree OID mismatch." }
        }
    }
    'C0/C1/C2/C3/F trees verified'
}

Add-ValidationCheck -Name 'layered-path-allowlists' -Action {
    $targets = @($state.evidenceTargetPaths)
    $c1Paths = Get-ChangedPaths -WorkingDirectory $worktree -BaseOid $chain.c1ParentOid -HeadOid $chain.c1Oid
    foreach ($path in $c1Paths) {
        if (-not $path.StartsWith($state.modRelativePath + '/', [StringComparison]::Ordinal) -or $path -cin $targets) { throw "C1 contains a target or out-of-MOD path: $path" }
    }
    if ($state.localizationMode -eq 'zh-tw') {
        foreach ($range in @([ordered]@{ base = $chain.c2ParentOid; head = $chain.c2Oid; name = 'C2' }, [ordered]@{ base = $chain.c3ParentOid; head = $chain.c3Oid; name = 'C3' })) {
            foreach ($path in Get-ChangedPaths -WorkingDirectory $worktree -BaseOid $range.base -HeadOid $range.head) {
                if ($path -cnotin $targets) { throw "$($range.name) contains a non-target path: $path" }
            }
        }
    }
    $finalAllowlist = @($state.metadataPaths | ForEach-Object { $_.Replace('\', '/') })
    foreach ($path in Get-ChangedPaths -WorkingDirectory $worktree -BaseOid $chain.c0Oid -HeadOid $chain.fOid) {
        if (-not $path.StartsWith($state.modRelativePath + '/', [StringComparison]::Ordinal) -and $path -cnotin $finalAllowlist) { throw "F contains an out-of-scope path: $path" }
    }
    'C1/C2/C3/F changed paths stay within their deterministic allowlists'
}

Add-ValidationCheck -Name 'diff-check' -Action {
    $finalCheck = Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--check', "$($chain.c0Oid)..$($chain.fOid)") -AllowFailure
    if ($finalCheck.exitCode -eq 0) { return 'standard diff --check passed' }
    if ($finalCheck.exitCode -ne 2) { throw "Standard Git diff --check failed unexpectedly: $($finalCheck.output)" }

    $upstreamRanges = @([ordered]@{ base = $chain.c0Oid; head = $chain.c1Oid })
    if ($state.localizationMode -eq 'zh-tw') { $upstreamRanges += [ordered]@{ base = $chain.c1Oid; head = $chain.c2Oid } }
    $upstreamSignatures = @(
        foreach ($range in $upstreamRanges) {
            $check = Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--check', "$($range.base)..$($range.head)") -AllowFailure
            if ($check.exitCode -notin @(0, 2)) { throw "Unable to verify upstream whitespace exceptions: $($check.output)" }
            Get-DiffCheckSignatures -Output $check.output
        }
    ) | Sort-Object -Unique
    if ($state.localizationMode -eq 'zh-tw') {
        $localizationCheck = Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--check', "$($chain.c2Oid)..$($chain.c3Oid)") -AllowFailure
        if ($localizationCheck.exitCode -ne 0) { throw "Localization introduced whitespace errors: $($localizationCheck.output)" }
    }
    $finalSignatures = @(Get-DiffCheckSignatures -Output $finalCheck.output)
    if ($finalSignatures.Count -eq 0) { throw "Standard Git diff --check produced an unrecognized rejection: $($finalCheck.output)" }
    foreach ($signature in $finalSignatures) {
        if ($signature -cnotin $upstreamSignatures) { throw "Final diff contains a non-upstream whitespace error: $signature" }
    }
    "standard diff --check accepted $($finalSignatures.Count) exact upstream whitespace exceptions"
}

Add-ValidationCheck -Name 'diff-readability' -Action {
    $ranges = @(
        [ordered]@{ name = 'c0-c1'; base = $chain.c0Oid; head = $chain.c1Oid },
        [ordered]@{ name = 'c0-f'; base = $chain.c0Oid; head = $chain.fOid }
    )
    if ($state.localizationMode -eq 'zh-tw') {
        $ranges += [ordered]@{ name = 'c1-c2'; base = $chain.c1Oid; head = $chain.c2Oid }
        $ranges += [ordered]@{ name = 'c2-c3'; base = $chain.c2Oid; head = $chain.c3Oid }
        if ($chain.fOid -ne $chain.c3Oid) { $ranges += [ordered]@{ name = 'c3-f'; base = $chain.c3Oid; head = $chain.fOid } }
    }
    $records = @()
    $noiseRanges = @()
    foreach ($range in $ranges) {
        $regular = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--numstat', '--no-renames', "$($range.base)..$($range.head)")).output
        $diagnostic = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('diff', '--ignore-space-at-eol', '--numstat', '--no-renames', "$($range.base)..$($range.head)")).output
        $regularTotal = 0; foreach ($line in @($regular -split "`r?`n" | Where-Object { $_ -match '^(\d+)\s+(\d+)\s+' })) { $parts = $line -split '\s+', 3; $regularTotal += [int]$parts[0] + [int]$parts[1] }
        $diagnosticTotal = 0; foreach ($line in @($diagnostic -split "`r?`n" | Where-Object { $_ -match '^(\d+)\s+(\d+)\s+' })) { $parts = $line -split '\s+', 3; $diagnosticTotal += [int]$parts[0] + [int]$parts[1] }
        $lineEndingNoise = $regularTotal -gt 20 -and $regularTotal -gt ([Math]::Max(1, $diagnosticTotal) * 4)
        $records += [ordered]@{ name = $range.name; baseOid = $range.base; headOid = $range.head; standardNumstat = $regular; ignoreSpaceAtEolDiagnosticNumstat = $diagnostic; standardChangedLines = $regularTotal; diagnosticChangedLines = $diagnosticTotal; lineEndingNoise = $lineEndingNoise }
        if ($lineEndingNoise) { $noiseRanges += $range.name }
    }
    $readabilityPath = Join-Path $state.artifactsRoot 'diff-readability.json'
    $readabilityResult = if ($noiseRanges.Count -eq 0) { 'passed' } else { 'rejected' }
    Write-AtomicJson -Path $readabilityPath -Value ([ordered]@{ schemaVersion = 1; ranges = $records; result = $readabilityResult; generatedAt = Get-UtcTimestamp })
    $state.diffReadability = [ordered]@{ path = $readabilityPath; sha256 = Get-FileSha256 -Path $readabilityPath; result = $readabilityResult }
    if ($noiseRanges.Count -ne 0) { throw "Diff readability rejected line-ending noise in $($noiseRanges -join ', ')." }
    $state.diffReadability.sha256
}

Add-ValidationCheck -Name 'evidence-generation-receipt' -Action {
    Assert-EvidenceGenerationReceiptIntegrity -State $state -Chain $chain -Worktree $worktree
}

Add-ValidationCheck -Name 'artifact-sha256' -Action {
    foreach ($artifact in @($state.sourceTuple, $state.extractionManifest, $state.rawInstallManifest, $state.installManifest, $state.gitIndexNormalization, $state.metadataPreview, $state.candidateTreeManifest, $state.evidenceReceipt)) {
        if (-not (Test-Path -LiteralPath $artifact.path -PathType Leaf)) { throw "Missing manifest or evidence artifact: $($artifact.path)" }
        if ((Get-FileSha256 -Path $artifact.path) -ne $artifact.sha256) { throw "Artifact sha256 mismatch: $($artifact.path)" }
    }
    foreach ($artifact in @($state.evidenceDiffs.Values)) {
        if ($artifact.Contains('status') -and $artifact.status -eq 'not-applicable') { continue }
        if (-not (Test-Path -LiteralPath $artifact.path -PathType Leaf) -or (Get-FileSha256 -Path $artifact.path) -ne $artifact.sha256) { throw "Git evidence artifact SHA-256 mismatch: $($artifact.path)" }
    }
    if ((Get-FileSha256 -Path $state.localizationManifestPath) -ne $state.stageTimings.localization.artifactSha256) { throw 'Localization manifest SHA-256 differs from its completed-stage receipt.' }
    'manifest and evidence sha256 values verified'
}

Add-ValidationCheck -Name 'raw-install-provenance' -Action {
    $extraction = Get-Content -LiteralPath $state.extractionManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $rawInstall = Get-Content -LiteralPath $state.rawInstallManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $prefix = ([string]$state.repoModDirectory).TrimEnd('/') + '/'
    $sourceFiles = @($extraction.files | ForEach-Object { [ordered]@{ path = if ($_.path.StartsWith($prefix, [StringComparison]::Ordinal)) { $_.path.Substring($prefix.Length) } else { throw "Extraction path is outside the one canonical MOD root: $($_.path)" }; size = $_.size; sha256 = $_.sha256 } } | Sort-Object { $_.path })
    $installedFiles = @($rawInstall.files | Sort-Object { $_.path })
    if ($sourceFiles.Count -ne $installedFiles.Count) { throw 'Raw install file count differs from extraction.' }
    for ($index = 0; $index -lt $sourceFiles.Count; $index++) {
        if (($index -band 0x3FF) -eq 0) { Invoke-Heartbeat }
        if ($sourceFiles[$index].path -cne $installedFiles[$index].path -or $sourceFiles[$index].size -ne $installedFiles[$index].size -or $sourceFiles[$index].sha256 -ne $installedFiles[$index].sha256) { throw 'Raw install differs from immutable extraction.' }
    }
    "$($sourceFiles.Count) raw archive files preserved"
}

Add-ValidationCheck -Name 'target-path-binding' -Action {
    $targetJson = ConvertTo-Json -InputObject @($state.evidenceTargetPaths) -Compress
    $actualSha = Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($targetJson))
    if ($actualSha -ne $state.evidenceTargetPathsSha256) { throw 'Evidence target path SHA-256 cannot be reconstructed.' }
    foreach ($record in @($state.localizationFiles)) {
        if ($record.relativePath -cnotin @($state.evidenceTargetPaths)) { throw 'Active localization path is outside evidenceTargetPaths.' }
    }
    $actualSha
}

Add-ValidationCheck -Name 'candidate-manifest' -Action {
    $manifest = Get-Content -LiteralPath $state.candidateTreeManifest.path -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest.commitOid -ne $chain.fOid -or $manifest.treeOid -ne $chain.fTreeOid) { throw 'Candidate manifest is not bound to F and F tree.' }
    $listing = (Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('-c', 'core.quotePath=false', 'ls-tree', '-r', '-l', '--full-tree', $chain.fOid, '--', $state.modRelativePath)).output
    $actual = [Collections.Generic.List[object]]::new()
    foreach ($line in @($listing -split "`r?`n" | Where-Object { $_ })) {
        if ($line -notmatch '^[0-7]{6} blob ([0-9a-f]{40})\s+(\d+)\t(.+)$') { throw "Unable to independently parse candidate Git tree entry: $line" }
        $repositoryPath = $Matches[3]
        $bytes = Get-GitBlobBytes -WorkingDirectory $worktree -Object $Matches[1]
        $actual.Add([ordered]@{ path = $repositoryPath.Substring(([string]$state.modRelativePath).Length).TrimStart('/'); blobOid = $Matches[1]; size = [int64]$Matches[2]; sha256 = Get-Sha256Bytes -Bytes $bytes })
    }
    $expected = @($manifest.files | Sort-Object { $_.path })
    $actual = @($actual | Sort-Object { $_.path })
    if ($actual.Count -ne $expected.Count) { throw 'Candidate Git tree path count differs from its manifest.' }
    for ($index = 0; $index -lt $actual.Count; $index++) {
        if (($index -band 0x3FF) -eq 0) { Invoke-Heartbeat }
        if ($actual[$index].path -cne $expected[$index].path -or $actual[$index].blobOid -ne $expected[$index].blobOid -or $actual[$index].size -ne $expected[$index].size -or $actual[$index].sha256 -ne $expected[$index].sha256) { throw 'Candidate Git tree differs from its manifest.' }
    }
    "$($actual.Count) Git tree manifest files verified"
}

Add-ValidationCheck -Name 'install-normalization' -Action {
    $install = Get-Content -LiteralPath $state.installManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $candidate = Get-Content -LiteralPath $state.candidateTreeManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $normalization = Get-Content -LiteralPath $state.gitIndexNormalization.path -Raw | ConvertFrom-Json -AsHashtable
    $candidateByPath = @{}; foreach ($file in $candidate.files) { $candidateByPath[$file.path] = $file }
    $normalizationByPath = @{}; foreach ($file in $normalization.files) { $normalizationByPath[$file.path] = $file }
    foreach ($file in $install.files) {
        if (-not $candidateByPath.ContainsKey($file.path) -or -not $normalizationByPath.ContainsKey($file.path)) { throw "Install path is missing from Git candidate evidence: $($file.path). Candidate paths: $($candidateByPath.Keys -join ', '). Normalization paths: $($normalizationByPath.Keys -join ', ')." }
        $rawPath = Assert-NoReparsePath -Path (Join-Path $state.installRoot $file.path) -Root $worktree -Label 'Installed candidate file'
        $raw = Read-FileBytesWithHeartbeat -Path $rawPath
        $candidateBytes = Get-GitBlobBytes -WorkingDirectory $worktree -Object ([string]$candidateByPath[$file.path].blobOid)
        $same = (Get-Sha256Bytes -Bytes $raw) -eq (Get-Sha256Bytes -Bytes $candidateBytes)
        if (-not $same -and -not (Test-CrlfNormalizationOnly -RawBytes $raw -IndexedBytes $candidateBytes)) { throw "Candidate changed bytes beyond CRLF-to-LF for $($file.path)" }
        if ((Get-Sha256Bytes -Bytes $candidateBytes) -ne $normalizationByPath[$file.path].indexedSha256 -and $file.path -notin @($state.localizationFiles.relativePath | ForEach-Object { $_.Substring(([string]$state.modRelativePath).Length).TrimStart('/') })) { throw "Candidate blob differs from normalization evidence for $($file.path)" }
    }
    'install, Git normalization, and candidate tree agree'
}

Add-ValidationCheck -Name 'localization-workset-boundary' -Action {
    if ([int]$state.schemaVersion -lt 15) { return 'not-applicable: Schema 14 approved spans' }
    if (-not $state.localizationWorkset -or [string]$state.localizationWorkset.status -cne 'applied') { throw 'Schema 15 applied localization workset evidence is missing.' }
    if ([string]$state.localizationMode -cne 'zh-tw' -or @($state.localizationFiles).Count -ne 1) {
        throw 'Schema 15 Candidate state must contain exactly one localization file.'
    }
    $worksetPath = Assert-NoReparsePath -Path ([string]$state.localizationWorkset.path) -Root ([string]$state.repositoryRoot) -Label 'Localization workset'
    if ($worksetPath -cne [IO.Path]::GetFullPath((Join-Path ([string]$state.runRoot) 'review-artifacts/localization-workset.json'))) {
        throw 'Localization workset is outside its fixed run-local path.'
    }
    if ((Get-FileSha256 -Path $worksetPath) -cne [string]$state.localizationWorkset.sha256) { throw 'Localization workset SHA-256 changed.' }
    $worksetFull = [IO.Path]::GetFullPath($worksetPath)
    $worktreeFull = [IO.Path]::GetFullPath([string]$state.worktreePath).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if ($worksetFull.StartsWith($worktreeFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'Localization workset must never be inside the Git worktree.' }
    $workset = Get-Content -LiteralPath $worksetPath -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$workset.workflowSchemaVersion -ne 15 -or [string]$workset.status -cne 'applied') { throw 'Localization workset is not an applied Schema 15 artifact.' }
    if (-not $workset.Contains('apply') -or -not $workset.apply -or [string]$workset.apply.status -cne 'applied') {
        throw 'Localization workset apply receipt is not finalized.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$workset.immutableContractSha256) -or
        (Get-ImmutableWorksetContractSha256 -Workset $workset) -cne [string]$workset.immutableContractSha256) {
        throw 'Localization workset immutable contract changed.'
    }
    if ([string]$state.localizationWorkset.immutableContractSha256 -cne [string]$workset.immutableContractSha256) {
        throw 'Localization workset immutable contract differs from state evidence.'
    }
    $localizationManifestPath = Assert-NoReparsePath -Path ([string]$state.localizationManifestPath) -Root ([string]$state.repositoryRoot) -Label 'Localization manifest'
    if ($localizationManifestPath -cne [IO.Path]::GetFullPath((Join-Path ([string]$state.artifactsRoot) 'localization-manifest.json'))) {
        throw 'Schema 15 localization manifest is outside its fixed artifact path.'
    }
    $localizationManifest = Get-Content -LiteralPath $localizationManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ([int]$localizationManifest.schemaVersion -ne 2 -or [int]$localizationManifest.workflowSchemaVersion -ne 15 -or
        [string]$localizationManifest.mode -cne 'zh-tw-workset' -or @($localizationManifest.files).Count -ne 1 -or
        @($localizationManifest.removedPaths).Count -ne 0 -or @($state.localizationRemovedPaths).Count -ne 0 -or
        [string]$localizationManifest.worksetPath -cne $worksetPath -or
        [string]$localizationManifest.worksetSha256 -cne [string]$state.localizationWorkset.sha256 -or
        [string]$localizationManifest.immutableContractSha256 -cne [string]$workset.immutableContractSha256) {
        throw 'Schema 15 localization manifest tuple differs from Candidate state or workset evidence.'
    }
    $classificationNames = @('unchanged', 'localized_source', 'missing_zh_tw', 'zh_tw_only_changed', 'source_changed_translation_unchanged', 'source_and_translation_changed', 'new_key', 'deleted_key', 'blocked')
    if (@($localizationManifest.counts.Keys).Count -ne $classificationNames.Count -or @($state.localizationWorkset.counts.Keys).Count -ne $classificationNames.Count) {
        throw 'Schema 15 localization classification counts are malformed.'
    }
    foreach ($name in $classificationNames) {
        if (-not $localizationManifest.counts.Contains($name) -or -not $state.localizationWorkset.counts.Contains($name) -or
            [int]$localizationManifest.counts[$name] -ne [int]$workset.counts[$name] -or
            [int]$state.localizationWorkset.counts[$name] -ne [int]$workset.counts[$name]) {
            throw "Schema 15 localization classification count binding changed: $name"
        }
    }
    $stateRecord = $state.localizationFiles[0]
    $manifestRecord = $localizationManifest.files[0]
    $recordFields = @('relativePath', 'safeId', 'rawSha256', 'indexedSha256', 'mergedRawSha256', 'mergedSha256', 'artifactDirectory', 'decisionsSha256', 'worksetPath', 'worksetUnitCount', 'worksetEditCount')
    if (@($stateRecord.Keys).Count -ne $recordFields.Count -or @($manifestRecord.Keys).Count -ne $recordFields.Count) {
        throw 'Schema 15 localization file record fields are malformed.'
    }
    foreach ($field in $recordFields) {
        if (-not $stateRecord.Contains($field) -or -not $manifestRecord.Contains($field) -or
            [string]$stateRecord[$field] -cne [string]$manifestRecord[$field]) {
            throw "Schema 15 localization manifest file binding changed: $field"
        }
    }
    $expectedStagingRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path ([string]$state.runRoot) 'staging/localization-workset-input') ([string]$state.repoModDirectory)))
    $stagedLocalizationPath = [IO.Path]::GetFullPath([string]$workset.new.path)
    $relativeToMod = [IO.Path]::GetRelativePath($expectedStagingRoot, $stagedLocalizationPath).Replace('\', '/')
    if ($relativeToMod -eq '..' -or $relativeToMod.StartsWith('../', [StringComparison]::Ordinal) -or [IO.Path]::IsPathRooted($relativeToMod)) {
        throw 'Schema 15 workset NEW localization path escapes fixed staging.'
    }
    $expectedRelativePath = ([string]$state.modRelativePath).TrimEnd('/') + '/' + $relativeToMod
    $expectedSafeId = (Get-Sha256Bytes -Bytes ([Text.Encoding]::UTF8.GetBytes($expectedRelativePath))).Substring(0, 16)
    $expectedArtifactDirectory = [IO.Path]::GetFullPath((Join-Path (Join-Path ([string]$state.artifactsRoot) 'localization') $expectedSafeId))
    if ([string]$stateRecord.relativePath -cne $expectedRelativePath -or [string]$stateRecord.safeId -cne $expectedSafeId -or
        [IO.Path]::GetFullPath([string]$stateRecord.artifactDirectory) -cne $expectedArtifactDirectory -or
        [string]$stateRecord.worksetPath -cne $worksetPath -or
        [string]$stateRecord.decisionsSha256 -cne [string]$state.localizationWorkset.sha256 -or
        [int]$stateRecord.worksetUnitCount -ne @($workset.units).Count -or
        [int]$stateRecord.worksetEditCount -ne @($workset.apply.edits).Count) {
        throw 'Schema 15 localization file record differs from the unique workset output.'
    }
    if ([string]$workset.old.path -cnotin @($state.evidenceTargetPaths)) { throw 'Workset OLD localization path is outside evidenceTargetPaths.' }
    if (@($workset.units | Where-Object { $_.action -ceq 'BLOCKED' }).Count -ne 0) { throw 'Localization workset contains BLOCKED units.' }
    if (@($workset.units | Where-Object { $_.action -ceq 'AI_REQUIRED' -and $_.reviewStatus -cne 'approved' }).Count -ne 0) { throw 'Localization workset contains unapproved AI_REQUIRED units.' }
        if (@($workset.units | Where-Object { $_.action -cne 'AI_REQUIRED' -and ($_.reviewStatus -cne 'not-required' -or $null -ne $_.suggestedZhTwExpression) }).Count -ne 0) { throw 'Localization review fields were edited outside AI_REQUIRED units.' }
    foreach ($record in @($state.localizationFiles)) {
        if ([string]$record.relativePath -cnotin @($state.evidenceTargetPaths)) { throw 'Workset NEW localization path is outside evidenceTargetPaths.' }
        if ([string]$record.decisionsSha256 -cne [string]$state.localizationWorkset.sha256) { throw 'Localization file is not bound to the current workset SHA-256.' }
        $newPath = Join-Path ([string]$record.artifactDirectory) 'new.lua'
        $mergedPath = Join-Path ([string]$record.artifactDirectory) 'merged.lua'
        $mergedIndexedPath = Join-Path ([string]$record.artifactDirectory) 'merged-indexed.lua'
        $newPath = Assert-NoReparsePath -Path $newPath -Root ([string]$state.repositoryRoot) -Label 'Raw NEW localization evidence'
        $mergedPath = Assert-NoReparsePath -Path $mergedPath -Root ([string]$state.repositoryRoot) -Label 'Merged localization evidence'
        $mergedIndexedPath = Assert-NoReparsePath -Path $mergedIndexedPath -Root ([string]$state.repositoryRoot) -Label 'Merged indexed localization evidence'
        $newBytes = Read-FileBytesWithHeartbeat -Path $newPath
        $mergedBytes = Read-FileBytesWithHeartbeat -Path $mergedPath
        $mergedIndexedBytes = Read-FileBytesWithHeartbeat -Path $mergedIndexedPath
        if ((Get-Sha256Bytes -Bytes $newBytes) -cne [string]$workset.apply.inputSha256 -or (Get-Sha256Bytes -Bytes $newBytes) -cne [string]$record.rawSha256) { throw 'Workset NEW bytes differ from raw localization evidence.' }
        if ((Get-Sha256Bytes -Bytes $mergedBytes) -cne [string]$workset.apply.outputSha256 -or (Get-Sha256Bytes -Bytes $mergedBytes) -cne [string]$record.mergedRawSha256) { throw 'Workset merged bytes differ from apply evidence.' }
        if ((Get-Sha256Bytes -Bytes $mergedIndexedBytes) -cne [string]$record.mergedSha256) { throw 'Workset merged indexed bytes changed.' }
        $receiptVerifier = Join-Path $PSScriptRoot 'Test-LocalizationWorksetReceipt.ps1'
        $receiptVerification = & $receiptVerifier -WorksetPath $worksetPath -NewPath $newPath -MergedPath $mergedPath `
            -RunRoot ([string]$state.runRoot) -RepositoryRoot ([string]$state.repositoryRoot) `
            -ExpectedBaseOid ([string]$chain.c0Oid) -ExpectedModRelativePath ([string]$state.modRelativePath) `
            -HeartbeatAction $HeartbeatAction -PassThru
        if ($receiptVerification.result -cne 'passed') { throw 'Independent localization apply receipt verification failed.' }
        $null = Test-LocalizationWorksetCandidate -NewBytes $newBytes -MergedBytes $mergedBytes -Edits @($workset.apply.edits)
        $targetPath = Join-Path $worktree ([string]$record.relativePath)
        $targetPath = Assert-NoReparsePath -Path $targetPath -Root $worktree -Label 'Worktree localization target'
        if ((Get-FileSha256 -Path $targetPath) -cne [string]$record.mergedRawSha256) { throw 'Worktree localization target differs from workset merged raw bytes.' }
        $candidateBlob = Get-GitBlobBytes -WorkingDirectory $worktree -Object "$($chain.fOid):$([string]$record.relativePath)"
        if ((Get-Sha256Bytes -Bytes $candidateBlob) -cne [string]$record.mergedSha256) { throw 'F localization blob differs from workset merged indexed bytes.' }
    }
    "Workset units=$(@($workset.units).Count), edits=$(@($workset.apply.edits).Count), SHA-256=$($state.localizationWorkset.sha256)"
}

Add-ValidationCheck -Name 'localization-byte-boundary' -Action {
    if ([int]$state.schemaVersion -ge 15) { return 'not-applicable: Schema 15 localization workset' }
    if ($state.localizationMode -eq 'none') { return 'not-applicable: localization mode none' }
    $rawInstall = Get-Content -LiteralPath $state.rawInstallManifest.path -Raw | ConvertFrom-Json -AsHashtable
    $normalization = Get-Content -LiteralPath $state.gitIndexNormalization.path -Raw | ConvertFrom-Json -AsHashtable
    foreach ($record in @($state.localizationFiles)) {
        $newPath = Join-Path ([string]$record.artifactDirectory) 'new.lua'
        $indexedPath = Join-Path ([string]$record.artifactDirectory) 'indexed.lua'
        $mergedPath = Join-Path ([string]$record.artifactDirectory) 'merged.lua'
        $decisionsPath = Join-Path ([string]$record.artifactDirectory) 'decisions.json'
        if ((Get-FileSha256 -Path $decisionsPath) -ne $record.decisionsSha256) { throw 'Localization decisions artifact SHA-256 changed.' }
        $decision = Get-Content -LiteralPath $decisionsPath -Raw | ConvertFrom-Json -AsHashtable
        $raw = Read-FileBytesWithHeartbeat -Path $newPath
        $indexed = Read-FileBytesWithHeartbeat -Path $indexedPath
        $merged = Read-FileBytesWithHeartbeat -Path $mergedPath
        if ((Get-Sha256Bytes -Bytes $raw) -ne $record.rawSha256) { throw 'Raw localization artifact sha256 mismatch.' }
        if ((Get-Sha256Bytes -Bytes $indexed) -ne $record.indexedSha256) { throw 'Indexed localization artifact sha256 mismatch.' }
        if ((Get-Sha256Bytes -Bytes $merged) -ne $record.mergedSha256) { throw 'Merged localization artifact sha256 mismatch.' }
        try {
            $null = Get-LuaLocalizationDocument -Bytes $merged -DisplayPath ([string]$record.relativePath) -SourceId ([string]$record.relativePath) -HeartbeatAction $HeartbeatAction
        }
        catch {
            throw "Merged Schema 14 localization structure is invalid: $($_.Exception.Message)"
        }
        $relativeToMod = ([string]$record.relativePath).Substring(([string]$state.modRelativePath).Length).TrimStart('/')
        $rawEntry = @($rawInstall.files | Where-Object { $_.path -ceq $relativeToMod })
        $normalizationEntry = @($normalization.files | Where-Object { $_.path -ceq $relativeToMod })
        if ($rawEntry.Count -ne 1 -or $rawEntry[0].sha256 -ne $record.rawSha256 -or $rawEntry[0].size -ne $raw.LongLength) { throw 'Raw localization artifact differs from the raw-install manifest.' }
        if ($normalizationEntry.Count -ne 1 -or $normalizationEntry[0].rawSha256 -ne $record.rawSha256 -or $normalizationEntry[0].indexedSha256 -ne $record.indexedSha256) { throw 'Localization artifacts differ from Git-normalization evidence.' }
        $null = Test-ApprovedSpanCandidate -Indexed $indexed -Merged $merged -ApprovedSpans @($decision.approvedSpans)
        $targetPath = Join-Path $worktree ([string]$record.relativePath)
        if ((Get-FileSha256 -Path $targetPath) -ne $record.mergedSha256) { throw 'Worktree localization target differs from merged artifact.' }
        $candidateBlob = Get-GitBlobBytes -WorkingDirectory $worktree -Object "$($chain.fOid):$([string]$record.relativePath)"
        if ((Get-Sha256Bytes -Bytes $candidateBlob) -ne $record.mergedSha256) { throw 'F localization blob differs from the approved merged artifact.' }
    }
    foreach ($removedPath in @($state.localizationRemovedPaths)) {
        if ($removedPath -cnotin @($state.evidenceTargetPaths)) { throw 'Removed localization target is outside evidenceTargetPaths.' }
        if ((Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('cat-file', '-e', "$($chain.c0Oid):$removedPath") -AllowFailure).exitCode -ne 0) { throw 'Removed localization target did not exist at C0.' }
        if ((Invoke-GitCheck -WorkingDirectory $worktree -Arguments @('cat-file', '-e', "$($chain.fOid):$removedPath") -AllowFailure).exitCode -eq 0) { throw 'Removed localization target still exists at F.' }
        $relativeToMod = $removedPath.Substring(([string]$state.modRelativePath).Length).TrimStart('/')
        if (@($rawInstall.files | Where-Object { $_.path -ceq $relativeToMod }).Count -ne 0) { throw 'Removed localization target still exists in the raw install.' }
    }
    'Only approved localization spans changed.'
}

$validationPath = Join-Path $state.artifactsRoot 'validation-report.json'
$resultName = if ($errors.Count -eq 0) { 'passed' } else { 'rejected' }
$sourceReceiptEvidence = if ($state.Contains('sourceReceipt')) { $state.sourceReceipt } else { $null }
$localizationWorksetEvidence = if ($state.Contains('localizationWorkset')) { $state.localizationWorkset } else { $null }
$report = [ordered]@{
    schemaVersion = 1
    result = $resultName
    runId = $state.runId
    candidateGate = $resultName
    evidenceChain = $chain
    workflow = [ordered]@{ commitOid = $state.workflowCommitOid; path = $state.workflowPath; blobOid = $state.workflowBlobOid; sha256 = $state.workflowSha256 }
    reviewBaseline = [ordered]@{ path = $state.reviewBaselinePath; blobOid = $state.reviewBaselineBlobOid; sha256 = $state.reviewBaselineSha256 }
    archive = $state.archive
    sourceTuple = $state.sourceTuple
    sourceReceipt = $sourceReceiptEvidence
    evidenceGeneration = $state.evidenceGeneration
    evidenceTargetPaths = $state.evidenceTargetPaths
    evidenceTargetPathsSha256 = $state.evidenceTargetPathsSha256
    evidenceDiffs = $state.evidenceDiffs
    diffReadability = $state.diffReadability
    localizationMode = $state.localizationMode
    localizationWorkset = $localizationWorksetEvidence
    manifests = [ordered]@{
        extraction = $state.extractionManifest
        rawInstall = $state.rawInstallManifest
        install = $state.installManifest
        candidate = $state.candidateTreeManifest
        gitIndexNormalization = $state.gitIndexNormalization
        metadataPreview = $state.metadataPreview
        evidenceReceipt = $state.evidenceReceipt
        securityOverride = if ($state.Contains('securityOverrideReceipt')) { $state.securityOverrideReceipt } else { $null }
        precommitSecurity = $state.securityPrecommitValidation
    }
    checks = $checks
    errors = @($errors)
    validatedAt = Get-UtcTimestamp
}
Write-AtomicJson -Path $validationPath -Value $report
$validationSha = Get-FileSha256 -Path $validationPath
$state.candidateGate = [ordered]@{
    status = $resultName
    c0Oid = $chain.c0Oid
    c1Oid = $chain.c1Oid
    c2Oid = $chain.c2Oid
    c3Oid = $chain.c3Oid
    fOid = $chain.fOid
    c0TreeOid = $chain.c0TreeOid
    c1TreeOid = $chain.c1TreeOid
    c2TreeOid = $chain.c2TreeOid
    c3TreeOid = $chain.c3TreeOid
    fTreeOid = $chain.fTreeOid
    c1ParentTreeOid = $chain.c1ParentTreeOid
    c2ParentTreeOid = $chain.c2ParentTreeOid
    c3ParentTreeOid = $chain.c3ParentTreeOid
    evidenceGeneration = $state.evidenceGeneration
    evidenceTargetPathsSha256 = $state.evidenceTargetPathsSha256
    extractionManifestSha256 = $state.extractionManifest.sha256
    rawInstallManifestSha256 = $state.rawInstallManifest.sha256
    installManifestSha256 = $state.installManifest.sha256
    candidateTreeManifestSha256 = $state.candidateTreeManifest.sha256
    gitIndexNormalizationSha256 = $state.gitIndexNormalization.sha256
    metadataPreviewSha256 = $state.metadataPreview.sha256
    sourceTupleSha256 = $state.sourceTuple.sha256
    sourceTupleContractSha256 = $state.sourceTuple.contractSha256
    evidenceGenerationReceiptSha256 = $state.evidenceReceipt.sha256
    securityOverrideReceiptSha256 = if ($state.Contains('securityOverrideReceipt') -and $state.securityOverrideReceipt) { $state.securityOverrideReceipt.sha256 } else { $null }
    securityPrecommitValidationSha256 = $state.securityPrecommitValidation.sha256
    diffReadabilitySha256 = $state.diffReadability.sha256
    localizationWorksetSha256 = if ([int]$state.schemaVersion -ge 15) { $state.localizationWorkset.sha256 } else { $null }
    sourceReceiptSha256 = if ([int]$state.schemaVersion -ge 15) { $state.sourceReceipt.sha256 } else { $null }
    validatorSha256 = Get-FileSha256 -Path $PSCommandPath
    validationReportPath = $validationPath
    validationReportSha256 = $validationSha
    validatedAt = Get-UtcTimestamp
}
$state.updatedAt = Get-UtcTimestamp
Write-AtomicJson -Path $StatePath -Value $state

$output = [ordered]@{
    result = $resultName
    runId = $state.runId
    candidateGate = $state.candidateGate
    validationReportPath = $validationPath
    validationReportSha256 = $validationSha
    errors = @($errors)
}

if ($PassThru) {
    $output
    if ($resultName -ne 'passed') { throw "Independent candidate validation rejected the run: $($errors -join '; ')" }
}
else {
    $output | ConvertTo-Json -Depth 20 -Compress
    if ($resultName -ne 'passed') { exit 1 }
}
