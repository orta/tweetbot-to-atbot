#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB to every slice of a Mach-O using LIEF (handles the
header-padding/relocation case the minimal Node patcher can't)."""
import sys, lief

path, install = sys.argv[1], sys.argv[2]
fat = lief.MachO.parse(path)
for b in fat:
    names = [c.name for c in b.libraries]
    if install in names:
        print(f"  {b.header.cpu_type}: already present"); continue
    b.add_library(install)
    print(f"  {b.header.cpu_type}: added LC_LOAD_DYLIB -> {install}")
fat.write(path)
print(f"patched: {path}")
