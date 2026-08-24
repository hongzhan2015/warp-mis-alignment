#!/usr/bin/env python3
"""Relocate absolute project paths embedded in archived Warp XML files."""

from pathlib import Path
import argparse
import re


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("xml_root", type=Path)
    parser.add_argument("project_name")
    parser.add_argument("new_project_directory", type=Path)
    args = parser.parse_args()

    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.project_name):
        raise ValueError(f"Unsafe project name: {args.project_name}")

    new_project = str(args.new_project_directory.resolve())
    # Match any absolute Linux path ending at the archived project directory,
    # for example /staging/.../output_TS_3_run001. Paths below it are retained.
    project_path = re.compile(
        rf"/(?:[^/<>'\"\s]+/)*{re.escape(args.project_name)}"
        rf"(?=/|[<>'\"\s]|$)"
    )

    xml_files = sorted(args.xml_root.rglob("*.xml"))
    if not xml_files:
        raise FileNotFoundError(f"No XML files found below {args.xml_root}")

    files_changed = 0
    paths_changed = 0
    for xml_file in xml_files:
        original = xml_file.read_text(encoding="utf-8")
        replacements = 0

        def relocate(match: re.Match[str]) -> str:
            nonlocal replacements
            if match.group(0) != new_project:
                replacements += 1
            return new_project

        updated = project_path.sub(relocate, original)
        if updated != original:
            xml_file.write_text(updated, encoding="utf-8")
            files_changed += 1
            paths_changed += replacements

    print(
        f"Warp XML relocation: {paths_changed} path(s) rewritten "
        f"in {files_changed} of {len(xml_files)} XML file(s)"
    )


if __name__ == "__main__":
    main()
