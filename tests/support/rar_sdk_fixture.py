# SPDX-FileCopyrightText: 2026 SyuanTsai
# SPDX-License-Identifier: Apache-2.0
"""Offline SDK fixture. Exercise the production header and callback adapter."""
import ctypes
import json
from pathlib import Path
import runpy
import sys
import zlib

reader = runpy.run_path(str(Path(__file__).with_name("reader_under_test.py")))
rows = json.loads(Path(sys.argv[1]).read_bytes()[8:])


class FixtureSDK:
    def RAROpenArchiveEx(self, data):
        self.index = 0
        self.callback = data._obj.callback
        return 1

    def RARCloseArchive(self, handle):
        return 0

    def RARReadHeaderEx(self, handle, header):
        if self.index == len(rows):
            return 10
        row = rows[self.index]
        h = header._obj
        h.wide_name = row["name"]
        h.size = h.packed = row.get("size", 3)
        h.host = 2
        h.hash_type = 1
        h.crc = row.get("crc", zlib.crc32(row.get("data", "abc").encode()))
        h.attributes = 32
        h.redir_type = row.get("redirect", 0)
        return 0

    def RARProcessFileW(self, handle, operation, target, name):
        assert target is None and name is None
        row = rows[self.index]
        self.index += 1
        if operation == 0:
            return 0
        assert operation == 1
        payload = row.get("data", "abc").encode()
        buffer = ctypes.create_string_buffer(payload)
        if self.callback(1, 0, ctypes.addressof(buffer), len(payload)) < 0:
            return 12
        return row.get("error", 0)


reader["process"](FixtureSDK(), sys.argv[1])
