#!/usr/bin/env python3
"""Run isolated Tcl checks without a tablet, machine, or private source tree."""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
cases = sorted(ROOT.glob("aiden/tests/*.test")) + sorted(ROOT.glob("tests/*.test"))
cases += [ROOT / "aiden/ui-fixture.tcl"]
failed = False
with tempfile.TemporaryDirectory(prefix="aiden-tests-") as temp:
    for case in cases:
        result = subprocess.run([os.environ.get("TCLSH", "tclsh"), str(case)],
                                cwd=temp, capture_output=True, text=True)
        print(result.stdout, end="")
        if result.stderr:
            print(result.stderr, file=sys.stderr, end="")
        failed |= result.returncode != 0 or bool(re.search(r"Failed\s+[1-9]", result.stdout))
        if case.suffix == ".test" and not re.search(r"Total\s+\d+.*Failed\s+\d+", result.stdout):
            failed = True
sys.exit(1 if failed else 0)
