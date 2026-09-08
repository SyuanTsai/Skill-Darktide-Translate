# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
#requires -Version 7.0

[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [string] $ArtifactsRoot = $(
        if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP }
        else { [IO.Path]::GetTempPath() }
    ),
    [string] $AuthorityArchivePath,
    [string] $BaseCommit,
    [string] $ExpectedGoRuntimeVersion = $env:STANDARD_GO_RUNTIME_VERSION,
    [string] $OutputPath,
    [switch] $EnableSemanticScan,
    [string[]] $SemanticCredentialNames = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:IsWindowsHost = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$script:IsLinuxHost = $false
$isLinuxVariable = Get-Variable -Name IsLinux -ErrorAction SilentlyContinue
if ($null -ne $isLinuxVariable) { $script:IsLinuxHost = [bool]$isLinuxVariable.Value }
$script:IsSupportedProcessBoundaryHost = $script:IsWindowsHost -or $script:IsLinuxHost
$env:GIT_NO_REPLACE_OBJECTS = '1'
$script:TrustedStatPath = $null

function Assert-NoDuplicateJsonProperties {
    param([Parameter(Mandatory = $true)][System.Text.Json.JsonElement] $Element, [string] $Context = '$')
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) { throw "$Context contains duplicate JSON property '$($property.Name)'." }
            Assert-NoDuplicateJsonProperties -Element $property.Value -Context "$Context.$($property.Name)"
        }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($item in $Element.EnumerateArray()) {
            Assert-NoDuplicateJsonProperties -Element $item -Context "$Context[$index]"
            $index++
        }
    }
}
function Read-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Context is missing: $Path" }
    try {
        $text = [IO.File]::ReadAllText($Path, [Text.UTF8Encoding]::new($false, $true))
        $document = [System.Text.Json.JsonDocument]::Parse($text)
        try { Assert-NoDuplicateJsonProperties -Element $document.RootElement -Context $Context }
        finally { $document.Dispose() }
        return $text | ConvertFrom-Json -Depth 100
    }
    catch { throw "$Context is not valid unambiguous UTF-8 JSON: $($_.Exception.Message)" }
}

function Assert-Sha256 {
    param($Value, [string] $Context)
    if ($Value -isnot [string] -or [string]$Value -cnotmatch '^[0-9a-f]{64}$') {
        throw "$Context must be a lowercase SHA-256 value."
    }
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)] $Object,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Object -isnot [pscustomobject] -or $null -eq $Object.PSObject.Properties[$Name]) {
        throw "$Context is missing required property '$Name'."
    }
    # Keep scalar JSON properties scalar while preserving array-valued properties
    # as one pipeline object for callers that validate their exact array shape.
    $propertyValue = $Object.PSObject.Properties[$Name].Value
    if ($propertyValue -is [array]) {
        Write-Output -NoEnumerate $propertyValue
    }
    else {
        return $propertyValue
    }
}

function Assert-SkillInventoryUnchanged {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Before,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $After,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Before.Count -ne 1 -or $After.Count -ne 1) {
        throw "$Context for Skill '$SkillId' did not return exactly one before/after inventory."
    }

    $beforeSkill = $Before[0]
    $afterSkill = $After[0]
    $beforeContentSha256 = Get-RequiredProperty -Object $beforeSkill -Name 'contentSha256' -Context "$Context before inventory for '$SkillId'"
    $afterContentSha256 = Get-RequiredProperty -Object $afterSkill -Name 'contentSha256' -Context "$Context after inventory for '$SkillId'"
    Assert-Sha256 -Value $beforeContentSha256 -Context "$Context before content hash for '$SkillId'"
    Assert-Sha256 -Value $afterContentSha256 -Context "$Context after content hash for '$SkillId'"
    if ([string]$beforeContentSha256 -cne [string]$afterContentSha256) {
        throw "Candidate Skill '$SkillId' content identity changed $Context."
    }

    $beforeFiles = @((Get-RequiredProperty -Object $beforeSkill -Name 'files' -Context "$Context before inventory for '$SkillId'"))
    $afterFiles = @((Get-RequiredProperty -Object $afterSkill -Name 'files' -Context "$Context after inventory for '$SkillId'"))
    if ($beforeFiles.Count -ne $afterFiles.Count -or $beforeFiles.Count -eq 0) {
        throw "Candidate Skill '$SkillId' file inventory changed $Context."
    }

    $afterFilesByPath = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($afterFile in $afterFiles) {
        $afterPath = Get-RequiredProperty -Object $afterFile -Name 'path' -Context "$Context after file inventory for '$SkillId'"
        if ($afterPath -isnot [string] -or [string]::IsNullOrWhiteSpace($afterPath) -or
            -not $afterFilesByPath.TryAdd([string]$afterPath, $afterFile)) {
            throw "Candidate Skill '$SkillId' has a duplicate or invalid file path $Context."
        }
    }

    $beforePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($beforeFile in $beforeFiles) {
        $beforePath = Get-RequiredProperty -Object $beforeFile -Name 'path' -Context "$Context before file inventory for '$SkillId'"
        if ($beforePath -isnot [string] -or [string]::IsNullOrWhiteSpace($beforePath) -or
            -not $beforePaths.Add([string]$beforePath)) {
            throw "Candidate Skill '$SkillId' has a duplicate or invalid file path before $Context."
        }
        $afterFile = $null
        if (-not $afterFilesByPath.TryGetValue([string]$beforePath, [ref]$afterFile)) {
            throw "Candidate Skill '$SkillId' file '$beforePath' is missing after $Context."
        }
        $beforeRawSha256 = Get-RequiredProperty -Object $beforeFile -Name 'rawSha256' -Context "$Context before file '$beforePath' for '$SkillId'"
        $afterRawSha256 = Get-RequiredProperty -Object $afterFile -Name 'rawSha256' -Context "$Context after file '$beforePath' for '$SkillId'"
        Assert-Sha256 -Value $beforeRawSha256 -Context "$Context before raw hash for '$SkillId/$beforePath'"
        Assert-Sha256 -Value $afterRawSha256 -Context "$Context after raw hash for '$SkillId/$beforePath'"
        if ([string]$beforeRawSha256 -cne [string]$afterRawSha256) {
            throw "Candidate Skill '$SkillId' file '$beforePath' changed raw bytes $Context."
        }
    }
}

function Get-FileByteSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Path
    )
    $bytes = [IO.File]::ReadAllBytes($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $hasher.Dispose()
    }
}

function Get-DescendantProcessIds {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId
    )
    if (-not $script:IsSupportedProcessBoundaryHost) {
        throw 'Process-tree enumeration is supported only on Windows and Linux hosts.'
    }
    $processes = @()
    if ($script:IsWindowsHost) {
        try {
            $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop | ForEach-Object {
                [pscustomobject]@{
                    processId = [int]$_.ProcessId
                    parentProcessId = [int]$_.ParentProcessId
                }
            })
        }
        catch {
            throw "Could not enumerate Windows child processes for process-tree cleanup: $($_.Exception.Message)"
        }
    }
    else {
        foreach ($entry in @(Get-ChildItem -LiteralPath '/proc' -Directory -ErrorAction SilentlyContinue)) {
            if ([string]$entry.Name -notmatch '^[0-9]+$') { continue }
            try {
                $info = Get-UnixProcessInfo -ProcessId ([int]$entry.Name)
                $processes += [pscustomobject]@{
                    processId = [int]$entry.Name
                    parentProcessId = [int]$info.parentProcessId
                }
            }
            catch { continue }
        }
    }

    $frontier = @($RootProcessId)
    $descendantIds = [Collections.Generic.List[int]]::new()
    while ($frontier.Count -gt 0) {
        $next = [Collections.Generic.List[int]]::new()
        foreach ($process in $processes) {
            $processId = [int]$process.processId
            if ($frontier -contains [int]$process.parentProcessId -and
                -not $descendantIds.Contains($processId)) {
                [void]$descendantIds.Add($processId)
                [void]$next.Add($processId)
            }
        }
        $frontier = @($next.ToArray())
    }
    return @($descendantIds.ToArray())
}

function Get-UnixProcessGroupId {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId
    )
    if ($script:IsWindowsHost) { return 0 }
    $info = Get-UnixProcessInfo -ProcessId $ProcessId
    return [int]$info.processGroupId
}

function Get-UnixProcessInfo {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId
    )
    if (-not $script:IsLinuxHost) {
        throw 'Unix process inspection requires a Linux host with procfs.'
    }
    if ($ProcessId -le 0) { throw 'Unix process inspection requires a positive process id.' }
    $statPath = Join-Path '/proc' "$ProcessId/stat"
    try {
        $stat = [IO.File]::ReadAllText($statPath)
    }
    catch {
        throw "Could not inspect Unix process ${ProcessId}: $($_.Exception.Message)"
    }
    $closeParen = $stat.LastIndexOf(')')
    if ($closeParen -lt 0) {
        throw "Could not parse Unix process ${ProcessId}: the command name is incomplete."
    }
    $fields = @([regex]::Split($stat.Substring($closeParen + 1).Trim(), '\s+'))
    # The fields start at proc(5) field 3 (state). Field 5 is the process
    # group and field 22 is the kernel process start time.
    if ($fields.Count -lt 20 -or
        [string]$fields[0] -notmatch '^\S$' -or
        [string]$fields[1] -notmatch '^[0-9]+$' -or
        [string]$fields[2] -notmatch '^[0-9]+$' -or
        [string]$fields[19] -notmatch '^[0-9]+$') {
        throw "Could not parse Unix process metadata for process $ProcessId."
    }
    return [pscustomobject][ordered]@{
        processId = $ProcessId
        parentProcessId = [int]$fields[1]
        processGroupId = [int]$fields[2]
        startTime = [string]$fields[19]
    }
}

function Get-UnixProcessGroupProcessIds {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessGroupId
    )
    if ($script:IsWindowsHost) { return @() }
    if (-not $script:IsLinuxHost) { throw 'Unix process-group enumeration requires a Linux host with procfs.' }
    if ($ProcessGroupId -le 0) { throw 'Unix process-group enumeration requires a positive process-group id.' }
    $members = [Collections.Generic.List[int]]::new()
    foreach ($entry in @(Get-ChildItem -LiteralPath '/proc' -Directory -ErrorAction SilentlyContinue)) {
        if ([string]$entry.Name -notmatch '^[0-9]+$') { continue }
        try {
            $info = Get-UnixProcessInfo -ProcessId ([int]$entry.Name)
        }
        catch {
            continue
        }
        if ($info.processGroupId -eq $ProcessGroupId) {
            [void]$members.Add([int]$entry.Name)
        }
    }
    return @($members.ToArray())
}

function Test-ProcessIdExists {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId
    )
    if ($ProcessId -le 0) { return $false }
    if ($script:IsWindowsHost) {
        try {
            Get-Process -Id $ProcessId -ErrorAction Stop | Out-Null
            return $true
        }
        catch {
            return $false
        }
    }
    if (-not $script:IsLinuxHost) { throw 'Process identity inspection requires a supported Windows or Linux host.' }
    return Test-Path -LiteralPath (Join-Path '/proc' ([string]$ProcessId)) -PathType Container
}

function Get-ProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId
    )
    if ($ProcessId -le 0) { throw 'Process identity inspection requires a positive process id.' }
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    try {
        $startTime = $process.StartTime.ToUniversalTime().Ticks
        return 'start-time:{0}' -f $startTime
    }
    finally {
        $process.Dispose()
    }
}

function Test-ProcessIdentity {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [Parameter(Mandatory = $true)][string] $Identity
    )
    try {
        return (Get-ProcessIdentity -ProcessId $ProcessId) -ceq $Identity
    }
    catch {
        return $false
    }
}

function Stop-UnixProcessByIdentity {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [Parameter(Mandatory = $true)][string] $Identity,
        [Parameter(Mandatory = $true)][int] $Signal
    )
    if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($Identity) -or $Signal -le 0) {
        return $false
    }
    $nativeType = 'Codex.Validation.UnixProcessBoundary' -as [type]
    if ($null -eq $nativeType) {
        Enable-UnixChildSubreaper
        $nativeType = 'Codex.Validation.UnixProcessBoundary' -as [type]
    }
    if ($null -eq $nativeType) {
        throw 'The Unix pidfd interop type could not be loaded.'
    }
    # Open a pidfd before the final identity check so signaling remains bound
    # to the observed process instance even if its numeric PID is reused.
    $fileDescriptor = -1
    if (-not (Test-ProcessIdentity -ProcessId $ProcessId -Identity $Identity)) {
        return $true
    }
    $fileDescriptor = $nativeType::OpenProcessFileDescriptor($ProcessId)
    if ($fileDescriptor -lt 0) {
        if (-not (Test-ProcessIdentity -ProcessId $ProcessId -Identity $Identity)) {
            return $true
        }
        return $false
    }
    try {
        try {
            $actualIdentity = Get-ProcessIdentity -ProcessId $ProcessId
        }
        catch {
            return (-not (Test-ProcessIdentity -ProcessId $ProcessId -Identity $Identity))
        }
        if ($actualIdentity -cne $Identity) {
            return $false
        }
        $result = $nativeType::SendProcessSignal($fileDescriptor, $Signal)
        if ($result -eq 0) {
            return $true
        }
        return (-not (Test-ProcessIdentity -ProcessId $ProcessId -Identity $Identity))
    }
    finally {
        [void]$nativeType::CloseProcessFileDescriptor($fileDescriptor)
    }
}

function Get-WindowsProcessBoundaryType {
    if (-not $script:IsWindowsHost) {
        throw 'The Windows process boundary is supported only on Windows hosts.'
    }
    $nativeType = 'Codex.Validation.WindowsProcessBoundary' -as [type]
    if ($null -eq $nativeType) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Codex.Validation {
    public static class WindowsProcessBoundary {
        [StructLayout(LayoutKind.Sequential)]
        private struct IoCounters {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BasicLimitInformation {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct ExtendedLimitInformation {
            public BasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeFileTime {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateJobObject(IntPtr lpJobAttributes, string lpName);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(
            IntPtr jobHandle,
            int jobObjectInformationClass,
            IntPtr jobObjectInformation,
            uint jobObjectInformationLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr jobHandle, IntPtr processHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr jobHandle, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(
            IntPtr processHandle,
            out NativeFileTime creationTime,
            out NativeFileTime exitTime,
            out NativeFileTime kernelTime,
            out NativeFileTime userTime);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr processHandle, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static IntPtr CreateKillOnCloseJob() {
            IntPtr jobHandle = CreateJobObject(IntPtr.Zero, null);
            if (jobHandle == IntPtr.Zero) {
                return IntPtr.Zero;
            }
            ExtendedLimitInformation information = new ExtendedLimitInformation();
            information.BasicLimitInformation.LimitFlags = 0x00002000;
            int informationLength = Marshal.SizeOf(typeof(ExtendedLimitInformation));
            IntPtr informationBuffer = Marshal.AllocHGlobal(informationLength);
            try {
                Marshal.StructureToPtr(information, informationBuffer, false);
                if (!SetInformationJobObject(jobHandle, 9, informationBuffer, (uint)informationLength)) {
                    CloseHandle(jobHandle);
                    return IntPtr.Zero;
                }
                return jobHandle;
            }
            finally {
                Marshal.FreeHGlobal(informationBuffer);
            }
        }

        public static bool AssignProcess(IntPtr jobHandle, IntPtr processHandle) {
            return AssignProcessToJobObject(jobHandle, processHandle);
        }

        public static bool TerminateJob(IntPtr jobHandle, uint exitCode) {
            return TerminateJobObject(jobHandle, exitCode);
        }

        public static IntPtr OpenProcessForTermination(int processId) {
            return OpenProcess(0x00100401, false, (uint)processId);
        }

        public static long GetProcessCreationTimeTicks(IntPtr processHandle) {
            NativeFileTime creationTime;
            NativeFileTime exitTime;
            NativeFileTime kernelTime;
            NativeFileTime userTime;
            if (!GetProcessTimes(processHandle, out creationTime, out exitTime, out kernelTime, out userTime)) {
                return -1;
            }
            long fileTime = ((long)creationTime.HighDateTime << 32) | (long)creationTime.LowDateTime;
            return DateTime.FromFileTimeUtc(fileTime).Ticks;
        }

        public static bool TerminateProcessHandle(IntPtr processHandle, uint exitCode) {
            return TerminateProcess(processHandle, exitCode);
        }

        public static bool Close(IntPtr handle) {
            return CloseHandle(handle);
        }
    }
}
'@ -ErrorAction Stop
        $nativeType = 'Codex.Validation.WindowsProcessBoundary' -as [type]
    }
    if ($null -eq $nativeType) {
        throw 'The Windows process boundary interop type could not be loaded.'
    }
    return $nativeType
}

function Get-WindowsSuspendedProcessBoundaryType {
    # The interop type also owns the cross-platform bounded output reader. The
    # Windows-only process-start entry point is called only on Windows.
    $nativeType = 'Codex.Validation.WindowsSuspendedProcessBoundary' -as [type]
    if ($null -eq $nativeType) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace Codex.Validation {
    public sealed class BoundedProcessOutputResult {
        public string Text { get; private set; }
        public bool Truncated { get; private set; }
        public long TotalCharacters { get; private set; }

        internal BoundedProcessOutputResult(string text, bool truncated, long totalCharacters) {
            Text = text;
            Truncated = truncated;
            TotalCharacters = totalCharacters;
        }
    }

    public sealed class WindowsSuspendedProcess : IDisposable {
        private IntPtr processHandle;
        private IntPtr threadHandle;
        private bool disposed;

        public int Id { get; private set; }
        public IntPtr ProcessHandle { get { return processHandle; } }
        public StreamWriter StandardInput { get; private set; }
        public StreamReader StandardOutput { get; private set; }
        public StreamReader StandardError { get; private set; }

        internal WindowsSuspendedProcess(
            ProcessInformation processInformation,
            IntPtr standardInputWrite,
            IntPtr standardOutputRead,
            IntPtr standardErrorRead) {
            processHandle = processInformation.ProcessHandle;
            threadHandle = processInformation.ThreadHandle;
            Id = processInformation.ProcessId;
            StandardInput = standardInputWrite == IntPtr.Zero
                ? null
                : new StreamWriter(
                    new FileStream(new SafeFileHandle(standardInputWrite, true), FileAccess.Write, 4096, false),
                    new UTF8Encoding(false));
            StandardOutput = new StreamReader(
                new FileStream(new SafeFileHandle(standardOutputRead, true), FileAccess.Read, 4096, false),
                new UTF8Encoding(false), false, 4096);
            StandardError = new StreamReader(
                new FileStream(new SafeFileHandle(standardErrorRead, true), FileAccess.Read, 4096, false),
                new UTF8Encoding(false), false, 4096);
        }

        public bool HasExited {
            get {
                EnsureNotDisposed();
                return WaitForSingleObject(processHandle, 0) == 0;
            }
        }

        public bool WaitForExit(int milliseconds) {
            EnsureNotDisposed();
            uint timeout = milliseconds < 0 ? 0xffffffffU : (uint)milliseconds;
            return WaitForSingleObject(processHandle, timeout) == 0;
        }

        public int ExitCode {
            get {
                EnsureNotDisposed();
                uint exitCode;
                if (!GetExitCodeProcess(processHandle, out exitCode)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "GetExitCodeProcess failed.");
                }
                return unchecked((int)exitCode);
            }
        }

        public bool Resume() {
            EnsureNotDisposed();
            if (threadHandle == IntPtr.Zero) { return false; }
            uint previousSuspendCount = ResumeThread(threadHandle);
            if (previousSuspendCount == 0xffffffffU) { return false; }
            CloseHandle(threadHandle);
            threadHandle = IntPtr.Zero;
            return true;
        }

        public bool Terminate() {
            EnsureNotDisposed();
            return TerminateProcess(processHandle, 1);
        }

        private void EnsureNotDisposed() {
            if (disposed || processHandle == IntPtr.Zero) {
                throw new ObjectDisposedException("WindowsSuspendedProcess");
            }
        }

        public void Dispose() {
            if (disposed) { return; }
            disposed = true;
            if (StandardInput != null) { StandardInput.Dispose(); }
            if (StandardOutput != null) { StandardOutput.Dispose(); }
            if (StandardError != null) { StandardError.Dispose(); }
            if (threadHandle != IntPtr.Zero) {
                CloseHandle(threadHandle);
                threadHandle = IntPtr.Zero;
            }
            if (processHandle != IntPtr.Zero) {
                CloseHandle(processHandle);
                processHandle = IntPtr.Zero;
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr threadHandle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr processHandle, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr processHandle, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);
    }

    public sealed class ProcessInformation {
        public IntPtr ProcessHandle;
        public IntPtr ThreadHandle;
        public int ProcessId;
        public int ThreadId;
    }

    public static class WindowsSuspendedProcessBoundary {
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint CreateExtendedStartupInfo = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint ProcThreadAttributeHandleList = 0x00020002;
        private const int ErrorInsufficientBuffer = 122;
        private const uint WaitObject0 = 0x00000000;

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfo {
            public int Size;
            public IntPtr Reserved;
            public IntPtr Desktop;
            public IntPtr Title;
            public int X;
            public int Y;
            public int XSize;
            public int YSize;
            public int XCountChars;
            public int YCountChars;
            public int FillAttribute;
            public uint Flags;
            public short ShowWindow;
            public short Reserved2;
            public IntPtr Reserved2Data;
            public IntPtr StandardInput;
            public IntPtr StandardOutput;
            public IntPtr StandardError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeProcessInformation {
            public IntPtr ProcessHandle;
            public IntPtr ThreadHandle;
            public int ProcessId;
            public int ThreadId;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreatePipe(
            out IntPtr readHandle,
            out IntPtr writeHandle,
            ref SecurityAttributes attributes,
            int size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetHandleInformation(
            IntPtr handle,
            uint mask,
            uint flags);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref StartupInfoEx startupInfo,
            out NativeProcessInformation processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(
            IntPtr attributeList,
            int attributeCount,
            uint flags,
            ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll", SetLastError = false)]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        public static WindowsSuspendedProcess Start(
            string fileName,
            string[] arguments,
            string workingDirectory,
            IDictionary environment,
            bool useStandardInput) {
            if (String.IsNullOrWhiteSpace(fileName)) { throw new ArgumentException("fileName"); }
            if (String.IsNullOrWhiteSpace(workingDirectory)) { throw new ArgumentException("workingDirectory"); }

            IntPtr childStandardInput = IntPtr.Zero;
            IntPtr parentStandardInput = IntPtr.Zero;
            IntPtr parentStandardOutput = IntPtr.Zero;
            IntPtr childStandardOutput = IntPtr.Zero;
            IntPtr parentStandardError = IntPtr.Zero;
            IntPtr childStandardError = IntPtr.Zero;
            IntPtr environmentBlock = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero;
            IntPtr attributeListSize = IntPtr.Zero;
            IntPtr handleList = IntPtr.Zero;
            bool attributeListInitialized = false;
            NativeProcessInformation nativeProcessInformation = new NativeProcessInformation();
            WindowsSuspendedProcess result = null;
            try {
                SecurityAttributes pipeAttributes = new SecurityAttributes {
                    Length = Marshal.SizeOf(typeof(SecurityAttributes)),
                    SecurityDescriptor = IntPtr.Zero,
                    InheritHandle = true
                };
                ThrowIfFalse(CreatePipe(out childStandardInput, out parentStandardInput, ref pipeAttributes, 0), "CreatePipe(stdin)");
                ThrowIfFalse(CreatePipe(out parentStandardOutput, out childStandardOutput, ref pipeAttributes, 0), "CreatePipe(stdout)");
                ThrowIfFalse(CreatePipe(out parentStandardError, out childStandardError, ref pipeAttributes, 0), "CreatePipe(stderr)");
                ThrowIfFalse(SetHandleInformation(parentStandardInput, HandleFlagInherit, 0), "SetHandleInformation(stdin)");
                ThrowIfFalse(SetHandleInformation(parentStandardOutput, HandleFlagInherit, 0), "SetHandleInformation(stdout)");
                ThrowIfFalse(SetHandleInformation(parentStandardError, HandleFlagInherit, 0), "SetHandleInformation(stderr)");

                if (!useStandardInput) {
                    CloseHandle(parentStandardInput);
                    parentStandardInput = IntPtr.Zero;
                }

                StartupInfoEx startupInfo = new StartupInfoEx {
                    StartupInfo = new StartupInfo {
                        Size = Marshal.SizeOf(typeof(StartupInfoEx)),
                        Flags = StartfUseStdHandles,
                        StandardInput = childStandardInput,
                        StandardOutput = childStandardOutput,
                        StandardError = childStandardError
                    }
                };
                bool initialAttributeListResult = InitializeProcThreadAttributeList(
                    IntPtr.Zero,
                    1,
                    0,
                    ref attributeListSize);
                int initialAttributeListError = Marshal.GetLastWin32Error();
                if (initialAttributeListResult || initialAttributeListError != ErrorInsufficientBuffer || attributeListSize == IntPtr.Zero) {
                    throw new Win32Exception(initialAttributeListError, "InitializeProcThreadAttributeList(size) failed.");
                }
                attributeList = Marshal.AllocHGlobal(attributeListSize);
                ThrowIfFalse(InitializeProcThreadAttributeList(
                    attributeList,
                    1,
                    0,
                    ref attributeListSize), "InitializeProcThreadAttributeList");
                attributeListInitialized = true;
                IntPtr[] inheritedHandles = new IntPtr[] {
                    childStandardInput,
                    childStandardOutput,
                    childStandardError
                };
                handleList = Marshal.AllocHGlobal(new IntPtr(IntPtr.Size * inheritedHandles.Length));
                Marshal.Copy(inheritedHandles, 0, handleList, inheritedHandles.Length);
                ThrowIfFalse(UpdateProcThreadAttribute(
                    attributeList,
                    0,
                    (IntPtr)ProcThreadAttributeHandleList,
                    handleList,
                    new IntPtr(IntPtr.Size * inheritedHandles.Length),
                    IntPtr.Zero,
                    IntPtr.Zero), "UpdateProcThreadAttribute(handle list)");
                startupInfo.AttributeList = attributeList;
                string environmentText = BuildEnvironment(environment);
                environmentBlock = Marshal.StringToHGlobalUni(environmentText);
                StringBuilder commandLine = new StringBuilder(BuildCommandLine(fileName, arguments));
                ThrowIfFalse(CreateProcessW(
                    fileName,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CreateSuspended | CreateUnicodeEnvironment | CreateExtendedStartupInfo | CreateNoWindow,
                    environmentBlock,
                    workingDirectory,
                    ref startupInfo,
                    out nativeProcessInformation), "CreateProcessW");

                CloseHandle(childStandardInput); childStandardInput = IntPtr.Zero;
                CloseHandle(childStandardOutput); childStandardOutput = IntPtr.Zero;
                CloseHandle(childStandardError); childStandardError = IntPtr.Zero;
                result = new WindowsSuspendedProcess(
                    new ProcessInformation {
                        ProcessHandle = nativeProcessInformation.ProcessHandle,
                        ThreadHandle = nativeProcessInformation.ThreadHandle,
                        ProcessId = nativeProcessInformation.ProcessId,
                        ThreadId = nativeProcessInformation.ThreadId
                    },
                    parentStandardInput,
                    parentStandardOutput,
                    parentStandardError);
                nativeProcessInformation.ProcessHandle = IntPtr.Zero;
                nativeProcessInformation.ThreadHandle = IntPtr.Zero;
                parentStandardInput = IntPtr.Zero;
                parentStandardOutput = IntPtr.Zero;
                parentStandardError = IntPtr.Zero;
                return result;
            }
            finally {
                CloseIfPresent(childStandardInput);
                CloseIfPresent(childStandardOutput);
                CloseIfPresent(childStandardError);
                CloseIfPresent(parentStandardInput);
                CloseIfPresent(parentStandardOutput);
                CloseIfPresent(parentStandardError);
                CloseIfPresent(nativeProcessInformation.ProcessHandle);
                CloseIfPresent(nativeProcessInformation.ThreadHandle);
                if (attributeListInitialized) { DeleteProcThreadAttributeList(attributeList); }
                if (attributeList != IntPtr.Zero) { Marshal.FreeHGlobal(attributeList); }
                if (handleList != IntPtr.Zero) { Marshal.FreeHGlobal(handleList); }
                if (environmentBlock != IntPtr.Zero) { Marshal.FreeHGlobal(environmentBlock); }
            }
        }

        public static Task<BoundedProcessOutputResult> ReadBoundedAsync(TextReader reader, int maximumCharacters) {
            return Task.Run(() => ReadBounded(reader, maximumCharacters));
        }

        private static BoundedProcessOutputResult ReadBounded(TextReader reader, int maximumCharacters) {
            if (reader == null) { throw new ArgumentNullException("reader"); }
            if (maximumCharacters < 1) { throw new ArgumentOutOfRangeException("maximumCharacters"); }
            char[] buffer = new char[8192];
            StringBuilder captured = new StringBuilder(Math.Min(maximumCharacters, 65536));
            long totalCharacters = 0;
            bool truncated = false;
            int read;
            while ((read = reader.Read(buffer, 0, buffer.Length)) > 0) {
                totalCharacters += read;
                int remaining = maximumCharacters - captured.Length;
                if (remaining > 0) {
                    int take = Math.Min(remaining, read);
                    captured.Append(buffer, 0, take);
                    if (take < read) { truncated = true; }
                }
                else {
                    truncated = true;
                }
            }
            return new BoundedProcessOutputResult(captured.ToString(), truncated, totalCharacters);
        }

        private static string BuildEnvironment(IDictionary environment) {
            List<string> entries = new List<string>();
            if (environment != null) {
                foreach (DictionaryEntry entry in environment) {
                    string name = Convert.ToString(entry.Key);
                    string value = entry.Value == null ? String.Empty : Convert.ToString(entry.Value);
                    if (String.IsNullOrEmpty(name) || name.IndexOf('\0') >= 0 || name[0] == '=') {
                        throw new ArgumentException("Invalid environment variable name.");
                    }
                    if (value.IndexOf('\0') >= 0) {
                        throw new ArgumentException("Invalid environment variable value.");
                    }
                    entries.Add(name + "=" + value);
                }
            }
            entries.Sort(StringComparer.OrdinalIgnoreCase);
            StringBuilder block = new StringBuilder();
            foreach (string entry in entries) { block.Append(entry).Append('\0'); }
            block.Append('\0');
            return block.ToString();
        }

        private static string BuildCommandLine(string fileName, string[] arguments) {
            StringBuilder commandLine = new StringBuilder(QuoteArgument(fileName));
            if (arguments != null) {
                foreach (string argument in arguments) {
                    commandLine.Append(' ').Append(QuoteArgument(argument ?? String.Empty));
                }
            }
            return commandLine.ToString();
        }

        private static string QuoteArgument(string argument) {
            StringBuilder result = new StringBuilder();
            result.Append('"');
            int backslashes = 0;
            foreach (char character in argument) {
                if (character == '\\') { backslashes++; continue; }
                if (character == '"') {
                    result.Append('\\', backslashes * 2 + 1).Append('"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(character);
            }
            result.Append('\\', backslashes * 2).Append('"');
            return result.ToString();
        }

        private static void ThrowIfFalse(bool value, string operation) {
            if (!value) { throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed."); }
        }

        private static void CloseIfPresent(IntPtr handle) {
            if (handle != IntPtr.Zero) { CloseHandle(handle); }
        }
    }
}
'@ -ErrorAction Stop
        $nativeType = 'Codex.Validation.WindowsSuspendedProcessBoundary' -as [type]
    }
    if ($null -eq $nativeType) {
        throw 'The suspended Windows process boundary interop type could not be loaded.'
    }
    return $nativeType
}

function Start-WindowsSuspendedProcess {
    param(
        [Parameter(Mandatory = $true)][string] $FileName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $WorkingDirectory,
        [Parameter(Mandatory = $true)] [Collections.IDictionary] $EnvironmentVariables,
        [Parameter(Mandatory = $true)][bool] $UseStandardInput
    )
    $nativeType = Get-WindowsSuspendedProcessBoundaryType
    return $nativeType::Start($FileName, $Arguments, $WorkingDirectory, $EnvironmentVariables, $UseStandardInput)
}

function New-WindowsKillOnCloseJob {
    param([Parameter(Mandatory = $true)][string] $Context)
    # The handle's creation time is checked before TerminateProcess is called
    # on that same handle; no numeric PID is reused for the signal operation.
    $nativeType = Get-WindowsProcessBoundaryType
    $jobHandle = $nativeType::CreateKillOnCloseJob()
    if ($jobHandle -eq [IntPtr]::Zero) {
        throw "$Context could not create a kill-on-close Windows Job Object."
    }
    return $jobHandle
}

function Assign-WindowsProcessToJob {
    param(
        [Parameter(Mandatory = $true)][IntPtr] $JobHandle,
        [Parameter(Mandatory = $true)][object] $Process,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $nativeType = Get-WindowsProcessBoundaryType
    $processHandle = if ($Process -is [Diagnostics.Process]) { $Process.Handle } else { [IntPtr]$Process.ProcessHandle }
    if (-not $nativeType::AssignProcess($JobHandle, $processHandle)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "$Context could not assign the child to its Windows Job Object (Win32 error $errorCode)."
    }
}

function Stop-WindowsProcessByIdentity {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [Parameter(Mandatory = $true)][string] $Identity
    )
    if ($ProcessId -le 0 -or [string]::IsNullOrWhiteSpace($Identity)) {
        return $false
    }
    $prefix = 'start-time:'
    if (-not $Identity.StartsWith($prefix, [StringComparison]::Ordinal)) {
        return $false
    }
    try {
        $expectedTicks = [long]::Parse(
            $Identity.Substring($prefix.Length),
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return $false
    }
    $nativeType = Get-WindowsProcessBoundaryType
    $processHandle = $nativeType::OpenProcessForTermination($ProcessId)
    if ($processHandle -eq [IntPtr]::Zero) {
        return (-not (Test-ProcessIdExists -ProcessId $ProcessId))
    }
    try {
        $actualTicks = $nativeType::GetProcessCreationTimeTicks($processHandle)
        if ($actualTicks -lt 0 -or $actualTicks -ne $expectedTicks) {
            return $false
        }
        if ($nativeType::TerminateProcessHandle($processHandle, 1)) {
            return $true
        }
        return (-not (Test-ProcessIdentity -ProcessId $ProcessId -Identity $Identity))
    }
    finally {
        [void]$nativeType::Close($processHandle)
    }
}

function Stop-WindowsProcessJob {
    param([Parameter(Mandatory = $true)][IntPtr] $JobHandle)
    $nativeType = Get-WindowsProcessBoundaryType
    if (-not $nativeType::TerminateJob($JobHandle, 1)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Could not terminate the candidate Windows Job Object (Win32 error $errorCode)."
    }
}

function Close-WindowsProcessJob {
    param([Parameter(Mandatory = $true)][IntPtr] $JobHandle)
    if ($JobHandle -eq [IntPtr]::Zero) { return }
    $nativeType = Get-WindowsProcessBoundaryType
    [void]$nativeType::Close($JobHandle)
}


function Enable-UnixChildSubreaper {
    if ($script:IsWindowsHost) { return }
    if (-not $script:IsLinuxHost) { throw 'The Unix child subreaper is supported only on Linux.' }
    $nativeType = 'Codex.Validation.UnixProcessBoundary' -as [type]
    if ($null -eq $nativeType) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Codex.Validation {
    public static class UnixProcessBoundary {
        [DllImport("libc.so.6", EntryPoint = "prctl", SetLastError = true)]
        private static extern int SetProcessControl(int option, ulong arg2, ulong arg3, ulong arg4, ulong arg5);

        [DllImport("libc.so.6", EntryPoint = "prctl", SetLastError = true)]
        private static extern int GetProcessControl(int option, out int arg2, ulong arg3, ulong arg4, ulong arg5);

        public static int SetChildSubreaper() {
            return SetProcessControl(36, 1, 0, 0, 0);
        }

        public static int GetChildSubreaper(out int enabled) {
            return GetProcessControl(37, out enabled, 0, 0, 0);
        }

        [DllImport("libc.so.6", EntryPoint = "syscall", SetLastError = true)]
        private static extern long InvokePidfdOpen(long syscallNumber, int processId, uint flags);

        [DllImport("libc.so.6", EntryPoint = "syscall", SetLastError = true)]
        private static extern long InvokePidfdSendSignal(long syscallNumber, int processFileDescriptor, int signal, IntPtr signalInfo, uint flags);

        [DllImport("libc.so.6", EntryPoint = "close", SetLastError = true)]
        private static extern int CloseFileDescriptor(int fileDescriptor);

        public static int OpenProcessFileDescriptor(int processId) {
            return (int)InvokePidfdOpen(434, processId, 0);
        }

        public static int SendProcessSignal(int processFileDescriptor, int signal) {
            return (int)InvokePidfdSendSignal(424, processFileDescriptor, signal, IntPtr.Zero, 0);
        }

        public static int CloseProcessFileDescriptor(int processFileDescriptor) {
            return CloseFileDescriptor(processFileDescriptor);
        }
    }
}
'@ -ErrorAction Stop
        $nativeType = 'Codex.Validation.UnixProcessBoundary' -as [type]
    }
    if ($null -eq $nativeType) {
        throw 'The Unix child-subreaper interop type could not be loaded.'
    }
    $setResult = $nativeType::SetChildSubreaper()
    if ($setResult -ne 0) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Could not enable the Unix child subreaper (errno $errorCode)."
    }
    $enabled = 0
    $getResult = $nativeType::GetChildSubreaper([ref]$enabled)
    if ($getResult -ne 0 -or $enabled -ne 1) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Unix child-subreaper verification failed (errno $errorCode, enabled $enabled)."
    }
}

function Wait-ForUnixProcessGroupId {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [Parameter(Mandatory = $true)][int] $ParentProcessGroupId,
        [Parameter()][int] $TimeoutMilliseconds = 5000
    )
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not (Test-ProcessIdExists -ProcessId $ProcessId)) { return 0 }
        try {
            $groupId = Get-UnixProcessGroupId -ProcessId $ProcessId
            if ($groupId -gt 0 -and $groupId -ne $ParentProcessGroupId) { return $groupId }
        }
        catch { }
        Start-Sleep -Milliseconds 25
    }
    throw 'The isolated Linux process did not establish a distinct process group before the bounded readiness timeout.'
}

function Add-ProcessIdentityToObservation {
    param(
        [Parameter(Mandatory = $true)][int] $ProcessId,
        [Parameter(Mandatory = $true)] $ObservedProcessIdentities
    )
    if ($ProcessId -le 0 -or $ObservedProcessIdentities.ContainsKey($ProcessId)) { return }
    if (-not (Test-ProcessIdExists -ProcessId $ProcessId)) { return }
    try {
        $identity = Get-ProcessIdentity -ProcessId $ProcessId
    }
    catch {
        if (Test-ProcessIdExists -ProcessId $ProcessId) {
            throw ("Could not bind candidate process identity for process " + $ProcessId + ": " + $_.Exception.Message)
        }
        return
    }
    [void]$ObservedProcessIdentities.Add($ProcessId, [string]$identity)
}

function Add-ObservedProcessIds {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId,
        [Parameter(Mandatory = $true)] $ObservedProcessIdentities,
        [Parameter()][int] $ProcessGroupId = 0,
        [Parameter()][int] $SupervisorProcessId = 0,
        [Parameter()][AllowNull()] $BaselineSupervisorProcessIdentities
    )
    if (Test-ProcessIdExists -ProcessId $RootProcessId) {
        foreach ($processId in @(Get-DescendantProcessIds -RootProcessId $RootProcessId)) {
            if ($processId -ne $RootProcessId) {
                Add-ProcessIdentityToObservation -ProcessId ([int]$processId) -ObservedProcessIdentities $ObservedProcessIdentities
            }
        }
    }
    if ($script:IsLinuxHost -and $ProcessGroupId -gt 0) {
        foreach ($processId in @(Get-UnixProcessGroupProcessIds -ProcessGroupId $ProcessGroupId)) {
            if ($processId -ne $RootProcessId) {
                Add-ProcessIdentityToObservation -ProcessId ([int]$processId) -ObservedProcessIdentities $ObservedProcessIdentities
            }
        }
    }
    if ($SupervisorProcessId -gt 0 -and $SupervisorProcessId -ne $RootProcessId) {
        foreach ($processId in @(Get-DescendantProcessIds -RootProcessId $SupervisorProcessId)) {
            if ($processId -eq $RootProcessId) { continue }
            $isBaseline = $false
            if ($null -ne $BaselineSupervisorProcessIdentities -and
                $BaselineSupervisorProcessIdentities.ContainsKey([int]$processId)) {
                $isBaseline = Test-ProcessIdentity -ProcessId ([int]$processId) -Identity ([string]$BaselineSupervisorProcessIdentities[[int]$processId])
            }
            if (-not $isBaseline) {
                Add-ProcessIdentityToObservation -ProcessId ([int]$processId) -ObservedProcessIdentities $ObservedProcessIdentities
            }
        }
    }
}

function Stop-ProcessTree {
    param(
        [Parameter(Mandatory = $true)][int] $RootProcessId,
        [Parameter()][int] $ProcessGroupId = 0,
        [Parameter()][AllowNull()][string] $RootProcessIdentity,
        [Parameter(Mandatory = $true)] $ObservedProcessIdentities,
        [Parameter()][IntPtr] $WindowsJobHandle = [IntPtr]::Zero
    )
    if ($RootProcessId -le 0) { throw 'Process-tree cleanup requires a positive root process id.' }
    if (-not $script:IsSupportedProcessBoundaryHost) {
        throw 'Process-tree cleanup is supported only on Windows and Linux hosts.'
    }
    if ($script:IsWindowsHost) {
        [void](Get-WindowsProcessBoundaryType)
    }
    elseif ($script:IsLinuxHost) {
        if ($ProcessGroupId -le 0 -and (Test-ProcessIdExists -ProcessId $RootProcessId)) {
            $ProcessGroupId = Get-UnixProcessGroupId -ProcessId $RootProcessId
        }
    }

    for ($round = 0; $round -lt 3; $round++) {
        $rootIsCandidate = if ([string]::IsNullOrWhiteSpace($RootProcessIdentity)) {
            Test-ProcessIdExists -ProcessId $RootProcessId
        }
        else {
            Test-ProcessIdentity -ProcessId $RootProcessId -Identity $RootProcessIdentity
        }
        if ($rootIsCandidate) {
            Add-ObservedProcessIds -RootProcessId $RootProcessId -ObservedProcessIdentities $ObservedProcessIdentities -ProcessGroupId $ProcessGroupId
        }
        $groupMembers = if ($script:IsWindowsHost -or $ProcessGroupId -le 0) { @() } else { @(Get-UnixProcessGroupProcessIds -ProcessGroupId $ProcessGroupId) }
        if ($rootIsCandidate) {
            foreach ($processId in @($groupMembers)) {
                if ([int]$processId -ne $RootProcessId) {
                    Add-ProcessIdentityToObservation -ProcessId ([int]$processId) -ObservedProcessIdentities $ObservedProcessIdentities
                }
            }
        }
        $targets = @($ObservedProcessIdentities.Keys | Where-Object {
            [int]$_ -gt 0 -and [int]$_ -ne $RootProcessId -and
            (Test-ProcessIdentity -ProcessId ([int]$_) -Identity ([string]$ObservedProcessIdentities[[int]$_]))
        } | Sort-Object -Unique -Descending)
        if ($script:IsWindowsHost) {
            if ($WindowsJobHandle -ne [IntPtr]::Zero -and $round -eq 0) {
                Stop-WindowsProcessJob -JobHandle $WindowsJobHandle
            }
            foreach ($processId in $targets) {
                [void](Stop-WindowsProcessByIdentity -ProcessId ([int]$processId) -Identity ([string]$ObservedProcessIdentities[[int]$processId]))
            }
            if ($rootIsCandidate) {
                if ([string]::IsNullOrWhiteSpace($RootProcessIdentity)) {
                    if ($WindowsJobHandle -eq [IntPtr]::Zero) {
                        throw 'Could not safely terminate the candidate Windows root without a bound process identity or Job Object.'
                    }
                }
                else {
                    [void](Stop-WindowsProcessByIdentity -ProcessId $RootProcessId -Identity $RootProcessIdentity)
                }
            }
        }
        else {
            $signalNumber = if ($round -eq 2) { 9 } else { 15 }
            if ($rootIsCandidate) {
                if ([string]::IsNullOrWhiteSpace($RootProcessIdentity)) {
                    throw 'Could not safely terminate the candidate Linux root without a bound process identity.'
                }
                [void](Stop-UnixProcessByIdentity -ProcessId $RootProcessId -Identity $RootProcessIdentity -Signal $signalNumber)
            }
            foreach ($processId in $targets) {
                [void](Stop-UnixProcessByIdentity -ProcessId ([int]$processId) -Identity ([string]$ObservedProcessIdentities[[int]$processId]) -Signal $signalNumber)
            }
        }
        Start-Sleep -Milliseconds 100
        if ($rootIsCandidate) {
            Add-ObservedProcessIds -RootProcessId $RootProcessId -ObservedProcessIdentities $ObservedProcessIdentities -ProcessGroupId $ProcessGroupId
        }
        $remainingRoot = if ([string]::IsNullOrWhiteSpace($RootProcessIdentity)) {
            Test-ProcessIdExists -ProcessId $RootProcessId
        }
        else {
            Test-ProcessIdentity -ProcessId $RootProcessId -Identity $RootProcessIdentity
        }
        $remainingObserved = @($ObservedProcessIdentities.Keys | Where-Object {
            Test-ProcessIdentity -ProcessId ([int]$_) -Identity ([string]$ObservedProcessIdentities[[int]$_])
        })
        $remainingGroupMembers = if ($script:IsWindowsHost -or $ProcessGroupId -le 0) { @() } else { @(Get-UnixProcessGroupProcessIds -ProcessGroupId $ProcessGroupId) }
        $unboundGroupMembers = @($remainingGroupMembers | Where-Object {
            [int]$_ -ne $RootProcessId -and
            (-not $ObservedProcessIdentities.ContainsKey([int]$_) -or
                -not (Test-ProcessIdentity -ProcessId ([int]$_) -Identity ([string]$ObservedProcessIdentities[[int]$_])))
        })
        if ($remainingGroupMembers.Count -gt 0 -and $unboundGroupMembers.Count -gt 0) {
            throw 'Could not establish process identity for every candidate process-group member.'
        }
        if (-not $remainingRoot -and $remainingObserved.Count -eq 0) { return }
    }
    throw "Could not terminate the complete candidate process boundary rooted at process $RootProcessId."
}

function Get-RunnerCommandFileSnapshot {
    param(
        [Parameter(Mandatory = $true)][string[]] $Names
    )
    $snapshot = [ordered]@{}
    foreach ($name in $Names) {
        $path = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrWhiteSpace($path)) {
            $snapshot[$name] = [pscustomobject][ordered]@{
                path = ''
                exists = $false
                sha256 = ''
            }
            continue
        }
        $fullPath = [IO.Path]::GetFullPath($path)
        $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
        $hash = ''
        if ($exists) {
            Assert-NoReparseAncestors -Path $fullPath -Context "Protected $name command file"
            $hash = Get-FileByteSha256 -Path $fullPath
        }
        $snapshot[$name] = [pscustomobject][ordered]@{
            path = $fullPath
            exists = [bool]$exists
            sha256 = $hash
        }
    }
    return $snapshot
}

function Assert-RunnerCommandFilesUnchanged {
    param(
        [Parameter(Mandatory = $true)] $Before,
        [Parameter(Mandatory = $true)][string[]] $Names
    )
    foreach ($name in $Names) {
        $beforeEntry = $Before[$name]
        $path = [string]$beforeEntry.path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $exists = Test-Path -LiteralPath $path -PathType Leaf
        if ([bool]$beforeEntry.exists -ne [bool]$exists) {
            throw "Protected $name command file was created or removed by candidate code."
        }
        if ($exists) {
            Assert-NoReparseAncestors -Path $path -Context "Protected $name command file"
            $actualHash = Get-FileByteSha256 -Path $path
            if ($actualHash -cne [string]$beforeEntry.sha256) {
                throw "Protected $name command file changed while candidate code was running."
            }
        }
    }
}

function ConvertTo-NativeProcessArgumentString {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Arguments
    )
    $rendered = foreach ($argument in $Arguments) {
        $value = [string]$argument
        $builder = [Text.StringBuilder]::new()
        [void]$builder.Append([char]34)
        $backslashCount = 0
        for ($index = 0; $index -lt $value.Length; $index++) {
            $character = $value[$index]
            if ($character -eq [char]92) {
                $backslashCount++
                continue
            }
            if ($character -eq [char]34) {
                [void]$builder.Append([char]92, ($backslashCount * 2) + 1)
                [void]$builder.Append([char]34)
                $backslashCount = 0
                continue
            }
            if ($backslashCount -gt 0) {
                [void]$builder.Append([char]92, $backslashCount)
                $backslashCount = 0
            }
            [void]$builder.Append($character)
        }
        if ($backslashCount -gt 0) {
            [void]$builder.Append([char]92, $backslashCount * 2)
        }
        [void]$builder.Append([char]34)
        $builder.ToString()
    }
    return ($rendered -join ' ')
}

function Get-ValidationSecurityAction {
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $Severity,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $severityMatches = @($Policy.security.severity | Where-Object { $_.level -ceq $Severity })
    if ($severityMatches.Count -ne 1 -or $severityMatches[0].action -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$severityMatches[0].action)) {
        throw "$Context has no unique central action for severity '$Severity'."
    }
    return [string]$severityMatches[0].action
}

function ConvertTo-ValidationSecurityFinding {
    param(
        [Parameter(Mandatory = $true)] $Policy,
        [Parameter(Mandatory = $true)][string] $ReportedSeverity,
        [Parameter(Mandatory = $true)][string] $Stage,
        [Parameter(Mandatory = $true)][string] $SkillId,
        [Parameter(Mandatory = $true)] $Issue
    )
    $severityAliases = [ordered]@{
        critical = 'critical'
        high = 'high'
        medium = 'medium'
        low = 'low'
        informational = 'informational'
        info = 'informational'
    }
    $severityKey = $ReportedSeverity.ToLowerInvariant()
    if (-not $severityAliases.Contains($severityKey)) {
        throw "$Stage returned unsupported severity '$ReportedSeverity' for '$SkillId'."
    }
    $severity = [string]$severityAliases[$severityKey]
    $action = Get-ValidationSecurityAction -Policy $Policy -Severity $severity -Context $Stage
    [pscustomobject][ordered]@{
        stage = $Stage
        skillId = $SkillId
        severity = $severity
        action = $action
        issue = $Issue
    }
}

function Test-PathEqual {
    param([string] $Left, [string] $Right)
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right), $comparison)
}

function Test-PathWithinOrEqual {
    param([string] $Path, [string] $Root)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return $fullPath.Equals($fullRoot, $comparison) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar, $comparison)
}

function Assert-NoReparseAncestors {
    param([string] $Path, [string] $Context)
    $currentPath = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($currentPath)) {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context is backed by a reparse point: $currentPath"
        }
        $parentPath = Split-Path -Parent $currentPath
        if ([string]::IsNullOrWhiteSpace($parentPath) -or (Test-PathEqual -Left $parentPath -Right $currentPath)) { break }
        $currentPath = $parentPath
    }
}

function Resolve-ReportedFilePath {
    param(
        [Parameter(Mandatory = $true)] $Value,
        [Parameter(Mandatory = $true)][string] $SkillRoot,
        [Parameter(Mandatory = $true)][string[]] $ExpectedInventoryPaths,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "$Context must be a non-empty path string." }
    $candidate = [string]$Value
    if ($candidate -cmatch '^file:') {
        $uri = $null
        if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$uri) -or -not $uri.IsFile) {
            throw "$Context must be a local Skill path."
        }
        $candidate = $uri.LocalPath
    }
    elseif (-not [IO.Path]::IsPathRooted($candidate) -and $candidate -cmatch '^[a-zA-Z][a-zA-Z0-9+.-]*:') {
        throw "$Context must be a local Skill path."
    }
    if (-not [IO.Path]::IsPathRooted($candidate)) { $candidate = Join-Path $SkillRoot $candidate }
    $fullPath = Assert-PathWithinRoot -Path $candidate -Root $SkillRoot -Context $Context
    foreach ($relativePath in $ExpectedInventoryPaths) {
        if (Test-PathEqual -Left $fullPath -Right (Join-Path $SkillRoot $relativePath)) { return $fullPath }
    }
    throw "$Context does not identify a file in the candidate-bound Skill inventory: $fullPath"
}

function Assert-SkillSpectorReport {
    param($Report, [string] $SkillRoot, [string] $SkillId, [string[]] $ExpectedInventoryPaths)
    $executionSuccessful = Get-RequiredProperty -Object $Report -Name 'execution_successful' -Context 'SkillSpector report'
    $completeness = Get-RequiredProperty -Object $Report -Name 'analysis_completeness' -Context 'SkillSpector report'
    $coverage = Get-RequiredProperty -Object $completeness -Name 'coverage_percent' -Context 'SkillSpector completeness'
    $numericTypes = @([byte], [sbyte], [int16], [uint16], [int], [uint32], [long], [uint64], [single], [double], [decimal])
    $coverageIsNumeric = $false
    foreach ($type in $numericTypes) { if ($coverage -is $type) { $coverageIsNumeric = $true; break } }
    if ($executionSuccessful -isnot [bool] -or -not $executionSuccessful -or
        (Get-RequiredProperty -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-RequiredProperty -Object $completeness -Name 'execution_successful' -Context 'SkillSpector completeness') -or
        (Get-RequiredProperty -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -isnot [bool] -or
        -not (Get-RequiredProperty -Object $completeness -Name 'is_complete' -Context 'SkillSpector completeness') -or
        (Get-RequiredProperty -Object $completeness -Name 'status' -Context 'SkillSpector completeness') -isnot [string] -or
        (Get-RequiredProperty -Object $completeness -Name 'status' -Context 'SkillSpector completeness') -cne 'complete' -or
        -not $coverageIsNumeric -or $coverage -ne 100) {
        throw "SkillSpector did not prove complete static analysis for '$SkillId'."
    }
    foreach ($name in @('ledger_exceptions', 'scope_exclusions', 'limitations')) {
        $items = Get-RequiredProperty -Object $completeness -Name $name -Context 'SkillSpector completeness'
        if ($items -isnot [array] -or @($items).Count -ne 0) {
            $detail = ConvertTo-Json -InputObject $items -Depth 12 -Compress
            throw "SkillSpector reported incomplete '$name' evidence for '$SkillId': $detail"
        }
    }
    $skill = Get-RequiredProperty -Object $Report -Name 'skill' -Context 'SkillSpector report'
    $reportedName = Get-RequiredProperty -Object $skill -Name 'name' -Context 'SkillSpector skill identity'
    $reportedSource = Get-RequiredProperty -Object $skill -Name 'source' -Context 'SkillSpector skill identity'
    if ($reportedName -isnot [string] -or $reportedName -cne $SkillId -or
        $reportedSource -isnot [string] -or -not (Test-PathEqual -Left $reportedSource -Right $SkillRoot)) {
        throw "SkillSpector report identity does not match '$SkillId'."
    }
    $components = Get-RequiredProperty -Object $Report -Name 'components' -Context 'SkillSpector report'
    if ($components -isnot [array] -or @($components).Count -ne $ExpectedInventoryPaths.Count) {
        throw "SkillSpector did not cover the exact candidate-bound inventory for '$SkillId'."
    }
    $observed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($component in @($components)) {
        $path = Get-RequiredProperty -Object $component -Name 'path' -Context 'SkillSpector component'
        if ($path -isnot [string] -or -not ($ExpectedInventoryPaths -ccontains $path) -or -not $observed.Add($path)) {
            throw "SkillSpector did not cover the exact candidate-bound inventory for '$SkillId'."
        }
    }
    $issues = Get-RequiredProperty -Object $Report -Name 'issues' -Context 'SkillSpector report'
    if ($issues -isnot [array]) { throw "SkillSpector issues must be an array for '$SkillId'." }
    return @($issues)
}

function Assert-SkillValidatorReport {
    param($Report, [string] $SkillRoot, [string[]] $ExpectedInventoryPaths, [string] $SkillId)
    $skillDirectory = Get-RequiredProperty -Object $Report -Name 'skill_dir' -Context 'skill-validator report'
    $passed = Get-RequiredProperty -Object $Report -Name 'passed' -Context 'skill-validator report'
    $errors = Get-RequiredProperty -Object $Report -Name 'errors' -Context 'skill-validator report'
    $warnings = Get-RequiredProperty -Object $Report -Name 'warnings' -Context 'skill-validator report'
    $results = Get-RequiredProperty -Object $Report -Name 'results' -Context 'skill-validator report'
    if ($skillDirectory -isnot [string] -or -not (Test-PathEqual -Left $skillDirectory -Right $SkillRoot) -or
        $passed -isnot [bool] -or -not $passed -or
        ($errors -isnot [int] -and $errors -isnot [long]) -or [int64]$errors -ne 0 -or
        ($warnings -isnot [int] -and $warnings -isnot [long]) -or [int64]$warnings -ne 0 -or
        $results -isnot [array] -or @($results).Count -le 0) {
        throw "skill-validator did not produce a clean candidate-bound report for '$SkillId'."
    }
    foreach ($result in @($results)) {
        $level = Get-RequiredProperty -Object $result -Name 'level' -Context 'skill-validator result'
        $category = Get-RequiredProperty -Object $result -Name 'category' -Context 'skill-validator result'
        $message = Get-RequiredProperty -Object $result -Name 'message' -Context 'skill-validator result'
        if ($level -isnot [string] -or $level -cnotin @('pass', 'info', 'warning', 'error') -or $level -in @('warning', 'error') -or
            $category -isnot [string] -or [string]::IsNullOrWhiteSpace($category) -or
            $message -isnot [string] -or [string]::IsNullOrWhiteSpace($message)) {
            throw "skill-validator returned a malformed or blocking result for '$SkillId'."
        }
        if ($null -ne $result.PSObject.Properties['file']) {
            [void](Resolve-ReportedFilePath -Value $result.file -SkillRoot $SkillRoot -ExpectedInventoryPaths $ExpectedInventoryPaths -Context 'skill-validator result file')
        }
        if ($null -ne $result.PSObject.Properties['line'] -and
            (($result.line -isnot [int] -and $result.line -isnot [long]) -or [int64]$result.line -le 0)) {
            throw "skill-validator returned an invalid line for '$SkillId'."
        }
    }
}

function Assert-SkillToolsReport {
    param($Report, [string] $SkillRoot, [string[]] $ExpectedInventoryPaths, [string] $SkillId)
    $version = Get-RequiredProperty -Object $Report -Name 'version' -Context 'skill-tools SARIF'
    $runs = Get-RequiredProperty -Object $Report -Name 'runs' -Context 'skill-tools SARIF'
    if ($version -isnot [string] -or $version -cne '2.1.0' -or $runs -isnot [array] -or @($runs).Count -ne 1) {
        throw "skill-tools did not produce SARIF 2.1.0 for '$SkillId'."
    }
    $run = $runs[0]
    $driver = Get-RequiredProperty -Object (Get-RequiredProperty -Object $run -Name 'tool' -Context 'skill-tools SARIF run') -Name 'driver' -Context 'skill-tools SARIF tool'
    $driverName = Get-RequiredProperty -Object $driver -Name 'name' -Context 'skill-tools SARIF driver'
    $rules = Get-RequiredProperty -Object $driver -Name 'rules' -Context 'skill-tools SARIF driver'
    $results = Get-RequiredProperty -Object $run -Name 'results' -Context 'skill-tools SARIF run'
    if ($driverName -isnot [string] -or $driverName -cne 'skill-tools' -or $rules -isnot [array] -or
        $results -isnot [array]) {
        throw "skill-tools SARIF is incomplete for '$SkillId'."
    }
    $ruleById = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($rule in @($rules)) {
        $ruleId = Get-RequiredProperty -Object $rule -Name 'id' -Context 'skill-tools SARIF rule'
        if ($ruleId -isnot [string] -or [string]::IsNullOrWhiteSpace($ruleId) -or $ruleById.ContainsKey($ruleId)) {
            throw "skill-tools SARIF rule metadata is malformed for '$SkillId'."
        }
        $ruleById.Add($ruleId, $rule)
    }
    foreach ($result in @($results)) {
        $ruleId = Get-RequiredProperty -Object $result -Name 'ruleId' -Context 'skill-tools SARIF result'
        if ($ruleId -isnot [string] -or -not $ruleById.ContainsKey($ruleId)) { throw "skill-tools SARIF references an unknown rule for '$SkillId'." }
        $effectiveLevel = if ($null -ne $result.PSObject.Properties['level']) { $result.level } else {
            $configuration = Get-RequiredProperty -Object $ruleById[$ruleId] -Name 'defaultConfiguration' -Context 'skill-tools SARIF rule'
            Get-RequiredProperty -Object $configuration -Name 'level' -Context 'skill-tools SARIF rule default'
        }
        if ($effectiveLevel -isnot [string] -or $effectiveLevel -cnotin @('none', 'note', 'warning', 'error') -or $effectiveLevel -ceq 'error') {
            throw "skill-tools SARIF contains a malformed or error-level result for '$SkillId'."
        }
        $message = Get-RequiredProperty -Object $result -Name 'message' -Context 'skill-tools SARIF result'
        $messageText = Get-RequiredProperty -Object $message -Name 'text' -Context 'skill-tools SARIF message'
        $locations = Get-RequiredProperty -Object $result -Name 'locations' -Context 'skill-tools SARIF result'
        if ($messageText -isnot [string] -or [string]::IsNullOrWhiteSpace($messageText) -or $locations -isnot [array] -or @($locations).Count -le 0) {
            throw "skill-tools SARIF lacks candidate-bound evidence for '$SkillId'."
        }
        foreach ($location in @($locations)) {
            $physical = Get-RequiredProperty -Object $location -Name 'physicalLocation' -Context 'skill-tools SARIF location'
            $artifact = Get-RequiredProperty -Object $physical -Name 'artifactLocation' -Context 'skill-tools SARIF physical location'
            $uri = Get-RequiredProperty -Object $artifact -Name 'uri' -Context 'skill-tools SARIF artifact location'
            [void](Resolve-ReportedFilePath -Value $uri -SkillRoot $SkillRoot -ExpectedInventoryPaths $ExpectedInventoryPaths -Context 'skill-tools SARIF artifact location')
        }
    }
}

function Assert-PathWithinRoot {
    param([string] $Path, [string] $Root, [string] $Context)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    ) + [IO.Path]::DirectorySeparatorChar
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $fullPath.StartsWith($fullRoot, $comparison)) { throw "$Context escapes its controlled root: $fullPath" }
    return $fullPath
}

function Get-InstalledDirectoryClosureSha256 {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $root = [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw "$Context install root is missing: $root" }
    Assert-NoReparseAncestors -Path $root -Context "$Context install root"
    $entries = @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)
    if ($entries.Count -eq 0) { throw "$Context install root is empty: $root" }
    foreach ($entry in $entries) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context installed closure contains a reparse-backed entry: $($entry.FullName)"
        }
    }
    $files = @($entries | Where-Object { -not $_.PSIsContainer })
    if ($files.Count -eq 0) { throw "$Context install root contains no regular files: $root" }
    $canonical = [Text.StringBuilder]::new()
    foreach ($file in $files) {
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Context installed closure contains a reparse-backed file: $($file.FullName)"
        }
        Assert-NoReparseAncestors -Path $file.FullName -Context "$Context installed closure file"
        $relative = $file.FullName.Substring($root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $relative = $relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative -match '(^|/)\.\.?(/|$)') {
            throw "$Context installed closure contains an unsafe relative path."
        }
        $sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash.ToLowerInvariant()
        [void]$canonical.Append($relative).Append("`t").Append($sha256).Append("`n")
    }
    $hasher = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical.ToString()))) -replace '-', '').ToLowerInvariant()
    }
    finally { $hasher.Dispose() }
}

function Assert-ReceiptInstalledClosure {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $rootValue = $Receipt.PSObject.Properties['installRoot']
    $hashValue = $Receipt.PSObject.Properties['installedClosureSha256']
    if ($null -eq $rootValue -or $rootValue.Value -isnot [string] -or
        $null -eq $hashValue -or $hashValue.Value -isnot [string]) {
        throw "$Context receipt does not provide installRoot/installedClosureSha256."
    }
    Assert-Sha256 -Value ([string]$hashValue.Value) -Context "$Context installed closure hash"
    $root = Assert-PathWithinRoot -Path ([string]$rootValue.Value) -Root $InstallRoot -Context "$Context install root"
    $actual = Get-InstalledDirectoryClosureSha256 -Path $root -Context $Context
    if ($actual -cne [string]$hashValue.Value) {
        throw "$Context installed closure changed after resolution."
    }
    return $root
}

function Assert-ReceiptFile {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $PathProperty,
        [Parameter(Mandatory = $true)][string] $HashProperty,
        [Parameter(Mandatory = $true)][string] $InstallRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $pathValue = $Receipt.PSObject.Properties[$PathProperty]
    $hashValue = $Receipt.PSObject.Properties[$HashProperty]
    if ($null -eq $pathValue -or $pathValue.Value -isnot [string] -or
        $null -eq $hashValue -or $hashValue.Value -isnot [string]) {
        throw "$Context receipt does not provide $PathProperty/$HashProperty."
    }
    Assert-Sha256 -Value ([string]$hashValue.Value) -Context "$Context receipt file hash"
    $path = Assert-PathWithinRoot -Path ([string]$pathValue.Value) -Root $InstallRoot -Context $Context
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Context installed file is missing: $path" }
    Assert-NoReparseAncestors -Path $path -Context "$Context installed file"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -cne [string]$hashValue.Value) { throw "$Context installed file changed after resolution." }
    return $path
}

function Assert-ExternalReceiptFile {
    param(
        [Parameter(Mandatory = $true)] $Receipt,
        [Parameter(Mandatory = $true)][string] $PathProperty,
        [Parameter(Mandatory = $true)][string] $HashProperty,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $pathValue = $Receipt.PSObject.Properties[$PathProperty]
    $hashValue = $Receipt.PSObject.Properties[$HashProperty]
    if ($null -eq $pathValue -or $pathValue.Value -isnot [string] -or
        $null -eq $hashValue -or $hashValue.Value -isnot [string]) {
        throw "$Context receipt does not provide $PathProperty/$HashProperty."
    }
    if (-not [IO.Path]::IsPathRooted([string]$pathValue.Value)) {
        throw "$Context receipt path must be absolute."
    }
    Assert-Sha256 -Value ([string]$hashValue.Value) -Context "$Context receipt file hash"
    $path = [IO.Path]::GetFullPath([string]$pathValue.Value)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "$Context runtime file is missing: $path" }
    Assert-NoReparseAncestors -Path $path -Context "$Context runtime file"
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToLowerInvariant()
    if ($actual -cne [string]$hashValue.Value) { throw "$Context runtime file changed after resolution." }
    return $path
}

function New-ContainedProcessEnvironment {
    param(
        [Parameter(Mandatory = $true)][string] $DiagnosticRoot
    )
    $allowedNames = @(
        'PATH', 'PATHEXT', 'SystemRoot', 'WINDIR', 'COMSPEC', 'PSHOME', 'PSModulePath',
        'HOME', 'USERPROFILE', 'HOMEDRIVE', 'HOMEPATH', 'TMP', 'TEMP', 'TMPDIR',
        'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME',
        'LANG', 'LANGUAGE', 'LC_ALL', 'LC_CTYPE', 'TZ', 'TERM', 'TERM_PROGRAM', 'COLORTERM',
        'CI', 'NO_COLOR', 'FORCE_COLOR', 'PWSH_DISTRIBUTION_CHANNEL', 'POWERSHELL_DISTRIBUTION_CHANNEL',
        'GITHUB_ACTIONS', 'GITHUB_ACTION', 'GITHUB_ACTION_PATH', 'GITHUB_ACTION_REPOSITORY',
        'GITHUB_ACTION_REF', 'GITHUB_ACTOR', 'GITHUB_BASE_REF', 'GITHUB_ENV', 'GITHUB_EVENT_NAME',
        'GITHUB_EVENT_PATH', 'GITHUB_GRAPHQL_URL', 'GITHUB_HEAD_REF', 'GITHUB_JOB', 'GITHUB_OUTPUT',
        'GITHUB_PATH', 'GITHUB_REF', 'GITHUB_REF_NAME', 'GITHUB_REF_PROTECTED', 'GITHUB_REF_TYPE',
        'GITHUB_REPOSITORY', 'GITHUB_REPOSITORY_ID', 'GITHUB_REPOSITORY_OWNER',
        'GITHUB_REPOSITORY_OWNER_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_RUN_ID', 'GITHUB_RUN_NUMBER',
        'GITHUB_SERVER_URL', 'GITHUB_SHA', 'GITHUB_STATE', 'GITHUB_STEP_SUMMARY', 'GITHUB_WORKFLOW',
        'GITHUB_WORKFLOW_REF', 'GITHUB_WORKFLOW_SHA', 'GITHUB_WORKSPACE', 'RUNNER_ARCH', 'RUNNER_DEBUG',
        'RUNNER_NAME', 'RUNNER_OS', 'RUNNER_TEMP', 'RUNNER_TOOL_CACHE', 'RUNNER_TRACKING_ID',
        'RUNNER_WORKSPACE', 'ImageOS', 'ImageVersion',
        'CODEX_VALIDATION_NATIVE_PAYLOAD', 'CODEX_VALIDATION_RESUME_EVENT', 'CODEX_VALIDATION_HAS_STANDARD_INPUT',
        'GIT_NO_REPLACE_OBJECTS'
    )
    $environment = [ordered]@{}
    foreach ($name in $allowedNames) {
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ($null -ne $value) {
            $environment[$name] = [string]$value
        }
    }
    # Candidate processes receive run-owned temporary/configuration locations,
    # never the runner's user profile or shared temp roots. Secrets and mutable
    # package-manager configuration are intentionally absent from the allowlist.
    $containmentRoot = Join-Path $DiagnosticRoot ("native-environment-{0}" -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $containmentRoot -Force)
    $containmentItem = Get-Item -LiteralPath $containmentRoot -Force
    if (-not $containmentItem.PSIsContainer -or ($containmentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Contained native-process environment root must be a regular non-reparse directory.'
    }
    Assert-NoReparseAncestors -Path $containmentRoot -Context 'Contained native-process environment root'
    $homePath = Join-Path $containmentRoot 'home'
    $tempPath = Join-Path $containmentRoot 'temp'
    $configPath = Join-Path $containmentRoot 'config'
    $cachePath = Join-Path $containmentRoot 'cache'
    $dataPath = Join-Path $containmentRoot 'data'
    foreach ($path in @($homePath, $tempPath, $configPath, $cachePath, $dataPath)) {
        [void](New-Item -ItemType Directory -Path $path -Force)
        $item = Get-Item -LiteralPath $path -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Contained native-process environment path is not a regular non-reparse directory: $path"
        }
        Assert-NoReparseAncestors -Path $path -Context 'Contained native-process environment path'
    }
    $environment['HOME'] = $homePath
    $environment['USERPROFILE'] = $homePath
    $environment['TMP'] = $tempPath
    $environment['TEMP'] = $tempPath
    $environment['TMPDIR'] = $tempPath
    $environment['XDG_CONFIG_HOME'] = $configPath
    $environment['XDG_CACHE_HOME'] = $cachePath
    $environment['XDG_DATA_HOME'] = $dataPath
    $environment['RUNNER_TEMP'] = $tempPath
    $environment['GIT_NO_REPLACE_OBJECTS'] = '1'
    $environment.Remove('GITHUB_TOKEN')
    $environment.Remove('GH_TOKEN')
    $environment.Remove('ACTIONS_RUNTIME_TOKEN')
    $environment.Remove('ACTIONS_ID_TOKEN_REQUEST_TOKEN')
    $environment.Remove('ACTIONS_ID_TOKEN_REQUEST_URL')
    return $environment
}

function Protect-ProcessCredentialEnvironment {
    param(
        [Parameter()][AllowEmptyCollection()][string[]] $SemanticCredentialNames
    )
    $credentialNamePattern = '(?i)(^|_)(API[_-]?KEY|TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE[_-]?KEY|ACCESS[_-]?KEY|CREDENTIALS?|AUTH)(_|$)'
    $exactCredentialNames = @(
        'GITHUB_TOKEN', 'GH_TOKEN', 'ACTIONS_RUNTIME_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN',
        'ACTIONS_ID_TOKEN_REQUEST_URL', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY',
        'AWS_SESSION_TOKEN', 'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_TENANT_ID',
        'GOOGLE_APPLICATION_CREDENTIALS', 'GOOGLE_API_KEY', 'KUBECONFIG', 'DOCKER_HOST',
        'DOCKER_CONFIG', 'CONTAINER_HOST'
    )
    $requestedNames = @($SemanticCredentialNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $requestedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $semanticEnvironment = [ordered]@{}
    foreach ($nameValue in $requestedNames) {
        $name = [string]$nameValue
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "Semantic credential environment variable name is invalid: '$name'."
        }
        if (-not $requestedSet.Add($name)) {
            throw "Semantic credential environment variable '$name' was specified more than once."
        }
        $value = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrWhiteSpace([string]$value)) {
            throw "Requested semantic credential environment variable '$name' is missing or empty."
        }
        $semanticEnvironment[$name] = [string]$value
    }
    $namesToRemove = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $exactCredentialNames) { [void]$namesToRemove.Add($name) }
    foreach ($name in @($requestedSet)) { [void]$namesToRemove.Add([string]$name) }
    foreach ($entry in @(Get-ChildItem Env: -ErrorAction SilentlyContinue)) {
        $name = [string]$entry.Name
        if ($name -match $credentialNamePattern) { [void]$namesToRemove.Add($name) }
    }
    foreach ($name in @($namesToRemove)) {
        [Environment]::SetEnvironmentVariable([string]$name, $null, [EnvironmentVariableTarget]::Process)
    }
    return $semanticEnvironment
}

function Get-RepositoryRawSnapshot {
    param(
        [Parameter(Mandatory = $true)][string] $RepositoryRoot
    )
    $root = [IO.Path]::GetFullPath($RepositoryRoot)
    $topLevel = @(Get-ChildItem -LiteralPath $root -Force)
    $items = foreach ($entry in $topLevel) {
        if ([string]$entry.Name -ceq '.git') {
            continue
        }
        $entry
        if ($entry.PSIsContainer) {
            Get-ChildItem -LiteralPath $entry.FullName -Recurse -Force
        }
    }
    $snapshot = foreach ($item in @($items)) {
        $relativePath = [IO.Path]::GetRelativePath($root, $item.FullName).Replace([IO.Path]::DirectorySeparatorChar, '/')
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Repository contains a reparse entry while taking the raw snapshot: $relativePath"
        }
        if (-not $item.PSIsContainer) {
            Assert-RegularFileForHash -Item $item -Context "Repository snapshot entry '$relativePath'"
        }
        [pscustomobject][ordered]@{
            path = $relativePath
            isContainer = [bool]$item.PSIsContainer
            length = if ($item.PSIsContainer) { [int64]-1 } else { [int64]$item.Length }
            rawSha256 = if ($item.PSIsContainer) { '' } else { (Get-FileHash -Algorithm SHA256 -LiteralPath $item.FullName).Hash.ToLowerInvariant() }
        }
    }
    @($snapshot | Sort-Object -Property path)
}

function Assert-RepositoryRawSnapshotUnchanged {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Before,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $After
    )
    if ($Before.Count -ne $After.Count) {
        throw 'Candidate repository filesystem changed during repository tests.'
    }
    for ($index = 0; $index -lt $Before.Count; $index++) {
        $beforeEntry = $Before[$index]
        $afterEntry = $After[$index]
        foreach ($propertyName in @('path', 'isContainer', 'length', 'rawSha256')) {
            if ([string]$beforeEntry.$propertyName -cne [string]$afterEntry.$propertyName) {
                throw "Candidate repository entry '$($beforeEntry.path)' changed during repository tests."
            }
        }
    }
}
function Assert-RegularFileForHash {
    param(
        [Parameter(Mandatory = $true)][IO.FileSystemInfo] $Item,
        [Parameter(Mandatory = $true)][string] $Context
    )
    if ($Item.PSIsContainer -or ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context is not a regular non-reparse file: $($Item.FullName)"
    }
    if ($script:IsLinuxHost) {
        if ($null -eq $script:TrustedStatPath) {
            $statCommand = Get-Command stat -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $script:TrustedStatPath = [IO.Path]::GetFullPath([string]$statCommand.Path)
            if (-not (Test-Path -LiteralPath $script:TrustedStatPath -PathType Leaf)) {
                throw "Trusted Linux stat utility is missing: $($script:TrustedStatPath)"
            }
            Assert-NoReparseAncestors -Path $script:TrustedStatPath -Context 'Trusted Linux stat utility'
        }
        $fileType = @(& $script:TrustedStatPath -c '%F' -- $Item.FullName 2>$null)
        $statExitCode = $LASTEXITCODE
        if ($statExitCode -ne 0 -or $fileType.Count -ne 1 -or [string]$fileType[0].Trim() -cne 'regular file') {
            throw "$Context is not a regular file according to the trusted filesystem type check: $($Item.FullName)"
        }
    }
}

function Assert-NoGitReplacementObjects {
    param(
        [Parameter(Mandatory = $true)][string] $GitPath,
        [Parameter(Mandatory = $true)][string] $RepositoryRoot,
        [Parameter(Mandatory = $true)][string] $Context
    )
    $replacePathOutput = @(& $GitPath -C $RepositoryRoot rev-parse --git-path refs/replace 2>$null)
    $replacePathExitCode = $LASTEXITCODE
    if ($replacePathExitCode -ne 0 -or $replacePathOutput.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$replacePathOutput[0])) {
        throw "$Context could not resolve the candidate Git replacement-object directory."
    }
    $replacePath = [string]$replacePathOutput[0].Trim()
    if (-not [IO.Path]::IsPathRooted($replacePath)) {
        $replacePath = Join-Path $RepositoryRoot $replacePath
    }
    $replacePath = [IO.Path]::GetFullPath($replacePath)
    if (-not (Test-Path -LiteralPath $replacePath)) { return }
    $replaceItem = Get-Item -LiteralPath $replacePath -Force
    if (-not $replaceItem.PSIsContainer -or ($replaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Context Git replacement-object path is not a regular non-reparse directory."
    }
    Assert-NoReparseAncestors -Path $replacePath -Context "$Context Git replacement-object directory"
    $replacementEntries = @(Get-ChildItem -LiteralPath $replacePath -Force -ErrorAction Stop)
    if ($replacementEntries.Count -ne 0) {
        throw "$Context found Git replacement objects; replacement refs are not permitted."
    }
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Context,
        [Parameter(Mandatory = $true)][string] $DiagnosticRoot,
        [Parameter()][AllowNull()][string] $StandardInput,
        [Parameter()][AllowNull()][Collections.IDictionary] $AdditionalEnvironmentVariables,
        [Parameter()][switch] $IsolateRunnerCommandFiles,
        [Parameter()][switch] $TerminateProcessTree,
        [Parameter()][switch] $ProtectRunnerCommandFiles,
        [Parameter()][switch] $ApplyLinuxResourceLimits,
        [Parameter()][ValidateRange(1000, 3600000)][int] $TimeoutMilliseconds = 300000
    )
    if (-not (Test-Path -LiteralPath $Command -PathType Leaf)) { throw "$Context executable is missing: $Command" }
    if ($ProtectRunnerCommandFiles -and -not $IsolateRunnerCommandFiles) {
        throw "$Context cannot protect runner command files without isolation."
    }
    if ($null -ne $AdditionalEnvironmentVariables -and -not $TerminateProcessTree) {
        throw "$Context cannot add environment variables without process containment."
    }
    $stderrPath = Join-Path $DiagnosticRoot ("stderr-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $runnerCommandFileNames = @(
        'GITHUB_ENV',
        'GITHUB_PATH',
        'GITHUB_OUTPUT',
        'GITHUB_STATE',
        'GITHUB_STEP_SUMMARY'
    )
    $previousRunnerCommandFileValues = [ordered]@{}
    $runnerCommandFileSnapshot = $null
    $runnerCommandFileIsolationStarted = $false
    $childProcess = $null
    $childProcessId = 0
    $childProcessGroupId = 0
    $childProcessIdentity = ''
    $observedProcessIdentities = [Collections.Generic.Dictionary[int,string]]::new()
    $baselineSupervisorProcessIdentities = [Collections.Generic.Dictionary[int,string]]::new()
    $processTreeStopped = $false
    $windowsJobHandle = [IntPtr]::Zero
    $windowsResumeEvent = $null
    $windowsResumeEventSignaled = $false
    $stdoutTask = $null
    $stderrTask = $null
    $maxProcessOutputCharacters = 4 * 1024 * 1024
    $windowsResumeEventReleaseEligible = $false
    try {
        if ($ProtectRunnerCommandFiles) {
            $runnerCommandFileSnapshot = Get-RunnerCommandFileSnapshot -Names $runnerCommandFileNames
        }
        if ($IsolateRunnerCommandFiles) {
            $runnerCommandFileIsolationStarted = $true
            foreach ($name in $runnerCommandFileNames) {
                $previousRunnerCommandFileValues[$name] = [Environment]::GetEnvironmentVariable(
                    $name,
                    [EnvironmentVariableTarget]::Process
                )
                $isolatedPath = Join-Path $DiagnosticRoot ("isolated-{0}-{1}.txt" -f $name.ToLowerInvariant(), [guid]::NewGuid().ToString('N'))
                $isolatedStream = [IO.File]::Open(
                    $isolatedPath,
                    [IO.FileMode]::CreateNew,
                    [IO.FileAccess]::Write,
                    [IO.FileShare]::Read
                )
                try {
                    $isolatedStream.Flush($true)
                }
                finally {
                    $isolatedStream.Dispose()
                }
                Assert-NoReparseAncestors -Path $isolatedPath -Context "Isolated $name command file"
                [Environment]::SetEnvironmentVariable($name, $isolatedPath, [EnvironmentVariableTarget]::Process)
            }
        }
        if ($TerminateProcessTree) {
            if (-not $script:IsSupportedProcessBoundaryHost) {
                throw "$Context process isolation requires a supported Windows or Linux host."
            }
            if ($script:IsLinuxHost) {
                Enable-UnixChildSubreaper
            }
            foreach ($supervisorProcessId in @(Get-DescendantProcessIds -RootProcessId $PID)) {
                Add-ProcessIdentityToObservation -ProcessId ([int]$supervisorProcessId) -ObservedProcessIdentities $baselineSupervisorProcessIdentities
            }
            if ($script:IsWindowsHost) {
                # Create containment before Process.Start, then assign the child
                # immediately after it returns so descendants stay in the boundary.
                $windowsJobHandle = New-WindowsKillOnCloseJob -Context $Context
            }
            $nativeCommand = $Command
            $nativeArguments = @($Arguments)
            if ($script:IsLinuxHost) {
                $setsidCommand = Get-Command setsid -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $setsidPath = [IO.Path]::GetFullPath([string]$setsidCommand.Path)
                if (-not (Test-Path -LiteralPath $setsidPath -PathType Leaf)) {
                    throw "$Context process-group launcher is missing: $setsidPath"
                }
                Assert-NoReparseAncestors -Path $setsidPath -Context "$Context process-group launcher"
                $unshareCommand = Get-Command unshare -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $unsharePath = [IO.Path]::GetFullPath([string]$unshareCommand.Path)
                if (-not (Test-Path -LiteralPath $unsharePath -PathType Leaf)) {
                    throw "$Context non-escapable Linux process namespace launcher is missing: $unsharePath"
                }
                Assert-NoReparseAncestors -Path $unsharePath -Context "$Context process namespace launcher"
                $shellCommand = Get-Command sh -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $shellPath = [IO.Path]::GetFullPath([string]$shellCommand.Path)
                if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
                    throw "$Context trusted Linux shell is missing: $shellPath"
                }
                Assert-NoReparseAncestors -Path $shellPath -Context "$Context trusted Linux shell"
                $mountCommand = Get-Command mount -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $mountPath = [IO.Path]::GetFullPath([string]$mountCommand.Path)
                if (-not (Test-Path -LiteralPath $mountPath -PathType Leaf)) {
                    throw "$Context trusted Linux mount utility is missing: $mountPath"
                }
                Assert-NoReparseAncestors -Path $mountPath -Context "$Context trusted Linux mount utility"
                $findCommand = Get-Command find -CommandType Application -ErrorAction Stop | Select-Object -First 1
                $findPath = [IO.Path]::GetFullPath([string]$findCommand.Path)
                if (-not (Test-Path -LiteralPath $findPath -PathType Leaf)) {
                    throw "$Context trusted Linux find utility is missing: $findPath"
                }
                Assert-NoReparseAncestors -Path $findPath -Context "$Context trusted Linux find utility"
                $prlimitPath = $null
                if ($ApplyLinuxResourceLimits) {
                    $prlimitCommand = Get-Command prlimit -CommandType Application -ErrorAction Stop | Select-Object -First 1
                    $prlimitPath = [IO.Path]::GetFullPath([string]$prlimitCommand.Path)
                    if (-not (Test-Path -LiteralPath $prlimitPath -PathType Leaf)) {
                        throw "$Context trusted Linux prlimit utility is missing: $prlimitPath"
                    }
                    Assert-NoReparseAncestors -Path $prlimitPath -Context "$Context trusted Linux prlimit utility"
                }
                $nativeCommand = if ($ApplyLinuxResourceLimits) { $prlimitPath } else { $setsidPath }
                $maskHostSocketsScript = @'
set -eu
mount_path="$1"
find_path="$2"
run_root="$3"
shift 3
"$mount_path" --make-rprivate /
for socket_root in /run /var/run /dev /dev/shm /tmp /var/tmp
do
    if [ -d "$socket_root" ]; then
        "$find_path" "$socket_root" -xdev -type s -readable -exec "$mount_path" --bind /dev/null '{}' \; 2>/dev/null || true
    fi
done
for private_root in /run /tmp /var/tmp /dev/shm
do
    case "$private_root:$run_root" in
        /tmp:/tmp|/tmp:/tmp/*) continue ;;
    esac
    if [ -d "$private_root" ]; then
        "$mount_path" -t tmpfs -o nodev,nosuid,noexec,mode=1777 tmpfs "$private_root"
    fi
done
# The process namespace gives the candidate a per-UID aggregate process cap in
# addition to the per-process prlimit applied by the trusted parent.  This is
# intentionally established before the candidate command is released.
ulimit -u 256
exec "$@"
'@
                $namespaceArguments = @(
                    $unsharePath,
                    '--user', '--map-root-user', '--mount', '--pid', '--fork', '--mount-proc', '--kill-child', '--',
                    $shellPath, '-c', $maskHostSocketsScript, '--', $mountPath, $findPath, $DiagnosticRoot, $Command
                ) + @($Arguments)
                $nativeArguments = if ($ApplyLinuxResourceLimits) {
                    @('--as=2147483648', '--cpu=300', '--nproc=256', '--nofile=1024', '--fsize=67108864', '--core=0', '--') + @($setsidPath) + @($namespaceArguments)
                }
                else {
                    @($namespaceArguments)
                }
            }
            elseif ($script:IsWindowsHost) {
                # Start a trusted gate that waits on a supervisor-owned event.
                # The candidate command is released only after Job Object assignment.
                $payloadJson = [ordered]@{
                    command = $Command
                    arguments = @($Arguments)
                } | ConvertTo-Json -Compress -Depth 20
                $payloadEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($payloadJson))
                $createdNewEvent = $false
                $eventName = "Local\CodexValidationResume-{0}" -f [guid]::NewGuid().ToString('N')
                $windowsResumeEvent = [Threading.EventWaitHandle]::new(
                    $false,
                    [Threading.EventResetMode]::ManualReset,
                    $eventName,
                    [ref]$createdNewEvent
                )
                if (-not $createdNewEvent -or $null -eq $windowsResumeEvent) {
                    throw "$Context could not create a private Windows resume event."
                }
                $wrapperScript = @'
$payloadEncoded = [Environment]::GetEnvironmentVariable('CODEX_VALIDATION_NATIVE_PAYLOAD')
$eventName = [Environment]::GetEnvironmentVariable('CODEX_VALIDATION_RESUME_EVENT')
$hasStandardInput = [Environment]::GetEnvironmentVariable('CODEX_VALIDATION_HAS_STANDARD_INPUT')
if ([string]::IsNullOrWhiteSpace($payloadEncoded) -or [string]::IsNullOrWhiteSpace($eventName)) {
    exit 1
}
$payloadJson = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($payloadEncoded))
$payload = $payloadJson | ConvertFrom-Json -Depth 20
$payloadArguments = @($payload.arguments | ForEach-Object { [string]$_ })
$resumeEvent = [Threading.EventWaitHandle]::OpenExisting($eventName)
try {
    $standardInput = $null
    if ($hasStandardInput -eq '1') {
        $standardInput = [Console]::In.ReadToEnd()
    }
    if (-not $resumeEvent.WaitOne()) {
        exit 1
    }
    if ($hasStandardInput -eq '1') {
        $standardInput | & ([string]$payload.command) @payloadArguments
    }
    else {
        & ([string]$payload.command) @payloadArguments
    }
    exit $LASTEXITCODE
}
finally {
    $resumeEvent.Dispose()
}
'@
                $wrapperEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapperScript))
                $nativeCommand = Join-Path $PSHOME 'pwsh.exe'
                if (-not (Test-Path -LiteralPath $nativeCommand -PathType Leaf)) {
                    throw "$Context trusted PowerShell gate is missing: $nativeCommand"
                }
                Assert-NoReparseAncestors -Path $nativeCommand -Context "$Context trusted PowerShell gate"
                $nativeArguments = @(
                    '-NoLogo',
                    '-NoProfile',
                    '-NonInteractive',
                    '-EncodedCommand',
                    $wrapperEncoded
                )
            }
            $parentProcessGroupId = if ($script:IsLinuxHost) { Get-UnixProcessGroupId -ProcessId $PID } else { 0 }
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $nativeCommand
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            if ($PSBoundParameters.ContainsKey('StandardInput')) {
                $startInfo.RedirectStandardInput = $true
            }
            $nativeEnvironmentVariables = if ($TerminateProcessTree) {
                New-ContainedProcessEnvironment -DiagnosticRoot $DiagnosticRoot
            }
            else {
                $null
            }
            if ($null -ne $nativeEnvironmentVariables) {
                $startInfo.EnvironmentVariables.Clear()
                foreach ($environmentName in @($nativeEnvironmentVariables.Keys)) {
                    $startInfo.EnvironmentVariables[[string]$environmentName] = [string]$nativeEnvironmentVariables[$environmentName]
                }
            }
            $argumentListProperty = $startInfo.PSObject.Properties['ArgumentList']
            if ($null -ne $argumentListProperty) {
                foreach ($argument in $nativeArguments) {
                    [void]$startInfo.ArgumentList.Add([string]$argument)
                }
            }
            else {
                $startInfo.Arguments = ConvertTo-NativeProcessArgumentString -Arguments $nativeArguments
            }
            $startInfo.WorkingDirectory = [string](Get-Location).Path
            if ($script:IsWindowsHost) {
                $startInfo.EnvironmentVariables['CODEX_VALIDATION_NATIVE_PAYLOAD'] = $payloadEncoded
                $startInfo.EnvironmentVariables['CODEX_VALIDATION_RESUME_EVENT'] = $eventName
                $startInfo.EnvironmentVariables['CODEX_VALIDATION_HAS_STANDARD_INPUT'] = if ($PSBoundParameters.ContainsKey('StandardInput')) { '1' } else { '0' }
            }
            $nativeEnvironmentVariables = @{}
            foreach ($environmentName in @($startInfo.EnvironmentVariables.Keys)) {
                $nativeEnvironmentVariables[[string]$environmentName] = [string]$startInfo.EnvironmentVariables[$environmentName]
            }
            if ($null -ne $AdditionalEnvironmentVariables) {
                foreach ($environmentName in @($AdditionalEnvironmentVariables.Keys)) {
                    $name = [string]$environmentName
                    $value = [string]$AdditionalEnvironmentVariables[$environmentName]
                    if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$' -or $value.IndexOf([char]0) -ge 0) {
                        throw "$Context received an invalid additional environment variable name or value."
                    }
                    $nativeEnvironmentVariables[$name] = $value
                    $startInfo.EnvironmentVariables[$name] = $value
                }
            }
            if ($script:IsWindowsHost) {
                $childProcess = Start-WindowsSuspendedProcess -FileName $nativeCommand -Arguments $nativeArguments -WorkingDirectory $startInfo.WorkingDirectory -EnvironmentVariables $nativeEnvironmentVariables -UseStandardInput ($PSBoundParameters.ContainsKey('StandardInput'))
            }
            else {
                $childProcess = [Diagnostics.Process]::new()
                $childProcess.StartInfo = $startInfo
                if (-not $childProcess.Start()) { throw "$Context process could not be started: $Command" }
            }
            $childProcessId = $childProcess.Id
            if ($script:IsWindowsHost) {
                Assign-WindowsProcessToJob -JobHandle $windowsJobHandle -Process $childProcess -Context $Context
            }
            if (Test-ProcessIdExists -ProcessId $childProcessId) {
                try {
                    $childProcessIdentity = Get-ProcessIdentity -ProcessId $childProcessId
                }
                catch {
                    if (Test-ProcessIdExists -ProcessId $childProcessId) { throw }
                }
            }
            if ((Test-ProcessIdExists -ProcessId $childProcessId) -and [string]::IsNullOrWhiteSpace($childProcessIdentity)) {
                throw "$Context could not bind the child process identity before execution."
            }
            if ($script:IsWindowsHost) {
                $windowsResumeEventReleaseEligible = $true
            }
            if ($script:IsLinuxHost) {
                $childProcessGroupId = Wait-ForUnixProcessGroupId -ProcessId $childProcessId -ParentProcessGroupId $parentProcessGroupId
                if ($childProcessGroupId -le 0 -and -not $childProcess.HasExited) {
                    throw "$Context process was not placed in a dedicated Linux process group."
                }
            }
            $outputBoundaryType = Get-WindowsSuspendedProcessBoundaryType
            $stdoutTask = $outputBoundaryType::ReadBoundedAsync($childProcess.StandardOutput, $maxProcessOutputCharacters)
            $stderrTask = $outputBoundaryType::ReadBoundedAsync($childProcess.StandardError, $maxProcessOutputCharacters)
            if ($script:IsWindowsHost) {
                if (-not $childProcess.Resume()) {
                    throw "$Context could not resume the suspended Windows process after Job Object assignment."
                }
            }
            if ($PSBoundParameters.ContainsKey('StandardInput')) {
                $childProcess.StandardInput.Write($StandardInput)
                $childProcess.StandardInput.Close()
            }
            if ($script:IsWindowsHost) {
                if (-not $windowsResumeEvent.Set()) {
                    throw "$Context could not release the Windows candidate gate."
                }
                $windowsResumeEventSignaled = $true
            }
            $processDeadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
            Add-ObservedProcessIds -RootProcessId $childProcessId -ObservedProcessIdentities $observedProcessIdentities -ProcessGroupId $childProcessGroupId -SupervisorProcessId $PID -BaselineSupervisorProcessIdentities $baselineSupervisorProcessIdentities
            while (-not $childProcess.HasExited) {
                if ([DateTime]::UtcNow -ge $processDeadline) {
                    throw "$Context exceeded the bounded candidate execution timeout of $TimeoutMilliseconds milliseconds."
                }
                [void]$childProcess.WaitForExit(100)
                Add-ObservedProcessIds -RootProcessId $childProcessId -ObservedProcessIdentities $observedProcessIdentities -ProcessGroupId $childProcessGroupId -SupervisorProcessId $PID -BaselineSupervisorProcessIdentities $baselineSupervisorProcessIdentities
            }
            Add-ObservedProcessIds -RootProcessId $childProcessId -ObservedProcessIdentities $observedProcessIdentities -ProcessGroupId $childProcessGroupId -SupervisorProcessId $PID -BaselineSupervisorProcessIdentities $baselineSupervisorProcessIdentities
            Stop-ProcessTree -RootProcessId $childProcessId -ProcessGroupId $childProcessGroupId -RootProcessIdentity $childProcessIdentity -ObservedProcessIdentities $observedProcessIdentities -WindowsJobHandle $windowsJobHandle
            $processTreeStopped = $true
            if (-not $childProcess.WaitForExit(5000)) {
                throw "$Context process did not terminate after process-boundary cleanup."
            }
            if (-not $stdoutTask.Wait(5000) -or -not $stderrTask.Wait(5000)) {
                throw "$Context left redirected output handles open after process-tree cleanup."
            }
            $stdoutResult = $stdoutTask.GetAwaiter().GetResult()
            $stderrResult = $stderrTask.GetAwaiter().GetResult()
            if ($stdoutResult.Truncated -or $stderrResult.Truncated) {
                throw "$Context exceeded the bounded native-process output limit of $maxProcessOutputCharacters characters per stream."
            }
            $stdoutText = [string]$stdoutResult.Text
            $stderrText = [string]$stderrResult.Text
            $exitCode = $childProcess.ExitCode
        }
        else {
            $stdout = if ($PSBoundParameters.ContainsKey('StandardInput')) {
                $StandardInput | & $Command @Arguments 2> $stderrPath
            }
            else {
                @(& $Command @Arguments 2> $stderrPath)
            }
            $exitCode = $LASTEXITCODE
            $stdoutText = ($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
            $stderrText = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
        }
        if ($ProtectRunnerCommandFiles) {
            Assert-RunnerCommandFilesUnchanged -Before $runnerCommandFileSnapshot -Names $runnerCommandFileNames
        }
        if ($exitCode -ne 0) {
            throw "$Context exited with code $exitCode.`nSTDOUT:`n$stdoutText`nSTDERR:`n$stderrText"
        }
        return $stdoutText
    }
    finally {
        try {
            if ($script:IsWindowsHost -and $null -ne $childProcess -and $childProcessId -gt 0 -and -not $windowsResumeEventReleaseEligible) {
                $terminated = $childProcess.Terminate()
                if (-not $terminated -and -not $childProcess.HasExited) {
                    throw "$Context could not terminate the unassigned suspended Windows process safely."
                }
            }
            if ($TerminateProcessTree -and $null -ne $childProcess -and $childProcessId -gt 0 -and -not $processTreeStopped) {
                Stop-ProcessTree -RootProcessId $childProcessId -ProcessGroupId $childProcessGroupId -RootProcessIdentity $childProcessIdentity -ObservedProcessIdentities $observedProcessIdentities -WindowsJobHandle $windowsJobHandle
                $processTreeStopped = $true
            }
        }
        finally {
            if ($null -ne $windowsResumeEvent) {
                $windowsResumeEvent.Dispose()
                $windowsResumeEvent = $null
            }
            if ($windowsJobHandle -ne [IntPtr]::Zero) {
                Close-WindowsProcessJob -JobHandle $windowsJobHandle
                $windowsJobHandle = [IntPtr]::Zero
            }
            if ($runnerCommandFileIsolationStarted) {
                foreach ($name in $runnerCommandFileNames) {
                    if ($previousRunnerCommandFileValues.Contains($name)) {
                        [Environment]::SetEnvironmentVariable(
                            $name,
                            $previousRunnerCommandFileValues[$name],
                            [EnvironmentVariableTarget]::Process
                        )
                    }
                }
            }
            if ($null -ne $childProcess) { $childProcess.Dispose() }
            if (Test-Path -LiteralPath $stderrPath) { Remove-Item -LiteralPath $stderrPath -Force -ErrorAction SilentlyContinue }
        }
    }
}

function Test-SecurityRelevantSkillChange {
    param([string] $GitPath, [string] $RepositoryRoot, [string] $BaseCommit)
    if ([string]::IsNullOrWhiteSpace($BaseCommit)) {
        # Without an immutable comparison base, fail closed instead of skipping
        # the supplemental semantic-scan trigger decision.
        return $true
    }
    $gitOutput = [string]((& $GitPath -c "safe.directory=$RepositoryRoot" -c "core.worktree=$RepositoryRoot" -C $RepositoryRoot diff --find-renames=100% --name-status -z "$BaseCommit...HEAD") -join '')
    if ($LASTEXITCODE -ne 0) { throw "Could not compare candidate with base commit '$BaseCommit'." }
    $tokens = @($gitOutput.Split([char]0) | Where-Object { $_ -ne '' })
    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $status = [string]$tokens[$index]
        if ($status -cmatch '^R[0-9]{3}$' -or $status -cmatch '^C[0-9]{3}$') {
            if ($index + 2 -ge $tokens.Count) { throw 'Git returned an incomplete rename/copy status record.' }
            $oldPath = [string]$tokens[$index + 1]
            $newPath = [string]$tokens[$index + 2]
            if ($status -ceq 'R100' -and $oldPath -clike '.agents/skills/*' -and $newPath -clike 'skills/*') {
                $index += 2
                continue
            }
            if ($oldPath -clike 'skills/*' -or $newPath -clike 'skills/*') { return $true }
            $index += 2
            continue
        }
        if ($index + 1 -ge $tokens.Count) { throw 'Git returned an incomplete path status record.' }
        if ([string]$tokens[$index + 1] -clike 'skills/*') { return $true }
        $index++
    }
    return $false
}

$repoRoot = if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
}
else { [IO.Path]::GetFullPath($RepositoryRoot) }
$supervisorRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$repositoryValidatorPath = Join-Path $supervisorRoot 'scripts/Test-Repository.ps1'
if (-not (Test-Path -LiteralPath $repositoryValidatorPath -PathType Leaf)) {
    throw "Trusted repository validator is missing: $repositoryValidatorPath"
}
Assert-NoReparseAncestors -Path $repositoryValidatorPath -Context 'Trusted repository validator'
$repositoryValidatorBytes = [IO.File]::ReadAllBytes($repositoryValidatorPath)
$repositoryValidatorHasher = [Security.Cryptography.SHA256]::Create()
try {
    $repositoryValidatorHash = [BitConverter]::ToString(
        $repositoryValidatorHasher.ComputeHash($repositoryValidatorBytes)
    ).Replace('-', '').ToLowerInvariant()
}
finally {
    $repositoryValidatorHasher.Dispose()
}
$gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
$gitPath = [IO.Path]::GetFullPath([string]$gitCommand.Path)
Assert-NoGitReplacementObjects -GitPath $gitPath -RepositoryRoot $repoRoot -Context 'Pre-test candidate'
$gitConfigArguments = @('-c', "safe.directory=$repoRoot", '-c', "core.worktree=$repoRoot")

$candidateCommit = ([string](@(& $gitPath @gitConfigArguments -C $repoRoot rev-parse HEAD 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $candidateCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Candidate must be an immutable Git commit.' }
$candidateTree = ([string](@(& $gitPath @gitConfigArguments -C $repoRoot rev-parse "$candidateCommit^{tree}" 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $candidateTree -cnotmatch '^[0-9a-f]{40}$') { throw 'Candidate must be bound to one immutable Git tree.' }
$dirty = @(& $gitPath @gitConfigArguments -C $repoRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Canonical validation requires a clean candidate commit; commit or remove every tracked/untracked change first.'
}
$gitIndexOutput = @(& $gitPath @gitConfigArguments -C $repoRoot rev-parse --git-path index 2>$null)
if ($LASTEXITCODE -ne 0 -or $gitIndexOutput.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$gitIndexOutput[0])) {
    throw 'Could not resolve the candidate Git index path before repository tests.'
}
$gitIndexPath = [string]$gitIndexOutput[0]
if (-not [IO.Path]::IsPathRooted($gitIndexPath)) {
    $gitIndexPath = Join-Path $repoRoot $gitIndexPath
}
$gitIndexPath = [IO.Path]::GetFullPath($gitIndexPath)
if (-not (Test-Path -LiteralPath $gitIndexPath -PathType Leaf)) {
    throw "Candidate Git index is missing before repository tests: $gitIndexPath"
}
Assert-NoReparseAncestors -Path $gitIndexPath -Context 'Candidate Git index'
$prePesterGitIndexSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $gitIndexPath).Hash.ToLowerInvariant()
$prePesterRepositoryRawSnapshot = @(Get-RepositoryRawSnapshot -RepositoryRoot $repoRoot)
$resolvedBaseCommit = ''
if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
    $baseRevision = "$BaseCommit^{commit}"
    $baseOutput = @(& $gitPath @gitConfigArguments -C $repoRoot rev-parse --verify --end-of-options $baseRevision 2>$null)
    if ($LASTEXITCODE -ne 0 -or $baseOutput.Count -ne 1 -or [string]$baseOutput[0] -cnotmatch '^[0-9a-f]{40}$') {
        throw "Base commit '$BaseCommit' does not resolve to one immutable commit."
    }
    $resolvedBaseCommit = ([string]$baseOutput[0]).Trim()
    & $gitPath @gitConfigArguments -C $repoRoot merge-base --is-ancestor $resolvedBaseCommit $candidateCommit
    if ($LASTEXITCODE -ne 0 -or $resolvedBaseCommit -ceq $candidateCommit) {
        throw 'Base commit must be a distinct ancestor of the immutable candidate.'
    }
    $BaseCommit = $resolvedBaseCommit
}

$adapterPath = Join-Path $repoRoot 'config/standard-v1.json'
$adapter = Read-JsonFile -Path $adapterPath -Context 'Standard v1 repository adapter'
$approvedAuthorityRepository = 'https://github.com/SyuanTsai/SyuanTsai-AI-Instructions.git'
$approvedAuthorityCommit = '5ff96a358a51788a3764b27c31def842d5aee55d'
$approvedAuthorityArchiveSha256 = '36aa50ec00697dd5b06c83aef9a591f0f4f4a553a8ecc5b165308de908161d80'
if ($adapter.schemaVersion -ne 1 -or $adapter.standardVersion -cne 'v1' -or $adapter.deviations -cne 'None') {
    throw 'Standard v1 repository adapter identity or deviation contract is invalid.'
}
if ($adapter.authority.repository -cne $approvedAuthorityRepository -or
    $adapter.authority.commit -cne $approvedAuthorityCommit -or
    $adapter.authority.archiveUrl -cne "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$approvedAuthorityCommit" -or
    $adapter.authority.archiveSha256 -cne $approvedAuthorityArchiveSha256) {
    throw 'Standard authority binding does not match the base-owned approved snapshot.'
}
$expectedArchiveUrl = "https://codeload.github.com/SyuanTsai/SyuanTsai-AI-Instructions/zip/$approvedAuthorityCommit"
if ($adapter.authority.archiveUrl -cne $expectedArchiveUrl) { throw 'Standard authority archive URL is not the exact approved immutable codeload path.' }
Assert-Sha256 -Value $adapter.authority.archiveSha256 -Context 'Authority archive identity'

$artifactsRootPath = [IO.Path]::GetFullPath($ArtifactsRoot)
if (Test-PathWithinOrEqual -Path $artifactsRootPath -Root $repoRoot) {
    throw 'Artifacts root must be outside the candidate repository.'
}
[void](New-Item -ItemType Directory -Path $artifactsRootPath -Force)
$artifactsItem = Get-Item -LiteralPath $artifactsRootPath -Force
if (-not $artifactsItem.PSIsContainer -or ($artifactsItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Artifacts root must be a regular non-reparse directory.'
}
Assert-NoReparseAncestors -Path $artifactsRootPath -Context 'Artifacts root'
$runId = [guid]::NewGuid().ToString('N')
# Keep the on-disk prefix short enough for Windows venv and wheel paths; evidence retains the full run ID.
$runRoot = Join-Path $artifactsRootPath "sgv1-$($runId.Substring(0, 12))"
$authorityExtractRoot = Join-Path $runRoot 'authority'
$installRoot = Join-Path $runRoot 'tools'
if (Test-Path -LiteralPath $runRoot) { throw 'Run-owned artifacts path unexpectedly already exists.' }
[void](New-Item -ItemType Directory -Path $runRoot)
Assert-NoReparseAncestors -Path $runRoot -Context 'Run-owned artifacts path'
$semanticCredentialEnvironment = Protect-ProcessCredentialEnvironment -SemanticCredentialNames $SemanticCredentialNames
[void](New-Item -ItemType Directory -Path $authorityExtractRoot -Force)
[void](New-Item -ItemType Directory -Path $installRoot -Force)
$trustedGitConfigPath = Join-Path $runRoot 'empty-git-config'
$trustedGitHooksPath = Join-Path $runRoot 'empty-git-hooks'
[IO.File]::WriteAllText($trustedGitConfigPath, '', [Text.UTF8Encoding]::new($false))
[void](New-Item -ItemType Directory -Path $trustedGitHooksPath -Force)
$trustedGitConfigSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $trustedGitConfigPath).Hash.ToLowerInvariant()
Assert-NoReparseAncestors -Path $trustedGitConfigPath -Context 'Run-owned Git global config'
Assert-NoReparseAncestors -Path $trustedGitHooksPath -Context 'Run-owned empty Git hooks directory'

# Bind the exact package/file inventory before any scanner is acquired or executed.
$integrityReportPath = Join-Path $runRoot 'candidate-integrity.json'
$integrityJson = & $repositoryValidatorPath -RepositoryRoot $repoRoot -OutputPath $integrityReportPath | Select-Object -Last 1
$integrityReport = $integrityJson | ConvertFrom-Json -Depth 100
if ($integrityReport.result -cne 'passed' -or [int]$integrityReport.activeSkillCount -le 0) {
    throw 'Candidate integrity verification did not bind a non-empty active Skill inventory.'
}
$skillIds = @($integrityReport.skills | ForEach-Object { [string]$_.skillId })
$skillsRoot = Join-Path $repoRoot 'skills'

$archivePath = Join-Path $runRoot 'authority.zip'
if ([string]::IsNullOrWhiteSpace($AuthorityArchivePath)) {
    Invoke-WebRequest -Uri $adapter.authority.archiveUrl -OutFile $archivePath
}
else {
    $suppliedArchive = [IO.Path]::GetFullPath($AuthorityArchivePath)
    if (-not (Test-Path -LiteralPath $suppliedArchive -PathType Leaf)) { throw 'Supplied authority archive does not exist.' }
    Copy-Item -LiteralPath $suppliedArchive -Destination $archivePath
}
$archiveHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $archivePath).Hash.ToLowerInvariant()
if ($archiveHash -cne [string]$adapter.authority.archiveSha256) { throw 'Authority archive SHA-256 does not match the approved immutable snapshot.' }
Expand-Archive -LiteralPath $archivePath -DestinationPath $authorityExtractRoot
$authorityRoots = @(Get-ChildItem -LiteralPath $authorityExtractRoot -Directory)
if ($authorityRoots.Count -ne 1 -or ($authorityRoots[0].Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Authority archive must contain exactly one non-reparse repository root.'
}
$authorityRoot = $authorityRoots[0].FullName

$authorityFiles = @()
$seenAuthorityPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($entry in @($adapter.authority.files)) {
    if ($entry.path -isnot [string] -or [string]$entry.path -cnotmatch '^[a-zA-Z0-9._/-]+$' -or
        [string]$entry.path -match '(^|/)\.\.?(/|$)' -or -not $seenAuthorityPaths.Add([string]$entry.path)) {
        throw 'Authority file inventory contains an unsafe or duplicate path.'
    }
    Assert-Sha256 -Value $entry.sha256 -Context "Authority file '$($entry.path)' identity"
    $authorityFile = Assert-PathWithinRoot -Path (Join-Path $authorityRoot ([string]$entry.path)) -Root $authorityRoot -Context 'Authority file'
    if (-not (Test-Path -LiteralPath $authorityFile -PathType Leaf)) { throw "Authority file is missing: $($entry.path)" }
    $fileHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $authorityFile).Hash.ToLowerInvariant()
    if ($fileHash -cne [string]$entry.sha256) { throw "Authority file identity mismatch: $($entry.path)" }
    $authorityFiles += [pscustomobject][ordered]@{ path = [string]$entry.path; sha256 = $fileHash }
}
$requiredAuthorityFiles = @(
    'docs/standards/README.md',
    'docs/standards/managed-skill-lifecycle.md',
    'docs/standards/schemas/managed-skill-lifecycle-v1.schema.json',
    'docs/standards/skill-repository-standard.md',
    'docs/standards/skill-repository-review-matrix.md',
    'docs/standards/upstream-interoperability.md',
    'docs/standards/validation-security-gate.json',
    'docs/standards/validation-toolchain.json',
    'docs/standards/schemas/validation-security-gate-v1.schema.json',
    'docs/standards/schemas/source-inventory-v2.schema.json',
    'docs/standards/schemas/openai-agent-metadata.schema.json',
    'scripts/Invoke-StandardAuthorityGate.ps1',
    'scripts/Resolve-StandardValidationTool.ps1',
    'scripts/Resolve-PythonWheelClosure.py'
)
foreach ($required in $requiredAuthorityFiles) {
    if (-not $seenAuthorityPaths.Contains($required)) { throw "Authority inventory does not bind required file '$required'." }
}

$standardPath = Join-Path $authorityRoot 'docs/standards/skill-repository-standard.md'
$standardText = Get-Content -LiteralPath $standardPath -Raw -Encoding UTF8
if ($standardText -cnotmatch '(?m)^# Agent Skill Repository Standard v1$' -or $standardText -cnotmatch '(?m)^Status: \*\*Normative\*\*$') {
    throw 'Verified authority snapshot does not identify normative Standard v1.'
}
$resolverPath = Join-Path $authorityRoot 'scripts/Resolve-StandardValidationTool.ps1'
$policyPath = Join-Path $authorityRoot 'docs/standards/validation-toolchain.json'
$authorityGatePath = Join-Path $authorityRoot 'scripts/Invoke-StandardAuthorityGate.ps1'
$validationSecurityGatePath = Join-Path $authorityRoot 'docs/standards/validation-security-gate.json'
. $authorityGatePath -DefineFunctionsOnly
$validationSecurityGate = Assert-AuthorityValidationSecurityGate `
    -Policy (Read-JsonFile -Path $validationSecurityGatePath -Context 'Validation/security gate policy')
$validationSecurityGatePolicySha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $validationSecurityGatePath).Hash.ToLowerInvariant()

$policyReceiptPath = Join-Path $runRoot 'policy.json'
& $resolverPath -PolicyPath $policyPath -ValidatePolicyOnly -OutputPath $policyReceiptPath | Out-Host
$policyReceipt = Read-JsonFile -Path $policyReceiptPath -Context 'Validation tool policy receipt'
if ($policyReceipt.policy -cne 'latest-stable-per-validation-run' -or
    $policyReceipt.sourceTrust.enforcement -cne 'exact-approved-source' -or
    $policyReceipt.recordResolvedIdentityWhenAvailable -ne $true) {
    throw 'Validation tool policy receipt does not preserve the central trust contract.'
}

$expectedSources = [ordered]@{
    'skillspector' = 'NVIDIA/SkillSpector'
    'skill-validator' = 'github.com/agent-ecosystem/skill-validator/cmd/skill-validator'
    'skill-tools' = 'npm:skill-tools'
    'pester' = 'PowerShellGallery:Pester'
}
$receipts = [ordered]@{}
foreach ($toolName in $expectedSources.Keys) {
    $receiptPath = Join-Path $runRoot "receipt-$toolName.json"
    & $resolverPath -PolicyPath $policyPath -ToolName $toolName -Install -InstallRoot $installRoot -ExpectedGoRuntimeVersion $ExpectedGoRuntimeVersion -OutputPath $receiptPath | Out-Host
    $receipt = Read-JsonFile -Path $receiptPath -Context "$toolName resolver receipt"
    if ($receipt.toolName -cne $toolName -or $receipt.source -cne $expectedSources[$toolName] -or
        $receipt.channel -cne 'latest-stable' -or $receipt.frozenForRun -ne $true -or
        [string]::IsNullOrWhiteSpace([string]$receipt.resolvedVersion) -or
        [string]::IsNullOrWhiteSpace([string]$receipt.resolvedIdentity)) {
        throw "$toolName receipt does not bind the approved frozen latest-stable identity."
    }
    $receipts[$toolName] = $receipt
    if ($toolName -ceq 'skillspector') {
        Remove-Item -LiteralPath 'Env:GITHUB_TOKEN' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Env:GH_TOKEN' -Force -ErrorAction SilentlyContinue
    }
}

$skillSpectorPath = Assert-ReceiptFile -Receipt $receipts.skillspector -PathProperty 'executablePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'SkillSpector'
$skillValidatorPath = Assert-ReceiptFile -Receipt $receipts.'skill-validator' -PathProperty 'executablePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'skill-validator'
$skillToolsNodePath = Assert-ExternalReceiptFile -Receipt $receipts.'skill-tools' -PathProperty 'nodePath' -HashProperty 'nodeSha256' -Context 'skill-tools Node'
$skillToolsEntryPoint = Assert-ReceiptFile -Receipt $receipts.'skill-tools' -PathProperty 'entryPointPath' -HashProperty 'entryPointSha256' -InstallRoot $installRoot -Context 'skill-tools entry point'
$pesterModulePath = Assert-ReceiptFile -Receipt $receipts.pester -PathProperty 'modulePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'Pester module'
$receiptClosureRoots = @{}
foreach ($toolName in $expectedSources.Keys) {
    $receipt = $receipts[$toolName]
    if ($null -ne $receipt.PSObject.Properties['installedClosureSha256']) {
        $receiptClosureRoots[$toolName] = Assert-ReceiptInstalledClosure -Receipt $receipt -InstallRoot $installRoot -Context "$toolName installed closure"
    }
}

$securityFindings = @()
$securityBlockers = @()
$securityHumanReview = @()
$securityTracked = @()
$staticReports = @()
$staticFindingCount = 0
$skillValidatorReports = @()
$skillValidatorCheckReports = @()
$skillToolsReports = @()
$skillToolsRouteReports = @()

# Stage 3: Package Validation. This must complete before any SkillSpector scan.
foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $skillIntegrity = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($skillIntegrity.Count -ne 1) { throw "Candidate integrity evidence is ambiguous for '$skillId'." }
    $expectedInventoryPaths = @($skillIntegrity[0].files | ForEach-Object { [string]$_.path })
    $validatorOutput = Invoke-NativeChecked -Command $skillValidatorPath -Arguments @('-o', 'json', 'validate', 'structure', '--allow-dirs=agents', $skillRoot) -Context "skill-validator package validation for $skillId" -DiagnosticRoot $runRoot -IsolateRunnerCommandFiles -TerminateProcessTree -ProtectRunnerCommandFiles
    $validatorReportPath = Join-Path $runRoot "skill-validator-$skillId.json"
    [IO.File]::WriteAllText($validatorReportPath, $validatorOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $validatorReport = Read-JsonFile -Path $validatorReportPath -Context "skill-validator package validation report for $skillId"
    Assert-SkillValidatorReport -Report $validatorReport -SkillRoot $skillRoot -ExpectedInventoryPaths $expectedInventoryPaths -SkillId $skillId
    $skillValidatorReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($validatorReportPath) }

    $checkOutput = Invoke-NativeChecked -Command $skillValidatorPath -Arguments @('check', '--strict', '--allow-dirs=agents', '-o', 'json', $skillRoot) -Context "skill-validator full check for $skillId" -DiagnosticRoot $runRoot -IsolateRunnerCommandFiles -TerminateProcessTree -ProtectRunnerCommandFiles
    $checkReportPath = Join-Path $runRoot "skill-validator-check-$skillId.json"
    [IO.File]::WriteAllText($checkReportPath, $checkOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $checkReport = Read-JsonFile -Path $checkReportPath -Context "skill-validator full check report for $skillId"
    Assert-SkillValidatorReport -Report $checkReport -SkillRoot $skillRoot -ExpectedInventoryPaths $expectedInventoryPaths -SkillId $skillId
    $skillValidatorCheckReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($checkReportPath) }
}

# Stage 4: SkillSpector Static.
foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $skillIntegrity = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    if ($skillIntegrity.Count -ne 1) { throw "Candidate integrity evidence is ambiguous for '$skillId'." }
    $expectedInventoryPaths = @($skillIntegrity[0].files | ForEach-Object { [string]$_.path })
    $reportPath = Join-Path $runRoot "skillspector-static-$skillId.json"
    [void](Invoke-NativeChecked -Command $skillSpectorPath -Arguments @('scan', $skillRoot, '--no-llm', '--format', 'json', '--output', $reportPath) -Context "SkillSpector static scan for $skillId" -DiagnosticRoot $runRoot -IsolateRunnerCommandFiles -TerminateProcessTree -ProtectRunnerCommandFiles)
    $report = Read-JsonFile -Path $reportPath -Context "SkillSpector static report for $skillId"
    $issues = @(Assert-SkillSpectorReport -Report $report -SkillRoot $skillRoot -SkillId $skillId -ExpectedInventoryPaths $expectedInventoryPaths)
    foreach ($issue in $issues) {
        $reportedSeverity = Get-RequiredProperty -Object $issue -Name 'severity' -Context 'SkillSpector issue'
        if ($reportedSeverity -isnot [string] -or [string]::IsNullOrWhiteSpace($reportedSeverity)) {
            throw "SkillSpector returned an issue without severity for '$skillId'."
        }
        $finding = ConvertTo-ValidationSecurityFinding `
            -Policy $validationSecurityGate `
            -ReportedSeverity ([string]$reportedSeverity) `
            -Stage 'skillspector-static' `
            -SkillId $skillId `
            -Issue $issue
        $securityFindings += $finding
        $staticFindingCount++
        switch ([string]$finding.action) {
            'BLOCK' { $securityBlockers += $finding }
            'HUMAN_REVIEW_REQUIRED' { $securityHumanReview += $finding; $securityBlockers += $finding }
            'RECORD_AND_TRACK' { $securityTracked += $finding }
            default { throw "Central validation/security gate returned unsupported action '$($finding.action)'." }
        }
    }
    $staticReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($reportPath); findings = $issues.Count; files = $expectedInventoryPaths.Count }
}

# Stage 5: Repository Tests.
$repositoryReportPath = Join-Path $runRoot 'repository-validation.json'
$repositoryJson = & $repositoryValidatorPath -RepositoryRoot $repoRoot -OutputPath $repositoryReportPath | Select-Object -Last 1
$repositoryReport = $repositoryJson | ConvertFrom-Json -Depth 100
if ($repositoryReport.result -cne 'passed' -or [int]$repositoryReport.activeSkillCount -ne $skillIds.Count) {
    throw 'Repository validation did not cover the exact active Skill inventory.'
}
foreach ($skillId in $skillIds) {
    $before = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    $after = @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })
    Assert-SkillInventoryUnchanged -Before $before -After $after -SkillId $skillId -Context 'between integrity verification and repository validation'
}
$diffArguments = if (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
    @($gitConfigArguments + @('-C', $repoRoot, 'diff', '--check', "$BaseCommit...HEAD"))
}
else {
    # A missing event base must validate the complete committed candidate,
    # not only the final commit. All supported GitHub repositories use the
    # SHA-1 object format, whose canonical empty tree object is stable.
    $emptyTreeObject = '4b825dc642cb6eb9a060e54bf8d69288fbee4904'
    @($gitConfigArguments + @('-C', $repoRoot, 'diff', '--check', $emptyTreeObject, 'HEAD'))
}
$diffOutput = @(& $gitPath @diffArguments 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Whitespace validation failed for the candidate event range.`n$($diffOutput -join [Environment]::NewLine)"
}

foreach ($skillId in $skillIds) {
    $skillRoot = Join-Path $repoRoot "skills/$skillId"
    $expectedInventoryPaths = @(
        @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })[0].files |
            ForEach-Object { [string]$_.path }
    )
    $toolsOutput = Invoke-NativeChecked -Command $skillToolsNodePath -Arguments @($skillToolsEntryPoint, 'check', $skillRoot, '--format', 'sarif', '--fail-on', 'warning', '--min-score', '91') -Context "skill-tools repository test for $skillId" -DiagnosticRoot $runRoot -IsolateRunnerCommandFiles -TerminateProcessTree -ProtectRunnerCommandFiles
    $toolsReportPath = Join-Path $runRoot "skill-tools-$skillId.sarif.json"
    [IO.File]::WriteAllText($toolsReportPath, $toolsOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $toolsReport = Read-JsonFile -Path $toolsReportPath -Context "skill-tools report for $skillId"
    Assert-SkillToolsReport -Report $toolsReport -SkillRoot $skillRoot -ExpectedInventoryPaths $expectedInventoryPaths -SkillId $skillId
    $skillToolsReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($toolsReportPath) }
}

$routeCases = @(
    [pscustomobject]@{ query = 'Update a Warhammer 40,000 DARKTIDE MOD from a verified Nexus Main file and preserve active zh-tw'; expected = 'auto-update-darktide-mod' },
    [pscustomobject]@{ query = 'Resume a DARKTIDE MOD update run using its exact evidence and finalize the merge'; expected = 'auto-update-darktide-mod' }
)
foreach ($routeCase in $routeCases) {
    $routeOutput = Invoke-NativeChecked -Command $skillToolsNodePath -Arguments @(
        $skillToolsEntryPoint, 'route', [string]$routeCase.query, '--skills', $skillsRoot, '--top-k', '1', '--format', 'json'
    ) -Context "skill-tools route for '$($routeCase.query)'" -DiagnosticRoot $runRoot -IsolateRunnerCommandFiles -TerminateProcessTree -ProtectRunnerCommandFiles
    $routePath = Join-Path $runRoot ("skill-tools-route-{0}.json" -f ([guid]::NewGuid().ToString('N')))
    [IO.File]::WriteAllText($routePath, $routeOutput + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    # PowerShell unwraps a one-item JSON array during assignment. Normalize the
    # result before enforcing the contract so a valid top-k=1 result is not
    # mistaken for a non-array value on the hosted runner.
    $routeResults = @(Read-JsonFile -Path $routePath -Context "skill-tools route report for '$($routeCase.query)'")
    if ($routeResults.Count -ne 1) {
        throw "skill-tools route did not return exactly one result for '$($routeCase.query)'."
    }
    $routeSkill = Get-RequiredProperty -Object @($routeResults)[0] -Name 'skill' -Context 'skill-tools route result'
    if ($routeSkill -isnot [string] -or $routeSkill -cne [string]$routeCase.expected) {
        throw "skill-tools route selected '$routeSkill' for '$($routeCase.query)'; expected '$($routeCase.expected)'."
    }
    $skillToolsRouteReports += [pscustomobject][ordered]@{
        query = [string]$routeCase.query
        expected = [string]$routeCase.expected
        selected = [string]$routeSkill
        report = [IO.Path]::GetFileName($routePath)
    }
}

# The optional semantic scanner is bound and executed before candidate Pester
# code can modify any run-owned tool or report path. Its output remains part of
# the final supervisor-owned summary, while post-Pester checks bind the final
# candidate state.
$semanticTriggerCandidate = $staticFindingCount -gt 0 -or (Test-SecurityRelevantSkillChange -GitPath $gitPath -RepositoryRoot $repoRoot -BaseCommit $BaseCommit)
$semanticTriggered = [bool]$EnableSemanticScan -and $semanticTriggerCandidate
$semanticReports = @()
# Required CI remains credential-free and deterministic; semantic scanning is opt-in.
if ($semanticTriggered) {
    $skillSpectorPath = Assert-ReceiptFile -Receipt $receipts.skillspector -PathProperty 'executablePath' -HashProperty 'executableSha256' -InstallRoot $installRoot -Context 'SkillSpector semantic scanner'
    if ($receiptClosureRoots.ContainsKey('skillspector')) {
        [void](Assert-ReceiptInstalledClosure -Receipt $receipts.skillspector -InstallRoot $installRoot -Context 'SkillSpector semantic scanner')
    }
    foreach ($skillId in $skillIds) {
        $skillRoot = Join-Path $repoRoot "skills/$skillId"
        $expectedInventoryPaths = @(
            @($repositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })[0].files |
                ForEach-Object { [string]$_.path }
        )
        $semanticPath = Join-Path $runRoot "skillspector-semantic-$skillId.json"
        [void](Invoke-NativeChecked -Command $skillSpectorPath -Arguments @('scan', $skillRoot, '--format', 'json', '--output', $semanticPath) -Context "SkillSpector semantic scan for $skillId" -DiagnosticRoot $runRoot -AdditionalEnvironmentVariables $semanticCredentialEnvironment -IsolateRunnerCommandFiles -TerminateProcessTree -ProtectRunnerCommandFiles)
        $semanticReport = Read-JsonFile -Path $semanticPath -Context "SkillSpector semantic report for $skillId"
        try {
            $semanticIssues = @(Assert-SkillSpectorReport -Report $semanticReport -SkillRoot $skillRoot -SkillId $skillId -ExpectedInventoryPaths $expectedInventoryPaths)
        }
        catch {
            throw "Triggered SkillSpector semantic scan did not complete for '$skillId': $($_.Exception.Message)"
        }
        foreach ($issue in $semanticIssues) {
            $reportedSeverity = Get-RequiredProperty -Object $issue -Name 'severity' -Context 'SkillSpector semantic issue'
            if ($reportedSeverity -isnot [string] -or [string]::IsNullOrWhiteSpace($reportedSeverity)) {
                throw "SkillSpector semantic scan returned an issue without severity for '$skillId'."
            }
            $finding = ConvertTo-ValidationSecurityFinding -Policy $validationSecurityGate -ReportedSeverity ([string]$reportedSeverity) -Stage 'conditional-semantic-scan' -SkillId $skillId -Issue $issue
            $securityFindings += $finding
            switch ([string]$finding.action) {
                'BLOCK' { $securityBlockers += $finding }
                'HUMAN_REVIEW_REQUIRED' { $securityHumanReview += $finding; $securityBlockers += $finding }
                'RECORD_AND_TRACK' { $securityTracked += $finding }
                default { throw "Central validation/security gate returned unsupported action '$($finding.action)'." }
            }
        }
        $semanticReports += [pscustomobject][ordered]@{ skillId = $skillId; report = [IO.Path]::GetFileName($semanticPath); findings = $semanticIssues.Count }
    }
}

foreach ($name in @($semanticCredentialEnvironment.Keys)) {
    $semanticCredentialEnvironment[$name] = ''
}

# Candidate tests are untrusted code. Run them in a child PowerShell process so
# a test cannot terminate this validator before the post-test integrity checks.
$pesterRunnerPath = Join-Path $runRoot 'invoke-pester-isolated.ps1'
$pesterRunnerScript = @'
#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $TestsRoot,
    [Parameter(Mandatory = $true)][string] $PesterModulePath,
    [Parameter(Mandatory = $true)][string] $ExpectedPesterVersion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testsRoot = [IO.Path]::GetFullPath($TestsRoot)
$pesterModulePath = [IO.Path]::GetFullPath($PesterModulePath)
$resultMarker = ([Console]::In.ReadToEnd()).TrimEnd([char]13, [char]10)
if ($resultMarker -notmatch '^SGV1-Pester-Result-[0-9a-f]{32}:$') {
    throw 'The isolated Pester supervisor did not receive a valid one-time completion marker.'
}
if (-not (Test-Path -LiteralPath $testsRoot -PathType Container)) { throw "Pester tests root is missing: $testsRoot" }
if (-not (Test-Path -LiteralPath $pesterModulePath -PathType Leaf)) { throw "Pester module manifest is missing: $pesterModulePath" }

Remove-Module Pester -Force -ErrorAction SilentlyContinue
Import-Module -Name $pesterModulePath -Force -ErrorAction Stop
$loadedPester = Get-Module Pester | Select-Object -First 1
if ($null -eq $loadedPester -or [string]$loadedPester.Version -cne $ExpectedPesterVersion) {
    throw 'The exact frozen Pester module was not imported in the isolated test process.'
}
$result = Invoke-Pester -Path $testsRoot -PassThru
if ($null -eq $result -or [int64]$result.TotalCount -le 0 -or [int64]$result.FailedCount -ne 0 -or
    [int64]$result.SkippedCount -ne 0 -or
    [int64]$result.PassedCount + [int64]$result.SkippedCount -ne [int64]$result.TotalCount) {
    throw 'Pester repository regression did not complete successfully.'
}

$summary = [ordered]@{
    result = 'passed'
    pesterVersion = [string]$loadedPester.Version
    totalCount = [int64]$result.TotalCount
    passedCount = [int64]$result.PassedCount
    failedCount = [int64]$result.FailedCount
    skippedCount = [int64]$result.SkippedCount
}
Write-Output ($resultMarker + ($summary | ConvertTo-Json -Depth 20 -Compress))
'@
[IO.File]::WriteAllText($pesterRunnerPath, $pesterRunnerScript + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
Assert-NoReparseAncestors -Path $pesterRunnerPath -Context 'Run-owned isolated Pester runner'
$powerShellExecutableName = if ($script:IsWindowsHost) { 'pwsh.exe' } else { 'pwsh' }
$powerShellPath = Join-Path $PSHOME $powerShellExecutableName
if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) { throw "PowerShell child executable is missing: $powerShellPath" }
Assert-NoReparseAncestors -Path $powerShellPath -Context 'PowerShell child executable'
$pesterResultMarker = 'SGV1-Pester-Result-{0}:' -f ([guid]::NewGuid().ToString('N'))
$pesterOutput = Invoke-NativeChecked -Command $powerShellPath -Arguments @(
    '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $pesterRunnerPath,
    '-TestsRoot', (Join-Path $repoRoot 'tests'),
    '-PesterModulePath', $pesterModulePath,
    '-ExpectedPesterVersion', [string]$receipts.pester.resolvedVersion
 ) -Context 'Isolated Pester repository regression' -DiagnosticRoot $runRoot -StandardInput $pesterResultMarker -IsolateRunnerCommandFiles -TerminateProcessTree -ProtectRunnerCommandFiles -ApplyLinuxResourceLimits
$pesterResultLines = @($pesterOutput -split "`r?`n" | Where-Object {
    $_.StartsWith($pesterResultMarker, [StringComparison]::Ordinal)
})
if ($pesterResultLines.Count -ne 1) {
    throw 'Isolated Pester exited without exactly one supervisor-owned completion result.'
}
try {
    $pesterResultJson = $pesterResultLines[0].Substring($pesterResultMarker.Length)
    $pesterResultDocument = [System.Text.Json.JsonDocument]::Parse($pesterResultJson)
    try {
        Assert-NoDuplicateJsonProperties -Element $pesterResultDocument.RootElement -Context 'Isolated Pester result'
    }
    finally {
        $pesterResultDocument.Dispose()
    }
    $pesterResult = $pesterResultJson | ConvertFrom-Json -Depth 20
}
catch {
    throw "Isolated Pester result is not valid unambiguous JSON: $($_.Exception.Message)"
}
if ($pesterResult.result -cne 'passed' -or
    $pesterResult.pesterVersion -cne [string]$receipts.pester.resolvedVersion -or
    [int64]$pesterResult.TotalCount -le 0 -or [int64]$pesterResult.FailedCount -ne 0 -or
    [int64]$pesterResult.SkippedCount -ne 0 -or
    [int64]$pesterResult.PassedCount + [int64]$pesterResult.SkippedCount -ne [int64]$pesterResult.TotalCount) {
    throw 'Isolated Pester repository regression result was missing, mismatched, or incomplete.'
}

# Candidate Pester code runs with the runner account and may replace files in
# the run-owned or supervisor roots. Never invoke the original path again
# after that untrusted process. Keep the trusted bytes in memory and execute
# a scriptblock created directly from that pre-test snapshot; this avoids
# reopening any candidate-writable pathname for post-test evidence.
$postPesterValidatorHasher = [Security.Cryptography.SHA256]::Create()
try {
    $postPesterValidatorHash = ([BitConverter]::ToString($postPesterValidatorHasher.ComputeHash($repositoryValidatorBytes)) -replace '-', '').ToLowerInvariant()
}
finally {
    $postPesterValidatorHasher.Dispose()
}
if ($postPesterValidatorHash -cne $repositoryValidatorHash) {
    throw 'Post-Pester repository validator identity does not match the pre-test trusted bytes.'
}
$postPesterRepositoryValidatorText = [Text.UTF8Encoding]::new($false, $true).GetString($repositoryValidatorBytes)
$postPesterRepositoryValidatorScript = [scriptblock]::Create($postPesterRepositoryValidatorText)
if ($null -eq $postPesterRepositoryValidatorScript) {
    throw 'Post-Pester repository validator script could not be created from the pre-test trusted bytes.'
}

$postPesterRepositoryReportPath = Join-Path $runRoot 'repository-validation-post-pester.json'
$trustedGitConfigActualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $trustedGitConfigPath).Hash.ToLowerInvariant()
if ($trustedGitConfigActualSha256 -cne $trustedGitConfigSha256) {
    throw 'Run-owned Git global config changed before post-Pester evidence collection.'
}
Assert-NoReparseAncestors -Path $trustedGitConfigPath -Context 'Run-owned Git global config'
Assert-NoReparseAncestors -Path $trustedGitHooksPath -Context 'Run-owned empty Git hooks directory'
$hookEntries = @(Get-ChildItem -LiteralPath $trustedGitHooksPath -Force)
if ($hookEntries.Count -ne 0) {
    throw 'Run-owned Git hooks directory is not empty before post-Pester evidence collection.'
}
$env:GIT_CONFIG_NOSYSTEM = '1'
$env:GIT_CONFIG_GLOBAL = $trustedGitConfigPath
$env:GIT_CONFIG_COUNT = '2'
$env:GIT_CONFIG_KEY_0 = 'core.hooksPath'
$env:GIT_CONFIG_VALUE_0 = $trustedGitHooksPath
$env:GIT_CONFIG_KEY_1 = 'core.fsmonitor'
$env:GIT_CONFIG_VALUE_1 = 'false'
$postPesterCandidateCommit = ([string](@(& $gitPath @gitConfigArguments -C $repoRoot rev-parse HEAD 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $postPesterCandidateCommit -cne $candidateCommit) {
    throw "Candidate commit changed during repository tests; expected '$candidateCommit' but found '$postPesterCandidateCommit'."
}
$postPesterTree = ([string](@(& $gitPath @gitConfigArguments -C $repoRoot rev-parse "$postPesterCandidateCommit^{tree}" 2>$null) | Select-Object -First 1)).Trim()
if ($LASTEXITCODE -ne 0 -or $postPesterTree -cne $candidateTree) {
    throw 'Candidate Git tree changed during repository tests.'
}
Assert-NoGitReplacementObjects -GitPath $gitPath -RepositoryRoot $repoRoot -Context 'Post-test candidate'
$postPesterIndexItem = Get-Item -LiteralPath $gitIndexPath -Force -ErrorAction SilentlyContinue
if ($null -eq $postPesterIndexItem -or $postPesterIndexItem.PSIsContainer -or
    ($postPesterIndexItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'Candidate Git index was removed or replaced with a non-regular entry during repository tests.'
}
$postPesterGitIndexSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $gitIndexPath).Hash.ToLowerInvariant()
if ($postPesterGitIndexSha256 -cne $prePesterGitIndexSha256) {
    throw 'Candidate Git index changed during repository tests.'
}
$postPesterRepositoryJson = & $postPesterRepositoryValidatorScript -RepositoryRoot $repoRoot -OutputPath $postPesterRepositoryReportPath -NoFilters | Select-Object -Last 1
$postPesterRepositoryReport = $postPesterRepositoryJson | ConvertFrom-Json -Depth 100
if ($postPesterRepositoryReport.result -cne 'passed' -or [int]$postPesterRepositoryReport.activeSkillCount -ne $skillIds.Count) {
    throw 'Post-Pester repository validation did not cover the exact active Skill inventory.'
}
foreach ($skillId in $skillIds) {
    $before = @($integrityReport.skills | Where-Object { $_.skillId -ceq $skillId })
    $after = @($postPesterRepositoryReport.skills | Where-Object { $_.skillId -ceq $skillId })
    Assert-SkillInventoryUnchanged -Before $before -After $after -SkillId $skillId -Context 'during repository tests'
}
$postPesterRepositoryRawSnapshot = @(Get-RepositoryRawSnapshot -RepositoryRoot $repoRoot)
Assert-RepositoryRawSnapshotUnchanged -Before $prePesterRepositoryRawSnapshot -After $postPesterRepositoryRawSnapshot
$repositoryReport = $postPesterRepositoryReport

$summary = [pscustomobject][ordered]@{
    schemaVersion = 1
    standardVersion = 'v1'
    runId = $runId
    authority = [ordered]@{
        repository = [string]$adapter.authority.repository
        commit = [string]$adapter.authority.commit
        archiveSha256 = $archiveHash
        files = $authorityFiles
    }
    canonicalGate = [ordered]@{
        policy = [string]$validationSecurityGate.policy
        policyPath = 'docs/standards/validation-security-gate.json'
        policySha256 = $validationSecurityGatePolicySha256
        stageIds = @($validationSecurityGate.stages | ForEach-Object { [string]$_.id })
    }
    candidate = [ordered]@{
        repository = 'https://github.com/SyuanTsai/Skill-Darktide-Translate.git'
        commit = $candidateCommit
        baseCommit = $resolvedBaseCommit
    }
    tools = @($expectedSources.Keys | ForEach-Object {
        [pscustomobject][ordered]@{
            toolName = $_
            source = [string]$receipts[$_].source
            version = [string]$receipts[$_].resolvedVersion
            resolvedIdentity = [string]$receipts[$_].resolvedIdentity
        }
    })
    skills = @($repositoryReport.skills | ForEach-Object { [pscustomobject][ordered]@{ skillId = $_.skillId; contentSha256 = $_.contentSha256 } })
    security = [ordered]@{
        result = if (@($securityBlockers).Count -eq 0) { 'passed' } else { 'blocked' }
        findings = $securityFindings
        humanReviewRequired = $securityHumanReview
        blockingFindings = $securityBlockers
        trackedFindings = $securityTracked
    }
    stages = [ordered]@{
        controlledAcquisition = 'passed'
        integrityVerification = 'passed'
        packageValidation = [ordered]@{ structure = $skillValidatorReports; fullCheck = $skillValidatorCheckReports }
        skillspectorStatic = $staticReports
        repositoryTests = [ordered]@{
            repositoryValidation = 'passed'
            skillTools = $skillToolsReports
            routing = $skillToolsRouteReports
            pester = [ordered]@{ result = 'passed'; total = [int]$pesterResult.TotalCount; passed = [int]$pesterResult.PassedCount; skipped = [int]$pesterResult.SkippedCount }
        }
        conditionalSemanticScan = [ordered]@{ requested = [bool]$EnableSemanticScan; triggered = $semanticTriggered; reports = $semanticReports }
        aiReview = 'required-before-release'
        humanApproval = 'required-before-release'
        publishOrInstall = 'blocked-until-approved-release'
        postInstallVerification = 'required-after-install'
    }
    deviations = 'None'
    result = if (@($securityBlockers).Count -eq 0) { 'passed' } else { 'blocked' }
}
$summaryJson = $summary | ConvertTo-Json -Depth 100
$summaryPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $runRoot 'conformance-report.json'
}
else {
    Assert-PathWithinRoot -Path ([IO.Path]::GetFullPath($OutputPath)) -Root $artifactsRootPath -Context 'Conformance output'
}
$summaryDirectory = Split-Path -Parent $summaryPath
if (-not [string]::IsNullOrWhiteSpace($summaryDirectory)) {
    [void](New-Item -ItemType Directory -Path $summaryDirectory -Force)
    Assert-NoReparseAncestors -Path $summaryDirectory -Context 'Conformance output directory'
}
if (Test-Path -LiteralPath $summaryPath) { throw 'Conformance output path already exists; evidence must not overwrite prior content.' }
$summaryEncoding = [Text.UTF8Encoding]::new($false)
$summaryText = $summaryJson + [Environment]::NewLine
$summaryBytes = $summaryEncoding.GetBytes($summaryText)
$summaryHasher = [Security.Cryptography.SHA256]::Create()
try {
    $summarySha256 = ([BitConverter]::ToString($summaryHasher.ComputeHash($summaryBytes)) -replace '-', '').ToLowerInvariant()
}
finally {
    $summaryHasher.Dispose()
}
try {
    $summaryStream = [IO.File]::Open(
        $summaryPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::Read
    )
    try {
        $summaryStream.Write($summaryBytes, 0, $summaryBytes.Length)
        $summaryStream.Flush($true)
    }
    finally {
        $summaryStream.Dispose()
    }
}
catch {
    throw "Could not create supervisor-owned conformance evidence: $($_.Exception.Message)"
}
Assert-NoReparseAncestors -Path $summaryPath -Context 'Conformance output'
$writtenSummaryBytes = [IO.File]::ReadAllBytes($summaryPath)
$readbackHasher = [Security.Cryptography.SHA256]::Create()
try {
    $writtenSummarySha256 = ([BitConverter]::ToString($readbackHasher.ComputeHash($writtenSummaryBytes)) -replace '-', '').ToLowerInvariant()
}
finally {
    $readbackHasher.Dispose()
}
if ($writtenSummarySha256 -cne $summarySha256) {
    throw 'Conformance evidence changed during immediate readback.'
}
$githubOutputPath = [Environment]::GetEnvironmentVariable('GITHUB_OUTPUT', [EnvironmentVariableTarget]::Process)
if (-not [string]::IsNullOrWhiteSpace($githubOutputPath)) {
    if (-not (Test-Path -LiteralPath $githubOutputPath -PathType Leaf)) {
        throw "GitHub output command file is missing: $githubOutputPath"
    }
    Assert-NoReparseAncestors -Path $githubOutputPath -Context 'GitHub output command file'
    [IO.File]::AppendAllText(
        $githubOutputPath,
        "standard_v1_evidence_sha256=$summarySha256$([Environment]::NewLine)",
        $summaryEncoding
    )
}
if (@($securityBlockers).Count -gt 0) {
    Write-Host "Darktide Translate Standard v1 canonical validation blocked by the central security gate. Evidence: $summaryPath"
}
else {
    Write-Host "Darktide Translate Standard v1 canonical validation passed. Evidence: $summaryPath"
}
$summaryJson
if (@($securityBlockers).Count -gt 0) {
    throw 'Canonical validation/security gate blocked the candidate; resolve central findings and obtain required Human Review before release or install.'
}
