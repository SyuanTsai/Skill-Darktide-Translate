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
        private const uint FileReadAttributes = 0x00000080;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const int FileCaseSensitiveInformation = 71;
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
                    FileCaseSensitiveInformation);
                if (status != 0) {
                    return false;
                }

                caseSensitive = (information.Flags & CaseSensitiveDirectoryFlag) != 0;
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
    $pathComparison = [StringComparison]::OrdinalIgnoreCase
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
    if ($null -ne $Item) { return $false }

    # FileInfo/DirectoryInfo.LinkTarget reads the directory entry itself and does
    # not follow a symlink. Walk lexical ancestors so a missing child below a
    # symlink is still rejected before it can be treated as ordinary absence.
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

Export-ModuleMember -Function Get-PortablePathComparison, Test-PortableReparseItem
