#!/usr/bin/env python3
"""Build the installable plugin archive without development artifacts."""

import argparse
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Destination ZIP file")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    files = [root / name for name in (
        "main.lua", "_meta.lua", "storygraph_version.lua", "version.json",
        "storygraph_config.example.lua", "LICENSE",
    )]
    files.extend(sorted(path for path in (root / "storygraph").rglob("*") if path.is_file()))
    with ZipFile(args.output, "w", compression=ZIP_DEFLATED) as archive:
        for path in files:
            archive.write(path, "storygraph.koplugin/" + path.relative_to(root).as_posix())


if __name__ == "__main__":
    main()
