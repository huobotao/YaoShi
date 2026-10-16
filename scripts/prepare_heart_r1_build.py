#!/usr/bin/env python3
"""Reject a Heart R1 build when any R4 data-sharing identity survived."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent.parent
FILES = [
    *ROOT.joinpath("Sources").glob("*.swift"),
    *ROOT.joinpath("Widget").glob("*.swift"),
    *ROOT.joinpath("Shared", "PartnerSync").glob("*.swift"),
]
bad = [str(path.relative_to(ROOT)) for path in FILES
       if "v21012r4" in path.read_text() or "yaoshi-21012r4" in path.read_text()]
if bad:
    sys.exit("Heart R1 隔离检查失败，发现 R4 标识: " + ", ".join(bad))
print("Heart R1 身份隔离检查通过")
