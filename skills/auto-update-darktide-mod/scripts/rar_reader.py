# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
"""Read the UnRAR SDK's structured headers. RAR_TEST only, never RAR_EXTRACT."""
import ctypes as c
import ctypes.util
from contextlib import ExitStack, contextmanager
import hashlib
import json
import os
from pathlib import Path
import sys
import zlib
import tempfile

U = c.c_uint32
P = c.c_void_p
CALL = c.WINFUNCTYPE if os.name == "nt" else c.CFUNCTYPE
Callback = CALL(c.c_int, U, c.c_ssize_t, c.c_ssize_t, c.c_ssize_t)


class OpenData(c.Structure):
    _pack_ = 1
    _fields_ = [
        ("name", P), ("wide_name", c.c_wchar_p), ("mode", U), ("result", U),
        ("comment", P), ("capacity", U), ("length", U), ("state", U),
        ("flags", U), ("callback", Callback), ("user", c.c_ssize_t),
        ("op_flags", U), ("wide_comment", P), ("reserved", U * 32),
    ]


class Header(c.Structure):
    _pack_ = 1
    _fields_ = [
        ("archive", c.c_char * 1024), ("wide_archive", c.c_wchar * 1024),
        ("name", c.c_char * 1024), ("wide_name", c.c_wchar * 1024),
        *((key, U) for key in ("flags", "packed", "packed_high", "size", "size_high",
                               "host", "crc", "time", "version", "method", "attributes")),
        ("comment", P), ("capacity", U), ("length", U), ("state", U),
        ("dictionary_kb", U), ("hash_type", U), ("hash", c.c_ubyte * 32),
        ("redir_type", U), ("redir_name", P), ("redir_size", U), ("dir_target", U),
        ("reserved", U * 1024),
    ]


def library():
    location = os.environ.get("DARKTIDE_UNRAR_LIBRARY")
    if location:
        if not Path(location).is_absolute():
            raise ValueError("DARKTIDE_UNRAR_LIBRARY requires an absolute installed library path")
    elif os.name == "nt":
        location = str(Path(os.environ["ProgramFiles"]) / "WinRAR" / "UnRAR.dll")
    else:
        location = ctypes.util.find_library("unrar")
    if not location:
        raise RuntimeError("UnRAR shared library unavailable. Set DARKTIDE_UNRAR_LIBRARY.")
    try:
        dll = (c.WinDLL if os.name == "nt" else c.CDLL)(location)
    except OSError as exc:
        raise RuntimeError("Cannot load installed UnRAR. Set DARKTIDE_UNRAR_LIBRARY to its absolute path.") from exc
    dll.RARGetDllVersion.restype, dll.RARGetDllVersion.argtypes = c.c_int, []
    dll.RAROpenArchiveEx.restype, dll.RAROpenArchiveEx.argtypes = P, [c.POINTER(OpenData)]
    dll.RARReadHeaderEx.restype, dll.RARReadHeaderEx.argtypes = c.c_int, [P, c.POINTER(Header)]
    dll.RARProcessFileW.restype, dll.RARProcessFileW.argtypes = c.c_int, [P, c.c_int, P, P]
    dll.RARCloseArchive.restype, dll.RARCloseArchive.argtypes = c.c_int, [P]
    if dll.RARGetDllVersion() < 8:
        raise ValueError("UnRAR SDK API version 8 or newer required")
    return dll


@contextmanager
def opened(dll, path, mode, callback):
    data = OpenData(wide_name=str(path), mode=mode, callback=callback)
    handle = dll.RAROpenArchiveEx(c.byref(data))
    if not handle:
        raise ValueError(f"RAR open failed ({data.result})")
    try:
        if data.result or data.flags & (1 | 32 | 128):
            raise ValueError("Invalid, multi-volume or encrypted RAR")
        yield handle
    finally:
        if dll.RARCloseArchive(handle):
            raise ValueError("RAR close failed")


def entries(dll, handle):
    while True:
        h = Header()
        result = dll.RARReadHeaderEx(handle, c.byref(h))
        if result == 10:  # ERAR_END_ARCHIVE
            return
        if result:
            raise ValueError(f"RAR header failed ({result})")
        path = h.wide_name.replace("\\", "/")
        unit_encoding = "utf-16-le" if c.sizeof(c.c_wchar) == 2 else "utf-32-le"
        name_units = len(h.wide_name.encode(unit_encoding)) // c.sizeof(c.c_wchar)
        if not path or name_units >= 1023 or h.flags & ~0x30 or h.redir_type or h.dir_target:
            raise ValueError("Unrepresentable RAR name, split/encrypted entry or link")
        directory = bool(h.flags & 32)
        if h.host == 3:
            mode = h.attributes
            if mode >> 16 or mode & 0o170000 != (0o040000 if directory else 0o100000):
                raise ValueError("RAR Unix entry is not a regular file or directory")
            attributes = mode << 16
        elif h.host in (0, 2):
            attributes = h.attributes
            if attributes & ~0xB7 or bool(attributes & 16) != directory:
                raise ValueError("Unsupported RAR Windows attributes")
        else:
            raise ValueError("Unsupported RAR host attributes")
        if h.dictionary_kb > 256 * 1024:
            raise ValueError("RAR decompression dictionary exceeds 256 MiB")
        entry = {
            "path": path + ("/" if directory and not path.endswith("/") else ""),
            "directory": directory,
            "size": h.size | h.size_high << 32,
            "compressedSize": h.packed | h.packed_high << 32,
            "externalAttributes": attributes,
        }
        if not directory:
            if h.hash_type == 1:
                entry["crc32"] = h.crc
            elif h.hash_type == 2:
                entry["blake2sp"] = bytes(h.hash).hex()
            else:
                raise ValueError("RAR regular file has no supported integrity checksum")
        yield entry


def process(dll, path):
    remaining = 0
    crc = 0
    error = None

    @Callback
    def callback(message, user, buffer, length):
        nonlocal remaining, error, crc
        if message != 1:  # refuse new volumes, password prompts and other requests
            return -1
        try:
            if not 0 <= length <= remaining:
                raise ValueError("RAR decoder exceeded the declared entry size")
            data = c.string_at(buffer, length)
            crc = zlib.crc32(data, crc)
            sys.stdout.buffer.write(data)
            remaining -= length
            return 1
        except Exception as exc:
            error = exc
            return -1

    manifest = []
    name_chars = 0
    with opened(dll, path, 2, callback) as handle:
        for entry in entries(dll, handle):
            name_chars += len(entry["path"])
            if name_chars > 4 * 1024 * 1024:
                raise ValueError("RAR manifest path metadata exceeds 4 Mi characters")
            if len(manifest) >= 100000:
                raise ValueError("RAR entry count exceeds 100,000")
            manifest.append(entry)
            if dll.RARProcessFileW(handle, 0, None, None):
                raise ValueError("RAR manifest is incomplete")
    print(json.dumps(manifest, separators=(",", ":")), flush=True)
    if sys.stdin.readline().strip() != "stream":
        return
    # The caller has now validated every destination and the aggregate limits.
    count = 0
    with opened(dll, path, 1, callback) as handle:
        for entry in entries(dll, handle):
            if count >= len(manifest) or entry != manifest[count]:
                raise ValueError("RAR header differs during replay")
            remaining = entry["size"]
            crc = 0
            result = dll.RARProcessFileW(handle, 1, None, None)  # RAR_TEST checks integrity
            if result or remaining or error:
                raise ValueError(f"RAR integrity or byte count failed ({result}, {remaining}, {error})")
            if "crc32" in entry and entry["crc32"] != crc:
                raise ValueError("RAR output CRC differs from manifest")
            count += 1
    if count != len(manifest):
        raise ValueError("RAR replay omitted entries")
    sys.stdout.buffer.flush()


if __name__ == "__main__":
    try:
        dll = library()
        if sys.argv[1:] == ["--check"]:
            print(f"UnRAR SDK API {dll.RARGetDllVersion()}")
        else:
            with ExitStack() as stack:
                source = stack.enter_context(open(sys.argv[1], "rb"))
                # Windows intake holds a deny-write handle. On Unix, bind both
                # SDK passes to an anonymous copy of the bytes actually hashed.
                snapshot = None
                if os.name != "nt":
                    snapshot = stack.enter_context(tempfile.TemporaryFile())
                digest = hashlib.sha256()
                for block in iter(lambda: source.read(1024 * 1024), b""):
                    digest.update(block)
                    if snapshot is not None:
                        snapshot.write(block)
                if digest.hexdigest() != sys.argv[2]:
                    raise ValueError("RAR archive SHA-256 differs")
                path = sys.argv[1]
                if snapshot is not None:
                    snapshot.flush()
                    snapshot.seek(0)
                    path = f"/dev/fd/{snapshot.fileno()}"
                process(dll, path)
    except Exception as exc:
        sys.exit(f"RAR verification failed: {exc}")
