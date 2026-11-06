#!/usr/bin/env python3
"""Copy reader-facing documentation, keeping bundled links usable offline."""
import argparse
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
FILES = ("README.md", "README.en.md", "THIRD-PARTY-NOTICES.md", "docs/INSTALL.md",
         "docs/INSTALL.en.md", "docs/PRIVACY.md", "docs/RELEASE-v1.0.md")
LOGO = "docs/assets/keywoo-icon.png"


def copy_docs(destination):
    logo = destination / LOGO
    logo.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / LOGO, logo)
    for name in FILES:
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text((ROOT / name).read_text())
    for name in FILES:
        target = destination / name
        def replace(match):
            label, link = match.groups()
            if ":" in link or link.startswith("#"):
                return match.group(0)
            if (target.parent / link.partition("#")[0]).exists():
                return match.group(0)
            source = (Path(name).parent / link).as_posix()
            if source.startswith("Sources/KeyDance/Resources/KeyboardSounds/"):
                relative = "../KeyboardSounds/" + source.split("KeyboardSounds/", 1)[1]
                if (target.parent / relative).exists():
                    return "[" + label + "](" + relative + ")"
            # Development-only references remain available in the source repository.
            return "[" + label + "](https://github.com/LeavesLei/KeyWoo/blob/v1.0.0/" + source + ")"
        target.write_text(re.sub(r"\[([^\]]+)\]\(([^)]+)\)", replace, target.read_text()))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    copy_docs(parser.parse_args().destination)
