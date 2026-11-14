// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.IO;
using System.IO.Pipes;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    [Serializable]
    public sealed class ProcessCleanupReceipt
    {
        public bool CleanedUp { get; internal set; }
        public string Isolation { get; internal set; }
        public string[] Limitations { get; internal set; }
        public string Uncertainty { get; internal set; }
        public int SignalsSent { get; internal set; }
        public int[] RemainingPids { get; internal set; }
        public UnixProcessObservation UnixObservation { get; internal set; }
        public bool CaptureReadersStopped { get; internal set; }
        public bool CaptureResourcesClosed { get; internal set; }
    }

    internal interface IOwnedProcessControl : IDisposable
    {
        int Pid { get; }
        string StartIdentity { get; }
        string Isolation { get; }
        bool Exited { get; }
        int? ExitCode { get; }
        string Uncertainty { get; }
        void Poll();
        int Signal(bool force);
        int[] Remaining();
    }

    // A process lease owns its capture leases. Working-directory/executable leases
    // are borrowed only during synchronous creation. No native handle is public.
    public sealed class OwnedProcessLease : IDisposable
    {
        private readonly object gate = new object();
        private readonly object outputGate = new object();
        private IOwnedProcessControl control;
        private AnonymousPipeServerStream stdout, stderr;
        private SafePipeHandle stdoutClient, stderrClient;
        private IDisposable outLease, errLease;
        private FileStream outFile, errFile;
        private Thread outReader, errReader, supervisor;
        private readonly ManualResetEventSlim exited = new ManualResetEventSlim(false);
        private readonly ManualResetEventSlim cleaned = new ManualResetEventSlim(false);
        private readonly ManualResetEventSlim captureCancelled = new ManualResetEventSlim(false);
        private long captureStopDeadlineTicks = Int64.MaxValue;
        private int readersRunning, readersAtEof;
        private readonly DateTimeOffset deadline;
        private readonly long limit;
        private long stderrLimit;
        private string outputLimitStream;
        private volatile bool outputExceeded, disposed, captureClosed;
        private readonly string captureProfile;
        private byte[] stdoutSnapshot, stderrSnapshot;
        private string stdoutSnapshotFailure, stderrSnapshotFailure;
        private string captureFailure;
        private ProcessCleanupReceipt cleanup;
        private string reason;
        public int Pid { get { return control.Pid; } }
        public string StartIdentity { get { return control.StartIdentity; } }
        public string Isolation { get { return control.Isolation; } }
        public string[] Limitations
        {
            get { return GetIsolationLimitations(Isolation); }
        }
        internal static string[] GetIsolationLimitations(string isolation)
        {
            if (isolation == "macos-process-group") return new string[] { "macos-process-group-cannot-detect-setsid-escape", "group-signal-external-reaper-race" };
            if (isolation == "linux-process-group-subreaper") return new string[] { "group-signal-external-reaper-race" };
            return new string[0];
        }
        public bool HasExited { get { return exited.IsSet; } }
        public int? ExitCode { get { lock (gate) return control.ExitCode; } }
        public bool OutputLimitExceeded { get { return outputExceeded; } }
        public string OutputLimitStream { get { return outputLimitStream; } }
        public string TerminationReason { get { lock (gate) return reason; } }
        public ProcessCleanupReceipt Cleanup { get { lock (gate) return cleanup; } }
        public bool CaptureReadersStopped { get { return (outReader == null || !outReader.IsAlive) && (errReader == null || !errReader.IsAlive); } }
        // Stopped readers may have hit their deadline or been cancelled. Only
        // two observed EOFs prove that descendants released both inherited pipes.
        public bool CaptureCompletedNaturally { get { return Volatile.Read(ref readersAtEof) == 2 && CaptureReadersStopped; } }
        public bool CaptureResourcesClosed { get { return captureClosed; } }
        public UnixProcessObservation UnixObservation { get { lock (gate) { var unix = control as UnixProcessControl; return unix == null ? null : unix.Observation; } } }
        public bool WaitForExit(TimeSpan timeout) { return exited.Wait(timeout); }
        public bool WaitForCleanup(TimeSpan timeout) { return cleaned.Wait(timeout); }

        public byte[] ReadCapture(string stream, int maximumBytes)
        {
            if (stream != "stdout" && stream != "stderr") throw new ArgumentException("Stream must be stdout or stderr.", "stream");
            if (maximumBytes < 0) throw new ArgumentOutOfRangeException("maximumBytes");
            if (captureProfile != "semantic-bridge")
                throw new InvalidOperationException("Only the semantic-bridge capture profile retains an in-memory capture snapshot.");
            lock (gate)
            {
                if (cleanup == null || !cleanup.CleanedUp || !captureClosed)
                    throw new InvalidOperationException("Capture can be read only after owned process cleanup and capture resource shutdown are complete.");
                lock (outputGate)
                {
                    byte[] snapshot = stream == "stdout" ? stdoutSnapshot : stderrSnapshot;
                    string failure = stream == "stdout" ? stdoutSnapshotFailure : stderrSnapshotFailure;
                    if (snapshot == null)
                        throw new InvalidOperationException("The " + stream + " capture snapshot is unavailable: " + (failure ?? "no snapshot was retained."));
                    if (snapshot.Length > maximumBytes)
                        throw new IOException("The " + stream + " capture snapshot exceeds the bounded read limit.");
                    return (byte[])snapshot.Clone();
                }
            }
        }

        private OwnedProcessLease(DateTimeOffset until, long maximum, string profile)
        { deadline = until; limit = maximum; stderrLimit = maximum; captureProfile = profile; }

        private OwnedProcessLease(DateTimeOffset until, long maximum)
            : this(until, maximum, "standard") { }

        public static OwnedProcessLease Start(string executablePath, object executableLease,
            string[] arguments, IDictionary environment, object workingDirectory,
            DateTimeOffset deadline, string isolationRequirement, object stdoutLease,
            object stderrLease, long outputLimitCharacters)
        {
            return Start(executablePath, executableLease, arguments, environment, workingDirectory,
                deadline, isolationRequirement, stdoutLease, stderrLease, outputLimitCharacters, null);
        }

        public static OwnedProcessLease Start(string executablePath, object executableLease,
            string[] arguments, IDictionary environment, object workingDirectory,
            DateTimeOffset deadline, string isolationRequirement, object stdoutLease,
            object stderrLease, long outputLimitCharacters, string argumentZero)
        {
            return Start(executablePath, executableLease, arguments, environment, workingDirectory,
                deadline, isolationRequirement, stdoutLease, stderrLease, outputLimitCharacters, argumentZero, null);
        }

        public static OwnedProcessLease Start(string executablePath, object executableLease,
            string[] arguments, IDictionary environment, object workingDirectory,
            DateTimeOffset deadline, string isolationRequirement, object stdoutLease,
            object stderrLease, long outputLimitCharacters, string argumentZero, byte[] standardInputBytes)
        {
            return Start(executablePath, executableLease, arguments, environment, workingDirectory,
                deadline, isolationRequirement, stdoutLease, stderrLease, outputLimitCharacters, argumentZero, standardInputBytes, "standard");
        }

        public static OwnedProcessLease Start(string executablePath, object executableLease,
            string[] arguments, IDictionary environment, object workingDirectory,
            DateTimeOffset deadline, string isolationRequirement, object stdoutLease,
            object stderrLease, long outputLimitCharacters, string argumentZero, byte[] standardInputBytes, string captureProfile)
        {
            if (captureProfile != "standard" && captureProfile != "semantic-bridge") throw new ArgumentException("Unknown capture profile.");
            if (captureProfile == "semantic-bridge" && standardInputBytes == null) throw new ArgumentException("The semantic-bridge capture profile requires explicit StandardInputBytes.");
            if (standardInputBytes != null && standardInputBytes.Length > 16777216)
                throw new ArgumentException("StandardInputBytes exceeds the 16 MiB limit.");
            string os = PlatformNative.GetOperatingSystem();
            if (String.IsNullOrEmpty(argumentZero)) argumentZero = null;
            else if (argumentZero.IndexOf('\0') >= 0 || !Path.IsPathFullyQualified(argumentZero))
                throw new ArgumentException("ArgumentZero must be an absolute path without NUL.");
            if (isolationRequirement != "cooperative" && isolationRequirement != "strong")
                throw new ArgumentException("IsolationRequirement must be cooperative or strong.");
            if (os != "windows" && isolationRequirement == "strong")
                throw new PlatformCapabilityUnavailableException("strong-process-isolation: external sandbox required", os);
            if (deadline <= DateTimeOffset.UtcNow || outputLimitCharacters < 1 || outputLimitCharacters > 1048576)
                throw new ArgumentException("A future deadline and a positive output limit are required.");
            if (environment == null) throw new ArgumentNullException("environment");
            var env = new List<string>();
            var keys = new HashSet<string>(os == "windows" ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
            foreach (DictionaryEntry entry in environment)
            {
                string key = entry.Key as string, value = entry.Value as string;
                if (String.IsNullOrEmpty(key) || key.IndexOfAny(new char[] { '=', '\0' }) >= 0 || value == null || value.IndexOf('\0') >= 0 || !keys.Add(key))
                    throw new ArgumentException("Environment must contain unique, explicit string names and values.");
                env.Add(key + "=" + value);
            }
            env.Sort(os == "windows" ? StringComparer.OrdinalIgnoreCase : StringComparer.Ordinal);
            if (arguments == null) arguments = new string[0];
            foreach (string argument in arguments)
                if (argument == null || argument.IndexOf('\0') >= 0) throw new ArgumentException("Arguments cannot contain nulls.");
            var lease = new OwnedProcessLease(deadline, captureProfile == "semantic-bridge" ? 16777216 : outputLimitCharacters, captureProfile);
            if (captureProfile == "semantic-bridge") lease.stderrLimit = 16384;
            try
            {
                lease.outLease = (IDisposable)stdoutLease; lease.errLease = (IDisposable)stderrLease;
                lease.outFile = CaptureFile(stdoutLease); lease.errFile = CaptureFile(stderrLease);
                lease.stdout = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
                lease.stdoutClient = lease.stdout.ClientSafePipeHandle;
                lease.stderr = new AnonymousPipeServerStream(PipeDirection.In, HandleInheritability.Inheritable);
                lease.stderrClient = lease.stderr.ClientSafePipeHandle;
                using (var stdin = new AnonymousPipeServerStream(PipeDirection.Out, HandleInheritability.Inheritable))
                {
                    try
                    {
                        IntPtr input = stdin.ClientSafePipeHandle.DangerousGetHandle();
                        IntPtr output = lease.stdout.ClientSafePipeHandle.DangerousGetHandle();
                        IntPtr error = lease.stderr.ClientSafePipeHandle.DangerousGetHandle();
                        if (os == "windows")
                        {
                            if (standardInputBytes != null) WindowsProcessControl.PrepareInputWriter(stdin.SafePipeHandle);
                            lease.control = WindowsProcessControl.Start(executablePath, executableLease as WindowsLease, arguments, env.ToArray(), (WindowsLease)workingDirectory, input, output, error);
                        }
                        else
                        {
                            if (standardInputBytes != null) UnixProcessControl.PrepareInputWriter(stdin.SafePipeHandle);
                            lease.control = UnixProcessControl.Start(executablePath, executableLease as UnixLease, arguments, env.ToArray(), (UnixLease)workingDirectory, input.ToInt32(), output.ToInt32(), error.ToInt32(), argumentZero);
                        }
                    }
                    finally { stdin.DisposeLocalCopyOfClientHandle(); }
                    // Start returned only after Job assignment / spawn identity and
                    // group registration. Drain output while sending input, and keep
                    // deadline supervision active even when the child never reads.
                    if (standardInputBytes != null)
                    {
                        lease.StartCapture();
                        try
                        {
                            if (os == "windows") WindowsProcessControl.WriteInput(stdin, standardInputBytes, deadline);
                            else UnixProcessControl.WriteInput(stdin.SafePipeHandle, standardInputBytes, deadline);
                        }
                        catch (Exception ex)
                        {
                            var failure = new IOException("StandardInputBytes delivery failed after process ownership was established.", ex);
                            failure.Data["StartupStage"] = "stdin-write";
                            failure.Data["StartupTerminationReason"] = lease.TerminationReason;
                            throw failure;
                        }
                    }
                } // child stdin observes EOF; no inherited terminal
                // Preserve the original no-input ordering: close stdin first.
                if (standardInputBytes == null) lease.StartCapture();
                return lease;
            }
            catch (Exception failure)
            {
                lease.CompleteFailedStart(failure);
                throw;
            }
        }

        private void StartCapture()
        {
            stdout.DisposeLocalCopyOfClientHandle(); stderr.DisposeLocalCopyOfClientHandle();
            outReader = Reader(stdout, outFile); errReader = Reader(stderr, errFile);
            supervisor = new Thread(Supervise) { IsBackground = true, Name = "platform-process-supervisor" };
            supervisor.Start();
        }

        private void CompleteFailedStart(Exception failure)
        {
            var receipt = failure.Data["StartupCleanupReceipt"] as ProcessCleanupReceipt;
            if (control != null)
            {
                try { receipt = Stop(TimeSpan.Zero, DateTimeOffset.UtcNow.AddSeconds(5), null); }
                catch (Exception ex) { receipt = Receipt(false, 0, new int[] { Pid }, "startup-stop-failed: " + ex.Message); }
                try { control.Dispose(); }
                catch (Exception ex) { receipt.CleanedUp = false; receipt.Uncertainty = "startup-dispose-failed: " + ex.Message; }
            }
            try { CloseCapture(); }
            catch (Exception ex)
            {
                failure.Data["StartupCaptureCleanupUncertainty"] = ex.Message;
                if (receipt != null) { receipt.CleanedUp = false; receipt.Uncertainty = "startup-capture-cleanup-failed: " + ex.Message; }
            }
            if (receipt != null)
            {
                receipt.CaptureReadersStopped = CaptureReadersStopped;
                receipt.CaptureResourcesClosed = CaptureResourcesClosed;
                receipt.CleanedUp = receipt.CleanedUp && receipt.CaptureReadersStopped && receipt.CaptureResourcesClosed;
                if (!receipt.CleanedUp && receipt.Uncertainty == null) receipt.Uncertainty = "startup-cleanup-incomplete";
                failure.Data["StartupCleanupReceipt"] = receipt;
                failure.Data["StartupCleanupConfirmed"] = receipt.CleanedUp;
                failure.Data["StartupRemainingPids"] = receipt.RemainingPids;
                if (!receipt.CleanedUp) failure.Data["StartupCleanupUncertainty"] = receipt.Uncertainty;
            }
        }

        private static FileStream CaptureFile(object file)
        {
            IntPtr handle;
            if (file is WindowsLease)
            {
                var w = (WindowsLease)file;
                WindowsNative.AssertIdentity(w, w.Observation, true); handle = w.Handle.DangerousGetHandle();
            }
            else
            {
                var u = (UnixLease)file;
                UnixNative.AssertIdentity(u, u.Observation, true); handle = u.Fd.DangerousGetHandle();
            }
            // The P2 lease retains ownership; the FileStream never closes its handle.
            return new FileStream(new SafeFileHandle(handle, false), FileAccess.Write, 4096, false);
        }

        [DllImport("libc", EntryPoint = "fcntl", SetLastError = true)] private static extern int GetPipeFlags(SafePipeHandle fd, int command);
        [DllImport("libc", EntryPoint = "fcntl", SetLastError = true)] private static extern int SetPipeFlags(SafePipeHandle fd, int command, int flags);
        // Darwin arm64 places the optional fcntl argument on the stack.
        [DllImport("libc", EntryPoint = "fcntl", SetLastError = true)] private static extern int SetPipeFlagsArm64(SafePipeHandle fd, int command, IntPtr x2, IntPtr x3, IntPtr x4, IntPtr x5, IntPtr x6, IntPtr x7, IntPtr flags);
        [DllImport("libc", SetLastError = true)] private static extern IntPtr read(SafePipeHandle fd, [Out] byte[] buffer, UIntPtr count);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool PeekNamedPipe(SafePipeHandle pipe, IntPtr buffer, uint size, IntPtr bytesRead, out uint available, IntPtr left);
        [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool ReadFile(SafePipeHandle pipe, [Out] byte[] buffer, int size, out int bytesRead, IntPtr overlapped);

        private static void PrepareCapture(PipeStream source)
        {
            string os = PlatformNative.GetOperatingSystem();
            if (os == "windows") return;
            int flags = GetPipeFlags(source.SafePipeHandle, 3); // F_GETFL, no vararg
            if (flags < 0) throw new PlatformErrnoException("capture-F_GETFL", Marshal.GetLastWin32Error());
            int nonBlocking = os == "macos" ? 4 : 0x800;
            flags |= nonBlocking; // O_NONBLOCK on the read end only
            int result = os == "macos" && RuntimeInformation.ProcessArchitecture == Architecture.Arm64
                ? SetPipeFlagsArm64(source.SafePipeHandle, 4, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, new IntPtr(flags))
                : SetPipeFlags(source.SafePipeHandle, 4, flags);
            if (result < 0) throw new PlatformErrnoException("capture-F_SETFL", Marshal.GetLastWin32Error());
            int actual = GetPipeFlags(source.SafePipeHandle, 3);
            if (actual < 0) throw new PlatformErrnoException("capture-F_GETFL-readback", Marshal.GetLastWin32Error());
            if ((actual & nonBlocking) == 0) throw new IOException("Capture O_NONBLOCK ABI readback failed.");
        }

        private static int ReadAvailable(PipeStream source, byte[] buffer)
        {
            if (PlatformNative.GetOperatingSystem() != "windows")
            {
                long count = read(source.SafePipeHandle, buffer, new UIntPtr((uint)buffer.Length)).ToInt64();
                if (count >= 0) return checked((int)count);
                int errno = Marshal.GetLastWin32Error();
                if (errno == 4 || errno == (PlatformNative.GetOperatingSystem() == "macos" ? 35 : 11)) return -1; // EINTR / EAGAIN
                throw new PlatformErrnoException("capture-read", errno);
            }
            uint available;
            if (!PeekNamedPipe(source.SafePipeHandle, IntPtr.Zero, 0, IntPtr.Zero, out available, IntPtr.Zero))
            { int error = Marshal.GetLastWin32Error(); if (error == 109) return 0; throw new PlatformWin32Exception("capture-peek", error); }
            if (available == 0) return -1;
            // This is the only reader and its read handle is never inherited by a
            // workload. Read at most the bytes already present; no blocking read
            // is ever issued against an empty pipe, including an idle escaped writer.
            int readCount;
            if (!ReadFile(source.SafePipeHandle, buffer, (int)Math.Min(available, (uint)buffer.Length), out readCount, IntPtr.Zero))
            { int error = Marshal.GetLastWin32Error(); if (error == 109) return 0; throw new PlatformWin32Exception("capture-read", error); }
            return readCount;
        }

        private Thread Reader(PipeStream source, FileStream destination)
        {
            PrepareCapture(source);
            long streamLimit = Object.ReferenceEquals(source, stderr) ? stderrLimit : limit;
            var thread = new Thread(() =>
            {
                try
                {
                    byte[] buffer = new byte[8192];
                    var encoding = new UTF8Encoding(false);
                    Decoder decoder = encoding.GetDecoder();
                    char[] characters = new char[encoding.GetMaxCharCount(buffer.Length)];
                    byte[] encoded = new byte[encoding.GetMaxByteCount(characters.Length)];
                    long written = 0; // independent quota for this reader/stream
                    while (!captureCancelled.IsSet)
                    {
                        DateTimeOffset now = DateTimeOffset.UtcNow;
                        // Cleanup inventory can itself exceed the reserved drain
                        // budget. Do not wait for Stop to return from native census
                        // before cancelling an idle pipe with an escaped writer.
                        if (now.UtcTicks >= Interlocked.Read(ref captureStopDeadlineTicks))
                        {
                            lock (outputGate) { if (captureFailure == null) captureFailure = "capture-pipe-still-open"; }
                            captureCancelled.Set();
                            return;
                        }
                        // A reader also has a deadline when no supervisor was
                        // started, or an idle writer holds a partial UTF-8 sequence.
                        if (now >= deadline)
                        { lock (outputGate) { if (captureFailure == null) captureFailure = "capture-deadline"; } return; }
                        int count = ReadAvailable(source, buffer);
                        if (count < 0) { captureCancelled.Wait(10); continue; }
                        // Preserve decoder state across pipe chunks. Count UTF-16
                        // characters, as bounded .NET text readers do, not UTF-8 bytes.
                        int decoded = decoder.GetChars(buffer, 0, count, characters, 0, count == 0);
                        lock (outputGate)
                        {
                            if (captureClosed) return;
                            int accepted = (int)Math.Min(decoded, streamLimit - written);
                            // Keep a valid text prefix if the quota bisects a pair.
                            if (accepted > 0 && Char.IsHighSurrogate(characters[accepted - 1])) accepted--;
                            if (accepted > 0)
                            {
                                int bytes = encoding.GetBytes(characters, 0, accepted, encoded, 0);
                                destination.Write(encoded, 0, bytes); destination.Flush(); written += accepted;
                            }
                            if (accepted < decoded) { outputLimitStream = Object.ReferenceEquals(source, stderr) ? "stderr" : "stdout"; outputExceeded = true; return; }
                        }
                        if (count == 0) { Interlocked.Increment(ref readersAtEof); return; }
                    }
                }
                catch (Exception ex) { lock (outputGate) { if (!captureClosed) captureFailure = ex.Message; } }
                finally
                {
                    if (Interlocked.Decrement(ref readersRunning) == 0 && captureCancelled.IsSet)
                        try { CloseCapture(); } catch (Exception ex) { captureFailure = ex.Message; }
                }
            }) { IsBackground = true, Name = "platform-bounded-capture" };
            Interlocked.Increment(ref readersRunning);
            try { thread.Start(); return thread; }
            catch { Interlocked.Decrement(ref readersRunning); throw; }
        }

        private void Supervise()
        {
            try
            {
                while (!disposed && !cleaned.IsSet)
                {
                    bool stop;
                    lock (gate)
                    {
                        if (disposed || cleaned.IsSet) return;
                        control.Poll(); if (control.Exited) exited.Set();
                        stop = outputExceeded || captureFailure != null || DateTimeOffset.UtcNow >= deadline;
                        if (stop) reason = outputExceeded ? "output-limit" : DateTimeOffset.UtcNow >= deadline ? "deadline" : "capture-failure";
                    }
                    if (stop) { Stop(TimeSpan.FromMilliseconds(200), DateTimeOffset.UtcNow.AddSeconds(5), null); return; }
                    Thread.Sleep(20);
                }
            }
            catch (Exception ex)
            {
                lock (gate) { reason = "supervisor-failure"; captureFailure = ex.Message; }
                try { Stop(TimeSpan.Zero, DateTimeOffset.UtcNow.AddSeconds(5), null); }
                catch (Exception cleanupError)
                {
                    lock (gate) { cleanup = Receipt(false, 0, new int[] { Pid }, ex.Message + "; " + cleanupError.Message); cleaned.Set(); }
                }
            }
        }

        private ProcessCleanupReceipt Receipt(bool success, int signals, int[] remaining, string uncertainty)
        { return new ProcessCleanupReceipt { CleanedUp = success, Isolation = Isolation, Limitations = Limitations, SignalsSent = signals, RemainingPids = remaining, Uncertainty = uncertainty, UnixObservation = UnixObservation, CaptureReadersStopped = CaptureReadersStopped, CaptureResourcesClosed = CaptureResourcesClosed }; }

        private bool PollCleanup(ref string failure)
        {
            try { control.Poll(); if (control.Exited) exited.Set(); return true; }
            catch (Exception ex) { if (failure == null) failure = "inventory-incomplete: " + ex.Message; return false; }
        }

        private int SignalCleanup(bool force, ref string failure)
        {
            try { return control.Signal(force); }
            catch (Exception ex) { if (failure == null) failure = "termination-failed: " + ex.Message; return 0; }
        }

        private bool RemainingCleanup(ref int[] remaining, ref string failure)
        {
            try { remaining = control.Remaining(); return true; }
            catch (Exception ex) { if (failure == null) failure = "cleanup-observation-failed: " + ex.Message; return false; }
        }

        public ProcessCleanupReceipt Stop(TimeSpan grace, DateTimeOffset until, string expectedStartIdentity)
        {
            if (grace < TimeSpan.Zero) throw new ArgumentOutOfRangeException("grace");
            lock (gate)
            {
                // This rejected request must not change the lease or suppress later valid cleanup.
                if (!String.IsNullOrEmpty(expectedStartIdentity) && !String.Equals(expectedStartIdentity, StartIdentity, StringComparison.Ordinal))
                    return Receipt(false, 0, new int[] { Pid }, "process-start-identity-mismatch");
                if (cleanup != null && cleanup.CleanedUp) return cleanup;
                if (disposed) return cleanup ?? Receipt(false, 0, new int[] { Pid }, "lease-disposed");
                if (reason == null) reason = "cancelled";
                int signals = 0; string failure = null; int[] remaining = new int[] { Pid };
                // Reserve time to cancel and join capture readers even when an
                // escaped process keeps its inherited write ends open indefinitely.
                DateTimeOffset processUntil = until <= DateTimeOffset.MinValue.AddMilliseconds(100) ? DateTimeOffset.MinValue : until.AddMilliseconds(-100);
                // Readers enforce this cutoff independently of the gate held by
                // process cleanup; a slow final Poll/Remaining cannot starve joins.
                Interlocked.Exchange(ref captureStopDeadlineTicks, processUntil.UtcTicks);
                PollCleanup(ref failure);
                signals += SignalCleanup(false, ref failure);
                DateTimeOffset now = DateTimeOffset.UtcNow;
                DateTimeOffset graceEnd = processUntil > now && grace < processUntil - now ? now.Add(grace) : processUntil;
                bool killed = false;
                do
                {
                    bool observed = PollCleanup(ref failure);
                    bool counted = RemainingCleanup(ref remaining, ref failure);
                    if (counted && remaining.Length == 0 && (observed || killed)) break;
                    if (!killed && (DateTimeOffset.UtcNow >= graceEnd || DateTimeOffset.UtcNow >= processUntil))
                    { signals += SignalCleanup(true, ref failure); killed = true; }
                    if (DateTimeOffset.UtcNow >= processUntil) break;
                    Thread.Sleep(20);
                    // Newly discovered owned identities also receive bound KILL.
                    if (killed) signals += SignalCleanup(true, ref failure);
                } while (true);
                PollCleanup(ref failure); RemainingCleanup(ref remaining, ref failure);
                // Drain output only until the cleanup deadline; escaped writers cannot hang Stop.
                if (!captureClosed)
                {
                    try { AssertCapture(outLease); AssertCapture(errLease); } catch (Exception ex) { captureFailure = ex.Message; }
                    DateTimeOffset drainUntil = DateTimeOffset.UtcNow.AddSeconds(1);
                    if (drainUntil > processUntil) drainUntil = processUntil;
                    foreach (Thread reader in new Thread[] { outReader, errReader })
                        if (reader != null && !reader.Join(MillisecondsLeft(drainUntil)))
                            captureFailure = "capture-pipe-still-open";
                }
                if (!CancelCaptureReaders(until)) captureFailure = "capture-reader-cancellation-incomplete";
                try { CloseCapture(); } catch (Exception ex) { captureFailure = ex.Message; }
                // Reaching the workload deadline triggers termination; it is not
                // itself evidence that termination or capture cancellation failed.
                string uncertainty = failure ?? (captureFailure == "capture-deadline" ? null : captureFailure) ?? control.Uncertainty;
                cleanup = Receipt(remaining.Length == 0 && uncertainty == null && CaptureReadersStopped && captureClosed, signals, remaining, uncertainty);
                cleaned.Set();
                return cleanup;
            }
        }

        private static int MillisecondsLeft(DateTimeOffset until)
        { return (int)Math.Max(0, Math.Min(Int32.MaxValue, (until - DateTimeOffset.UtcNow).TotalMilliseconds)); }

        private bool CancelCaptureReaders(DateTimeOffset until)
        {
            captureCancelled.Set();
            foreach (Thread reader in new Thread[] { outReader, errReader })
                if (reader != null && reader != Thread.CurrentThread) reader.Join(MillisecondsLeft(until));
            return CaptureReadersStopped;
        }

        private static void AssertCapture(IDisposable file)
        {
            var windows = file as WindowsLease;
            if (windows != null) WindowsNative.AssertIdentity(windows, windows.Observation, true);
            else { var unix = (UnixLease)file; UnixNative.AssertIdentity(unix, unix.Observation, true); }
        }

        private void CloseCapture()
        {
            captureCancelled.Set();
            // Never dispose an fd underneath active native I/O. The last reader
            // releases resources itself if scheduling prevented joining by deadline.
            if (Volatile.Read(ref readersRunning) != 0) return;
            lock (outputGate)
            {
                if (captureClosed) return;
                Exception failure = null;
                if (captureProfile == "semantic-bridge")
                {
                    try
                    {
                        outFile.Flush();
                        int maximum = checked((int)Math.Min(limit * 3, Int32.MaxValue));
                        var windows = outLease as WindowsLease;
                        stdoutSnapshot = windows != null ? windows.ReadAllBytes(maximum) : ((UnixLease)outLease).ReadRetainedBytes(maximum);
                    }
                    catch (Exception ex) { stdoutSnapshotFailure = ex.Message; }
                    try
                    {
                        errFile.Flush();
                        int maximum = checked((int)Math.Min(stderrLimit * 3, Int32.MaxValue));
                        var windows = errLease as WindowsLease;
                        stderrSnapshot = windows != null ? windows.ReadAllBytes(maximum) : ((UnixLease)errLease).ReadRetainedBytes(maximum);
                    }
                    catch (Exception ex) { stderrSnapshotFailure = ex.Message; }
                }
                // AnonymousPipeServerStream.Dispose does not release its local
                // client copy. Retain/dispose those handles even if spawn failed
                // before DisposeLocalCopyOfClientHandle was reached.
                foreach (IDisposable resource in new IDisposable[] { stdoutClient, stderrClient, stdout, stderr, outFile, errFile, outLease, errLease })
                { if (resource != null) { try { resource.Dispose(); } catch (Exception ex) { if (failure == null) failure = ex; } } }
                captureClosed = true;
                if (failure != null) throw new IOException("Capture resources could not all be released.", failure);
            }
        }
        public void Dispose()
        {
            lock (gate)
            {
                if (disposed) return;
                try { Stop(TimeSpan.FromMilliseconds(100), DateTimeOffset.UtcNow.AddSeconds(5), null); }
                finally { control.Dispose(); CloseCapture(); disposed = true; }
            }
        }
    }
}
