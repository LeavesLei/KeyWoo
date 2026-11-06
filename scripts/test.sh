#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CLANG_MODULE_CACHE_PATH="$ROOT/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT/.build/module-cache"
python3 "$ROOT/scripts/prepare-assets.py"
# Audio and localization tests share process-wide caches and MainActor state.
# Serial execution keeps preview deadlines independent of another cache's setup.
swift test --no-parallel --disable-xctest --disable-sandbox --cache-path "$ROOT/.build/spm-cache" --scratch-path "$ROOT/.build" -Xswiftc -module-cache-path -Xswiftc "$CLANG_MODULE_CACHE_PATH" "$@"
