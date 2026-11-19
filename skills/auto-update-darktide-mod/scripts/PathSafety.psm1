# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PortablePlatformName {
    [OutputType([string])]
    param()

    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        return 'windows'
    }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Linux)) {
        return 'linux'
    }
    if ([Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::OSX)) {
        return 'macos'
    }
    throw [PlatformNotSupportedException]::new('The local path runtime supports Windows, Linux, and macOS only.')
}

function Get-PortablePathComparison {
    param(
        [AllowEmptyCollection()][string[]] $Paths = @(),
        [ValidateSet('Containment', 'Exclusion')][string] $Purpose = 'Containment'
    )

    if ((Get-PortablePlatformName) -ceq 'windows') {
        return [StringComparison]::OrdinalIgnoreCase
    }
    [StringComparison]::Ordinal
}

function Resolve-PortableContainedPath {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Root,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Path
    )

    $rootFull = [IO.Path]::GetFullPath($Root)
    $rootPath = [IO.Path]::GetPathRoot($rootFull)
    if (-not $rootFull.Equals($rootPath, (Get-PortablePathComparison))) {
        $rootFull = $rootFull.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    $candidateFull = if ([string]::IsNullOrEmpty($Path)) {
        $rootFull
    }
    elseif ([IO.Path]::IsPathFullyQualified($Path)) {
        [IO.Path]::GetFullPath($Path)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $rootFull $Path))
    }
    $comparison = Get-PortablePathComparison -Paths @($rootFull, $candidateFull)
    $prefix = if ($rootFull.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $rootFull
    }
    else {
        $rootFull + [IO.Path]::DirectorySeparatorChar
    }
    if (-not $candidateFull.Equals($rootFull, $comparison) -and
        -not $candidateFull.StartsWith($prefix, $comparison)) {
        throw [UnauthorizedAccessException]::new("Path escapes its containing root: $candidateFull")
    }
    $candidateFull
}

function Resolve-PortableTrustedRoot {
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    $full = [IO.Path]::GetFullPath($Path)
    if (-not [IO.Directory]::Exists($full)) {
        throw [IO.DirectoryNotFoundException]::new("Trusted root is not an existing directory: $full")
    }
    $full
}

function Test-PortableReparseItem {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][object] $Item,
        [string] $Label = 'path',
        [AllowEmptyString()][string] $TrustedRoot
    )

    $full = [IO.Path]::GetFullPath($Path)
    $root = $null
    if (-not [string]::IsNullOrWhiteSpace($TrustedRoot)) {
        $root = [IO.Path]::GetFullPath($TrustedRoot)
        $null = Resolve-PortableContainedPath -Root $root -Path $full
    }
    $comparison = Get-PortablePathComparison -Paths @($root, $full)
    $current = $full
    for ($depth = 0; $depth -lt 2048; $depth++) {
        $candidate = if ($current.Equals($full, $comparison) -and $null -ne $Item) {
            $Item
        }
        else {
            Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        }
        if ($null -ne $candidate) {
            try {
                if (($candidate.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
                    -not [string]::IsNullOrWhiteSpace([string]$candidate.LinkType) -or
                    -not [string]::IsNullOrWhiteSpace([string]$candidate.LinkTarget)) {
                    return $true
                }
            }
            catch {
                throw "Unable to inspect $Label reparse metadata: $($_.Exception.Message)"
            }
        }
        if ($null -ne $root -and $current.Equals($root, $comparison)) { break }
        $parent = [IO.DirectoryInfo]::new($current).Parent
        if ($null -eq $parent -or $parent.FullName.Equals($current, $comparison)) { break }
        $current = $parent.FullName
    }
    $false
}

function Test-PortablePhysicalIdentity {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $PathA,
        [Parameter(Mandatory)][string] $PathB
    )

    $fullA = [IO.Path]::GetFullPath($PathA)
    $fullB = [IO.Path]::GetFullPath($PathB)
    if (-not [IO.File]::Exists($fullA) -and -not [IO.Directory]::Exists($fullA)) { return $false }
    if (-not [IO.File]::Exists($fullB) -and -not [IO.Directory]::Exists($fullB)) { return $false }
    $fullA.Equals($fullB, (Get-PortablePathComparison -Paths @($fullA, $fullB)))
}

function Get-PortableLockPrimitive {
    [OutputType([string])]
    param()

    'dotnet-fileshare-none'
}

function Enter-PortableFileLock {
    param(
        [Parameter(Mandatory)][string] $Root,
        [AllowEmptyString()][string] $RelativeDirectory = '',
        [Parameter(Mandatory)][string] $Leaf,
        [ValidateRange(0, 3600000)][int] $TimeoutMilliseconds = 15000,
        [string] $Label = 'coordination'
    )

    if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf -cne [IO.Path]::GetFileName($Leaf)) {
        throw [ArgumentException]::new('Lock leaf must be one file name.')
    }
    $rootFull = Resolve-PortableTrustedRoot -Path $Root
    $relative = $RelativeDirectory.Replace('\', [IO.Path]::DirectorySeparatorChar).Replace('/', [IO.Path]::DirectorySeparatorChar)
    $directory = Resolve-PortableContainedPath -Root $rootFull -Path $relative
    if (-not [IO.Directory]::Exists($directory)) {
        throw [IO.DirectoryNotFoundException]::new("Lock directory is missing: $directory")
    }
    $lockPath = Resolve-PortableContainedPath -Root $rootFull -Path (Join-Path $directory $Leaf)
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $stream = $null
    while ($null -eq $stream) {
        try {
            $stream = [IO.File]::Open(
                $lockPath,
                [IO.FileMode]::OpenOrCreate,
                [IO.FileAccess]::ReadWrite,
                [IO.FileShare]::None)
        }
        catch [IO.IOException] {
            if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                throw [TimeoutException]::new("Unable to acquire the $Label lock within $TimeoutMilliseconds milliseconds.", $_.Exception)
            }
            [Threading.Thread]::Sleep(50)
        }
    }
    $stopwatch.Stop()
    $handle = [pscustomobject][ordered]@{
        platform = Get-PortablePlatformName
        lockPrimitive = Get-PortableLockPrimitive
        path = $lockPath
        Stream = $stream
    }
    $handle | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        if ($null -ne $this.Stream) {
            $this.Stream.Dispose()
            $this.Stream = $null
        }
    }
    $handle
}

function Get-PortableLeaseFileState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ParentPath,
        [Parameter(Mandatory)][string] $Leaf,
        [ValidateRange(1, 16777216)][int] $MaximumBytes = 1048576,
        [switch] $AllowMissing,
        [string] $LegacyDirectoryMessage
    )

    if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf -cne [IO.Path]::GetFileName($Leaf)) {
        throw [ArgumentException]::new('Lease leaf must be one file name.')
    }
    $parent = Resolve-PortableTrustedRoot -Path $ParentPath
    $path = Resolve-PortableContainedPath -Root $parent -Path $Leaf
    if ([IO.Directory]::Exists($path)) {
        if ([string]::IsNullOrWhiteSpace($LegacyDirectoryMessage)) {
            throw [IO.InvalidDataException]::new("The lease path is a directory: $Leaf")
        }
        throw [IO.InvalidDataException]::new($LegacyDirectoryMessage)
    }
    if (-not [IO.File]::Exists($path)) {
        if ($AllowMissing) {
            return [ordered]@{ exists = $false; bytes = $null; sha256 = $null; length = $null }
        }
        throw [IO.FileNotFoundException]::new("Lease file is missing: $path", $path)
    }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        if ($stream.Length -gt $MaximumBytes) {
            throw [IO.InvalidDataException]::new("Lease file exceeds $MaximumBytes bytes: $path")
        }
        [byte[]]$bytes = [byte[]]::new([int]$stream.Length)
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -le 0) { throw [IO.EndOfStreamException]::new("Lease file ended early: $path") }
            $offset += $read
        }
    }
    finally { $stream.Dispose() }
    [ordered]@{
        exists = $true
        bytes = $bytes
        sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        length = [int64]$bytes.Length
    }
}

function New-PortablePublicationException {
    param([Parameter(Mandatory)][string] $Kind, [Parameter(Mandatory)][string] $Message, [Exception] $InnerException)

    $exception = if ($null -eq $InnerException) {
        [IO.IOException]::new($Message)
    }
    else {
        [IO.IOException]::new($Message, $InnerException)
    }
    $exception.Data['PortablePublicationKind'] = $Kind
    $exception
}

function Write-PortableTemporaryFile {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][byte[]] $Bytes)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Get-PortableTransactionResidue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $LockRoot,
        [string] $OwnerLeaf
    )

    $root = Resolve-PortableTrustedRoot -Path $LockRoot
    if (-not [string]::IsNullOrWhiteSpace($OwnerLeaf) -and $OwnerLeaf -cne [IO.Path]::GetFileName($OwnerLeaf)) {
        throw [ArgumentException]::new('OwnerLeaf must be one file name when provided.')
    }
    $pattern = if ([string]::IsNullOrWhiteSpace($OwnerLeaf)) {
        '^\..+\.publish-[0-9a-f]{32}\.tmp$'
    }
    else {
        '^\.' + [regex]::Escape($OwnerLeaf) + '\.publish-[0-9a-f]{32}\.tmp$'
    }
    $entries = [Collections.Generic.List[string]]::new()
    foreach ($path in [IO.Directory]::GetFileSystemEntries($root)) {
        $leaf = [IO.Path]::GetFileName([IO.Path]::TrimEndingDirectorySeparator($path))
        if ($leaf -match $pattern) { $entries.Add($leaf) }
    }
    [string[]]$sorted = @($entries.ToArray() | Sort-Object -Unique)
    [ordered]@{ hasResidue = $sorted.Count -gt 0; entries = $sorted }
}

function Publish-PortableLeaseFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ParentPath,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][Collections.IDictionary] $ExpectedState,
        [switch] $NoReplace,
        [switch] $PreserveDisplaced
    )

    if ([string]::IsNullOrWhiteSpace($Leaf) -or $Leaf -cne [IO.Path]::GetFileName($Leaf)) {
        throw [ArgumentException]::new('Publication leaf must be one file name.')
    }
    if ($NoReplace -and [bool]$ExpectedState.exists) {
        throw [ArgumentException]::new('NoReplace requires an absent expected state.')
    }
    if ($PreserveDisplaced -and -not [bool]$ExpectedState.exists) {
        throw [ArgumentException]::new('PreserveDisplaced requires an existing expected state.')
    }
    $parent = Resolve-PortableTrustedRoot -Path $ParentPath
    $target = Resolve-PortableContainedPath -Root $parent -Path $Leaf
    $current = Get-PortableLeaseFileState -ParentPath $parent -Leaf $Leaf -AllowMissing
    if ([bool]$current.exists -ne [bool]$ExpectedState.exists -or
        ([bool]$current.exists -and (
            [string]$current.sha256 -cne [string]$ExpectedState.sha256 -or
            [int64]$current.length -ne [int64]$ExpectedState.length))) {
        if ($NoReplace -and [bool]$current.exists -and -not [bool]$ExpectedState.exists) {
            throw (New-PortablePublicationException -Kind 'no-replace-target-exists' -Message 'No-replace publication target already exists.')
        }
        throw (New-PortablePublicationException -Kind 'cas-expected-state-mismatch' -Message 'Publication target differs from its expected state.')
    }

    $displacedPath = $null
    if ($PreserveDisplaced) {
        $evidenceLeaf = ".$Leaf.stale-$([string]$ExpectedState.sha256).json"
        $displacedPath = Resolve-PortableContainedPath -Root $parent -Path $evidenceLeaf
        if ([IO.File]::Exists($displacedPath)) {
            $evidence = Get-PortableLeaseFileState -ParentPath $parent -Leaf $evidenceLeaf
            if ([string]$evidence.sha256 -cne [string]$ExpectedState.sha256 -or
                [int64]$evidence.length -ne [int64]$ExpectedState.length) {
                throw [IO.InvalidDataException]::new('Existing stale-owner evidence differs from the displaced owner state.')
            }
        }
        else {
            $evidenceTemporary = Resolve-PortableContainedPath -Root $parent -Path (".$evidenceLeaf.publish-$([guid]::NewGuid().ToString('N')).tmp")
            try {
                Write-PortableTemporaryFile -Path $evidenceTemporary -Bytes ([byte[]]$current.bytes)
                try { [IO.File]::Move($evidenceTemporary, $displacedPath, $false) }
                catch [IO.IOException] {
                    if (-not [IO.File]::Exists($displacedPath)) { throw }
                    $evidence = Get-PortableLeaseFileState -ParentPath $parent -Leaf $evidenceLeaf
                    if ([string]$evidence.sha256 -cne [string]$ExpectedState.sha256 -or
                        [int64]$evidence.length -ne [int64]$ExpectedState.length) { throw }
                }
            }
            finally {
                if ([IO.File]::Exists($evidenceTemporary)) { [IO.File]::Delete($evidenceTemporary) }
            }
        }
    }

    $temporary = Resolve-PortableContainedPath -Root $parent -Path (".$Leaf.publish-$([guid]::NewGuid().ToString('N')).tmp")
    try {
        Write-PortableTemporaryFile -Path $temporary -Bytes $Bytes
        try { [IO.File]::Move($temporary, $target, -not $NoReplace) }
        catch [IO.IOException] {
            if ($NoReplace -and [IO.File]::Exists($target)) {
                throw (New-PortablePublicationException -Kind 'no-replace-target-exists' -Message 'No-replace publication target already exists.' -InnerException $_.Exception)
            }
            throw
        }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
    [ordered]@{
        receipt = [ordered]@{ durability = 'flushed'; publication = 'same-directory-move' }
        displacedPath = $displacedPath
        state = [ordered]@{ exists = $true; sha256 = $digest; length = [int64]$Bytes.Length }
    }
}

Export-ModuleMember -Function Get-PortablePathComparison, Resolve-PortableContainedPath, Test-PortableReparseItem,
    Test-PortablePhysicalIdentity, Resolve-PortableTrustedRoot, Enter-PortableFileLock, Get-PortableLockPrimitive,
    Get-PortablePlatformName, Get-PortableLeaseFileState, Get-PortableTransactionResidue, Publish-PortableLeaseFile
