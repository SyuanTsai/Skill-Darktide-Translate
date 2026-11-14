// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    [Serializable]
    public sealed class UnixProcessObservation
    {
        public string RootInventory { get; internal set; }
        public string ExitInventory { get; internal set; }
        public int? WaitIdResult { get; internal set; }
        public int? WaitIdPid { get; internal set; }
        public int? WaitIdErrno { get; internal set; }
        public int? WaitPidResult { get; internal set; }
        public int? WaitPidErrno { get; internal set; }
        public int? KqueueExitStatus { get; internal set; }
        public int? GroupProbeErrno { get; internal set; }
        public bool RootReserved { get; internal set; }
        public int GroupSignalsSent { get; internal set; }
        public bool InventoryComplete { get; internal set; }
        public string WaitBinding { get; internal set; }
        public string ExitCodeSource { get; internal set; }
    }

    internal sealed class UnixProcessControl : IOwnedProcessControl
    {
        [DllImport("libc", EntryPoint = "fcntl", SetLastError = true)] private static extern int InputFlags(SafePipeHandle fd, int command);
        [DllImport("libc", EntryPoint = "fcntl", SetLastError = true)] private static extern int InputSetFlags(SafePipeHandle fd, int command, int flags);
        [DllImport("libc", EntryPoint = "fcntl", SetLastError = true)] private static extern int InputSetFlagsArm64(SafePipeHandle fd, int command, IntPtr x2, IntPtr x3, IntPtr x4, IntPtr x5, IntPtr x6, IntPtr x7, IntPtr flags);
        [DllImport("libc", EntryPoint = "write", SetLastError = true)] private static extern IntPtr WriteInputChunk(SafePipeHandle fd, byte[] buffer, UIntPtr count);
        private static void SetInputFlags(SafePipeHandle fd, int command, int flags)
        {
            int result = PlatformNative.GetOperatingSystem() == "macos" && RuntimeInformation.ProcessArchitecture == Architecture.Arm64
                ? InputSetFlagsArm64(fd, command, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, new IntPtr(flags))
                : InputSetFlags(fd, command, flags);
            if (result < 0) throw new PlatformErrnoException("stdin-fcntl", Marshal.GetLastWin32Error());
        }
        internal static void PrepareInputWriter(SafePipeHandle writer)
        {
            // The read end alone is dup2'd to fd 0. Protect the writer even from
            // unrelated execs in this host; spawn also uses closefrom/CLOEXEC_DEFAULT.
            int flags = InputFlags(writer, 1); // F_GETFD
            if (flags < 0) throw new PlatformErrnoException("stdin-F_GETFD", Marshal.GetLastWin32Error());
            SetInputFlags(writer, 2, flags | 1); // F_SETFD / FD_CLOEXEC
            int actual = InputFlags(writer, 1);
            if (actual < 0 || (actual & 1) == 0) throw new IOException("stdin FD_CLOEXEC readback failed.");
        }
        internal static void WriteInput(SafePipeHandle writer, byte[] bytes, DateTimeOffset deadline)
        {
            int flags = InputFlags(writer, 3), nonblocking = PlatformNative.GetOperatingSystem() == "macos" ? 4 : 0x800;
            if (flags < 0) throw new PlatformErrnoException("stdin-F_GETFL", Marshal.GetLastWin32Error());
            SetInputFlags(writer, 4, flags | nonblocking);
            int actual = InputFlags(writer, 3);
            if (actual < 0 || (actual & nonblocking) == 0) throw new IOException("stdin O_NONBLOCK readback failed.");
            var buffer = new byte[4096];
            int offset = 0;
            while (offset < bytes.Length)
            {
                if (DateTimeOffset.UtcNow >= deadline) throw new TimeoutException("stdin delivery deadline was exceeded.");
                int count = Math.Min(buffer.Length, bytes.Length - offset);
                Array.Copy(bytes, offset, buffer, 0, count);
                long written = WriteInputChunk(writer, buffer, new UIntPtr((uint)count)).ToInt64();
                if (written > 0) { offset += checked((int)written); continue; }
                int errno = Marshal.GetLastWin32Error();
                if (written < 0 && (errno == 4 || errno == 11 || errno == 35)) { Thread.Sleep(10); continue; }
                throw new PlatformErrnoException("stdin-write", errno);
            }
        }
        // Darwin SIGCONT is 19; 18 is SIGTSTP (Linux SIGCONT is 18).
        private const int DarwinSigCont = 19;
        // libc resolves to libSystem on Darwin. All spawn APIs are fixed-arity.
        // Opaque spawn objects are native-initialized in aligned oversized storage:
        // glibc embeds structs, Darwin stores pointers. No internal layout is marshalled.
        [DllImport("libc")] private static extern int posix_spawnattr_init(IntPtr value);
        [DllImport("libc")] private static extern int posix_spawnattr_destroy(IntPtr value);
        [DllImport("libc")] private static extern int posix_spawnattr_setflags(IntPtr value, short flags);
        [DllImport("libc")] private static extern int posix_spawnattr_getflags(IntPtr value, out short flags);
        [DllImport("libc")] private static extern int posix_spawnattr_setpgroup(IntPtr value, int group);
        [DllImport("libc")] private static extern int posix_spawnattr_getpgroup(IntPtr value, out int group);
        [DllImport("libc")] private static extern int posix_spawn_file_actions_init(IntPtr value);
        [DllImport("libc")] private static extern int posix_spawn_file_actions_destroy(IntPtr value);
        [DllImport("libc")] private static extern int posix_spawn_file_actions_adddup2(IntPtr value, int source, int target);
        [DllImport("libc")] private static extern int posix_spawn_file_actions_addfchdir_np(IntPtr value, int fd);
        [DllImport("libc")] private static extern int posix_spawn_file_actions_addclosefrom_np(IntPtr value, int fd);
        [DllImport("libc")] private static extern int posix_spawn(out int pid, [MarshalAs(UnmanagedType.LPUTF8Str)] string executable, IntPtr actions, IntPtr attributes, IntPtr argv, IntPtr envp);
        // Linux prctl is variadic, but Linux x64/arm64 integer varargs follow the
        // normal register ABI. It is NEVER called on Apple arm64.
        [DllImport("libc", SetLastError = true)] private static extern int prctl(int option, UIntPtr arg2, UIntPtr arg3, UIntPtr arg4, UIntPtr arg5);
        [DllImport("libc", EntryPoint = "prctl", SetLastError = true)] private static extern int prctl_get(int option, out int value, UIntPtr arg3, UIntPtr arg4, UIntPtr arg5);
        [DllImport("libc", SetLastError = true)] private static extern int waitpid(int pid, out int status, int options);
        [DllImport("libc", SetLastError = true)] private static extern int waitid(int kind, uint pid, IntPtr info, int options);
        [DllImport("libc", SetLastError = true)] private static extern int kqueue();
        [StructLayout(LayoutKind.Sequential)]
        private struct Kevent
        {
            internal UIntPtr Ident;
            internal short Filter;
            internal ushort Flags;
            internal uint FilterFlags;
            internal IntPtr Data, UserData;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct Timespec { internal IntPtr Seconds, Nanoseconds; }
        [DllImport("libc", SetLastError = true)] private static extern int kevent(SafeFd queue, [In] Kevent[] changes, int changeCount, [Out] Kevent[] events, int eventCount, ref Timespec timeout);
        [DllImport("libc", EntryPoint = "fcntl", SetLastError = true)] private static extern int fcntlGetPath(int fd, int command, IntPtr path);
        // Apple arm64 varargs start on the stack: x2..x7 are deliberately unused.
        [DllImport("libc", EntryPoint = "fcntl", SetLastError = true)] private static extern int fcntlGetPathArm64(int fd, int command, IntPtr x2, IntPtr x3, IntPtr x4, IntPtr x5, IntPtr x6, IntPtr x7, IntPtr path);
        [DllImport("libc", SetLastError = true)] private static extern int kill(int pid, int signal);
        // Linux-only, fixed-arity libc APIs. No syscall-number or variadic ABI assumptions.
        [DllImport("libc", SetLastError = true)] private static extern int pidfd_open(int pid, uint flags);
        [DllImport("libc", SetLastError = true)] private static extern int pidfd_send_signal(int fd, int signal, IntPtr info, uint flags);
        [DllImport("libc", SetLastError = true)] private static extern int getpgid(int pid);
        [DllImport("libc")] private static extern uint geteuid();
        [DllImport("/usr/lib/libproc.dylib", SetLastError = true)] private static extern int proc_pidinfo(int pid, int flavor, ulong arg, IntPtr buffer, int size);
        [DllImport("/usr/lib/libproc.dylib", SetLastError = true)] private static extern int proc_listpids(uint type, uint typeInfo, IntPtr buffer, int size);

        private sealed class Identity
        {
            internal int Pid, Parent, Group;
            internal string Start;
            internal bool Zombie;
        }
        private sealed class Vector : IDisposable
        {
            internal IntPtr Pointer;
            private readonly List<IntPtr> strings = new List<IntPtr>();
            internal Vector(string[] values)
            {
                try
                {
                    Pointer = Marshal.AllocHGlobal((values.Length + 1) * IntPtr.Size);
                    for (int i = 0; i < values.Length; i++)
                    {
                        byte[] bytes = Encoding.UTF8.GetBytes(values[i] + "\0");
                        IntPtr value = Marshal.AllocHGlobal(bytes.Length); strings.Add(value);
                        Marshal.Copy(bytes, 0, value, bytes.Length); Marshal.WriteIntPtr(Pointer, i * IntPtr.Size, value);
                    }
                    Marshal.WriteIntPtr(Pointer, values.Length * IntPtr.Size, IntPtr.Zero);
                }
                catch { Dispose(); throw; }
            }
            public void Dispose() { foreach (IntPtr value in strings) Marshal.FreeHGlobal(value); strings.Clear(); if (Pointer != IntPtr.Zero) { Marshal.FreeHGlobal(Pointer); Pointer = IntPtr.Zero; } }
        }

        private static readonly object spawnGate = new object();
        private static bool active;
        // Failed startup OR unresolved Dispose still owns its descendants. Keep
        // bindings rooted in the runtime until a later cleanup retry succeeds.
        private static UnixProcessControl pendingFailedStart;
        private readonly bool mac = PlatformNative.GetOperatingSystem() == "macos";
        private readonly int supervisor = Process.GetCurrentProcess().Id;
        private readonly Dictionary<int, Identity> owned = new Dictionary<int, Identity>();
        private readonly HashSet<string> baseline = new HashSet<string>();
        private readonly HashSet<int> unreadable = new HashSet<int>();
        private readonly HashSet<string> excluded = new HashSet<string>();
        private readonly HashSet<string> unboundSignals = new HashSet<string>();
        private readonly Dictionary<string, int> boundPidfds = new Dictionary<string, int>();
        private string uncertainty;
        private Dictionary<int, Identity> last = new Dictionary<int, Identity>();
        private bool released, cleanupStarted, rootReaped;
        private bool inventoryIncomplete;
        private bool rootReserved, rootGroupLost, rootAnchorLost;
        private bool darwinGroupEmpty;
        private int groupSignalsSent;
        private int startupSignalsSent;
        private int censusGeneration, exitObservedCensus = -1;
        private SafeFd exitQueue;
        private string rootInventory, exitInventory, exitCodeSource;
        private int? waitIdResult, waitIdPid, waitIdErrno, waitPidResult, waitPidErrno, kqueueExitStatus, groupProbeErrno;
        private Func<int, Tuple<int, int, int>> peekChild;
        private Func<int?> readExitEvent;
        private UnixProcessControl()
        { peekChild = pid => mac ? PeekDarwinChild(pid) : WaitOwnedLinuxChild(pid, true); waitForChild = WaitOwnedChild; readExitEvent = ReadExitEvent; }
        // Instance-local syscall boundaries allow deterministic race regression tests.
        // No global hooks, environment switches or public injection API.
        private Func<int, string> readStat = pid => File.ReadAllText("/proc/" + pid.ToString(CultureInfo.InvariantCulture) + "/stat");
        private Func<int, byte[]> readBsdInfo = ReadBsdInfo;
        private Func<uint> effectiveUid = geteuid;
        private Func<int[]> listLinuxPids = ListLinuxPids;
        private Func<uint, uint, int[]> listDarwinPids = ListDarwinPids;
        private Func<int, int, int> sendSignal = (pid, signal) => kill(pid, signal) == 0 ? 0 : Marshal.GetLastWin32Error();
        private Func<int, Tuple<int, int>> openPidfd = pid =>
        { int fd = pidfd_open(pid, 0); return Tuple.Create(fd, fd < 0 ? Marshal.GetLastWin32Error() : 0); };
        private Func<int, int, int> sendPidfdSignal = (fd, signal) => pidfd_send_signal(fd, signal, IntPtr.Zero, 0) == 0 ? 0 : Marshal.GetLastWin32Error();
        private Action<int> closePidfd = fd => UnixNative.Close(fd);
        private Func<int, Tuple<int, int, int>> waitForChild;
        private Func<int, int, bool, Tuple<int, int, int>> waitPidfd = WaitLinuxPidfd;
        private Func<int, uint, IntPtr, int, Tuple<int, int>> waitDarwin = (kind, pid, info, options) =>
        { int result = waitid(kind, pid, info, options); return Tuple.Create(result, result < 0 ? Marshal.GetLastWin32Error() : 0); };
        public int Pid { get; private set; }
        public string StartIdentity { get; private set; }
        public string Isolation { get { return mac ? "macos-process-group" : "linux-process-group-subreaper"; } }
        public bool Exited { get; private set; }
        public int? ExitCode { get; private set; }
        public string Uncertainty
        {
            get
            {
                if (uncertainty != null) return uncertainty;
                foreach (Identity value in owned.Values)
                    if (unboundSignals.Contains(Key(value))) return "macos-unbound-pid-signal-refused: " + value.Pid.ToString(CultureInfo.InvariantCulture);
                if (mac && rootAnchorLost)
                {
                    if (owned.Count != 0 || (!darwinGroupEmpty && (groupProbeErrno == 0 || groupProbeErrno == 1))) return "root-anchor-lost";
                    foreach (Identity value in last.Values) if (value.Group == Pid) return "root-anchor-lost";
                }
                return null;
            }
        }
        internal UnixProcessObservation Observation
        {
            get { return new UnixProcessObservation { RootInventory = rootInventory, ExitInventory = exitInventory, WaitIdResult = waitIdResult, WaitIdPid = waitIdPid, WaitIdErrno = waitIdErrno,
                WaitPidResult = waitPidResult, WaitPidErrno = waitPidErrno, KqueueExitStatus = kqueueExitStatus, GroupProbeErrno = groupProbeErrno, ExitCodeSource = exitCodeSource,
                RootReserved = rootReserved, GroupSignalsSent = groupSignalsSent,
                InventoryComplete = !inventoryIncomplete, WaitBinding = mac ? "kqueue-exit-with-waitid-WNOWAIT-reservation" : "waitid-P_PIDFD" }; }
        }
        private static string Key(Identity value) { return value.Pid.ToString(CultureInfo.InvariantCulture) + ":" + value.Start; }
        private static void Check(int result, string operation) { if (result != 0) throw new PlatformErrnoException(operation, result); }
        private void Unknown(string reason) { if (uncertainty == null) uncertainty = reason; }

        private void ProbePidfd()
        {
            try
            {
                // The executing supervisor cannot be replaced during this probe.
                Tuple<int, int> opened = openPidfd(supervisor);
                if (opened.Item1 < 0) throw new PlatformErrnoException("pidfd_open-probe", opened.Item2);
                try
                {
                    Check(sendPidfdSignal(opened.Item1, 0), "pidfd_send_signal-probe");
                    Tuple<int, int, int> wait = waitPidfd(supervisor, opened.Item1, true);
                    if (wait.Item1 != -1 || wait.Item3 != 10)
                        throw new PlatformErrnoException("waitid-P_PIDFD-probe", wait.Item3); // self is never our child
                }
                finally { closePidfd(opened.Item1); }
            }
            catch (EntryPointNotFoundException)
            { throw new PlatformCapabilityUnavailableException("linux-pidfd-required-entrypoint", "linux"); }
        }

        private void RecordSpawnIdentity(int pid)
        {
            Identity spawned = Read(pid);
            if (spawned == null || spawned.Parent != supervisor)
                throw new IOException("Spawn child identity verification failed.");
            StartIdentity = spawned.Start; owned[pid] = spawned;
            if (!mac && !BindIdentity(spawned)) throw new IOException("Spawn pidfd identity binding failed.");
            // A running Linux child can already have changed groups. Retain its
            // verified identity so failure cleanup can bind a pidfd to that child.
            if (spawned.Group != pid) throw new IOException("Spawn process-group identity verification failed.");
        }

        private bool BindIdentity(Identity expected)
        {
            if (mac) return false;
            if (boundPidfds.ContainsKey(Key(expected))) return true;
            try
            {
                Tuple<int, int> opened = openPidfd(expected.Pid);
                if (opened.Item1 < 0)
                {
                    if (opened.Item2 != 3) Unknown("pidfd-open-failed: " + opened.Item2);
                    return false;
                }
                bool retained = false;
                try
                {
                    // Open first, then verify. After verification the descriptor
                    // continues to address this process even if the PID is reused.
                    Identity current = ReadObserved(expected.Pid, true);
                    if (current == null) return false;
                    if (current.Start != expected.Start) { RetireReplacement(expected, current); return false; }
                    boundPidfds.Add(Key(expected), opened.Item1); retained = true;
                    return true;
                }
                finally { if (!retained) closePidfd(opened.Item1); }
            }
            catch (EntryPointNotFoundException) { Unknown("linux-pidfd-required-entrypoint"); return false; }
        }

        private bool SignalIndividual(Identity expected, int signal)
        {
            if (mac) { unboundSignals.Add(Key(expected)); return false; }
            // Once bound, neither a failed census nor a later stat read is needed
            // to authorize a signal. The fd cannot address a replacement process.
            if (!BindIdentity(expected)) return false;
            int errno = sendPidfdSignal(boundPidfds[Key(expected)], signal);
            if (errno == 0) return true;
            if (errno != 3) Unknown("pidfd-send-signal-failed: " + errno);
            return false;
        }

        private void ForgetOwned(int pid)
        {
            Identity expected;
            if (owned.TryGetValue(pid, out expected))
            {
                int fd;
                if (boundPidfds.TryGetValue(Key(expected), out fd))
                { boundPidfds.Remove(Key(expected)); closePidfd(fd); }
                unboundSignals.Remove(Key(expected)); owned.Remove(pid);
            }
        }

        private void ClosePidfds()
        { foreach (int fd in boundPidfds.Values) closePidfd(fd); boundPidfds.Clear(); }

        private Tuple<int, int, int> WaitOwnedLinuxChild(int pid, bool peek)
        {
            Identity expected;
            if (!owned.TryGetValue(pid, out expected) || !BindIdentity(expected))
                throw new IOException("Cannot wait without a verified pidfd.");
            return waitPidfd(pid, boundPidfds[Key(expected)], peek);
        }

        private Tuple<int, int, int> WaitOwnedChild(int pid)
        {
            if (!mac) return WaitOwnedLinuxChild(pid, false);
            int status; int waited = waitpid(pid, out status, 1);
            return Tuple.Create(waited, status, waited < 0 ? Marshal.GetLastWin32Error() : 0);
        }

        private static Tuple<int, int, int> WaitLinuxPidfd(int pid, int fd, bool peek)
        {
            // Linux siginfo_t and wait options differ from Darwin's (see below).
            // P_PIDFD binds reaping as well as signalling. P_PID would have the
            // same read/wait PID-reuse race when another waiter reaps the child.
            IntPtr info = Marshal.AllocHGlobal(256);
            try
            {
                Marshal.Copy(new byte[256], 0, info, 256);
                int result = waitid(3, (uint)fd, info, 1 | 4 | (peek ? 0x01000000 : 0)); // P_PIDFD, NOHANG, EXITED, optional NOWAIT
                if (result < 0) return Tuple.Create(-1, 0, Marshal.GetLastWin32Error());
                int child = Marshal.ReadInt32(info, 16);
                if (child == 0) return Tuple.Create(0, 0, 0);
                int code = Marshal.ReadInt32(info, 8), status = Marshal.ReadInt32(info, 24);
                if (child != pid || Marshal.ReadInt32(info, 0) != 17 || code < 1 || code > 3)
                    throw new IOException("waitid SIGCHLD ABI mismatch.");
                return Tuple.Create(child, code == 1 ? status << 8 : status & 127, 0);
            }
            finally { Marshal.FreeHGlobal(info); }
        }

        private Tuple<int, int, int> PeekDarwinChild(int pid)
        {
            // Darwin <sys/wait.h>: P_PID=1, WNOHANG=1, WEXITED=4, WNOWAIT=0x20.
            // <sys/signal.h> starts siginfo_t with four int32 fields:
            // signo, errno, code, pid. SIGCHLD is 20, NOT Linux's 17. The remaining
            // pointer/union fields are deliberately not marshalled. Exit status
            // still comes from the pre-spawn kqueue watch, including external reap.
            // This fixed-arity call only verifies waitability; it never consumes it.
            IntPtr info = Marshal.AllocHGlobal(256);
            try
            {
                Marshal.Copy(new byte[256], 0, info, 256);
                Tuple<int, int> result = waitDarwin(1, (uint)pid, info, 1 | 4 | 0x20);
                if (result.Item1 < 0) return Tuple.Create(-1, 0, result.Item2);
                int child = Marshal.ReadInt32(info, 12);
                if (child == 0) return Tuple.Create(0, 0, 0);
                if (child != pid || Marshal.ReadInt32(info, 0) != 20)
                    throw new IOException("Darwin waitid reservation ABI mismatch.");
                return Tuple.Create(child, 0, 0);
            }
            finally { Marshal.FreeHGlobal(info); }
        }

        private void InstallExitWatch()
        {
            if (Marshal.SizeOf(typeof(Kevent)) != 32 || Marshal.OffsetOf(typeof(Kevent), "Data").ToInt32() != 16)
                throw new IOException("Darwin kevent ABI mismatch.");
            int fd = kqueue(); if (fd < 0) throw new PlatformErrnoException("kqueue", Marshal.GetLastWin32Error());
            exitQueue = new SafeFd(fd);
            var changes = new Kevent[] { new Kevent { Ident = new UIntPtr((uint)Pid), Filter = -5, Flags = 1 | 4 | 0x10, FilterFlags = 0x80000000 | 0x04000000 } };
            var events = new Kevent[1]; var timeout = new Timespec();
            int count = kevent(exitQueue, changes, 1, events, 1, ref timeout);
            if (count < 0) throw new PlatformErrnoException("kevent-register", Marshal.GetLastWin32Error());
            if (count != 0) throw new IOException("Could not register suspended root exit watch.");
        }

        private int? ReadExitEvent()
        {
            if (exitQueue == null || kqueueExitStatus.HasValue) return kqueueExitStatus;
            var events = new Kevent[1]; var timeout = new Timespec();
            int count = kevent(exitQueue, null, 0, events, 1, ref timeout);
            if (count < 0) { int errno = Marshal.GetLastWin32Error(); if (errno == 4) return null; throw new PlatformErrnoException("kevent-poll", errno); }
            if (count == 0) return null;
            Kevent value = events[0];
            if ((value.Flags & 0x4000) != 0 || value.Ident.ToUInt64() != (ulong)Pid || value.Filter != -5 || (value.FilterFlags & 0x80000000) == 0)
                throw new IOException("Unexpected Darwin process exit event.");
            return checked((int)value.Data.ToInt64());
        }

        private static string MacExecutablePath(UnixLease executable)
        {
            IntPtr buffer = Marshal.AllocHGlobal(1024); // Darwin MAXPATHLEN
            try
            {
                Marshal.Copy(new byte[1024], 0, buffer, 1024);
                int fd = executable.Fd.DangerousGetHandle().ToInt32();
                int result = RuntimeInformation.ProcessArchitecture == Architecture.Arm64
                    ? fcntlGetPathArm64(fd, 50, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, buffer)
                    : fcntlGetPath(fd, 50, buffer); // F_GETPATH; /dev/fd is not an exec-by-fd API on Darwin.
                if (result != 0) throw new PlatformErrnoException("fcntl-F_GETPATH", Marshal.GetLastWin32Error());
                byte[] bytes = new byte[1024]; Marshal.Copy(buffer, bytes, 0, bytes.Length);
                int end = Array.IndexOf(bytes, (byte)0);
                if (end <= 0) throw new IOException("Executable path unavailable.");
                string path = new UTF8Encoding(false, true).GetString(bytes, 0, end);
                using (UnixLease parent = OpenExecutableParent(path))
                using (UnixLease file = UnixNative.OpenFile(parent, Path.GetFileName(path), "Read", "OpenExisting"))
                    PlatformPaths.Same(file.Observation, executable.Observation);
                return path;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private Identity Read(int pid)
        {
            if (!mac)
            {
                string value;
                try { value = readStat(pid); }
                catch (FileNotFoundException) { return null; }
                catch (DirectoryNotFoundException) { return null; }
                catch (IOException ex)
                {
                    // .NET Unix uses raw errno for some read failures; some runtimes
                    // encode it as HRESULT_FROM_WIN32. Classify only ENOENT/ESRCH.
                    if (ex.HResult == 2 || ex.HResult == 3 || ex.HResult == unchecked((int)0x80070002) || ex.HResult == unchecked((int)0x80070003)) return null;
                    throw;
                }
                // comm may contain spaces, ')' or newlines. Fields after the LAST ')'
                // begin at state (field 3); starttime is field 22, offset 19.
                int end = value.LastIndexOf(')');
                if (end < 0) throw new IOException("Malformed proc stat identity.");
                string[] fields = value.Substring(end + 2).Split(new char[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                if (fields.Length < 20) throw new IOException("Truncated proc stat identity.");
                return new Identity { Pid = pid, Parent = Int32.Parse(fields[1], CultureInfo.InvariantCulture), Group = Int32.Parse(fields[2], CultureInfo.InvariantCulture), Start = fields[19], Zombie = fields[0] == "Z" || fields[0] == "X" };
            }
            byte[] info = readBsdInfo(pid);
            if (info == null) return null;
            if (info.Length != 136 || BitConverter.ToInt32(info, 12) != pid) throw new IOException("Darwin proc_bsdinfo ABI mismatch.");
            ulong sec = BitConverter.ToUInt64(info, 120), usec = BitConverter.ToUInt64(info, 128);
            if (sec == 0 || usec >= 1000000) throw new IOException("Darwin start-time identity invalid.");
            return new Identity { Pid = pid, Parent = BitConverter.ToInt32(info, 16), Group = BitConverter.ToInt32(info, 100), Zombie = BitConverter.ToInt32(info, 4) == 5, Start = sec.ToString(CultureInfo.InvariantCulture) + ":" + usec.ToString(CultureInfo.InvariantCulture) };
        }

        private static byte[] ReadBsdInfo(int pid)
        {
            IntPtr buffer = Marshal.AllocHGlobal(136);
            try
            {
                int size = proc_pidinfo(pid, 3, 0, buffer, 136); // PROC_PIDTBSDINFO, proc_bsdinfo
                if (size == 0)
                {
                    int errno = Marshal.GetLastWin32Error();
                    if (errno == 3 || errno == 2) return null;
                    throw new PlatformErrnoException("proc_pidinfo", errno);
                }
                if (size != 136) throw new IOException("Darwin proc_bsdinfo ABI mismatch.");
                var info = new byte[136]; Marshal.Copy(buffer, info, 0, info.Length); return info;
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }

        private static int[] ListLinuxPids()
        {
            var pids = new List<int>();
            foreach (string path in Directory.GetDirectories("/proc")) { int pid; if (Int32.TryParse(Path.GetFileName(path), out pid)) pids.Add(pid); }
            return pids.ToArray();
        }

        private static int[] ListDarwinPids(uint kind, uint value)
        {
            // PROC_UID_ONLY=4, PROC_PPID_ONLY=6, PROC_PGRP_ONLY=2.
            // Read-only census: do not require access to unrelated system services.
            int bytes = proc_listpids(kind, value, IntPtr.Zero, 0);
            if (bytes < 0) throw new PlatformErrnoException("proc_listpids-size", Marshal.GetLastWin32Error());
            if (bytes == 0 && Marshal.GetLastWin32Error() != 0) throw new PlatformErrnoException("proc_listpids-size", Marshal.GetLastWin32Error());
            for (int attempt = 0; attempt < 4; attempt++)
            {
                bytes = checked(bytes * 2 + 4096); IntPtr buffer = Marshal.AllocHGlobal(bytes);
                try
                {
                    int used = proc_listpids(kind, value, buffer, bytes);
                    if (used < 0 || used % 4 != 0) throw new IOException("Darwin process inventory unavailable.");
                    if (used == 0 && Marshal.GetLastWin32Error() != 0) throw new PlatformErrnoException("proc_listpids", Marshal.GetLastWin32Error());
                    if (used >= bytes) continue;
                    var pids = new List<int>();
                    for (int offset = 0; offset < used; offset += 4) { int pid = Marshal.ReadInt32(buffer, offset); if (pid > 0) pids.Add(pid); }
                    return pids.ToArray();
                }
                finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new IOException("Darwin process inventory kept growing.");
        }

        private Identity ReadObserved(int pid, bool required)
        {
            try { return Read(pid); }
            catch (UnauthorizedAccessException) { }
            catch (PlatformErrnoException ex) { if (ex.Errno != 1 && ex.Errno != 13) throw; }
            if (required) { unreadable.Add(pid); Unknown("owned-process-inventory-permission-denied: " + pid.ToString(CultureInfo.InvariantCulture)); }
            return null;
        }

        private Dictionary<int, Identity> Snapshot()
        {
            unreadable.Clear();
            var pids = new HashSet<int>(mac ? listDarwinPids(4, effectiveUid()) : listLinuxPids());
            // The UID census is a discovery aid, never proof that an owned PID exited.
            // An owned process can change credentials or be omitted by a racing census.
            foreach (int pid in owned.Keys) pids.Add(pid);
            pids.Add(supervisor);
            var result = new Dictionary<int, Identity>();
            foreach (int pid in pids)
            {
                Identity value = ReadObserved(pid, owned.ContainsKey(pid) || pid == supervisor);
                if (value != null) result[pid] = value;
            }
            if (mac && Pid > 0)
            {
                // A denied descendant must not disappear merely because it wasn't
                // readable in the UID census. Query children/group from verified roots.
                // An exit event permits discovery only. If the root is no longer
                // readable, candidates are not adopted until waitpid confirms a
                // waitable root following this post-exit census.
                var queue = new Queue<int>(); var visited = new HashSet<int>(); bool anchor = rootReserved || (Exited && !rootReaped);
                foreach (Identity expected in owned.Values)
                {
                    Identity actual;
                    if (result.TryGetValue(expected.Pid, out actual) && actual.Start == expected.Start)
                    { queue.Enqueue(actual.Pid); if (actual.Group == Pid) anchor = true; }
                }
                if (anchor)
                    foreach (int member in listDarwinPids(2, (uint)Pid))
                    { Identity value = ReadObserved(member, true); if (value != null) { result[member] = value; queue.Enqueue(member); } }
                while (queue.Count > 0)
                {
                    int parent = queue.Dequeue(); if (!visited.Add(parent)) continue;
                    foreach (int child in listDarwinPids(6, (uint)parent))
                    { Identity value = ReadObserved(child, true); if (value != null) { result[child] = value; queue.Enqueue(child); } }
                }
            }
            return result;
        }

        private static UnixLease OpenExecutableParent(string path)
        {
            string parent = Path.GetDirectoryName(path);
            return parent == "/" ? UnixNative.OpenDirectoryRoot("/") : UnixNative.OpenDirectory("/", parent.TrimStart('/'), false);
        }

        private static void EnsureStartAvailable()
        {
            if (pendingFailedStart != null)
            {
                var failure = new PlatformCapabilityUnavailableException("owned-process: previous process cleanup is incomplete", PlatformNative.GetOperatingSystem());
                // Allow a post-exit census before deciding whether the retained
                // zombie can be reaped. One zero-duration poll cannot prove that.
                pendingFailedStart.FinishFailedStart(failure, TimeSpan.FromMilliseconds(100));
                if (pendingFailedStart != null) throw failure;
            }
            if (active) throw new PlatformCapabilityUnavailableException("owned-process: another Unix lease is active", PlatformNative.GetOperatingSystem());
        }

        internal static UnixProcessControl Start(string path, UnixLease executable, string[] args, string[] env, UnixLease cwd, int input, int output, int error, string argumentZero = null)
        {
            if (String.IsNullOrEmpty(argumentZero)) argumentZero = null;
            else if (argumentZero.IndexOf('\0') >= 0 || !Path.IsPathFullyQualified(argumentZero))
                throw new ArgumentException("ArgumentZero must be an absolute path without NUL.");
            lock (spawnGate)
            {
                // Subreaper is process-wide. Serialize leases rather than attributing
                // another lease's adopted children to this one. External host children
                // still make cleanup uncertain; never kill/reap an unowned PID.
                EnsureStartAvailable();
                var result = new UnixProcessControl();
                UnixNative.ValidateAbi();
                if (IntPtr.Size != 8) throw new PlatformCapabilityUnavailableException("unix-process-abi", PlatformNative.GetOperatingSystem());
                if (input < 3 || output < 3 || error < 3)
                    throw new PlatformCapabilityUnavailableException("spawn-descriptor-collision", PlatformNative.GetOperatingSystem());
                Identity self = result.Read(result.supervisor);
                if (self == null || self.Group != getpgid(result.supervisor)) throw new IOException("Process identity ABI self-check failed.");
                if (!result.mac)
                {
                    result.ProbePidfd();
                    if (prctl(36, new UIntPtr(1), UIntPtr.Zero, UIntPtr.Zero, UIntPtr.Zero) != 0) throw new PlatformErrnoException("PR_SET_CHILD_SUBREAPER", Marshal.GetLastWin32Error());
                    int enabled;
                    if (prctl_get(37, out enabled, UIntPtr.Zero, UIntPtr.Zero, UIntPtr.Zero) != 0 || enabled != 1) throw new IOException("Subreaper readback failed.");
                }
                foreach (Identity entry in result.Snapshot().Values) result.baseline.Add(Key(entry));
                if (result.Uncertainty != null) throw new PlatformCapabilityUnavailableException(result.Uncertainty, PlatformNative.GetOperatingSystem());
                IntPtr attributes = Marshal.AllocHGlobal(1024), actions = Marshal.AllocHGlobal(1024);
                bool attrReady = false, actionsReady = false, success = false;
                Exception startupFailure = null;
                try
                {
                    Check(posix_spawnattr_init(attributes), "spawnattr-init"); attrReady = true;
                    Check(posix_spawn_file_actions_init(actions), "spawn-actions-init"); actionsReady = true;
                    // Darwin starts suspended so identity and NOTE_EXITSTATUS are
                    // registered before even a very short executable can exit.
                    short flags = (short)(2 | (result.mac ? 0x4080 : 0)); // SETPGROUP; CLOEXEC_DEFAULT | START_SUSPENDED
                    Check(posix_spawnattr_setflags(attributes, flags), "spawnattr-setflags");
                    Check(posix_spawnattr_setpgroup(attributes, 0), "spawnattr-setpgroup");
                    short actualFlags; int group;
                    Check(posix_spawnattr_getflags(attributes, out actualFlags), "spawnattr-getflags");
                    Check(posix_spawnattr_getpgroup(attributes, out group), "spawnattr-getpgroup");
                    if (actualFlags != flags || group != 0) throw new IOException("posix_spawn attribute ABI readback failed.");
                    lock (cwd.Sync)
                    {
                        UnixNative.AssertIdentity(cwd, cwd.Observation, false);
                        if (cwd.Observation.Kind != "directory") throw new ArgumentException("WorkingDirectoryLease must be a directory.");
                        Check(posix_spawn_file_actions_addfchdir_np(actions, cwd.Fd.DangerousGetHandle().ToInt32()), "spawn-fchdir");
                        Check(posix_spawn_file_actions_adddup2(actions, input, 0), "spawn-stdin");
                        Check(posix_spawn_file_actions_adddup2(actions, output, 1), "spawn-stdout");
                        Check(posix_spawn_file_actions_adddup2(actions, error, 2), "spawn-stderr");
                        object executableGate = executable == null ? new object() : executable.Sync;
                        lock (executableGate)
                        {
                            if (executable != null)
                            {
                                FileObservation executableInfo = UnixNative.AssertIdentity(executable, executable.Observation, true);
                                if ((executableInfo.Mode & 73) == 0) throw new PlatformErrnoException("executable-lease-permission", 13); // 0111
                                if (executable.Fd.DangerousGetHandle().ToInt32() < 3)
                                    throw new PlatformCapabilityUnavailableException("spawn-executable-descriptor-collision", PlatformNative.GetOperatingSystem());
                                if (result.mac) path = MacExecutablePath(executable);
                                else
                                {
                                    // spawn dup2 clears FD_CLOEXEC on fd 3, including
                                    // when source == target. Keep it below closefrom(4)
                                    // so a shebang interpreter can reopen the script.
                                    Check(posix_spawn_file_actions_adddup2(actions, executable.Fd.DangerousGetHandle().ToInt32(), 3), "spawn-executable-fd");
                                    path = "/proc/self/fd/3";
                                }
                            }
                            if (String.IsNullOrEmpty(path) || !Path.IsPathRooted(path) || path.IndexOf('\0') >= 0) throw new ArgumentException("ExecutablePath must be absolute.");
                            if (!result.mac) Check(posix_spawn_file_actions_addclosefrom_np(actions, executable == null ? 3 : 4), "spawn-closefrom");
                            // Invocation identity is independent of the exec target:
                            // e.g. Python locates pyvenv.cfg beside the original alias.
                            string[] argv = new string[args.Length + 1]; argv[0] = argumentZero ?? path; Array.Copy(args, 0, argv, 1, args.Length);
                            using (var arguments = new Vector(argv)) using (var environment = new Vector(env))
                            {
                                int pid;
                                Check(posix_spawn(out pid, path, actions, attributes, arguments.Pointer, environment.Pointer), "posix_spawn");
                                result.Pid = pid;
                                // Capture identity before any post-spawn operation
                                // can throw. Failure cleanup never authorizes a PID
                                // merely because posix_spawn once returned it.
                                result.RecordSpawnIdentity(pid);
                                // Darwin has no exec-by-fd primitive here. Verify the
                                // leased path on both sides of spawn, before resuming.
                                // This is cooperative path validation, not atomic fd exec.
                                if (result.mac && executable != null && MacExecutablePath(executable) != path)
                                    throw new IOException("Executable lease path changed during spawn.");
                            }
                        }
                    }
                    if (result.mac)
                    {
                        result.InstallExitWatch();
                        Identity stopped = result.Read(result.Pid);
                        if (stopped == null || stopped.Start != result.StartIdentity || stopped.Group != result.Pid)
                            throw new IOException("Suspended root identity changed before SIGCONT.");
                        Check(result.sendSignal(-result.Pid, DarwinSigCont), "spawn-group-SIGCONT");
                    }
                    result.Poll(); active = true; success = true; return result;
                }
                catch (EntryPointNotFoundException ex)
                { startupFailure = new PlatformCapabilityUnavailableException("posix-spawn-required-entrypoint: " + ex.Message, PlatformNative.GetOperatingSystem()); throw startupFailure; }
                catch (Exception ex) { startupFailure = ex; throw; }
                finally
                {
                    if (actionsReady) posix_spawn_file_actions_destroy(actions);
                    if (attrReady) posix_spawnattr_destroy(attributes);
                    Marshal.FreeHGlobal(actions); Marshal.FreeHGlobal(attributes);
                    if (!success)
                    {
                        if (result.Pid > 0) result.FinishFailedStart(startupFailure, TimeSpan.FromSeconds(5));
                        else result.ReleaseStartupBindings();
                    }
                }
            }
        }

        private void ReleaseStartupBindings()
        {
            if (exitQueue != null) { exitQueue.Dispose(); exitQueue = null; }
            ClosePidfds();
        }

        private void FinishFailedStart(Exception failure, TimeSpan timeout)
        {
            lock (spawnGate)
            {
                // Publish the guard BEFORE cleanup: even unexpected cleanup errors
                // must not drop the only owner or permit a new spawn baseline.
                pendingFailedStart = this; active = true;
                CleanupFailedStart(timeout);
                AttachStartupCleanupReceipt(failure);
                failure.Data["PendingCleanupReceipt"] = failure.Data["StartupCleanupReceipt"];
                bool complete = ((ProcessCleanupReceipt)failure.Data["StartupCleanupReceipt"]).CleanedUp;
                failure.Data["UnixRuntimePoisoned"] = !complete;
                if (complete)
                {
                    ReleaseStartupBindings();
                    pendingFailedStart = null; active = false;
                }
                // Otherwise retain pidfds/kqueue and the census. Subsequent Start
                // retries cleanup under spawnGate and refuses admission if unknown.
            }
        }

        private void CleanupFailedStart(TimeSpan timeout)
        {
            startupSignalsSent = 0;
            if (Pid <= 0 || (rootReaped && owned.Count == 0)) return;
            if (String.IsNullOrEmpty(StartIdentity)) { Unknown("startup-identity-unavailable"); return; }
            try
            {
                if (!mac)
                {
                    // Poll may have discovered descendants before a later startup
                    // check failed. Terminate every verified binding, not just root.
                    startupSignalsSent += Signal(true);
                    var watch = Stopwatch.StartNew();
                    do
                    {
                        try { Poll(); } catch (Exception ex) { Unknown("startup-inventory-incomplete: " + ex.Message); }
                        // A previous signal covered only identities known then. Poll
                        // can bind late descendants even after root exit or a failed
                        // census. Terminate those bindings before attempting to reap.
                        startupSignalsSent += Signal(true);
                        ReapBoundAfterInventoryFailure();
                        if (rootReaped && owned.Count == 0) return; // final receipt also probes the group
                        if (watch.Elapsed >= timeout) return;
                        Thread.Sleep(10);
                    } while (true);
                }
                // Use the same retained-root policy as Stop. Poll can already have
                // discovered children before startup failed; consuming only the root
                // here would leave their group without a signalling reservation.
                var timer = Stopwatch.StartNew();
                do
                {
                    try { Poll(); } catch (Exception ex) { Unknown("startup-inventory-incomplete: " + ex.Message); }
                    startupSignalsSent += Signal(true);
                    if (rootReaped && owned.Count == 0 && Remaining().Length == 0) return;
                    if (timer.Elapsed >= timeout) return;
                    Thread.Sleep(10);
                } while (true);
            }
            catch (Exception ex) { Unknown("startup-cleanup-failed: " + ex.Message); }
        }

        private void AttachStartupCleanupReceipt(Exception failure)
        {
            int[] remaining;
            try { remaining = Remaining(); }
            catch (Exception ex)
            {
                Unknown("startup-cleanup-observation-failed: " + ex.Message);
                var pending = new HashSet<int>(owned.Keys); pending.Add(Pid);
                remaining = new int[pending.Count]; pending.CopyTo(remaining);
            }
            bool complete = rootReaped && owned.Count == 0 && remaining.Length == 0 && Uncertainty == null;
            var receipt = new ProcessCleanupReceipt {
                CleanedUp = complete, Isolation = Isolation, Limitations = OwnedProcessLease.GetIsolationLimitations(Isolation),
                SignalsSent = startupSignalsSent, RemainingPids = remaining, UnixObservation = Observation,
                Uncertainty = Uncertainty ?? (complete ? null : "startup-cleanup-incomplete"),
                CaptureReadersStopped = true, CaptureResourcesClosed = false
            };
            // The outer owner closes capture resources and finalizes these flags
            // before rethrowing the original startup exception to the caller.
            failure.Data["StartupCleanupReceipt"] = receipt;
            failure.Data["StartupRootExitConfirmed"] = rootReaped;
            failure.Data["StartupCleanupConfirmed"] = complete;
            failure.Data["StartupRemainingPids"] = remaining;
            if (!complete) failure.Data["StartupCleanupUncertainty"] = receipt.Uncertainty;
        }

        private void MarkExited()
        {
            if (!Exited) { exitObservedCensus = censusGeneration; exitInventory = rootInventory; }
            Exited = true;
        }
        private void SetExitStatus(int status, string source)
        { ExitCode = (status & 127) == 0 ? (status >> 8) & 255 : 128 + (status & 127); exitCodeSource = source; MarkExited(); }

        private void ObserveRoot()
        {
            Identity actual;
            bool present = last.TryGetValue(Pid, out actual);
            rootInventory = unreadable.Contains(Pid) ? "denied" : !present ? "absent" : actual.Start != StartIdentity ? "replacement" : actual.Zombie ? "zombie" : "present";
            if (present && actual.Start == StartIdentity && actual.Group != Pid) rootGroupLost = true;
            if (mac)
            {
                int? status = readExitEvent();
                if (status.HasValue) { kqueueExitStatus = status; SetExitStatus(status.Value, "kqueue-NOTE_EXITSTATUS"); }
            }
            if (rootReaped) return;
            // Do not wait on a reused PID, even if it is another child of this host.
            if (present && actual.Start != StartIdentity) { rootReserved = false; rootReaped = true; MarkExited(); return; }
            if (mac && !Exited && present && !actual.Zombie) return;
            if (RefreshRootReservation())
            {
                Identity expected;
                // libproc may omit our zombie. WNOWAIT preserves that very child
                // while the post-exit census discovers and terminates its group.
                if (!unreadable.Contains(Pid) && owned.TryGetValue(Pid, out expected))
                    last[Pid] = new Identity { Pid = Pid, Parent = supervisor, Group = present ? actual.Group : expected.Group, Start = expected.Start, Zombie = true };
            }
            if (present && actual.Start == StartIdentity && actual.Zombie) MarkExited();
        }

        private bool RefreshRootReservation()
        {
            if (rootReaped || !owned.ContainsKey(Pid)) { rootReserved = false; return false; }
            Tuple<int, int, int> wait = peekChild(Pid);
            waitIdResult = wait.Item1 < 0 ? -1 : 0; waitIdPid = wait.Item1 > 0 ? wait.Item1 : 0; waitIdErrno = wait.Item3;
            if (wait.Item1 == Pid)
            {
                rootReserved = true;
                if (!mac) SetExitStatus(wait.Item2, "waitid-WNOWAIT");
                else MarkExited();
                return true;
            }
            rootReserved = false;
            if (wait.Item1 < 0 && wait.Item3 == 10) // ECHILD: never equate this alone with exit.
            {
                rootAnchorLost = true;
                Identity actual = ReadObserved(Pid, true);
                if (actual == null && !unreadable.Contains(Pid))
                {
                    rootReaped = true; MarkExited(); ForgetOwned(Pid); last.Remove(Pid);
                    if (!ExitCode.HasValue) exitCodeSource = "unavailable-after-external-reap";
                }
                else if (actual != null && actual.Start != StartIdentity)
                { Identity expected; if (owned.TryGetValue(Pid, out expected)) RetireReplacement(expected, actual); rootReaped = true; MarkExited(); }
                // A still-present identity (or permission failure) remains owned.
            }
            else if (wait.Item1 < 0 && wait.Item3 != 4) Unknown("root-waitid-failed: " + wait.Item3);
            return false;
        }

        public void Poll()
        {
            try { PollInventory(); }
            catch (Exception ex)
            {
                inventoryIncomplete = true;
                Unknown("inventory-incomplete: " + ex.Message);
                throw;
            }
        }

        private void PollInventory()
        {
            censusGeneration++;
            last = Snapshot();
            if (!mac)
                foreach (Identity expected in new List<Identity>(owned.Values)) BindIdentity(expected);
            ObserveRoot();
            foreach (Identity expected in new List<Identity>(owned.Values))
            {
                Identity actual;
                if (last.TryGetValue(expected.Pid, out actual) && actual.Start != expected.Start)
                    RetireReplacement(expected, actual);
                else if (expected.Pid != Pid && !last.ContainsKey(expected.Pid) && !unreadable.Contains(expected.Pid))
                    ForgetOwned(expected.Pid); // explicit ENOENT/ESRCH, not a missing census entry
            }
            // Follow PPID edges and group membership to a fixed point. Group membership
            // is trusted only while the unreaped ROOT anchors that group. A live
            // descendant or an already-consumed root never reserves the PGID.
            Identity ownedRoot, actualRoot;
            bool anchor = !rootReaped && !rootGroupLost && owned.TryGetValue(Pid, out ownedRoot) &&
                (rootReserved || (last.TryGetValue(Pid, out actualRoot) && actualRoot.Start == ownedRoot.Start && actualRoot.Group == Pid));
            bool changed;
            do
            {
                changed = false;
                foreach (Identity value in new List<Identity>(last.Values))
                {
                    if (owned.ContainsKey(value.Pid) || baseline.Contains(Key(value)) || excluded.Contains(Key(value))) continue;
                    Identity parent, liveParent;
                    bool descendant = owned.TryGetValue(value.Parent, out parent) && last.TryGetValue(value.Parent, out liveParent) && liveParent.Start == parent.Start;
                    if ((anchor && value.Group == Pid) || descendant)
                    {
                        if (!mac)
                        {
                            if (!BindIdentity(value)) continue;
                            // Bind the candidate first; only then check that the
                            // original authority still exists. A reused root/group
                            // or parent PID cannot authorize this acquired identity.
                            int authorityFd; bool attributed = false;
                            Identity root;
                            if (value.Group == Pid && owned.TryGetValue(Pid, out root) && boundPidfds.TryGetValue(Key(root), out authorityFd))
                                attributed = sendPidfdSignal(authorityFd, 0) == 0;
                            if (!attributed && descendant && boundPidfds.TryGetValue(Key(parent), out authorityFd))
                                attributed = sendPidfdSignal(authorityFd, 0) == 0;
                            if (!attributed)
                            {
                                int candidateFd = boundPidfds[Key(value)]; boundPidfds.Remove(Key(value)); closePidfd(candidateFd);
                                Unknown("owned-attribution-lost: " + value.Pid); continue;
                            }
                        }
                        owned.Add(value.Pid, value); changed = true;
                    }
                }
            } while (changed);
            foreach (Identity value in last.Values)
            {
                if (!mac && value.Parent == supervisor && !owned.ContainsKey(value.Pid) && !baseline.Contains(Key(value)))
                    Unknown("unattributed-adopted-child: " + value.Pid.ToString(CultureInfo.InvariantCulture));
                // Darwin promises group cleanup and tracking of observed owned
                // identities, not discovery of unobserved setsid/setpgid escapes.
                // Unrelated launchd children never establish workload ownership.
            }
            // Only exact owned child PIDs are waited. Never waitpid(-1), which would
            // steal another .NET Process/runner's exit status in the host pwsh.
            foreach (Identity expected in new List<Identity>(owned.Values))
            {
                Identity value;
                if (last.TryGetValue(expected.Pid, out value) && value.Start == expected.Start && value.Zombie && value.Parent == supervisor)
                {
                    // Darwin does not adopt grandchildren. If a group member is
                    // independently parented by this host, its waiter may be .NET;
                    // there is no identity-bound wait API for that descendant.
                    if (mac && value.Pid != Pid) { Unknown("macos-unbound-child-wait-refused: " + value.Pid); continue; }
                    // A /proc census is not atomic: a grandchild can be born after
                    // enumeration, before we read the now-zombie root. Keep that root
                    // waitable until Stop has signalled the group and refreshed census.
                    if (value.Pid == Pid)
                    {
                        MarkExited();
                        if (!cleanupStarted || !rootReserved || censusGeneration <= exitObservedCensus || unreadable.Count != 0) continue;
                        // Known escaped descendants also keep the reservation until
                        // their identities end. Never release it merely because the
                        // current census omits a previously observed owned process.
                        if (owned.Count != 1) continue;
                        bool other = false; foreach (Identity member in last.Values) if (member.Pid != Pid && member.Group == Pid) { other = true; break; }
                        if (other) continue;
                        int errno = sendSignal(-Pid, 0); groupProbeErrno = errno;
                        // Linux kill(0) includes our own retained zombie. A complete
                        // post-exit census containing ONLY that root permits the final
                        // wait; requiring ESRCH here would deadlock forever. Darwin
                        // may report EPERM for a zombie-only group; only a fresh,
                        // readable group census can distinguish that from denial.
                        if (errno != 3 && !(errno == 0 && !mac) && !(errno == 1 && mac && DarwinGroupHasNoLiveMembers()))
                        { if (errno != 0 && errno != 1) Unknown("group-existence-unknown: " + errno); continue; }
                        if (!RefreshRootReservation()) continue;
                    }
                    Tuple<int, int, int> wait = waitForChild(value.Pid);
                    if (value.Pid == Pid) { waitPidResult = wait.Item1; waitPidErrno = wait.Item3; }
                    if (wait.Item1 == value.Pid)
                    {
                        ForgetOwned(value.Pid); last.Remove(value.Pid);
                        if (value.Pid == Pid) { rootReserved = false; rootReaped = true; SetExitStatus(wait.Item2, "waitpid"); }
                    }
                    else if (wait.Item1 < 0 && wait.Item3 == 10)
                    {
                        Identity current = ReadObserved(value.Pid, true);
                        if (current == null && !unreadable.Contains(value.Pid))
                        { ForgetOwned(value.Pid); last.Remove(value.Pid); if (value.Pid == Pid) { rootReserved = false; rootReaped = true; MarkExited(); } }
                        else if (current != null && current.Start != value.Start) RetireReplacement(value, current);
                    }
                    else if (wait.Item1 < 0 && wait.Item3 != 4) Unknown("owned-waitpid-failed: " + wait.Item3); // EINTR retries next poll
                }
            }
        }

        private void RetireReplacement(Identity expected, Identity actual)
        {
            ForgetOwned(expected.Pid);
            excluded.Add(Key(actual));
            last[actual.Pid] = actual;
            // The old process ended, but its unobserved descendants are uncertain.
            // This must not disable cancellation of the other verified identities.
            Unknown("process-start-identity-mismatch: " + expected.Pid.ToString(CultureInfo.InvariantCulture));
        }

        public int Signal(bool force)
        {
            cleanupStarted = true;
            int signal = force ? 9 : 15, count = 0;
            bool groupSent = false;
            try
            {
                if (CanSignalGroup())
                {
                    // WNOWAIT does not exclude other waiters in this CLR process.
                    // An external reaper can still win between the reservation check
                    // and killpg. This follow-up boundary is disclosed in Limitations
                    // as group-signal-external-reaper-race; pidfd loss detection stays
                    // in place, but cannot make this numeric group signal atomic.
                    int errno = sendSignal(-Pid, signal);
                    if (errno == 0) { count++; groupSignalsSent++; groupSent = true; }
                    else if (errno != 3 && !(errno == 1 && mac && DarwinGroupHasNoLiveMembers())) Unknown("group-signal-failed: " + errno);
                }
            }
            catch (Exception ex) { rootReserved = false; Unknown("group-anchor-unverified: " + ex.Message); }
            foreach (Identity expected in new List<Identity>(owned.Values))
            {
                try
                {
                    if (!mac)
                    {
                        // Cached pidfds remain safe after external reap, group escape
                        // or inventory failure. Signal all bindings, even if the group
                        // signal succeeded: a descendant may have moved meanwhile.
                        if (SignalIndividual(expected, signal)) count++;
                        continue;
                    }
                    Identity actual = ReadObserved(expected.Pid, true);
                    if (actual == null)
                    { if (expected.Pid != Pid && !unreadable.Contains(expected.Pid)) ForgetOwned(expected.Pid); continue; }
                    if (actual.Start != expected.Start) { RetireReplacement(expected, actual); continue; }
                    if (actual.Zombie || (groupSent && actual.Group == Pid)) continue;
                    // Darwin has no pidfd equivalent: a number plus a fresh identity
                    // read is insufficient to authorize an individual signal.
                    SignalIndividual(actual, signal);
                }
                catch (Exception ex) { Unknown("owned-signal-failed: " + expected.Pid + ": " + ex.Message); }
            }
            if (!mac && inventoryIncomplete && force) ReapBoundAfterInventoryFailure();
            return count;
        }

        private bool CanSignalGroup()
        {
            Identity root;
            if (rootReaped || rootGroupLost || !owned.TryGetValue(Pid, out root) || root.Group != Pid) return false;
            foreach (Identity value in last.Values)
                if (value.Group == Pid && excluded.Contains(Key(value))) return false;
            // Refresh non-destructive waitability before EVERY group signal. Once
            // the root is reserved, inventory failure need not block termination.
            // No lifecycle reservation is ever inferred from a remaining descendant.
            if (rootReserved || Exited) return RefreshRootReservation();
            if (!mac) return false; // a live Linux root is signalled via its pidfd
            Identity current = ReadObserved(Pid, true);
            if (current == null) return false;
            if (current.Start != root.Start) { RetireReplacement(root, current); rootReaped = true; return false; }
            if (current.Group != Pid) { rootGroupLost = true; return false; }
            if (current.Zombie)
            {
                int? status = readExitEvent();
                if (status.HasValue) { kqueueExitStatus = status; SetExitStatus(status.Value, "kqueue-NOTE_EXITSTATUS"); }
                return RefreshRootReservation();
            }
            return current.Parent == supervisor;
        }

        private bool DarwinGroupHasNoLiveMembers()
        {
            if (!mac || !Exited || rootGroupLost || (!rootReaped && !rootReserved)) return false;
            try
            {
                // Query the PGID itself, not only the UID census or cached snapshot.
                // A newly discovered or credential-changing member must be readable;
                // EPERM, I/O errors and failed enumeration are never evidence of exit.
                var inspected = new HashSet<int>(listDarwinPids(2, (uint)Pid));
                foreach (Identity value in last.Values) if (value.Group == Pid) inspected.Add(value.Pid);
                foreach (int pid in owned.Keys) inspected.Add(pid);
                foreach (int pid in inspected)
                {
                    Identity current = Read(pid);
                    if (current == null) continue; // explicit ENOENT/ESRCH, including omitted zombies
                    if (pid == Pid && current.Start != StartIdentity)
                    { Unknown("process-start-identity-mismatch: " + pid); return false; }
                    if (current.Group == Pid && !current.Zombie) return false;
                }
                // A member may fork before its zombie stat is read. Require a census
                // acquired after those reads to contain no newly discovered member.
                foreach (int pid in listDarwinPids(2, (uint)Pid)) if (!inspected.Contains(pid)) return false;
                return true;
            }
            catch (Exception ex)
            { inventoryIncomplete = true; Unknown("group-inventory-incomplete: " + ex.Message); return false; }
        }

        public int[] Remaining()
        {
            var result = new HashSet<int>();
            foreach (Identity expected in owned.Values) result.Add(expected.Pid);
            if (!rootReaped) result.Add(Pid); // pending wait/identity confirmation is not cleanup.
            // ESRCH alone is not proof of descendant cleanup; both inventory and
            // ownership observations above participate in the receipt.
            int errno = sendSignal(-Pid, 0);
            groupProbeErrno = errno;
            darwinGroupEmpty = errno == 1 && mac && DarwinGroupHasNoLiveMembers();
            // A Darwin zombie can be absent from libproc before launchd reaps it.
            // Positive kill(0) keeps cleanup pending; a later ESRCH can resolve this
            // observation. Never turn a transient, still-live group into success.
            if (errno == 0 || (errno == 1 && !darwinGroupEmpty)) { foreach (Identity member in last.Values) if (member.Group == Pid) result.Add(member.Pid); if (result.Count == 0) result.Add(Pid); }
            else if (errno != 3 && !darwinGroupEmpty) Unknown("group-existence-unknown: " + errno);
            var array = new int[result.Count]; result.CopyTo(array); return array;
        }

        private void ReapBoundAfterInventoryFailure()
        {
            // No census or pathname read is needed. waitid(P_PIDFD) cannot reap
            // another child that happens to reuse a previously recorded PID.
            var pending = new List<Identity>(owned.Values);
            pending.Sort((left, right) => (left.Pid == Pid ? 1 : 0).CompareTo(right.Pid == Pid ? 1 : 0));
            foreach (Identity expected in pending)
            {
                int fd;
                if (!boundPidfds.TryGetValue(Key(expected), out fd)) continue;
                try
                {
                    if (expected.Pid == Pid)
                    {
                        if (owned.Count != 1) continue;
                        // A failed census cannot prove that only our zombie remains.
                        // Keep its PGID reservation if the group still exists; an
                        // incomplete cleanup must not trade safety for a successful wait.
                        if (rootReserved && sendSignal(-Pid, 0) != 3) continue;
                    }
                    Tuple<int, int, int> waited = waitForChild(expected.Pid);
                    if (expected.Pid == Pid) { waitPidResult = waited.Item1; waitPidErrno = waited.Item3; }
                    bool gone = waited.Item1 == expected.Pid;
                    if (waited.Item1 < 0 && waited.Item3 == 10) gone = sendPidfdSignal(fd, 0) == 3;
                    if (gone)
                    {
                        if (expected.Pid == Pid)
                        {
                            rootReaped = true; rootReserved = false;
                            if (waited.Item1 == Pid) SetExitStatus(waited.Item2, "waitid-P_PIDFD"); else MarkExited();
                        }
                        ForgetOwned(expected.Pid); last.Remove(expected.Pid);
                    }
                }
                catch (Exception ex) { Unknown("bound-reap-failed: " + ex.Message); }
            }
        }
        public void Dispose()
        {
            lock (spawnGate)
            {
                if (released) return;
                try
                {
                    // The public lease may now be permanently disposed. Transfer
                    // unresolved ownership to the same admission guard as failed
                    // startup, keeping pidfds/kqueue and any zombie reservation.
                    // This bounded attempt never frees bindings on an unknown result.
                    FinishFailedStart(new IOException("dispose-cleanup-incomplete"), TimeSpan.FromMilliseconds(100));
                }
                finally { released = true; }
            }
        }
    }
}
