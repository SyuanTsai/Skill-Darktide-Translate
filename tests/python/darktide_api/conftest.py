import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "packages/claude-runner"))
sys.path.insert(0, str(REPO_ROOT / "packages/darktide-translate"))
