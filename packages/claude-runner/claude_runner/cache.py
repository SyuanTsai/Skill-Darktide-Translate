"""依呼叫端提供的輸入身分儲存已通過的結果。"""

import hashlib
import json
from pathlib import Path

from .state import atomic_json, read_json


def cache_key(identity):
    canonical = json.dumps(identity, ensure_ascii=False, sort_keys=True,
                           separators=(",", ":"), allow_nan=False)
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class Cache:
    def __init__(self, directory: Path):
        self.directory = directory

    def _path(self, identity):
        key = cache_key(identity)
        return self.directory / key[:2] / f"{key}.json"

    def get(self, identity):
        try:
            entry = read_json(self._path(identity))
        except (FileNotFoundError, ValueError):
            return None
        if not isinstance(entry, dict) or entry.get("identity") != identity:
            return None
        return entry.get("result")

    def put(self, identity, result):
        atomic_json(self._path(identity), {"identity": identity, "result": result})
