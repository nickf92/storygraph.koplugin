#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="${STORYGRAPH_TEST_RUNTIME:-$repo_dir/lua_modules/test-runtime}"
cd "$repo_dir"
if [[ ! -x "$runtime/bin/busted" ]]; then
  echo 'Run scripts/setup-tests.sh first (or set STORYGRAPH_TEST_RUNTIME).' >&2
  exit 1
fi
"$runtime/bin/busted" "$@"
while IFS= read -r file; do
  "$runtime/bin/luac" -p "$file"
done < <(rg --files -g '*.lua')
echo 'All tracked/unignored Lua files passed syntax checks.'
