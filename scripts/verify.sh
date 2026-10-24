#!/usr/bin/env bash
# 品質チェック: format lint → ログ出力の検査 → Swift Package の build/test → シェルスクリプト lint
# アプリターゲット（Apps/, Extensions/, Workers/）の xcodebuild は、ターゲット作成時にここへ追加する。
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

swift_sources="$(git ls-files --cached --others --exclude-standard -- '*.swift')"

echo "==> swift format lint"
if [[ -z "$swift_sources" ]]; then
  echo "Swiftソースがないためスキップします。"
else
  printf '%s\n' "$swift_sources" | xargs swift format lint --strict
fi

echo "==> ログ出力の検査（iAC-10）"
scripts/check-logging.sh

echo "==> Swift Package build / test"
shopt -s nullglob
packages=(Packages/*/Package.swift)
if (( ${#packages[@]} == 0 )); then
  echo "Packages/ にSwift Packageがないためスキップします。"
else
  for manifest in "${packages[@]}"; do
    package_dir="$(dirname -- "$manifest")"
    echo "--> $package_dir"
    swift build --package-path "$package_dir"
    swift test --package-path "$package_dir"
  done
fi

echo "==> shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # Verification/ の計測スクリプトも対象にする（Swift のビルドは verify に含めない。各 README を参照）
  shell_scripts=(scripts/*.sh Verification/*/scripts/*.sh)
  shellcheck "${shell_scripts[@]}"
else
  echo "shellcheck が見つからないためスキップします（brew install shellcheck）。"
fi

echo "すべての品質チェックに成功しました。"
