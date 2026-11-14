Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('CodexAiInstructions.InstallerMutationSourceLoader' -as [type])) {
    try { Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace CodexAiInstructions
{
    [StructLayout(LayoutKind.Sequential)]
    internal struct InstallerSourceByHandleFileInformation
    {
        internal uint FileAttributes;
        internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        internal uint VolumeSerialNumber;
        internal uint FileSizeHigh;
        internal uint FileSizeLow;
        internal uint NumberOfLinks;
        internal uint FileIndexHigh;
        internal uint FileIndexLow;
    }

    public static class InstallerMutationSourceLoader
    {
        private const uint GenericRead = 0x80000000;
        private const uint FileReadAttributes = 0x00000080;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint OpenExisting = 3;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out InstallerSourceByHandleFileInformation fileInformation);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint pathLength, uint flags);

        public static byte[] ReadPhysicalSingleLinkFile(string path)
        {
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            try
            {
                if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                {
                    throw new InvalidDataException("Installer source path safety validation requires Windows.");
                }
                string fullPath = Path.GetFullPath(path);
                string root = Path.GetPathRoot(fullPath);
                if (string.IsNullOrEmpty(root) || string.Equals(fullPath.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("Installer source path safety validation requires a file below a filesystem root.");
                }

                SafeFileHandle rootHandle = OpenComponent(root, false);
                handles.Add(rootHandle);
                ValidateComponent(rootHandle, root, true, false);

                string current = root;
                string remainder = fullPath.Substring(root.Length);
                string[] segments = remainder.Split(new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
                if (segments.Length == 0)
                {
                    throw new InvalidDataException("Installer source path safety validation found no file component.");
                }
                SafeFileHandle target = null;
                for (int index = 0; index < segments.Length; index++)
                {
                    bool isTarget = index == segments.Length - 1;
                    current = Path.Combine(current, segments[index]);
                    SafeFileHandle handle = OpenComponent(current, isTarget);
                    handles.Add(handle);
                    ValidateComponent(handle, current, !isTarget, isTarget);
                    if (isTarget) target = handle;
                }
                string finalPath = GetFinalPath(target);
                if (!string.Equals(NormalizePath(finalPath), NormalizePath(fullPath), StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidDataException("Installer source path safety rejected a path that resolved through a different physical location: " + fullPath);
                }

                using (SafeFileHandle borrowed = new SafeFileHandle(target.DangerousGetHandle(), false))
                using (FileStream stream = new FileStream(borrowed, FileAccess.Read))
                using (MemoryStream memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    return memory.ToArray();
                }
            }
            catch (InvalidDataException)
            {
                throw;
            }
            catch (Exception ex)
            {
                throw new InvalidDataException("Installer source path safety validation failed: " + ex.Message, ex);
            }
            finally
            {
                for (int index = handles.Count - 1; index >= 0; index--)
                {
                    handles[index].Dispose();
                }
            }
        }

        private static SafeFileHandle OpenComponent(string path, bool isTarget)
        {
            uint access = isTarget ? GenericRead | FileReadAttributes : 0u;
            uint share = FileShareRead | (isTarget ? 0u : FileShareWrite | FileShareDelete);
            SafeFileHandle handle = CreateFile(
                path,
                access,
                share,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new InvalidDataException("Installer source path safety validation could not open '" + path + "': " + new Win32Exception(error).Message);
            }
            return handle;
        }

        private static void ValidateComponent(SafeFileHandle handle, string path, bool expectDirectory, bool requireSingleLink)
        {
            InstallerSourceByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new InvalidDataException("Installer source path safety validation could not inspect '" + path + "'.");
            }
            if ((information.FileAttributes & FileAttributeReparsePoint) != 0)
            {
                throw new InvalidDataException("Installer source path safety rejected a reparse point: " + path);
            }
            bool isDirectory = (information.FileAttributes & FileAttributeDirectory) != 0;
            if (isDirectory != expectDirectory)
            {
                throw new InvalidDataException("Installer source path safety rejected a non-regular path component: " + path);
            }
            if (requireSingleLink && information.NumberOfLinks != 1)
            {
                throw new InvalidDataException("Installer source link count must be exactly one: " + path);
            }
        }

        private static string GetFinalPath(SafeFileHandle handle)
        {
            StringBuilder buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity)
            {
                throw new InvalidDataException("Installer source path safety could not resolve the opened source identity.");
            }
            return buffer.ToString();
        }

        private static string NormalizePath(string path)
        {
            if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = @"\\" + path.Substring(8);
            else if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) path = path.Substring(4);
            return Path.GetFullPath(path).TrimEnd('\\');
        }
    }
}
'@ -ErrorAction Stop }
    catch { throw [IO.InvalidDataException]::new("The installer source path-safety helper could not be compiled: $($_.Exception.Message)",$_.Exception) }
}

if (-not ('CodexAiInstructions.InstallerNativeMutation' -as [type])) {
    try {
        $manifestPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'platform-runtime.psd1'))
        $nativeSourcePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'platform/WindowsInstallerMutation.cs'))
        [byte[]]$manifestBytes = [CodexAiInstructions.InstallerMutationSourceLoader]::ReadPhysicalSingleLinkFile($manifestPath)
        [byte[]]$nativeSourceBytes = [CodexAiInstructions.InstallerMutationSourceLoader]::ReadPhysicalSingleLinkFile($nativeSourcePath)
        $utf8 = [Text.UTF8Encoding]::new($false,$true)
        foreach($item in @(@('manifest',$manifestBytes),@('native source',$nativeSourceBytes))) {
            [byte[]]$bytes=$item[1]
            if($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
                throw [IO.InvalidDataException]::new("The installer $($item[0]) must be UTF-8 without BOM.")
            }
        }
        $manifestText=$utf8.GetString($manifestBytes)
        $tokens=$null;$parseErrors=$null
        $manifestAst=[Management.Automation.Language.Parser]::ParseInput($manifestText,[ref]$tokens,[ref]$parseErrors)
        if(@($parseErrors).Count -ne 0 -or $manifestAst.EndBlock.Statements.Count -ne 1 -or
            $manifestAst.EndBlock.Statements[0] -isnot [Management.Automation.Language.PipelineAst] -or
            $manifestAst.EndBlock.Statements[0].PipelineElements.Count -ne 1 -or
            $manifestAst.EndBlock.Statements[0].PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst] -or
            $manifestAst.EndBlock.Statements[0].PipelineElements[0].Expression -isnot [Management.Automation.Language.HashtableAst]) {
            throw [IO.InvalidDataException]::new('The installer platform runtime manifest is not a safe data-file hashtable.')
        }
        $manifest=$manifestAst.EndBlock.Statements[0].PipelineElements[0].Expression.SafeGetValue()
        if($null -eq $manifest.PrivateData -or $null -eq $manifest.PrivateData.PlatformRuntime -or
            [string]$manifest.PrivateData.PlatformRuntime.HashMode -cne 'sha256-utf8-lf') {
            throw [IO.InvalidDataException]::new('The installer platform runtime manifest has no supported inventory hash mode.')
        }
        $entries=@($manifest.PrivateData.PlatformRuntime.Inventory | Where-Object { [string]$_.Path -ceq 'platform/WindowsInstallerMutation.cs' })
        if($entries.Count -ne 1 -or [string]$entries[0].Sha256 -cnotmatch '^[0-9a-f]{64}$') {
            throw [IO.InvalidDataException]::new('The installer platform runtime manifest must bind exactly one native source inventory entry.')
        }
        $nativeSourceText=$utf8.GetString($nativeSourceBytes)
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $actualHash=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($nativeSourceText.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if($actualHash -cne [string]$entries[0].Sha256) {
            throw [IO.InvalidDataException]::new('The installer mutation native source hash mismatch rejected compilation.')
        }
        Add-Type -TypeDefinition $nativeSourceText -ErrorAction Stop
    }
    catch {
        if($_.Exception -is [IO.InvalidDataException]) { throw }
        throw [IO.InvalidDataException]::new("The installer mutation native source could not be verified and compiled: $($_.Exception.Message)",$_.Exception)
    }
}

function Open-InstallerMutationDirectoryGuard {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $RelativeDirectory
    )

    return [CodexAiInstructions.InstallerNativeMutation]::OpenDirectoryGuard($TargetRoot,$RelativeDirectory)
}

function Assert-InstallerMutationFileOwnership {
    param([Parameter(Mandatory = $true)][string] $Path)

    [CodexAiInstructions.InstallerNativeMutation]::AssertSingleLinkFile($Path)
}

function Test-InstallerSafeBytesEqual {
    param(
        [AllowNull()][byte[]] $Left,
        [AllowNull()][byte[]] $Right
    )

    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function Read-InstallerSafeStreamBytes {
    param([Parameter(Mandatory = $true)][System.IO.FileStream] $Stream)

    $memory = New-Object System.IO.MemoryStream
    try {
        $Stream.Position = 0
        $Stream.CopyTo($memory)
        return ,([byte[]]$memory.ToArray())
    }
    finally { $memory.Dispose() }
}

function Write-InstallerSafeStreamBytes {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes
    )

    $Stream.Position = 0
    $Stream.SetLength(0)
    if ($Bytes.Length -gt 0) { $Stream.Write($Bytes,0,$Bytes.Length) }
    $Stream.Flush($true)
}

function Set-InstallerSafeFileBytes {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]] $Bytes,
        [AllowNull()][AllowEmptyCollection()][byte[]] $ExpectedBytes,
        [switch] $ExpectMissing
    )

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "Installer safe mutation requires Windows: $RelativePath"
    }
    $hasExpectedBytes = $PSBoundParameters.ContainsKey('ExpectedBytes')
    if ($ExpectMissing -and $hasExpectedBytes) {
        throw "Installer safe mutation cannot require both missing state and expected bytes: $RelativePath"
    }
    $targetPath = Join-Path ([System.IO.Path]::GetFullPath($TargetRoot)) $RelativePath.Replace('/','\')
    $context = $null
    $handle = $null
    $stream = $null
    try {
        $context = [CodexAiInstructions.InstallerNativeMutation]::OpenForAtomicWriteOrCreate(
            $TargetRoot,$targetPath,$RelativePath)
        $handle = $context.TakeFileHandle()
        $stream = [System.IO.FileStream]::new($handle,[System.IO.FileAccess]::ReadWrite)
        $handle = $null
        [byte[]]$originalBytes = Read-InstallerSafeStreamBytes -Stream $stream
        if ($ExpectMissing -and -not [bool]$context.Created) {
            throw "Installer destination changed concurrently; an unexpected file was preserved: $RelativePath"
        }
        if ($hasExpectedBytes -and [bool]$context.Created) {
            [CodexAiInstructions.InstallerNativeMutation]::MarkDeleteOnClose($stream.SafeFileHandle)
            throw "Installer destination changed concurrently; the expected file is missing: $RelativePath"
        }
        if ($hasExpectedBytes -and -not (Test-InstallerSafeBytesEqual -Left $originalBytes -Right $ExpectedBytes)) {
            throw "Installer destination changed concurrently; current bytes were preserved: $RelativePath"
        }
        try {
            Write-InstallerSafeStreamBytes -Stream $stream -Bytes $Bytes
            [byte[]]$writtenBytes = Read-InstallerSafeStreamBytes -Stream $stream
            if (-not (Test-InstallerSafeBytesEqual -Left $writtenBytes -Right $Bytes)) {
                throw "Installer destination did not retain the exact requested bytes: $RelativePath"
            }
        }
        catch {
            $writeError = $_
            try {
                if ([bool]$context.Created) {
                    [CodexAiInstructions.InstallerNativeMutation]::MarkDeleteOnClose($stream.SafeFileHandle)
                }
                else {
                    Write-InstallerSafeStreamBytes -Stream $stream -Bytes $originalBytes
                    [byte[]]$restoredBytes = Read-InstallerSafeStreamBytes -Stream $stream
                    if (-not (Test-InstallerSafeBytesEqual -Left $restoredBytes -Right $originalBytes)) {
                        throw 'The original installer destination bytes were not restored exactly.'
                    }
                }
            }
            catch {
                throw "Installer destination write failed and its single-file rollback also failed: $RelativePath. Original: $($writeError.Exception.Message). Rollback: $($_.Exception.Message)"
            }
            throw $writeError
        }
    }
    finally {
        if ($null -ne $stream) {
            try {
                if ($null -ne $context -and $context.RestoreReadOnly) {
                    [CodexAiInstructions.InstallerNativeMutation]::RestoreReadOnly($stream.SafeFileHandle)
                }
            }
            finally { $stream.Dispose() }
        }
        if ($null -ne $handle) { $handle.Dispose() }
        if ($null -ne $context) { $context.Dispose() }
    }
}

function Set-InstallerSafeFileFromSource {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [Parameter(Mandatory = $true)][string] $Source,
        [AllowNull()][AllowEmptyCollection()][byte[]] $ExpectedBytes,
        [switch] $ExpectMissing
    )

    $arguments = @{
        TargetRoot = $TargetRoot
        RelativePath = $RelativePath
        Bytes = [System.IO.File]::ReadAllBytes($Source)
    }
    if ($PSBoundParameters.ContainsKey('ExpectedBytes')) { $arguments.ExpectedBytes = $ExpectedBytes }
    if ($ExpectMissing) { $arguments.ExpectMissing = $true }
    Set-InstallerSafeFileBytes @arguments
}

function Remove-InstallerSafeFile {
    param(
        [Parameter(Mandatory = $true)][string] $TargetRoot,
        [Parameter(Mandatory = $true)][string] $RelativePath,
        [AllowNull()][AllowEmptyCollection()][byte[]] $ExpectedBytes
    )

    $targetPath = Join-Path ([System.IO.Path]::GetFullPath($TargetRoot)) $RelativePath.Replace('/','\')
    $handle = $null
    $stream = $null
    try {
        $handle = [CodexAiInstructions.InstallerNativeMutation]::OpenForAtomicDelete(
            $TargetRoot,$targetPath,$RelativePath)
        $stream = [System.IO.FileStream]::new($handle,[System.IO.FileAccess]::Read)
        $handle = $null
        if ($PSBoundParameters.ContainsKey('ExpectedBytes')) {
            [byte[]]$currentBytes = Read-InstallerSafeStreamBytes -Stream $stream
            if (-not (Test-InstallerSafeBytesEqual -Left $currentBytes -Right $ExpectedBytes)) {
                throw "Installer rollback detected concurrent destination bytes; the current file was preserved: $RelativePath"
            }
        }
        [CodexAiInstructions.InstallerNativeMutation]::MarkDeleteOnClose($stream.SafeFileHandle)
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

Export-ModuleMember -Function @(
    'Open-InstallerMutationDirectoryGuard',
    'Assert-InstallerMutationFileOwnership',
    'Set-InstallerSafeFileBytes',
    'Set-InstallerSafeFileFromSource',
    'Remove-InstallerSafeFile'
)
