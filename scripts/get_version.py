#!/usr/bin/env python3
"""Read the file version from a PE executable (whale.exe)."""
import sys

import pefile


def find_file_version(obj):
    # FileInfo layout varies across pefile versions (nested lists/objects),
    # so walk it generically looking for StringFileInfo entries.
    if isinstance(obj, (list, tuple)):
        for item in obj:
            found = find_file_version(item)
            if found:
                return found
    elif hasattr(obj, "StringTable"):
        for st in obj.StringTable or []:
            entries = getattr(st, "entries", None) or {}
            for key, value in entries.items():
                key = key.decode() if isinstance(key, bytes) else key
                if key == "FileVersion":
                    return value.decode() if isinstance(value, bytes) else value
    elif isinstance(obj, dict):
        for key in ("StringFileInfo", "StringTable"):
            found = find_file_version(obj.get(key))
            if found:
                return found
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <exe>", file=sys.stderr)
        return 2
    pe = pefile.PE(sys.argv[1], fast_load=True)
    pe.parse_data_directories(
        directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_RESOURCE"]]
    )
    version = find_file_version(getattr(pe, "FileInfo", []))
    if not version:
        fixed = getattr(pe, "VS_FIXEDFILEINFO", None)
        if isinstance(fixed, list):
            fixed = next((f for f in fixed if hasattr(f, "FileVersion")), None)
        if fixed:
            version = fixed.FileVersion
    pe.close()
    if not version:
        print("no version info found", file=sys.stderr)
        return 1
    print(version.strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
