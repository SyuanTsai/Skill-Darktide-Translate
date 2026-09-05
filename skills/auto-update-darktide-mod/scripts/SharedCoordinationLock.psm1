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
    if (-not $fullPath.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Shared coordination path escapes the repository root.'
    }
    $current = $fullPath
    for ($depth = 0; $depth -lt 2048; $depth++) {
        if (Test-Path -LiteralPath $current) {
            if (Test-PortableReparseItem -Path $current -Item (Get-Item -LiteralPath $current -Force) -Label 'Shared coordination') {
                throw 'Shared coordination path contains a symlink or reparse point.'
            }
        }
        else {
            if (Test-PortableReparseItem -Path $current -Label 'Shared coordination') {
                throw 'Shared coordination path contains a symlink or reparse point.'
            }
            if (-not $AllowMissing) {
                throw 'Shared coordination path is missing.'
            }
        }
        if ($current.Equals($repository, [StringComparison]::OrdinalIgnoreCase)) { return $fullPath }
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

function Test-CoordinationProcessActive {
    param([Parameter(Mandatory)][Collections.IDictionary] $Owner)
    if ([string]$Owner.machineName -cne [Environment]::MachineName -or
        -not $Owner.processId -or -not $Owner.processStartTicks) {
        return $false
    }
    try {
        $process = Get-Process -Id ([int]$Owner.processId) -ErrorAction Stop
        $process.StartTime.ToUniversalTime().Ticks -eq [int64]$Owner.processStartTicks
    }
    catch { $false }
}

function Enter-CoordinationOwnerGuard {
    param([Parameter(Mandatory)][string] $LockRoot, [Parameter(Mandatory)][string] $ResourceKey)
    $guardPath = Join-Path $LockRoot "$ResourceKey.owner-update.guard"
    $null = Assert-CoordinationPath -Path $guardPath -RepositoryRoot $LockRoot -AllowMissing
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(15)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            return [IO.File]::Open($guardPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        }
        catch [IO.IOException] { [Threading.Thread]::Sleep(25) }
    }
    throw "Unable to acquire the short $ResourceKey owner update guard."
}

function Assert-CoordinationOwner {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Owner,
        [Parameter(Mandatory)][string] $ResourceKey
    )
    foreach ($field in @('schemaVersion', 'runId', 'resourceKey', 'machineName', 'processId', 'processStartTicks', 'token', 'acquiredAt', 'heartbeat')) {
        if (-not $Owner.Contains($field) -or [string]::IsNullOrWhiteSpace([string]$Owner[$field])) {
            throw "Existing $ResourceKey coordination lock owner is missing $field."
        }
    }
    $parsedSchemaVersion = 0
    $parsedProcessId = 0
    $parsedProcessStartTicks = [int64]0
    if (-not [int]::TryParse([string]$Owner.schemaVersion, [ref]$parsedSchemaVersion) -or $parsedSchemaVersion -ne 1 -or
        -not [int]::TryParse([string]$Owner.processId, [ref]$parsedProcessId) -or $parsedProcessId -le 0 -or
        -not [int64]::TryParse([string]$Owner.processStartTicks, [ref]$parsedProcessStartTicks) -or $parsedProcessStartTicks -le 0 -or
        [string]$Owner.runId -notmatch '^[A-Za-z0-9._-]+$' -or
        [string]$Owner.resourceKey -cne $ResourceKey -or
        [string]$Owner.token -notmatch '^[0-9a-f]{32}$') {
        throw "Existing $ResourceKey coordination lock owner contract is invalid."
    }
    foreach ($timestampField in @('acquiredAt', 'heartbeat')) {
        $parsed = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParseExact(
            [string]$Owner[$timestampField], 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed
        )) { throw "Existing $ResourceKey coordination lock $timestampField is invalid." }
    }
}

function Test-CoordinationLeaseMatchesOwner {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Lease,
        [Parameter(Mandatory)][Collections.IDictionary] $Owner
    )
    [string]$Owner.runId -ceq [string]$Lease.runId -and
        [string]$Owner.resourceKey -ceq [string]$Lease.resourceKey -and
        [string]$Owner.token -ceq [string]$Lease.token -and
        [string]$Owner.machineName -ceq [string]$Lease.machineName -and
        [int]$Owner.processId -eq [int]$Lease.processId -and
        [int64]$Owner.processStartTicks -eq [int64]$Lease.processStartTicks
}

function Write-CoordinationReceipt {
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Lease,
        [Parameter(Mandatory)][string] $Disposition
    )
    if ([string]::IsNullOrWhiteSpace([string]$Lease.receiptRoot)) { return $null }
    $receiptDirectory = Join-Path ([string]$Lease.receiptRoot) 'coordination-locks'
    New-Item -ItemType Directory -Path $receiptDirectory -Force | Out-Null
    $receiptPath = Join-Path $receiptDirectory ("$($Lease.resourceKey)-$($Lease.receiptId).json")
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
        acquiredAt = $Owner.acquiredAt
        receiptRoot = $ReceiptRoot
        receiptId = [guid]::NewGuid().ToString('N')
        staleEvidencePath = $StaleEvidencePath
        waitingMilliseconds = $WaitingMilliseconds
        lastHeartbeatUtc = [DateTimeOffset]::UtcNow
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
        $prepared = Join-Path $lockRoot (".pending-$ResourceKey-$RunId-$([guid]::NewGuid().ToString('N'))")
        New-Item -ItemType Directory -Path $prepared -ErrorAction Stop | Out-Null
        $owner = [ordered]@{
            schemaVersion = 1
            runId = $RunId
            resourceKey = $ResourceKey
            machineName = $identity.machineName
            processId = $identity.processId
            processStartTicks = $identity.processStartTicks
            token = $token
            acquiredAt = Get-CoordinationUtcTimestamp
            heartbeat = Get-CoordinationUtcTimestamp
        }
        Write-CoordinationAtomicJson -Path (Join-Path $prepared 'owner.json') -Value $owner
        $waitForOwner = $false
        $guard = Enter-CoordinationOwnerGuard -LockRoot $lockRoot -ResourceKey $ResourceKey
        try {
            if (Test-Path -LiteralPath $lockPath -PathType Container) {
                $null = Assert-CoordinationPath -Path $lockPath -RepositoryRoot $repository
                $existingOwnerPath = Join-Path $lockPath 'owner.json'
                $null = Assert-CoordinationPath -Path $existingOwnerPath -RepositoryRoot $lockRoot
                try { $existing = Get-Content -LiteralPath $existingOwnerPath -Raw | ConvertFrom-Json -AsHashtable }
                catch { throw "Existing $ResourceKey coordination lock owner is unreadable; preserve it for explicit recovery." }
                Assert-CoordinationOwner -Owner $existing -ResourceKey $ResourceKey
                $existingHeartbeat = [DateTimeOffset]::ParseExact(
                    [string]$existing.heartbeat, 'o', [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                )
                if ((Test-CoordinationProcessActive -Owner $existing) -or
                    ([DateTimeOffset]::UtcNow - $existingHeartbeat).TotalMinutes -le 3) {
                    $waitForOwner = $true
                }
                else {
                    $stalePath = Join-Path $lockRoot (".stale-$ResourceKey-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ'))-$([guid]::NewGuid().ToString('N'))")
                    try {
                        [IO.Directory]::Move($lockPath, $stalePath)
                        $staleEvidencePath = [IO.Path]::GetFullPath($stalePath)
                    }
                    catch [IO.IOException] { $waitForOwner = $true }
                }
            }
            if (-not $waitForOwner) {
                $owner.acquiredAt = Get-CoordinationUtcTimestamp
                $owner.heartbeat = $owner.acquiredAt
                Write-CoordinationAtomicJson -Path (Join-Path $prepared 'owner.json') -Value $owner
                try {
                    [IO.Directory]::Move($prepared, $lockPath)
                    $waitingMilliseconds = if ($waitStartedMilliseconds -lt 0) {
                        [int64]0
                    }
                    else {
                        [Math]::Max([int64]0, [Environment]::TickCount64 - $waitStartedMilliseconds)
                    }
                    return New-CoordinationLeaseRecord -LockPath $lockPath -Token $token -RunId $RunId `
                        -ResourceKey $ResourceKey -Identity $identity -Owner $owner -ReceiptRoot $receiptRootFull `
                        -StaleEvidencePath $staleEvidencePath -WaitingMilliseconds $waitingMilliseconds
                }
                catch [IO.IOException] { $waitForOwner = $true }
            }
        }
        finally {
            $guard.Dispose()
            if (Test-Path -LiteralPath $prepared -PathType Container) {
                $preparedItems = @(Get-ChildItem -LiteralPath $prepared -Force)
                if ($preparedItems.Count -eq 1 -and $preparedItems[0].Name -ceq 'owner.json' -and -not $preparedItems[0].PSIsContainer) {
                    [IO.File]::Delete($preparedItems[0].FullName)
                    [IO.Directory]::Delete($prepared)
                }
            }
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
        $ownerPath = Join-Path ([string]$Lease.path) 'owner.json'
        $null = Assert-CoordinationPath -Path $ownerPath -RepositoryRoot $lockRoot
        if (-not (Test-Path -LiteralPath $ownerPath -PathType Leaf)) {
            throw 'Shared coordination owner disappeared before heartbeat refresh.'
        }
        $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-CoordinationOwner -Owner $owner -ResourceKey ([string]$Lease.resourceKey)
        if (-not (Test-CoordinationLeaseMatchesOwner -Lease $Lease -Owner $owner)) {
            throw 'Shared coordination ownership changed before heartbeat refresh.'
        }
        $owner.heartbeat = Get-CoordinationUtcTimestamp
        Write-CoordinationAtomicJson -Path $ownerPath -Value $owner
        $verified = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
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
        if (-not (Test-Path -LiteralPath ([string]$Lease.path) -PathType Container)) {
            throw 'Shared coordination lock disappeared before owner-checked release.'
        }
        $ownerPath = Join-Path ([string]$Lease.path) 'owner.json'
        $null = Assert-CoordinationPath -Path $ownerPath -RepositoryRoot $lockRoot
        $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-CoordinationOwner -Owner $owner -ResourceKey ([string]$Lease.resourceKey)
        if (-not (Test-CoordinationLeaseMatchesOwner -Lease $Lease -Owner $owner)) {
            throw 'Shared coordination lock ownership changed before release.'
        }
        $lockItems = @(Get-ChildItem -LiteralPath ([string]$Lease.path) -Force)
        if ($lockItems.Count -ne 1 -or $lockItems[0].Name -cne 'owner.json' -or $lockItems[0].PSIsContainer) {
            throw 'Shared coordination lock contains unexpected entries; preserving it for recovery.'
        }
        $Lease.completedAt = Get-CoordinationUtcTimestamp
        [IO.File]::Delete($ownerPath)
        [IO.Directory]::Delete([string]$Lease.path)
    }
    finally { $guard.Dispose() }
    Write-CoordinationReceipt -Lease $Lease -Disposition 'released'
}

Export-ModuleMember -Function Enter-SharedCoordinationLease, Update-SharedCoordinationLease, Exit-SharedCoordinationLease
