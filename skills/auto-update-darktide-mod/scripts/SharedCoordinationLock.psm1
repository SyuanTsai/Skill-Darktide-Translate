# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:pathSafetyModule = Import-Module (Join-Path $PSScriptRoot 'PathSafety.psm1') -Force -PassThru -ErrorAction Stop

function ConvertFrom-JsonToken {
    param(
        [AllowNull()][Newtonsoft.Json.Linq.JToken] $Token,
        [switch] $AsHashtable
    )
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

function Get-CoordinationUtcTimestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Get-CoordinationActorToken {
    param([Parameter(Mandatory)][string] $RunId, [Parameter(Mandatory)][string] $ResourceKey)
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes("coordination:${ResourceKey}:$RunId")
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant().Substring(0, 32)
}

function Open-CoordinationPrivateDirectory {
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][string] $RelativePath
    )
    $rootFull = Resolve-PortableTrustedRoot -Path $Root
    $directory = Resolve-PortableContainedPath -Root $rootFull -Path $RelativePath
    [void][IO.Directory]::CreateDirectory($directory)
    if (-not [IO.Directory]::Exists($directory)) {
        throw 'Shared coordination receipt root is not a directory.'
    }
    $directory
}

function Assert-CoordinationPath {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [switch] $AllowMissing
    )
    $repository = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $repository + [IO.Path]::DirectorySeparatorChar
    $comparison = Get-PortablePathComparison -Paths @($repository, $fullPath)
    if (-not $fullPath.Equals($repository, $comparison) -and
        -not $fullPath.StartsWith($prefix, $comparison)) {
        throw 'Shared coordination path escapes the repository root.'
    }
    $current = $fullPath
    for ($depth = 0; $depth -lt 2048; $depth++) {
        if (Test-Path -LiteralPath $current) {
            if (Test-PortableReparseItem -Path $current -Item (Get-Item -LiteralPath $current -Force) -Label 'Shared coordination' -TrustedRoot $repository) {
                throw 'Shared coordination path contains a symlink or reparse point.'
            }
        }
        else {
            if (Test-PortableReparseItem -Path $current -Label 'Shared coordination' -TrustedRoot $repository) {
                throw 'Shared coordination path contains a symlink or reparse point.'
            }
            if (-not $AllowMissing) {
                throw 'Shared coordination path is missing.'
            }
        }
        if ($current.Equals($repository, $comparison)) { return $fullPath }
        $parent = [IO.DirectoryInfo]::new($current).Parent
        if ($null -eq $parent) { break }
        $current = $parent.FullName
    }
    throw 'Unable to prove shared coordination path containment.'
}

function Write-CoordinationAtomicJson {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Value)
    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($Path))
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = Join-Path $parent ('.tmp-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json -AsHashtable
        [IO.File]::Move($temporary, [IO.Path]::GetFullPath($Path), $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { [IO.File]::Delete($temporary) }
    }
}

function Start-SharedCoordinationAcquisitionAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][ValidateSet('source-acquisition', 'git-coordination')][string] $ResourceKey,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $RunId,
        [string] $ReceiptRoot
    )
    $repository = Resolve-PortableTrustedRoot -Path ([IO.Path]::GetFullPath($RepositoryRoot))
    $logicalRoot = if ([string]::IsNullOrWhiteSpace($ReceiptRoot)) {
        Join-Path $repository ("AI Auto Update/In Progress/.coordination-attempts/$RunId")
    }
    else { [IO.Path]::GetFullPath($ReceiptRoot) }
    $null = Assert-CoordinationPath -Path $logicalRoot -RepositoryRoot $repository -AllowMissing
    $relativeRoot = [IO.Path]::GetRelativePath($repository, $logicalRoot)
    $attemptRoot = if ($relativeRoot -ceq '.') { $repository } else {
        Open-CoordinationPrivateDirectory -Root $repository -RelativePath $relativeRoot
    }
    $attemptDirectory = Open-CoordinationPrivateDirectory -Root $attemptRoot -RelativePath 'coordination-locks'
    $recordPath = Join-Path $attemptDirectory "$ResourceKey-acquisition-attempt.json"
    $guard = Enter-PortableFileLock -Root $attemptDirectory -Leaf "$ResourceKey-acquisition-attempt.guard" `
        -TimeoutMilliseconds 15000 -Label "$ResourceKey acquisition attempt journal"
    try {
        $record = if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
            Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable
        }
        else { $null }
        if ($record) {
            if (@($record.Keys).Count -ne 7 -or [int]$record.schemaVersion -ne 1 -or
                [string]$record.resourceKey -cne $ResourceKey -or [string]$record.runId -cne $RunId -or
                [string]$record.attemptToken -notmatch '^[0-9a-f]{32}$' -or
                [string]$record.status -notin @('pending', 'acquired') -or
                [string]$record.createdAt -notmatch '^\d{4}-\d{2}-\d{2}T' -or
                [string]$record.updatedAt -notmatch '^\d{4}-\d{2}-\d{2}T') {
                throw 'Shared coordination acquisition attempt journal is invalid.'
            }
        }
        $now = Get-CoordinationUtcTimestamp
        if ($record -and [string]$record.status -ceq 'pending') {
            $attemptToken = [string]$record.attemptToken
            $createdAt = [string]$record.createdAt
        }
        else {
            $attemptToken = [guid]::NewGuid().ToString('N')
            $createdAt = $now
        }
        $pending = [ordered]@{
            schemaVersion = 1
            resourceKey = $ResourceKey
            runId = $RunId
            attemptToken = $attemptToken
            status = 'pending'
            createdAt = $createdAt
            updatedAt = $now
        }
        Write-CoordinationAtomicJson -Path $recordPath -Value $pending
        [ordered]@{
            path = [IO.Path]::GetFullPath($recordPath)
            attemptToken = $attemptToken
            resourceKey = $ResourceKey
            runId = $RunId
        }
    }
    finally { $guard.Dispose() }
}

function Complete-SharedCoordinationAcquisitionAttempt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary] $Attempt)
    foreach ($field in @('path', 'attemptToken', 'resourceKey', 'runId')) {
        if (-not $Attempt.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$Attempt[$field])) {
            throw "Shared coordination acquisition attempt is missing $field."
        }
    }
    $recordPath = [IO.Path]::GetFullPath([string]$Attempt.path)
    $attemptDirectory = Split-Path -Parent $recordPath
    $resourceKey = [string]$Attempt.resourceKey
    $guard = Enter-PortableFileLock -Root $attemptDirectory -Leaf "$resourceKey-acquisition-attempt.guard" `
        -TimeoutMilliseconds 15000 -Label "$resourceKey acquisition attempt journal"
    try {
        $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json -AsHashtable
        if ([int]$record.schemaVersion -ne 1 -or [string]$record.resourceKey -cne $resourceKey -or
            [string]$record.runId -cne [string]$Attempt.runId -or
            [string]$record.attemptToken -cne [string]$Attempt.attemptToken -or
            [string]$record.status -notin @('pending', 'acquired')) {
            throw 'Shared coordination acquisition attempt journal changed before completion.'
        }
        if ([string]$record.status -ceq 'pending') {
            $record.status = 'acquired'
            $record.updatedAt = Get-CoordinationUtcTimestamp
            Write-CoordinationAtomicJson -Path $recordPath -Value $record
        }
    }
    finally { $guard.Dispose() }
}

function Get-CoordinationFileSha256 {
    param([Parameter(Mandatory)][string] $Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $hasher = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        $buffer = [byte[]]::new(1MB)
        while (($readCount = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $hasher.AppendData($buffer, 0, $readCount)
        }
        [Convert]::ToHexString($hasher.GetHashAndReset()).ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
        $stream.Dispose()
    }
}

function Get-CoordinationProcessIdentity {
    $process = Get-Process -Id $PID -ErrorAction Stop
    [ordered]@{
        machineName = [Environment]::MachineName
        processId = $PID
        processStartTicks = $process.StartTime.ToUniversalTime().Ticks
    }
}

function Get-CoordinationProcessStartToleranceTicks {
    # Windows reports the kernel creation FILETIME, so the recorded value is
    # exact. On Linux .NET derives StartTime from /proc starttime plus a boot
    # time recomputed from the wall clock at every query, so NTP slew or clock
    # adjustment makes later reads of the SAME live process drift. macOS uses
    # the proc_pidinfo start timestamp but is treated the same way for safety.
    # A tolerant match can only keep a lock held longer (the heartbeat still
    # expires it); an exact match could steal a live owner's lock.
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { return [int64]0 }
    [TimeSpan]::FromSeconds(10).Ticks
}

function Test-CoordinationProcessStartMatch {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][int64] $ActualTicks,
        [Parameter(Mandatory)][int64] $ExpectedTicks
    )
    if ($ActualTicks -le 0 -or $ExpectedTicks -le 0) { return $false }
    [Math]::Abs([decimal]$ActualTicks - [decimal]$ExpectedTicks) -le [decimal](Get-CoordinationProcessStartToleranceTicks)
}

function Test-CoordinationProcessActive {
    param([Parameter(Mandatory)][Collections.IDictionary] $Owner)
    if ([string]$Owner.machineName -cne [Environment]::MachineName) {
        return $false
    }
    $process = Get-Process -Id ([int]$Owner.processId) -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try { $actualStartTicks = $process.StartTime.ToUniversalTime().Ticks }
    catch { return $false }
    if (-not (Test-CoordinationProcessStartMatch -ActualTicks $actualStartTicks -ExpectedTicks ([int64]$Owner.processStartTicks))) {
        return $false
    }
    $true
}

function Enter-CoordinationOwnerGuard {
    param([Parameter(Mandatory)][string] $LockRoot, [Parameter(Mandatory)][string] $ResourceKey)
    $namespaceGuardLeaf = 'shared-owner-update.guard'
    $guardLeaf = "$ResourceKey.owner-update.guard"
    $namespaceGuardPath = Join-Path $LockRoot $namespaceGuardLeaf
    $guardPath = Join-Path $LockRoot $guardLeaf
    $null = Assert-CoordinationPath -Path $namespaceGuardPath -RepositoryRoot $LockRoot -AllowMissing
    $null = Assert-CoordinationPath -Path $guardPath -RepositoryRoot $LockRoot -AllowMissing
    # The short owner guards use the same FileShare.None primitive on every
    # supported host, and the namespace guard serializes residue inspection.
    $namespaceGuard = $null
    $resourceGuard = $null
    try {
        $namespaceGuard = Enter-PortableFileLock -Root $LockRoot -Leaf $namespaceGuardLeaf `
            -TimeoutMilliseconds 15000 -Label 'shared owner update namespace guard'
        $resourceGuard = Enter-PortableFileLock -Root $LockRoot -Leaf $guardLeaf `
            -TimeoutMilliseconds 15000 -Label "$ResourceKey owner update guard"
    }
    catch [TimeoutException] {
        if ($null -ne $resourceGuard) { $resourceGuard.Dispose() }
        if ($null -ne $namespaceGuard) { $namespaceGuard.Dispose() }
        throw "Unable to acquire the short $ResourceKey owner update guard."
    }
    catch {
        if ($null -ne $resourceGuard) { $resourceGuard.Dispose() }
        if ($null -ne $namespaceGuard) { $namespaceGuard.Dispose() }
        throw
    }
    $handle = [pscustomobject][ordered]@{
        NamespaceGuard = $namespaceGuard
        ResourceGuard = $resourceGuard
    }
    $handle | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        if ($null -ne $this.ResourceGuard) {
            $this.ResourceGuard.Dispose()
            $this.ResourceGuard = $null
        }
        if ($null -ne $this.NamespaceGuard) {
            $this.NamespaceGuard.Dispose()
            $this.NamespaceGuard = $null
        }
    }
    $handle
}

function Get-CoordinationPublicationContentionKind {
    [OutputType([string])]
    param([Parameter(Mandatory)] $Failure)

    $exception = if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure.Exception } else { $Failure }
    for ($depth = 0; $depth -lt 32 -and $null -ne $exception; $depth++) {
        if ($exception.Data.Contains('PortablePublicationKind')) {
            $kind = [string]$exception.Data['PortablePublicationKind']
            if ($kind -in @('no-replace-target-exists', 'cas-expected-state-mismatch')) { return $kind }
        }
        $exception = $exception.InnerException
    }
    $null
}

function Assert-CoordinationOwner {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Owner,
        [Parameter(Mandatory)][string] $ResourceKey
    )
    foreach ($field in @('schemaVersion', 'state', 'resourceKey', 'owner', 'expiresAt', 'platform', 'lockPrimitive')) {
        if (-not $Owner.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$Owner[$field])) {
            throw "Existing $ResourceKey coordination lock owner is missing $field."
        }
    }
    if ($Owner.owner -isnot [Collections.IDictionary]) {
        throw "Existing $ResourceKey coordination lock owner contract is invalid."
    }
    foreach ($field in @('runId', 'machineName', 'processId', 'processStartTicks', 'token', 'acquiredAt', 'heartbeat')) {
        if (-not $Owner.owner.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$Owner.owner[$field])) {
            throw "Existing $ResourceKey coordination lock owner is missing $field."
        }
    }
    $parsedSchemaVersion = 0
    $parsedProcessId = 0
    $parsedProcessStartTicks = [int64]0
    if (-not [int]::TryParse([string]$Owner.schemaVersion, [ref]$parsedSchemaVersion) -or $parsedSchemaVersion -ne 2 -or
        [string]$Owner.state -notin @('held', 'released') -or
        -not [int]::TryParse([string]$Owner.owner.processId, [ref]$parsedProcessId) -or $parsedProcessId -le 0 -or
        -not [int64]::TryParse([string]$Owner.owner.processStartTicks, [ref]$parsedProcessStartTicks) -or $parsedProcessStartTicks -le 0 -or
        [string]$Owner.owner.runId -notmatch '^[A-Za-z0-9._-]+$' -or
        [string]$Owner.resourceKey -cne $ResourceKey -or
        [string]$Owner.platform -notin @('windows', 'linux', 'macos') -or
        [string]$Owner.lockPrimitive -cne 'dotnet-fileshare-none' -or
        [string]$Owner.owner.token -notmatch '^[0-9a-f]{32}$') {
        throw "Existing $ResourceKey coordination lock owner contract is invalid."
    }
    foreach ($timestampValue in @($Owner.owner.acquiredAt, $Owner.owner.heartbeat, $Owner.expiresAt)) {
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact(
            [string]$timestampValue, 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed
        )) { throw "Existing $ResourceKey coordination lock timestamp is invalid." }
    }
    if ([string]$Owner.state -ceq 'released') {
        foreach ($field in @('releasedByOwnerToken', 'releaseReceiptPath', 'releaseReceiptSha256', 'coordinationReceiptId', 'coordinationCompletedAt')) {
            if (-not $Owner.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$Owner[$field])) {
                throw "Existing $ResourceKey released coordination lock is missing $field."
            }
        }
        $completedAt = [DateTimeOffset]::MinValue
        if ([string]$Owner.releasedByOwnerToken -cne [string]$Owner.owner.token -or
            [string]$Owner.releaseReceiptSha256 -notmatch '^[0-9a-f]{64}$' -or
            [string]$Owner.coordinationReceiptId -notmatch '^[0-9a-f]{32}$' -or
            -not [DateTimeOffset]::TryParseExact([string]$Owner.coordinationCompletedAt, 'o', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$completedAt)) {
            throw "Existing $ResourceKey released coordination lock receipt tuple is invalid."
        }
    }
}

function Test-CoordinationLeaseMatchesOwner {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Lease,
        [Parameter(Mandatory)][Collections.IDictionary] $Owner
    )
    [string]$Owner.state -ceq 'held' -and
        [string]$Owner.owner.runId -ceq [string]$Lease.runId -and
        [string]$Owner.resourceKey -ceq [string]$Lease.resourceKey -and
        [string]$Owner.owner.token -ceq [string]$Lease.token -and
        [string]$Owner.owner.machineName -ceq [string]$Lease.machineName -and
        [int]$Owner.owner.processId -eq [int]$Lease.processId -and
        [int64]$Owner.owner.processStartTicks -eq [int64]$Lease.processStartTicks -and
        [string]$Owner.platform -ceq [string]$Lease.platform -and
        [string]$Owner.lockPrimitive -ceq [string]$Lease.lockPrimitive
}

function Get-CoordinationLeaseSnapshot {
    param([string] $LockRoot, [string] $ResourceKey)
    $leaf = "$ResourceKey.lock"
    $lockPath = Join-Path $LockRoot $leaf
    $migration = "Legacy coordination lease directory format detected at '$lockPath'. Stop all owners, move this directory to a preserved evidence location outside .locks, verify the original path is absent, then rerun. Automatic deletion or migration is forbidden."
    $snapshot = Get-PortableLeaseFileState -ParentPath $LockRoot -Leaf $leaf -AllowMissing -LegacyDirectoryMessage $migration
    if (-not [bool]$snapshot.exists) { return $snapshot }
    try {
        $snapshot['value'] = [Text.UTF8Encoding]::new($false, $true).GetString([byte[]]$snapshot.bytes) |
            ConvertFrom-Json -AsHashtable
    }
    catch { throw "Existing $ResourceKey coordination lock owner is unreadable; preserve it for explicit recovery." }
    $snapshot
}

function Publish-CoordinationLeaseSnapshot {
    param(
        [string] $LockRoot,
        [string] $ResourceKey,
        [Collections.IDictionary] $Value,
        [Collections.IDictionary] $ExpectedState,
        [switch] $NoReplace,
        [switch] $PreserveDisplaced
    )
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 30 -Compress) + "`n")
    $publicationParameters = @{
        ParentPath = $LockRoot
        Leaf = "$ResourceKey.lock"
        Bytes = $bytes
        ExpectedState = $ExpectedState
        NoReplace = [bool]$NoReplace
        PreserveDisplaced = [bool]$PreserveDisplaced
    }
    Publish-PortableLeaseFile @publicationParameters
}

function Get-CoordinationTakeoverEvidence {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Owner,
        [Parameter(Mandatory)][string] $LockRoot
    )
    if (-not $Owner.Contains('takeover') -or $Owner.takeover -isnot [Collections.IDictionary]) {
        return [ordered]@{ path = $null; waitingMilliseconds = 0 }
    }
    $takeover = $Owner.takeover
    if ([string]$takeover.staleSha256 -notmatch '^[0-9a-f]{64}$' -or
        [int64]$takeover.staleLength -lt 1 -or
        [string]$takeover.evidenceLeaf -notmatch '^\.[A-Za-z0-9._-]+\.lock\.stale-[0-9a-f]{64}\.json$' -or
        [int64]$takeover.waitingMilliseconds -lt 0) {
        throw 'Persisted coordination takeover metadata is invalid.'
    }
    $path = Resolve-PortableContainedPath -Root $LockRoot -Path ([string]$takeover.evidenceLeaf)
    $evidence = Get-PortableLeaseFileState -ParentPath (Split-Path -Parent $path) -Leaf (Split-Path -Leaf $path)
    if ([string]$evidence.sha256 -cne [string]$takeover.staleSha256 -or
        [int64]$evidence.length -ne [int64]$takeover.staleLength) {
        throw 'Stale coordination evidence differs from the persisted takeover metadata.'
    }
    [ordered]@{ path = $path; waitingMilliseconds = [int64]$takeover.waitingMilliseconds }
}

function Invoke-CoordinationFaultInjection {
    param([Parameter(Mandatory)][string] $Point)
    $hook = Get-Variable -Name CoordinationFaultInjectionHook -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($hook -is [scriptblock]) { & $hook $Point }
}

function Write-CoordinationReceipt {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Lease,
        [Parameter(Mandatory)][string] $Disposition
    )
    if ([string]::IsNullOrWhiteSpace([string]$Lease.receiptRoot)) { return $null }
    $receiptRoot = Resolve-PortableTrustedRoot -Path ([string]$Lease.receiptRoot)
    $receiptDirectory = Join-Path $receiptRoot 'coordination-locks'
    $null = Assert-CoordinationPath -Path $receiptDirectory -RepositoryRoot $receiptRoot -AllowMissing
    New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    $null = Assert-CoordinationPath -Path $receiptDirectory -RepositoryRoot $receiptRoot
    $receiptDirectory = Resolve-PortableTrustedRoot -Path $receiptDirectory
    $receiptPath = Join-Path $receiptDirectory ('{0}-{1}.json' -f ([string]$Lease.resourceKey), ([string]$Lease.receiptId))
    $null = Assert-CoordinationPath -Path $receiptPath -RepositoryRoot $receiptDirectory -AllowMissing
    $receipt = [ordered]@{
        schemaVersion = 1
        runId = $Lease.runId
        resourceKey = $Lease.resourceKey
        lockPath = $Lease.path
        machineName = $Lease.machineName
        processId = $Lease.processId
        processStartTicks = $Lease.processStartTicks
        token = $Lease.token
        acquiredAt = $Lease.acquiredAt
        completedAt = if ($Lease.Contains('completedAt')) { $Lease.completedAt } else { Get-CoordinationUtcTimestamp }
        disposition = $Disposition
        staleEvidencePath = $Lease.staleEvidencePath
        platform = $Lease.platform
        lockPrimitive = $Lease.lockPrimitive
    }
    [byte[]]$expectedBytes = [Text.UTF8Encoding]::new($false).GetBytes(($receipt | ConvertTo-Json -Depth 30))
    $receiptSnapshot = Get-PortableLeaseFileState -ParentPath $receiptDirectory -Leaf ([IO.Path]::GetFileName($receiptPath)) -AllowMissing
    if ([bool]$receiptSnapshot.exists) {
        if ([Convert]::ToHexString([byte[]]$receiptSnapshot.bytes) -cne [Convert]::ToHexString($expectedBytes)) {
            throw 'Existing coordination receipt differs from the immutable release tuple.'
        }
    }
    else { Write-CoordinationAtomicJson -Path $receiptPath -Value $receipt }
    [ordered]@{
        path = [IO.Path]::GetFullPath($receiptPath)
        sha256 = Get-CoordinationFileSha256 -Path $receiptPath
        resourceKey = [string]$Lease.resourceKey
    }
}

function Get-CoordinationTerminalReceipt {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Lease,
        [Parameter(Mandatory)][string] $LockRoot,
        [switch] $Publish
    )
    $leaf = ('{0}.released-{1}.json' -f ([string]$Lease.resourceKey), ([string]$Lease.token))
    $value = [ordered]@{
        schemaVersion = 1
        disposition = 'released'
        runId = [string]$Lease.runId
        resourceKey = [string]$Lease.resourceKey
        ownerToken = [string]$Lease.token
    }
    [byte[]]$bytes = [Text.UTF8Encoding]::new($false).GetBytes(($value | ConvertTo-Json -Depth 10 -Compress) + "`n")
    $snapshot = Get-PortableLeaseFileState -ParentPath $LockRoot -Leaf $leaf -AllowMissing
    if ([bool]$snapshot.exists) {
        if ([Convert]::ToHexString([byte[]]$snapshot.bytes) -cne [Convert]::ToHexString($bytes)) {
            throw 'Shared coordination terminal receipt belongs to another owner token or tuple.'
        }
        return [ordered]@{ path = Join-Path $LockRoot $leaf; sha256 = [string]$snapshot.sha256 }
    }
    if (-not $Publish) { throw 'Shared coordination terminal receipt is missing.' }
    $published = Publish-PortableLeaseFile -ParentPath $LockRoot -Leaf $leaf -Bytes $bytes -ExpectedState $snapshot -NoReplace
    [ordered]@{ path = Join-Path $LockRoot $leaf; sha256 = [string]$published.state.sha256 }
}

function Assert-ReleasedCoordinationOwnerReceipt {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Owner,
        [Parameter(Mandatory)][string] $LockRoot,
        [Parameter(Mandatory)][string] $ResourceKey
    )
    $lease = [ordered]@{
        runId = [string]$Owner.owner.runId
        resourceKey = $ResourceKey
        token = [string]$Owner.owner.token
    }
    $terminal = Get-CoordinationTerminalReceipt -Lease $lease -LockRoot $LockRoot
    if (-not ([IO.Path]::GetFullPath([string]$Owner.releaseReceiptPath)).Equals(
            [IO.Path]::GetFullPath([string]$terminal.path),
            (Get-PortablePathComparison -Paths @($LockRoot, [string]$Owner.releaseReceiptPath, [string]$terminal.path))) -or
        [string]$Owner.releaseReceiptSha256 -cne [string]$terminal.sha256) {
        throw 'Released coordination owner differs from its immutable terminal receipt.'
    }
}

function New-CoordinationLeaseRecord {
    param(
        [Parameter(Mandatory)][string] $LockPath,
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $RunId,
        [Parameter(Mandatory)][string] $ResourceKey,
        [Parameter(Mandatory)][Collections.IDictionary] $Identity,
        [Parameter(Mandatory)][Collections.IDictionary] $Owner,
        [AllowNull()][string] $ReceiptRoot,
        [AllowNull()][string] $StaleEvidencePath,
        [ValidateRange(0, [int64]::MaxValue)][int64] $WaitingMilliseconds = 0
    )
    [ordered]@{
        path = [IO.Path]::GetFullPath($LockPath)
        token = $Token
        runId = $RunId
        resourceKey = $ResourceKey
        machineName = $Identity.machineName
        processId = $Identity.processId
        processStartTicks = $Identity.processStartTicks
        acquiredAt = $Owner.owner.acquiredAt
        receiptRoot = $ReceiptRoot
        receiptId = [guid]::NewGuid().ToString('N')
        staleEvidencePath = $StaleEvidencePath
        waitingMilliseconds = $WaitingMilliseconds
        lastHeartbeatUtc = [DateTimeOffset]::UtcNow
        platform = $Owner.platform
        lockPrimitive = $Owner.lockPrimitive
    }
}

function Enter-SharedCoordinationLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][ValidateSet('source-acquisition', 'git-coordination')][string] $ResourceKey,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9._-]+$')][string] $RunId,
        [ValidatePattern('^[0-9a-f]{32}$')][string] $AttemptToken,
        [string] $ReceiptRoot,
        [scriptblock] $WaitHeartbeatAction,
        [ValidateRange(1, 3600)][int] $TimeoutSeconds = 300
    )
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $physicalRepository = Resolve-PortableTrustedRoot -Path $repository
    $receiptRootFull = if ([string]::IsNullOrWhiteSpace($ReceiptRoot)) { $physicalRepository } else {
        $candidateReceiptRoot = [IO.Path]::GetFullPath($ReceiptRoot)
        $null = Assert-CoordinationPath -Path $candidateReceiptRoot -RepositoryRoot $repository -AllowMissing
        $relativeReceiptRoot = [IO.Path]::GetRelativePath($repository, $candidateReceiptRoot)
        if ($relativeReceiptRoot -ceq '.') {
            $physicalRepository
        }
        else {
            Open-CoordinationPrivateDirectory -Root $physicalRepository -RelativePath $relativeReceiptRoot
        }
    }
    $logicalLockRoot = Join-Path $repository 'AI Auto Update/In Progress/.locks'
    $null = Assert-CoordinationPath -Path $logicalLockRoot -RepositoryRoot $repository -AllowMissing
    New-Item -ItemType Directory -Path $logicalLockRoot -Force | Out-Null
    $null = Assert-CoordinationPath -Path $logicalLockRoot -RepositoryRoot $repository
    $lockRoot = Resolve-PortableTrustedRoot -Path $logicalLockRoot
    $lockPath = Join-Path $lockRoot "$ResourceKey.lock"
    $identity = Get-CoordinationProcessIdentity
    $effectiveAttemptToken = if ([string]::IsNullOrWhiteSpace($AttemptToken)) { [guid]::NewGuid().ToString('N') } else { $AttemptToken }
    $token = Get-CoordinationActorToken -RunId ("{0}:{1}:{2}:{3}:{4}" -f $RunId, $identity.machineName, $identity.processId, $identity.processStartTicks, $effectiveAttemptToken) -ResourceKey $ResourceKey
    $staleEvidencePath = $null
    [int64]$waitStartedMilliseconds = -1
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        if ($WaitHeartbeatAction) { $null = & $WaitHeartbeatAction }
        $now = [DateTimeOffset]::UtcNow
        $owner = [ordered]@{
            schemaVersion = 2
            state = 'held'
            resourceKey = $ResourceKey
            owner = [ordered]@{
                runId = $RunId
                machineName = $identity.machineName
                processId = $identity.processId
                processStartTicks = $identity.processStartTicks
                token = $token
                acquiredAt = $now.ToString('o')
                heartbeat = $now.ToString('o')
            }
            expiresAt = $now.AddMinutes(3).ToString('o')
            platform = Get-PortablePlatformName
            lockPrimitive = Get-PortableLockPrimitive
        }
        $waitForOwner = $false
        $guard = Enter-CoordinationOwnerGuard -LockRoot $lockRoot -ResourceKey $ResourceKey
        try {
            $snapshot = Get-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey $ResourceKey
            if (-not [bool]$snapshot.exists) {
                $transactionResidue = Get-PortableTransactionResidue -LockRoot $lockRoot
                if ([bool]$transactionResidue.hasResidue) {
                    throw [IO.InvalidDataException]::new(
                        "BLOCKED: incomplete owner publication residue exists under 'AI Auto Update/In Progress/.locks' ($(@($transactionResidue.entries) -join ', ')). Follow 'Manual recovery for incomplete owner publication' in references/automation.md.")
                }
            }
            if ([bool]$snapshot.exists) {
                $existing = $snapshot.value
                Assert-CoordinationOwner -Owner $existing -ResourceKey $ResourceKey
                if ([string]$existing.state -ceq 'released') {
                    Assert-ReleasedCoordinationOwnerReceipt -Owner $existing -LockRoot $lockRoot -ResourceKey $ResourceKey
                }
                if ([string]$existing.state -ceq 'held' -and [string]$existing.owner.token -ceq $token) {
                    if ([string]$existing.owner.runId -cne $RunId) { throw 'Shared coordination owner token is bound to another run.' }
                    $existingIdentity = [ordered]@{
                        machineName = [string]$existing.owner.machineName
                        processId = [int]$existing.owner.processId
                        processStartTicks = [int64]$existing.owner.processStartTicks
                    }
                    $takeoverEvidence = Get-CoordinationTakeoverEvidence -Owner $existing -LockRoot $lockRoot
                    return New-CoordinationLeaseRecord -LockPath $lockPath -Token $token -RunId $RunId -ResourceKey $ResourceKey `
                        -Identity $existingIdentity -Owner $existing -ReceiptRoot $receiptRootFull `
                        -StaleEvidencePath ([string]$takeoverEvidence.path) -WaitingMilliseconds ([int64]$takeoverEvidence.waitingMilliseconds)
                }
                $expiresAt = [DateTimeOffset]::ParseExact(
                    [string]$existing.expiresAt, 'o', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind)
                if ([string]$existing.state -ceq 'held') {
                    if ([DateTimeOffset]::UtcNow -lt $expiresAt -or (Test-CoordinationProcessActive -Owner $existing.owner)) {
                        $waitForOwner = $true
                    }
                }
            }
            if (-not $waitForOwner) {
                $preserveStaleEvidence = [bool]$snapshot.exists -and [string]$existing.state -ceq 'held'
                try {
                    $publicationNow = [DateTimeOffset]::UtcNow
                    $owner.owner.acquiredAt = $publicationNow.ToString('o')
                    $owner.owner.heartbeat = $publicationNow.ToString('o')
                    $owner.expiresAt = $publicationNow.AddMinutes(3).ToString('o')
                    $waitingMilliseconds = if ($waitStartedMilliseconds -lt 0) { [int64]0 } else {
                        [Math]::Max([int64]0, [Environment]::TickCount64 - $waitStartedMilliseconds)
                    }
                    if ($preserveStaleEvidence) {
                        $owner['takeover'] = [ordered]@{
                            evidenceLeaf = ".$ResourceKey.lock.stale-$([string]$snapshot.sha256).json"
                            staleSha256 = [string]$snapshot.sha256
                            staleLength = [int64]$snapshot.length
                            waitingMilliseconds = $waitingMilliseconds
                        }
                    }
                    $publicationParameters = @{
                        LockRoot = $lockRoot
                        ResourceKey = $ResourceKey
                        Value = $owner
                        ExpectedState = $snapshot
                        NoReplace = -not [bool]$snapshot.exists
                        PreserveDisplaced = $preserveStaleEvidence
                    }
                    $publication = Publish-CoordinationLeaseSnapshot @publicationParameters
                    Invoke-CoordinationFaultInjection -Point 'acquire-published-before-evidence-verification'
                    if ($preserveStaleEvidence) {
                        $staleEvidencePath = [string]$publication.displacedPath
                        if ([string]::IsNullOrWhiteSpace($staleEvidencePath)) {
                            throw 'Stale coordination CAS did not return its displaced owner evidence path.'
                        }
                        $evidence = Get-PortableLeaseFileState -ParentPath (Split-Path -Parent $staleEvidencePath) `
                            -Leaf (Split-Path -Leaf $staleEvidencePath)
                        if ([string]$evidence.sha256 -cne [string]$snapshot.sha256 -or
                            [int64]$evidence.length -ne [int64]$snapshot.length -or
                            [Convert]::ToHexString([byte[]]$evidence.bytes) -cne [Convert]::ToHexString([byte[]]$snapshot.bytes)) {
                            throw 'Stale coordination evidence differs from the displaced owner snapshot.'
                        }
                    }
                    return New-CoordinationLeaseRecord -LockPath $lockPath -Token $token -RunId $RunId -ResourceKey $ResourceKey -Identity $identity -Owner $owner -ReceiptRoot $receiptRootFull -StaleEvidencePath $staleEvidencePath -WaitingMilliseconds $waitingMilliseconds
                }
                catch {
                    $publicationFailure = $_
                    if ($null -ne (Get-CoordinationPublicationContentionKind -Failure $publicationFailure)) {
                        $waitForOwner = $true
                    }
                    else {
                        throw [IO.IOException]::new(
                            "Shared coordination lease publication failed: $($publicationFailure.Exception.Message)",
                            $publicationFailure.Exception)
                    }
                }
            }
        }
        finally {
            $guard.Dispose()
        }
        if ($waitForOwner) {
            if ($waitStartedMilliseconds -lt 0) { $waitStartedMilliseconds = [Environment]::TickCount64 }
            [Threading.Thread]::Sleep(250)
            if ($WaitHeartbeatAction) { $null = & $WaitHeartbeatAction }
        }
    }
    throw "Timed out acquiring the short-lived $ResourceKey coordination lock."
}

function Update-SharedCoordinationLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Lease,
        [switch] $Force,
        [ValidateRange(1, 300)][int] $MinimumIntervalSeconds = 30
    )
    if (-not $Force -and
        ([DateTimeOffset]::UtcNow - [DateTimeOffset]$Lease.lastHeartbeatUtc).TotalSeconds -lt $MinimumIntervalSeconds) { return }
    $lockRoot = Split-Path -Parent ([string]$Lease.path)
    $guard = Enter-CoordinationOwnerGuard -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey)
    try {
        $snapshot = Get-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey)
        if (-not [bool]$snapshot.exists) { throw 'Shared coordination owner disappeared before heartbeat refresh.' }
        $owner = $snapshot.value
        Assert-CoordinationOwner -Owner $owner -ResourceKey ([string]$Lease.resourceKey)
        if (-not (Test-CoordinationLeaseMatchesOwner -Lease $Lease -Owner $owner)) {
            throw 'Shared coordination ownership changed before heartbeat refresh.'
        }
        if (-not $Lease.Contains('pendingHeartbeat')) {
            $now = [DateTimeOffset]::UtcNow
            $Lease.pendingHeartbeat = $now.ToString('o')
            $Lease.pendingExpiresAt = $now.AddMinutes(3).ToString('o')
        }
        $observed = [DateTimeOffset]::ParseExact([string]$owner.owner.heartbeat, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $target = [DateTimeOffset]::ParseExact([string]$Lease.pendingHeartbeat, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        if ($observed -ge $target) {
            $Lease.Remove('pendingHeartbeat')
            $Lease.Remove('pendingExpiresAt')
            $Lease.lastHeartbeatUtc = $observed
            return
        }
        $owner.owner.heartbeat = [string]$Lease.pendingHeartbeat
        $owner.expiresAt = [string]$Lease.pendingExpiresAt
        $null = Publish-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey) `
            -Value $owner -ExpectedState $snapshot
        Invoke-CoordinationFaultInjection -Point 'heartbeat-published-before-readback'
        $verified = (Get-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey)).value
        if (-not (Test-CoordinationLeaseMatchesOwner -Lease $Lease -Owner $verified) -or
            [DateTimeOffset]::ParseExact([string]$verified.owner.heartbeat, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) -lt $target) {
            throw 'Shared coordination ownership changed during heartbeat refresh.'
        }
        $Lease.lastHeartbeatUtc = $target
        $Lease.Remove('pendingHeartbeat')
        $Lease.Remove('pendingExpiresAt')
    }
    finally { $guard.Dispose() }
}

function Exit-SharedCoordinationLease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary] $Lease)
    $lockRoot = Split-Path -Parent ([string]$Lease.path)
    $guard = Enter-CoordinationOwnerGuard -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey)
    try {
        $snapshot = Get-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey)
        if (-not [bool]$snapshot.exists) { throw 'Shared coordination lock disappeared before owner-checked release.' }
        $owner = $snapshot.value
        Assert-CoordinationOwner -Owner $owner -ResourceKey ([string]$Lease.resourceKey)
        if ([string]$owner.state -ceq 'released') {
            if ([string]$owner.releasedByOwnerToken -cne [string]$Lease.token) {
                throw 'Shared coordination lease was released by another owner token.'
            }
            $terminal = Get-CoordinationTerminalReceipt -Lease $Lease -LockRoot $lockRoot
            if (-not ([IO.Path]::GetFullPath([string]$owner.releaseReceiptPath)).Equals(
                    [IO.Path]::GetFullPath([string]$terminal.path),
                    (Get-PortablePathComparison -Paths @($lockRoot, [string]$owner.releaseReceiptPath, [string]$terminal.path))) -or
                [string]$owner.releaseReceiptSha256 -cne [string]$terminal.sha256) {
                throw 'Released coordination owner differs from its immutable terminal receipt.'
            }
            if (-not $owner.Contains('coordinationReceiptId') -or -not $owner.Contains('coordinationCompletedAt')) {
                throw 'Released coordination owner lacks its operational receipt tuple.'
            }
            $Lease.receiptId = [string]$owner.coordinationReceiptId
            $Lease.completedAt = [string]$owner.coordinationCompletedAt
            return Write-CoordinationReceipt -Lease $Lease -Disposition 'released'
        }
        if (-not (Test-CoordinationLeaseMatchesOwner -Lease $Lease -Owner $owner)) {
            throw 'Shared coordination lock ownership changed before release.'
        }
        $Lease.completedAt = Get-CoordinationUtcTimestamp
        $owner.coordinationReceiptId = [string]$Lease.receiptId
        $owner.coordinationCompletedAt = [string]$Lease.completedAt
        $terminal = Get-CoordinationTerminalReceipt -Lease $Lease -LockRoot $lockRoot -Publish
        $owner.state = 'released'
        $owner.releasedByOwnerToken = [string]$Lease.token
        $owner.releaseReceiptPath = [string]$terminal.path
        $owner.releaseReceiptSha256 = [string]$terminal.sha256
        $owner.owner.heartbeat = $Lease.completedAt
        $owner.expiresAt = $Lease.completedAt
        $null = Publish-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey) `
            -Value $owner -ExpectedState $snapshot
    }
    finally { $guard.Dispose() }
    Invoke-CoordinationFaultInjection -Point 'release-published-before-operational-receipt'
    Write-CoordinationReceipt -Lease $Lease -Disposition 'released'
}

Export-ModuleMember -Function Start-SharedCoordinationAcquisitionAttempt, Complete-SharedCoordinationAcquisitionAttempt,
    Enter-SharedCoordinationLease, Update-SharedCoordinationLease, Exit-SharedCoordinationLease,
    Test-CoordinationProcessStartMatch
