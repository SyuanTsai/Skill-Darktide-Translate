# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:PlatformRuntimeApiVersion = '1.0'
$script:PlatformRuntimeManifestPath = Join-Path $PSScriptRoot 'platform-runtime.psd1'

if ($null -eq ('CodexAiInstructions.InstallerMutationSourceLoader' -as [type])) {
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
        private static extern SafeFileHandle CreateFile(string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle file, out InstallerSourceByHandleFileInformation fileInformation);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint pathLength, uint flags);

        public static byte[] ReadPhysicalSingleLinkFile(string path)
        {
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            try
            {
                if (Environment.OSVersion.Platform != PlatformID.Win32NT) throw new InvalidDataException("Installer source path safety validation requires Windows.");
                string fullPath = Path.GetFullPath(path);
                string root = Path.GetPathRoot(fullPath);
                if (string.IsNullOrEmpty(root) || string.Equals(fullPath.TrimEnd('\\'), root.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
                    throw new InvalidDataException("Installer source path safety validation requires a file below a filesystem root.");
                SafeFileHandle rootHandle = OpenComponent(root, false);
                handles.Add(rootHandle);
                ValidateComponent(rootHandle, root, true, false);
                string current = root;
                string[] segments = fullPath.Substring(root.Length).Split(new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries);
                if (segments.Length == 0) throw new InvalidDataException("Installer source path safety validation found no file component.");
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
                    throw new InvalidDataException("Installer source path safety rejected a path that resolved through a different physical location: " + fullPath);
                using (SafeFileHandle borrowed = new SafeFileHandle(target.DangerousGetHandle(), false))
                using (FileStream stream = new FileStream(borrowed, FileAccess.Read))
                using (MemoryStream memory = new MemoryStream())
                {
                    stream.CopyTo(memory);
                    return memory.ToArray();
                }
            }
            catch (InvalidDataException) { throw; }
            catch (Exception ex) { throw new InvalidDataException("Installer source path safety validation failed: " + ex.Message, ex); }
            finally { for (int index = handles.Count - 1; index >= 0; index--) handles[index].Dispose(); }
        }

        private static SafeFileHandle OpenComponent(string path, bool isTarget)
        {
            uint access = isTarget ? GenericRead | FileReadAttributes : 0u;
            uint share = FileShareRead | (isTarget ? 0u : FileShareWrite | FileShareDelete);
            SafeFileHandle handle = CreateFile(path, access, share, IntPtr.Zero, OpenExisting, FileFlagBackupSemantics | FileFlagOpenReparsePoint, IntPtr.Zero);
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
            if (!GetFileInformationByHandle(handle, out information)) throw new InvalidDataException("Installer source path safety validation could not inspect '" + path + "'.");
            if ((information.FileAttributes & FileAttributeReparsePoint) != 0) throw new InvalidDataException("Installer source path safety rejected a reparse point: " + path);
            bool isDirectory = (information.FileAttributes & FileAttributeDirectory) != 0;
            if (isDirectory != expectDirectory) throw new InvalidDataException("Installer source path safety rejected a non-regular path component: " + path);
            if (requireSingleLink && information.NumberOfLinks != 1) throw new InvalidDataException("Installer source link count must be exactly one: " + path);
        }

        private static string GetFinalPath(SafeFileHandle handle)
        {
            StringBuilder buffer = new StringBuilder(32768);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0 || length >= buffer.Capacity) throw new InvalidDataException("Installer source path safety could not resolve the opened source identity.");
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
    catch { throw [IO.InvalidDataException]::new("The platform runtime installer source path-safety helper could not be compiled: $($_.Exception.Message)",$_.Exception) }
}

function Get-PlatformRuntimeVerifiedInstallerSourceText {
    if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
        return [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'platform/WindowsInstallerMutation.cs'),[Text.UTF8Encoding]::new($false,$true))
    }
    try {
        [byte[]]$manifestBytes=[CodexAiInstructions.InstallerMutationSourceLoader]::ReadPhysicalSingleLinkFile($script:PlatformRuntimeManifestPath)
        [byte[]]$sourceBytes=[CodexAiInstructions.InstallerMutationSourceLoader]::ReadPhysicalSingleLinkFile((Join-Path $PSScriptRoot 'platform/WindowsInstallerMutation.cs'))
        $utf8=[Text.UTF8Encoding]::new($false,$true)
        foreach($item in @(@('manifest',$manifestBytes),@('native source',$sourceBytes))) {
            [byte[]]$bytes=$item[1]
            if($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) { throw [IO.InvalidDataException]::new("The platform runtime installer $($item[0]) must be UTF-8 without BOM.") }
        }
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseInput($utf8.GetString($manifestBytes),[ref]$tokens,[ref]$parseErrors)
        if(@($parseErrors).Count -ne 0 -or $ast.EndBlock.Statements.Count -ne 1 -or
            $ast.EndBlock.Statements[0] -isnot [Management.Automation.Language.PipelineAst] -or
            $ast.EndBlock.Statements[0].PipelineElements.Count -ne 1 -or
            $ast.EndBlock.Statements[0].PipelineElements[0] -isnot [Management.Automation.Language.CommandExpressionAst] -or
            $ast.EndBlock.Statements[0].PipelineElements[0].Expression -isnot [Management.Automation.Language.HashtableAst]) {
            throw [IO.InvalidDataException]::new('The platform runtime manifest is not a safe data-file hashtable.')
        }
        $manifest=$ast.EndBlock.Statements[0].PipelineElements[0].Expression.SafeGetValue()
        if($null -eq $manifest.PrivateData -or $null -eq $manifest.PrivateData.PlatformRuntime -or [string]$manifest.PrivateData.PlatformRuntime.HashMode -cne 'sha256-utf8-lf') {
            throw [IO.InvalidDataException]::new('The platform runtime manifest has no supported installer source hash mode.')
        }
        $entries=@($manifest.PrivateData.PlatformRuntime.Inventory | Where-Object { [string]$_.Path -ceq 'platform/WindowsInstallerMutation.cs' })
        if($entries.Count -ne 1 -or [string]$entries[0].Sha256 -cnotmatch '^[0-9a-f]{64}$') { throw [IO.InvalidDataException]::new('The platform runtime manifest must bind exactly one installer native source entry.') }
        $text=$utf8.GetString($sourceBytes)
        $sha=[Security.Cryptography.SHA256]::Create()
        try { $actual=([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
        if($actual -cne [string]$entries[0].Sha256) { throw [IO.InvalidDataException]::new('The platform runtime installer native source hash mismatch rejected compilation.') }
        return $text
    }
    catch {
        if($_.Exception -is [IO.InvalidDataException]) { throw }
        throw [IO.InvalidDataException]::new("The platform runtime installer native source could not be verified: $($_.Exception.Message)",$_.Exception)
    }
}

function Get-PlatformRuntimeCanonicalSha256 {
    param([Parameter(Mandatory = $true)][string] $LiteralPath)

    [byte[]]$bytes = [IO.File]::ReadAllBytes($LiteralPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xef -and $bytes[1] -eq 0xbb -and $bytes[2] -eq 0xbf) {
        throw [IO.InvalidDataException]::new('Platform runtime inventory files must be UTF-8 without BOM.')
    }
    $utf8 = [Text.UTF8Encoding]::new($false,$true)
    $canonicalText = $utf8.GetString($bytes).Replace("`r`n","`n")
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($utf8.GetBytes($canonicalText)))).Replace('-','').ToLowerInvariant()
    }
    finally { $sha256.Dispose() }
}

function Assert-PlatformRuntimeInventory {
    [CmdletBinding()]
    param(
        [Parameter()][string] $Root = $PSScriptRoot,
        [Parameter()][string] $ManifestPath = (Join-Path $Root 'platform-runtime.psd1')
    )

    $resolvedRoot = [IO.Path]::GetFullPath($Root)
    $resolvedManifest = [IO.Path]::GetFullPath($ManifestPath)
    if (-not (Test-Path -LiteralPath $resolvedManifest -PathType Leaf)) {
        throw [IO.InvalidDataException]::new('Platform runtime manifest is missing.')
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $resolvedManifest
    if ($null -eq $manifest.PrivateData -or $null -eq $manifest.PrivateData.PlatformRuntime -or
        $manifest.PrivateData.PlatformRuntime.HashMode -cne 'sha256-utf8-lf' -or
        $null -eq $manifest.PrivateData.PlatformRuntime.Inventory) {
        throw [IO.InvalidDataException]::new('Platform runtime manifest has no bound inventory.')
    }

    $inventory = @($manifest.PrivateData.PlatformRuntime.Inventory)
    $declaredPaths = @($inventory | ForEach-Object { ([string]$_.Path).Replace('\','/') })
    $expectedFileList = @('platform-runtime.psd1') + $declaredPaths
    $manifestFileList = @($manifest.FileList | ForEach-Object { ([string]$_).Replace('\','/') })
    $expectedFileListText = (@($expectedFileList | Sort-Object) -join "`n")
    $manifestFileListText = (@($manifestFileList | Sort-Object) -join "`n")
    if ($expectedFileListText -cne $manifestFileListText -or
        @($expectedFileList | Select-Object -Unique).Count -ne $expectedFileList.Count) {
        throw [IO.InvalidDataException]::new('Platform runtime FileList differs from its bound inventory.')
    }

    $platformRoot = Join-Path $resolvedRoot 'platform'
    if (-not (Test-Path -LiteralPath $platformRoot -PathType Container)) {
        throw [IO.InvalidDataException]::new('Platform runtime implementation directory is missing.')
    }
    $actualPlatformPaths = @(
        Get-ChildItem -LiteralPath $platformRoot -File -Recurse | ForEach-Object {
            ('platform/' + $_.FullName.Substring($platformRoot.Length).TrimStart('\','/')).Replace('\','/')
        }
    )
    $declaredPlatformPaths = @($declaredPaths | Where-Object { $_.StartsWith('platform/',[StringComparison]::Ordinal) })
    $actualPlatformPathsText = (@($actualPlatformPaths | Sort-Object) -join "`n")
    $declaredPlatformPathsText = (@($declaredPlatformPaths | Sort-Object) -join "`n")
    if ($actualPlatformPathsText -cne $declaredPlatformPathsText) {
        throw [IO.InvalidDataException]::new('Platform runtime implementation directory contains missing or extra files.')
    }

    $verifiedFiles = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $inventory) {
        $relativePath = ([string]$entry.Path).Replace('\','/')
        $expectedHash = [string]$entry.Sha256
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathRooted($relativePath) -or
            @($relativePath.Split('/') | Where-Object { $_ -ceq '..' }).Count -gt 0 -or
            $expectedHash -notmatch '^[a-f0-9]{64}$') {
            throw [IO.InvalidDataException]::new('Platform runtime inventory contains an invalid entry.')
        }
        $fullPath = Join-Path $resolvedRoot $relativePath
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
            throw [IO.InvalidDataException]::new("Platform runtime inventory file is missing: $relativePath")
        }
        $actualHash = Get-PlatformRuntimeCanonicalSha256 -LiteralPath $fullPath
        if ($actualHash -cne $expectedHash) {
            throw [IO.InvalidDataException]::new("Platform runtime inventory hash mismatch: $relativePath")
        }
        $verifiedFiles.Add([pscustomobject][ordered]@{ path = $relativePath; sha256 = $actualHash })
    }

    return [pscustomobject][ordered]@{
        apiVersion = $script:PlatformRuntimeApiVersion
        hashMode = 'sha256-utf8-lf'
        files = [object[]]$verifiedFiles.ToArray()
    }
}

Assert-PlatformRuntimeInventory | Out-Null

$nativeSourcePaths = @(
    'platform/PlatformNative.cs',
    'platform/UnixNative.cs',
    'platform/WindowsNative.cs',
    'platform/OwnedProcess.cs',
    'platform/UnixProcess.cs',
    'platform/WindowsProcess.cs'
)
$nativeSourceFullPaths = @($nativeSourcePaths | ForEach-Object { Join-Path $PSScriptRoot $_ })

if ($null -eq ('CodexAiInstructions.InstallerNativeMutation' -as [type])) {
    $installerMutationSourceText=Get-PlatformRuntimeVerifiedInstallerSourceText
    try { Add-Type -TypeDefinition $installerMutationSourceText -ErrorAction Stop }
    catch { throw [IO.InvalidDataException]::new("The verified installer mutation native source could not be compiled: $($_.Exception.Message)",$_.Exception) }
}

if ($null -eq ('SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative' -as [type])) {
    Add-Type -LiteralPath $nativeSourceFullPaths -ErrorAction Stop
    [SyuanTsai.AIInstructions.PlatformRuntime.PlatformRuntimeBuild]::Seal(
        [SyuanTsai.AIInstructions.PlatformRuntime.PlatformRuntimeBuild]::ComputeSourceFingerprint($PSScriptRoot))
}
else {
    $loadedBuildType = 'SyuanTsai.AIInstructions.PlatformRuntime.PlatformRuntimeBuild' -as [type]
    $loadedFingerprintProperty = if ($null -eq $loadedBuildType) { $null } else { $loadedBuildType.GetProperty('Fingerprint') }
    $loadedFingerprint = if ($null -eq $loadedFingerprintProperty) { $null } else { [string]$loadedFingerprintProperty.GetValue($null) }
    if ($null -eq $loadedBuildType -or
        [string]::IsNullOrEmpty($loadedFingerprint)) {
        throw [InvalidOperationException]::new('INVALID|A different platform runtime build is already loaded in this process; start a new PowerShell process.')
    }
    $platformRuntimeSourceFingerprint = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformRuntimeBuild]::ComputeSourceFingerprint($PSScriptRoot)
    if ($loadedFingerprint -cne $platformRuntimeSourceFingerprint) {
        throw [InvalidOperationException]::new('INVALID|A different platform runtime build is already loaded in this process; start a new PowerShell process.')
    }
}

Import-Module (Join-Path $PSScriptRoot 'platform/Windows.psm1') -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'platform/Linux.psm1') -Scope Local -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'platform/MacOS.psm1') -Scope Local -ErrorAction Stop
$script:PlatformRuntimePreparationPath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'platform/RuntimePreparation.psm1'))
$loadedRuntimePreparationModules = @(Import-Module -Name $script:PlatformRuntimePreparationPath -PassThru -Scope Local -ErrorAction Stop)
$runtimePreparationPathComparison = if ([SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem() -ceq 'windows') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if ($loadedRuntimePreparationModules.Count -ne 1 -or -not [string]::Equals([IO.Path]::GetFullPath([string]$loadedRuntimePreparationModules[0].Path),$script:PlatformRuntimePreparationPath,$runtimePreparationPathComparison)) {
    throw [IO.InvalidDataException]::new('The allowlisted process-launch dependency did not load from its inventory-bound path.')
}
$script:PlatformRuntimePreparationModule = $loadedRuntimePreparationModules[0]

function Get-CurrentPlatformName {
    return [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetOperatingSystem()
}

function Clear-PlatformProbe {
    param(
        [Parameter(Mandatory = $true)] $Directory,
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Entries,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Evidence
    )
    $verified = $false
    try {
        # Check the directory BEFORE using its pathname for file cleanup. A renamed
        # lease still owns the old inode, not a replacement at the original path.
        Assert-PlatformFileIdentity -Lease $Directory -Expected $Directory.Observation | Out-Null
        foreach ($entry in $Entries) {
            if ($null -ne $entry[1]) {
                $cleanup = Open-PlatformFile -ParentLease $Directory -Leaf $entry[0] -Access Read -CreateMode OpenExisting
                try { Assert-PlatformFileIdentity -Lease $cleanup -Expected $entry[1] -SingleLink | Out-Null } finally { $cleanup.Dispose() }
                Assert-PlatformFileIdentity -Lease $Directory -Expected $Directory.Observation | Out-Null
                [IO.File]::Delete((Join-Path $Path $entry[0]))
            }
        }
        Assert-PlatformFileIdentity -Lease $Directory -Expected $Directory.Observation | Out-Null
        $verified = $true
    } catch { $Evidence['cleanupFailure'] = $_.Exception.Message } finally { $Directory.Dispose() }
    # A1 still applies to the final check-to-delete interval on Unix. A detected
    # mismatch, however, must NEVER authorize deletion of the replacement.
    if ($verified) {
        try { [IO.Directory]::Delete($Path,$false) } catch { $Evidence['cleanupFailure'] = $_.Exception.Message }
    }
}

function Test-PlatformPrimitives {
    # Receipt describes this local probe filesystem, not every mounted filesystem.
    $platform = Get-CurrentPlatformName
    $root = if ($platform -eq 'windows') { [IO.Path]::GetTempPath().TrimEnd('\','/') } elseif ($platform -eq 'macos') { '/private/tmp' } else { '/tmp' }
    $name = 'platform-probe-' + [Guid]::NewGuid().ToString('N')
    $path = Join-Path $root $name
    $directory = $null; $file = $null; $first = $null; $second = $null
    $fileIdentity = $null; $lockIdentity = $null
    $status = 'unavailable'
    $evidence = [ordered]@{
        lockPrimitive = $(if ($platform -eq 'windows') { 'windows-fileshare' } else { 'flock' })
        scope = 'Fresh local temporary-directory probe; other filesystems require their own validation.'
        guarantee = $(if ($platform -eq 'windows') { 'Handle sharing denies conflicting open/write/delete.' } else { 'Cooperative advisory flock only; same-account nonparticipants can mutate names/content. Revalidation is not mandatory exclusion (A1).' })
        abi = 'Win32 handle information'
    }
    try {
        if ($platform -ne 'windows') { $evidence.abi = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::ValidateAbi() }
        $directory = Open-PlatformDirectory -Root $root -RelativePath $name -CreatePrivate
        $file = Open-PlatformFile -ParentLease $directory -Leaf 'data' -Access ReadWrite -CreateMode CreateNew
        $fileIdentity = Assert-PlatformFileIdentity -Lease $file -Expected $file.Observation -SingleLink
        if ($platform -eq 'windows') {
            $permissions = Get-PlatformPermissions -Lease $file
            Set-PlatformPermissions -Lease $file -Policy @{ Sddl=$permissions.Sddl; ReadOnly=$permissions.ReadOnly } | Out-Null
        }
        $file.Dispose(); $file = $null
        $first = Enter-PlatformLock -ParentLease $directory -Leaf 'lock' -Mode Shared -Timeout ([TimeSpan]::Zero)
        $lockIdentity = $first.Observation
        $second = Enter-PlatformLock -ParentLease $directory -Leaf 'lock' -Mode Shared -Timeout ([TimeSpan]::Zero)
        $conflicted = $false
        try {
            $unexpected = Enter-PlatformLock -ParentLease $directory -Leaf 'lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
            $unexpected.Dispose()
        } catch {
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            if ($cause -isnot [TimeoutException]) { throw }
            $conflicted = $true
        }
        if (-not $conflicted) { throw [IO.IOException]::new('Lock probe did not exclude an exclusive participant.') }
        $second.Dispose(); $second = $null; $first.Dispose(); $first = $null
        $first = Enter-PlatformLock -ParentLease $directory -Leaf 'lock' -Mode Exclusive -Timeout ([TimeSpan]::Zero)
        Assert-PlatformFileIdentity -Lease $first -Expected $lockIdentity -SingleLink | Out-Null
        $status = 'available'
    }
    catch {
        $evidence['failure'] = $_.Exception.Message
    }
    finally {
        if ($null -ne $second) { $second.Dispose() }
        if ($null -ne $first) { $first.Dispose() }
        if ($null -ne $file) { $file.Dispose() }
        # Only our two known probe names are cleaned; no recursive deletion.
        if ($null -ne $directory) {
            Clear-PlatformProbe -Directory $directory -Path $path -Entries @(@('data',$fileIdentity),@('lock',$lockIdentity)) -Evidence $evidence
        }
    }
    # Construct the receipt AFTER finally so cleanup failures are not lost in a
    # PSCustomObject copy made before cleanup ran.
    return [pscustomobject]@{ status=$status; evidence=[pscustomobject]$evidence }
}

function Test-PlatformDirectoryPublication {
    $platform=Get-CurrentPlatformName
    if($platform -cne 'windows'){
        return [pscustomobject]@{status='unavailable';evidence=[pscustomobject][ordered]@{implementation='P11 directory publication is not implemented on this platform.'}}
    }
    $status='unavailable'
    $evidence=[ordered]@{
        noReplace='not verified'
        identityPreserved='not verified'
        sameFileSystem='not verified'
    }
    $rootLease=$null;$parentLease=$null;$transactionRootLease=$null;$transactionLease=$null;$stageLease=$null;$movedLease=$null;$occupiedLease=$null;$receipt=$null;$transactionIdentity=$null
    $root=[IO.Path]::GetTempPath().TrimEnd('\','/')
    $name='platform-directory-publication-probe-'+[Guid]::NewGuid().ToString('N')
    $path=Join-Path $root $name
    $transactionId=[Guid]::NewGuid().ToString('N')
    try{
        $rootLease=Open-PlatformDirectory -Root $root -RelativePath $name -CreatePrivate
        [void][IO.Directory]::CreateDirectory((Join-Path $path 'target'))
        [void][IO.Directory]::CreateDirectory((Join-Path $path '.ai-instructions-txn'))
        [void][IO.Directory]::CreateDirectory((Join-Path $path ".ai-instructions-txn/$transactionId"))
        [void][IO.Directory]::CreateDirectory((Join-Path $path ".ai-instructions-txn/$transactionId/stage"))
        [void][IO.Directory]::CreateDirectory((Join-Path $path 'target/occupied'))
        $parentLease=Open-PlatformDirectory -Root $path -RelativePath 'target'
        $occupiedLease=Open-PlatformDirectory -Root $path -RelativePath 'target/occupied'
        $transactionRootLease=Open-PlatformDirectory -Root $path -RelativePath '.ai-instructions-txn'
        $transactionLease=Open-PlatformDirectory -Root $path -RelativePath ".ai-instructions-txn/$transactionId"
        $transactionIdentity=[pscustomobject][ordered]@{kind='windows-file-id';device=('0x{0:x}' -f [uint64]$transactionLease.Observation.Device);fileId=('0x{0:x}' -f [uint64]$transactionLease.Observation.Inode)}
        $stageLease=Open-PlatformDirectory -Root $path -RelativePath ".ai-instructions-txn/$transactionId/stage"
        $sourceIdentity=[pscustomobject][ordered]@{kind='windows-file-id';device=('0x{0:x}' -f [uint64]$stageLease.Observation.Device);fileId=('0x{0:x}' -f [uint64]$stageLease.Observation.Inode)}
        $evidence.sameFileSystem=if([uint64]$stageLease.Observation.Device -eq [uint64]$parentLease.Observation.Device){'Source and destination directory leases reported the same volume serial.'}else{throw 'Source and destination are not on the same filesystem.'}
        $stageLease.Dispose();$stageLease=$null
        $rejected=$false
        try{Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf 'stage' -TransactionLease $transactionLease -DestinationLeaf 'occupied' -ExpectedIdentity $sourceIdentity -Direction FromTransaction|Out-Null}
        catch{$rejected=$true}
        if(-not $rejected -or -not [IO.Directory]::Exists((Join-Path $path ".ai-instructions-txn/$transactionId/stage")) -or -not [IO.Directory]::Exists((Join-Path $path 'target/occupied'))){throw 'Native no-replace rename did not preserve both directory names.'}
        $evidence.noReplace='Native no-replace directory rename rejected an existing destination and preserved both names.'
        $receipt=Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf 'stage' -TransactionLease $transactionLease -DestinationLeaf 'published' -ExpectedIdentity $sourceIdentity -Direction FromTransaction
        $movedLease=Open-PlatformDirectory -Root $path -RelativePath 'target/published'
        $movedIdentity=[pscustomobject][ordered]@{kind='windows-file-id';device=('0x{0:x}' -f [uint64]$movedLease.Observation.Device);fileId=('0x{0:x}' -f [uint64]$movedLease.Observation.Inode)}
        if([string]$receipt.identity.device -cne [string]$sourceIdentity.device -or [string]$receipt.identity.fileId -cne [string]$sourceIdentity.fileId -or [string]$movedIdentity.fileId -cne [string]$sourceIdentity.fileId){throw 'Directory identity was not preserved by rename.'}
        $evidence.identityPreserved='Handle and path readback retained the original Windows file ID.'
        $status='available'
    }
    catch{$evidence['failure']=$_.Exception.Message}
    finally{
        if($null -ne $movedLease){$movedLease.Dispose();$movedLease=$null}
        if($null -ne $stageLease){$stageLease.Dispose();$stageLease=$null}
        if($null -ne $receipt -and $null -ne $parentLease -and $null -ne $transactionLease){
            try{Move-PlatformOwnedDirectory -ParentLease $parentLease -Leaf 'published' -TransactionLease $transactionLease -DestinationLeaf 'published.cleanup' -ExpectedIdentity $receipt.identity -Direction ToTransaction|Out-Null}
            catch{$evidence['cleanupFailure']=$_.Exception.Message}
        }
        if($null -ne $transactionLease){$transactionLease.Dispose();$transactionLease=$null}
        if($null -ne $transactionRootLease){
            try{Remove-PlatformOwnedDirectoryTree -TransactionRootLease $transactionRootLease -Leaf $transactionId -ExpectedIdentity $transactionIdentity|Out-Null}
            catch{$evidence['cleanupFailure']=$_.Exception.Message}
        }
        if($null -ne $occupiedLease){Clear-PlatformProbe -Directory $occupiedLease -Path (Join-Path $path 'target/occupied') -Entries @() -Evidence $evidence;$occupiedLease=$null}
        if($null -ne $parentLease){Clear-PlatformProbe -Directory $parentLease -Path (Join-Path $path 'target') -Entries @() -Evidence $evidence;$parentLease=$null}
        if($null -ne $transactionRootLease){Clear-PlatformProbe -Directory $transactionRootLease -Path (Join-Path $path '.ai-instructions-txn') -Entries @() -Evidence $evidence;$transactionRootLease=$null}
        if($null -ne $rootLease){Clear-PlatformProbe -Directory $rootLease -Path $path -Entries @() -Evidence $evidence;$rootLease=$null}
    }
    if ($evidence.Contains('cleanupFailure')) { $status = 'unavailable' }
    return [pscustomobject]@{status=$status;evidence=[pscustomobject]$evidence}
}

function Test-WindowsFilePublicationPrimitives {
    $platform=Get-CurrentPlatformName
    if($platform -cne 'windows'){
        return [pscustomobject]@{status='unverified';evidence=[pscustomobject][ordered]@{implementation='Windows file publication probe does not apply to this host.'}}
    }
    $status='unavailable'
    $evidence=[ordered]@{publication='not verified';ownedFileRemoval='not verified'}
    $rootLease=$null;$parentLease=$null;$transactionRootLease=$null;$transactionLease=$null;$stageLease=$null
    $root=[IO.Path]::GetTempPath().TrimEnd('\','/')
    $name='platform-file-publication-probe-'+[Guid]::NewGuid().ToString('N')
    $path=Join-Path $root $name
    $transactionId=[Guid]::NewGuid().ToString('N')
    $transactionIdentity=$null
    try{
        $rootLease=Open-PlatformDirectory -Root $root -RelativePath $name -CreatePrivate
        [void][IO.Directory]::CreateDirectory((Join-Path $path 'target'))
        [void][IO.Directory]::CreateDirectory((Join-Path $path '.ai-instructions-txn'))
        [void][IO.Directory]::CreateDirectory((Join-Path $path ".ai-instructions-txn/$transactionId"))
        $parentLease=Open-PlatformDirectory -Root $path -RelativePath 'target'
        $transactionRootLease=Open-PlatformDirectory -Root $path -RelativePath '.ai-instructions-txn'
        $transactionLease=Open-PlatformDirectory -Root $path -RelativePath ".ai-instructions-txn/$transactionId"
        $transactionIdentity=[pscustomobject][ordered]@{kind='windows-file-id';device=('0x{0:x}' -f [uint64]$transactionLease.Observation.Device);fileId=('0x{0:x}' -f [uint64]$transactionLease.Observation.Inode)}
        [byte[]]$bytes=[Text.UTF8Encoding]::new($false).GetBytes('platform publication probe')
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$digest=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $stageLease=Open-PlatformFile -ParentLease $transactionLease -Leaf 'stage' -Access ReadWrite -CreateMode CreateNew
        $stageLease.WriteNewBytes($bytes)
        $stageIdentity=[pscustomobject][ordered]@{kind='windows-file-id';device=('0x{0:x}' -f [uint64]$stageLease.Observation.Device);fileId=('0x{0:x}' -f [uint64]$stageLease.Observation.Inode)}
        $missing=[pscustomobject][ordered]@{exists=$false;sha256=$null;length=$null;identity=$null}
        $staged=[pscustomobject][ordered]@{exists=$true;sha256=$digest;length=[int64]$bytes.Length;identity=$stageIdentity}
        $receipt=Publish-PlatformFile -ParentLease $parentLease -Leaf 'published' -TransactionLease $transactionLease -StageLease $stageLease -ExpectedState $missing -ExpectedStage $staged -NoReplace
        $stageLease.Dispose();$stageLease=$null
        if([string]$receipt.durability -cne 'confirmed'){throw 'File publication did not return confirmed durability.'}
        $evidence.publication='Create-file publication used native no-replace rename with confirmed file and directory durability.'
        $published=[pscustomobject][ordered]@{exists=$true;sha256=$digest;length=[int64]$bytes.Length;identity=$receipt.appliedIdentity}
        $removeReceipt=Remove-PlatformOwnedFile -ParentLease $parentLease -Leaf 'published' -ExpectedState $published -TransactionLease $transactionLease -TombstoneLeaf 'removed'
        if([string]$removeReceipt.durability -cne 'confirmed'){throw 'Owned-file removal did not return confirmed durability.'}
        $evidence.ownedFileRemoval='Owned-file removal used tombstone rename with confirmed file and directory durability.'
        $status='available'
    }
    catch{$evidence['failure']=$_.Exception.Message}
    finally{
        if($null -ne $stageLease){$stageLease.Dispose();$stageLease=$null}
        if($null -ne $transactionLease){$transactionLease.Dispose();$transactionLease=$null}
        if($null -ne $transactionRootLease -and $null -ne $transactionIdentity){
            try{Remove-PlatformOwnedDirectoryTree -TransactionRootLease $transactionRootLease -Leaf $transactionId -ExpectedIdentity $transactionIdentity|Out-Null}catch{$evidence['cleanupFailure']=$_.Exception.Message}
        }
        if($null -ne $parentLease){Clear-PlatformProbe -Directory $parentLease -Path (Join-Path $path 'target') -Entries @() -Evidence $evidence;$parentLease=$null}
        if($null -ne $transactionRootLease){Clear-PlatformProbe -Directory $transactionRootLease -Path (Join-Path $path '.ai-instructions-txn') -Entries @() -Evidence $evidence;$transactionRootLease=$null}
        if($null -ne $rootLease){Clear-PlatformProbe -Directory $rootLease -Path $path -Entries @() -Evidence $evidence;$rootLease=$null}
    }
    if ($evidence.Contains('cleanupFailure')) { $status = 'unavailable' }
    return [pscustomobject]@{status=$status;evidence=[pscustomobject]$evidence}
}

function Test-UnixPublicationPrimitives {
    $platform = Get-CurrentPlatformName
    if ($platform -cnotin @('linux','macos')) {
        return [pscustomobject]@{ status='unverified'; evidence=[object[]]@('Unix publication probes do not apply to this host.') }
    }
    try {
        $evidence = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::ProbePublicationPrimitives()
        return [pscustomobject]@{ status='available'; evidence=[object[]]@($evidence) }
    }
    catch {
        return [pscustomobject]@{ status='unavailable'; evidence=[object[]]@($_.Exception.Message) }
    }
}

function Test-UnixPermissionPrimitives {
    $platform = Get-CurrentPlatformName
    if ($platform -cnotin @('linux','macos')) {
        return [pscustomobject]@{ status='unverified'; evidence=[object[]]@('Unix permission probes do not apply to this host.') }
    }
    try {
        $evidence = [SyuanTsai.AIInstructions.PlatformRuntime.UnixNative]::ProbePermissionPrimitives()
        return [pscustomobject]@{ status='available'; evidence=[object[]]@($evidence) }
    }
    catch {
        return [pscustomobject]@{ status='unavailable'; evidence=[object[]]@($_.Exception.Message) }
    }
}

function Get-PlatformCapabilities {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Required)

    $platform = Get-CurrentPlatformName
    $primitiveProbe = Test-PlatformPrimitives
    $directoryPublicationProbe = Test-PlatformDirectoryPublication
    $windowsFilePublicationProbe = Test-WindowsFilePublicationPrimitives
    $publicationProbe = Test-UnixPublicationPrimitives
    $permissionProbe = Test-UnixPermissionPrimitives
    $processProbe = Test-PlatformOwnedProcess
    $processEnvironmentMethod = @(
        [Environment].GetMethods([Reflection.BindingFlags]'Public,Static') | Where-Object {
            $_.Name -ceq 'SetEnvironmentVariable' -and
            $_.GetParameters().Count -eq 3 -and
            $_.GetParameters()[2].ParameterType -eq [EnvironmentVariableTarget]
        }
    )
    $processEnvironmentStatus = if ($processEnvironmentMethod.Count -gt 0) { 'available' } else { 'unavailable' }
    $processEnvironmentEvidence = if ($processEnvironmentMethod.Count -gt 0) {
        'The current runtime exposes System.Environment process-scope assignment.'
    }
    else {
        'The current runtime does not expose System.Environment process-scope assignment.'
    }
    $powerShellExecutable = Join-Path $PSHOME $(if ($platform -ceq 'windows') { 'pwsh.exe' } else { 'pwsh' })
    $powerShellStatus = 'unavailable'
    $powerShellEvidence = 'The current PowerShell executable was not verified.'
    try {
        $powerShellItem = Get-Item -Force -LiteralPath $powerShellExecutable -ErrorAction Stop
        if ($powerShellItem.PSIsContainer -or ($powerShellItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $powerShellItem.LinkType) { throw 'The current pwsh is not a physical regular file.' }
        $identityCommand = $script:PlatformRuntimePreparationModule.ExportedCommands['Test-PlatformPowerShellIdentity']
        if ($null -eq $identityCommand) { throw 'The verified runtime identity dependency is incomplete.' }
        $runtimeClosure = & $script:PlatformRuntimePreparationModule {
            param([string]$Root,[string]$Platform)
            Get-PlatformRuntimeClosure $Root $Platform
        } $PSHOME $platform
        $expectedArchitecture = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()
        $identity = & $identityCommand $powerShellExecutable $PSVersionTable.PSVersion.ToString() $platform $expectedArchitecture $runtimeClosure
        if ([string]$identity.version -cne $PSVersionTable.PSVersion.ToString()) { throw 'The current pwsh version probe disagrees with this process.' }
        $powerShellStatus = 'available'
        $powerShellEvidence = "Physical pwsh identity and version probe passed: $([IO.Path]::GetFullPath($powerShellExecutable))"
    } catch { $powerShellEvidence = $_.Exception.Message }
    $pesterStatus = 'unavailable'
    $pesterEvidence = 'No physical Pester module manifest was verified.'
    try {
        $verifiedPester = New-Object Collections.Generic.List[string]
        foreach ($candidate in @(Get-Module -ListAvailable -Name Pester)) {
            $item = Get-Item -Force -LiteralPath ([string]$candidate.Path) -ErrorAction Stop
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $item.LinkType) { continue }
            $manifest = Import-PowerShellDataFile -Path $item.FullName -ErrorAction Stop
            if ([string]$manifest.ModuleVersion -ceq $candidate.Version.ToString()) { $verifiedPester.Add("$($candidate.Version):$($item.FullName)") }
        }
        if ($verifiedPester.Count -gt 0) { $pesterStatus = 'available'; $pesterEvidence = [string]::Join('; ',$verifiedPester.ToArray()) }
    } catch { $pesterEvidence = $_.Exception.Message }
    $capabilityDefinitions = [ordered]@{
        'directory-lease' = @('unverified','P2 probe pending.')
        'file-lease' = @('unverified','P2 probe pending.')
        'file-identity' = @('unverified','P2 probe pending.')
        'lock' = @('unverified','P2 probe pending.')
        'publication' = @('unverified','P7 publication primitive is not implemented or probed.')
        'owned-file-removal' = @('unverified','P7 owned-file removal is not implemented or probed.')
        'directory-publication' = @('unverified','Directory publication probe result is applied below.')
        'permissions' = @('unverified','P2 probe pending.')
        'process-isolation' = @('unverified','P3 probe pending.')
        'owned-process' = @('unverified','P3 probe pending.')
        'process-cleanup' = @('unverified','P3 probe pending.')
        'powershell-resolution' = @('unverified','P4 PowerShell resolution is not implemented or probed.')
        'pester-initialization' = @('unverified','P4 Pester initialization is not implemented or probed.')
        'powershell-runtime' = @($powerShellStatus,$powerShellEvidence)
        'pester-module' = @($pesterStatus,$pesterEvidence)
        'process-environment' = @($processEnvironmentStatus,$processEnvironmentEvidence)
    }

    $capabilities = New-Object System.Collections.Generic.List[object]
    foreach ($name in $capabilityDefinitions.Keys) {
        $definition = $capabilityDefinitions[$name]
        $capabilities.Add([pscustomobject][ordered]@{
            name = $name
            status = [string]$definition[0]
            evidence = [object[]]@([string]$definition[1])
        })
    }
    foreach ($capability in $capabilities) {
        if ($capability.name -cin @('directory-lease','file-lease','file-identity','lock') -or
            ($platform -ceq 'windows' -and $capability.name -ceq 'permissions')) {
            $capability.status = $primitiveProbe.status
            $capability.evidence = [object[]]@($primitiveProbe.evidence)
        }
        if ($capability.name -ceq 'directory-publication') {
            $capability.status = $directoryPublicationProbe.status
            $capability.evidence = [object[]]@($directoryPublicationProbe.evidence)
        }
        if ($platform -ceq 'windows' -and $capability.name -cin @('publication','owned-file-removal')) {
            $capability.status = $windowsFilePublicationProbe.status
            $evidenceName = if ($capability.name -ceq 'publication') { 'publication' } else { 'ownedFileRemoval' }
            $capability.evidence = [object[]]@($windowsFilePublicationProbe.evidence.PSObject.Properties[$evidenceName].Value)
            if ($windowsFilePublicationProbe.evidence.PSObject.Properties['failure']) {
                $capability.evidence += [object[]]@([string]$windowsFilePublicationProbe.evidence.failure)
            }
            if ($windowsFilePublicationProbe.evidence.PSObject.Properties['cleanupFailure']) {
                $capability.evidence += [object[]]@("Probe cleanup failed: $([string]$windowsFilePublicationProbe.evidence.cleanupFailure)")
            }
        }
        if ($platform -cne 'windows' -and $capability.name -cin @('publication','owned-file-removal')) {
            $capability.status = $publicationProbe.status
            $capability.evidence = [object[]]@($publicationProbe.evidence)
        }
        if ($platform -cne 'windows' -and $capability.name -ceq 'permissions') {
            $capability.status = $permissionProbe.status
            $capability.evidence = [object[]]@($permissionProbe.evidence)
        }
        if ($capability.name -cin @('owned-process','process-cleanup','process-isolation')) {
            $capability.status = $processProbe.status
            $capability.evidence = [object[]]@($processProbe.evidence)
        }
    }
    foreach ($name in @($Required)) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw [ArgumentException]::new('Required capability names cannot be empty.','Required')
        }
        $matches = @($capabilities | Where-Object {
            [StringComparer]::Ordinal.Equals([string]$_.name,[string]$name)
        })
        if ($matches.Count -ne 1 -or $matches[0].status -cne 'available') {
            throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new($name,$platform)
        }
    }

    return [pscustomobject][ordered]@{
        apiVersion = $script:PlatformRuntimeApiVersion
        os = $platform
        architecture = [SyuanTsai.AIInstructions.PlatformRuntime.PlatformNative]::GetArchitecture()
        runtime = [pscustomobject][ordered]@{
            powerShellVersion = $PSVersionTable.PSVersion.ToString()
            dotNetVersion = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        }
        capabilities = [object[]]$capabilities.ToArray()
    }
}

function Invoke-PlatformAdapter {
    param([Parameter(Mandatory = $true)][string] $Operation, [Parameter(Mandatory = $true)][System.Collections.IDictionary] $Arguments)
    $platformToken = switch (Get-CurrentPlatformName) {
        'windows' { 'Windows' }
        'linux' { 'Linux' }
        'macos' { 'MacOS' }
        default { throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new($Operation,'unknown') }
    }
    $operationParts = $Operation.Split('-',2)
    if ($operationParts.Count -ne 2) { throw [ArgumentException]::new('Platform adapter operation must contain a verb and noun.','Operation') }
    $commandName = "$($operationParts[0])-$platformToken$($operationParts[1])"
    return & $commandName @Arguments
}

function Open-PlatformDirectory {
    [CmdletBinding(DefaultParameterSetName='Child')]
    param(
        [Parameter(Mandatory=$true)][string] $Root,
        [Parameter(Mandatory=$true,ParameterSetName='Child')][string] $RelativePath,
        [Parameter(ParameterSetName='Child')][switch] $CreatePrivate,
        [Parameter(Mandatory=$true,ParameterSetName='Root')][switch] $RootOnly
    )
    Invoke-PlatformAdapter 'Open-PlatformDirectory' $PSBoundParameters
}
function Open-PlatformFile { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][string] $Access, [Parameter(Mandatory = $true)][string] $CreateMode) Invoke-PlatformAdapter 'Open-PlatformFile' @{ ParentLease=$ParentLease; Leaf=$Leaf; Access=$Access; CreateMode=$CreateMode } }
function Assert-PlatformFileIdentity { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Lease, [Parameter(Mandatory = $true)] $Expected, [switch] $SingleLink, [switch] $VerifyPath) Invoke-PlatformAdapter 'Assert-PlatformFileIdentity' $PSBoundParameters }
function Enter-PlatformLock { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)][ValidateSet('Shared','Exclusive')][string] $Mode, [Parameter(Mandatory = $true)][TimeSpan] $Timeout) Invoke-PlatformAdapter 'Enter-PlatformLock' $PSBoundParameters }
function Publish-PlatformFile { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $TransactionLease, [Parameter(Mandatory = $true)] $StageLease, [Parameter(Mandatory = $true)] $ExpectedState, [AllowNull()] $DisplacedLeaf, [Parameter(Mandatory = $true)] $ExpectedStage, [switch] $NoReplace, $Journal) Invoke-PlatformAdapter 'Publish-PlatformFile' $PSBoundParameters }
function Remove-PlatformOwnedFile { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedState, $TransactionLease, [AllowNull()] $TombstoneLeaf, $Journal) Invoke-PlatformAdapter 'Remove-PlatformOwnedFile' $PSBoundParameters }
function Get-PlatformDirectoryState { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf) Invoke-PlatformAdapter 'Get-PlatformDirectoryState' $PSBoundParameters }
function Move-PlatformOwnedDirectory { [CmdletBinding()] param([Parameter(Mandatory = $true)] $ParentLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $TransactionLease, [Parameter(Mandatory = $true)][string] $DestinationLeaf, [Parameter(Mandatory = $true)] $ExpectedIdentity, [Parameter(Mandatory = $true)][ValidateSet('ToTransaction','FromTransaction')][string] $Direction, $ExpectedState, $Journal) if($null -ne $Journal -and -not $PSBoundParameters.ContainsKey('ExpectedState')){throw [ArgumentException]::new('ExpectedState is required when Journal is supplied.')} Invoke-PlatformAdapter 'Move-PlatformOwnedDirectory' $PSBoundParameters }
function Remove-PlatformOwnedDirectoryTree { [CmdletBinding(DefaultParameterSetName='TransactionRoot')] param([Parameter(Mandatory = $true,ParameterSetName='TransactionRoot')] $TransactionRootLease, [Parameter(Mandatory = $true,ParameterSetName='Transaction')] $TransactionLease, [Parameter(Mandatory = $true)][string] $Leaf, [Parameter(Mandatory = $true)] $ExpectedIdentity) Invoke-PlatformAdapter 'Remove-PlatformOwnedDirectoryTree' $PSBoundParameters }
function Get-PlatformPermissions { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Lease) Invoke-PlatformAdapter 'Get-PlatformPermissions' $PSBoundParameters }
function Set-PlatformPermissions { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Lease, $Policy, $Snapshot) Invoke-PlatformAdapter 'Set-PlatformPermissions' $PSBoundParameters }
function Start-PlatformOwnedProcess {
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory=$true,ParameterSetName='Lease')] $ExecutableLease,
        [Parameter(Mandatory=$true,ParameterSetName='Path')][ValidateNotNullOrEmpty()][string] $ExecutablePath,
        [string[]] $ArgumentList = @(),
        [Parameter(Mandatory=$true)][AllowEmptyCollection()][System.Collections.IDictionary] $Environment,
        [Parameter(Mandatory=$true)] $WorkingDirectoryLease,
        [Parameter(Mandatory=$true)][DateTimeOffset] $Deadline,
        [ValidateSet('cooperative','strong')][string] $IsolationRequirement = 'cooperative',
        [Parameter(Mandatory=$true)][string] $StdoutPath,
        [Parameter(Mandatory=$true)][string] $StderrPath,
        # Legacy spelling remains an alias; quotas are UTF-8 decoded characters per stream.
        [Alias('OutputLimitBytes')][ValidateRange(1,1048576)][long] $OutputLimitCharacters = 1048576,
        # Unix invocation name only; Windows validates it but keeps its launch semantics.
        [string] $ArgumentZero,
        [ValidateNotNull()][AllowEmptyCollection()][byte[]] $StandardInputBytes,
        # Preserve the bridge's existing asymmetric quotas without changing the
        # standard capture parameter's default or maximum.
        [ValidateSet('standard','semantic-bridge')][string] $CaptureProfile = 'standard'
    )
    $platform = Get-CurrentPlatformName
    if ($PSBoundParameters.ContainsKey('StandardInputBytes') -and $StandardInputBytes.Length -gt 16777216) {
        throw [ArgumentException]::new('StandardInputBytes exceeds the 16 MiB limit.')
    }
    if ($CaptureProfile -eq 'semantic-bridge') {
        if (-not $PSBoundParameters.ContainsKey('StandardInputBytes')) { throw [ArgumentException]::new('The semantic-bridge capture profile requires explicit StandardInputBytes.') }
        if ($PSBoundParameters.ContainsKey('OutputLimitCharacters')) { throw [ArgumentException]::new('The semantic-bridge capture profile fixes both stream quotas; OutputLimitCharacters cannot override it.') }
    }
    $argumentZeroValue = $null
    if ($PSBoundParameters.ContainsKey('ArgumentZero')) {
        if ($ArgumentZero.IndexOf([char]0) -ge 0 -or -not [IO.Path]::IsPathFullyQualified($ArgumentZero)) {
            throw [ArgumentException]::new('ArgumentZero must be an absolute path without NUL.')
        }
        $argumentZeroValue = $ArgumentZero
    }
    if ($IsolationRequirement -eq 'strong' -and $platform -ne 'windows') {
        throw [SyuanTsai.AIInstructions.PlatformRuntime.PlatformCapabilityUnavailableException]::new('strong-process-isolation: external sandbox required',$platform)
    }
    if ($Deadline -le [DateTimeOffset]::UtcNow) { throw [ArgumentException]::new('Deadline must be in the future.') }
    # Output files are create-only P2 leases, including validation of every ancestor.
    # Linux executable leases execute through /proc/self/fd. Darwin uses F_GETPATH
    # with identity checks before/after suspended spawn (cooperative, not atomic fd
    # execution). Neither mode supplies a hostile-UID sandbox.
    $outLease = $null; $errLease = $null
    try {
        foreach ($path in @($StdoutPath,$StderrPath)) {
            if (-not [IO.Path]::IsPathRooted($path)) { throw [ArgumentException]::new('Capture paths must be absolute.') }
            $anchor = [IO.Path]::GetPathRoot($path)
            [void][SyuanTsai.AIInstructions.PlatformRuntime.PlatformPaths]::Segments($path.Substring($anchor.Length))
        }
        foreach ($pair in @(@('out',$StdoutPath),@('err',$StderrPath))) {
            $parentPath = [IO.Path]::GetDirectoryName($pair[1])
            $anchor = [IO.Path]::GetPathRoot($parentPath)
            $relative = $parentPath.Substring($anchor.Length)
            if ([string]::IsNullOrEmpty($relative)) { throw [ArgumentException]::new('Capture files require a directory below the filesystem root.') }
            $parent = Open-PlatformDirectory -Root $anchor -RelativePath $relative
            try {
                $captureAccess = if ($CaptureProfile -eq 'semantic-bridge') { 'ReadWrite' } else { 'Write' }
                $file = Open-PlatformFile -ParentLease $parent -Leaf ([IO.Path]::GetFileName($pair[1])) -Access $captureAccess -CreateMode CreateNew
                if ($pair[0] -eq 'out') { $outLease = $file } else { $errLease = $file }
            } finally { $parent.Dispose() }
        }
        $startParameters = @{
            ExecutablePath = $ExecutablePath; ExecutableLease = $ExecutableLease; ArgumentList = $ArgumentList
            Environment = $Environment; WorkingDirectoryLease = $WorkingDirectoryLease; Deadline = $Deadline
            IsolationRequirement = $IsolationRequirement; StdoutLease = $outLease; StderrLease = $errLease
            OutputLimitBytes = $OutputLimitCharacters
            CaptureProfile = $CaptureProfile
        }
        if ($PSBoundParameters.ContainsKey('ArgumentZero')) { $startParameters.ArgumentZero = $argumentZeroValue }
        if ($PSBoundParameters.ContainsKey('StandardInputBytes')) { $startParameters.StandardInputBytes = $StandardInputBytes }
        $lease = Start-PlatformCapturedProcess @startParameters
        $outLease = $null; $errLease = $null
        return $lease
    } finally {
        if ($null -ne $outLease) { $outLease.Dispose() }
        if ($null -ne $errLease) { $errLease.Dispose() }
    }
}
function Start-PlatformCapturedProcess {
    # Internal boundary shared by caller-owned capture files and temporary probes.
    param($ExecutablePath,$ExecutableLease,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$IsolationRequirement,$StdoutLease,$StderrLease,$OutputLimitBytes,$ArgumentZero=$null,[byte[]]$StandardInputBytes,$CaptureProfile='standard')
    if ($PSBoundParameters.ContainsKey('StandardInputBytes')) {
        return [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]::Start($ExecutablePath,$ExecutableLease,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$IsolationRequirement,$StdoutLease,$StderrLease,$OutputLimitBytes,$ArgumentZero,$StandardInputBytes,$CaptureProfile)
    }
    if ($CaptureProfile -ne 'standard') { throw [ArgumentException]::new('The semantic-bridge capture profile requires explicit StandardInputBytes.') }
    if ($PSBoundParameters.ContainsKey('ArgumentZero') -and $null -ne $ArgumentZero) {
        return [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]::Start($ExecutablePath,$ExecutableLease,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$IsolationRequirement,$StdoutLease,$StderrLease,$OutputLimitBytes,[string]$ArgumentZero)
    }
    [SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease]::Start($ExecutablePath,$ExecutableLease,$ArgumentList,$Environment,$WorkingDirectoryLease,$Deadline,$IsolationRequirement,$StdoutLease,$StderrLease,$OutputLimitBytes)
}

function Start-PlatformProbeProcess {
    param($Directory,[string]$StdoutLeaf,[string]$StderrLeaf,$Executable,$Arguments,$Environment,
        [Collections.Generic.List[object]]$Entries)
    $outLease = $null; $errLease = $null
    try {
        # Record each create-only lease before the next creation or native start
        # can fail. Never infer ownership later by reopening a known pathname.
        $outLease = Open-PlatformFile -ParentLease $Directory -Leaf $StdoutLeaf -Access Write -CreateMode CreateNew
        $Entries.Add(@($StdoutLeaf,$outLease.Observation))
        $errLease = Open-PlatformFile -ParentLease $Directory -Leaf $StderrLeaf -Access Write -CreateMode CreateNew
        $Entries.Add(@($StderrLeaf,$errLease.Observation))
        $lease = Start-PlatformCapturedProcess -ExecutablePath $Executable -ArgumentList $Arguments -Environment $Environment -WorkingDirectoryLease $Directory -Deadline ([DateTimeOffset]::UtcNow.AddSeconds(10)) -IsolationRequirement cooperative -StdoutLease $outLease -StderrLease $errLease -OutputLimitBytes 4096
        $outLease = $null; $errLease = $null
        return $lease
    } finally {
        if ($null -ne $outLease) { $outLease.Dispose() }
        if ($null -ne $errLease) { $errLease.Dispose() }
    }
}

function Stop-PlatformOwnedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][SyuanTsai.AIInstructions.PlatformRuntime.OwnedProcessLease] $Lease,
        [TimeSpan] $GracePeriod = [TimeSpan]::FromMilliseconds(250),
        [DateTimeOffset] $Deadline = [DateTimeOffset]::UtcNow.AddSeconds(5),
        [ValidateNotNullOrEmpty()][string] $ExpectedStartIdentity
    )
    $expected = if ($PSBoundParameters.ContainsKey('ExpectedStartIdentity')) { $ExpectedStartIdentity } else { $null }
    $Lease.Stop($GracePeriod,$Deadline,$expected)
}

function Test-PlatformOwnedProcess {
    $platform = Get-CurrentPlatformName
    $root = if ($platform -eq 'windows') { [IO.Path]::GetTempPath().TrimEnd('\','/') } elseif ($platform -eq 'macos') { '/private/tmp' } else { '/tmp' }
    $name = 'process-probe-' + [guid]::NewGuid().ToString('N')
    $path = Join-Path $root $name
    $directory = $null; $lease = $null; $status = 'unavailable'
    $entries = [Collections.Generic.List[object]]::new()
    $evidence = [ordered]@{
        isolation = $(switch ($platform) { windows { 'windows-job-object' }; linux { 'linux-process-group-subreaper' }; macos { 'macos-process-group' } })
        scope = 'Measured cooperative child execution and cleanup on this host; no filesystem isolation.'
        strong = ($platform -eq 'windows')
        limitations = @(
            if ($platform -eq 'macos') { 'macos-process-group-cannot-detect-setsid-escape' }
            if ($platform -eq 'macos' -or $platform -eq 'linux') { 'group-signal-external-reaper-race' }
        )
        # This probe exercises pathname execution only. ExecutableLease binding
        # must not be advertised without a separate successful lease probe.
        boundary = 'Unix process groups allow setsid escape; polling cannot prove containment of hostile code. Strong Unix isolation requires an external sandbox. Subreaper remains enabled for the supervisor lifetime; Unix leases are serialized.'
    }
    try {
        $directory = Open-PlatformDirectory -Root $root -RelativePath $name -CreatePrivate
        $environment = @{}
        if ($platform -eq 'windows') {
            $executable = (Get-Process -Id $PID).Path
            $environment['SystemRoot'] = [Environment]::GetEnvironmentVariable('SystemRoot')
            $arguments = @('-NoLogo','-NoProfile','-NonInteractive','-Command','[Console]::Out.Write("probe-out"); [Console]::Error.Write("probe-err"); exit 7')
        } else { $executable = '/bin/sh'; $arguments = @('-c','printf probe-out; printf probe-err >&2; exit 7') }
        $lease = Start-PlatformProbeProcess -Directory $directory -StdoutLeaf out -StderrLeaf err -Executable $executable -Arguments $arguments -Environment $environment -Entries $entries
        if (-not $lease.WaitForExit([TimeSpan]::FromSeconds(10))) { throw [TimeoutException]::new('Process capability probe timed out.') }
        $receipt = Stop-PlatformOwnedProcess -Lease $lease
        $evidence['cleanup'] = $receipt
        if (-not $receipt.CleanedUp -or $lease.ExitCode -ne 7) { throw [IO.IOException]::new('Process capability probe did not exit and clean up as expected.') }
        foreach ($leaf in @('out','err')) {
            $file = Open-PlatformFile -ParentLease $directory -Leaf $leaf -Access Read -CreateMode OpenExisting
            try {
                $created = $entries | Where-Object { $_[0] -ceq $leaf }
                Assert-PlatformFileIdentity -Lease $file -Expected $created[1] -SingleLink | Out-Null
                if ([IO.File]::ReadAllText((Join-Path $path $leaf)) -cne ('probe-' + $leaf)) { throw [IO.IOException]::new('Process capture probe mismatch.') }
            } finally { $file.Dispose() }
        }
        $evidence['exitCode'] = $lease.ExitCode
        $lease.Dispose(); $lease = $null
        $arguments = if ($platform -eq 'windows') { @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep 30') } else { @('-c','exec /bin/sleep 30') }
        $lease = Start-PlatformProbeProcess -Directory $directory -StdoutLeaf stop-out -StderrLeaf stop-err -Executable $executable -Arguments $arguments -Environment $environment -Entries $entries
        $receipt = Stop-PlatformOwnedProcess -Lease $lease
        $evidence['terminationCleanup'] = $receipt
        if (-not $receipt.CleanedUp -or $receipt.SignalsSent -lt 1) { throw [IO.IOException]::new('Process termination probe did not confirm cleanup.') }
        $status = 'available'
    } catch {
        $evidence['failure'] = $_.Exception.Message
        if ($null -ne $lease) { $evidence['unixObservation'] = $lease.UnixObservation }
    }
    finally {
        try {
            if ($null -ne $lease) { $lease.Dispose() }
        } catch {
            $evidence['processDisposeFailure'] = $_.Exception.Message
            $status = 'unavailable'
        } finally {
            if ($null -ne $directory) { Clear-PlatformProbe -Directory $directory -Path $path -Entries $entries.ToArray() -Evidence $evidence }
        }
    }
    if ($evidence.Contains('cleanupFailure')) { $status = 'unavailable' }
    [pscustomobject]@{ status=$status; evidence=[pscustomobject]$evidence }
}
function Resolve-PlatformPowerShell { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $DestinationLease, [Parameter(Mandatory = $true)] $OfflineCache, $ReleaseMetadata) Invoke-PlatformAdapter 'Resolve-PlatformPowerShell' $PSBoundParameters }
function Resolve-PlatformPhysicalPath {
    param([Parameter(Mandatory=$true)][string]$Path)
    & $script:PlatformRuntimePreparationModule.ExportedCommands['Resolve-PlatformPhysicalPath'] @PSBoundParameters
}
function Initialize-PlatformAuthorityPester {
    param([Parameter(Mandatory=$true)][string]$ModulePath,[Parameter(Mandatory=$true)][string]$Executable)
    & $script:PlatformRuntimePreparationModule.ExportedCommands['Initialize-PlatformAuthorityPester'] @PSBoundParameters
}
function Assert-PlatformAuthorityPester {
    param([Parameter(Mandatory=$true)]$Receipt)
    & $script:PlatformRuntimePreparationModule.ExportedCommands['Assert-PlatformAuthorityPester'] @PSBoundParameters
}
function New-PlatformPrivateRoot {
    param([Parameter(Mandatory=$true)][string]$Parent,[Parameter(Mandatory=$true)][string]$Leaf)
    & $script:PlatformRuntimePreparationModule.ExportedCommands['New-PlatformPrivateRoot'] @PSBoundParameters
}
function Invoke-PlatformPreparationCommand {
    param([Parameter(Mandatory=$true)][string]$Command,[AllowEmptyCollection()][string[]]$Arguments=@(),
        [Parameter(Mandatory=$true)][Collections.IDictionary]$Environment,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [ValidateRange(1,3600000)][int]$TimeoutMilliseconds=900000,
        $PreparationReceipt)
    & $script:PlatformRuntimePreparationModule.ExportedCommands['Invoke-PlatformPreparationCommand'] @PSBoundParameters
}
function Initialize-PlatformPester { [CmdletBinding()] param([Parameter(Mandatory = $true)] $Policy, [Parameter(Mandatory = $true)] $RuntimeReceipt, [Parameter(Mandatory = $true)] $DestinationLease) Invoke-PlatformAdapter 'Initialize-PlatformPester' $PSBoundParameters }

function Set-PlatformProcessEnvironment {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string] $Name, [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Value)
    [Environment]::SetEnvironmentVariable($Name,$Value,[EnvironmentVariableTarget]::Process)
    return [pscustomobject][ordered]@{
        apiVersion = $script:PlatformRuntimeApiVersion
        name = $Name
        scope = 'Process'
    }
}

Export-ModuleMember -Function @(
    'Assert-PlatformRuntimeInventory',
    'Get-PlatformCapabilities',
    'Open-PlatformDirectory',
    'Open-PlatformFile',
    'Assert-PlatformFileIdentity',
    'Enter-PlatformLock',
    'Publish-PlatformFile',
    'Remove-PlatformOwnedFile',
    'Get-PlatformDirectoryState',
    'Move-PlatformOwnedDirectory',
    'Remove-PlatformOwnedDirectoryTree',
    'Get-PlatformPermissions',
    'Set-PlatformPermissions',
    'Start-PlatformOwnedProcess',
    'Stop-PlatformOwnedProcess',
    'Resolve-PlatformPowerShell',
    'Resolve-PlatformPhysicalPath',
    'Initialize-PlatformAuthorityPester',
    'Assert-PlatformAuthorityPester',
    'New-PlatformPrivateRoot',
    'Invoke-PlatformPreparationCommand',
    'Initialize-PlatformPester',
    'Set-PlatformProcessEnvironment'
)
