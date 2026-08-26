#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ReceiptPath,

    [Parameter(Mandatory)]
    [string] $SourceRequestPath,

    [string] $RunRoot,

    [string] $RetainedPath,

    [switch] $AllowNonDelivered,

    [scriptblock] $HeartbeatAction,

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
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function ConvertTo-InvariantString {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return ([DateTimeOffset]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture) }
    [Convert]::ToString($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Get-SanitizedUrl {
    param([string] $Url)
    $builder = [UriBuilder]::new([Uri]$Url)
    $builder.Query = ''
    $builder.Fragment = ''
    $builder.UserName = ''
    $builder.Password = ''
    $builder.Uri.AbsoluteUri.TrimEnd('?')
}

function Get-ArchiveEvidence {
    param([string] $Path)
    Invoke-Heartbeat
    $bytes = [byte[]]::new(8)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $size = $stream.Length
        $read = $stream.Read($bytes, 0, $bytes.Length)
        $stream.Position = 0
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $readCount)
            Invoke-Heartbeat
        }
        $sha256 = [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
    $format = if ($read -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and
        (($bytes[2] -eq 0x03 -and $bytes[3] -eq 0x04) -or ($bytes[2] -eq 0x05 -and $bytes[3] -eq 0x06) -or ($bytes[2] -eq 0x07 -and $bytes[3] -eq 0x08))) {
        'zip'
    }
    elseif ($read -ge 7 -and $bytes[0] -eq 0x52 -and $bytes[1] -eq 0x61 -and $bytes[2] -eq 0x72 -and
        $bytes[3] -eq 0x21 -and $bytes[4] -eq 0x1A -and $bytes[5] -eq 0x07 -and $bytes[6] -in @(0x00, 0x01)) {
        'rar'
    }
    elseif ($read -ge 6 -and $bytes[0] -eq 0x37 -and $bytes[1] -eq 0x7A -and $bytes[2] -eq 0xBC -and
        $bytes[3] -eq 0xAF -and $bytes[4] -eq 0x27 -and $bytes[5] -eq 0x1C) {
        '7z'
    }
    else { 'unknown' }
    [ordered]@{ size = [int64]$size; sha256 = $sha256; archiveFormat = $format }
}

function Assert-NoReparsePath {
    param([string] $Path, [string] $Root, [string] $Label)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if (-not $pathFull.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -and
        -not $pathFull.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escapes the source run root."
    }
    $current = $pathFull
    for ($depth = 0; $depth -lt 2048; $depth++) {
        if (-not (Test-Path -LiteralPath $current)) { throw "$Label path component is missing." }
        if ((Get-Item -LiteralPath $current).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "$Label path contains a symlink or reparse point."
        }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $pathFull }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent)) { throw "Unable to prove $Label physical containment." }
        $current = $parent
    }
    throw "Unable to prove $Label physical containment within 2048 path components."
}

function ConvertTo-ReceiptTimestamp {
    param($Value)
    if ($Value -is [DateTimeOffset]) { return [DateTimeOffset]$Value }
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new([DateTime]$Value) }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact([string]$Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        throw 'Source receipt stability timestamp is not an ISO-8601 round-trip value.'
    }
    $parsed
}

function Assert-StableObservations {
    param([Collections.IDictionary] $Receipt)
    $stableObservations = @($Receipt.stableObservations)
    $stableObservationsValid = $stableObservations.Count -eq 2
    $lastWriteTimeValues = [Collections.Generic.List[DateTimeOffset]]::new()
    $observedAtValues = [Collections.Generic.List[DateTimeOffset]]::new()
    if ($stableObservationsValid) {
        foreach ($observation in $stableObservations) {
            if ($observation -isnot [Collections.IDictionary] -or
                -not $observation.Contains('size') -or -not $observation.Contains('lastWriteTimeUtc') -or -not $observation.Contains('observedAt') -or
                [int64]$observation.size -ne [int64]$Receipt.size -or [int64]$observation.size -le 0) {
                $stableObservationsValid = $false
                break
            }
            try {
                $lastWriteTime = ConvertTo-ReceiptTimestamp -Value $observation.lastWriteTimeUtc
                $observedAt = ConvertTo-ReceiptTimestamp -Value $observation.observedAt
            }
            catch {
                $stableObservationsValid = $false
                break
            }
            $lastWriteTimeValues.Add($lastWriteTime)
            $observedAtValues.Add($observedAt)
        }
    }
    if (-not $stableObservationsValid -or
        $lastWriteTimeValues[0] -ne $lastWriteTimeValues[1] -or
        $observedAtValues[0] -gt $observedAtValues[1]) {
        throw 'Source receipt does not contain two matching stability observations.'
    }
}

$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
$requestFull = [IO.Path]::GetFullPath($SourceRequestPath)
$receiptParent = Split-Path -Parent $receiptFull
$sourceRunRoot = if (-not [string]::IsNullOrWhiteSpace($RunRoot)) { [IO.Path]::GetFullPath($RunRoot) }
    elseif ((Split-Path -Leaf $receiptParent) -ceq 'review-artifacts') { Split-Path -Parent $receiptParent }
    else { $receiptParent }
if (-not (Test-Path -LiteralPath $sourceRunRoot -PathType Container)) { throw 'Source receipt run root does not exist.' }
$null = Assert-NoReparsePath -Path $sourceRunRoot -Root $sourceRunRoot -Label 'Source run root'
$null = Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt'
$null = Assert-NoReparsePath -Path $requestFull -Root $sourceRunRoot -Label 'Source request'
if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
    if ($receiptFull -cne [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'review-artifacts/source-receipt.json')) -or
        $requestFull -cne [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'review-artifacts/source-request.json'))) {
        throw 'Source receipt verification requires the fixed run-local review artifact paths.'
    }
}
$null = Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt'
$receipt = Get-Content -LiteralPath $receiptFull -Raw | ConvertFrom-Json -AsHashtable
$null = Assert-NoReparsePath -Path $requestFull -Root $sourceRunRoot -Label 'Source request'
$request = Get-Content -LiteralPath $requestFull -Raw | ConvertFrom-Json -AsHashtable
if ([int]$receipt.schemaVersion -ne 1) { throw 'Source receipt schemaVersion must be 1.' }
if ([int]$request.schemaVersion -notin @(1, 2)) { throw 'Source request schemaVersion must be 1 or 2.' }
$receiptStatus = [string]$receipt.status
$isRetainedNonDelivered = $receiptStatus -in @('unsupported', 'rejected')
if ($receiptStatus -cne 'delivered' -and (-not $AllowNonDelivered -or -not $isRetainedNonDelivered)) {
    throw 'Source receipt is not in delivered state.'
}
foreach ($field in @('gameDomain', 'modId', 'mainFileId', 'version', 'fileName')) {
    if ((ConvertTo-InvariantString $receipt.sourceRequest[$field]) -cne (ConvertTo-InvariantString $request[$field])) {
        throw "Source receipt $field does not match the immutable source request."
    }
}
if ([int]$request.schemaVersion -eq 2) {
    foreach ($field in @('pageUrl', 'pageVersion', 'pageUpdatedAt', 'mainFileUploadedAtUtc')) {
        if (-not $request.Contains($field) -or [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $request[$field])) -or
            -not $receipt.sourceRequest.Contains($field) -or
            (ConvertTo-InvariantString $receipt.sourceRequest[$field]) -cne (ConvertTo-InvariantString $request[$field])) {
            throw "Source receipt $field does not match the complete immutable source request."
        }
    }
    foreach ($timestampField in @('pageUpdatedAt', 'mainFileUploadedAtUtc')) {
        $timestamp = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact(
            (ConvertTo-InvariantString $request[$timestampField]),
            'o',
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$timestamp
        )) { throw "Source request $timestampField is not an ISO-8601 round-trip value." }
    }
}
$sourceUri = [Uri]$receipt.sourceUrl
if (-not $sourceUri.IsAbsoluteUri -or $sourceUri.Scheme -cne 'https' -or $sourceUri.Query -or $sourceUri.Fragment -or -not [string]::IsNullOrWhiteSpace($sourceUri.UserInfo)) {
    throw 'Source receipt URL is not sanitized.'
}
$requestUri = [Uri](ConvertTo-InvariantString $request.pageUrl)
if (-not $requestUri.IsAbsoluteUri -or $requestUri.Scheme -cne 'https' -or
    -not [string]::IsNullOrEmpty($requestUri.UserInfo) -or -not [string]::IsNullOrEmpty($requestUri.Query) -or
    -not [string]::IsNullOrEmpty($requestUri.Fragment) -or -not $requestUri.IsDefaultPort) {
    throw 'Source request pageUrl must be a canonical page URL without user-info, query, fragment, or a custom port.'
}
$expectedGameDomain = 'warhammer40kdarktide'
$expectedPagePath = "/$expectedGameDomain/mods/$(ConvertTo-InvariantString $request.modId)"
if ((ConvertTo-InvariantString $request.gameDomain) -cne $expectedGameDomain -or
    $requestUri.Host -notin @('nexusmods.com', 'www.nexusmods.com') -or
    $requestUri.AbsolutePath.TrimEnd('/') -cne $expectedPagePath) {
    throw 'Source request does not identify the official Nexus MOD page for warhammer40kdarktide.'
}
$requestedFileName = ConvertTo-InvariantString $request.fileName
if ([IO.Path]::GetFileName($requestedFileName) -cne $requestedFileName -or
    $requestedFileName.TrimEnd([char[]]' .') -cne $requestedFileName -or
    $requestedFileName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) {
    throw 'Source request fileName is not one safe single file name.'
}
if ($requestedFileName -match '(?i)^(con|prn|aux|nul|clock\$|conin\$|conout\$|com[1-9¹²³]|lpt[1-9¹²³])(?:\..*)?$') {
    throw 'Source request fileName uses a reserved Windows device name.'
}
$requestOfficialSha256 = if ($request.Contains('officialSha256') -and
    -not [string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $request.officialSha256))) {
    (ConvertTo-InvariantString $request.officialSha256).ToLowerInvariant()
} else { $null }
if ($null -ne $requestOfficialSha256 -and $requestOfficialSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Source request official SHA-256 is invalid.'
}
if (-not $receipt.Contains('officialSha256') -or -not $receipt.Contains('officialHashPassed')) {
    throw 'Source receipt official SHA-256 evidence is missing.'
}
$receiptOfficialSha256 = if ([string]::IsNullOrWhiteSpace((ConvertTo-InvariantString $receipt.officialSha256))) {
    $null
} else { (ConvertTo-InvariantString $receipt.officialSha256).ToLowerInvariant() }
if ($receiptOfficialSha256 -cne $requestOfficialSha256) {
    throw 'Source receipt official SHA-256 does not match the immutable source request.'
}
if ([string]$receipt.sourceUrl -cne (Get-SanitizedUrl -Url (ConvertTo-InvariantString $request.pageUrl))) {
    throw 'Source receipt URL does not match the sanitized source request pageUrl.'
}
if ([string]$receipt.provider -notin @('api', 'browser')) { throw 'Source receipt provider is unsupported.' }
foreach ($timing in @('downloadMilliseconds', 'waitingMilliseconds', 'verifyMilliseconds', 'deliverMilliseconds')) {
    if (-not $receipt.timings.Contains($timing) -or [int64]$receipt.timings[$timing] -lt 0) { throw "Source receipt $timing is invalid." }
}
Assert-StableObservations -Receipt $receipt
if ($isRetainedNonDelivered) {
    if ([string]::IsNullOrWhiteSpace($RetainedPath)) { throw 'Retained non-delivered receipt verification requires RetainedPath.' }
    if ([IO.Path]::GetExtension($requestedFileName).ToLowerInvariant() -cne '.zip') {
        throw 'Retained non-delivered receipt requires an originally eligible ZIP filename.'
    }
    $retainedFull = [IO.Path]::GetFullPath($RetainedPath)
    $null = Assert-NoReparsePath -Path $retainedFull -Root $sourceRunRoot -Label 'Retained source'
    $retainedParent = Split-Path -Parent $retainedFull
    if (-not (Test-Path -LiteralPath $retainedFull -PathType Leaf) -or
        (Split-Path -Leaf $retainedParent).StartsWith('.incoming-', [StringComparison]::Ordinal) -ne $true -or
        [IO.Path]::GetFullPath((Split-Path -Parent $retainedParent)) -cne $sourceRunRoot) {
        throw 'Retained source is outside a fixed run-local incoming directory.'
    }
    $archiveEvidence = Get-ArchiveEvidence -Path $retainedFull
    if ([int64]$archiveEvidence.size -ne [int64]$receipt.size -or
        [string]$archiveEvidence.sha256 -cne [string]$receipt.sha256 -or
        [string]$archiveEvidence.archiveFormat -cne [string]$receipt.archiveFormat -or
        [IO.Path]::GetFileName($retainedFull) -cne [string]$receipt.filename) {
        throw 'Retained source bytes do not match the non-delivered receipt.'
    }
    $actualOfficialHashPassed = if ($null -ne $requestOfficialSha256) { [string]$archiveEvidence.sha256 -ceq $requestOfficialSha256 } else { $null }
    if ($receipt.officialHashPassed -ne $actualOfficialHashPassed) {
        throw 'Retained source official SHA-256 result differs from the receipt.'
    }
    $filenameMismatch = [string]$receipt.filename -cne $requestedFileName
    $hashMismatch = $null -ne $requestOfficialSha256 -and -not $actualOfficialHashPassed
    $recoveryResult = if ($receiptStatus -ceq 'unsupported') {
        if ([string]$archiveEvidence.archiveFormat -ceq 'zip') { throw 'Unsupported source receipt contains ZIP bytes.' }
        [ordered]@{
            result = 'waiting'; status = 'waiting-user'
            waitingReason = [ordered]@{ code = 'unsupported_archive_format'; message = "Detected unsupported $($archiveEvidence.archiveFormat) archive bytes after download." }
            archiveFormat = [string]$archiveEvidence.archiveFormat; retainedPath = $retainedFull
        }
    }
    else {
        if ([string]$archiveEvidence.archiveFormat -cne 'zip' -or (-not $hashMismatch -and -not $filenameMismatch)) {
            throw 'Rejected source receipt has no reproducible hash or filename mismatch.'
        }
        if ($hashMismatch) {
            [ordered]@{
                result = 'blocked'; status = 'blocked'
                waitingReason = [ordered]@{ code = 'source_hash_mismatch'; message = 'Downloaded SHA-256 does not match the official hash.' }
                retainedPath = $retainedFull
            }
        }
        else {
            [ordered]@{
                result = 'blocked'; status = 'blocked'
                waitingReason = [ordered]@{ code = 'source_filename_mismatch'; message = 'Downloaded filename does not match the requested Main file.' }
                retainedPath = $retainedFull
            }
        }
    }
    $result = [ordered]@{
        result = 'passed'; receiptPath = $receiptFull; receiptSha256 = $null
        retainedPath = $retainedFull; retainedSha256 = [string]$archiveEvidence.sha256
        receiptStatus = $receiptStatus; recoveryResult = $recoveryResult
    }
    $null = Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt'
    $result.receiptSha256 = Get-FileSha256 -Path $receiptFull
    if ($PassThru) { $result } else { $result | ConvertTo-Json -Depth 10 -Compress }
    return
}
$deliveredPath = [IO.Path]::GetFullPath([string]$receipt.deliveredPath)
$null = Assert-NoReparsePath -Path $deliveredPath -Root $sourceRunRoot -Label 'Delivered source'
if (-not [string]::IsNullOrWhiteSpace($RunRoot)) {
    $verifiedRoot = [IO.Path]::GetFullPath((Join-Path $sourceRunRoot 'verified-source')).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not $deliveredPath.StartsWith($verifiedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Delivered source escapes the fixed run-local verified-source directory.'
    }
}
$null = Assert-NoReparsePath -Path $deliveredPath -Root $sourceRunRoot -Label 'Delivered source'
$archiveEvidence = Get-ArchiveEvidence -Path $deliveredPath
if ([int64]$archiveEvidence.size -ne [int64]$receipt.size) { throw 'Delivered source size does not match the receipt.' }
$actualSha256 = [string]$archiveEvidence.sha256
if ($actualSha256 -cne [string]$receipt.sha256) { throw 'Delivered source SHA-256 does not match the receipt.' }
if ([string]$receipt.archiveFormat -cne 'zip' -or [string]$archiveEvidence.archiveFormat -cne 'zip') { throw 'Delivered source is not a ZIP archive.' }
if ([IO.Path]::GetFileName($deliveredPath) -cne [string]$receipt.filename -or $receipt.filename -cne (ConvertTo-InvariantString $request.fileName)) {
    throw 'Delivered source filename does not match the receipt and request.'
}
if ($null -ne $requestOfficialSha256) {
    if ($receipt.officialHashPassed -ne $true -or $actualSha256 -cne $requestOfficialSha256) {
        throw 'Delivered source does not match the recorded official SHA-256.'
    }
}
elseif ($null -ne $receipt.officialHashPassed) { throw 'Source receipt records an unexpected official SHA-256 result.' }

$result = [ordered]@{
    result = 'passed'
    receiptPath = $receiptFull
    receiptSha256 = $null
    deliveredPath = $deliveredPath
    deliveredSha256 = $actualSha256
}
$null = Assert-NoReparsePath -Path $receiptFull -Root $sourceRunRoot -Label 'Source receipt'
$result.receiptSha256 = Get-FileSha256 -Path $receiptFull
if ($PassThru) { $result } else { $result | ConvertTo-Json -Depth 10 -Compress }
