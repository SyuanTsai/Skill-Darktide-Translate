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
    internal struct InstallerFileDispositionInfo
    {
        [MarshalAs(UnmanagedType.Bool)]
        internal bool DeleteFile;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct InstallerFileBasicInfo
    {
        internal long CreationTime;
        internal long LastAccessTime;
        internal long LastWriteTime;
        internal long ChangeTime;
        internal uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct InstallerByHandleFileInformation
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

    public sealed class InstallerDirectoryGuard : IDisposable
    {
        private List<SafeFileHandle> handles;

        internal InstallerDirectoryGuard(List<SafeFileHandle> handles)
        {
            this.handles = handles;
        }

        public void Dispose()
        {
            if (handles == null)
            {
                return;
            }
            for (int index = handles.Count - 1; index >= 0; index--)
            {
                handles[index].Dispose();
            }
            handles = null;
        }
    }

    public sealed class InstallerFileMutationContext : IDisposable
    {
        private SafeFileHandle fileHandle;
        private List<SafeFileHandle> directoryHandles;
        public bool Created { get; private set; }
        public bool RestoreReadOnly { get; private set; }

        internal InstallerFileMutationContext(
            SafeFileHandle fileHandle,
            List<SafeFileHandle> directoryHandles,
            bool created,
            bool restoreReadOnly)
        {
            this.fileHandle = fileHandle;
            this.directoryHandles = directoryHandles;
            Created = created;
            RestoreReadOnly = restoreReadOnly;
        }

        public SafeFileHandle TakeFileHandle()
        {
            if (fileHandle == null)
            {
                throw new InvalidOperationException("The installer mutation handle has already been transferred.");
            }
            SafeFileHandle result = fileHandle;
            fileHandle = null;
            return result;
        }

        public void Dispose()
        {
            if (fileHandle != null)
            {
                fileHandle.Dispose();
                fileHandle = null;
            }
            if (directoryHandles != null)
            {
                for (int index = directoryHandles.Count - 1; index >= 0; index--)
                {
                    directoryHandles[index].Dispose();
                }
                directoryHandles = null;
            }
        }
    }

    public static class InstallerNativeMutation
    {
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint Delete = 0x00010000;
        private const uint FileWriteAttributes = 0x00000100;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint FileShareDelete = 0x00000004;
        private const uint CreateNew = 1;
        private const uint OpenExisting = 3;
        private const uint FileAttributeReadOnly = 0x00000001;
        private const uint FileAttributeDirectory = 0x00000010;
        private const uint FileAttributeNormal = 0x00000080;
        private const uint FileAttributeReparsePoint = 0x00000400;
        private const uint FileFlagBackupSemantics = 0x02000000;
        private const uint FileFlagOpenReparsePoint = 0x00200000;
        private const int FileBasicInfoClass = 0;
        private const int FileDispositionInfoClass = 4;
        private const int ErrorFileNotFound = 2;
        private const int ErrorPathNotFound = 3;
        private const int ErrorAccessDenied = 5;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
        private static extern SafeFileHandle CreateFile(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileDispositionByHandle(
            SafeFileHandle file,
            int fileInformationClass,
            ref InstallerFileDispositionInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetFileInformationByHandle")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool SetFileBasicInfoByHandle(
            SafeFileHandle file,
            int fileInformationClass,
            ref InstallerFileBasicInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(
            SafeFileHandle file,
            int fileInformationClass,
            out InstallerFileBasicInfo fileInformation,
            uint bufferSize);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandle(
            SafeFileHandle file,
            out InstallerByHandleFileInformation fileInformation);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandle(
            SafeFileHandle file,
            StringBuilder path,
            uint pathLength,
            uint flags);

        public static InstallerDirectoryGuard OpenDirectoryGuard(string targetRoot, string relativeDirectory)
        {
            string lexicalRoot = Path.GetFullPath(targetRoot).TrimEnd('\\');
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            try
            {
                SafeFileHandle rootHandle = OpenValidatedDirectory(
                    lexicalRoot,
                    null,
                    "Unable to guard the installer target root.");
                handles.Add(rootHandle);
                string currentPath = lexicalRoot;
                string currentFinalPath = GetFinalPath(rootHandle).TrimEnd('\\');
                if (!string.IsNullOrWhiteSpace(relativeDirectory))
                {
                    foreach (string segment in NormalizeRelativePath(relativeDirectory).Split('\\'))
                    {
                        currentPath = Path.Combine(currentPath, segment);
                        currentFinalPath = currentFinalPath + "\\" + segment;
                        handles.Add(OpenValidatedDirectory(
                            currentPath,
                            currentFinalPath,
                            "Unable to guard an installer mutation directory."));
                    }
                }
                InstallerDirectoryGuard result = new InstallerDirectoryGuard(handles);
                handles = null;
                return result;
            }
            finally
            {
                if (handles != null)
                {
                    for (int index = handles.Count - 1; index >= 0; index--)
                    {
                        handles[index].Dispose();
                    }
                }
            }
        }

        public static void AssertSingleLinkFile(string path)
        {
            SafeFileHandle handle = CreateFile(
                Path.GetFullPath(path),
                GenericRead,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileAttributeNormal | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            try
            {
                EnsureValidHandle(handle, "Unable to inspect an installer destination file.");
                ValidateRegularFile(handle, null, "installer destination validation");
            }
            finally
            {
                handle.Dispose();
            }
        }

        public static InstallerFileMutationContext OpenForAtomicWriteOrCreate(
            string targetRoot,
            string path,
            string relativePath)
        {
            string safeRelativePath = NormalizeRelativePath(relativePath);
            string lexicalRoot = Path.GetFullPath(targetRoot).TrimEnd('\\');
            string lexicalPath = Path.GetFullPath(path);
            string expectedLexicalPath = Path.GetFullPath(Path.Combine(lexicalRoot, safeRelativePath));
            if (!string.Equals(lexicalPath, expectedLexicalPath, StringComparison.OrdinalIgnoreCase))
            {
                throw new IOException("The installer file path did not match its target-root relative path.");
            }

            string expectedFinalPath;
            List<SafeFileHandle> directoryHandles = OpenParentGuards(
                lexicalRoot,
                safeRelativePath,
                out expectedFinalPath);
            SafeFileHandle fileHandle = null;
            try
            {
                fileHandle = CreateFile(
                    lexicalPath,
                    GenericRead | GenericWrite | Delete | FileWriteAttributes,
                    FileShareRead,
                    IntPtr.Zero,
                    OpenExisting,
                    FileAttributeNormal | FileFlagOpenReparsePoint,
                    IntPtr.Zero);
                if (!fileHandle.IsInvalid)
                {
                    ValidateRegularFile(fileHandle, expectedFinalPath, "installer file mutation");
                    InstallerFileMutationContext existingResult = new InstallerFileMutationContext(
                        fileHandle,
                        directoryHandles,
                        false,
                        false);
                    fileHandle = null;
                    directoryHandles = null;
                    return existingResult;
                }

                int openError = Marshal.GetLastWin32Error();
                fileHandle.Dispose();
                fileHandle = null;
                if (openError == ErrorFileNotFound || openError == ErrorPathNotFound)
                {
                    fileHandle = CreateFile(
                        lexicalPath,
                        GenericRead | GenericWrite | Delete | FileWriteAttributes,
                        FileShareRead,
                        IntPtr.Zero,
                        CreateNew,
                        FileAttributeNormal | FileFlagOpenReparsePoint,
                        IntPtr.Zero);
                    EnsureValidHandle(fileHandle, "Unable to create the installer destination file atomically.");
                    ValidateRegularFile(fileHandle, expectedFinalPath, "installer file creation");
                    InstallerFileMutationContext createResult = new InstallerFileMutationContext(
                        fileHandle,
                        directoryHandles,
                        true,
                        false);
                    fileHandle = null;
                    directoryHandles = null;
                    return createResult;
                }
                if (openError != ErrorAccessDenied)
                {
                    throw new Win32Exception(openError, "Unable to open the installer destination for atomic mutation.");
                }

                SafeFileHandle attributeHandle = null;
                uint originalAttributes = 0;
                bool attributeCleared = false;
                try
                {
                    attributeHandle = CreateFile(
                        lexicalPath,
                        GenericRead | FileWriteAttributes,
                        FileShareRead | FileShareWrite,
                        IntPtr.Zero,
                        OpenExisting,
                        FileAttributeNormal | FileFlagOpenReparsePoint,
                        IntPtr.Zero);
                    EnsureValidHandle(attributeHandle, "Unable to inspect a read-only installer destination.");
                    ValidateRegularFile(attributeHandle, expectedFinalPath, "read-only installer destination");
                    originalAttributes = GetAttributes(attributeHandle);
                    if ((originalAttributes & FileAttributeReadOnly) == 0)
                    {
                        throw new Win32Exception(openError, "Unable to acquire an atomic installer write handle.");
                    }
                    SetAttributes(attributeHandle, originalAttributes & ~FileAttributeReadOnly);
                    attributeCleared = true;
                    fileHandle = CreateFile(
                        lexicalPath,
                        GenericRead | GenericWrite | Delete | FileWriteAttributes,
                        FileShareRead,
                        IntPtr.Zero,
                        OpenExisting,
                        FileAttributeNormal | FileFlagOpenReparsePoint,
                        IntPtr.Zero);
                    EnsureValidHandle(fileHandle, "Unable to reopen the read-only installer destination for mutation.");
                    ValidateRegularFile(fileHandle, expectedFinalPath, "installer file mutation");
                    if (!AreSameFile(attributeHandle, fileHandle))
                    {
                        throw new IOException("The installer write handle did not reopen the file whose read-only attribute was cleared.");
                    }
                    InstallerFileMutationContext readOnlyResult = new InstallerFileMutationContext(
                        fileHandle,
                        directoryHandles,
                        false,
                        true);
                    fileHandle = null;
                    directoryHandles = null;
                    return readOnlyResult;
                }
                catch
                {
                    if (attributeCleared && attributeHandle != null && !attributeHandle.IsInvalid)
                    {
                        SetAttributes(attributeHandle, originalAttributes);
                    }
                    throw;
                }
                finally
                {
                    if (attributeHandle != null)
                    {
                        attributeHandle.Dispose();
                    }
                }
            }
            finally
            {
                if (fileHandle != null)
                {
                    fileHandle.Dispose();
                }
                if (directoryHandles != null)
                {
                    for (int index = directoryHandles.Count - 1; index >= 0; index--)
                    {
                        directoryHandles[index].Dispose();
                    }
                }
            }
        }

        public static SafeFileHandle OpenForAtomicDelete(string targetRoot, string path, string relativePath)
        {
            string expectedFinalPath;
            List<SafeFileHandle> directoryHandles = OpenParentGuards(
                Path.GetFullPath(targetRoot).TrimEnd('\\'),
                NormalizeRelativePath(relativePath),
                out expectedFinalPath);
            SafeFileHandle handle = null;
            try
            {
                handle = CreateFile(
                    Path.GetFullPath(path),
                    GenericRead | Delete | FileWriteAttributes,
                    FileShareRead,
                    IntPtr.Zero,
                    OpenExisting,
                    FileAttributeNormal | FileFlagOpenReparsePoint,
                    IntPtr.Zero);
                EnsureValidHandle(handle, "Unable to open the installer destination for atomic deletion.");
                ValidateRegularFile(handle, expectedFinalPath, "installer file deletion");
                SafeFileHandle result = handle;
                handle = null;
                return result;
            }
            finally
            {
                if (handle != null)
                {
                    handle.Dispose();
                }
                for (int index = directoryHandles.Count - 1; index >= 0; index--)
                {
                    directoryHandles[index].Dispose();
                }
            }
        }

        public static void MarkDeleteOnClose(SafeFileHandle handle)
        {
            uint originalAttributes = GetAttributes(handle);
            bool restoreReadOnly = (originalAttributes & FileAttributeReadOnly) != 0;
            if (restoreReadOnly)
            {
                SetAttributes(handle, originalAttributes & ~FileAttributeReadOnly);
            }
            try
            {
                InstallerFileDispositionInfo information = new InstallerFileDispositionInfo { DeleteFile = true };
                uint size = (uint)Marshal.SizeOf(typeof(InstallerFileDispositionInfo));
                if (!SetFileDispositionByHandle(handle, FileDispositionInfoClass, ref information, size))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to mark the installer file for atomic deletion.");
                }
            }
            catch
            {
                if (restoreReadOnly)
                {
                    SetAttributes(handle, originalAttributes);
                }
                throw;
            }
        }

        public static void RestoreReadOnly(SafeFileHandle handle)
        {
            uint attributes = GetAttributes(handle);
            if ((attributes & FileAttributeReadOnly) == 0)
            {
                SetAttributes(handle, (attributes & ~FileAttributeNormal) | FileAttributeReadOnly);
            }
        }

        private static List<SafeFileHandle> OpenParentGuards(
            string lexicalRoot,
            string safeRelativePath,
            out string expectedFileFinalPath)
        {
            List<SafeFileHandle> handles = new List<SafeFileHandle>();
            try
            {
                SafeFileHandle rootHandle = OpenValidatedDirectory(
                    lexicalRoot,
                    null,
                    "Unable to guard the installer target root.");
                handles.Add(rootHandle);
                string currentPath = lexicalRoot;
                string currentFinalPath = GetFinalPath(rootHandle).TrimEnd('\\');
                string[] segments = safeRelativePath.Split('\\');
                for (int index = 0; index < segments.Length - 1; index++)
                {
                    currentPath = Path.Combine(currentPath, segments[index]);
                    currentFinalPath = currentFinalPath + "\\" + segments[index];
                    handles.Add(OpenValidatedDirectory(
                        currentPath,
                        currentFinalPath,
                        "Unable to guard an installer destination parent directory."));
                }
                expectedFileFinalPath = currentFinalPath + "\\" + segments[segments.Length - 1];
                List<SafeFileHandle> result = handles;
                handles = null;
                return result;
            }
            finally
            {
                if (handles != null)
                {
                    for (int index = handles.Count - 1; index >= 0; index--)
                    {
                        handles[index].Dispose();
                    }
                }
            }
        }

        private static SafeFileHandle OpenValidatedDirectory(string path, string expectedFinalPath, string message)
        {
            SafeFileHandle handle = CreateFile(
                path,
                GenericRead,
                FileShareRead | FileShareWrite,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics | FileFlagOpenReparsePoint,
                IntPtr.Zero);
            try
            {
                EnsureValidHandle(handle, message);
                InstallerByHandleFileInformation information = GetInformation(
                    handle,
                    "Unable to inspect a guarded installer directory.");
                if ((information.FileAttributes & FileAttributeReparsePoint) != 0 ||
                    (information.FileAttributes & FileAttributeDirectory) == 0)
                {
                    throw new IOException("An installer mutation directory must be a non-reparse directory.");
                }
                if (expectedFinalPath != null)
                {
                    string actualFinalPath = GetFinalPath(handle).TrimEnd('\\');
                    if (!string.Equals(expectedFinalPath, actualFinalPath, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new IOException("An installer mutation directory resolved outside its guarded target-root path.");
                    }
                }
                return handle;
            }
            catch
            {
                handle.Dispose();
                throw;
            }
        }

        private static void ValidateRegularFile(SafeFileHandle handle, string expectedFinalPath, string operation)
        {
            InstallerByHandleFileInformation information = GetInformation(
                handle,
                "Unable to inspect the " + operation + " handle.");
            if ((information.FileAttributes & FileAttributeReparsePoint) != 0 ||
                (information.FileAttributes & FileAttributeDirectory) != 0)
            {
                throw new IOException("The " + operation + " handle must identify a non-reparse regular file.");
            }
            if (information.NumberOfLinks != 1)
            {
                throw new IOException(
                    "The " + operation + " handle has multiple file-system links; hard link aliases do not provide exclusive ownership.");
            }
            if (expectedFinalPath != null)
            {
                string actualFinalPath = GetFinalPath(handle).TrimEnd('\\');
                if (!string.Equals(expectedFinalPath, actualFinalPath, StringComparison.OrdinalIgnoreCase))
                {
                    throw new IOException("The " + operation + " handle resolved outside its guarded target-root path.");
                }
            }
        }

        private static InstallerByHandleFileInformation GetInformation(SafeFileHandle handle, string message)
        {
            InstallerByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), message);
            }
            return information;
        }

        private static bool AreSameFile(SafeFileHandle first, SafeFileHandle second)
        {
            InstallerByHandleFileInformation firstInformation = GetInformation(first, "Unable to identify an installer file handle.");
            InstallerByHandleFileInformation secondInformation = GetInformation(second, "Unable to identify a reopened installer file handle.");
            return firstInformation.VolumeSerialNumber == secondInformation.VolumeSerialNumber &&
                firstInformation.FileIndexHigh == secondInformation.FileIndexHigh &&
                firstInformation.FileIndexLow == secondInformation.FileIndexLow;
        }

        private static uint GetAttributes(SafeFileHandle handle)
        {
            InstallerFileBasicInfo information;
            uint size = (uint)Marshal.SizeOf(typeof(InstallerFileBasicInfo));
            if (!GetFileInformationByHandleEx(handle, FileBasicInfoClass, out information, size))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read installer file attributes through its handle.");
            }
            return information.FileAttributes;
        }

        private static void SetAttributes(SafeFileHandle handle, uint attributes)
        {
            InstallerFileBasicInfo information;
            uint size = (uint)Marshal.SizeOf(typeof(InstallerFileBasicInfo));
            if (!GetFileInformationByHandleEx(handle, FileBasicInfoClass, out information, size))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to read installer file attributes through its handle.");
            }
            information.FileAttributes = attributes == 0 ? FileAttributeNormal : attributes;
            if (!SetFileBasicInfoByHandle(handle, FileBasicInfoClass, ref information, size))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to update installer file attributes through its handle.");
            }
        }

        private static string GetFinalPath(SafeFileHandle handle)
        {
            uint capacity = 32768;
            StringBuilder path = new StringBuilder((int)capacity);
            uint length = GetFinalPathNameByHandle(handle, path, capacity, 0);
            if (length == 0)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resolve a handle-bound installer path.");
            }
            if (length >= capacity)
            {
                capacity = length + 1;
                path = new StringBuilder((int)capacity);
                length = GetFinalPathNameByHandle(handle, path, capacity, 0);
                if (length == 0 || length >= capacity)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to resolve a complete handle-bound installer path.");
                }
            }
            return path.ToString().Replace('/', '\\');
        }

        private static string NormalizeRelativePath(string relativePath)
        {
            if (string.IsNullOrWhiteSpace(relativePath) || Path.IsPathRooted(relativePath))
            {
                throw new ArgumentException("Installer mutation requires a safe relative path.", "relativePath");
            }
            string[] segments = relativePath.Replace('/', '\\').Split('\\');
            foreach (string segment in segments)
            {
                if (string.IsNullOrWhiteSpace(segment) || segment == "." || segment == "..")
                {
                    throw new ArgumentException("Installer mutation rejected an unsafe relative path.", "relativePath");
                }
            }
            return string.Join("\\", segments);
        }

        private static void EnsureValidHandle(SafeFileHandle handle, string message)
        {
            if (handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                throw new Win32Exception(error, message);
            }
        }
    }
}
