// SPDX-FileCopyrightText: 2026 SyuanTsai
// SPDX-License-Identifier: Apache-2.0

using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace SyuanTsai.AIInstructions.PlatformRuntime
{
    public static class PlatformRuntimeBuild
    {
        private static readonly string[] RuntimeSourcePaths = new string[]
        {
            "platform/PlatformNative.cs",
            "platform/UnixNative.cs",
            "platform/WindowsNative.cs",
            "platform/WindowsInstallerMutation.cs",
            "platform/OwnedProcess.cs",
            "platform/UnixProcess.cs",
            "platform/WindowsProcess.cs"
        };
        private static readonly object Sync = new object();
        private static string sealedFingerprint;

        public static string Fingerprint
        {
            get { lock (Sync) { return sealedFingerprint; } }
        }

        public static void Seal(string fingerprint)
        {
            if (fingerprint == null || fingerprint.Length != 64)
                throw new ArgumentException("The platform runtime fingerprint must contain 64 lowercase hexadecimal characters.", "fingerprint");
            for (int i = 0; i < fingerprint.Length; i++)
                if ((fingerprint[i] < '0' || fingerprint[i] > '9') && (fingerprint[i] < 'a' || fingerprint[i] > 'f'))
                    throw new ArgumentException("The platform runtime fingerprint must contain 64 lowercase hexadecimal characters.", "fingerprint");
            lock (Sync)
            {
                if (sealedFingerprint == null) { sealedFingerprint = fingerprint; return; }
                if (!String.Equals(sealedFingerprint, fingerprint, StringComparison.Ordinal))
                    throw new InvalidOperationException("The platform runtime build is already sealed with a different fingerprint.");
            }
        }

        public static string ComputeSourceFingerprint(string runtimeRoot)
        {
            if (String.IsNullOrEmpty(runtimeRoot) || !Path.IsPathFullyQualified(runtimeRoot))
                throw new ArgumentException("The platform runtime root must be an absolute path.", "runtimeRoot");

            string root = Path.GetFullPath(runtimeRoot);
            var utf8 = new UTF8Encoding(false, true);
            using (var fingerprint = new MemoryStream())
            {
                foreach (string relativePath in RuntimeSourcePaths)
                {
                    string sourcePath = Path.Combine(root, relativePath);
                    FileAttributes attributes = File.GetAttributes(sourcePath);
                    if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                        throw new IOException("Platform runtime source files must be regular non-reparse files.");

                    byte[] sourceBytes = File.ReadAllBytes(sourcePath);
                    if (sourceBytes.Length >= 3 && sourceBytes[0] == 0xef && sourceBytes[1] == 0xbb && sourceBytes[2] == 0xbf)
                        throw new InvalidDataException("Platform runtime source files must be UTF-8 without BOM.");
                    byte[] canonicalBytes = utf8.GetBytes(utf8.GetString(sourceBytes).Replace("\r\n", "\n"));
                    byte[] prefixBytes = utf8.GetBytes(relativePath + "\n" + canonicalBytes.Length.ToString(CultureInfo.InvariantCulture) + "\n");
                    fingerprint.Write(prefixBytes, 0, prefixBytes.Length);
                    fingerprint.Write(canonicalBytes, 0, canonicalBytes.Length);
                }

                using (var sha256 = SHA256.Create())
                    return BitConverter.ToString(sha256.ComputeHash(fingerprint.ToArray())).Replace("-", "").ToLowerInvariant();
            }
        }
    }

    // Bounded data I/O on a borrowed P2 handle; no public native handle or path reopen.
    internal static class LeaseBytes
    {
        internal static byte[] Read(SafeHandle handle, int maximumBytes)
        {
            if (maximumBytes < 0) throw new ArgumentOutOfRangeException("maximumBytes");
            using (var borrowed = new Microsoft.Win32.SafeHandles.SafeFileHandle(handle.DangerousGetHandle(), false))
            using (var stream = new System.IO.FileStream(borrowed, System.IO.FileAccess.Read))
            {
                long length = stream.Length;
                if (length > maximumBytes) throw new System.IO.IOException("File exceeds the bounded read limit.");
                stream.Position = 0;
                byte[] bytes = new byte[checked((int)length)];
                int offset = 0;
                while (offset < bytes.Length)
                {
                    int count = stream.Read(bytes, offset, bytes.Length - offset);
                    if (count == 0) throw new System.IO.EndOfStreamException();
                    offset += count;
                }
                if (stream.ReadByte() != -1) throw new System.IO.IOException("File grew during the bounded read.");
                return bytes;
            }
        }
        internal static void Write(SafeHandle handle, byte[] bytes)
        {
            if (bytes == null) throw new ArgumentNullException("bytes");
            using (var borrowed = new Microsoft.Win32.SafeHandles.SafeFileHandle(handle.DangerousGetHandle(), false))
            using (var stream = new System.IO.FileStream(borrowed, System.IO.FileAccess.Write))
            {
                if (stream.Length != 0) throw new System.IO.IOException("New evidence file is no longer empty.");
                stream.Position = 0; stream.Write(bytes, 0, bytes.Length); stream.Flush(true);
            }
        }
    }

    public static class PlatformNative
    {
        public static string GetOperatingSystem()
        {
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) return "windows";
            if (RuntimeInformation.IsOSPlatform(OSPlatform.Linux)) return "linux";
            if (RuntimeInformation.IsOSPlatform(OSPlatform.OSX)) return "macos";
            throw new PlatformCapabilityUnavailableException("operating-system", "unknown");
        }

        public static string GetArchitecture()
        {
            switch (RuntimeInformation.ProcessArchitecture)
            {
                case Architecture.X64: return "x64";
                case Architecture.X86: return "x86";
                case Architecture.Arm64: return "arm64";
                case Architecture.Arm: return "arm";
                default: throw new PlatformCapabilityUnavailableException(
                    "architecture", GetOperatingSystem());
            }
        }
    }

    public class PlatformCapabilityUnavailableException : InvalidOperationException
    {
        public string Capability { get; private set; }
        public string Platform { get; private set; }

        public PlatformCapabilityUnavailableException(string capability, string platform)
            : base(String.Format(
                "Platform capability '{0}' is not available on '{1}'.", capability, platform))
        {
            Capability = capability;
            Platform = platform;
        }

        protected PlatformCapabilityUnavailableException(
            string message, string capability, string platform) : base(message)
        {
            Capability = capability;
            Platform = platform;
        }
    }

    public sealed class PlatformNotImplementedException : PlatformCapabilityUnavailableException
    {
        public string ImplementationStep { get; private set; }

        public PlatformNotImplementedException(string capability, string platform, string implementationStep)
            : base(String.Format(
                "Platform capability '{0}' is not implemented on '{1}'; implementation is deferred to {2}.",
                capability, platform, implementationStep), capability, platform)
        {
            ImplementationStep = implementationStep;
        }
    }

    public sealed class PlatformErrnoException : InvalidOperationException
    {
        public int Errno { get; private set; }
        public string ErrnoName { get; private set; }
        public string Operation { get; private set; }

        public PlatformErrnoException(string operation, int errno)
            : this(operation, errno, "UNKNOWN")
        {
        }

        public PlatformErrnoException(string operation, int errno, string errnoName)
            : base(String.Format("Native operation '{0}' failed with {1} (errno {2}).", operation, errnoName, errno))
        {
            Operation = operation;
            Errno = errno;
            ErrnoName = errnoName;
        }
    }

    public sealed class PlatformMutationException : System.IO.IOException
    {
        public string Capability { get; private set; }
        public string Platform { get; private set; }
        public string CurrentState { get; private set; }
        public object Receipt { get; private set; }

        public PlatformMutationException(string capability, string platform, string currentState, string message, object receipt)
            : base(String.Format("Platform mutation for '{0}' failed on '{1}' in state '{2}': {3}", capability, platform, currentState, message))
        {
            Capability = capability;
            Platform = platform;
            CurrentState = currentState;
            Receipt = receipt;
        }
    }

    public sealed class PlatformVerificationException : System.IO.IOException
    {
        public string Capability { get; private set; }
        public string Platform { get; private set; }

        public PlatformVerificationException(string capability, string platform, string message)
            : base(String.Format("Platform verification for '{0}' failed on '{1}': {2}", capability, platform, message))
        {
            Capability = capability;
            Platform = platform;
        }
    }

    public sealed class PlatformWin32Exception : InvalidOperationException
    {
        public int Win32Error { get; private set; }
        public string Operation { get; private set; }

        public PlatformWin32Exception(string operation, int win32Error)
            : base(String.Format("Native operation '{0}' failed with Win32 error {1}.", operation, win32Error))
        {
            Operation = operation;
            Win32Error = win32Error;
        }
    }
}
