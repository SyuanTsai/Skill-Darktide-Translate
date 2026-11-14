// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.Text;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    internal sealed class WindowsProcessControl : IOwnedProcessControl
    {
        [StructLayout(LayoutKind.Sequential)] private struct BasicLimit
        {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr Minimum, Maximum;
            public uint ActiveLimit;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimit
        {
            public BasicLimit Basic;
            public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [StructLayout(LayoutKind.Sequential)] private struct Accounting
        {
            public long User, Kernel, PeriodUser, PeriodKernel;
            public uint Faults, Total, Active, Terminated;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct Startup
        {
            public int Size;
            public IntPtr Reserved, Desktop, Title;
            public uint X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
            public ushort Show, ReservedCount;
            public IntPtr ReservedBytes, Input, Output, Error;
        }
        [StructLayout(LayoutKind.Sequential)] private struct StartupEx { public Startup Startup; public IntPtr Attributes; }
        [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr Process, Thread; public uint Pid, Tid; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObjectW(IntPtr security, string name);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref ExtendedLimit info, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool QueryInformationJobObject(SafeFileHandle job, int kind, out Accounting info, uint size, IntPtr returned);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, SafeFileHandle process);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateJobObject(SafeFileHandle job, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool TerminateProcess(SafeFileHandle process, uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returned);
        [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateProcessW(string application, StringBuilder commandLine, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags, IntPtr environment, string cwd, ref StartupEx startup, out ProcessInfo info);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint ResumeThread(SafeFileHandle thread);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern uint WaitForSingleObject(SafeFileHandle handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetExitCodeProcess(SafeFileHandle process, out uint code);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetProcessTimes(SafeFileHandle process, out long created, out long exited, out long kernel, out long user);

        private SafeFileHandle job, process;
        private Func<uint> countProcesses;
        private WindowsProcessControl() { countProcesses = CountActiveProcesses; }
        public int Pid { get; private set; }
        public string StartIdentity { get; private set; }
        public string Isolation { get { return "windows-job-object"; } }
        public bool Exited { get; private set; }
        public int? ExitCode { get; private set; }
        public string Uncertainty { get { return null; } }
        private static void Check(bool result, string operation)
        { if (!result) throw new PlatformWin32Exception(operation, Marshal.GetLastWin32Error()); }

        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetHandleInformation(SafePipeHandle handle, uint mask, uint flags);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetHandleInformation(SafePipeHandle handle, out uint flags);
        internal static void PrepareInputWriter(SafePipeHandle writer)
        {
            // Only the read end appears in CreateProcess's explicit handle list.
            Check(SetHandleInformation(writer, 1, 0), "stdin-writer-no-inherit");
            uint flags;
            Check(GetHandleInformation(writer, out flags), "stdin-writer-inherit-readback");
            if ((flags & 1) != 0) throw new IOException("stdin writer remained inheritable.");
        }

        internal static void WriteInput(AnonymousPipeServerStream writer, byte[] bytes, DateTimeOffset deadline)
        {
            // Only the owned Job can retain the read end. Its deadline supervisor
            // terminates every reader, releasing a blocked synchronous Write.
            for (int offset = 0; offset < bytes.Length;)
            {
                if (DateTimeOffset.UtcNow >= deadline) throw new TimeoutException("stdin delivery deadline was exceeded.");
                int count = Math.Min(4096, bytes.Length - offset);
                writer.Write(bytes, offset, count);
                offset += count;
            }
        }

        private static string Quote(string argument)
        {
            var result = new StringBuilder("\""); int slashes = 0;
            foreach (char c in argument)
            {
                if (c == '\\') { slashes++; continue; }
                if (c == '"') { result.Append('\\', slashes * 2 + 1); result.Append(c); }
                else { result.Append('\\', slashes); result.Append(c); }
                slashes = 0;
            }
            result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
        }

        internal static WindowsProcessControl Start(string path, WindowsLease executable, string[] args, string[] env, WindowsLease cwd, IntPtr input, IntPtr output, IntPtr error)
        {
            var result = new WindowsProcessControl();
            IntPtr attributes = IntPtr.Zero, handles = IntPtr.Zero, environment = IntPtr.Zero;
            bool initialized = false, success = false;
            Exception startupFailure = null;
            SafeFileHandle thread = null;
            try
            {
                if (IntPtr.Size != 8 || Marshal.SizeOf(typeof(ExtendedLimit)) != 144 || Marshal.SizeOf(typeof(StartupEx)) != 112)
                    throw new PlatformCapabilityUnavailableException("windows-process-abi", "windows");
                result.job = CreateJobObjectW(IntPtr.Zero, null); Check(!result.job.IsInvalid, "CreateJobObject");
                ExtendedLimit limits = new ExtendedLimit(); limits.Basic.Flags = 0x2000; // KILL_ON_JOB_CLOSE; no breakaway
                Check(SetInformationJobObject(result.job, 9, ref limits, (uint)Marshal.SizeOf(limits)), "SetInformationJobObject");
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                if (size == IntPtr.Zero) throw new PlatformWin32Exception("attribute-list-size", Marshal.GetLastWin32Error());
                attributes = Marshal.AllocHGlobal(size);
                Check(InitializeProcThreadAttributeList(attributes, 1, 0, ref size), "InitializeProcThreadAttributeList"); initialized = true;
                handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handles, 0, input); Marshal.WriteIntPtr(handles, IntPtr.Size, output); Marshal.WriteIntPtr(handles, IntPtr.Size * 2, error);
                Check(UpdateProcThreadAttribute(attributes, 0, new IntPtr(0x20002), handles, new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero), "handle-inheritance-allowlist");
                environment = Marshal.StringToHGlobalUni(String.Join("\0", env) + "\0\0");
                StartupEx startup = new StartupEx(); startup.Startup.Size = Marshal.SizeOf(startup);
                startup.Startup.Flags = 0x101; startup.Startup.Show = 0;
                startup.Startup.Input = input; startup.Startup.Output = output; startup.Startup.Error = error; startup.Attributes = attributes;
                // Holding the lease monitors through creation prevents concurrent Dispose.
                lock (cwd.Sync)
                {
                    WindowsNative.AssertIdentity(cwd, cwd.Observation, false);
                    if (cwd.Observation.Kind != "directory") throw new ArgumentException("WorkingDirectoryLease must be a directory.");
                    object executableGate = executable == null ? new object() : executable.Sync;
                    lock (executableGate)
                    {
                        if (executable != null) { WindowsNative.AssertIdentity(executable, executable.Observation, true); path = executable.Path; }
                        if (String.IsNullOrEmpty(path) || !Path.IsPathRooted(path) || Path.GetPathRoot(path).Length < 3 || path.IndexOf('\0') >= 0) throw new ArgumentException("ExecutablePath must be absolute.");
                        var command = new StringBuilder(Quote(path)); foreach (string arg in args) command.Append(" ").Append(Quote(arg));
                        ProcessInfo info;
                        Check(CreateProcessW(path, command, IntPtr.Zero, IntPtr.Zero, true, 0x08080404, environment, cwd.Path, ref startup, out info), "CreateProcess-suspended");
                        result.process = new SafeFileHandle(info.Process, true); thread = new SafeFileHandle(info.Thread, true); result.Pid = checked((int)info.Pid);
                    }
                    Check(AssignProcessToJobObject(result.job, result.process), "AssignProcessToJobObject-before-resume");
                    long created, ended, kernel, user;
                    Check(GetProcessTimes(result.process, out created, out ended, out kernel, out user), "GetProcessTimes"); result.StartIdentity = created.ToString(System.Globalization.CultureInfo.InvariantCulture);
                    if (ResumeThread(thread) == UInt32.MaxValue) throw new PlatformWin32Exception("ResumeThread", Marshal.GetLastWin32Error());
                }
                success = true; return result;
            }
            catch (Exception ex) { startupFailure = ex; throw; }
            finally
            {
                if (!success)
                {
                    if (result.process != null)
                    {
                        bool terminated = TerminateProcess(result.process, 137);
                        int terminationError = terminated ? 0 : Marshal.GetLastWin32Error();
                        uint waited = WaitForSingleObject(result.process, 5000);
                        if (startupFailure != null)
                        {
                            startupFailure.Data["StartupRootExitConfirmed"] = waited == 0;
                            if (waited != 0) startupFailure.Data["StartupCleanupUncertainty"] = "process-handle termination=" + terminationError + "; wait=" + waited;
                        }
                    }
                    result.Dispose();
                }
                if (thread != null) thread.Dispose();
                if (initialized) DeleteProcThreadAttributeList(attributes);
                if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                if (environment != IntPtr.Zero) Marshal.FreeHGlobal(environment);
            }
        }
        public void Poll()
        {
            if (Exited) return;
            uint wait = WaitForSingleObject(process, 0);
            if (wait == 0) { uint code; Check(GetExitCodeProcess(process, out code), "GetExitCodeProcess"); ExitCode = unchecked((int)code); Exited = true; }
            else if (wait != 258) throw new PlatformWin32Exception("WaitForSingleObject", Marshal.GetLastWin32Error());
        }
        public int Signal(bool force)
        {
            // A failed accounting query must not suppress handle-bound termination.
            // Terminating an empty Job is harmless; the retained handle identifies it.
            Check(TerminateJobObject(job, 137), "TerminateJobObject"); return 1;
        }
        public int[] Remaining()
        {
            // Root PID is diagnostic only. The authoritative count is the kernel Job count.
            return countProcesses() == 0 ? new int[0] : new int[] { Pid };
        }
        private uint CountActiveProcesses()
        {
            Accounting accounting;
            Check(QueryInformationJobObject(job, 1, out accounting, (uint)Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero), "QueryInformationJobObject-active-processes");
            return accounting.Active;
        }
        public void Dispose() { if (job != null) job.Dispose(); if (process != null) process.Dispose(); }
    }
}
