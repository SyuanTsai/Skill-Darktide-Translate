# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
    $null -eq ('SyuanTsai.PathSafetyNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;

namespace SyuanTsai {
    public static class PathSafetyNative {
        // A zero desired-access handle is sufficient for the case-sensitivity
        // query and also works for user-profile directories whose ACLs reject
        // FILE_READ_ATTRIBUTES even though the directory itself is traversable.
        private const uint FileReadAttributes = 0x00000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        // NtQueryInformationFile uses the native FILE_INFORMATION_CLASS value,
        // while GetFileInformationByHandleEx uses the Win32
        // FILE_INFO_BY_HANDLE_CLASS value for the same information.
        private const int NtFileCaseSensitiveInformation = 71;
        private const int Win32FileCaseSensitiveInformation = 23;
        private const uint CaseSensitiveDirectoryFlag = 0x00000001;

        [StructLayout(LayoutKind.Sequential)]
        private struct FileCaseSensitiveInformationBuffer {
            public uint Flags;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock {
            public IntPtr Status;
            public IntPtr Information;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeFileTime {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ByHandleFileInformationBuffer {
            public uint FileAttributes;
            public NativeFileTime CreationTime;
            public NativeFileTime LastAccessTime;
            public NativeFileTime LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle CreateFile(
            string path,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationFile(
            SafeFileHandle fileHandle,
            out IoStatusBlock ioStatusBlock,
            out FileCaseSensitiveInformationBuffer fileInformation,
            uint length,
            int fileInformationClass);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "GetFileInformationByHandleEx")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle fileHandle,
            int fileInformationClass,
            out FileCaseSensitiveInformationBuffer fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "GetFileInformationByHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle fileHandle,
            out ByHandleFileInformationBuffer fileInformation);

        private static string GetNativeOpenPath(string path) {
            if (path == null || path.Length < 260 || path.IndexOf('/') >= 0 ||
                path.StartsWith(@"\\?\", StringComparison.Ordinal) ||
                path.StartsWith(@"\\.\", StringComparison.Ordinal)) {
                return path;
            }
            bool drivePath = path.Length >= 3 &&
                ((path[0] >= 'A' && path[0] <= 'Z') || (path[0] >= 'a' && path[0] <= 'z')) &&
                path[1] == ':' && path[2] == '\\';
            bool uncPath = path.StartsWith(@"\\", StringComparison.Ordinal);
            if ((!drivePath && !uncPath) || path.IndexOf(':', drivePath ? 2 : 0) >= 0) {
                return path;
            }
            // Extended syntax bypasses Win32 normalization. Preserve the old
            // open semantics for inputs that are not ordinary canonical paths.
            string[] components = path.Substring(drivePath ? 3 : 2).Split('\\');
            foreach (string component in components) {
                if (component.EndsWith(".", StringComparison.Ordinal) ||
                    component.EndsWith(" ", StringComparison.Ordinal)) {
                    return path;
                }
            }
            try {
                if (!String.Equals(Path.GetFullPath(path), path, StringComparison.Ordinal)) {
                    return path;
                }
            }
            catch (ArgumentException) { return path; }
            catch (NotSupportedException) { return path; }
            catch (PathTooLongException) { return path; }
            return uncPath ? @"\\?\UNC\" + path.Substring(2) : @"\\?\" + path;
        }

        public static bool TryGetDirectoryCaseSensitive(string path, out bool caseSensitive) {
            caseSensitive = false;
            using (SafeFileHandle handle = CreateFile(
                GetNativeOpenPath(path),
                FileReadAttributes,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero)) {
                if (handle == null || handle.IsInvalid) {
                    return false;
                }

                FileCaseSensitiveInformationBuffer information;
                IoStatusBlock ioStatusBlock;
                int status = NtQueryInformationFile(
                    handle,
                    out ioStatusBlock,
                    out information,
                    (uint)Marshal.SizeOf(typeof(FileCaseSensitiveInformationBuffer)),
                    NtFileCaseSensitiveInformation);
                if (status != 0 && !GetFileInformationByHandleEx(
                    handle,
                    Win32FileCaseSensitiveInformation,
                    out information,
                    (uint)Marshal.SizeOf(typeof(FileCaseSensitiveInformationBuffer)))) {
                    return false;
                }

                caseSensitive = (information.Flags & CaseSensitiveDirectoryFlag) != 0;
                return true;
            }
        }

        public static bool TryGetPhysicalFileIdentity(
            string path,
            out ulong volumeSerialNumber,
            out ulong fileIndex) {
            volumeSerialNumber = 0;
            fileIndex = 0;
            using (SafeFileHandle handle = CreateFile(
                GetNativeOpenPath(path),
                0,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero)) {
                if (handle == null || handle.IsInvalid) {
                    return false;
                }

                ByHandleFileInformationBuffer information;
                if (!GetFileInformationByHandle(handle, out information)) {
                    return false;
                }

                volumeSerialNumber = information.VolumeSerialNumber;
                fileIndex = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
                return true;
            }
        }
    }
}
'@
}

# The Skill runtime has no access to the AI-Instructions authority checkout at
# run time. The authority platform runtime is therefore vendored byte-for-byte
# below scripts/platform-runtime and every file is bound to the reviewed
# authority revision before the module is imported. Any missing, extra, or
# changed file, or any load failure, stops the Skill (fail closed); there is no
# local substitute implementation of the Unix identity or lock primitives.
$script:VendoredPlatformRuntimeAuthority = [ordered]@{
    repository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
    commit = 'fbdc793c1c439b15c6def97d53111f250d0ff4db'
    sourceDirectory = 'scripts'
    hashMode = 'sha256-raw-bytes'
    manifestPath = 'platform-runtime.psd1'
    manifestSha256 = 'd3d8eef434484b3b2449cd4762e60b94afc314d9beb91481538c7f57207a11c9'
}
$script:VendoredPlatformRuntimeFiles = [ordered]@{
    'platform-runtime.psd1' = 'd3d8eef434484b3b2449cd4762e60b94afc314d9beb91481538c7f57207a11c9'
    'platform-runtime.psm1' = 'ad051b2794ce4dc10108404201735d02f7b032ed0e633c5f22f73c884fb10370'
    'installer-safe-mutation.psm1' = 'dc031edcc2f48968df83cd68ad52eacb7f7b05d3ca6a0cc622658cf6151c8293'
    'WindowsDacl.psm1' = 'ffa1f85d94bb6bce9bf8353f8c7733bdbe59880a3d0d075191938cc28aebb5f6'
    'Resolve-StandardValidationTool.ps1' = 'c0d68b227fc04e19d710a89c4559fe45e0cc979eead846006261dc2dc5bfa14f'
    'platform/Linux.psm1' = '52c261d577ee7b3946771d1112030996896fdd119e06ac3849e430a3d56fb38c'
    'platform/MacOS.psm1' = '8f25edfbee5ab36b5e1c42eb55c6dbab44db0bc29896c180612b1248920c7c47'
    'platform/OwnedProcess.cs' = '097061ad5902f896ff74b3f60b0ecaf63f3d58f357aed8fdbf80a8586564de58'
    'platform/PlatformNative.cs' = 'f9da23bf3e6e3c8960b26d534e14873f6b4fc98b3d13f5b6cdfdd5f7716a4514'
    'platform/RuntimePreparation.psm1' = 'dc254c04e7e2caf280726e66f67434776bc7df12a210a38c80596e41344fd077'
    'platform/Unix.psm1' = 'ec3b3bb0b39e1ce84d4c8f60a78c44fb40cb9d58c13ed88a6b9d9db978fcc147'
    'platform/UnixNative.cs' = '171da4acded889da89ab4e7af2729e9bbf4f3639cf1e63fe08a4c046f7545c74'
    'platform/UnixProcess.cs' = '125d2b3eecdad6a6c201d5f5d61a6efd0ad55ba93822c7b83a679a5397005db1'
    'platform/Windows.psm1' = '9b7442178083a9b165ed3bf53367d5c3ce1b1f09d56f0f6efe964b524e17be0b'
    'platform/WindowsInstallerMutation.cs' = 'b88b4b09c7bb5c3e71b762ddc6ebe72007ed0cca99977ab7a7272529c3ff9218'
    'platform/WindowsNative.cs' = '6eea8ca2701b6a6de88ee4a3348f053d07a0543d607832e667335c838bb7d433'
    'platform/WindowsProcess.cs' = '7b8a0cddd3b9809b861801fe1d6a618684e2ca6fa13f9334825c5c9da5b2d8d6'
}
$script:VendoredPlatformRuntimeRoot = Join-Path $PSScriptRoot 'platform-runtime'

function Get-VendoredPlatformRuntimeSha256 {
    param([Parameter(Mandatory)][string] $LiteralPath)
    [byte[]]$bytes = [IO.File]::ReadAllBytes($LiteralPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw [IO.InvalidDataException]::new('Vendored platform runtime files must be UTF-8 without BOM.')
    }
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha256.Dispose() }
}

function Assert-VendoredPlatformRuntime {
    [CmdletBinding()]
    param([string] $Root = $script:VendoredPlatformRuntimeRoot)

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem -or -not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $rootItem.LinkType) {
        throw [IO.InvalidDataException]::new('Vendored platform runtime directory is missing or is not a regular directory.')
    }
    $actualFiles = [Collections.Generic.List[string]]::new()
    foreach ($entry in @(Get-ChildItem -LiteralPath $rootFull -Recurse -Force)) {
        $relative = [IO.Path]::GetRelativePath($rootFull, $entry.FullName).Replace('\', '/')
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $entry.LinkType) {
            throw [IO.InvalidDataException]::new("Vendored platform runtime contains a link or reparse point: $relative")
        }
        if ($entry.PSIsContainer) {
            if ($relative -cne 'platform') {
                throw [IO.InvalidDataException]::new("Vendored platform runtime contains an unexpected directory: $relative")
            }
            continue
        }
        $actualFiles.Add($relative)
    }
    [string[]]$expected = @($script:VendoredPlatformRuntimeFiles.Keys)
    [string[]]$actual = $actualFiles.ToArray()
    [Array]::Sort($expected, [StringComparer]::Ordinal)
    [Array]::Sort($actual, [StringComparer]::Ordinal)
    if (($expected -join "`n") -cne ($actual -join "`n")) {
        throw [IO.InvalidDataException]::new('Vendored platform runtime file set differs from its authority registry.')
    }
    $verified = [Collections.Generic.List[object]]::new()
    foreach ($relative in $expected) {
        $actualHash = Get-VendoredPlatformRuntimeSha256 -LiteralPath (Join-Path $rootFull $relative)
        if ($actualHash -cne [string]$script:VendoredPlatformRuntimeFiles[$relative]) {
            throw [IO.InvalidDataException]::new("Vendored platform runtime hash mismatch: $relative")
        }
        $verified.Add([pscustomobject][ordered]@{ path = $relative; sha256 = $actualHash })
    }
    $manifestHash = Get-VendoredPlatformRuntimeSha256 -LiteralPath (Join-Path $rootFull $script:VendoredPlatformRuntimeAuthority.manifestPath)
    if ($manifestHash -cne [string]$script:VendoredPlatformRuntimeAuthority.manifestSha256) {
        throw [IO.InvalidDataException]::new('Vendored platform runtime manifest pin mismatch.')
    }
    [pscustomobject][ordered]@{
        authorityRepository = [string]$script:VendoredPlatformRuntimeAuthority.repository
        authorityCommit = [string]$script:VendoredPlatformRuntimeAuthority.commit
        authoritySourceDirectory = [string]$script:VendoredPlatformRuntimeAuthority.sourceDirectory
        hashMode = [string]$script:VendoredPlatformRuntimeAuthority.hashMode
        manifestSha256 = $manifestHash
        root = $rootFull
        files = [object[]]$verified.ToArray()
    }
}

function Assert-VendoredPlatformRuntimePostLoad {
    param([Parameter(Mandatory)][string] $Root)

    $manifestPath = Join-Path $Root ([string]$script:VendoredPlatformRuntimeAuthority.manifestPath)
    $null = Assert-PlatformRuntimeInventory -Root $Root -ManifestPath $manifestPath
    foreach ($relative in @($script:VendoredPlatformRuntimeFiles.Keys)) {
        $parentLease = $null
        $fileLease = $null
        try {
            $parentRelative = [IO.Path]::GetDirectoryName([string]$relative)
            $parentLease = if ([string]::IsNullOrWhiteSpace($parentRelative)) {
                Open-PlatformDirectory -Root $Root -RootOnly
            }
            else {
                Open-PlatformDirectory -Root $Root -RelativePath $parentRelative.Replace('\', '/')
            }
            $fileLease = Open-PlatformFile -ParentLease $parentLease -Leaf ([IO.Path]::GetFileName([string]$relative)) `
                -Access Read -CreateMode OpenExisting
            $null = Assert-PlatformFileIdentity -Lease $fileLease -Expected $fileLease.Observation -SingleLink -VerifyPath
        }
        finally {
            if ($null -ne $fileLease) { $fileLease.Dispose() }
            if ($null -ne $parentLease) { $parentLease.Dispose() }
        }
    }
}

function ConvertTo-PortablePlatformFileIdentity {
    param([Parameter(Mandatory)] $Observation)
    if ((Get-PortablePlatformName) -ceq 'windows') {
        return [pscustomobject][ordered]@{
            kind = 'windows-file-id'
            device = ('0x{0:x}' -f [uint64]$Observation.Device)
            fileId = ('0x{0:x}' -f [uint64]$Observation.Inode)
        }
    }
    [pscustomobject][ordered]@{
        kind = 'unix-device-inode'
        device = ('0x{0:x}' -f [uint64]$Observation.Device)
        fileId = ('0x{0:x}' -f [uint64]$Observation.Inode)
    }
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
    $parentLease = $null
    $fileLease = $null
    try {
        $parentLease = Open-PlatformDirectory -Root $ParentPath -RootOnly
        try {
            $fileLease = Open-PlatformFile -ParentLease $parentLease -Leaf $Leaf -Access Read -CreateMode OpenExisting
        }
        catch {
            $fileFailure = $_
            $legacyDirectory = $null
            try { $legacyDirectory = Open-PlatformDirectory -Root $ParentPath -RelativePath $Leaf }
            catch { }
            if ($null -ne $legacyDirectory) {
                $legacyDirectory.Dispose()
                if ([string]::IsNullOrWhiteSpace($LegacyDirectoryMessage)) {
                    throw [IO.InvalidDataException]::new("The lease path is a legacy directory: $Leaf")
                }
                throw [IO.InvalidDataException]::new($LegacyDirectoryMessage)
            }
            if ($AllowMissing) {
                return [ordered]@{
                    exists = $false
                    bytes = $null
                    sha256 = $null
                    length = $null
                    identity = $null
                }
            }
            throw $fileFailure
        }
        [byte[]]$bytes = $fileLease.ReadAllBytes($MaximumBytes)
        $observation = Assert-PlatformFileIdentity -Lease $fileLease -Expected $fileLease.Observation -SingleLink -VerifyPath
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $digest = ([BitConverter]::ToString($sha256.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        [ordered]@{
            exists = $true
            bytes = $bytes
            sha256 = $digest
            length = [int64]$bytes.Length
            identity = ConvertTo-PortablePlatformFileIdentity -Observation $observation
        }
    }
    finally {
        if ($null -ne $fileLease) { $fileLease.Dispose() }
        if ($null -ne $parentLease) { $parentLease.Dispose() }
    }
}

function Remove-PortableTransactionFile {
    param(
        [Parameter(Mandatory)] $TransactionLease,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)] $ExpectedState
    )
    # Authority cleanup mode applies only to a file already inside the
    # .ai-instructions-txn/<id> directory. Omitting both optional tombstone
    # parameters is intentional; supplying only one is invalid on Unix.
    $parameters = @{
        ParentLease = $TransactionLease
        Leaf = $Leaf
        ExpectedState = $ExpectedState
    }
    $null = Remove-PlatformOwnedFile @parameters
}

function Publish-PortableLeaseFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ParentPath,
        [Parameter(Mandatory)][string] $Leaf,
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][Collections.IDictionary] $ExpectedState,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string] $TransactionId,
        [switch] $NoReplace,
        [switch] $PreserveDisplaced
    )
    if ($PreserveDisplaced -and -not [bool]$ExpectedState.exists) {
        throw [ArgumentException]::new('A displaced file can be preserved only for an existing expected state.')
    }
    $parentLease = $null
    $transactionRootLease = $null
    $transactionLease = $null
    $stageLease = $null
    $stageLeaf = 'stage-' + [guid]::NewGuid().ToString('N')
    $displacedLeaf = if ([bool]$ExpectedState.exists) { 'previous-' + [guid]::NewGuid().ToString('N') } else { $null }
    $transactionRootPath = Join-Path $ParentPath '.ai-instructions-txn'
    $stageState = $null
    $published = $false
    $displacedPath = $null
    try {
        $parentLease = Open-PlatformDirectory -Root $ParentPath -RootOnly
        try { $transactionRootLease = Open-PlatformDirectory -Root $ParentPath -RelativePath '.ai-instructions-txn' -CreatePrivate }
        catch { $transactionRootLease = Open-PlatformDirectory -Root $ParentPath -RelativePath '.ai-instructions-txn' }
        try { $transactionLease = Open-PlatformDirectory -Root $transactionRootPath -RelativePath $TransactionId -CreatePrivate }
        catch { $transactionLease = Open-PlatformDirectory -Root $transactionRootPath -RelativePath $TransactionId }
        $stageLease = Open-PlatformFile -ParentLease $transactionLease -Leaf $stageLeaf -Access ReadWrite -CreateMode CreateNew
        $stageLease.WriteNewBytes($Bytes)
        $stageObservation = Assert-PlatformFileIdentity -Lease $stageLease -Expected $stageLease.Observation -SingleLink -VerifyPath
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try { $digest = ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
        finally { $sha256.Dispose() }
        $stageState = [ordered]@{
            exists = $true
            sha256 = $digest
            length = [int64]$Bytes.Length
            identity = ConvertTo-PortablePlatformFileIdentity -Observation $stageObservation
        }
        $parameters = @{
            ParentLease = $parentLease
            Leaf = $Leaf
            TransactionLease = $transactionLease
            StageLease = $stageLease
            ExpectedState = $ExpectedState
            ExpectedStage = $stageState
        }
        if ($NoReplace) { $parameters.NoReplace = $true }
        if ($null -ne $displacedLeaf) { $parameters.DisplacedLeaf = $displacedLeaf }
        $receipt = Publish-PlatformFile @parameters
        $published = $true
        if ([string]$receipt.durability -cne 'confirmed') {
            throw [IO.IOException]::new('Lease publication durability was not confirmed.')
        }
        if ($null -ne $displacedLeaf) {
            if ([string]$receipt.displacedLeaf -cne $displacedLeaf -or $null -eq $receipt.displacedIdentity) {
                throw [IO.InvalidDataException]::new('Lease CAS publication did not return the exact displaced file evidence.')
            }
            $displacedState = [ordered]@{
                exists = $true
                sha256 = [string]$ExpectedState.sha256
                length = [int64]$ExpectedState.length
                identity = $receipt.displacedIdentity
            }
            if ($PreserveDisplaced) {
                $displacedPath = [IO.Path]::GetFullPath((Join-Path (Join-Path $transactionRootPath $TransactionId) $displacedLeaf))
            }
            else {
                Remove-PortableTransactionFile -TransactionLease $transactionLease -Leaf $displacedLeaf -ExpectedState $displacedState
            }
        }
        [ordered]@{
            receipt = $receipt
            displacedPath = $displacedPath
            state = [ordered]@{
                exists = $true
                sha256 = $digest
                length = [int64]$Bytes.Length
                identity = $receipt.appliedIdentity
            }
        }
    }
    catch {
        $publicationFailure = $_
        if (-not $published -and $null -ne $stageState) {
            try {
                if ($null -ne $stageLease) { $stageLease.Dispose(); $stageLease = $null }
                Remove-PortableTransactionFile -TransactionLease $transactionLease -Leaf $stageLeaf -ExpectedState $stageState
            }
            catch { }
        }
        throw $publicationFailure
    }
    finally {
        if ($null -ne $stageLease) { $stageLease.Dispose() }
        if ($null -ne $transactionLease) { $transactionLease.Dispose() }
        if ($null -ne $transactionRootLease) { $transactionRootLease.Dispose() }
        if ($null -ne $parentLease) { $parentLease.Dispose() }
    }
}

try {
    $script:VendoredPlatformRuntimeBinding = Assert-VendoredPlatformRuntime
    $vendoredManifestPath = Join-Path $script:VendoredPlatformRuntimeRoot 'platform-runtime.psd1'
    $loadedPlatformRuntime = @(Import-Module -Name $vendoredManifestPath -PassThru -ErrorAction Stop)
    $expectedPlatformRuntimePath = [IO.Path]::GetFullPath((Join-Path $script:VendoredPlatformRuntimeRoot 'platform-runtime.psm1'))
    $platformRuntimePathComparer = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        [StringComparer]::OrdinalIgnoreCase
    }
    else { [StringComparer]::Ordinal }
    if ($loadedPlatformRuntime.Count -ne 1 -or
        -not $platformRuntimePathComparer.Equals([IO.Path]::GetFullPath([string]$loadedPlatformRuntime[0].Path), $expectedPlatformRuntimePath)) {
        throw [IO.InvalidDataException]::new('The vendored platform runtime did not load from its registry-bound path.')
    }
    Assert-VendoredPlatformRuntimePostLoad -Root $script:VendoredPlatformRuntimeRoot
    $script:VendoredPlatformRuntimeModule = $loadedPlatformRuntime[0]
}
catch {
    throw [IO.InvalidDataException]::new(
        ('The vendored authority platform runtime failed verification or loading; the Skill runtime stops: {0}' -f $_.Exception.Message),
        $_.Exception)
}

function Get-VendoredPlatformRuntimeBinding {
    $script:VendoredPlatformRuntimeBinding
}

function Get-PortablePlatformName {
    [OutputType([string])]
    param()
    [string][SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
}


function Get-WindowsPathCaseSensitivity {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Path
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        return $false
    }

    $probe = [IO.Path]::GetFullPath($Path)
    # This comparison only terminates the lexical ancestor walk; it does not
    # authorize containment. The authorization result is returned by the
    # filesystem case-sensitivity queries below.
    for ($depth = 0; $depth -lt 2048; $depth++) {
        $directory = [IO.DirectoryInfo]::new($probe)
        if ($directory.Exists) {
            $caseSensitive = $false
            if (-not [SyuanTsai.PathSafetyNative]::TryGetDirectoryCaseSensitive($directory.FullName, [ref]$caseSensitive)) {
                # An unsupported or inaccessible filesystem cannot prove its
                # comparison semantics, so callers must use strict comparison.
                return $null
            }
            if ($caseSensitive) {
                return $true
            }
        }

        $parent = $directory.Parent
        if ($null -eq $parent -or
            $parent.FullName.Equals($directory.FullName, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $probe = $parent.FullName
    }
    $false
}

function Get-PortablePathComparison {
    param(
        [AllowEmptyCollection()][string[]] $Paths = @(),
        # Containment proves that a path is inside a root, so an unknown case
        # policy must use strict comparison. Exclusion proves that a path is
        # outside a root, so an unknown case policy must ignore case; otherwise
        # a case alias on a case-insensitive volume would escape the check.
        [ValidateSet('Containment', 'Exclusion')][string] $Purpose = 'Containment'
    )

    if ($Purpose -ceq 'Exclusion') {
        # Exclusion is never weakened by a case-sensitive comparer on any host:
        # Linux volumes may be case-insensitive (for example vfat), macOS APFS is
        # usually case-insensitive, and Windows directories may be either.
        return [StringComparison]::OrdinalIgnoreCase
    }

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        # Linux is case-sensitive. macOS case sensitivity is per volume; strict
        # comparison is the conservative containment choice there as well.
        return [StringComparison]::Ordinal
    }

    if (@($Paths).Count -eq 0) {
        # No path context means that the filesystem semantics are unknown.
        # Strict comparison is the safe default for security-sensitive checks.
        return [StringComparison]::Ordinal
    }

    foreach ($path in @($Paths)) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            return [StringComparison]::Ordinal
        }
        $caseSensitive = Get-WindowsPathCaseSensitivity -Path $path
        if ($null -eq $caseSensitive -or $caseSensitive) {
            return [StringComparison]::Ordinal
        }
    }
    [StringComparison]::OrdinalIgnoreCase
}

function Resolve-PortableTrustedRoot {
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    # A trusted root is canonicalized to its physical path before it anchors
    # any descriptor walk. Operating-system aliases above the selected root,
    # such as macOS /var -> /private/var or /tmp -> /private/tmp, are resolved
    # here instead of being reported as managed-path symlinks.
    $full = [IO.Path]::GetFullPath($Path)
    $physical = [string](Resolve-PlatformPhysicalPath -Path $full)
    if ([string]::IsNullOrWhiteSpace($physical) -or -not [IO.Path]::IsPathFullyQualified($physical)) {
        throw "Trusted root could not be physically canonicalized: $full"
    }
    $rootLease = $null
    try {
        $rootLease = Open-PlatformDirectory -Root $physical -RootOnly
        $observation = Assert-PlatformFileIdentity -Lease $rootLease -Expected $rootLease.Observation -VerifyPath
        if ([string]$observation.Kind -cne 'directory') {
            throw "Trusted root is not an existing directory: $full"
        }
    }
    finally {
        if ($null -ne $rootLease) { $rootLease.Dispose() }
    }
    $physical
}

function Test-PortableReparseItem {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][object] $Item,
        [string] $Label = 'path',
        # Unix-like hosts stop the raw ancestor walk at this trusted root. The
        # root entry itself is still inspected; its own ancestors are trusted
        # operating-system aliases that physical canonicalization resolves.
        [AllowEmptyString()][string] $TrustedRoot
    )

    $inspectProviderItem = {
        param([AllowNull()][object] $Candidate)
        if ($null -eq $Candidate) { return $false }
        try {
            $attributesProperty = $Candidate.PSObject.Properties['Attributes']
            if ($null -ne $attributesProperty -and
                (($attributesProperty.Value -band [IO.FileAttributes]::ReparsePoint) -ne 0)) {
                return $true
            }
            $modeProperty = $Candidate.PSObject.Properties['Mode']
            if ($null -ne $modeProperty -and [string]$modeProperty.Value -match '^l') {
                return $true
            }
            foreach ($propertyName in @('LinkType', 'LinkTarget', 'Target')) {
                $property = $Candidate.PSObject.Properties[$propertyName]
                if ($null -eq $property) { continue }
                if ($propertyName -eq 'LinkType') {
                    if (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) { return $true }
                }
                elseif (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                    return $true
                }
            }
        }
        catch {
            throw "Unable to inspect $Label reparse metadata: $($_.Exception.Message)"
        }
        $false
    }

    if (& $inspectProviderItem $Item) { return $true }

    # FileInfo/DirectoryInfo.LinkTarget reads the directory entry itself and does
    # not follow a symlink. Some Unix providers return the symlink target as the
    # provider item, so always walk raw lexical ancestors even when $Item exists.
    # This also ensures a missing child below a symlink is rejected before it can
    # be treated as ordinary absence.
    $probe = [IO.Path]::GetFullPath($Path)
    $isWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
    $stopRoot = $null
    if (-not $isWindows) {
        # Unix ancestor checks stop at the trusted root. Without an explicit
        # root the walk covers the entry and its parent directory; callers that
        # prove containment walk every component up to their own root.
        $stopRoot = if ([string]::IsNullOrWhiteSpace($TrustedRoot)) {
            $parentPath = [IO.Path]::GetDirectoryName($probe)
            if ([string]::IsNullOrWhiteSpace($parentPath)) { $probe } else { $parentPath }
        }
        else {
            $candidateRoot = [IO.Path]::GetFullPath($TrustedRoot)
            if ($candidateRoot -cne [IO.Path]::GetPathRoot($candidateRoot)) {
                $candidateRoot = $candidateRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
            }
            $rootPrefix = if ($candidateRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) { $candidateRoot } else { $candidateRoot + [IO.Path]::DirectorySeparatorChar }
            if (-not $probe.Equals($candidateRoot, [StringComparison]::Ordinal) -and
                -not $probe.StartsWith($rootPrefix, [StringComparison]::Ordinal)) {
                throw "$Label is outside its trusted root."
            }
            $candidateRoot
        }
    }
    # On Windows this comparison only terminates the lexical ancestor walk; it
    # does not authorize containment. Containment is established by the caller's
    # boundary-aware path checks.
    $pathComparison = if ($isWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    for ($depth = 0; $depth -lt 2048; $depth++) {
        foreach ($info in @([IO.FileInfo]::new($probe), [IO.DirectoryInfo]::new($probe))) {
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$info.LinkTarget)) { return $true }
                if ($info.Exists -and (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $true }
            }
            catch [IO.FileNotFoundException] { }
            catch [IO.DirectoryNotFoundException] { }
            catch {
                throw ('Unable to inspect {0} physical containment component: {1}' -f ([string]$Label), ([string]$_.Exception.Message))
            }
        }
        if ($null -ne $stopRoot -and $probe.Equals($stopRoot, $pathComparison)) {
            break
        }
        $parent = [IO.DirectoryInfo]::new($probe).Parent
        if ($null -eq $parent -or $parent.FullName.Equals($probe, $pathComparison)) {
            break
        }
        $probe = $parent.FullName
    }
    $false
}

function Get-PortablePlatformErrno {
    [OutputType([Nullable[int]])]
    param([Parameter(Mandatory)] $Failure)

    $candidate = if ($Failure -is [Management.Automation.ErrorRecord]) { $Failure.Exception } else { $Failure }
    for ($depth = 0; $depth -lt 32 -and $null -ne $candidate; $depth++) {
        $errnoProperty = $candidate.PSObject.Properties['Errno']
        if ($null -ne $errnoProperty -and $null -ne $errnoProperty.Value) {
            $errno = 0
            if ([int]::TryParse([string]$errnoProperty.Value, [ref]$errno)) { return $errno }
        }
        $candidate = $candidate.InnerException
    }
    $null
}

function Get-PortableUnixObservation {
    param([Parameter(Mandatory)][string] $Path)

    # The vendored descriptor API opens every component with O_NOFOLLOW and
    # reports the kernel (st_dev, st_ino, st_nlink) tuple of the opened entry.
    $full = [IO.Path]::GetFullPath($Path)
    $parent = [IO.Path]::GetDirectoryName($full)
    $leaf = [IO.Path]::GetFileName($full)
    if ([string]::IsNullOrEmpty($parent) -or [string]::IsNullOrEmpty($leaf)) {
        throw "Physical identity requires a path below a filesystem root: $full"
    }
    $physicalParent = Resolve-PortableTrustedRoot -Path $parent
    $lease = $null
    try { $lease = Open-PlatformDirectory -Root $physicalParent -RelativePath $leaf }
    catch {
        $errno = Get-PortablePlatformErrno -Failure $_
        if ($errno -eq 2) { return $null }
        if ($errno -ne 20) { throw }
    }
    if ($null -ne $lease) {
        try {
            $observation = Assert-PlatformFileIdentity -Lease $lease -Expected $lease.Observation
        }
        finally { $lease.Dispose() }
        return $observation
    }
    $directory = Open-PlatformDirectory -Root $physicalParent -RootOnly
    try {
        # Open-PlatformFile rejects symlinks, non-regular files, and any managed
        # regular file whose link count is not exactly one (hard-link aliases).
        try { $file = Open-PlatformFile -ParentLease $directory -Leaf $leaf -Access Read -CreateMode OpenExisting }
        catch {
            if ((Get-PortablePlatformErrno -Failure $_) -eq 2) { return $null }
            throw
        }
        try {
            $observation = Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink
        }
        finally { $file.Dispose() }
    }
    finally { $directory.Dispose() }
    $observation
}

function Test-PortablePhysicalIdentity {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $PathA,
        [Parameter(Mandatory)][string] $PathB
    )

    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
        if ($null -eq ('SyuanTsai.PathSafetyNative' -as [type])) {
            return $false
        }
        [ulong]$volumeA = 0
        [ulong]$fileA = 0
        [ulong]$volumeB = 0
        [ulong]$fileB = 0
        if (-not [SyuanTsai.PathSafetyNative]::TryGetPhysicalFileIdentity($PathA, [ref]$volumeA, [ref]$fileA) -or
            -not [SyuanTsai.PathSafetyNative]::TryGetPhysicalFileIdentity($PathB, [ref]$volumeB, [ref]$fileB)) {
            return $false
        }
        return ($volumeA -eq $volumeB -and $fileA -eq $fileB)
    }

    # Unix physical identity is the kernel (st_dev, st_ino) pair from the
    # vendored authority runtime. A missing path has no identity.
    try {
        $observationA = Get-PortableUnixObservation -Path $PathA
        $observationB = Get-PortableUnixObservation -Path $PathB
    }
    catch {
        throw ('Unable to prove Unix physical identity: {0}' -f $_.Exception.Message)
    }
    if ($null -eq $observationA -or $null -eq $observationB) { return $false }
    [uint64]$observationA.Device -eq [uint64]$observationB.Device -and
        [uint64]$observationA.Inode -eq [uint64]$observationB.Inode -and
        [string]$observationA.Kind -ceq [string]$observationB.Kind
}

function Get-PortableLockPrimitive {
    [OutputType([string])]
    param()
    if ((Get-PortablePlatformName) -ceq 'windows') { 'windows-fileshare' } else { 'flock' }
}

function Enter-PortableFileLock {
    param(
        [Parameter(Mandatory)][string] $Root,
        [AllowEmptyString()][string] $RelativeDirectory = '',
        [Parameter(Mandatory)][string] $Leaf,
        [ValidateRange(0, 3600000)][int] $TimeoutMilliseconds = 15000,
        [string] $Label = 'coordination'
    )

    # Windows uses handle share modes; Linux and macOS use flock on a fixed
    # inode that is never unlinked. Both come from the vendored authority
    # runtime, so DOTNET_SYSTEM_IO_DISABLEFILELOCKING cannot disable them.
    $physicalRoot = Resolve-PortableTrustedRoot -Path $Root
    $relative = $RelativeDirectory.Replace('\', '/').Trim('/')
    $directory = if ([string]::IsNullOrEmpty($relative)) {
        Open-PlatformDirectory -Root $physicalRoot -RootOnly
    }
    else {
        Open-PlatformDirectory -Root $physicalRoot -RelativePath $relative
    }
    $lock = $null
    try {
        $lock = Enter-PlatformLock -ParentLease $directory -Leaf $Leaf -Mode Exclusive -Timeout ([TimeSpan]::FromMilliseconds($TimeoutMilliseconds))
    }
    catch {
        $directory.Dispose()
        $cause = $_.Exception
        while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
        if ($cause -is [TimeoutException]) {
            throw [TimeoutException]::new("Unable to acquire the $Label lock within $TimeoutMilliseconds milliseconds.")
        }
        throw
    }
    $handle = [pscustomobject][ordered]@{
        platform = Get-PortablePlatformName
        lockPrimitive = Get-PortableLockPrimitive
        path = [IO.Path]::Combine($physicalRoot, $relative, $Leaf)
        device = [uint64]$lock.Observation.Device
        inode = [uint64]$lock.Observation.Inode
        LockLease = $lock
        DirectoryLease = $directory
    }
    $handle | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        try { if ($null -ne $this.LockLease) { $this.LockLease.Dispose() } }
        finally {
            if ($null -ne $this.DirectoryLease) { $this.DirectoryLease.Dispose() }
            $this.LockLease = $null
            $this.DirectoryLease = $null
        }
    }
    $handle
}

Export-ModuleMember -Function Get-PortablePathComparison, Test-PortableReparseItem, Test-PortablePhysicalIdentity,
    Resolve-PortableTrustedRoot, Enter-PortableFileLock, Get-PortableLockPrimitive, Get-PortablePlatformName,
    Assert-VendoredPlatformRuntime, Get-VendoredPlatformRuntimeBinding, Get-PortableLeaseFileState,
    Publish-PortableLeaseFile
