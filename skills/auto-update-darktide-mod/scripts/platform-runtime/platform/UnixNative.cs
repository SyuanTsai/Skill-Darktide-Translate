// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.IO;
using System.Collections.Generic;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    // Only observations cross the evidence boundary. No public fd/HANDLE property.
    public sealed class FileObservation
    {
        public ulong Device { get; internal set; }
        public ulong Inode { get; internal set; }
        public uint Mode { get; internal set; }
        public ulong LinkCount { get; internal set; }
        public uint Uid { get; internal set; }
        public uint Gid { get; internal set; }
        public uint Flags { get; internal set; }
        public long Size { get; internal set; }
        public string Kind { get; internal set; }
    }

    public sealed class UnixPermissionSnapshot
    {
        public string Kind { get { return "unix-mode"; } }
        public string Mode { get; internal set; }
        public ulong Uid { get; internal set; }
        public ulong Gid { get; internal set; }
    }

    public sealed class UnixFlushReceipt
    {
        public string File { get; internal set; }
        public string ParentDirectory { get; internal set; }
        public string TransactionDirectory { get; internal set; }
        public string Durability { get; internal set; }
    }

    public sealed class UnixPublicationResult
    {
        public FileObservation AppliedIdentity { get; internal set; }
        public FileObservation DisplacedIdentity { get; internal set; }
        public UnixPermissionSnapshot Permissions { get; internal set; }
        public string DisplacedLeaf { get; internal set; }
        public string[] CompletedSteps { get; internal set; }
        public UnixFlushReceipt Flush { get; internal set; }
    }

    public sealed class UnixRemovalResult
    {
        public FileObservation BackupIdentity { get; internal set; }
        public UnixPermissionSnapshot Permissions { get; internal set; }
        public string TombstoneLeaf { get; internal set; }
        public string Method { get; internal set; }
        public string[] CompletedSteps { get; internal set; }
        public UnixFlushReceipt Flush { get; internal set; }
    }

    internal sealed class SafeFd : SafeHandle
    {
        internal SafeFd(int fd) : base(new IntPtr(-1), true) { SetHandle(new IntPtr(fd)); }
        public override bool IsInvalid { get { return handle.ToInt64() < 0; } }
        // Do not retry close on EINTR: the descriptor may already have been reused.
        protected override bool ReleaseHandle() { return UnixNative.Close(handle.ToInt32()) == 0; }
    }

    public sealed class UnixLease : IDisposable
    {
        internal readonly object Sync = new object();
        internal SafeFd Fd;
        internal SafeFd Parent;
        internal string Leaf;
        internal string Path;
        internal bool Locked;
        public FileObservation Observation { get; internal set; }
        public string Name { get { return Leaf; } }
        internal bool NewWritable;
        public byte[] ReadAllBytes(int maximumBytes)
        {
            lock (Sync)
            {
                Check(); UnixNative.AssertIdentity(this, Observation, true);
                byte[] bytes = UnixNative.ReadLeaseBytes(Fd, maximumBytes);
                UnixNative.AssertIdentity(this, Observation, true); return bytes;
            }
        }
        internal byte[] ReadRetainedBytes(int maximumBytes)
        {
            lock (Sync)
            {
                Check(); UnixNative.AssertRetainedIdentity(this, Observation);
                byte[] bytes = UnixNative.ReadLeaseBytes(Fd, maximumBytes);
                UnixNative.AssertRetainedIdentity(this, Observation); return bytes;
            }
        }
        public void WriteNewBytes(byte[] bytes)
        {
            lock (Sync)
            {
                Check(); UnixNative.AssertIdentity(this, Observation, true);
                if (!NewWritable) throw new InvalidOperationException("A fresh create-only writable lease is required.");
                NewWritable = false; UnixNative.WriteNewLeaseBytes(Fd, bytes);
                UnixNative.AssertIdentity(this, Observation, true);
            }
        }
        internal UnixLease(SafeFd fd, SafeFd parent, string leaf, string path, FileObservation observation)
        { Fd = fd; Parent = parent; Leaf = leaf; Path = path; Observation = observation; }
        internal void Check() { if (Fd == null || Fd.IsClosed) throw new ObjectDisposedException("UnixLease"); }
        public void Dispose()
        {
            lock (Sync)
            {
                if (Fd == null) return;
                try { if (Locked) UnixNative.Unlock(Fd); }
                finally { Fd.Dispose(); if (Parent != null) Parent.Dispose(); Fd = null; Parent = null; }
            }
        }
    }

    public static class PlatformPaths
    {
        public static string[] Segments(string relative)
        {
            if (String.IsNullOrWhiteSpace(relative) || relative.IndexOf('\0') >= 0 ||
                relative.IndexOf(':') >= 0 || relative.StartsWith("/") || relative.StartsWith("\\"))
                throw new ArgumentException("A nonempty relative path is required.");
            string[] parts = relative.Replace('\\', '/').Split('/');
            foreach (string part in parts) Leaf(part);
            return parts;
        }
        public static void Leaf(string leaf)
        {
            if (String.IsNullOrWhiteSpace(leaf) || leaf == "." || leaf == ".." ||
                leaf.IndexOfAny(new char[] { '/', '\\', ':', '\0' }) >= 0)
                throw new ArgumentException("An ordinary single path component is required.");
            if (PlatformNative.GetOperatingSystem() == "windows" &&
                (leaf.EndsWith(".") || leaf.EndsWith(" ") || leaf.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0))
                throw new ArgumentException("Ambiguous Windows component.");
            if (PlatformNative.GetOperatingSystem() == "windows")
            {
                string stem = leaf.Split('.')[0].ToUpperInvariant();
                if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
                    stem == "CONIN$" || stem == "CONOUT$" ||
                    System.Text.RegularExpressions.Regex.IsMatch(stem, "^(COM|LPT)[0-9\u00b9\u00b2\u00b3]$"))
                    throw new ArgumentException("Windows device names are forbidden.");
            }
        }
        public static bool IsTransactionStoreTarget(string parentPath, string leaf)
        {
            if (String.IsNullOrWhiteSpace(parentPath)) throw new ArgumentException("A verified parent path is required.");
            Leaf(leaf);
            if (String.Equals(leaf, ".ai-instructions-txn", StringComparison.OrdinalIgnoreCase)) return true;
            string[] segments = parentPath.Split(new char[] { '/', '\\' }, StringSplitOptions.RemoveEmptyEntries);
            foreach (string segment in segments)
                if (String.Equals(segment, ".ai-instructions-txn", StringComparison.OrdinalIgnoreCase)) return true;
            return false;
        }
        internal static void Same(FileObservation actual, FileObservation expected)
        {
            if (expected == null || actual.Device != expected.Device || actual.Inode != expected.Inode || actual.Kind != expected.Kind)
                throw new IOException("The file identity or type changed.");
        }
        internal static void Single(FileObservation value)
        {
            if (value.Kind != "file" || value.LinkCount != 1)
                throw new IOException("A regular file with exactly one link is required.");
        }
    }

    public static class UnixNative
    {
        // Explicit ABI records. Linux x86_64: glibc bits/struct_stat.h (144 bytes).
        // Linux aarch64: asm-generic/stat.h (128 bytes). Darwin: stat64 (144 bytes).
        // Darwin x64 calls the INODE64 symbol; arm64 uses the native 64-bit inode ABI.
        [StructLayout(LayoutKind.Explicit, Size = 144)]
        private struct LinuxX64Stat
        {
            [FieldOffset(0)] public ulong Dev; [FieldOffset(8)] public ulong Ino;
            [FieldOffset(16)] public ulong Nlink; [FieldOffset(24)] public uint Mode;
            [FieldOffset(28)] public uint Uid; [FieldOffset(32)] public uint Gid;
            [FieldOffset(48)] public long Size;
        }
        [StructLayout(LayoutKind.Explicit, Size = 128)]
        private struct LinuxArm64Stat
        {
            [FieldOffset(0)] public ulong Dev; [FieldOffset(8)] public ulong Ino;
            [FieldOffset(16)] public uint Mode; [FieldOffset(20)] public uint Nlink;
            [FieldOffset(24)] public uint Uid; [FieldOffset(28)] public uint Gid;
            [FieldOffset(48)] public long Size;
        }
        [StructLayout(LayoutKind.Explicit, Size = 144)]
        private struct DarwinStat
        {
            [FieldOffset(0)] public uint Dev; [FieldOffset(4)] public ushort Mode;
            [FieldOffset(6)] public ushort Nlink; [FieldOffset(8)] public ulong Ino;
            [FieldOffset(16)] public uint Uid; [FieldOffset(20)] public uint Gid;
            [FieldOffset(96)] public long Size;
            [FieldOffset(116)] public uint Flags;
        }
        private static class Linux
        {
            [DllImport("libc", SetLastError = true)] internal static extern int openat(int fd, string name, int flags, uint mode);
            [DllImport("libc", SetLastError = true)] internal static extern int mkdirat(SafeFd fd, string name, uint mode);
            [DllImport("libc", SetLastError = true)] internal static extern int fstat(SafeFd fd, IntPtr stat);
            [DllImport("libc", SetLastError = true)] internal static extern int fstatat(SafeFd fd, string name, IntPtr stat, int flags);
            [DllImport("libc", SetLastError = true)] internal static extern int flock(SafeFd fd, int operation);
            [DllImport("libc", SetLastError = true)] internal static extern int fchmod(SafeFd fd, uint mode);
            [DllImport("libc", SetLastError = true)] internal static extern int fchown(SafeFd fd, uint uid, uint gid);
            [DllImport("libc", SetLastError = true)] internal static extern int fsync(SafeFd fd);
            [DllImport("libc", SetLastError = true)] internal static extern int renameat(SafeFd oldDirectory, string oldName, SafeFd newDirectory, string newName);
            [DllImport("libc", SetLastError = true)] internal static extern int renameat2(SafeFd oldDirectory, string oldName, SafeFd newDirectory, string newName, uint flags);
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr fgetxattr(SafeFd fd, string name, IntPtr value, UIntPtr size);
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr flistxattr(SafeFd fd, IntPtr list, UIntPtr size);
            [DllImport("libc", SetLastError = true)] internal static extern int ioctl(SafeFd fd, UIntPtr request, IntPtr argument);
            [DllImport("libc", SetLastError = true)] internal static extern int close(int fd);
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr write(SafeFd fd, IntPtr buffer, UIntPtr count);
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr read(SafeFd fd, IntPtr buffer, UIntPtr count);
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr pread(SafeFd fd, IntPtr buffer, UIntPtr count, long offset);
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr pwrite(SafeFd fd, IntPtr buffer, UIntPtr count, long offset);
            [DllImport("libc", SetLastError = true)] internal static extern int unlinkat(SafeFd fd, string name, int flags);
            [DllImport("libc", SetLastError = true)] internal static extern int linkat(SafeFd fd, string name, SafeFd other, string link, int flags);
            [DllImport("libc", SetLastError = true)] internal static extern int symlinkat(string target, SafeFd fd, string name);
            [DllImport("libc", SetLastError = true)] internal static extern int fcntl(SafeFd fd, int command);
            [DllImport("libc", SetLastError = true)] internal static extern uint geteuid();
            [DllImport("libc", SetLastError = true)] internal static extern IntPtr gnu_get_libc_version();
        }
        private static class Darwin
        {
            private const string Lib = "/usr/lib/libSystem.B.dylib";
            [DllImport(Lib, SetLastError = true)] internal static extern int openat(int fd, string name, int flags, uint mode);
            // Apple arm64 puts variadic arguments on the stack, unlike fixed arguments.
            // Fill x3..x7 so the ninth fixed argument occupies the first stack slot
            // consumed by openat's va_arg(mode_t). We pass ONLY zero here; fchmod
            // applies the requested mode through a non-variadic, handle-bound call.
            [DllImport(Lib, EntryPoint = "openat", SetLastError = true)]
            internal static extern int openatArm64Create(int fd, string name, int flags,
                IntPtr x3, IntPtr x4, IntPtr x5, IntPtr x6, IntPtr x7, uint stackMode);
            [DllImport(Lib, SetLastError = true)] internal static extern int mkdirat(SafeFd fd, string name, uint mode);
            [DllImport(Lib, SetLastError = true)] internal static extern int fstat(SafeFd fd, IntPtr stat);
            [DllImport(Lib, EntryPoint = "fstat$INODE64", SetLastError = true)] internal static extern int fstat64(SafeFd fd, IntPtr stat);
            [DllImport(Lib, SetLastError = true)] internal static extern int fstatat(SafeFd fd, string name, IntPtr stat, int flags);
            [DllImport(Lib, EntryPoint = "fstatat$INODE64", SetLastError = true)] internal static extern int fstatat64(SafeFd fd, string name, IntPtr stat, int flags);
            [DllImport(Lib, SetLastError = true)] internal static extern int flock(SafeFd fd, int operation);
            [DllImport(Lib, SetLastError = true)] internal static extern int fchmod(SafeFd fd, uint mode);
            [DllImport(Lib, SetLastError = true)] internal static extern int fchown(SafeFd fd, uint uid, uint gid);
            [DllImport(Lib, SetLastError = true)] internal static extern int fsync(SafeFd fd);
            [DllImport(Lib, SetLastError = true)] internal static extern int fchflags(SafeFd fd, uint flags);
            [DllImport(Lib, SetLastError = true)] internal static extern int renameat(SafeFd oldDirectory, string oldName, SafeFd newDirectory, string newName);
            [DllImport(Lib, SetLastError = true)] internal static extern int renameatx_np(SafeFd oldDirectory, string oldName, SafeFd newDirectory, string newName, uint flags);
            [DllImport(Lib, SetLastError = true)] internal static extern IntPtr acl_get_fd_np(SafeFd fd, int type);
            [DllImport(Lib, SetLastError = true)] internal static extern int acl_get_entry(IntPtr acl, int entryId, ref IntPtr entry);
            [DllImport(Lib, SetLastError = true)] internal static extern int acl_get_flagset_np(IntPtr entry, ref IntPtr flagset);
            [DllImport(Lib, SetLastError = true)] internal static extern int acl_get_flag_np(IntPtr flagset, int flag);
            [DllImport(Lib, SetLastError = true)] internal static extern int acl_free(IntPtr value);
            [DllImport(Lib, SetLastError = true)] internal static extern int close(int fd);
            [DllImport(Lib, SetLastError = true)] internal static extern IntPtr write(SafeFd fd, IntPtr buffer, UIntPtr count);
            [DllImport(Lib, SetLastError = true)] internal static extern IntPtr read(SafeFd fd, IntPtr buffer, UIntPtr count);
            [DllImport(Lib, SetLastError = true)] internal static extern IntPtr pread(SafeFd fd, IntPtr buffer, UIntPtr count, long offset);
            [DllImport(Lib, SetLastError = true)] internal static extern IntPtr pwrite(SafeFd fd, IntPtr buffer, UIntPtr count, long offset);
            [DllImport(Lib, SetLastError = true)] internal static extern int unlinkat(SafeFd fd, string name, int flags);
            [DllImport(Lib, SetLastError = true)] internal static extern int linkat(SafeFd fd, string name, SafeFd other, string link, int flags);
            [DllImport(Lib, SetLastError = true)] internal static extern int symlinkat(string target, SafeFd fd, string name);
            // Only F_GETFD is used; it does not consume a variadic third argument.
            [DllImport(Lib, SetLastError = true)] internal static extern int fcntl(SafeFd fd, int command);
            [DllImport(Lib, SetLastError = true)] internal static extern uint geteuid();
        }

        private static bool Mac { get { return PlatformNative.GetOperatingSystem() == "macos"; } }
        private static bool X64 { get { return PlatformNative.GetArchitecture() == "x64"; } }
        // Linux aarch64 overrides asm-generic O_DIRECTORY/O_NOFOLLOW. Select by
        // both OS and architecture; these are NOT the Linux x86_64 values.
        private static int DirectoryFlags { get { return Mac ? 0x100000 : X64 ? 0x10000 : 0x4000; } }
        private static int NoFollow { get { return Mac ? 0x100 : X64 ? 0x20000 : 0x8000; } }
        private static int CloseOnExec { get { return Mac ? 0x1000000 : 0x80000; } }
        private static int Create { get { return Mac ? 0x200 : 0x40; } }
        private static int Exclusive { get { return Mac ? 0x800 : 0x80; } }
        private static int NonBlock { get { return Mac ? 0x4 : 0x800; } }
        private static int AtNoFollow { get { return Mac ? 0x20 : 0x100; } }
        private static int AtRemoveDirectory { get { return Mac ? 0x80 : 0x200; } }
        private static int AtCwd { get { return Mac ? -2 : -100; } }
        // flock values coincide in these ABIs, kept explicit in each selection.
        private static int LockShared { get { return Mac ? 1 : 1; } }
        private static int LockExclusive { get { return Mac ? 2 : 2; } }
        private static int LockNonBlock { get { return Mac ? 4 : 4; } }
        private static int LockUnlock { get { return Mac ? 8 : 8; } }
        private const uint RenameNoReplaceFlag = 1;
        private const uint RenameExclusive = 0x00000004;
        private const int AclTypeExtended = 0x00000100;
        private const int AclFirstEntry = 0;
        private const int AclNextEntry = 1;
        private static readonly int[] DarwinAclInheritanceFlags = new int[] { 0x0001, 0x0002, 0x0004, 0x0008, 0x0010 };
        // Linux include/uapi/linux/fs.h deny mask 0x42900834.
        // Semantic-changing: FS_IMMUTABLE_FL 0x00000010 and FS_APPEND_FL
        // 0x00000020 alter write/rename/unlink behavior. Not preserved by
        // stage->rename: FS_COMPR_FL 0x00000004, FS_ENCRYPT_FL 0x00000800,
        // FS_NOCOW_FL 0x00800000, FS_VERITY_FL 0x00100000,
        // FS_DAX_FL 0x02000000, and FS_CASEFOLD_FL 0x40000000.
        // FS_NODUMP_FL and implementation flags such as EXTENT, INLINE_DATA,
        // INDEX, and HUGE_FILE are intentionally outside this deny mask.
        private const uint LinuxDeniedInodeFlags = 0x42900834;
        private static readonly object AbiSync = new object();
        private static string abiEvidence;
        private static bool abiAttempted;
        private static Exception abiFailure;
        // Test-only barrier. Production code never assigns this internal hook.
        internal static Action<string> MutationTestHook = null;
        internal static Action<string> ProbeTestHook = null;

        internal static int Close(int fd) { return Mac ? Darwin.close(fd) : Linux.close(fd); }
        private static string ErrnoName(int error)
        {
            switch (error)
            {
                case 1: return "EPERM"; case 2: return "ENOENT"; case 4: return "EINTR";
                case 5: return "EIO"; case 9: return "EBADF"; case 13: return "EACCES";
                case 17: return "EEXIST"; case 18: return "EXDEV"; case 20: return "ENOTDIR";
                case 21: return "EISDIR"; case 22: return "EINVAL"; case 28: return "ENOSPC";
                case 34: return "ERANGE";
                case 38: return Mac ? "ERRNO_38" : "ENOSYS";
                case 39: return Mac ? "ERRNO_39" : "ENOTEMPTY";
                case 40: return Mac ? "EMSGSIZE" : "ELOOP";
                case 45: return Mac ? "ENOTSUP" : "EL2NSYNC";
                case 61: return Mac ? "ECONNREFUSED" : "ENODATA";
                case 62: return Mac ? "ELOOP" : "ETIME";
                case 78: return Mac ? "ENOSYS" : "EREMCHG";
                case 93: return Mac ? "ENOATTR" : "EPROTONOSUPPORT";
                case 95: return Mac ? "EMULTIHOP" : "EOPNOTSUPP";
                case 96: return Mac ? "ENODATA" : "ERRNO_96";
                case 102: return Mac ? "EOPNOTSUPP" : "ERRNO_102";
                default: return "ERRNO_" + error.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
        }
        private static PlatformErrnoException Errno(string operation, int error)
        { return new PlatformErrnoException(operation, error, ErrnoName(error)); }
        private static void Check(int result, string operation)
        { if (result < 0) { int error = Marshal.GetLastWin32Error(); throw Errno(operation, error); } }

        // Retain a SafeHandle reference across raw-int openat, including concurrent Dispose.
        private static SafeFd Open(SafeFd parent, string name, int flags, uint mode)
        {
            bool held = false;
            try
            {
                if (parent != null) parent.DangerousAddRef(ref held);
                int fd = parent == null ? AtCwd : parent.DangerousGetHandle().ToInt32();
                bool creating = (flags & Create) != 0;
                if (creating && (flags & Exclusive) == 0) throw new ArgumentException("Creation must be exclusive before applying permissions.");
                int nativeFlags = flags | NoFollow | CloseOnExec;
                int result;
                if (Mac && !X64 && creating)
                    result = Darwin.openatArm64Create(fd, name, nativeFlags,
                        IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 0);
                else result = Mac ? Darwin.openat(fd, name, nativeFlags, 0) : Linux.openat(fd, name, nativeFlags, 0);
                Check(result, "openat");
                SafeFd opened = new SafeFd(result);
                try
                {
                    if (creating)
                    {
                        // New inodes start with mode bits 0000, even in a non-private parent.
                        // ACL policy remains outside this mode-only primitive's contract.
                        // This also self-checks the ABI before a requested mode is applied.
                        FileObservation initial = Stat(opened, null);
                        PlatformPaths.Single(initial);
                        if ((initial.Mode & 4095) != 0) throw new IOException("openat initial mode must be 0000; creation ABI check failed.");
                        Chmod(opened, mode);
                        if ((Stat(opened, null).Mode & 4095) != mode) throw new IOException("Created file mode readback failed.");
                    }
                    return opened;
                }
                catch { opened.Dispose(); throw; }
            }
            finally { if (held) parent.DangerousRelease(); }
        }
        private static FileObservation Stat(SafeFd fd, string leaf)
        {
            // Oversized buffer also bounds writes before a layout passes the self-test.
            IntPtr buffer = Marshal.AllocHGlobal(512);
            try
            {
                for (int i = 0; i < 512; i += 8) Marshal.WriteInt64(buffer, i, 0);
                int result;
                if (!Mac) result = leaf == null ? Linux.fstat(fd, buffer) : Linux.fstatat(fd, leaf, buffer, AtNoFollow);
                else if (X64) result = leaf == null ? Darwin.fstat64(fd, buffer) : Darwin.fstatat64(fd, leaf, buffer, AtNoFollow);
                else result = leaf == null ? Darwin.fstat(fd, buffer) : Darwin.fstatat(fd, leaf, buffer, AtNoFollow);
                Check(result, leaf == null ? "fstat" : "fstatat");
                FileObservation value;
                if (Mac)
                {
                    DarwinStat s = (DarwinStat)Marshal.PtrToStructure(buffer, typeof(DarwinStat));
                    value = new FileObservation { Device = s.Dev, Inode = s.Ino, Mode = s.Mode, LinkCount = s.Nlink, Uid = s.Uid, Gid = s.Gid, Flags = s.Flags, Size = s.Size };
                }
                else if (X64)
                {
                    LinuxX64Stat s = (LinuxX64Stat)Marshal.PtrToStructure(buffer, typeof(LinuxX64Stat));
                    value = new FileObservation { Device = s.Dev, Inode = s.Ino, Mode = s.Mode, LinkCount = s.Nlink, Uid = s.Uid, Gid = s.Gid, Size = s.Size };
                }
                else
                {
                    LinuxArm64Stat s = (LinuxArm64Stat)Marshal.PtrToStructure(buffer, typeof(LinuxArm64Stat));
                    value = new FileObservation { Device = s.Dev, Inode = s.Ino, Mode = s.Mode, LinkCount = s.Nlink, Uid = s.Uid, Gid = s.Gid, Size = s.Size };
                }
                uint type = value.Mode & 0xf000;
                value.Kind = type == 0x8000 ? "file" : type == 0x4000 ? "directory" : "other";
                return value;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        private static void Chmod(SafeFd fd, uint mode) { Check(Mac ? Darwin.fchmod(fd, mode) : Linux.fchmod(fd, mode), "fchmod"); }
        private static void Unlink(SafeFd fd, string leaf, bool directory)
        { Check(Mac ? Darwin.unlinkat(fd, leaf, directory ? AtRemoveDirectory : 0) : Linux.unlinkat(fd, leaf, directory ? AtRemoveDirectory : 0), "unlinkat-probe-cleanup"); }
        private static void UnlinkOwnedProbeDirectory(SafeFd parent, string leaf, SafeFd directory, string context)
        {
            FileObservation held = Stat(directory, null);
            FileObservation named = TryStat(parent, leaf);
            if (held.Kind != "directory" || !SameIdentity(held, named))
                throw new PlatformVerificationException(context, PlatformNative.GetOperatingSystem(),
                    "probe directory identity changed before cleanup; replacement was preserved");
            Unlink(parent, leaf, true);
        }
        private static SafeFd WalkRoot(string root)
        {
            if (String.IsNullOrEmpty(root) || !root.StartsWith("/") || root.IndexOf('\\') >= 0 || root.IndexOf('\0') >= 0)
                throw new ArgumentException("An absolute physical Unix root is required.");
            SafeFd current = Open(null, "/", DirectoryFlags, 0);
            try
            {
                if (root != "/") foreach (string part in PlatformPaths.Segments(root.Substring(1).TrimEnd('/')))
                {
                    SafeFd next = Open(current, part, DirectoryFlags, 0);
                    current.Dispose(); current = next;
                }
                SafeFd result = current; current = null; return result;
            }
            finally { if (current != null) current.Dispose(); }
        }
        private static SafeFd ChildDirectory(SafeFd parent, string leaf, bool create)
        {
            SafeFd child;
            bool created = false;
            try { child = Open(parent, leaf, DirectoryFlags, 0); }
            catch (PlatformErrnoException ex)
            {
                if (!create || ex.Errno != 2) throw;
                int result = Mac ? Darwin.mkdirat(parent, leaf, 448) : Linux.mkdirat(parent, leaf, 448);
                // EEXIST means a competing creator won. Re-open with NOFOLLOW, never adopt a symlink.
                if (result != 0 && Marshal.GetLastWin32Error() != 17) Check(result, "mkdirat");
                child = Open(parent, leaf, DirectoryFlags, 0);
                if (result == 0)
                {
                    created = true;
                    try { Chmod(child, 448); }
                    catch { child.Dispose(); throw; }
                }
            }
            try
            {
                FileObservation value = Stat(child, null);
                if (value.Kind != "directory") throw new IOException("Not a directory.");
                if (created && (value.Mode & 4095) != 448) throw new IOException("Private-directory mode readback failed.");
                PlatformPaths.Same(value, Stat(parent, leaf));
                return child;
            }
            catch { child.Dispose(); throw; }
        }

        public static string ValidateAbi()
        {
            lock (AbiSync)
            {
                if (abiAttempted)
                {
                    if (abiFailure != null) throw new PlatformCapabilityUnavailableException("unix-abi: " + abiFailure.Message, PlatformNative.GetOperatingSystem());
                    return abiEvidence;
                }
                abiAttempted = true;
                try
                {
                    string os = PlatformNative.GetOperatingSystem(), arch = PlatformNative.GetArchitecture();
                    if ((os != "linux" && os != "macos") || (arch != "x64" && arch != "arm64") ||
                        IntPtr.Size != 8 || !BitConverter.IsLittleEndian)
                        throw new PlatformCapabilityUnavailableException("unix-abi", os + "-" + arch);
                    if (!Mac && Linux.gnu_get_libc_version() == IntPtr.Zero) throw new IOException("glibc is required.");
                    MethodInfo getMode = typeof(File).GetMethod("GetUnixFileMode", new Type[] { typeof(string) });
                    if (getMode == null) throw new IOException("The runtime lacks independent UnixFileMode validation.");
                    string basePath = Mac ? "/private/tmp" : "/tmp";
                    string name = "platform-abi-" + Guid.NewGuid().ToString("N");
                    using (SafeFd parent = WalkRoot(basePath))
                    {
                        Check(Mac ? Darwin.mkdirat(parent, name, 448) : Linux.mkdirat(parent, name, 448), "mkdirat-probe");
                        try
                        {
                            using (SafeFd directory = ChildDirectory(parent, name, false))
                            {
                                using (SafeFd file = Open(directory, "probe", 2 | Create | Exclusive, 384))
                                {
                                    try
                                    {
                                        string path = basePath + "/" + name + "/probe";
                                        if ((Stat(file, null).Mode & 4095) != 384 ||
                                            Convert.ToUInt32(getMode.Invoke(null, new object[] { path })) != 384)
                                            throw new IOException("Created probe must have mode 0600 before any path-based I/O.");
                                        File.WriteAllBytes(path, new byte[173]);
                                        Chmod(file, 416); // 0640, independently read by .NET.
                                        FileObservation observed = Stat(file, null);
                                        PlatformPaths.Single(observed);
                                        PlatformPaths.Same(observed, Stat(directory, "probe"));
                                        if (observed.Inode == 0 || observed.Size != new FileInfo(path).Length || observed.Size != 173 ||
                                            (observed.Mode & 4095) != Convert.ToUInt32(getMode.Invoke(null, new object[] { path })) ||
                                            (observed.Mode & 4095) != 416 || observed.Uid != (Mac ? Darwin.geteuid() : Linux.geteuid()) ||
                                            observed.Gid != Stat(directory, null).Gid)
                                            throw new IOException("stat size/mode/uid/gid self-test failed.");
                                        if (Mac)
                                        {
                                            Check(Darwin.fchflags(file, 1), "fchflags-abi-probe"); // UF_NODUMP
                                            if (Stat(file, null).Flags != 1) throw new IOException("stat st_flags self-test failed.");
                                            Check(Darwin.fchflags(file, 0), "fchflags-abi-probe-clear");
                                            if (Stat(file, null).Flags != 0) throw new IOException("stat st_flags clear self-test failed.");
                                        }
                                        Check(Mac ? Darwin.linkat(directory, "probe", directory, "alias", 0) : Linux.linkat(directory, "probe", directory, "alias", 0), "linkat-probe");
                                        try { if (Stat(file, null).LinkCount != 2) throw new IOException("stat nlink self-test failed."); }
                                        finally { Unlink(directory, "alias", false); }
                                        int fdFlags = Mac ? Darwin.fcntl(file, 1) : Linux.fcntl(file, 1); // F_GETFD
                                        Check(fdFlags, "fcntl-F_GETFD");
                                        if ((fdFlags & 1) == 0) throw new IOException("O_CLOEXEC self-test failed.");
                                        Check(Mac ? Darwin.symlinkat("probe", directory, "symlink") : Linux.symlinkat("probe", directory, "symlink"), "symlinkat-probe");
                                        try
                                        {
                                            if ((Stat(directory, "symlink").Mode & 0xf000) != 0xa000)
                                                throw new IOException("AT_SYMLINK_NOFOLLOW self-test failed.");
                                            bool refused = false;
                                            try { using (SafeFd unexpected = Open(directory, "symlink", 0, 0)) { } }
                                            catch (PlatformErrnoException ex) { if (ex.Errno != (Mac ? 62 : 40)) throw; refused = true; }
                                            if (!refused) throw new IOException("O_NOFOLLOW self-test failed.");
                                        }
                                        finally { Unlink(directory, "symlink", false); }
                                    }
                                    finally { Unlink(directory, "probe", false); }
                                }
                            }
                        }
                        finally { Unlink(parent, name, true); }
                    }
                    abiEvidence = os + "-" + arch + ": stat/fstatat size, type, mode, uid, gid, inode, nlink" +
                        (Mac ? " and st_flags" : "") + " self-test passed; nofollow/cloexec passed; create mode 0000 -> 0600 verified";
                    return abiEvidence;
                }
                catch (Exception ex)
                {
                    abiFailure = ex;
                    throw new PlatformCapabilityUnavailableException("unix-abi: " + ex.Message, PlatformNative.GetOperatingSystem());
                }
            }
        }

        // Explicit existing absolute-directory anchor, including /. Relative paths
        // still require ordinary nonempty components; no traversal exception.
        public static UnixLease OpenDirectoryRoot(string root)
        {
            ValidateAbi();
            SafeFd directory = WalkRoot(root);
            try { return new UnixLease(directory, null, null, Path.GetFullPath(root), Stat(directory, null)); }
            catch { directory.Dispose(); throw; }
        }

        // Preparation roots are create-only: never adopt an existing directory,
        // including a concurrent mkdir winner with the same run identifier.
        public static UnixLease CreatePrivateDirectory(string root, string leaf)
        {
            PlatformPaths.Leaf(leaf); ValidateAbi();
            SafeFd parent = WalkRoot(root), child = null;
            try
            {
                Check(Mac ? Darwin.mkdirat(parent, leaf, 448) : Linux.mkdirat(parent, leaf, 448), "mkdirat create-only");
                child = ChildDirectory(parent, leaf, false);
                UnixLease result = new UnixLease(child, parent, leaf, Path.GetFullPath(Path.Combine(root, leaf)), Stat(child, null));
                child = null; parent = null; return result;
            }
            finally { if (child != null) child.Dispose(); if (parent != null) parent.Dispose(); }
        }

        public static UnixLease OpenDirectory(string root, string relative, bool create)
        {
            string[] parts = PlatformPaths.Segments(relative);
            ValidateAbi();
            SafeFd current = WalkRoot(root), parent = null;
            try
            {
                foreach (string part in parts)
                {
                    SafeFd next = ChildDirectory(current, part, create);
                    if (parent != null) parent.Dispose(); parent = current; current = next;
                }
                string path = Path.GetFullPath(Path.Combine(root, String.Join("/", parts)));
                UnixLease result = new UnixLease(current, parent, parts[parts.Length - 1], path, Stat(current, null));
                current = null; parent = null; return result;
            }
            finally { if (current != null) current.Dispose(); if (parent != null) parent.Dispose(); }
        }
        public static UnixLease OpenFile(UnixLease parent, string leaf, string access, string createMode)
        {
            PlatformPaths.Leaf(leaf); ValidateAbi();
            int flags = access == "Read" || access == "ReadPermissions" ? 0 : access == "Write" ? 1 : access == "ReadWrite" ? 2 : -1;
            if (flags < 0) throw new ArgumentException("Access must be Read, Write, ReadWrite or ReadPermissions.");
            if (createMode == "CreateNew") flags |= Create | Exclusive;
            else if (createMode != "OpenExisting") throw new ArgumentException("CreateMode must be CreateNew or OpenExisting.");
            lock (parent.Sync)
            {
                parent.Check();
                AssertIdentity(parent, parent.Observation, false);
                if (parent.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
                SafeFd duplicate = Open(parent.Fd, ".", DirectoryFlags, 0), file = null;
                try
                {
                    // O_NONBLOCK avoids hanging on a malicious FIFO before fstat rejects its type.
                    file = Open(duplicate, leaf, flags | NonBlock, 384);
                    FileObservation value = Stat(file, null);
                    PlatformPaths.Single(value);
                    PlatformPaths.Same(value, Stat(duplicate, leaf));
                    UnixLease result = new UnixLease(file, duplicate, leaf, Path.Combine(parent.Path, leaf), value);
                    result.NewWritable = createMode == "CreateNew" && access != "Read" && access != "ReadPermissions";
                    file = null; duplicate = null; return result;
                }
                finally { if (file != null) file.Dispose(); if (duplicate != null) duplicate.Dispose(); }
            }
        }
        private static UnixLease OpenPreparationSource(string path)
        {
            ValidateAbi();
            // Read-only source anchors may include OS aliases such as /var.
            // As in OpenFile, the leaf is opened NOFOLLOW | NONBLOCK and fstat
            // must prove a single-link regular file BEFORE any content read.
            string full = Path.GetFullPath(path);
            SafeFd file = Open(null, full, NonBlock, 0);
            try
            {
                FileObservation observed = Stat(file, null);
                PlatformPaths.Single(observed);
                return new UnixLease(file, null, null, full, observed);
            }
            catch { file.Dispose(); throw; }
        }
        public static void AssertRegularSourceFile(string path)
        {
            using (UnixLease file = OpenPreparationSource(path))
                AssertIdentity(file, file.Observation, true);
        }
        public static byte[] ReadPreparationFileBytes(string path)
        {
            using (UnixLease file = OpenPreparationSource(path))
            {
                long size = file.Observation.Size;
                if (size < 0 || size > Int32.MaxValue) throw new IOException("Source is too large for a private snapshot.");
                byte[] bytes = new byte[(int)size];
                GCHandle pinned = GCHandle.Alloc(bytes, GCHandleType.Pinned);
                try
                {
                    int offset = 0;
                    while (offset < bytes.Length)
                    {
                        UIntPtr length = new UIntPtr((uint)Math.Min(65536, bytes.Length - offset));
                        IntPtr data = IntPtr.Add(pinned.AddrOfPinnedObject(), offset);
                        long count = (Mac ? Darwin.read(file.Fd, data, length) : Linux.read(file.Fd, data, length)).ToInt64();
                        if (count < 0)
                        {
                            int error = Marshal.GetLastWin32Error();
                            if (error == 4) continue; // EINTR
                            throw new PlatformErrnoException("read", error);
                        }
                        if (count == 0) throw new EndOfStreamException("Source changed during snapshot read.");
                        if (count > (long)length.ToUInt64()) throw new IOException("Invalid native read result.");
                        offset += (int)count;
                    }
                    if (AssertIdentity(file, file.Observation, true).Size != size)
                        throw new IOException("Source size changed during snapshot read.");
                    return bytes;
                }
                finally { pinned.Free(); }
            }
        }
        public static FileObservation AssertIdentity(UnixLease lease, FileObservation expected, bool single)
        {
            lock (lease.Sync)
            {
                lease.Check(); FileObservation value = Stat(lease.Fd, null);
                PlatformPaths.Same(value, expected);
                if (single) PlatformPaths.Single(value);
                if (lease.Parent != null) PlatformPaths.Same(value, Stat(lease.Parent, lease.Leaf));
                return value;
            }
        }
        internal static FileObservation AssertRetainedIdentity(UnixLease lease, FileObservation expected)
        {
            lock (lease.Sync)
            {
                lease.Check(); FileObservation value = Stat(lease.Fd, null);
                PlatformPaths.Same(value, expected);
                if (value.Kind != "file") throw new IOException("A retained regular file is required.");
                return value;
            }
        }
        public static string GetVerifiedPath(UnixLease lease)
        {
            lock (lease.Sync)
            {
                AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
                // The retained parent may itself have been renamed. Re-walk ALL
                // pathname ancestors with NOFOLLOW and compare the final inode.
                // This is read/receipt evidence only, never authority for writes.
                string path = Path.GetFullPath(lease.Path);
                if (lease.Observation.Kind == "directory")
                {
                    using (SafeFd named = WalkRoot(path)) PlatformPaths.Same(Stat(named, null), lease.Observation);
                }
                else
                {
                    using (SafeFd parent = WalkRoot(Path.GetDirectoryName(path)))
                        PlatformPaths.Same(Stat(parent, Path.GetFileName(path)), lease.Observation);
                }
                return path;
            }
        }

        // P4 writes are rooted in the P2 directory descriptor. No cached pathname
        // is reopened for creation or writes, even if a same-account actor renames
        // an ancestor between validation and I/O (the cooperative A1 boundary).
        private static UnixLease OpenPreparationDirectory(UnixLease root, string relative, out FileObservation[] ancestors)
        {
            ancestors = null;
            AssertIdentity(root, root.Observation, false);
            if (root.Observation.Kind != "directory") throw new ArgumentException("A directory lease is required.");
            SafeFd current = Open(root.Fd, ".", DirectoryFlags, 0), parent = null;
            string leaf = root.Leaf, path = root.Path;
            List<FileObservation> observed = new List<FileObservation>();
            try
            {
                PlatformPaths.Same(Stat(current, null), root.Observation);
                observed.Add(root.Observation);
                if (!String.IsNullOrEmpty(relative)) foreach (string part in PlatformPaths.Segments(relative))
                {
                    SafeFd next = ChildDirectory(current, part, true);
                    if (parent != null) parent.Dispose();
                    parent = current; current = next; leaf = part; path = Path.Combine(path, part);
                    observed.Add(Stat(current, null));
                }
                UnixLease result = new UnixLease(current, parent, leaf, path, Stat(current, null));
                ancestors = observed.ToArray();
                current = null; parent = null; return result;
            }
            finally { if (current != null) current.Dispose(); if (parent != null) parent.Dispose(); }
        }

        private static void AssertPreparationDirectoryPath(UnixLease root, string relative, FileObservation[] ancestors, UnixLease directory)
        {
            string[] parts = String.IsNullOrEmpty(relative) ? new string[0] : PlatformPaths.Segments(relative);
            if (ancestors == null || ancestors.Length != parts.Length + 1)
                throw new IOException("Preparation directory ancestry evidence is incomplete.");
            GetVerifiedPath(root);
            SafeFd current = Open(root.Fd, ".", DirectoryFlags, 0);
            try
            {
                PlatformPaths.Same(Stat(current, null), ancestors[0]);
                for (int i = 0; i < parts.Length; i++)
                {
                    // Reopen from the retained root with NOFOLLOW, comparing
                    // EVERY component. Checking only the final c and parent b
                    // misses a moved/replaced a even if b/c keep their inodes.
                    SafeFd next = Open(current, parts[i], DirectoryFlags, 0);
                    try { PlatformPaths.Same(Stat(next, null), ancestors[i + 1]); }
                    catch { next.Dispose(); throw; }
                    current.Dispose(); current = next;
                }
                PlatformPaths.Same(Stat(current, null), directory.Observation);
                AssertIdentity(directory, directory.Observation, false);
                GetVerifiedPath(root);
            }
            finally { current.Dispose(); }
        }

        public static void CreatePreparationDirectory(UnixLease root, string relative)
        {
            PlatformPaths.Segments(relative);
            lock (root.Sync)
            {
                GetVerifiedPath(root);
                FileObservation[] ancestors;
                using (UnixLease directory = OpenPreparationDirectory(root, relative, out ancestors))
                    AssertPreparationDirectoryPath(root, relative, ancestors, directory);
            }
        }

        public static void WritePreparationFile(UnixLease root, string relative, Stream source)
        {
            string[] parts = PlatformPaths.Segments(relative);
            if (source == null || !source.CanRead) throw new ArgumentException("A readable payload stream is required.");
            string parentPath = String.Join("/", parts, 0, parts.Length - 1);
            lock (root.Sync)
            {
                GetVerifiedPath(root);
                FileObservation[] ancestors;
                using (UnixLease directory = OpenPreparationDirectory(root, parentPath, out ancestors))
                {
                    AssertPreparationDirectoryPath(root, parentPath, ancestors, directory);
                    using (UnixLease file = OpenFile(directory, parts[parts.Length - 1], "Write", "CreateNew"))
                    {
                        byte[] buffer = new byte[65536];
                        GCHandle pinned = GCHandle.Alloc(buffer, GCHandleType.Pinned);
                        try
                        {
                            int count;
                            while ((count = source.Read(buffer, 0, buffer.Length)) != 0)
                            {
                                int offset = 0;
                                while (offset < count)
                                {
                                    AssertPreparationDirectoryPath(root, parentPath, ancestors, directory);
                                    AssertIdentity(file, file.Observation, true);
                                    IntPtr data = IntPtr.Add(pinned.AddrOfPinnedObject(), offset);
                                    UIntPtr length = new UIntPtr((uint)(count - offset));
                                    long written = (Mac ? Darwin.write(file.Fd, data, length) : Linux.write(file.Fd, data, length)).ToInt64();
                                    if (written < 0)
                                    {
                                        int error = Marshal.GetLastWin32Error();
                                        if (error == 4) continue; // EINTR, no bytes written.
                                        throw new PlatformErrnoException("write", error);
                                    }
                                    if (written == 0 || written > count - offset) throw new IOException("Invalid native write result.");
                                    offset += (int)written;
                                }
                            }
                            // Read may rename a directory even when it returns EOF.
                            AssertPreparationDirectoryPath(root, parentPath, ancestors, directory);
                            AssertIdentity(file, file.Observation, true);
                        }
                        finally { pinned.Free(); }
                    }
                }
            }
        }
        private static int Flock(SafeFd fd, int operation)
        {
            try { return Mac ? Darwin.flock(fd, operation) : Linux.flock(fd, operation); }
            catch (EntryPointNotFoundException) { throw new PlatformCapabilityUnavailableException("flock-symbol", PlatformNative.GetOperatingSystem()); }
        }
        internal static void Unlock(SafeFd fd) { Flock(fd, LockUnlock); }
        private static void WaitForLockRetry(Stopwatch timer, TimeSpan timeout)
        {
            if (timer.Elapsed >= timeout) throw new TimeoutException("The platform lock deadline expired.");
            Thread.Sleep((int)Math.Min(20, Math.Max(1, (timeout - timer.Elapsed).TotalMilliseconds)));
            if (timer.Elapsed >= timeout) throw new TimeoutException("The platform lock deadline expired.");
        }
        private static FileObservation ObserveLockName(UnixLease parent, string leaf)
        {
            lock (parent.Sync)
            {
                parent.Check();
                AssertIdentity(parent, parent.Observation, false);
                FileObservation value = Stat(parent.Fd, leaf); // AT_SYMLINK_NOFOLLOW
                PlatformPaths.Single(value);
                return value;
            }
        }
        private static UnixLease OpenLockFile(UnixLease parent, string leaf, Stopwatch timer, TimeSpan timeout)
        {
            try { return OpenFile(parent, leaf, "ReadWrite", "CreateNew"); }
            catch (PlatformErrnoException ex) { if (ex.Errno != 17) throw; }

            FileObservation initializing = null;
            while (true)
            {
                FileObservation before = ObserveLockName(parent, leaf);
                if (initializing != null)
                {
                    PlatformPaths.Same(before, initializing);
                    if (before.Uid != initializing.Uid) throw new IOException("The initializing lock owner changed.");
                }
                try
                {
                    UnixLease lease = OpenFile(parent, leaf, "ReadWrite", "OpenExisting");
                    try { AssertIdentity(lease, before, true); return lease; }
                    catch { lease.Dispose(); throw; }
                }
                catch (PlatformErrnoException ex)
                {
                    if (ex.Errno != 13) throw;
                    FileObservation after = ObserveLockName(parent, leaf);
                    PlatformPaths.Same(after, before);
                    uint owner = Mac ? Darwin.geteuid() : Linux.geteuid();
                    uint beforeMode = before.Mode & 4095, afterMode = after.Mode & 4095;
                    // A cooperating creator exposes mode 0000 before fchmod(0600).
                    // Observe both sides of open so completion between EACCES and
                    // fstatat does not turn a legitimate race into a fatal denial.
                    // All other permission failures remain immediate; never chmod
                    // another participant's file or adopt a replacement while waiting.
                    if (before.Uid != owner || after.Uid != owner ||
                        (beforeMode != 0 && afterMode != 0) || (afterMode != 0 && afterMode != 384)) throw;
                    initializing = before;
                    WaitForLockRetry(timer, timeout);
                }
            }
        }
        public static UnixLease EnterLock(UnixLease parent, string leaf, string mode, TimeSpan timeout)
        {
            if (timeout < TimeSpan.Zero || (mode != "Shared" && mode != "Exclusive")) throw new ArgumentException("Invalid lock mode or timeout.");
            Stopwatch timer = Stopwatch.StartNew();
            // Never unlink on release. All participants must use flock on this fixed inode.
            UnixLease lease = OpenLockFile(parent, leaf, timer, timeout);
            try
            {
                while (Flock(lease.Fd, (mode == "Shared" ? LockShared : LockExclusive) | LockNonBlock) != 0)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error != (Mac ? 35 : 11) && error != 4) throw new PlatformErrnoException("flock", error);
                    WaitForLockRetry(timer, timeout);
                }
                lease.Locked = true;
                AssertIdentity(lease, lease.Observation, true);
                return lease;
            }
            catch { lease.Dispose(); throw; }
        }

        private static bool SameIdentity(FileObservation left, FileObservation right)
        { return left != null && right != null && left.Device == right.Device && left.Inode == right.Inode && left.Kind == right.Kind; }

        private static FileObservation TryStat(SafeFd directory, string leaf)
        {
            try { return Stat(directory, leaf); }
            catch (PlatformErrnoException ex) { if (ex.Errno == 2) return null; throw; }
        }

        private static void RenameNoReplace(SafeFd oldDirectory, string oldLeaf, SafeFd newDirectory, string newLeaf, string operation)
        {
            int result;
            try
            {
                result = Mac
                    ? Darwin.renameatx_np(oldDirectory, oldLeaf, newDirectory, newLeaf, RenameExclusive)
                    : Linux.renameat2(oldDirectory, oldLeaf, newDirectory, newLeaf, RenameNoReplaceFlag);
            }
            catch (EntryPointNotFoundException)
            {
                throw new PlatformCapabilityUnavailableException("publication-noreplace: native symbol missing", PlatformNative.GetOperatingSystem());
            }
            if (result == 0) return;
            int error = Marshal.GetLastWin32Error();
            if (error == 18)
                throw new PlatformCapabilityUnavailableException("same-filesystem-rename: EXDEV", PlatformNative.GetOperatingSystem());
            if (error == 22 || (!Mac && (error == 38 || error == 95)) || (Mac && (error == 45 || error == 78 || error == 102)))
                throw new PlatformCapabilityUnavailableException("publication-noreplace: " + ErrnoName(error), PlatformNative.GetOperatingSystem());
            throw Errno(operation, error);
        }

        // Lease data I/O uses explicit-offset pread/pwrite. Leases are opened O_NONBLOCK
        // (FIFO safety), and .NET 11 routes FileStream I/O on O_NONBLOCK descriptors
        // through offset-less read/write, so a FileStream Position is not honored.
        internal static int PositionalRead(SafeFd fd, byte[] buffer, int index, int count, long fileOffset)
        {
            if (buffer == null) throw new ArgumentNullException("buffer");
            if (index < 0 || count < 0 || count > buffer.Length - index || fileOffset < 0) throw new ArgumentOutOfRangeException("count");
            if (count == 0) return 0;
            GCHandle pinned = GCHandle.Alloc(buffer, GCHandleType.Pinned);
            try
            {
                IntPtr data = IntPtr.Add(pinned.AddrOfPinnedObject(), index);
                UIntPtr length = new UIntPtr((uint)count);
                while (true)
                {
                    long result = (Mac ? Darwin.pread(fd, data, length, fileOffset) : Linux.pread(fd, data, length, fileOffset)).ToInt64();
                    if (result < 0)
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 4) continue; // EINTR
                        throw new PlatformErrnoException("pread", error);
                    }
                    if (result > count) throw new IOException("Invalid native read result.");
                    return (int)result;
                }
            }
            finally { pinned.Free(); }
        }
        internal static byte[] ReadLeaseBytes(SafeFd fd, int maximumBytes)
        {
            if (maximumBytes < 0) throw new ArgumentOutOfRangeException("maximumBytes");
            long length = Stat(fd, null).Size;
            if (length < 0) throw new IOException("Invalid file length.");
            if (length > maximumBytes) throw new IOException("File exceeds the bounded read limit.");
            byte[] bytes = new byte[(int)length];
            int offset = 0;
            while (offset < bytes.Length)
            {
                int count = PositionalRead(fd, bytes, offset, bytes.Length - offset, offset);
                if (count == 0) throw new EndOfStreamException();
                offset += count;
            }
            if (PositionalRead(fd, new byte[1], 0, 1, offset) != 0) throw new IOException("File grew during the bounded read.");
            return bytes;
        }
        internal static void WriteNewLeaseBytes(SafeFd fd, byte[] bytes)
        {
            if (bytes == null) throw new ArgumentNullException("bytes");
            if (Stat(fd, null).Size != 0) throw new IOException("New evidence file is no longer empty.");
            GCHandle pinned = GCHandle.Alloc(bytes, GCHandleType.Pinned);
            try
            {
                int offset = 0;
                while (offset < bytes.Length)
                {
                    IntPtr data = IntPtr.Add(pinned.AddrOfPinnedObject(), offset);
                    UIntPtr length = new UIntPtr((uint)(bytes.Length - offset));
                    long written = (Mac ? Darwin.pwrite(fd, data, length, offset) : Linux.pwrite(fd, data, length, offset)).ToInt64();
                    if (written < 0)
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 4) continue; // EINTR, no bytes written.
                        throw new PlatformErrnoException("pwrite", error);
                    }
                    if (written == 0 || written > bytes.Length - offset) throw new IOException("Invalid native write result.");
                    offset += (int)written;
                }
            }
            finally { pinned.Free(); }
            Sync(fd, false, "fsync");
        }

        private static void Sync(SafeFd fd, bool directory, string operation)
        {
            int result = Mac ? Darwin.fsync(fd) : Linux.fsync(fd);
            if (result == 0) return;
            int error = Marshal.GetLastWin32Error();
            if (directory && (error == 22 || (!Mac && error == 95) || (Mac && (error == 45 || error == 102))))
                throw new PlatformCapabilityUnavailableException("directory-fsync: " + ErrnoName(error), PlatformNative.GetOperatingSystem());
            throw Errno(operation, error);
        }

        private static bool HasLinuxXattr(SafeFd fd, string name)
        {
            long result = Linux.fgetxattr(fd, name, IntPtr.Zero, UIntPtr.Zero).ToInt64();
            if (result >= 0) return true;
            int error = Marshal.GetLastWin32Error();
            if (error == 61) return false; // ENODATA
            // A filesystem that does not support extended attributes cannot
            // carry the POSIX ACL xattrs inspected by this runtime.
            if (error == 95) return false; // ENOTSUP/EOPNOTSUPP
            throw Errno("fgetxattr-" + name, error);
        }

        private static bool HasLinuxAcl(SafeFd fd)
        {
            bool exact = HasLinuxXattr(fd, "system.posix_acl_access") || HasLinuxXattr(fd, "system.posix_acl_default");
            long length = Linux.flistxattr(fd, IntPtr.Zero, UIntPtr.Zero).ToInt64();
            if (length < 0)
            {
                int error = Marshal.GetLastWin32Error();
                if (error == 95) return false; // ENOTSUP/EOPNOTSUPP
                throw Errno("flistxattr", error);
            }
            if (length == 0) return exact;
            IntPtr buffer = Marshal.AllocHGlobal(checked((int)length));
            try
            {
                long read = Linux.flistxattr(fd, buffer, new UIntPtr((ulong)length)).ToInt64();
                if (read < 0)
                {
                    int error = Marshal.GetLastWin32Error();
                    if (error == 95) return false; // ENOTSUP/EOPNOTSUPP
                    throw Errno("flistxattr", error);
                }
                byte[] bytes = new byte[checked((int)read)];
                Marshal.Copy(buffer, bytes, 0, bytes.Length);
                string names = Encoding.UTF8.GetString(bytes);
                foreach (string name in names.Split('\0'))
                    if (name == "system.posix_acl_access" || name == "system.posix_acl_default") return true;
                return exact;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static bool HasDarwinAcl(SafeFd fd)
        {
            IntPtr acl = Darwin.acl_get_fd_np(fd, AclTypeExtended);
            if (acl == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                if (error == 2) return false; // ENOENT means no extended ACL on Darwin.
                throw Errno("acl_get_fd_np", error);
            }
            try
            {
                IntPtr entry = IntPtr.Zero;
                int result = Darwin.acl_get_entry(acl, AclFirstEntry, ref entry);
                if (result == 0) return true;
                int error = Marshal.GetLastWin32Error();
                if (error == 2 || error == 22) return false;
                throw Errno("acl_get_entry", error);
            }
            finally { Check(Darwin.acl_free(acl), "acl_free"); }
        }

        private static bool HasDarwinInheritableAcl(SafeFd fd)
        {
            IntPtr acl = Darwin.acl_get_fd_np(fd, AclTypeExtended);
            if (acl == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                if (error == 2) return false; // ENOENT means no extended ACL on Darwin.
                throw new PlatformCapabilityUnavailableException(
                    "parent-inheritance-acl: unable to read macOS ACL (" + ErrnoName(error) + ")", "macos");
            }
            try
            {
                IntPtr entry = IntPtr.Zero;
                int entryId = AclFirstEntry;
                while (true)
                {
                    int result = Darwin.acl_get_entry(acl, entryId, ref entry);
                    if (result != 0)
                    {
                        int error = Marshal.GetLastWin32Error();
                        if (error == 2 || error == 22) return false;
                        throw new PlatformCapabilityUnavailableException(
                            "parent-inheritance-acl: unable to enumerate macOS ACL entries (" + ErrnoName(error) + ")", "macos");
                    }
                    IntPtr flagset = IntPtr.Zero;
                    if (Darwin.acl_get_flagset_np(entry, ref flagset) != 0 || flagset == IntPtr.Zero)
                        throw new PlatformCapabilityUnavailableException("parent-inheritance-acl: unable to read macOS ACL flags", "macos");
                    foreach (int flag in DarwinAclInheritanceFlags)
                    {
                        int present = Darwin.acl_get_flag_np(flagset, flag);
                        if (present == 1) return true;
                        if (present < 0)
                            throw new PlatformCapabilityUnavailableException("parent-inheritance-acl: unable to determine macOS inheritance flags", "macos");
                    }
                    entryId = AclNextEntry;
                }
            }
            catch (EntryPointNotFoundException ex)
            {
                throw new PlatformCapabilityUnavailableException("parent-inheritance-acl: native symbol missing: " + ex.Message, "macos");
            }
            finally { Check(Darwin.acl_free(acl), "acl_free"); }
        }

        private static ulong GetLinuxFsIocGetFlagsRequest()
        {
            string architecture = PlatformNative.GetArchitecture();
            if (architecture != "x64" && architecture != "arm64")
                throw new PlatformCapabilityUnavailableException(
                    "linux-inode-flags-abi: unsupported architecture " + architecture, "linux");
            // asm-generic _IOC: dir[31:30], size[29:16], type[15:8], nr[7:0].
            // _IOR('f', 1, long) uses IOC_READ=2 and sizeof(long)=8 on both
            // supported 64-bit ABIs, yielding FS_IOC_GETFLAGS 0x80086601.
            ulong request = (2UL << 30) | (8UL << 16) | ((ulong)'f' << 8) | 1UL;
            if (request != 0x80086601UL)
                throw new PlatformCapabilityUnavailableException("linux-inode-flags-abi", "linux-" + architecture);
            return request;
        }

        public static bool HasDeniedLinuxInodeFlags(int flags)
        {
            return (((uint)flags) & LinuxDeniedInodeFlags) != 0;
        }

        private static int GetLinuxInodeFlags(SafeFd fd)
        {
            // The request encodes sizeof(long)==8, while the kernel writes a
            // 32-bit flags value. Allocate the encoded size and read only int.
            IntPtr buffer = Marshal.AllocHGlobal(8);
            try
            {
                Marshal.WriteInt64(buffer, 0);
                int result = Linux.ioctl(fd, new UIntPtr(GetLinuxFsIocGetFlagsRequest()), buffer);
                if (result == 0) return Marshal.ReadInt32(buffer);
                int error = Marshal.GetLastWin32Error();
                // Filesystems returning these errors cannot expose inode flags
                // for this file, so no flag can be present on this descriptor.
                if (error == 22 || error == 25 || error == 95) return 0; // EINVAL, ENOTTY, ENOTSUP/EOPNOTSUPP
                throw Errno("ioctl-FS_IOC_GETFLAGS", error);
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static void AssertNoExtendedMetadata(SafeFd fd, FileObservation observation)
        {
            if (Mac)
            {
                if (observation.Flags != 0)
                    throw new PlatformCapabilityUnavailableException("permissions: macOS file flags are present", "macos");
                if (HasDarwinAcl(fd))
                    throw new PlatformCapabilityUnavailableException("permissions: macOS extended ACL is present", "macos");
            }
            else
            {
                if (HasLinuxAcl(fd))
                    throw new PlatformCapabilityUnavailableException("permissions: POSIX ACL xattr is present", "linux");
                int flags = GetLinuxInodeFlags(fd);
                if (HasDeniedLinuxInodeFlags(flags))
                    throw new PlatformCapabilityUnavailableException(
                        "permissions: denied Linux inode flags are present (0x" +
                        ((uint)flags).ToString("x8", System.Globalization.CultureInfo.InvariantCulture) + ")", "linux");
            }
        }

        private static string ModeText(uint mode)
        {
            string value = Convert.ToString(mode & 4095, 8);
            return value.PadLeft(value.Length > 3 ? 4 : 3, '0');
        }

        private static UnixPermissionSnapshot Snapshot(SafeFd fd, FileObservation observation)
        {
            AssertNoExtendedMetadata(fd, observation);
            return new UnixPermissionSnapshot { Mode = ModeText(observation.Mode), Uid = observation.Uid, Gid = observation.Gid };
        }

        private static UnixPermissionSnapshot AssertExpectedPermissions(SafeFd fd, FileObservation observation,
            bool verify, uint expectedMode, ulong expectedUid, ulong expectedGid, string context)
        {
            UnixPermissionSnapshot live = Snapshot(fd, observation);
            if (verify && (Convert.ToUInt32(live.Mode, 8) != expectedMode || live.Uid != expectedUid || live.Gid != expectedGid))
                throw new PlatformVerificationException(context, PlatformNative.GetOperatingSystem(), "live mode/uid/gid differs from journal permissions");
            return live;
        }

        private static uint EffectiveUid() { return Mac ? Darwin.geteuid() : Linux.geteuid(); }

        private static void ChangeOwnership(SafeFd fd, uint uid, uint gid, string operation)
        {
            int result = Mac ? Darwin.fchown(fd, uid, gid) : Linux.fchown(fd, uid, gid);
            if (result == 0) return;
            int error = Marshal.GetLastWin32Error();
            if (error == 1 || error == 13)
                throw new PlatformCapabilityUnavailableException("permissions: " + operation + " failed with " + ErrnoName(error), PlatformNative.GetOperatingSystem());
            throw Errno(operation, error);
        }

        private static void ApplyPermissions(SafeFd fd, UnixPermissionSnapshot snapshot)
        {
            FileObservation before = Stat(fd, null);
            if (before.Uid != snapshot.Uid || before.Gid != snapshot.Gid)
                ChangeOwnership(fd, checked((uint)snapshot.Uid), checked((uint)snapshot.Gid), "fchown");
            uint mode = Convert.ToUInt32(snapshot.Mode, 8);
            Chmod(fd, mode);
            FileObservation after = Stat(fd, null);
            if ((after.Mode & 4095) != mode || after.Uid != snapshot.Uid || after.Gid != snapshot.Gid)
                throw new PlatformVerificationException("permissions", PlatformNative.GetOperatingSystem(), "mode/uid/gid readback differs from the requested snapshot");
            AssertNoExtendedMetadata(fd, after);
        }

        private static void AssertPermissionSnapshot(SafeFd fd, UnixPermissionSnapshot expected, string context)
        {
            FileObservation observed = Stat(fd, null);
            uint mode = Convert.ToUInt32(expected.Mode, 8);
            if ((observed.Mode & 4095) != mode || observed.Uid != expected.Uid || observed.Gid != expected.Gid)
                throw new PlatformVerificationException(context, PlatformNative.GetOperatingSystem(),
                    "mode/uid/gid readback differs after fsync");
            AssertNoExtendedMetadata(fd, observed);
        }

        private static string Hash(SafeFd fd, FileObservation expected)
        {
            FileObservation before = Stat(fd, null);
            PlatformPaths.Same(before, expected); PlatformPaths.Single(before);
            using (var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                byte[] buffer = new byte[65536];
                long offset = 0;
                while (offset < before.Size)
                {
                    int count = PositionalRead(fd, buffer, 0, (int)Math.Min(buffer.Length, before.Size - offset), offset);
                    if (count == 0) throw new EndOfStreamException("File shrank while hashing.");
                    sha.AppendData(buffer, 0, count); offset += count;
                }
                if (PositionalRead(fd, buffer, 0, 1, offset) != 0) throw new IOException("File grew while hashing.");
                string value = BitConverter.ToString(sha.GetHashAndReset()).Replace("-", "").ToLowerInvariant();
                FileObservation after = Stat(fd, null);
                PlatformPaths.Same(after, before); PlatformPaths.Single(after);
                if (after.Size != before.Size) throw new IOException("File size changed while hashing.");
                return value;
            }
        }

        private static FileObservation AssertFileState(SafeFd fd, FileObservation expectedIdentity,
            string sha256, long length, string context)
        {
            try
            {
                FileObservation value = Stat(fd, null);
                if (!SameIdentity(value, expectedIdentity) || value.Kind != "file" || value.LinkCount != 1 ||
                    value.Size != length || !String.Equals(Hash(fd, value), sha256, StringComparison.Ordinal))
                    throw new PlatformVerificationException(context, PlatformNative.GetOperatingSystem(),
                        "identity, type, link count, length, or SHA-256 differs from expected state");
                return value;
            }
            catch (PlatformVerificationException) { throw; }
            catch (Exception ex)
            {
                throw new PlatformVerificationException(context, PlatformNative.GetOperatingSystem(),
                    "file state could not be verified: " + ex.Message);
            }
        }

        private static FileObservation AssertNamedFileState(SafeFd parent, string leaf,
            FileObservation expectedIdentity, string sha256, long length, string context)
        {
            FileObservation named = Stat(parent, leaf);
            PlatformPaths.Same(named, expectedIdentity); PlatformPaths.Single(named);
            using (SafeFd reopened = Open(parent, leaf, 0, 0))
            {
                FileObservation value = AssertFileState(reopened, expectedIdentity, sha256, length, context);
                PlatformPaths.Same(value, named);
            }
            return named;
        }

        private static void AssertState(UnixLease lease, ulong device, ulong inode, string sha256, long length, string context)
        {
            FileObservation expected = new FileObservation { Device = device, Inode = inode, Kind = "file" };
            FileObservation value = AssertFileState(lease.Fd, expected, sha256, length, context);
            if (lease.Parent != null && !SameIdentity(value, TryStat(lease.Parent, lease.Leaf)))
                throw new PlatformVerificationException(context, PlatformNative.GetOperatingSystem(),
                    "the retained file identity is no longer named by its parent directory");
        }

        private static void AssertStage(UnixLease transaction, UnixLease stage, string sha256, long length)
        {
            if (stage.Parent == null || !SameIdentity(Stat(stage.Parent, null), Stat(transaction.Fd, null)))
                throw new PlatformVerificationException("publication", PlatformNative.GetOperatingSystem(), "stage is not named by TransactionLease");
            FileObservation value = Stat(stage.Fd, null);
            PlatformPaths.Single(value); PlatformPaths.Same(value, Stat(transaction.Fd, stage.Leaf));
            if (value.Device != transaction.Observation.Device || value.Size != length ||
                !String.Equals(Hash(stage.Fd, value), sha256, StringComparison.Ordinal))
                throw new PlatformVerificationException("publication", PlatformNative.GetOperatingSystem(), "stage identity, length, or SHA-256 is invalid");
            Snapshot(stage.Fd, value);
        }

        private static void AssertTransaction(UnixLease transaction, UnixLease targetParent)
        {
            FileObservation transactionValue = AssertIdentity(transaction, transaction.Observation, false);
            if (transactionValue.Kind != "directory" || targetParent.Observation.Kind != "directory") throw new ArgumentException("Directory leases are required.");
            string verified = GetVerifiedPath(transaction);
            string id = Path.GetFileName(verified.TrimEnd(Path.DirectorySeparatorChar));
            string container = Path.GetFileName(Path.GetDirectoryName(verified));
            if (!Regex.IsMatch(id ?? "", "^[0-9a-f]{32}$", RegexOptions.CultureInvariant) || container != ".ai-instructions-txn")
                throw new PlatformVerificationException("transaction-root", PlatformNative.GetOperatingSystem(), "TransactionLease must be .ai-instructions-txn/<32-lowercase-hex>");
            UnixPermissionSnapshot transactionPermissions = Snapshot(transaction.Fd, transactionValue);
            if (transactionPermissions.Mode != "700" || transactionValue.Uid != EffectiveUid())
                throw new PlatformVerificationException("transaction-root", PlatformNative.GetOperatingSystem(), "TransactionLease must be owned by the effective user with mode 0700");
            FileObservation parentValue = AssertIdentity(targetParent, targetParent.Observation, false);
            if (SameIdentity(transactionValue, parentValue)) return; // cleanup mode; caller applies stricter checks.
            string targetPath = GetVerifiedPath(targetParent).TrimEnd(Path.DirectorySeparatorChar);
            string transactionPath = verified.TrimEnd(Path.DirectorySeparatorChar);
            if (targetPath.StartsWith(transactionPath + Path.DirectorySeparatorChar, StringComparison.Ordinal))
                throw new PlatformVerificationException("transaction-root", PlatformNative.GetOperatingSystem(), "target must not be inside the transaction directory");
            if (transactionValue.Device != parentValue.Device)
                throw new PlatformCapabilityUnavailableException("same-filesystem-rename: EXDEV", PlatformNative.GetOperatingSystem());
        }

        private static UnixFlushReceipt NewFlush(string durability)
        { return new UnixFlushReceipt { File = "confirmed", ParentDirectory = "pending", TransactionDirectory = "pending", Durability = durability }; }

        private static string[] AddStep(string[] existing, string step)
        {
            string[] result = new string[(existing == null ? 0 : existing.Length) + 1];
            if (existing != null) Array.Copy(existing, result, existing.Length);
            result[result.Length - 1] = step;
            return result;
        }

        private static void AssertMutationDirectoryPaths(UnixLease parent, UnixLease transaction)
        {
            GetVerifiedPath(parent);
            GetVerifiedPath(transaction);
        }

        private static string NewPreflightLeaf(HashSet<string> reserved, string suffix)
        {
            while (true)
            {
                string leaf = ".ai-instructions-preflight-" + Guid.NewGuid().ToString("N") + "-" + suffix;
                PlatformPaths.Leaf(leaf);
                if (reserved.Add(leaf)) return leaf;
            }
        }

        private static FileObservation CreatePreflightProbe(UnixLease transaction, HashSet<string> reserved, string suffix, out string leaf)
        {
            while (true)
            {
                leaf = NewPreflightLeaf(reserved, suffix);
                try
                {
                    using (SafeFd probe = Open(transaction.Fd, leaf, 2 | Create | Exclusive, 384))
                    { return Stat(probe, null); }
                }
                catch (PlatformErrnoException ex) { if (ex.Errno != 17) throw; }
            }
        }

        private static void UnlinkPreflightProbe(UnixLease transaction, string leaf, FileObservation expected, bool owned)
        {
            if (!owned) return;
            FileObservation named = TryStat(transaction.Fd, leaf);
            PlatformPaths.Same(named, expected);
            Unlink(transaction.Fd, leaf, false);
        }

        private static void DestinationFilesystemPreflight(UnixLease parent, UnixLease transaction, params string[] reservedLeaves)
        {
            FileObservation parentValue = Stat(parent.Fd, null);
            FileObservation transactionValue = Stat(transaction.Fd, null);
            if (parentValue.Device != transactionValue.Device)
                throw new PlatformCapabilityUnavailableException("same-filesystem-rename: EXDEV", PlatformNative.GetOperatingSystem());

            // Get-PlatformCapabilities probes /tmp and proves only that the host exposes
            // the primitives. Each operation must prove directory fsync and no-replace
            // on the destination filesystem before touching target or stage names.
            RunMutationTestHook("destination-preflight-before-transaction-fsync");
            Sync(transaction.Fd, true, "fsync-destination-preflight-transaction");
            RunMutationTestHook("destination-preflight-before-parent-fsync");
            Sync(parent.Fd, true, "fsync-destination-preflight-parent");

            HashSet<string> reserved = new HashSet<string>(StringComparer.Ordinal);
            if (reservedLeaves != null) foreach (string leaf in reservedLeaves) if (leaf != null) reserved.Add(leaf);
            string source = null, renamed = null, conflict = null;
            FileObservation sourceIdentity = null, conflictIdentity = null;
            bool sourceOwned = false, renamedOwned = false, conflictOwned = false;
            try
            {
                sourceIdentity = CreatePreflightProbe(transaction, reserved, "source", out source);
                sourceOwned = true;
                RunMutationTestHook("destination-preflight-before-noreplace");
                while (true)
                {
                    renamed = NewPreflightLeaf(reserved, "renamed");
                    try
                    {
                        RenameNoReplace(transaction.Fd, source, transaction.Fd, renamed, "rename-destination-preflight");
                        sourceOwned = false; renamedOwned = true; break;
                    }
                    catch (PlatformErrnoException ex) { if (ex.Errno != 17) throw; }
                }
                // Source and destination are the same directory, so this one
                // immediate fsync persists both rename sides before cleanup.
                Sync(transaction.Fd, true, "fsync-destination-preflight-rename");
                conflictIdentity = CreatePreflightProbe(transaction, reserved, "conflict", out conflict);
                conflictOwned = true;
                bool refused = false;
                try { RenameNoReplace(transaction.Fd, conflict, transaction.Fd, renamed, "rename-destination-preflight-conflict"); }
                catch (PlatformErrnoException ex) { if (ex.Errno != 17) throw; refused = true; }
                if (!refused || TryStat(transaction.Fd, renamed) == null || TryStat(transaction.Fd, conflict) == null)
                    throw new PlatformVerificationException("destination-preflight", PlatformNative.GetOperatingSystem(), "no-replace did not preserve both conflicting probe names");
            }
            finally
            {
                UnlinkPreflightProbe(transaction, source, sourceIdentity, sourceOwned);
                UnlinkPreflightProbe(transaction, renamed, sourceIdentity, renamedOwned);
                UnlinkPreflightProbe(transaction, conflict, conflictIdentity, conflictOwned);
                RunMutationTestHook("destination-preflight-after-probe-cleanup-before-transaction-fsync");
                Sync(transaction.Fd, true, "fsync-destination-preflight-probe-cleanup");
            }
        }

        private static UnixPermissionSnapshot GetCreatePermissions(UnixLease parent, UnixLease stage, uint createMode)
        {
            FileObservation parentValue = Stat(parent.Fd, null);
            bool inheritedAcl = Mac ? HasDarwinInheritableAcl(parent.Fd) : HasLinuxXattr(parent.Fd, "system.posix_acl_default");
            if (inheritedAcl)
                throw new PlatformCapabilityUnavailableException("parent-inheritance-acl: inheritable ACL is present", PlatformNative.GetOperatingSystem());

            FileObservation stageValue = Stat(stage.Fd, null);
            uint gid = stageValue.Gid;
            if ((parentValue.Mode & 0x400) != 0)
            {
                ChangeOwnership(stage.Fd, UInt32.MaxValue, parentValue.Gid, "fchown-stage-parent-gid");
                FileObservation changed = Stat(stage.Fd, null);
                if (changed.Gid != parentValue.Gid)
                    throw new PlatformVerificationException("publication-parent-setgid", PlatformNative.GetOperatingSystem(), "stage gid differs from setgid parent gid after fchown");
                gid = parentValue.Gid;
            }
            return new UnixPermissionSnapshot { Mode = ModeText(createMode), Uid = stageValue.Uid, Gid = gid };
        }

        private static void RunMutationTestHook(string point)
        {
            Action<string> hook = MutationTestHook;
            if (hook != null) hook(point);
        }

        private static void RunProbeTestHook(string point)
        {
            Action<string> hook = ProbeTestHook;
            if (hook != null) hook(point);
        }

        public static string GetSha256(UnixLease lease)
        {
            lock (lease.Sync) { lease.Check(); return Hash(lease.Fd, AssertIdentity(lease, lease.Observation, true)); }
        }

        public static UnixPermissionSnapshot GetPermissionSnapshot(UnixLease lease)
        {
            lock (lease.Sync)
            {
                lease.Check(); FileObservation value = AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
                return Snapshot(lease.Fd, value);
            }
        }

        public static UnixPermissionSnapshot SetPermissionSnapshot(UnixLease lease, string mode, ulong uid, ulong gid)
        {
            if (!Regex.IsMatch(mode ?? "", "^[0-7]{3,4}$", RegexOptions.CultureInvariant)) throw new ArgumentException("Unix mode must contain three or four octal digits.");
            lock (lease.Sync)
            {
                lease.Check(); AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file");
                UnixPermissionSnapshot original = Snapshot(lease.Fd, Stat(lease.Fd, null));
                UnixPermissionSnapshot requested = new UnixPermissionSnapshot { Mode = mode, Uid = uid, Gid = gid };
                try
                {
                    ApplyPermissions(lease.Fd, requested);
                    return Snapshot(lease.Fd, Stat(lease.Fd, null));
                }
                catch (Exception failure)
                {
                    try { ApplyPermissions(lease.Fd, original); }
                    catch (Exception rollback)
                    {
                        throw new PlatformMutationException("permissions-rollback", PlatformNative.GetOperatingSystem(), "permission-state-unconfirmed", failure.Message + " Rollback failed: " + rollback.Message, null);
                    }
                    throw;
                }
            }
        }

        public static UnixPublicationResult Publish(UnixLease parent, string leaf, UnixLease transaction, UnixLease stage,
            bool expectedExists, ulong expectedDevice, ulong expectedInode, string expectedSha256, long expectedLength,
            string displacedLeaf, string stageSha256, long stageLength, bool noReplace, uint createMode,
            bool verifyExpectedPermissions, uint expectedMode, ulong expectedUid, ulong expectedGid)
        {
            PlatformPaths.Leaf(leaf);
            if (expectedExists) PlatformPaths.Leaf(displacedLeaf);
            else if (displacedLeaf != null) throw new ArgumentException("displacedLeaf must be null when the target is absent.");
            ValidateAbi();
            if (createMode > 4095) throw new ArgumentOutOfRangeException("createMode");
            lock (parent.Sync) lock (transaction.Sync) lock (stage.Sync)
            {
                parent.Check(); transaction.Check(); stage.Check(); AssertTransaction(transaction, parent);
                bool sameTransaction = SameIdentity(parent.Observation, transaction.Observation);
                bool journalStore = sameTransaction && String.Equals(leaf, "journal.json", StringComparison.OrdinalIgnoreCase) &&
                    String.Equals(stage.Leaf, "journal.stage", StringComparison.OrdinalIgnoreCase) &&
                    (!expectedExists || String.Equals(displacedLeaf, "journal.prev", StringComparison.OrdinalIgnoreCase));
                if (PlatformPaths.IsTransactionStoreTarget(GetVerifiedPath(parent), leaf) && !journalStore)
                    throw new PlatformVerificationException("publication", PlatformNative.GetOperatingSystem(), "target must stay outside .ai-instructions-txn");
                AssertStage(transaction, stage, stageSha256, stageLength);
                FileObservation stageIdentity = Stat(stage.Fd, null);
                Sync(stage.Fd, false, "fsync-stage");
                UnixPermissionSnapshot stageOriginal = Snapshot(stage.Fd, stageIdentity);
                UnixLease target = null;
                bool displaced = false, published = false, permissionsChanged = false, durabilityFailure = false, postVerificationFailure = false;
                UnixPublicationResult receipt = new UnixPublicationResult {
                    AppliedIdentity = stageIdentity, DisplacedLeaf = expectedExists ? displacedLeaf : null,
                    CompletedSteps = new string[] { "stage-file-fsynced" }, Flush = NewFlush("unconfirmed")
                };
                try
                {
                    FileObservation named = TryStat(parent.Fd, leaf);
                    UnixPermissionSnapshot desired = null;
                    if (expectedExists)
                    {
                        if (named == null) throw new PlatformVerificationException("publication", PlatformNative.GetOperatingSystem(), "expected target is absent");
                        target = OpenFile(parent, leaf, "Read", "OpenExisting");
                        AssertState(target, expectedDevice, expectedInode, expectedSha256, expectedLength, "publication-target");
                        receipt.DisplacedIdentity = Stat(target.Fd, null);
                        desired = AssertExpectedPermissions(target.Fd, receipt.DisplacedIdentity,
                            verifyExpectedPermissions, expectedMode, expectedUid, expectedGid, "publication-permissions");
                        if (noReplace) throw Errno("publication-noreplace-target", 17);
                    }
                    else
                    {
                        if (named != null) throw Errno("publication-create-target", 17);
                    }
                    DestinationFilesystemPreflight(parent, transaction, leaf, stage.Leaf, displacedLeaf);
                    receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "destination-preflight");
                    if (!expectedExists)
                    {
                        permissionsChanged = true;
                        desired = verifyExpectedPermissions
                            ? new UnixPermissionSnapshot { Mode = ModeText(expectedMode), Uid = expectedUid, Gid = expectedGid }
                            : GetCreatePermissions(parent, stage, createMode);
                    }
                    receipt.Permissions = desired;
                    permissionsChanged = true; ApplyPermissions(stage.Fd, desired);
                    RunMutationTestHook("publication-after-permission-apply-before-readback");
                    Sync(stage.Fd, false, "fsync-stage-after-permissions");
                    receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "stage-permissions-fsynced");
                    AssertPermissionSnapshot(stage.Fd, desired, "publication-stage-permissions");
                    receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "stage-permissions-verified");
                    RunMutationTestHook("publication-after-preflight-before-revalidation");
                    AssertMutationDirectoryPaths(parent, transaction);
                    AssertState(stage, stageIdentity.Device, stageIdentity.Inode, stageSha256, stageLength,
                        "publication-stage-post-preflight");
                    AssertPermissionSnapshot(stage.Fd, desired, "publication-stage-post-preflight-permissions");
                    if (expectedExists)
                    {
                        AssertState(target, expectedDevice, expectedInode, expectedSha256, expectedLength,
                            "publication-target-post-preflight");
                        AssertPermissionSnapshot(target.Fd, desired, "publication-target-post-preflight-permissions");
                        // Directory fsync only persists directory entries. Persist the
                        // original file data through its fd before renaming that entry.
                        RunMutationTestHook("publication-before-original-file-fsync");
                        Sync(target.Fd, false, "fsync-publication-original-file");
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "original-file-fsynced");
                        RenameNoReplace(parent.Fd, leaf, transaction.Fd, displacedLeaf, "rename-target-to-displaced");
                        displaced = true;
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "target-displaced");
                        PlatformPaths.Same(Stat(transaction.Fd, displacedLeaf), receipt.DisplacedIdentity);
                        try
                        {
                            // After A -> B, persist destination B before source A so the
                            // inode always retains at least one durable name across a crash.
                            RunMutationTestHook("publication-before-backup-transaction-fsync");
                            Sync(transaction.Fd, true, "fsync-publication-backup-transaction"); receipt.Flush.TransactionDirectory = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "backup-transaction-directory-fsynced");
                            RunMutationTestHook("publication-before-backup-parent-fsync");
                            Sync(parent.Fd, true, "fsync-publication-backup-parent"); receipt.Flush.ParentDirectory = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "backup-parent-directory-fsynced");
                        }
                        catch
                        {
                            durabilityFailure = true; receipt.Flush.Durability = "unconfirmed"; throw;
                        }
                    }
                    RunMutationTestHook("publication-before-stage-rename");
                    AssertMutationDirectoryPaths(parent, transaction);
                    AssertState(stage, stageIdentity.Device, stageIdentity.Inode, stageSha256, stageLength,
                        "publication-stage-before-rename");
                    AssertPermissionSnapshot(stage.Fd, desired, "publication-stage-before-rename-permissions");
                    RenameNoReplace(transaction.Fd, stage.Leaf, parent.Fd, leaf, "rename-stage-to-target");
                    published = true;
                    receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "stage-published");
                    receipt.Flush.ParentDirectory = "pending"; receipt.Flush.TransactionDirectory = "pending";
                    PlatformPaths.Same(Stat(parent.Fd, leaf), stageIdentity);
                    try
                    {
                        // stage transaction -> target parent: destination before source.
                        RunMutationTestHook("publication-before-parent-fsync");
                        Sync(parent.Fd, true, "fsync-target-parent"); receipt.Flush.ParentDirectory = "confirmed";
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "parent-directory-fsynced");
                        RunMutationTestHook("publication-before-transaction-fsync");
                        Sync(transaction.Fd, true, "fsync-transaction-directory"); receipt.Flush.TransactionDirectory = "confirmed";
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "transaction-directory-fsynced");
                        receipt.Flush.Durability = "confirmed";
                    }
                    catch
                    {
                        durabilityFailure = true; receipt.Flush.Durability = "unconfirmed";
                        throw;
                    }
                    try
                    {
                        RunMutationTestHook("publication-after-fsync-before-postcheck");
                        AssertMutationDirectoryPaths(parent, transaction);
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "directory-paths-verified");
                        FileObservation applied = Stat(parent.Fd, leaf);
                        PlatformPaths.Same(applied, stageIdentity); PlatformPaths.Single(applied);
                        using (SafeFd publishedFile = Open(parent.Fd, leaf, 0, 0))
                        {
                            FileObservation reopened = AssertFileState(publishedFile, stageIdentity, stageSha256, stageLength,
                                "publication-published-post-verification");
                            PlatformPaths.Same(reopened, applied);
                            AssertPermissionSnapshot(publishedFile, desired, "publication-published-post-verification-permissions");
                        }
                        if (expectedExists)
                        {
                            AssertNamedFileState(transaction.Fd, displacedLeaf, receipt.DisplacedIdentity,
                                expectedSha256, expectedLength, "publication-displaced-post-verification");
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "displaced-content-verified");
                        }
                        receipt.AppliedIdentity = applied;
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "applied-identity-verified");
                    }
                    catch (Exception ex)
                    {
                        postVerificationFailure = true;
                        throw new PlatformMutationException("publication-post-verification", PlatformNative.GetOperatingSystem(), "published-path-identity-unconfirmed", ex.Message, receipt);
                    }
                    return receipt;
                }
                catch (Exception original)
                {
                    if (postVerificationFailure) throw;
                    bool mutated = published || displaced;
                    try
                    {
                        if (published)
                        {
                            AssertMutationDirectoryPaths(parent, transaction);
                            PlatformPaths.Same(Stat(parent.Fd, leaf), stageIdentity);
                            RenameNoReplace(parent.Fd, leaf, transaction.Fd, stage.Leaf, "rollback-target-to-stage"); published = false;
                            receipt.Flush.ParentDirectory = "pending"; receipt.Flush.TransactionDirectory = "pending";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-stage-to-transaction");
                            // target parent -> stage transaction: destination before source.
                            Sync(transaction.Fd, true, "fsync-publication-rollback-stage-transaction"); receipt.Flush.TransactionDirectory = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-stage-transaction-directory-fsynced");
                            Sync(parent.Fd, true, "fsync-publication-rollback-stage-parent"); receipt.Flush.ParentDirectory = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-stage-parent-directory-fsynced");
                        }
                        if (displaced)
                        {
                            AssertMutationDirectoryPaths(parent, transaction);
                            PlatformPaths.Same(Stat(transaction.Fd, displacedLeaf), receipt.DisplacedIdentity);
                            RenameNoReplace(transaction.Fd, displacedLeaf, parent.Fd, leaf, "rollback-displaced-to-target"); displaced = false;
                            receipt.Flush.ParentDirectory = "pending"; receipt.Flush.TransactionDirectory = "pending";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-displaced-to-target");
                            // displaced transaction -> target parent: destination before source.
                            Sync(parent.Fd, true, "fsync-publication-rollback-parent"); receipt.Flush.ParentDirectory = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-parent-directory-fsynced");
                            Sync(transaction.Fd, true, "fsync-publication-rollback-transaction"); receipt.Flush.TransactionDirectory = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-transaction-directory-fsynced");
                        }
                        if (permissionsChanged) ApplyPermissions(stage.Fd, stageOriginal);
                    }
                    catch (Exception rollback)
                    {
                        string state = String.Format("published={0};displaced={1};stage={2}", published, displaced, TryStat(transaction.Fd, stage.Leaf) != null);
                        throw new PlatformMutationException("publication-rollback", PlatformNative.GetOperatingSystem(), state, original.Message + " Rollback failed: " + rollback.Message, receipt);
                    }
                    if (mutated)
                    {
                        receipt.Flush.Durability = "unconfirmed";
                        string capability = durabilityFailure ? "publication-durability" : "publication-mutation";
                        string state = durabilityFailure ? "rolled-back-durability-unconfirmed" : "rolled-back-after-mutation-failure";
                        throw new PlatformMutationException(capability, PlatformNative.GetOperatingSystem(), state, original.Message, receipt);
                    }
                    throw;
                }
                finally { if (target != null) target.Dispose(); }
            }
        }

        public static UnixRemovalResult Remove(UnixLease parent, string leaf, UnixLease transaction, string tombstoneLeaf,
            ulong expectedDevice, ulong expectedInode, string expectedSha256, long expectedLength,
            bool verifyExpectedPermissions, uint expectedMode, ulong expectedUid, ulong expectedGid)
        {
            PlatformPaths.Leaf(leaf); PlatformPaths.Leaf(tombstoneLeaf); ValidateAbi();
            lock (parent.Sync) lock (transaction.Sync)
            {
                parent.Check(); transaction.Check(); AssertTransaction(transaction, parent);
                bool cleanup = SameIdentity(Stat(parent.Fd, null), Stat(transaction.Fd, null));
                if (!cleanup && PlatformPaths.IsTransactionStoreTarget(GetVerifiedPath(parent), leaf))
                    throw new PlatformVerificationException("owned-file-removal", PlatformNative.GetOperatingSystem(), "target must stay outside .ai-instructions-txn");
                if (cleanup && leaf != tombstoneLeaf)
                    throw new PlatformVerificationException("owned-file-removal", PlatformNative.GetOperatingSystem(), "cleanup mode requires identical private leaf names");
                UnixLease target = OpenFile(parent, leaf, "Read", "OpenExisting");
                UnixRemovalResult receipt = new UnixRemovalResult {
                    TombstoneLeaf = tombstoneLeaf, Method = cleanup ? "cleanup-unlinkat" : "tombstone-rename",
                    CompletedSteps = new string[0], Flush = NewFlush("unconfirmed")
                };
                if (!cleanup) receipt.Flush.File = "pending";
                bool moved = false, durabilityFailure = false, postVerificationFailure = false;
                try
                {
                    AssertState(target, expectedDevice, expectedInode, expectedSha256, expectedLength, "owned-file-removal");
                    FileObservation identity = Stat(target.Fd, null);
                    receipt.BackupIdentity = identity;
                    receipt.Permissions = AssertExpectedPermissions(target.Fd, identity,
                        verifyExpectedPermissions, expectedMode, expectedUid, expectedGid, "owned-file-removal-permissions");
                    DestinationFilesystemPreflight(parent, transaction, leaf, tombstoneLeaf);
                    receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "destination-preflight");
                    RunMutationTestHook("removal-after-preflight-before-revalidation");
                    AssertMutationDirectoryPaths(parent, transaction);
                    AssertState(target, expectedDevice, expectedInode, expectedSha256, expectedLength,
                        "owned-file-removal-post-preflight");
                    AssertPermissionSnapshot(target.Fd, receipt.Permissions, "owned-file-removal-post-preflight-permissions");
                    if (cleanup)
                    {
                        RunMutationTestHook("removal-cleanup-before-unlink");
                        AssertMutationDirectoryPaths(parent, transaction);
                        AssertState(target, expectedDevice, expectedInode, expectedSha256, expectedLength,
                            "owned-file-removal-cleanup-before-unlink");
                        Check(Mac ? Darwin.unlinkat(transaction.Fd, leaf, 0) : Linux.unlinkat(transaction.Fd, leaf, 0), "unlinkat-private-cleanup");
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "private-tombstone-unlinked");
                        try
                        {
                            RunMutationTestHook("removal-cleanup-after-unlink-before-fsync");
                            Sync(transaction.Fd, true, "fsync-transaction-cleanup");
                            receipt.Flush.ParentDirectory = "confirmed"; receipt.Flush.TransactionDirectory = "confirmed"; receipt.Flush.Durability = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "transaction-directory-fsynced");
                        }
                        catch (Exception ex)
                        {
                            durabilityFailure = true;
                            receipt.Flush.ParentDirectory = "unconfirmed"; receipt.Flush.TransactionDirectory = "unconfirmed"; receipt.Flush.Durability = "unconfirmed";
                            throw new PlatformMutationException("owned-file-removal-durability", PlatformNative.GetOperatingSystem(), "cleaned-durability-unconfirmed", ex.Message, receipt);
                        }
                        try
                        {
                            RunMutationTestHook("removal-after-fsync-before-postcheck");
                            AssertMutationDirectoryPaths(parent, transaction);
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "directory-paths-verified");
                            if (TryStat(transaction.Fd, leaf) != null)
                                throw new PlatformVerificationException("owned-file-removal", PlatformNative.GetOperatingSystem(), "cleaned private tombstone name is still present");
                        }
                        catch (Exception ex)
                        {
                            postVerificationFailure = true;
                            throw new PlatformMutationException("owned-file-removal-post-verification", PlatformNative.GetOperatingSystem(), "cleanup-path-identity-unconfirmed", ex.Message, receipt);
                        }
                        return receipt;
                    }
                    if (parent.Observation.Device != transaction.Observation.Device)
                        throw new PlatformCapabilityUnavailableException("same-filesystem-rename: EXDEV", PlatformNative.GetOperatingSystem());
                    AssertMutationDirectoryPaths(parent, transaction);
                    AssertState(target, expectedDevice, expectedInode, expectedSha256, expectedLength,
                        "owned-file-removal-before-rename");
                    AssertPermissionSnapshot(target.Fd, receipt.Permissions, "owned-file-removal-before-rename-permissions");
                    // Directory fsync only persists directory entries. Persist the
                    // original file data through its fd before renaming that entry.
                    RunMutationTestHook("removal-before-original-file-fsync");
                    Sync(target.Fd, false, "fsync-removal-original-file");
                    receipt.Flush.File = "confirmed";
                    receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "original-file-fsynced");
                    RenameNoReplace(parent.Fd, leaf, transaction.Fd, tombstoneLeaf, "rename-target-to-tombstone"); moved = true;
                    receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "target-tombstoned");
                    PlatformPaths.Same(Stat(transaction.Fd, tombstoneLeaf), identity);
                    try
                    {
                        // target parent -> tombstone transaction: destination before source.
                        RunMutationTestHook("removal-before-transaction-fsync");
                        Sync(transaction.Fd, true, "fsync-removal-transaction"); receipt.Flush.TransactionDirectory = "confirmed";
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "transaction-directory-fsynced");
                        RunMutationTestHook("removal-before-parent-fsync");
                        Sync(parent.Fd, true, "fsync-removal-parent"); receipt.Flush.ParentDirectory = "confirmed";
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "parent-directory-fsynced");
                        receipt.Flush.Durability = "confirmed";
                    }
                    catch
                    {
                        durabilityFailure = true; receipt.Flush.Durability = "unconfirmed"; throw;
                    }
                    try
                    {
                        RunMutationTestHook("removal-after-fsync-before-postcheck");
                        AssertMutationDirectoryPaths(parent, transaction);
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "directory-paths-verified");
                        AssertNamedFileState(transaction.Fd, tombstoneLeaf, identity, expectedSha256, expectedLength,
                            "owned-file-removal-tombstone-post-verification");
                        receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "tombstone-identity-verified");
                    }
                    catch (Exception ex)
                    {
                        postVerificationFailure = true;
                        throw new PlatformMutationException("owned-file-removal-post-verification", PlatformNative.GetOperatingSystem(), "tombstoned-path-identity-unconfirmed", ex.Message, receipt);
                    }
                    return receipt;
                }
                catch (Exception original)
                {
                    if (postVerificationFailure) throw;
                    bool mutated = moved;
                    if (moved)
                    {
                        try
                        {
                            AssertMutationDirectoryPaths(parent, transaction);
                            PlatformPaths.Same(Stat(transaction.Fd, tombstoneLeaf), receipt.BackupIdentity);
                            RenameNoReplace(transaction.Fd, tombstoneLeaf, parent.Fd, leaf, "rollback-tombstone-to-target"); moved = false;
                            receipt.Flush.ParentDirectory = "pending"; receipt.Flush.TransactionDirectory = "pending";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-tombstone-to-target");
                            // tombstone transaction -> target parent: destination before source.
                            Sync(parent.Fd, true, "fsync-removal-rollback-parent"); receipt.Flush.ParentDirectory = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-parent-directory-fsynced");
                            Sync(transaction.Fd, true, "fsync-removal-rollback-transaction"); receipt.Flush.TransactionDirectory = "confirmed";
                            receipt.CompletedSteps = AddStep(receipt.CompletedSteps, "rollback-transaction-directory-fsynced");
                        }
                        catch (Exception rollback)
                        {
                            throw new PlatformMutationException("owned-file-removal-rollback", PlatformNative.GetOperatingSystem(), "tombstone=" + (TryStat(transaction.Fd, tombstoneLeaf) != null), original.Message + " Rollback failed: " + rollback.Message, receipt);
                        }
                    }
                    if (mutated)
                    {
                        receipt.Flush.Durability = "unconfirmed";
                        string capability = durabilityFailure ? "owned-file-removal-durability" : "owned-file-removal-mutation";
                        string state = durabilityFailure ? "rolled-back-durability-unconfirmed" : "rolled-back-after-mutation-failure";
                        throw new PlatformMutationException(capability, PlatformNative.GetOperatingSystem(), state, original.Message, receipt);
                    }
                    throw;
                }
                finally { target.Dispose(); }
            }
        }

        public static string ProbePublicationPrimitives()
        {
            // Host-level evidence only: per-operation destination filesystem support is
            // established by DestinationFilesystemPreflight in Publish and Remove.
            RunProbeTestHook("publication-probe");
            ValidateAbi(); string rootPath = Mac ? "/private/tmp" : "/tmp";
            string name = "platform-publication-" + Guid.NewGuid().ToString("N");
            using (SafeFd root = WalkRoot(rootPath))
            {
                Check(Mac ? Darwin.mkdirat(root, name, 448) : Linux.mkdirat(root, name, 448), "mkdirat-publication-probe");
                SafeFd directory = null;
                string[] leaves = new string[] { "source", "published", "conflict-source", "conflict-destination" };
                try
                {
                    directory = ChildDirectory(root, name, false);
                    Chmod(directory, 448);
                    if ((Stat(directory, null).Mode & 4095) != 448) throw new IOException("Publication probe directory is not private.");
                    try
                    {
                        using (SafeFd source = Open(directory, leaves[0], 2 | Create | Exclusive, 384)) { Sync(source, false, "fsync-publication-probe-file"); Snapshot(source, Stat(source, null)); }
                        RenameNoReplace(directory, leaves[0], directory, leaves[1], "rename-publication-probe");
                        // Both rename sides are this probe directory; its single fsync
                        // persists the destination name before any cleanup can remove it.
                        using (SafeFd conflictSource = Open(directory, leaves[2], 2 | Create | Exclusive, 384)) { }
                        using (SafeFd conflictDestination = Open(directory, leaves[3], 2 | Create | Exclusive, 384)) { }
                        bool refused = false;
                        try { RenameNoReplace(directory, leaves[2], directory, leaves[3], "rename-publication-probe-conflict"); }
                        catch (PlatformErrnoException ex) { if (ex.Errno != 17) throw; refused = true; }
                        if (!refused || TryStat(directory, leaves[2]) == null || TryStat(directory, leaves[3]) == null)
                            throw new IOException("No-replace publication probe did not preserve both conflicting names.");
                        Sync(directory, true, "fsync-publication-probe-directory");
                        return (Mac ? "renameatx_np(RENAME_EXCL)" : "renameat2(RENAME_NOREPLACE)") + ", file fsync, directory fsync, ACL/flags detection passed";
                    }
                    finally { foreach (string leaf in leaves) if (TryStat(directory, leaf) != null) try { Unlink(directory, leaf, false); } catch { } }
                }
                finally
                {
                    if (directory != null)
                    {
                        try
                        {
                            RunProbeTestHook("publication-probe-before-directory-cleanup:" + rootPath + "/" + name);
                            UnlinkOwnedProbeDirectory(root, name, directory, "publication-probe-cleanup");
                        }
                        finally { directory.Dispose(); }
                    }
                }
            }
        }

        public static string ProbePermissionPrimitives()
        {
            RunProbeTestHook("permissions-probe");
            ValidateAbi(); string rootPath = Mac ? "/private/tmp" : "/tmp";
            string name = "platform-permissions-" + Guid.NewGuid().ToString("N");
            using (SafeFd root = WalkRoot(rootPath))
            {
                Check(Mac ? Darwin.mkdirat(root, name, 448) : Linux.mkdirat(root, name, 448), "mkdirat-permissions-probe");
                SafeFd directory = null;
                try
                {
                    directory = ChildDirectory(root, name, false);
                    using (SafeFd file = Open(directory, "probe", 2 | Create | Exclusive, 384))
                    {
                        try
                        {
                            FileObservation initial = Stat(file, null);
                            UnixPermissionSnapshot snapshot = Snapshot(file, initial);
                            UnixPermissionSnapshot requested = new UnixPermissionSnapshot {
                                Mode = "640", Uid = snapshot.Uid, Gid = snapshot.Gid
                            };
                            ApplyPermissions(file, requested);
                            AssertPermissionSnapshot(file, requested, "permissions-probe");
                            return "descriptor fstat/fchmod mode, uid, gid readback and " +
                                (Mac ? "macOS ACL/file-flags" : "Linux POSIX ACL/inode-flags ioctl") +
                                " detection passed; rename and directory fsync were not required";
                        }
                        finally { if (TryStat(directory, "probe") != null) Unlink(directory, "probe", false); }
                    }
                }
                finally
                {
                    if (directory != null)
                    {
                        try
                        {
                            RunProbeTestHook("permissions-probe-before-directory-cleanup:" + rootPath + "/" + name);
                            UnlinkOwnedProbeDirectory(root, name, directory, "permissions-probe-cleanup");
                        }
                        finally { directory.Dispose(); }
                    }
                }
            }
        }

        public static FileObservation GetPermissions(UnixLease lease) { return AssertIdentity(lease, lease.Observation, lease.Observation.Kind == "file"); }
        public static FileObservation SetPermissions(UnixLease lease, uint mode)
        {
            if (mode > 4095) throw new ArgumentOutOfRangeException("mode");
            lock (lease.Sync)
            {
                GetPermissions(lease); Chmod(lease.Fd, mode);
                FileObservation value = GetPermissions(lease);
                if ((value.Mode & 4095) != mode) throw new IOException("Permission readback failed.");
                return value;
            }
        }
    }
}
