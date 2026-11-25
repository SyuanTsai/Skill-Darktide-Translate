"""原子檔案寫入與不可變工作識別綁定。"""

import json
import os
from pathlib import Path
from tempfile import NamedTemporaryFile


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def atomic_text(path: Path, contents: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with NamedTemporaryFile(mode="w", encoding="utf-8", newline="\n",
                                dir=path.parent, prefix=f".{path.name}.", suffix=".tmp",
                                delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(contents)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def atomic_json(path: Path, value):
    atomic_text(path, json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n")


class StateMismatch(ValueError):
    pass


class State:
    def __init__(self, path: Path, identity: dict):
        self.path = path
        contract = {"stateVersion": 1, **identity}
        self.data = read_json(path) if path.exists() else {**contract, "units": {}, "usage": {}}
        if (not isinstance(self.data, dict)
                or any(self.data.get(key) != value for key, value in contract.items())
                or not isinstance(self.data.get("units"), dict)
                or not isinstance(self.data.get("usage"), dict)):
            raise StateMismatch("狀態檔與目前工作集不同，請移除舊狀態檔或改用新的 --state 路徑。")

    @property
    def units(self):
        return self.data["units"]

    def save(self):
        atomic_json(self.path, self.data)

    def set_unit(self, unit_id, record):
        self.units[unit_id] = record
        self.save()
