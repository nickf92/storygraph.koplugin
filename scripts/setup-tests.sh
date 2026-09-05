#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="${STORYGRAPH_TEST_RUNTIME:-$repo_dir/lua_modules/test-runtime}"
python3 -m venv "$runtime-bootstrap"
"$runtime-bootstrap/bin/pip" install hererocks==0.25.1
"$runtime-bootstrap/bin/hererocks" "$runtime" --lua 5.1.5 --luarocks 3.8.0 --no-readline
while read -r package version; do
  "$runtime/bin/luarocks" install "$package" "$version" --deps-mode=none
done < "$repo_dir/scripts/test-dependencies.txt"
