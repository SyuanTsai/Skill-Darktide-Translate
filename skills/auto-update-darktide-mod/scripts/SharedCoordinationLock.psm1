# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'PathSafety.psm1') -Force -ErrorAction Stop

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
    if ([string]$Owner.machineName -cne [Environment]::MachineName -or
        -not $Owner.processId -or -not $Owner.processStartTicks) {
        return $false
    }
    try {
        $process = Get-Process -Id ([int]$Owner.processId) -ErrorAction Stop
        Test-CoordinationProcessStartMatch -ActualTicks $process.StartTime.ToUniversalTime().Ticks -ExpectedTicks ([int64]$Owner.processStartTicks)
    }
    catch { $false }
}

function Enter-CoordinationOwnerGuard {
    param([Parameter(Mandatory)][string] $LockRoot, [Parameter(Mandatory)][string] $ResourceKey)
    $guardLeaf = "$ResourceKey.owner-update.guard"
    $guardPath = Join-Path $LockRoot $guardLeaf
    $null = Assert-CoordinationPath -Path $guardPath -RepositoryRoot $LockRoot -AllowMissing
    # The vendored authority lock is a Windows share-mode handle or a Unix
    # flock on a fixed inode; it does not depend on .NET FileShare emulation.
    try {
        Enter-PortableFileLock -Root $LockRoot -Leaf $guardLeaf -TimeoutMilliseconds 15000 -Label "$ResourceKey owner update guard"
    }
    catch [TimeoutException] {
        throw "Unable to acquire the short $ResourceKey owner update guard."
    }
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
        ([string]$Owner.platform -ceq 'windows' -and [string]$Owner.lockPrimitive -cne 'windows-fileshare') -or
        ([string]$Owner.platform -in @('linux', 'macos') -and [string]$Owner.lockPrimitive -cne 'flock') -or
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
    $idBytes = [Text.UTF8Encoding]::new($false).GetBytes("coordination:$ResourceKey")
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { $transactionId = ([BitConverter]::ToString($sha256.ComputeHash($idBytes))).Replace('-', '').ToLowerInvariant().Substring(0, 32) }
    finally { $sha256.Dispose() }
    Publish-PortableLeaseFile -ParentPath $LockRoot -Leaf "$ResourceKey.lock" -Bytes $bytes `
        -ExpectedState $ExpectedState -TransactionId $transactionId -NoReplace:$NoReplace `
        -PreserveDisplaced:$PreserveDisplaced
}

function Write-CoordinationReceipt {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Lease,
        [Parameter(Mandatory)][string] $Disposition
    )
    if ([string]::IsNullOrWhiteSpace([string]$Lease.receiptRoot)) { return $null }
    $receiptDirectory = Join-Path ([string]$Lease.receiptRoot) 'coordination-locks'
    New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    $receiptPath = Join-Path $receiptDirectory ('{0}-{1}.json' -f ([string]$Lease.resourceKey), ([string]$Lease.receiptId))
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
    Write-CoordinationAtomicJson -Path $receiptPath -Value $receipt
    [ordered]@{
        path = [IO.Path]::GetFullPath($receiptPath)
        sha256 = Get-CoordinationFileSha256 -Path $receiptPath
        resourceKey = [string]$Lease.resourceKey
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
        [string] $ReceiptRoot,
        [scriptblock] $WaitHeartbeatAction,
        [ValidateRange(1, 3600)][int] $TimeoutSeconds = 300
    )
    $repository = [IO.Path]::GetFullPath($RepositoryRoot)
    $receiptRootFull = if ([string]::IsNullOrWhiteSpace($ReceiptRoot)) { $null } else {
        $candidateReceiptRoot = [IO.Path]::GetFullPath($ReceiptRoot)
        $null = Assert-CoordinationPath -Path $candidateReceiptRoot -RepositoryRoot $repository -AllowMissing
        $candidateReceiptRoot
    }
    $lockRoot = Join-Path $repository 'AI Auto Update/In Progress/.locks'
    $null = Assert-CoordinationPath -Path $lockRoot -RepositoryRoot $repository -AllowMissing
    New-Item -ItemType Directory -Path $lockRoot -Force | Out-Null
    $null = Assert-CoordinationPath -Path $lockRoot -RepositoryRoot $repository
    $lockPath = Join-Path $lockRoot "$ResourceKey.lock"
    $identity = Get-CoordinationProcessIdentity
    $token = [guid]::NewGuid().ToString('N')
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
            if ([bool]$snapshot.exists) {
                $existing = $snapshot.value
                Assert-CoordinationOwner -Owner $existing -ResourceKey $ResourceKey
                $expiresAt = [DateTimeOffset]::ParseExact(
                    [string]$existing.expiresAt, 'o', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind)
                if ([string]$existing.state -ceq 'held' -and [DateTimeOffset]::UtcNow -lt $expiresAt) {
                    $waitForOwner = $true
                }
            }
            if (-not $waitForOwner) {
                $preserveStaleEvidence = [bool]$snapshot.exists -and [string]$existing.state -ceq 'held'
                try {
                    $publication = Publish-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey $ResourceKey -Value $owner `
                        -ExpectedState $snapshot -NoReplace:(-not [bool]$snapshot.exists) `
                        -PreserveDisplaced:$preserveStaleEvidence
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
                    $waitingMilliseconds = if ($waitStartedMilliseconds -lt 0) {
                        [int64]0
                    }
                    else {
                        [Math]::Max([int64]0, [Environment]::TickCount64 - $waitStartedMilliseconds)
                    }
                    return New-CoordinationLeaseRecord -LockPath $lockPath -Token $token -RunId $RunId -ResourceKey $ResourceKey -Identity $identity -Owner $owner -ReceiptRoot $receiptRootFull -StaleEvidencePath $staleEvidencePath -WaitingMilliseconds $waitingMilliseconds
                }
                catch { $waitForOwner = $true }
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
        $now = [DateTimeOffset]::UtcNow
        $owner.owner.heartbeat = $now.ToString('o')
        $owner.expiresAt = $now.AddMinutes(3).ToString('o')
        $null = Publish-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey) `
            -Value $owner -ExpectedState $snapshot
        $verified = (Get-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey)).value
        if (-not (Test-CoordinationLeaseMatchesOwner -Lease $Lease -Owner $verified)) {
            throw 'Shared coordination ownership changed during heartbeat refresh.'
        }
    }
    finally { $guard.Dispose() }
    $Lease.lastHeartbeatUtc = [DateTimeOffset]::UtcNow
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
        if (-not (Test-CoordinationLeaseMatchesOwner -Lease $Lease -Owner $owner)) {
            throw 'Shared coordination lock ownership changed before release.'
        }
        $Lease.completedAt = Get-CoordinationUtcTimestamp
        $owner.state = 'released'
        $owner.owner.heartbeat = $Lease.completedAt
        $owner.expiresAt = $Lease.completedAt
        $null = Publish-CoordinationLeaseSnapshot -LockRoot $lockRoot -ResourceKey ([string]$Lease.resourceKey) `
            -Value $owner -ExpectedState $snapshot
    }
    finally { $guard.Dispose() }
    Write-CoordinationReceipt -Lease $Lease -Disposition 'released'
}

Export-ModuleMember -Function Enter-SharedCoordinationLease, Update-SharedCoordinationLease, Exit-SharedCoordinationLease,
    Test-CoordinationProcessStartMatch
