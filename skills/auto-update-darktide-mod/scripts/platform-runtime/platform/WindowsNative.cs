// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using System.Security.Cryptography;
using System.Security.AccessControl;
using Microsoft.Win32.SafeHandles;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    public sealed class WindowsPermissions
    {
        public string Sddl { get; internal set; }
        public bool ReadOnly { get; internal set; }
    }

    public sealed class WindowsDirectoryState
    {
        public FileObservation Observation { get; internal set; }
        public string InventorySha256 { get; internal set; }
        public long EntryCount { get; internal set; }
    }

    public sealed class WindowsLease : IDisposable
    {
        internal readonly object Sync = new object();
        internal SafeFileHandle Handle;
        internal string Path;
        private List<IDisposable> guards;
        private WindowsLease parent;
        private int references = 1;
        private bool disposed;
        public FileObservation Observation { get; internal set; }
        internal bool NewWritable;
        public byte[] ReadAllBytes(int maximumBytes)
        {
            lock (Sync)
            {
                Check(); WindowsNative.AssertIdentity(this, Observation, true);
                byte[] bytes = LeaseBytes.Read(Handle, maximumBytes);
                WindowsNative.AssertIdentity(this, Observation, true); return bytes;
            }
        }
        public void WriteNewBytes(byte[] bytes)
        {
            lock (Sync)
            {
                Check(); WindowsNative.AssertIdentity(this, Observation, true);
                if (!NewWritable) throw new InvalidOperationException("A fresh create-only writable lease is required.");
                NewWritable = false; LeaseBytes.Write(Handle, bytes);
                WindowsNative.AssertIdentity(this, Observation, true);
            }
        }
        internal WindowsLease(SafeFileHandle handle, string path, List<IDisposable> guards, WindowsLease parent, FileObservation observation)
        {
            Handle = handle; Path = path; this.guards = guards; this.parent = parent; Observation = observation;
            if (parent != null) parent.Retain();
        }
        internal void Check() { if (disposed) throw new ObjectDisposedException("WindowsLease"); }
        private void Retain() { lock (Sync) { Check(); references++; } }
        private void Release()
        {
            lock (Sync)
            {
                if (--references != 0) return;
                Handle.Dispose();
                if (guards != null) for (int i = guards.Count - 1; i >= 0; i--) guards[i].Dispose();
                if (parent != null) parent.Release();
            }
        }
        public void Dispose() { lock (Sync) { if (disposed) return; disposed = true; Release(); } }
    }

    public static class WindowsNative
    {
        // Internal, disabled-by-default fault injection used only by the native
        // Windows regression tests.  It is intentionally not part of the public API.
        internal static Action<string> PermissionsMutationTestHook = null;
        internal static Action<string> PublicationDaclTestHook = null;
        internal static string PublicationDaclReadbackSddlTestOverride = null;
        [StructLayout(LayoutKind.Sequential)]
        private struct Information
        {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct BasicInfo { public long Creation, Access, Write, Change; public uint Attributes; }
        [StructLayout(LayoutKind.Sequential)]
        private struct UnicodeString { public ushort Length, MaximumLength; public IntPtr Buffer; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ObjectAttributes
        {
            public int Length;
            public IntPtr RootDirectory, ObjectName;
            public uint Attributes;
            public IntPtr SecurityDescriptor, SecurityQualityOfService;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct IoStatusBlock { public IntPtr Status; public UIntPtr Information; }
        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes { public int Length; public IntPtr Descriptor; public int Inherit; }
        [StructLayout(LayoutKind.Sequential)]
        private struct GenericMapping { public uint Read, Write, Execute, All; }
        [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out Information information);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle, int kind, out BasicInfo information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, ref BasicInfo information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int kind, IntPtr information, uint size);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool FlushFileBuffers(SafeFileHandle handle);
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentThread();
        [DllImport("kernel32.dll", EntryPoint = "CreateDirectoryW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateDirectory(string path, ref SecurityAttributes attributes);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr LocalFree(IntPtr pointer);
        [DllImport("advapi32.dll", EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool ParseDescriptor(string text, uint revision, out IntPtr descriptor, out uint size);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern uint GetSecurityInfo(SafeFileHandle handle, int type, uint information, out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr descriptor);
        [DllImport("advapi32.dll", EntryPoint = "ConvertSecurityDescriptorToStringSecurityDescriptorW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool FormatDescriptor(IntPtr descriptor, uint revision, uint information, out IntPtr text, out uint length);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorDacl(IntPtr descriptor, out bool present, out IntPtr dacl, out bool defaulted);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetSecurityDescriptorControl(IntPtr descriptor, out ushort control, out uint revision);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern uint SetSecurityInfo(SafeFileHandle handle, int type, uint information, IntPtr owner, IntPtr group, IntPtr dacl, IntPtr sacl);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool SetKernelObjectSecurity(SafeFileHandle handle, uint information, IntPtr descriptor);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out SafeAccessTokenHandle token);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool OpenThreadToken(IntPtr thread, uint desiredAccess, bool openAsSelf, out SafeAccessTokenHandle token);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool CreatePrivateObjectSecurityEx(IntPtr parentDescriptor, IntPtr creatorDescriptor, out IntPtr newDescriptor, IntPtr objectType, bool isContainerObject, uint autoInheritFlags, IntPtr token, ref GenericMapping genericMapping);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern bool DestroyPrivateObjectSecurity(ref IntPtr descriptor);
        [DllImport("ntdll.dll")] private static extern int NtOpenFile(out SafeFileHandle handle, uint access, ref ObjectAttributes attributes, out IoStatusBlock status, uint share, uint options);
        [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(SafeFileHandle handle, out IoStatusBlock status, IntPtr information, uint length, int informationClass);
        [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
        private static void Check(bool result, string operation) { if (!result) throw new PlatformWin32Exception(operation, Marshal.GetLastWin32Error()); }
        private static SafeAccessTokenHandle OpenEffectiveToken()
        {
            SafeAccessTokenHandle token;
            if (OpenThreadToken(GetCurrentThread(), 0x0008u, true, out token)) return token; // TOKEN_QUERY
            int error = Marshal.GetLastWin32Error();
            if (token != null) token.Dispose();
            if (error != 1008) throw new PlatformWin32Exception("OpenThreadToken(CreatePrivateObjectSecurityEx)", error); // ERROR_NO_TOKEN
            Check(OpenProcessToken(GetCurrentProcess(), 0x0008u, out token), "OpenProcessToken(CreatePrivateObjectSecurityEx)");
            return token;
        }
        private static SafeFileHandle Open(string path, uint access, uint share, uint disposition)
        {
            SafeFileHandle handle = CreateFile(path, access, share, IntPtr.Zero, disposition, 0x02200000, IntPtr.Zero);
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error(); handle.Dispose(); throw new PlatformWin32Exception("CreateFileW", error);
            }
            return handle;
        }
        private static FileObservation Stat(SafeFileHandle handle)
        {
            bool reparsePoint;
            FileObservation observation = StatEntry(handle, out reparsePoint);
            if (reparsePoint) throw new IOException("Reparse points are forbidden.");
            return observation;
        }
        private static FileObservation StatEntry(SafeFileHandle handle, out bool reparsePoint)
        {
            Information value; Check(GetFileInformationByHandle(handle, out value), "GetFileInformationByHandle");
            reparsePoint = (value.Attributes & 0x400) != 0;
            return new FileObservation { Device = value.Volume, Inode = ((ulong)value.IndexHigh << 32) | value.IndexLow,
                LinkCount = value.Links, Size = ((long)value.SizeHigh << 32) | value.SizeLow,
                Mode = value.Attributes, Kind = (value.Attributes & 0x10) != 0 ? "directory" : "file" };
        }
        // Called only after verified installer-module guards cover EVERY path ancestor.
        // Ownership of guards transfers on success; the PowerShell adapter disposes them on failure.
        public static WindowsLease WrapDirectory(string path, IDisposable[] guards)
        {
            SafeFileHandle handle = Open(path, 0x20081, 3, 3);
            try
            {
                FileObservation value = Stat(handle);
                if (value.Kind != "directory") throw new IOException("Not a directory.");
                return new WindowsLease(handle, path, new List<IDisposable>(guards), null, value);
            }
            catch { handle.Dispose(); throw; }
        }
        public static void CreatePrivateDirectory(string path, string sddl)
        { CreatePrivateDirectory(path, sddl, false); }
        public static void CreatePrivateDirectory(string path, string sddl, bool createOnly)
        {
            IntPtr descriptor; uint size; Check(ParseDescriptor(sddl, 1, out descriptor, out size), "ParseSecurityDescriptor");
            try
            {
                SecurityAttributes attributes = new SecurityAttributes { Length = Marshal.SizeOf(typeof(SecurityAttributes)), Descriptor = descriptor };
                if (!CreateDirectory(path, ref attributes))
                {
                    int error = Marshal.GetLastWin32Error();
                    if (createOnly || error != 183) throw new PlatformWin32Exception("CreateDirectoryW", error);
                }
            }
            finally { LocalFree(descriptor); }
        }
        public static WindowsLease OpenFile(WindowsLease parent, string leaf, string access, string createMode)
        { return OpenFileCore(parent, leaf, access, createMode, 1); }
        // Reacquire a complete no-reparse chain for a receipt's existing runtime.
        // Never create missing directories while validating an existing closure.
        public static WindowsLease OpenPreparationRoot(string path)
        {
            string full = Path.GetFullPath(path);
            if (full.Length < 3 || full[1] != ':' || full[2] != '\\') throw new ArgumentException("A local absolute drive path is required.");
            string root = Path.GetPathRoot(full);
            SafeFileHandle handle = Open(root, 0x80020080, 1, 3);
            WindowsLease current;
            try { current = new WindowsLease(handle, root, null, null, Stat(handle)); }
            catch { handle.Dispose(); throw; }
            try
            {
                string tail = full.Substring(root.Length).TrimEnd('\\');
                if (tail.Length != 0) foreach (string part in PlatformPaths.Segments(tail))
                {
                    WindowsLease next = OpenPreparationDirectory(current, part);
                    current.Dispose(); current = next;
                }
                WindowsLease result = current; current = null; return result;
            }
            finally { if (current != null) current.Dispose(); }
        }
        // Preparation extends the P2 lease chain one component at a time. Deny
        // both write and delete sharing: a held child cannot be renamed/replaced
        // or have a reparse tag installed while a descendant is being written.
        public static WindowsLease OpenPreparationDirectory(WindowsLease parent, string leaf)
        {
            PlatformPaths.Leaf(leaf);
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                string path = Path.Combine(parent.Path, leaf);
                // Include directory data/list access: metadata-only handles do
                // not participate in Windows data/delete sharing arbitration.
                SafeFileHandle handle = Open(path, 0x80020080, 1, 3);
                try
                {
                    FileObservation value = Stat(handle);
                    if (value.Kind != "directory") throw new IOException("Not a directory.");
                    using (SafeFileHandle named = Open(path, 0, 7, 3)) PlatformPaths.Same(value, Stat(named));
                    return new WindowsLease(handle, path, null, parent, value);
                }
                catch { handle.Dispose(); throw; }
            }
        }
        private static WindowsLease OpenFileCore(WindowsLease parent, string leaf, string access, string createMode, uint share)
        {
            PlatformPaths.Leaf(leaf);
            uint desired = access == "Read" ? 0x80000000 : access == "Write" ? 0x40000000 : access == "ReadWrite" ? 0xc0000000 :
                access == "ReadPermissions" ? 0x80040100 : 0; // GENERIC_READ | WRITE_DAC | FILE_WRITE_ATTRIBUTES
            if (desired == 0) throw new ArgumentException("Access must be Read, Write, ReadWrite or ReadPermissions.");
            uint disposition = createMode == "CreateNew" ? 1u : createMode == "OpenExisting" ? 3u : 0u;
            if (disposition == 0) throw new ArgumentException("CreateMode must be CreateNew or OpenExisting.");
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                string path = System.IO.Path.Combine(parent.Path, leaf);
                SafeFileHandle handle = Open(path, desired | 0x20080, share, disposition);
                try
                {
                    FileObservation value = Stat(handle); PlatformPaths.Single(value);
                    using (SafeFileHandle named = Open(path, 0, 7, 3)) PlatformPaths.Same(value, Stat(named));
                    return new WindowsLease(handle, path, null, parent, value) { NewWritable = createMode == "CreateNew" && access != "Read" && access != "ReadPermissions" };
                }
                catch { handle.Dispose(); throw; }
            }
        }
        public static FileObservation AssertIdentity(WindowsLease lease, FileObservation expected, bool single)
        {
            lock (lease.Sync)
            {
                lease.Check(); FileObservation value = Stat(lease.Handle);
                PlatformPaths.Same(value, expected); if (single) PlatformPaths.Single(value);
                using (SafeFileHandle named = Open(lease.Path, 0, 7, 3)) PlatformPaths.Same(value, Stat(named));
                return value;
            }
        }
        public static string GetVerifiedPath(WindowsLease lease)
        {
            AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
            return Path.GetFullPath(lease.Path);
        }
        public static WindowsLease EnterLock(WindowsLease parent, string leaf, string mode, TimeSpan timeout)
        {
            if (timeout < TimeSpan.Zero || (mode != "Shared" && mode != "Exclusive")) throw new ArgumentException("Invalid lock mode or timeout.");
            Stopwatch timer = Stopwatch.StartNew();
            while (true)
            {
                try
                {
                    try { return OpenFileCore(parent, leaf, mode == "Shared" ? "Read" : "ReadWrite", "CreateNew", mode == "Shared" ? 1u : 0u); }
                    catch (PlatformWin32Exception ex)
                    {
                        if (ex.Win32Error != 80 && ex.Win32Error != 183) throw;
                        return OpenFileCore(parent, leaf, mode == "Shared" ? "Read" : "ReadWrite", "OpenExisting", mode == "Shared" ? 1u : 0u);
                    }
                }
                catch (PlatformWin32Exception ex)
                {
                    if (ex.Win32Error != 32 && ex.Win32Error != 33) throw;
                    if (timer.Elapsed >= timeout) throw new TimeoutException("The platform lock deadline expired.");
                    Thread.Sleep((int)Math.Min(20, Math.Max(1, (timeout - timer.Elapsed).TotalMilliseconds)));
                }
            }
        }
        public static WindowsPermissions GetPermissions(WindowsLease lease)
        {
            lock (lease.Sync)
            {
                FileObservation observed = AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
                string sddl = GetDaclSddl(lease.Handle);
                string readbackOverride = PublicationDaclReadbackSddlTestOverride;
                PublicationDaclReadbackSddlTestOverride = null;
                if (!String.IsNullOrEmpty(readbackOverride)) sddl = readbackOverride;
                return new WindowsPermissions { Sddl = sddl, ReadOnly = (observed.Mode & 1) != 0 };
            }
        }
        public static WindowsPermissions GetInheritedFilePermissions(WindowsLease parent)
        {
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                IntPtr owner, group, dacl, sacl, parentDescriptor;
                uint error = GetSecurityInfo(parent.Handle, 1, 7, out owner, out group, out dacl, out sacl, out parentDescriptor);
                if (error != 0) throw new PlatformWin32Exception("GetSecurityInfo(parent inheritance)", (int)error);
                IntPtr inheritedDescriptor = IntPtr.Zero;
                try
                {
                    GenericMapping mapping = new GenericMapping
                    {
                        Read = 0x00120089u,
                        Write = 0x00120116u,
                        Execute = 0x001200a0u,
                        All = 0x001f01ffu
                    };
                    // SEF_DACL_AUTO_INHERIT preserves file inheritance semantics.
                    // SEF_AVOID_PRIVILEGE_CHECK and SEF_AVOID_OWNER_CHECK avoid
                    // requiring privilege/owner authority while calculating a DACL
                    // that will be applied separately.  Owner/group are deliberately
                    // not defaulted from the parent: the effective thread/process token
                    // supplies the creator owner and primary group for CO/CG expansion.
                    Action<string> hook = PublicationDaclTestHook;
                    if (hook != null) hook("before-open-effective-token");
                    SafeAccessTokenHandle token = OpenEffectiveToken();
                    using (token)
                    {
                        if (hook != null) hook("before-create-private-object-security");
                        Check(CreatePrivateObjectSecurityEx(parentDescriptor, IntPtr.Zero, out inheritedDescriptor,
                            IntPtr.Zero, false, 0x19u, token.DangerousGetHandle(), ref mapping), "CreatePrivateObjectSecurityEx(file)");
                    }
                    if (inheritedDescriptor == IntPtr.Zero) throw new IOException("CreatePrivateObjectSecurityEx returned a null descriptor.");
                    return new WindowsPermissions { Sddl = GetDaclSddl(inheritedDescriptor), ReadOnly = false };
                }
                finally
                {
                    try
                    {
                        if (inheritedDescriptor != IntPtr.Zero)
                            Check(DestroyPrivateObjectSecurity(ref inheritedDescriptor), "DestroyPrivateObjectSecurity");
                    }
                    finally { LocalFree(parentDescriptor); }
                }
            }
        }
        private static string GetDaclSddl(SafeFileHandle handle)
        {
            IntPtr owner, group, dacl, sacl, descriptor;
            uint error = GetSecurityInfo(handle, 1, 4, out owner, out group, out dacl, out sacl, out descriptor);
            if (error != 0) throw new PlatformWin32Exception("GetSecurityInfo", (int)error);
            try
            {
                IntPtr text; uint length; Check(FormatDescriptor(descriptor, 1, 4, out text, out length), "FormatSecurityDescriptor");
                try { return Marshal.PtrToStringUni(text); }
                finally { LocalFree(text); }
            }
            finally { LocalFree(descriptor); }
        }
        private static string GetDaclSddl(IntPtr descriptor)
        {
            IntPtr text; uint length; Check(FormatDescriptor(descriptor, 1, 4, out text, out length), "FormatSecurityDescriptor");
            try { return Marshal.PtrToStringUni(text); }
            finally { LocalFree(text); }
        }
        private static uint GetDaclSecurityInformation(IntPtr descriptor)
        {
            ushort control; uint revision;
            Check(GetSecurityDescriptorControl(descriptor, out control, out revision), "GetSecurityDescriptorControl");
            return 4u | ((control & 0x1000) != 0 ? 0x80000000u : 0x20000000u);
        }
        private static void ApplyDaclDescriptor(SafeFileHandle handle, IntPtr descriptor)
        {
            bool present, defaulted; IntPtr dacl;
            Check(GetSecurityDescriptorDacl(descriptor, out present, out dacl, out defaulted), "GetSecurityDescriptorDacl");
            if (!present || dacl == IntPtr.Zero) throw new ArgumentException("An explicit non-null DACL is required.");
            ushort control; uint revision;
            Check(GetSecurityDescriptorControl(descriptor, out control, out revision), "GetSecurityDescriptorControl");
            uint information = GetDaclSecurityInformation(descriptor);
            uint error = SetSecurityInfo(handle, 1, information, IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
            if (error != 0) throw new PlatformWin32Exception("SetSecurityInfo", (int)error);
            // Preserve the descriptor's protected and auto-inherited control flags
            // exactly; SetSecurityInfo may otherwise synthesize the informational AI bit.
            if ((control & 0x0400) == 0)
                Check(SetKernelObjectSecurity(handle, information, descriptor), "SetKernelObjectSecurity");
        }
        public static void ApplyPublicationDacl(WindowsLease lease, string sddl)
        {
            if (String.IsNullOrEmpty(sddl) || !sddl.StartsWith("D:", StringComparison.Ordinal) ||
                sddl.IndexOf("O:", StringComparison.Ordinal) >= 0 ||
                sddl.IndexOf("G:", StringComparison.Ordinal) >= 0 ||
                sddl.IndexOf("S:", StringComparison.Ordinal) >= 0)
                throw new ArgumentException("Only a DACL SDDL policy is supported.", "sddl");
            lock (lease.Sync)
            {
                AssertIdentity(lease, lease.Observation, true);
                IntPtr descriptor; uint size; Check(ParseDescriptor(sddl, 1, out descriptor, out size), "ParseSecurityDescriptor(publication)");
                try
                {
                    bool present, defaulted; IntPtr dacl;
                    Check(GetSecurityDescriptorDacl(descriptor, out present, out dacl, out defaulted), "GetSecurityDescriptorDacl(publication)");
                    if (!present || dacl == IntPtr.Zero) throw new ArgumentException("An explicit non-null DACL is required.", "sddl");
                    Action<string> hook = PublicationDaclTestHook;
                    if (hook != null) hook("before-low-level-dacl-write");
                    // DACL_SECURITY_INFORMATION only.  The descriptor retains P and
                    // every ACE flag; AI is intentionally allowed to clear on readback.
                    Check(SetKernelObjectSecurity(lease.Handle, 4u, descriptor), "SetKernelObjectSecurity(publication DACL)");
                    if (hook != null) hook("after-low-level-dacl-write-before-readback");
                }
                finally { LocalFree(descriptor); }
            }
        }
        public static string NormalizeDaclSddl(string sddl)
        {
            if (String.IsNullOrEmpty(sddl) || !sddl.StartsWith("D:", StringComparison.Ordinal) ||
                sddl.IndexOf("O:", StringComparison.Ordinal) >= 0 ||
                sddl.IndexOf("G:", StringComparison.Ordinal) >= 0 ||
                sddl.IndexOf("S:", StringComparison.Ordinal) >= 0)
                throw new ArgumentException("Only a DACL SDDL policy is supported.", "sddl");
            RawSecurityDescriptor raw = new RawSecurityDescriptor(sddl);
            if (raw.DiscretionaryAcl != null)
            {
                foreach (GenericAce ace in raw.DiscretionaryAcl)
                {
                    KnownAce known = ace as KnownAce;
                    if (known == null) continue;
                    uint mask = unchecked((uint)known.AccessMask);
                    if ((mask & 0x80000000u) != 0) mask |= 0x00120089u; // FILE_GENERIC_READ
                    if ((mask & 0x40000000u) != 0) mask |= 0x00120116u; // FILE_GENERIC_WRITE
                    if ((mask & 0x20000000u) != 0) mask |= 0x001200a0u; // FILE_GENERIC_EXECUTE
                    if ((mask & 0x10000000u) != 0) mask |= 0x001f01ffu; // FILE_ALL_ACCESS
                    known.AccessMask = unchecked((int)(mask & 0x0fffffffu));
                }
            }
            string mappedSddl = raw.GetSddlForm(AccessControlSections.Access);
            IntPtr descriptor; uint size; Check(ParseDescriptor(mappedSddl, 1, out descriptor, out size), "ParseSecurityDescriptor");
            try
            {
                IntPtr text; uint length; Check(FormatDescriptor(descriptor, 1, 4, out text, out length), "FormatSecurityDescriptor");
                try { return Marshal.PtrToStringUni(text); }
                finally { LocalFree(text); }
            }
            finally { LocalFree(descriptor); }
        }
        public static WindowsPermissions SetPermissions(WindowsLease lease, string sddl, bool? readOnly)
        {
            // PowerShell converts an unbound/null string argument to String.Empty.
            if (sddl == String.Empty) sddl = null;
            lock (lease.Sync)
            {
                AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
                // Snapshot/readback needs READ_CONTROL and FILE_READ_ATTRIBUTES.
                // Add only the mutation rights requested by this call; rollback is
                // limited to dimensions whose mutation was started. The original
                // lease retains its deny-write/delete share.
                uint desiredAccess = 0x00020080u;
                if (sddl != null) desiredAccess |= 0x00040000u; // WRITE_DAC
                if (readOnly.HasValue) desiredAccess |= 0x00000100u; // FILE_WRITE_ATTRIBUTES
                using (SafeFileHandle writable = Open(lease.Path, desiredAccess, 7, 3))
                {
                    PlatformPaths.Same(Stat(writable), lease.Observation);
                    IntPtr owner, group, originalDacl, sacl, originalDescriptor;
                    uint snapshotError = GetSecurityInfo(writable, 1, 4, out owner, out group, out originalDacl, out sacl, out originalDescriptor);
                    if (snapshotError != 0) throw new PlatformWin32Exception("GetSecurityInfo", (int)snapshotError);
                    BasicInfo originalBasic; uint basicSize = (uint)Marshal.SizeOf(typeof(BasicInfo));
                    try
                    {
                        Check(GetFileInformationByHandleEx(writable, 0, out originalBasic, basicSize), "GetFileInformationByHandleEx");
                        string originalSddl = GetDaclSddl(originalDescriptor);
                        bool originalReadOnly = (originalBasic.Attributes & 1) != 0;
                        string normalizedSddl = sddl == null ? null : NormalizeDaclSddl(sddl);
                        bool daclMutationStarted = false;
                        bool readOnlyMutationStarted = false;
                        try
                        {
                            if (normalizedSddl != null)
                            {
                                IntPtr descriptor; uint size; Check(ParseDescriptor(normalizedSddl, 1, out descriptor, out size), "ParseSecurityDescriptor");
                                try { daclMutationStarted = true; ApplyDaclDescriptor(writable, descriptor); }
                                finally { LocalFree(descriptor); }
                            }
                            if (readOnly.HasValue)
                            {
                                BasicInfo value = originalBasic;
                                value.Attributes = readOnly.Value ? value.Attributes | 1 : value.Attributes & ~1u;
                                if (value.Attributes == 0) value.Attributes = 0x80;
                                readOnlyMutationStarted = true;
                                Check(SetFileInformationByHandle(writable, 0, ref value, basicSize), "SetFileInformationByHandle");
                            }
                            Action<string> hook = PermissionsMutationTestHook;
                            if ((daclMutationStarted || readOnlyMutationStarted) && hook != null) hook("after-apply-before-readback");
                            string observedSddl = GetDaclSddl(writable);
                            bool observedReadOnly = (Stat(writable).Mode & 1) != 0;
                            if ((normalizedSddl != null && !String.Equals(observedSddl, normalizedSddl, StringComparison.Ordinal)) ||
                                (readOnly.HasValue && observedReadOnly != readOnly.Value))
                                throw new PlatformVerificationException("permissions-snapshot", "windows",
                                    String.Format("Permission readback differs from the requested normalized snapshot (expected '{0}'/{1}, observed '{2}'/{3}).",
                                        normalizedSddl ?? originalSddl, readOnly.HasValue ? readOnly.Value.ToString() : originalReadOnly.ToString(), observedSddl, observedReadOnly));
                        }
                        catch (Exception mutationFailure)
                        {
                            if (!daclMutationStarted && !readOnlyMutationStarted) throw;
                            try
                            {
                                if (daclMutationStarted) ApplyDaclDescriptor(writable, originalDescriptor);
                                if (readOnlyMutationStarted)
                                {
                                    BasicInfo restoreBasic = originalBasic;
                                    Check(SetFileInformationByHandle(writable, 0, ref restoreBasic, basicSize), "SetFileInformationByHandle(restore)");
                                }
                                string restoredSddl = GetDaclSddl(writable);
                                bool restoredReadOnly = (Stat(writable).Mode & 1) != 0;
                                if ((daclMutationStarted && !String.Equals(restoredSddl, originalSddl, StringComparison.Ordinal)) ||
                                    (readOnlyMutationStarted && restoredReadOnly != originalReadOnly))
                                    throw new IOException(String.Format("Rollback readback differs (SDDL '{0}', readOnly {1}).", restoredSddl, restoredReadOnly));
                            }
                            catch (Exception rollbackFailure)
                            {
                                string currentSddl;
                                try { currentSddl = GetDaclSddl(writable); }
                                catch (Exception currentFailure) { currentSddl = "<unavailable: " + currentFailure.Message + ">"; }
                                throw new PlatformVerificationException("permissions-snapshot", "windows",
                                    String.Format("Permission mutation failed and rollback also failed; permissions may have changed. Original SDDL '{0}', current SDDL '{1}'. Mutation: {2} Rollback: {3}",
                                        originalSddl, currentSddl, mutationFailure.Message, rollbackFailure.Message));
                            }
                            throw;
                        }
                    }
                    finally { LocalFree(originalDescriptor); }
                }
                return GetPermissions(lease);
            }
        }

        private static SafeFileHandle OpenRelativeMutationHandle(WindowsLease parent, string leaf, bool writable, bool writeDacl)
        {
            IntPtr nameBuffer = Marshal.StringToHGlobalUni(leaf);
            IntPtr namePointer = IntPtr.Zero;
            try
            {
                UnicodeString name = new UnicodeString
                {
                    Length = checked((ushort)(leaf.Length * 2)),
                    MaximumLength = checked((ushort)((leaf.Length + 1) * 2)),
                    Buffer = nameBuffer
                };
                namePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
                Marshal.StructureToPtr(name, namePointer, false);
                ObjectAttributes attributes = new ObjectAttributes
                {
                    Length = Marshal.SizeOf(typeof(ObjectAttributes)),
                    RootDirectory = parent.Handle.DangerousGetHandle(),
                    ObjectName = namePointer,
                    Attributes = 0x40
                };
                IoStatusBlock ioStatus;
                SafeFileHandle handle;
                // GENERIC_READ | optional GENERIC_WRITE | SYNCHRONIZE | DELETE |
                // FILE_READ_ATTRIBUTES.  Publication stage handles require write access
                // so FlushFileBuffers remains valid after the handle-bound rename.
                // share read only; synchronous, non-directory, and open the reparse point itself.
                uint desired = 0x80110080u | (writable ? 0x40000000u : 0u) | (writeDacl ? 0x00040000u : 0u);
                int status = NtOpenFile(out handle, desired, ref attributes, out ioStatus, 1, 0x00200060);
                if (status < 0)
                {
                    uint error = RtlNtStatusToDosError(status);
                    if (handle != null) handle.Dispose();
                    throw new PlatformWin32Exception("NtOpenFile(relative mutation file)", unchecked((int)error));
                }
                return handle;
            }
            finally
            {
                if (namePointer != IntPtr.Zero) Marshal.FreeHGlobal(namePointer);
                Marshal.FreeHGlobal(nameBuffer);
            }
        }

        private static WindowsLease OpenMutationFileCore(WindowsLease parent, string leaf, ulong expectedDevice, ulong expectedFileId, bool verifyIdentity, bool allowMissing, bool writable, bool writeDacl)
        {
            PlatformPaths.Leaf(leaf);
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                SafeFileHandle handle;
                try { handle = OpenRelativeMutationHandle(parent, leaf, writable, writeDacl); }
                catch (PlatformWin32Exception ex) { if (allowMissing && (ex.Win32Error == 2 || ex.Win32Error == 3)) return null; throw; }
                try
                {
                    FileObservation value = Stat(handle); PlatformPaths.Single(value);
                    if (value.Kind != "file") throw new IOException("A regular file is required.");
                    if (verifyIdentity && (value.Device != expectedDevice || value.Inode != expectedFileId))
                        throw new IOException("The mutation file identity differs from the expected volume serial or file ID.");
                    return new WindowsLease(handle, Path.Combine(parent.Path, leaf), null, parent, value);
                }
                catch { handle.Dispose(); throw; }
            }
        }

        public static WindowsLease OpenMutationFile(WindowsLease parent, string leaf, ulong expectedDevice, ulong expectedFileId)
        { return OpenMutationFileCore(parent, leaf, expectedDevice, expectedFileId, true, false, false, false); }

        public static WindowsLease OpenWritableMutationFile(WindowsLease parent, string leaf, ulong expectedDevice, ulong expectedFileId)
        { return OpenMutationFileCore(parent, leaf, expectedDevice, expectedFileId, true, false, true, false); }

        public static WindowsLease OpenPermissionMutationFile(WindowsLease parent, string leaf, ulong expectedDevice, ulong expectedFileId)
        { return OpenMutationFileCore(parent, leaf, expectedDevice, expectedFileId, true, false, false, true); }

        public static WindowsLease OpenPublicationStageFile(WindowsLease parent, string leaf, ulong expectedDevice, ulong expectedFileId)
        { return OpenMutationFileCore(parent, leaf, expectedDevice, expectedFileId, true, false, true, true); }

        public static WindowsLease TryOpenMutationFile(WindowsLease parent, string leaf)
        { return OpenMutationFileCore(parent, leaf, 0, 0, false, true, false, false); }

        public static WindowsLease TryOpenMutationFile(WindowsLease parent, string leaf, ulong expectedDevice, ulong expectedFileId)
        { return OpenMutationFileCore(parent, leaf, expectedDevice, expectedFileId, true, true, false, false); }

        private static SafeFileHandle OpenRelativeEntryHandle(WindowsLease parent, string leaf, uint access, uint share, bool directoryOnly, string operation)
        {
            IntPtr nameBuffer = Marshal.StringToHGlobalUni(leaf);
            IntPtr namePointer = IntPtr.Zero;
            try
            {
                UnicodeString name = new UnicodeString
                {
                    Length = checked((ushort)(leaf.Length * 2)),
                    MaximumLength = checked((ushort)((leaf.Length + 1) * 2)),
                    Buffer = nameBuffer
                };
                namePointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UnicodeString)));
                Marshal.StructureToPtr(name, namePointer, false);
                ObjectAttributes attributes = new ObjectAttributes
                {
                    Length = Marshal.SizeOf(typeof(ObjectAttributes)),
                    RootDirectory = parent.Handle.DangerousGetHandle(),
                    ObjectName = namePointer,
                    Attributes = 0x40
                };
                IoStatusBlock ioStatus;
                SafeFileHandle handle;
                uint options = 0x00200020u | (directoryOnly ? 0x00000001u : 0u);
                int status = NtOpenFile(out handle, access, ref attributes, out ioStatus, share, options);
                if (status < 0)
                {
                    uint error = RtlNtStatusToDosError(status);
                    if (handle != null) handle.Dispose();
                    throw new PlatformWin32Exception(operation, unchecked((int)error));
                }
                return handle;
            }
            finally
            {
                if (namePointer != IntPtr.Zero) Marshal.FreeHGlobal(namePointer);
                Marshal.FreeHGlobal(nameBuffer);
            }
        }

        private static SafeFileHandle OpenRelativeOwnedEntryHandle(WindowsLease parent, string leaf, bool directoryOnly)
        {
            // DELETE | SYNCHRONIZE | FILE_READ_ATTRIBUTES | FILE_WRITE_ATTRIBUTES;
            // deny-delete sharing while the entry is classified and mutated.
            // OPEN_REPARSE_POINT makes a junction/symlink itself the deletion target.
            return OpenRelativeEntryHandle(parent, leaf, 0x00110180u, 3, directoryOnly, "NtOpenFile(relative owned entry)");
        }

        private static SafeFileHandle OpenRelativeInventoryEntryHandle(WindowsLease parent, string leaf)
        {
            // GENERIC_READ | SYNCHRONIZE | FILE_READ_ATTRIBUTES with read-only
            // sharing keeps each opened entry stable while its bytes and descendants
            // are inventoried. OPEN_REPARSE_POINT prevents traversal through links.
            return OpenRelativeEntryHandle(parent, leaf, 0x80100080u, 1, false, "NtOpenFile(relative directory inventory entry)");
        }

        private sealed class DirectoryInventoryEntry
        {
            internal string Path;
            internal string Sha256;
            internal long Length;
        }

        private static string ComputeHandleSha256(SafeFileHandle handle)
        {
            using (var borrowed = new SafeFileHandle(handle.DangerousGetHandle(), false))
            using (var stream = new FileStream(borrowed, FileAccess.Read))
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
        }

        private static List<string> EnumerateChildLeaves(WindowsLease directory)
        {
            var leaves = new List<string>();
            foreach (string childPath in Directory.EnumerateFileSystemEntries(directory.Path))
            {
                string leaf = Path.GetFileName(childPath);
                PlatformPaths.Leaf(leaf);
                leaves.Add(leaf);
            }
            leaves.Sort(StringComparer.Ordinal);
            return leaves;
        }

        private static void CollectDirectoryInventory(WindowsLease directory, string prefix,
            List<DirectoryInventoryEntry> inventory, List<WindowsLease> retained)
        {
            FileObservation directoryObservation = AssertIdentity(directory, directory.Observation, false);
            if (directoryObservation.Kind != "directory") throw new IOException("A non-reparse directory is required.");
            List<string> before = EnumerateChildLeaves(directory);
            foreach (string leaf in before)
            {
                SafeFileHandle handle = OpenRelativeInventoryEntryHandle(directory, leaf);
                WindowsLease entry = null;
                try
                {
                    bool reparsePoint;
                    FileObservation observation = StatEntry(handle, out reparsePoint);
                    if (reparsePoint) throw new IOException("Directory inventory must not cross a reparse point.");
                    entry = new WindowsLease(handle, Path.Combine(directory.Path, leaf), null, directory, observation);
                    handle = null;
                    retained.Add(entry);
                    string relativePath = prefix + leaf;
                    if (observation.Kind == "directory")
                    {
                        inventory.Add(new DirectoryInventoryEntry {
                            Path = relativePath + "/",
                            Sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
                            Length = 0
                        });
                        CollectDirectoryInventory(entry, relativePath + "/", inventory, retained);
                    }
                    else
                    {
                        if (observation.Kind != "file") throw new IOException("Directory inventory contains a non-regular file.");
                        if (observation.LinkCount > 1) throw new IOException("Directory inventory contains a multiply-linked file.");
                        inventory.Add(new DirectoryInventoryEntry {
                            Path = relativePath,
                            Sha256 = ComputeHandleSha256(entry.Handle),
                            Length = observation.Size
                        });
                    }
                }
                finally
                {
                    if (handle != null) handle.Dispose();
                }
            }
            List<string> after = EnumerateChildLeaves(directory);
            if (before.Count != after.Count) throw new IOException("Directory contents changed while inventory was being captured.");
            for (int i = 0; i < before.Count; i++)
                if (!StringComparer.Ordinal.Equals(before[i], after[i]))
                    throw new IOException("Directory contents changed while inventory was being captured.");
        }

        private static WindowsDirectoryState ComputeDirectoryState(WindowsLease directory)
        {
            var inventory = new List<DirectoryInventoryEntry>();
            var retained = new List<WindowsLease>();
            try
            {
                FileObservation root = AssertIdentity(directory, directory.Observation, false);
                if (root.Kind != "directory") throw new IOException("A non-reparse directory is required.");
                CollectDirectoryInventory(directory, String.Empty, inventory, retained);
                inventory.Sort(delegate(DirectoryInventoryEntry first, DirectoryInventoryEntry second) {
                    return StringComparer.Ordinal.Compare(first.Path, second.Path);
                });
                var canonical = new System.Text.StringBuilder();
                foreach (DirectoryInventoryEntry entry in inventory)
                    canonical.Append(entry.Path).Append('\t').Append(entry.Sha256).Append('\n');
                byte[] bytes = new System.Text.UTF8Encoding(false).GetBytes(canonical.ToString());
                using (var sha = SHA256.Create())
                    return new WindowsDirectoryState {
                        Observation = root,
                        InventorySha256 = BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant(),
                        EntryCount = inventory.Count
                    };
            }
            finally
            {
                for (int i = retained.Count - 1; i >= 0; i--) retained[i].Dispose();
            }
        }

        public static WindowsDirectoryState GetDirectoryState(WindowsLease directory)
        {
            lock (directory.Sync)
            {
                directory.Check();
                return ComputeDirectoryState(directory);
            }
        }

        public static WindowsDirectoryState TryGetDirectoryState(WindowsLease parent, string leaf)
        {
            PlatformPaths.Leaf(leaf);
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                SafeFileHandle handle;
                try { handle = OpenRelativeInventoryEntryHandle(parent, leaf); }
                catch (PlatformWin32Exception ex) { if (ex.Win32Error == 2 || ex.Win32Error == 3) return null; throw; }
                WindowsLease directory = null;
                try
                {
                    FileObservation observation = Stat(handle);
                    if (observation.Kind != "directory") throw new IOException("A non-reparse directory is required.");
                    directory = new WindowsLease(handle, Path.Combine(parent.Path, leaf), null, parent, observation);
                    handle = null;
                    return ComputeDirectoryState(directory);
                }
                finally
                {
                    if (directory != null) directory.Dispose();
                    if (handle != null) handle.Dispose();
                }
            }
        }

        public static WindowsLease OpenMutationDirectory(WindowsLease parent, string leaf, ulong expectedDevice, ulong expectedFileId)
        {
            PlatformPaths.Leaf(leaf);
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                SafeFileHandle handle = OpenRelativeOwnedEntryHandle(parent, leaf, true);
                try
                {
                    FileObservation value = Stat(handle);
                    if (value.Kind != "directory") throw new IOException("A non-reparse directory is required.");
                    if (value.Device != expectedDevice || value.Inode != expectedFileId)
                        throw new IOException("The mutation directory identity differs from the expected volume serial or file ID.");
                    return new WindowsLease(handle, Path.Combine(parent.Path, leaf), null, parent, value);
                }
                catch { handle.Dispose(); throw; }
            }
        }

        public static WindowsLease OpenValidationFile(WindowsLease parent, string leaf)
        {
            PlatformPaths.Leaf(leaf);
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                string path = Path.Combine(parent.Path, leaf);
                SafeFileHandle handle = Open(path, 0x80020080, 7, 3);
                try
                {
                    FileObservation value = Stat(handle); PlatformPaths.Single(value);
                    if (value.Kind != "file") throw new IOException("A regular file is required.");
                    return new WindowsLease(handle, path, null, parent, value);
                }
                catch { handle.Dispose(); throw; }
            }
        }

        public static string ComputeSha256(WindowsLease lease)
        {
            lock (lease.Sync)
            {
                lease.Check(); AssertIdentity(lease, lease.Observation, true);
                using (var borrowed = new SafeFileHandle(lease.Handle.DangerousGetHandle(), false))
                using (var stream = new FileStream(borrowed, FileAccess.Read))
                using (var sha = SHA256.Create())
                {
                    stream.Position = 0;
                    return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "").ToLowerInvariant();
                }
            }
        }

        public static void RenameNoReplace(WindowsLease lease, WindowsLease destinationParent, string destinationLeaf)
        {
            PlatformPaths.Leaf(destinationLeaf);
            lock (lease.Sync)
            lock (destinationParent.Sync)
            {
                lease.Check(); destinationParent.Check();
                AssertIdentity(lease, lease.Observation, true);
                AssertIdentity(destinationParent, destinationParent.Observation, false);
                if (lease.Observation.Device != destinationParent.Observation.Device)
                    throw new PlatformWin32Exception("SetFileInformationByHandle(FileRenameInfo)", 17);
                string destinationPath = Path.Combine(destinationParent.Path, destinationLeaf);
                // SetFileInformationByHandle does not consistently accept the native
                // RootDirectory-relative form used by NtSetInformationFile.  Keep the
                // source handle-bound and supply the destination as an NT DOS-device path.
                byte[] name = System.Text.Encoding.Unicode.GetBytes(@"\??\" + destinationPath);
                int rootOffset = IntPtr.Size == 8 ? 8 : 4;
                int lengthOffset = rootOffset + IntPtr.Size;
                int nameOffset = lengthOffset + 4;
                int bufferLength = nameOffset + name.Length + 2;
                IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
                try
                {
                    for (int i = 0; i < bufferLength; i++) Marshal.WriteByte(buffer, i, 0);
                    Marshal.WriteInt32(buffer, 0, 0);
                    Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
                    Marshal.WriteInt32(buffer, lengthOffset, name.Length);
                    Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
                    if (!SetFileInformationByHandle(lease.Handle, 3, buffer, (uint)bufferLength))
                        throw new PlatformWin32Exception("SetFileInformationByHandle(FileRenameInfo NoReplace)", Marshal.GetLastWin32Error());
                    lease.Path = destinationPath;
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }

        public static void RenameDirectoryNoReplace(WindowsLease lease, WindowsLease destinationParent, string destinationLeaf)
        {
            PlatformPaths.Leaf(destinationLeaf);
            lock (lease.Sync)
            lock (destinationParent.Sync)
            {
                lease.Check(); destinationParent.Check();
                FileObservation source = AssertIdentity(lease, lease.Observation, false);
                if (source.Kind != "directory") throw new IOException("A non-reparse directory is required.");
                AssertIdentity(destinationParent, destinationParent.Observation, false);
                if (source.Device != destinationParent.Observation.Device)
                    throw new PlatformWin32Exception("SetFileInformationByHandle(FileRenameInfo directory)", 17);

                byte[] name = System.Text.Encoding.Unicode.GetBytes(destinationLeaf);
                int rootOffset = IntPtr.Size == 8 ? 8 : 4;
                int lengthOffset = rootOffset + IntPtr.Size;
                int nameOffset = lengthOffset + 4;
                int bufferLength = nameOffset + name.Length + 2;
                IntPtr buffer = Marshal.AllocHGlobal(bufferLength);
                try
                {
                    for (int i = 0; i < bufferLength; i++) Marshal.WriteByte(buffer, i, 0);
                    Marshal.WriteInt32(buffer, 0, 0); // ReplaceIfExists = FALSE
                    Marshal.WriteIntPtr(buffer, rootOffset, destinationParent.Handle.DangerousGetHandle());
                    Marshal.WriteInt32(buffer, lengthOffset, name.Length);
                    Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
                    IoStatusBlock ioStatus;
                    int status = NtSetInformationFile(lease.Handle, out ioStatus, buffer, (uint)bufferLength, 10); // FileRenameInformation
                    if (status < 0)
                        throw new PlatformWin32Exception("NtSetInformationFile(FileRenameInformation directory NoReplace)", unchecked((int)RtlNtStatusToDosError(status)));
                    lease.Path = Path.Combine(destinationParent.Path, destinationLeaf);
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }

        private static void MarkEntryDeleteOnClose(SafeFileHandle handle)
        {
            IntPtr buffer = Marshal.AllocHGlobal(4);
            try
            {
                const int deleteFlags = 0x00000001 | 0x00000002 | 0x00000010;
                Marshal.WriteInt32(buffer, deleteFlags);
                if (SetFileInformationByHandle(handle, 21, buffer, 4)) return;
                int error = Marshal.GetLastWin32Error();
                if (error != 87 && error != 50)
                    throw new PlatformWin32Exception("SetFileInformationByHandle(FileDispositionInfoEx owned tree)", error);

                BasicInfo basic;
                Check(GetFileInformationByHandleEx(handle, 0, out basic, (uint)Marshal.SizeOf(typeof(BasicInfo))), "GetFileInformationByHandleEx(FileBasicInfo owned tree)");
                if ((basic.Attributes & 1u) != 0)
                {
                    basic.Attributes &= ~1u;
                    if (basic.Attributes == 0) basic.Attributes = 0x80u; // FILE_ATTRIBUTE_NORMAL
                    Check(SetFileInformationByHandle(handle, 0, ref basic, (uint)Marshal.SizeOf(typeof(BasicInfo))), "SetFileInformationByHandle(FileBasicInfo clear readonly owned tree)");
                }
                Marshal.WriteInt32(buffer, 1);
                if (!SetFileInformationByHandle(handle, 4, buffer, 4))
                    throw new PlatformWin32Exception("SetFileInformationByHandle(FileDispositionInfo owned tree)", Marshal.GetLastWin32Error());
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static void DeleteOwnedEntry(WindowsLease parent, string leaf, string relativePath, bool requireDirectory, bool verifyExpectedIdentity, ulong expectedDevice, ulong expectedFileId, ref int removedEntryCount, ref string remainingPath)
        {
            PlatformPaths.Leaf(leaf);
            remainingPath = relativePath;
            SafeFileHandle handle = OpenRelativeOwnedEntryHandle(parent, leaf, false);
            WindowsLease entry = null;
            bool deleteMarked = false;
            try
            {
                bool reparsePoint;
                FileObservation observation = StatEntry(handle, out reparsePoint);
                if (requireDirectory && (reparsePoint || observation.Kind != "directory"))
                    throw new IOException("The owned-tree root must be a non-reparse directory.");
                if (verifyExpectedIdentity && (observation.Device != expectedDevice || observation.Inode != expectedFileId))
                    throw new IOException("The owned-tree root identity differs from ExpectedIdentity.");
                if (!reparsePoint && observation.Kind != "directory" && observation.LinkCount != 1)
                    throw new IOException("Owned directory tree cleanup requires every non-reparse file to have exactly one link before mutation.");
                entry = new WindowsLease(handle, Path.Combine(parent.Path, leaf), null, parent, observation);
                handle = null;
                if (!reparsePoint && observation.Kind == "directory")
                {
                    foreach (string childPath in Directory.EnumerateFileSystemEntries(entry.Path))
                    {
                        string childLeaf = Path.GetFileName(childPath);
                        PlatformPaths.Leaf(childLeaf);
                        DeleteOwnedEntry(entry, childLeaf, relativePath + "\\" + childLeaf, false, false, 0, 0, ref removedEntryCount, ref remainingPath);
                    }
                    foreach (string unexpected in Directory.EnumerateFileSystemEntries(entry.Path))
                        throw new IOException("A directory entry appeared during owned-tree cleanup: " + unexpected);
                    AssertIdentity(entry, observation, false);
                }
                else if (!reparsePoint)
                {
                    AssertIdentity(entry, observation, false);
                }
                MarkEntryDeleteOnClose(entry.Handle);
                deleteMarked = true;
            }
            finally
            {
                if (entry != null) entry.Dispose();
                if (handle != null) handle.Dispose();
            }
            if (deleteMarked) removedEntryCount++;
        }

        public static int DeleteOwnedDirectoryTree(WindowsLease parent, string leaf, ulong expectedDevice, ulong expectedFileId)
        {
            PlatformPaths.Leaf(leaf);
            lock (parent.Sync)
            {
                parent.Check(); AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                int removedEntryCount = 0;
                string remainingPath = leaf;
                try
                {
                    DeleteOwnedEntry(parent, leaf, leaf, true, true, expectedDevice, expectedFileId, ref removedEntryCount, ref remainingPath);
                    return removedEntryCount;
                }
                catch (Exception failure)
                {
                    throw new IOException(String.Format(
                        "Owned directory tree cleanup stopped after deleting {0} entries; remaining path '{1}'. {2}",
                        removedEntryCount, remainingPath, failure.Message), failure);
                }
            }
        }

        public static void Flush(WindowsLease lease)
        {
            lock (lease.Sync)
            {
                lease.Check(); AssertIdentity(lease, lease.Observation, true);
                Check(FlushFileBuffers(lease.Handle), "FlushFileBuffers");
            }
        }

        public static void FlushDirectory(WindowsLease lease)
        {
            lock (lease.Sync)
            {
                lease.Check(); AssertIdentity(lease, lease.Observation, false);
                if (lease.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                // Do not widen the long-lived lease.  Open a short-lived dedicated
                // directory handle with write/add-file access, permissive sharing,
                // backup semantics, and open-reparse-point behavior; then bind it
                // back to the verified lease identity before probing or flushing.
                using (SafeFileHandle writable = Open(lease.Path, 0x40000082u, 7, 3))
                {
                    FileObservation observed = Stat(writable);
                    PlatformPaths.Same(observed, lease.Observation);
                    if (observed.Kind != "directory") throw new IOException("A directory lease is required.");
                    Check(FlushFileBuffers(writable), "FlushFileBuffers(directory)");
                }
            }
        }

        public static void DeleteOnClose(WindowsLease lease)
        {
            lock (lease.Sync)
            {
                lease.Check(); AssertIdentity(lease, lease.Observation, true);
                IntPtr buffer = Marshal.AllocHGlobal(4);
                try
                {
                    Marshal.WriteInt32(buffer, 1);
                    if (!SetFileInformationByHandle(lease.Handle, 4, buffer, 4))
                        throw new PlatformWin32Exception("SetFileInformationByHandle(FileDispositionInfo)", Marshal.GetLastWin32Error());
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
        }
    }
}
