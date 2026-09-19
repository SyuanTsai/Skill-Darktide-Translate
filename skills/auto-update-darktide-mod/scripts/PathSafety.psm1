# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT -and
    $null -eq ('SyuanTsai.PathSafetyNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
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

        public static bool TryGetDirectoryCaseSensitive(string path, out bool caseSensitive) {
            caseSensitive = false;
            using (SafeFileHandle handle = CreateFile(
                path,
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
                path,
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
        [AllowEmptyCollection()][string[]] $Paths = @()
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
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

function Test-PortableReparseItem {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][object] $Item,
        [string] $Label = 'path'
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
    # This comparison only terminates the lexical ancestor walk; it does not
    # authorize containment. Containment is established by the caller's
    # boundary-aware path checks.
    $pathComparison = [StringComparison]::OrdinalIgnoreCase
    for ($depth = 0; $depth -lt 2048; $depth++) {
        foreach ($info in @([IO.FileInfo]::new($probe), [IO.DirectoryInfo]::new($probe))) {
            try {
                if (-not [string]::IsNullOrWhiteSpace([string]$info.LinkTarget)) { return $true }
                if ($info.Exists -and (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { return $true }
            }
            catch [IO.FileNotFoundException] { }
            catch [IO.DirectoryNotFoundException] { }
            catch {
                throw "Unable to inspect $Label physical containment component: $($_.Exception.Message)"
            }
        }
        $parent = [IO.DirectoryInfo]::new($probe).Parent
        if ($null -eq $parent -or $parent.FullName.Equals($probe, $pathComparison)) {
            break
        }
        $probe = $parent.FullName
    }
    $false
}

function Test-PortablePhysicalIdentity {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $PathA,
        [Parameter(Mandatory)][string] $PathB
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
        $null -eq ('SyuanTsai.PathSafetyNative' -as [type])) {
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
    $volumeA -eq $volumeB -and $fileA -eq $fileB
}

Export-ModuleMember -Function Get-PortablePathComparison, Test-PortableReparseItem, Test-PortablePhysicalIdentity
