#!/usr/bin/env python3
"""Render production UI with isolated fixtures after scripts/test.sh builds debug objects."""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
build = root / '.build' / 'debug'
output = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / 'dist' / 'qa' / 'ui-polish' / 'previews'
output.mkdir(parents=True, exist_ok=True)
objects = sorted(p for p in (build / 'KeyDance.build').glob('*.o') if p.name != 'Launcher.swift.o')
objects += sorted((build / 'AudioAtomics.build').glob('*.o'))
if not objects:
    raise SystemExit('Run scripts/test.sh before rendering interface previews.')
executable = output / 'render-ui-preview'
environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(root / '.build' / 'module-cache'))
subprocess.run(['swiftc', '-parse-as-library', '-enable-testing', '-module-cache-path', environment['CLANG_MODULE_CACHE_PATH'],
                '-I', str(build / 'Modules'), '-I', str(build / 'AudioAtomics.build'),
                str(root / 'scripts' / 'render-ui-preview.swift'), *map(str, objects), '-o', str(executable)],
               cwd=root, env=environment, check=True)
subprocess.run([str(executable), str(output)], cwd=root, env=environment, check=True)
