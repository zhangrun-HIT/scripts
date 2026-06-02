#!/usr/bin/env python3
"""WSL/Windows entrypoint for the shared select_clash_node.py script."""

from pathlib import Path
import runpy
import sys


ROOT = Path(__file__).resolve().parent.parent
TARGET = ROOT / "select_clash_node.py"

sys.path.insert(0, str(ROOT))
runpy.run_path(str(TARGET), run_name="__main__")

