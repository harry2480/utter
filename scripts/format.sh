#!/usr/bin/env bash
# Swiftソースを swift format で整形する。Swiftソースがなければ何もしない。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift_sources="$(git ls-files --cached --others --exclude-standard -- '*.swift')"
if [[ -z "$swift_sources" ]]; then
  exit 0
fi

printf '%s\n' "$swift_sources" | xargs swift format format --in-place
